import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/services/auth_session_store.dart';
import '../features/services/base_api.dart';
import '../features/services/cash_book_seen_at_store.dart';
import '../features/services/endPoints.dart';
import '../features/services/flutter_customer_invoice_web_api.dart';
import '../features/services/flutter_customer_payment_api.dart';
import '../features/services/invoice_detail_service.dart';
import '../features/services/invoice_list_pager.dart';
import '../features/services/odoo_rpc_helper.dart';
import '../features/services/payment_history_service.dart';
import '../features/services/calendar_date.dart';
import '../features/services/customer_payment_list_service.dart';
import '../models/amount_book_model.dart';
import '../models/customer_payment_model.dart';
import '../models/invoice_summary_model.dart';
import '../models/net_amount_model.dart';
import 'customer_invoice_viewmodel.dart';
import 'login_viewmodel.dart';

class _CustomerBalance {
  const _CustomerBalance({
    this.advance,
    this.oldBalance,
    required this.fetchedAt,
  });

  final double? advance;
  final double? oldBalance;
  final DateTime fetchedAt;

  bool get hasAny => advance != null || oldBalance != null;

  bool get hasUseful =>
      (advance != null && advance != 0) || (oldBalance != null && oldBalance != 0);

  bool get isFresh =>
      DateTime.now().difference(fetchedAt) < AmountBookViewModel.balanceTtl;
}

class AmountBookViewModel extends ChangeNotifier {
  AmountBookViewModel() {
    hydrateFromSharedCache();
  }

  static const _cacheTtl = Duration(seconds: 3);
  static const _advanceTtl = Duration(seconds: 20);
  /// Soft UI skip window; live form re-read still runs when master id is known.
  static const balanceTtl = Duration(seconds: 3);

  static List<InvoiceSummaryModel>? _advanceCache;
  static DateTime? _advanceCachedAt;
  static final Map<String, _CustomerBalance> _balancesByCustomer = {};
  /// Masters customer id so live refresh can hit the edit form directly.
  static final Map<String, int> _masterCustomerIdByName = {};

  bool loading = false;
  String error = '';
  bool _disposed = false;

  // The backend only ever reports an invoice's *cumulative* paid amount —
  // never the individual payments behind it, and never a date for when
  // any of them happened (only the bill's own date). So to show each
  // payment (e.g. ₹100 then later ₹50) as its own separate, correctly
  // timestamped line — instead of one merged total — we keep our own
  // running log here: whenever the paid amount goes up since we last
  // looked, that increase is appended as its own dated entry.
  //
  // Note: this only survives while the app process is alive. Payments
  // recorded, then the app fully closed and reopened, collapse back into
  // a single "as of bill date" entry on that next cold start, since
  // nothing is yet persisted to disk to remember the log across restarts.
  static final Map<int, double> _lastKnownPaidByInvoice = {};
  static final Map<int, List<PaymentLogEntry>> _paymentLogByInvoice = {};

  static DateTime? _paymentBatchTime;

  static List<PaymentLogEntry> _paymentEventsFor(
      int? invoiceId,
      double totalPaid,
      DateTime fallbackDate,
      ) {
    if (invoiceId == null) {
      return [PaymentLogEntry(amount: totalPaid, time: fallbackDate)];
    }

    final hadPrevious = _lastKnownPaidByInvoice.containsKey(invoiceId);
    final lastKnown = _lastKnownPaidByInvoice[invoiceId] ?? 0;

    if (!hadPrevious) {
      // First time this session we've seen this invoice — whatever is
      // already paid is unattributed history, so file it under the
      // bill's own date rather than guessing it just happened now.
      _lastKnownPaidByInvoice[invoiceId] = totalPaid;
      if (totalPaid > 0.0001) {
        _paymentLogByInvoice[invoiceId] = [
          PaymentLogEntry(amount: totalPaid, time: fallbackDate),
        ];
      }
    } else if (totalPaid - lastKnown > 0.0001) {
      // A new payment landed since we last looked — log only the increase
      // as its own entry. Never replace the older payment with the sum.
      _lastKnownPaidByInvoice[invoiceId] = totalPaid;
      final log = _paymentLogByInvoice.putIfAbsent(invoiceId, () => []);
      log.add(
        PaymentLogEntry(
          amount: totalPaid - lastKnown,
          time: _paymentBatchTime ?? DateTime.now(),
        ),
      );
    }

    final log = _paymentLogByInvoice[invoiceId];
    if (log == null || log.isEmpty) {
      return [PaymentLogEntry(amount: totalPaid, time: fallbackDate)];
    }
    return log;
  }

  // Laravel invoice/payment dates often have no clock. We persist the
  // wall-clock when each id first appears in the app so order stays stable.
  static bool _hasEstablishedInvoiceBaseline = false;
  static final Set<int> _knownInvoiceIds = {};
  static final Map<int, DateTime> _saleSeenAt = {};

  static bool _paymentBaselineReady = false;
  static final Map<int, DateTime> _paymentSeenAt = {};
  static bool _seenAtHydrated = false;

  static Future<void> _ensureSeenAtHydrated() async {
    if (_seenAtHydrated) return;
    await CashBookSeenAtStore.ensureLoaded();
    _saleSeenAt.addAll(CashBookSeenAtStore.sales);
    _paymentSeenAt.addAll(CashBookSeenAtStore.payments);
    _knownInvoiceIds.addAll(_saleSeenAt.keys);
    if (_saleSeenAt.isNotEmpty) _hasEstablishedInvoiceBaseline = true;
    if (_paymentSeenAt.isNotEmpty) _paymentBaselineReady = true;
    _seenAtHydrated = true;
  }

  static void _rememberSaleSeen(int id, DateTime at) {
    final kept = CashBookSeenAtStore.rememberSale(id, at);
    _saleSeenAt[id] = kept;
    unawaited(CashBookSeenAtStore.persist());
  }

  static void _rememberPaymentSeen(int id, DateTime at) {
    final kept = CashBookSeenAtStore.rememberPayment(id, at);
    _paymentSeenAt[id] = kept;
    unawaited(CashBookSeenAtStore.persist());
  }

  static void _trackNewlySeenInvoices(List<NetAmountRow> rows) {
    final currentIds = <int>{};
    for (final row in rows) {
      final id = row.id;
      if (id == null || row.sectionKey == 'cancel') continue;
      currentIds.add(id);
    }

    if (!_hasEstablishedInvoiceBaseline) {
      _knownInvoiceIds.addAll(currentIds);
      _hasEstablishedInvoiceBaseline = true;
      final ordered = [...rows]
        ..removeWhere((r) => r.id == null || r.sectionKey == 'cancel')
        ..sort((a, b) => (a.id ?? 0).compareTo(b.id ?? 0));
      final base = DateTime.now().subtract(Duration(seconds: ordered.length + 1));
      for (var i = 0; i < ordered.length; i++) {
        final id = ordered[i].id!;
        if (_saleSeenAt.containsKey(id)) continue;
        final created = CalendarDate.parseDateTime(ordered[i].createdAt);
        if (created != null && CalendarDate.hasClockTime(created)) {
          _rememberSaleSeen(id, created);
        } else {
          // Stable synthetic clock so date-only Laravel rows do not reshuffle.
          _rememberSaleSeen(id, base.add(Duration(seconds: i + 1)));
        }
      }
      return;
    }

    final now = DateTime.now();
    for (final id in currentIds) {
      if (_knownInvoiceIds.add(id) && !_saleSeenAt.containsKey(id)) {
        _rememberSaleSeen(id, now);
      }
    }
  }

  static List<PaymentLogEntry> _saleEventsFor(
      int? invoiceId,
      double totalAmount,
      DateTime fallbackDate,
      ) {
    if (invoiceId == null) {
      return [PaymentLogEntry(amount: totalAmount, time: fallbackDate)];
    }
    final seenAt = _saleSeenAt[invoiceId] ?? CashBookSeenAtStore.saleAt(invoiceId);
    if (seenAt != null) {
      _saleSeenAt[invoiceId] = seenAt;
      return [PaymentLogEntry(amount: totalAmount, time: seenAt)];
    }
    if (CalendarDate.hasClockTime(fallbackDate)) {
      _rememberSaleSeen(invoiceId, fallbackDate);
      return [PaymentLogEntry(amount: totalAmount, time: fallbackDate)];
    }
    final stamped = DateTime.now();
    _rememberSaleSeen(invoiceId, stamped);
    return [PaymentLogEntry(amount: totalAmount, time: stamped)];
  }

  static List<CustomerPaymentRecord> _stampPaymentTimes(
    List<CustomerPaymentRecord> rows,
  ) {
    if (rows.isEmpty) return rows;

    if (!_paymentBaselineReady) {
      final ordered = [...rows]
        ..removeWhere((p) => p.id == null)
        ..sort((a, b) => (a.id ?? 0).compareTo(b.id ?? 0));
      final base = DateTime.now().subtract(Duration(seconds: ordered.length + 1));
      for (var i = 0; i < ordered.length; i++) {
        final payment = ordered[i];
        final id = payment.id!;
        if (_paymentSeenAt.containsKey(id)) continue;
        final apiTime = payment.dateTime;
        if (apiTime != null && CalendarDate.hasClockTime(apiTime)) {
          _rememberPaymentSeen(id, apiTime);
        } else {
          _rememberPaymentSeen(id, base.add(Duration(seconds: i + 1)));
        }
      }
      _paymentBaselineReady = true;
    }

    final now = DateTime.now();
    return [
      for (final payment in rows) _withPaymentSeenTime(payment, now),
    ];
  }

  static CustomerPaymentRecord _withPaymentSeenTime(
    CustomerPaymentRecord payment,
    DateTime now,
  ) {
    final id = payment.id;
    if (id == null) return payment;
    final seen = _paymentSeenAt[id] ?? CashBookSeenAtStore.paymentAt(id);
    if (seen == null) {
      _rememberPaymentSeen(id, now);
      return payment.copyWith(dateTime: now);
    }
    _paymentSeenAt[id] = seen;
    return payment.copyWith(dateTime: seen);
  }

  List<NetAmountRow> youGotInvoices = [];
  List<NetAmountRow> youGaveBills = [];
  List<CustomerPaymentRecord> payments = [];
  String? reportDate;

  AmountBookFilter filter = const AmountBookFilter();

  DateTime? _loadedAt;
  bool _fetchBusy = false;
  bool _enrichBusy = false;
  bool _prefetchBalancesBusy = false;

  bool get hasData =>
      youGotInvoices.isNotEmpty || payments.isNotEmpty;

  bool get _hasFreshData =>
      _loadedAt != null &&
          DateTime.now().difference(_loadedAt!) < _cacheTtl &&
          youGotInvoices.isNotEmpty;

  static bool get _hasFreshAdvanceCache =>
      _advanceCache != null &&
          _advanceCache!.isNotEmpty &&
          _advanceCachedAt != null &&
          DateTime.now().difference(_advanceCachedAt!) < _advanceTtl;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  static String _normName(String? name) => (name ?? '').trim().toLowerCase();

  static double? _preferAmount(double? current, double? next) {
    if (next == null) return current;
    if (current == null) return next;
    if (current == 0 && next != 0) return next;
    return current;
  }

  /// List/payment payloads often send `0` for unset advance/old — ignore those.
  static bool _isUnsetBalance(double? advance, double? oldBalance) {
    final advUnset = advance == null || advance == 0;
    final oldUnset = oldBalance == null || oldBalance == 0;
    return advUnset && oldUnset;
  }

  static void _ingestCustomerBalances(Iterable<InvoiceSummaryModel> invoices) {
    for (final inv in invoices) {
      final name = _normName(inv.displayCustomer);
      if (name.isEmpty) continue;
      if (InvoiceSummaryModel.isWalkInCustomerName(name)) continue;
      if (_isUnsetBalance(inv.advanceAmount, inv.oldBalance)) continue;
      // Weak list-API merge only fills gaps — never blocks a later overwrite.
      final existing = _balancesByCustomer[name];
      if (existing != null && existing.hasUseful && existing.isFresh) continue;
      _balancesByCustomer[name] = _CustomerBalance(
        advance: _preferAmount(existing?.advance, inv.advanceAmount),
        oldBalance: _preferAmount(existing?.oldBalance, inv.oldBalance),
        fetchedAt: existing?.fetchedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
      );
    }
  }

  /// Laravel payment list may carry per-customer `advance_amt` / `old_balance`.
  /// Confirmed vouchers usually send `0` — do not treat that as authoritative.
  static void _ingestBalancesFromPayments(
    Iterable<CustomerPaymentRecord> payments,
  ) {
    final newest = <String, CustomerPaymentRecord>{};
    for (final payment in payments) {
      final name = _normName(payment.customerName);
      if (name.isEmpty) continue;
      if (InvoiceSummaryModel.isWalkInCustomerName(name)) continue;
      if (_isUnsetBalance(payment.advanceAmount, payment.oldBalance)) continue;
      final prev = newest[name];
      if (prev == null || (payment.id ?? 0) >= (prev.id ?? 0)) {
        newest[name] = payment;
      }
    }
    for (final entry in newest.entries) {
      final payment = entry.value;
      final existing = _balancesByCustomer[entry.key];
      _balancesByCustomer[entry.key] = _CustomerBalance(
        advance: _preferAmount(existing?.advance, payment.advanceAmount),
        oldBalance: _preferAmount(existing?.oldBalance, payment.oldBalance),
        fetchedAt: DateTime.now(),
      );
    }
  }

  static List<NetAmountRow> _applyCustomerBalances(List<NetAmountRow> rows) {
    if (_balancesByCustomer.isEmpty) return rows;
    var changed = false;
    final out = rows.map((row) {
      final bal = _balancesByCustomer[_normName(row.customer)];
      if (bal == null || !bal.hasAny) return row;
      // Odoo / cached balances are source of truth (including website updates).
      final nextAdvance = bal.advance ?? row.advanceAmount;
      final nextOld = bal.oldBalance ?? row.oldBalance;
      if (nextAdvance == row.advanceAmount && nextOld == row.oldBalance) {
        return row;
      }
      changed = true;
      return row.copyWith(
        advanceAmount: nextAdvance,
        oldBalance: nextOld,
      );
    }).toList(growable: false);
    return changed ? out : rows;
  }

  /// Patch invoice residuals from partner.payment lines (website Balance).
  /// Fixes cases like R0053 still showing ₹90 after PAY/0352 cleared it to ₹0.
  /// Prefer the latest/lowest residual when multiple payments mention an invoice.
  static List<NetAmountRow> _applyPaymentInvoiceResiduals(
    List<NetAmountRow> rows,
    List<CustomerPaymentRecord> payments,
  ) {
    if (rows.isEmpty || payments.isEmpty) return rows;
    final byId = <int, double>{};
    final byNumber = <String, double>{};
    for (final payment in payments) {
      for (final inv in payment.invoices) {
        if (CustomerPaymentRecord.effectiveAllocation(inv, payment) <= 0.0001) {
          continue;
        }
        // Prefer remaining-after-pay; balance_due is pre-allocation and
        // must not replace a smaller live residual.
        final bal = inv.balanceAfter ?? inv.balance;
        if (bal == null) continue;
        if (inv.invoiceId != null) {
          final prev = byId[inv.invoiceId!];
          // Keep the smallest residual (most settled) when sources disagree.
          byId[inv.invoiceId!] =
              prev == null ? bal : (bal < prev ? bal : prev);
        }
        final no = inv.number.trim().toLowerCase();
        if (no.isNotEmpty) {
          final prev = byNumber[no];
          byNumber[no] = prev == null ? bal : (bal < prev ? bal : prev);
        }
      }
    }
    if (byId.isEmpty && byNumber.isEmpty) return rows;

    var changed = false;
    final out = rows.map((row) {
      double? next;
      if (row.id != null && byId.containsKey(row.id)) {
        next = byId[row.id!];
      } else {
        final no = row.displayNumber.trim().toLowerCase();
        if (byNumber.containsKey(no)) next = byNumber[no];
      }
      if (next == null ||
          (row.balance != null && (row.balance! - next).abs() < 0.0001)) {
        return row;
      }
      changed = true;
      return row.copyWith(balance: next);
    }).toList(growable: false);
    return changed ? out : rows;
  }

  /// Fill PAY rows that came without nested bills (needed for bill icon).
  static Future<List<CustomerPaymentRecord>> _enrichMissingPaymentInvoices(
    String webSid,
    List<CustomerPaymentRecord> payments,
  ) async {
    if (payments.isEmpty) return payments;
    final out = <CustomerPaymentRecord>[];
    var enriched = 0;
    for (final payment in payments) {
      if (payment.invoices.isNotEmpty ||
          payment.id == null ||
          enriched >= 25) {
        out.add(payment);
        continue;
      }
      try {
        final linked = await OdooRpcHelper.invoicesFromPartnerPayment(
          webSid,
          payment.id!,
          defaultPayAmount: payment.amount,
        );
        if (linked.isEmpty) {
          out.add(payment);
          continue;
        }
        enriched++;
        out.add(
          payment.copyWith(
            invoices: [
              for (final inv in linked)
                if ((inv.payAmount ?? 0) > 0.0001)
                  CustomerPaymentInvoice(
                    invoiceId: inv.moveId,
                    number: inv.number ?? '',
                    allocatedAmount: inv.payAmount ?? 0,
                    total: inv.total,
                    balance: inv.balance,
                    status: inv.status ?? '',
                    responsiblePerson: inv.responsiblePerson,
                    invoiceDate: inv.invoiceDate,
                  ),
            ],
          ),
        );
      } catch (_) {
        out.add(payment);
      }
    }
    return out;
  }

  /// Instant open from home-prefetch / payment-history cache.
  void hydrateFromSharedCache() {
    final cached = PaymentHistoryService.cachedInvoices;
    if (cached == null || cached.isEmpty) return;
    if (youGotInvoices.isNotEmpty) return;
    youGotInvoices = cached.map(NetAmountRow.fromInvoice).toList(growable: false);
    final cachedPays = CustomerPaymentListService.cached;
    _ingestBalancesFromPayments(cachedPays);
    payments = cachedPays;
    if (_advanceCache != null && _advanceCache!.isNotEmpty) {
      _ingestCustomerBalances(_advanceCache!);
    }
    youGotInvoices = _applyCustomerBalances(youGotInvoices);
    _loadedAt = PaymentHistoryService.cachedAt ?? DateTime.now();
    error = '';
    unawaited(_applyPersistedSeenTimes());
  }

  Future<void> _applyPersistedSeenTimes() async {
    await _ensureSeenAtHydrated();
    if (_disposed) return;
    payments = _stampPaymentTimes(payments);
    _trackNewlySeenInvoices(youGotInvoices);
    _safeNotify();
  }

  List<AmountBookCustomerSummary> get allCustomerSummaries =>
      AmountBookLedgerBuilder.buildCustomerSummaries(
        youGotRows: youGotInvoices,
        youGaveRows: youGaveBills,
        paymentEventsFor: _paymentEventsFor,
        saleEventsFor: _saleEventsFor,
        payments: payments,
      );

  List<AmountBookCustomerSummary> get customerSummaries =>
      AmountBookLedgerBuilder.buildCustomerSummaries(
        youGotRows: youGotInvoices,
        youGaveRows: youGaveBills,
        filter: filter,
        paymentEventsFor: _paymentEventsFor,
        saleEventsFor: _saleEventsFor,
        payments: payments,
      );

  double get allYouGot {
    var sum = 0.0;
    for (final s in allCustomerSummaries) {
      sum += s.youGotTotal ?? 0;
    }
    return sum;
  }

  /// YOU GAVE = bill/sales totals (same as filteredYouGave), not outstanding.
  double get allYouGave {
    var sum = 0.0;
    for (final s in allCustomerSummaries) {
      sum += s.youGaveTotal ?? 0;
    }
    return sum;
  }

  double get filteredYouGot {
    var sum = 0.0;
    for (final s in customerSummaries) {
      sum += s.youGotTotal ?? 0;
    }
    return sum;
  }

  double get filteredYouGave {
    var sum = 0.0;
    for (final s in customerSummaries) {
      sum += s.youGaveTotal ?? 0;
    }
    return sum;
  }

  /// Header card totals — respect active Cash Book filter like the website.
  double get summaryYouGot =>
      filter.isActive ? filteredYouGot : allYouGot;

  double get summaryYouGave =>
      filter.isActive ? filteredYouGave : allYouGave;

  double get filteredBalance {
    var sum = 0.0;
    for (final s in customerSummaries) {
      sum += s.lastBalance ?? 0;
    }
    return sum;
  }

  Future<void> fetch(
      BuildContext context, {
        bool forceRefresh = false,
        bool silent = false,
        /// Prefer a fast newest-page merge (website → app live sync).
        bool headOnly = false,
        DateTime? dateFrom,
        DateTime? dateTo,
      }) async {
    if (_disposed) return;

    if (dateFrom != null || dateTo != null) {
      filter = filter.copyWith(dateFrom: dateFrom, dateTo: dateTo);
    }

    hydrateFromSharedCache();

    if (forceRefresh) {
      // Keep sticky advance/old on screen; ensureBalances overwrites when ready.
      CustomerPaymentListService.clearCache();
    }

    // Already fresh — paint and skip network.
    if (!forceRefresh && !headOnly && _hasFreshData) {
      if (!silent) {
        loading = false;
        _safeNotify();
      }
      if (context.mounted) {
        final login = Provider.of<LoginViewmodel>(context, listen: false);
        unawaited(prefetchBalancesForLogin(login, refreshStale: true));
      }
      return;
    }

    // Have data but stale / head refresh — paint now, refresh quietly.
    if (youGotInvoices.isNotEmpty && silent) {
      _safeNotify();
    }

    if (_fetchBusy) return;
    _fetchBusy = true;

    if (!silent && youGotInvoices.isEmpty) {
      loading = true;
      error = '';
      _safeNotify();
    }

    try {
      final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
      if (loginModel.sessionId == null || loginModel.sessionId!.isEmpty) {
        throw Exception('Session expired');
      }
      final sessionId = loginModel.sessionId!;

      // Prefer head merge whenever a catalog already exists. Laravel
      // get_payment_history is today-only after save — a full replace wipes Cash Book.
      final useHead = headOnly ||
          youGotInvoices.isNotEmpty ||
          PaymentHistoryService.hasAnyCache;

      _paymentBatchTime = DateTime.now();

      // Start both at once — website edits show after one RTT, not two.
      final invoicesFuture = useHead
          ? PaymentHistoryService.refreshHead(sessionId: sessionId)
          : PaymentHistoryService.fetchInvoices(
              sessionId: sessionId,
              forceRefresh: forceRefresh,
            );
      final paymentsFuture = CustomerPaymentListService.fetch(
        sessionId: sessionId,
        forceRefresh: forceRefresh,
        headOnly: useHead && !forceRefresh,
      );

      final invoices = await invoicesFuture;
      List<CustomerPaymentRecord> paymentRows = payments;
      try {
        paymentRows = await paymentsFuture;
      } catch (e) {
        if (kDebugMode) {
          debugPrint('AmountBookViewModel payments: $e');
        }
      }

      if (_disposed) return;

      await _ensureSeenAtHydrated();
      if (_disposed) return;

      CustomerInvoiceViewModel.seedFromPaymentHistory();

      if (enableOdooRpc && !silent) {
        final webSid = await _webSession(loginModel);
        if (webSid != null && webSid.isNotEmpty) {
          paymentRows = await _enrichMissingPaymentInvoices(
            webSid,
            paymentRows,
          );
        }
      }

      // Fresh head already carries advance/old — avoid a second invoice list call.
      _ingestCustomerBalances(invoices);
      // Payment vouchers expose advance_amt / old_balance per customer.
      _ingestBalancesFromPayments(paymentRows);
      if (_advanceCache == null || _advanceCache!.isEmpty || forceRefresh) {
        _advanceCache = invoices;
        _advanceCachedAt = DateTime.now();
      }

      var rows = invoices.map(NetAmountRow.fromInvoice).toList(growable: false);
      rows = _applyCustomerBalances(rows);

      youGotInvoices = rows;
      _trackNewlySeenInvoices(youGotInvoices);
      youGaveBills = const [];
      payments = _stampPaymentTimes(paymentRows);
      youGotInvoices = _applyPaymentInvoiceResiduals(youGotInvoices, payments);
      reportDate = null;
      error = invoices.isEmpty && paymentRows.isEmpty
          ? 'No customer invoices found'
          : '';
      _loadedAt = DateTime.now();
      loading = false;
      _safeNotify();

      // Full/cold load only — live head polls already ingested balances above.
      if (!useHead || forceRefresh) {
        unawaited(_enrichAdvanceInBackground(sessionId));
      }
      unawaited(
        prefetchBalancesForLogin(
          loginModel,
          refreshStale: forceRefresh || !useHead,
        ),
      );
    } catch (e, s) {
      if (kDebugMode) debugPrint('AmountBookViewModel.fetch: $e\n$s');
      if (_disposed) return;
      if (!silent || youGotInvoices.isEmpty) {
        error = 'Network error. Please check your connection and try again.';
      }
      loading = false;
      _safeNotify();
    } finally {
      _fetchBusy = false;
    }
  }

  /// Load advance/old balance for one customer (e.g. opening ledger detail).
  ///
  /// Pass [force] to re-read even when a cached value exists (pull-to-refresh).
  /// Useful cached values stay on screen while a refresh runs (no zero flash).
  Future<void> ensureBalancesForCustomer(
      BuildContext context,
      String customerName, {
        bool force = false,
      }) async {
    if (_disposed) return;
    final key = _normName(customerName);
    if (key.isEmpty) return;

    final existing = _balancesByCustomer[key];
    final hasMasterId = _masterCustomerIdByName[key] != null;

    // Keep sticky values on screen (avoid 0 flash).
    if (existing != null && existing.hasUseful) {
      final merged = _applyCustomerBalances(youGotInvoices);
      if (!identical(merged, youGotInvoices)) {
        youGotInvoices = merged;
        _safeNotify();
      }
    }

    // Skip network only when fresh AND we cannot fast-hit the masters form.
    // With a cached customer id, always re-read the form so Advance live-updates
    // the same way Old Balance does.
    if (!force &&
        !hasMasterId &&
        existing != null &&
        existing.hasUseful &&
        existing.isFresh) {
      return;
    }

    final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
    final flutterSid = loginModel.sessionId;
    if (flutterSid == null || flutterSid.isEmpty) return;

    try {
      // Never let weak invoice/payment zeros block a masters form re-read.
      // Masters form has Advance + Old Balance (live + force).
      final fromLaravel = await _resolveLaravelCustomerBalances(
        loginModel,
        customerName: customerName,
        key: key,
        allowWebsiteScrape: true,
        listOnly: false,
      );
      if (_disposed) return;
      if (fromLaravel != null &&
          (fromLaravel.advance != null || fromLaravel.oldBalance != null)) {
        final prev = _balancesByCustomer[key];
        // Trust masters form as a whole (null advance → 0) so live Advance
        // updates replace sticky values instead of keeping a stale amount.
        final fromForm = fromLaravel.advance != null ||
            fromLaravel.oldBalance != null;
        final adv = fromForm
            ? (fromLaravel.advance ?? 0)
            : prev?.advance;
        final old = fromLaravel.oldBalance ?? prev?.oldBalance;
        _storeBalance(key, adv, old, overwrite: true);
        youGotInvoices = _applyCustomerBalances(youGotInvoices);
        _safeNotify();
        if (kDebugMode) {
          debugPrint(
            'cash book balances $customerName '
            'advance=$adv old=$old'
            '${force ? ' (forced)' : ' (live)'}',
          );
        }
        if (!enableOdooRpc) return;
      } else if (!enableOdooRpc) {
        return;
      }

      final webSid = await _webSession(loginModel);
      if (webSid == null || webSid.isEmpty) return;

      // Prefer newest move id only — one fast read, no fields_get.
      final moveIds = youGotInvoices
          .where((r) => _normName(r.customer) == key && r.id != null)
          .map((r) => r.id!)
          .toList(growable: false);
      final newest = moveIds.isEmpty
          ? const <int>[]
          : <int>[moveIds.reduce((a, b) => a > b ? a : b)];

      var fromOdoo = await OdooRpcHelper.readCustomerFormBalances(
        webSid,
        moveIds: newest,
        customerName: customerName,
      );

      if (fromOdoo == null) {
        OdooRpcHelper.invalidateWebSession();
        final retrySid = await _webSession(loginModel, force: true);
        if (retrySid != null && retrySid.isNotEmpty) {
          fromOdoo = await OdooRpcHelper.readCustomerFormBalances(
            retrySid,
            moveIds: newest,
            customerName: customerName,
          );
        }
      }

      if (_disposed) return;
      if (fromOdoo != null &&
          (fromOdoo.advance != null || fromOdoo.oldBalance != null)) {
        _storeBalance(
          key,
          fromOdoo.advance,
          fromOdoo.oldBalance,
          overwrite: true,
        );
        youGotInvoices = _applyCustomerBalances(youGotInvoices);
        _safeNotify();
        if (kDebugMode) {
          debugPrint(
            'cash book balances $customerName '
                'advance=${fromOdoo.advance} old=${fromOdoo.oldBalance}'
                '${force ? ' (forced)' : ''}',
          );
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('cash book ensureBalancesForCustomer($customerName): $e');
      }
    }
  }

  int? _newestInvoiceIdForCustomer(String key) {
    int? newest;
    for (final row in youGotInvoices) {
      if (_normName(row.customer) != key || row.id == null) continue;
      if (newest == null || row.id! > newest) newest = row.id;
    }
    if (newest != null) return newest;
    final cached = PaymentHistoryService.cachedInvoices;
    if (cached == null) return null;
    for (final inv in cached) {
      if (_normName(inv.displayCustomer) != key || inv.id == null) continue;
      if (newest == null || inv.id! > newest) newest = inv.id;
    }
    return newest;
  }

  Future<({double? advance, double? oldBalance})?>
      _resolveLaravelCustomerBalances(
    LoginViewmodel loginModel, {
    required String customerName,
    required String key,
    bool allowWebsiteScrape = true,
    bool listOnly = false,
  }) async {
    final flutterSid = (loginModel.sessionId ?? '').trim();
    if (flutterSid.isEmpty) return null;

    var email = (loginModel.loginEmail ?? '').trim();
    var pass = loginModel.loginPassword ?? '';
    if (email.isEmpty || pass.isEmpty) {
      final saved = await AuthSessionStore.load();
      email = (saved?.email ?? '').trim();
      pass = saved?.password ?? '';
    }

    // 1) Masters → Customers (website Old Balance / Advance source of truth).
    if (allowWebsiteScrape && email.isNotEmpty && pass.isNotEmpty) {
      final cachedId = _masterCustomerIdByName[key];
      final fromMaster =
          await FlutterCustomerInvoiceWebApi.fetchCustomerMasterBalances(
        customerName: customerName,
        email: email,
        password: pass,
        customerId: cachedId,
        apiToken: AuthSessionStore.currentApiToken,
        listOnly: listOnly,
      );
      if (fromMaster?.customerId != null && fromMaster!.customerId! > 0) {
        _masterCustomerIdByName[key] = fromMaster.customerId!;
      }
      if (fromMaster != null &&
          (fromMaster.advance != null || fromMaster.oldBalance != null)) {
        return (
          advance: fromMaster.advance,
          oldBalance: fromMaster.oldBalance,
        );
      }
      if (listOnly) return null;
    }

    final invoiceId = _newestInvoiceIdForCustomer(key);

    if (invoiceId != null && invoiceId > 0) {
      final fromDetail = await InvoiceDetailService.fetchCustomerBalances(
        sessionId: flutterSid,
        invoiceId: invoiceId,
      );
      if (fromDetail != null &&
          !_isUnsetBalance(fromDetail.advance, fromDetail.oldBalance)) {
        return fromDetail;
      }

      if (allowWebsiteScrape && email.isNotEmpty && pass.isNotEmpty) {
        final fromWeb =
            await FlutterCustomerInvoiceWebApi.fetchCustomerFormBalances(
          invoiceId: invoiceId,
          email: email,
          password: pass,
          apiToken: AuthSessionStore.currentApiToken,
        );
        if (fromWeb != null &&
            !_isUnsetBalance(fromWeb.advance, fromWeb.oldBalance)) {
          return fromWeb;
        }
      }
    }

    // Newest payment detail for this customer (form fields when present).
    CustomerPaymentRecord? newestPay;
    for (final p in payments) {
      if (_normName(p.customerName) != key) continue;
      if (newestPay == null || (p.id ?? 0) > (newestPay.id ?? 0)) {
        newestPay = p;
      }
    }
    final payId = newestPay?.id;
    if (payId != null && payId > 0) {
      final detailed = await FlutterCustomerPaymentApi.getPayment(
        sessionId: flutterSid,
        paymentId: payId,
      );
      if (detailed != null &&
          !_isUnsetBalance(detailed.advanceAmount, detailed.oldBalance)) {
        return (
          advance: detailed.advanceAmount,
          oldBalance: detailed.oldBalance,
        );
      }
    }

    return null;
  }

  /// Prefetch advance/old for list customers so detail opens instantly.
  ///
  /// When [refreshStale] is true, also re-reads customers whose cache TTL
  /// expired so website edits appear during live sync.
  Future<void> prefetchBalances(
      BuildContext context, {
        bool refreshStale = false,
      }) async {
    if (_disposed || _prefetchBalancesBusy) return;
    if (!context.mounted) return;
    final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
    await prefetchBalancesForLogin(loginModel, refreshStale: refreshStale);
  }

  /// Same as [prefetchBalances] but safe after the calling widget is disposed.
  Future<void> prefetchBalancesForLogin(
    LoginViewmodel loginModel, {
    bool refreshStale = false,
  }) async {
    if (_disposed || _prefetchBalancesBusy) return;
    // Weak payment-list fields (non-zero only).
    _ingestBalancesFromPayments(payments);
    if (_balancesByCustomer.isNotEmpty) {
      final merged = _applyCustomerBalances(youGotInvoices);
      if (!identical(merged, youGotInvoices) && !_disposed) {
        youGotInvoices = merged;
        _safeNotify();
      }
    }

    final missing = _customersNeedingBalances(includeStale: refreshStale);
    if (missing.isEmpty) return;
    if (loginModel.sessionId == null || loginModel.sessionId!.isEmpty) return;

    _prefetchBalancesBusy = true;
    try {
      if (!enableOdooRpc) {
        // Masters/customers scrape for a few missing (Old Balance source).
        var changed = false;
        var n = 0;
        for (final key in missing) {
          if (_disposed || n >= 6) break;
          n++;
          var displayName = key;
          for (final row in youGotInvoices) {
            if (_normName(row.customer) == key) {
              displayName = (row.customer ?? key).trim();
              break;
            }
          }
          final hit = await _resolveLaravelCustomerBalances(
            loginModel,
            customerName: displayName,
            key: key,
            allowWebsiteScrape: true,
            listOnly: false,
          );
          if (hit == null) continue;
          if (hit.advance == null && hit.oldBalance == null) continue;
          _storeBalance(key, hit.advance, hit.oldBalance, overwrite: true);
          changed = true;
        }
        if (changed && !_disposed) {
          youGotInvoices = _applyCustomerBalances(youGotInvoices);
          _safeNotify();
        }
        return;
      }

      final webSid = await _webSession(loginModel);
      if (webSid == null || webSid.isEmpty) return;

      // Newest invoice id per customer that still needs balances.
      final newestByCustomer = <String, int>{};
      for (final row in youGotInvoices) {
        final key = _normName(row.customer);
        if (key.isEmpty || !missing.contains(key) || row.id == null) continue;
        final prev = newestByCustomer[key];
        if (prev == null || row.id! > prev) {
          newestByCustomer[key] = row.id!;
        }
      }
      if (newestByCustomer.isEmpty) return;

      final idToCustomer = <int, String>{
        for (final e in newestByCustomer.entries) e.value: e.key,
      };
      final batch = await OdooRpcHelper.readMoveBalancesBatch(
        webSid,
        idToCustomer.keys.toList(growable: false),
      );
      if (batch.isEmpty || _disposed) return;

      var changed = false;
      for (final entry in batch.entries) {
        final key = idToCustomer[entry.key];
        if (key == null) continue;
        if (entry.value.advance == null && entry.value.oldBalance == null) {
          continue;
        }
        _storeBalance(
          key,
          entry.value.advance,
          entry.value.oldBalance,
          overwrite: true,
        );
        changed = true;
      }
      if (changed && !_disposed) {
        youGotInvoices = _applyCustomerBalances(youGotInvoices);
        _safeNotify();
        if (kDebugMode) {
          debugPrint(
            'cash book prefetch balances hit=${batch.length} '
            'customers=${newestByCustomer.length}'
            '${refreshStale ? ' stale-refresh' : ''}',
          );
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('cash book prefetchBalances: $e');
    } finally {
      _prefetchBalancesBusy = false;
    }
  }

  /// Push balances from invoice/payment screens into Cash Book cache.
  static void rememberCustomerBalances(
    String customerName, {
    double? advance,
    double? oldBalance,
  }) {
    final key = _normName(customerName);
    if (key.isEmpty) return;
    if (advance == null && oldBalance == null) return;
    _balancesByCustomer[key] = _CustomerBalance(
      advance: advance,
      oldBalance: oldBalance,
      fetchedAt: DateTime.now(),
    );
  }

  void _storeBalance(
      String key,
      double? advance,
      double? oldBalance, {
        bool overwrite = false,
      }) {
    if (overwrite) {
      _balancesByCustomer[key] = _CustomerBalance(
        advance: advance,
        oldBalance: oldBalance,
        fetchedAt: DateTime.now(),
      );
      return;
    }
    final existing = _balancesByCustomer[key];
    _balancesByCustomer[key] = _CustomerBalance(
      advance: _preferAmount(existing?.advance, advance),
      oldBalance: _preferAmount(existing?.oldBalance, oldBalance),
      fetchedAt: existing?.fetchedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  Future<String?> _webSession(
      LoginViewmodel login, {
        bool force = false,
      }) async {
    final email = (login.loginEmail ?? '').trim();
    final pass = login.loginPassword ?? '';
    if (email.isEmpty || pass.isEmpty) return null;
    if (force) OdooRpcHelper.invalidateWebSession();
    return OdooRpcHelper.cachedWebSessionId(
      db: LoginViewmodel.dbName,
      login: email,
      password: pass,
    );
  }

  Set<String> _customersNeedingBalances({bool includeStale = false}) {
    final needed = <String>{};
    for (final row in youGotInvoices) {
      final key = _normName(row.customer);
      if (key.isEmpty) continue;
      final bal = _balancesByCustomer[key];
      if (bal == null || !bal.hasUseful) {
        needed.add(key);
      } else if (includeStale && !bal.isFresh) {
        needed.add(key);
      }
    }
    return needed;
  }

  Future<void> _enrichAdvanceInBackground(
      String sessionId, {
        bool force = false,
      }) async {
    if (_enrichBusy) return;
    _enrichBusy = true;
    try {
      if (_balancesByCustomer.isNotEmpty) {
        final merged = _applyCustomerBalances(youGotInvoices);
        if (!identical(merged, youGotInvoices) && !_disposed) {
          youGotInvoices = merged;
          _safeNotify();
        }
      }

      final missing = _customersNeedingBalances();
      if (!force && _hasFreshAdvanceCache && missing.isEmpty) {
        return;
      }

      // get_customer_invoice_list ignores offset (always same first page).
      final page = await InvoiceListPager.fetchPage(
        endpointPath: EndPoint.customerInvoiceList.path,
        sessionId: sessionId,
        limit: InvoiceListPager.pageSize,
        offset: 0,
      );
      if (page.invoices.isEmpty) return;

      _advanceCache = page.invoices;
      _advanceCachedAt = DateTime.now();
      _ingestCustomerBalances(page.invoices);

      if (!_disposed) {
        youGotInvoices = _applyCustomerBalances(youGotInvoices);
        _safeNotify();
      }
    } catch (e) {
      if (kDebugMode) debugPrint('cash book advance enrich: $e');
    } finally {
      _enrichBusy = false;
    }
  }

  void applyFilter(AmountBookFilter newFilter) {
    filter = newFilter;
    _safeNotify();
  }

  void clearFilter() {
    filter = const AmountBookFilter();
    _safeNotify();
  }

  List<AmountBookLedgerEntry> ledgerForCustomer(String customerName) {
    return AmountBookLedgerBuilder.entriesForCustomer(
      customerName: customerName,
      youGotRows: youGotInvoices,
      youGaveRows: youGaveBills,
      paymentEventsFor: _paymentEventsFor,
      saleEventsFor: _saleEventsFor,
      payments: payments,
    );
  }

  List<AmountBookInvoiceLine> invoicesForLedgerTap({
    required String customerName,
    required bool isYouGave,
    DateTime? date,
    required List<String> numbers,
    int? paymentId,
  }) {
    final wanted = numbers.where((n) => n.trim().isNotEmpty).toSet();
    final day = AmountBookLedgerBuilder.dayKey(date);
    for (final entry in ledgerForCustomer(customerName)) {
      if (paymentId != null && entry.paymentId == paymentId) {
        // Prefer nested customer bills (R0053…), not the PAY/xxxx itself.
        final bills = entry.invoices
            .where((l) => !_looksLikePaymentNumber(l.number))
            .toList(growable: false);
        if (bills.isNotEmpty) return bills;
        return entry.invoices;
      }
      if (entry.isYouGave != isYouGave) continue;
      if (AmountBookLedgerBuilder.dayKey(entry.sortDate) != day) continue;
      if (wanted.isEmpty) return entry.invoices;
      if (entry.invoices.any((line) => wanted.contains(line.number))) {
        return entry.invoices;
      }
    }
    return const [];
  }

  static bool _looksLikePaymentNumber(String number) {
    final n = number.trim().toUpperCase();
    return n.startsWith('PAY/') || n.startsWith('PMT/');
  }

  AmountBookInvoiceLine _paymentBillLine(
    CustomerPaymentRecord payment,
    CustomerPaymentInvoice inv,
  ) {
    NetAmountRow? match;
    if (inv.invoiceId != null) {
      for (final row in youGotInvoices) {
        if (row.id == inv.invoiceId) {
          match = row;
          break;
        }
      }
    }
    if (match == null) {
      final want = inv.number.trim().toLowerCase();
      if (want.isNotEmpty) {
        for (final row in youGotInvoices) {
          if (row.displayNumber.trim().toLowerCase() == want) {
            match = row;
            break;
          }
        }
      }
    }

    final pay = CustomerPaymentRecord.effectiveAllocation(inv, payment);
    final total = inv.total ?? match?.total;
    // Remaining after this payment — never reuse bill total as balance.
    double? balance = inv.balanceAfter ?? inv.balance;
    if (balance == null && inv.balanceDue != null) {
      balance = inv.balanceDue! - pay;
      if (balance < 0) balance = 0;
    }
    balance ??= match?.balance;
    if (balance != null &&
        total != null &&
        pay > 0.0001 &&
        (balance - total).abs() < 0.0001) {
      final remaining = (inv.balanceDue ?? total) - pay;
      balance = remaining < 0 ? 0 : remaining;
    }

    return AmountBookInvoiceLine(
      number: inv.number.trim().isNotEmpty
          ? inv.number
          : (match?.displayNumber ?? '—'),
      isYouGave: false,
      invoiceId: inv.invoiceId ?? match?.id,
      sortDate: CalendarDate.parseDateTime(inv.invoiceDate) ??
          (match == null
              ? null
              : AmountBookLedgerBuilder.parseRowDateTime(match)) ??
          payment.dateTime,
      total: total,
      balance: balance,
      youGotAmount: pay,
      status: inv.status.isNotEmpty
          ? inv.status
          : (match?.toInvoiceSummary().displayStatus ?? ''),
      responsiblePerson: inv.responsiblePerson ?? match?.billedBy,
      paymentMode: payment.paymentMode ?? match?.paymentMode,
    );
  }

  /// Lazy-load website invoice table for a payment (bill icon).
  Future<List<AmountBookInvoiceLine>> loadPaymentInvoiceLines(
    BuildContext context,
    int paymentId,
  ) async {
    try {
      CustomerPaymentRecord? payment;
      for (final p in payments) {
        if (p.id == paymentId) {
          payment = p;
          break;
        }
      }

      // List API often omits lines — pull detail so share/open bill have ids.
      if (payment == null || payment.invoices.isEmpty) {
        final login = Provider.of<LoginViewmodel>(context, listen: false);
        final sid = login.sessionId;
        if (sid != null && sid.isNotEmpty) {
          final detailed = await FlutterCustomerPaymentApi.getPayment(
            sessionId: sid,
            paymentId: paymentId,
          );
          if (_disposed) return const [];
          if (detailed != null && detailed.invoices.isNotEmpty) {
            final allocated =
                CustomerPaymentRecord.onlyAllocatedInvoices(detailed);
            payment = detailed.copyWith(
              invoices: allocated.isNotEmpty ? allocated : detailed.invoices,
            );
            final idx = payments.indexWhere((p) => p.id == paymentId);
            if (idx >= 0) {
              payments = [
                for (var i = 0; i < payments.length; i++)
                  if (i == idx)
                    payments[i].copyWith(invoices: payment.invoices)
                  else
                    payments[i],
              ];
            }
          }
        }
      }

      // Laravel payments already carry nested invoices when available.
      if (payment != null && payment.invoices.isNotEmpty) {
        final allocatedOnly = CustomerPaymentRecord.onlyAllocatedInvoices(
          payment,
        );
        // Prefer filtered lines; fall back only if helper kept none.
        final source =
            allocatedOnly.isNotEmpty ? allocatedOnly : payment.invoices;
        return [
          for (final inv in source)
            if (CustomerPaymentRecord.effectiveAllocation(inv, payment) >
                0.0001)
              _paymentBillLine(payment, inv),
        ];
      }

      if (!enableOdooRpc) return const [];

      final login = Provider.of<LoginViewmodel>(context, listen: false);
      final webSid = await _webSession(login);
      if (webSid == null || webSid.isEmpty) return const [];

      final linked = await OdooRpcHelper.invoicesFromPartnerPayment(
        webSid,
        paymentId,
        defaultPayAmount: payment?.amount,
      );
      if (linked.isEmpty) return const [];

      final lines = <AmountBookInvoiceLine>[];
      for (final inv in linked) {
        final number = (inv.number ?? '').trim();
        if (number.isEmpty && (inv.payAmount ?? 0) <= 0) continue;
        NetAmountRow? match;
        if (inv.moveId != null) {
          for (final row in youGotInvoices) {
            if (row.id == inv.moveId) {
              match = row;
              break;
            }
          }
        }
        lines.add(
          AmountBookInvoiceLine(
            number: number.isNotEmpty
                ? number
                : (match?.displayNumber ?? '—'),
            isYouGave: false,
            invoiceId: inv.moveId ?? match?.id,
            sortDate: CalendarDate.parseDateTime(inv.invoiceDate) ??
                (match == null
                    ? null
                    : AmountBookLedgerBuilder.parseRowDateTime(match)) ??
                payment?.dateTime,
            total: inv.total ?? match?.total,
            balance: inv.balance ?? match?.balance,
            youGotAmount: inv.payAmount ?? 0,
            status: inv.status ??
                match?.toInvoiceSummary().displayStatus ??
                '',
            responsiblePerson:
                inv.responsiblePerson ?? match?.billedBy,
            paymentMode: payment?.paymentMode ?? match?.paymentMode,
          ),
        );
      }

      // Only bills that affect YOU GOT (pay amount > 0).
      final paidLines = lines
          .where((l) => (l.youGotAmount ?? 0) > 0.0001)
          .toList(growable: false);

      // Refresh residuals into the ledger so "You will get" matches website.
      final patched = youGotInvoices.map((row) {
        if (row.id == null) return row;
        for (final inv in linked) {
          if (inv.moveId == row.id && inv.balance != null) {
            if (row.balance != inv.balance) {
              return row.copyWith(balance: inv.balance);
            }
          }
        }
        return row;
      }).toList(growable: false);
      if (!identical(patched, youGotInvoices)) {
        youGotInvoices = patched;
        _safeNotify();
      }
      return paidLines;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('loadPaymentInvoiceLines($paymentId): $e');
      }
      return const [];
    }
  }

  AmountBookCustomerFooter footerForCustomer(String customerName) {
    final base = AmountBookLedgerBuilder.footerForCustomer(
      customerName: customerName,
      invoiceRows: youGotInvoices,
      filter: filter,
      paymentEventsFor: _paymentEventsFor,
      saleEventsFor: _saleEventsFor,
      payments: payments,
    );
    final bal = _balancesByCustomer[_normName(customerName)];
    // Masters cache wins over invoice/payment zeros (avoids footer glitch).
    if (bal != null && bal.hasUseful) {
      return AmountBookCustomerFooter(
        advance: bal.advance ?? 0,
        oldBalance: bal.oldBalance ?? 0,
        balance: base.balance,
      );
    }
    if (bal == null || !bal.hasAny) return base;
    return AmountBookCustomerFooter(
      advance: bal.advance ?? base.advance,
      oldBalance: bal.oldBalance ?? base.oldBalance,
      balance: base.balance,
    );
  }

  /// Resolve a cash-book line to the customer invoice used by detail screen.
  InvoiceSummaryModel invoiceSummaryForLine(AmountBookInvoiceLine line) {
    NetAmountRow? match;
    final id = line.invoiceId;
    if (id != null && id > 0) {
      for (final row in youGotInvoices) {
        if (row.id == id) {
          match = row;
          break;
        }
      }
    }
    if (match == null) {
      final want = line.number.trim().toLowerCase();
      if (want.isNotEmpty && want != '—' && want != 'unknown') {
        for (final row in youGotInvoices) {
          if (row.displayNumber.trim().toLowerCase() == want) {
            match = row;
            break;
          }
        }
      }
    }
    // Prefer payment-line residual (balance_after) when present.
    final lineBalance = line.balance != null
        ? InvoiceSummaryModel(
            balance: line.balance,
            total: line.total,
          )
        : null;
    if (match != null) {
      final summary = match.toInvoiceSummary();
      return lineBalance == null ? summary : summary.mergedWith(lineBalance);
    }

    return InvoiceSummaryModel(
      id: line.invoiceId,
      invoiceNumber: line.number,
      invoiceDate: line.sortDate == null
          ? null
          : AmountBookLedgerBuilder.formatDisplayDate(line.sortDate),
      total: line.total,
      balance: line.balance,
      paymentMode: line.paymentMode,
      advanceAmount: line.advanceAmount,
      oldBalance: line.oldBalance,
      status: line.status,
      responsiblePerson: line.responsiblePerson,
    );
  }

  static String formatAmount(double? value) {
    if (value == null) return '—';
    final isWhole = value == value.roundToDouble();
    final number = isWhole
        ? value.toInt().toString()
        : value.toStringAsFixed(2);
    return '₹$number';
  }

  static String formatAmountPlain(double? value) {
    if (value == null) return '—';
    final isWhole = value == value.roundToDouble();
    return isWhole ? value.toInt().toString() : value.toStringAsFixed(2);
  }

  static String formatAmountFixed(double? value) {
    if (value == null) return '—';
    return '₹ ${value.toStringAsFixed(2)}';
  }
}
