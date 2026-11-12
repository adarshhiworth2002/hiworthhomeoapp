import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/services/endPoints.dart';
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

  static const _cacheTtl = Duration(seconds: 8);
  static const _advanceTtl = Duration(seconds: 45);
  /// How long advance/old balance may stay without re-reading Odoo.
  static const balanceTtl = Duration(seconds: 12);

  static List<InvoiceSummaryModel>? _advanceCache;
  static DateTime? _advanceCachedAt;
  static final Map<String, _CustomerBalance> _balancesByCustomer = {};

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
      // A new payment landed since we last looked — log it as its own
      // entry, timestamped with this fetch batch so two invoices paid
      // together (₹100 + ₹400 = ₹500) share one YOU GOT row.
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

  // Same problem, but for the bill itself: the website's invoice date has
  // no time component, so a bill saved just now still sorts wherever its
  // date puts it, not at the top. We track which invoice ids we already
  // knew about — once that baseline is established (first successful
  // load this session), any id that shows up afterwards for the first
  // time is a bill that was genuinely just saved, and gets stamped with
  // "now" instead of its own date.
  static bool _hasEstablishedInvoiceBaseline = false;
  static final Set<int> _knownInvoiceIds = {};
  static final Map<int, DateTime> _saleSeenAt = {};

  static void _trackNewlySeenInvoices(List<NetAmountRow> rows) {
    final currentIds = <int>{};
    for (final row in rows) {
      final id = row.id;
      if (id != null) currentIds.add(id);
    }

    if (!_hasEstablishedInvoiceBaseline) {
      // First successful load this session — these are bills that
      // already existed on the website, not ones just saved. Record
      // them as the known baseline without stamping a "just now" time.
      _knownInvoiceIds.addAll(currentIds);
      _hasEstablishedInvoiceBaseline = true;
      for (final row in rows) {
        final id = row.id;
        if (id == null) continue;
        final created = CalendarDate.parseDateTime(row.createdAt);
        if (created != null && CalendarDate.hasClockTime(created)) {
          _saleSeenAt[id] = created;
        }
      }
      return;
    }

    final now = DateTime.now();
    for (final id in currentIds) {
      if (_knownInvoiceIds.add(id)) {
        // Wasn't known before, and the baseline is already established —
        // this bill was genuinely just saved on the website.
        _saleSeenAt[id] = now;
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
    final seenAt = _saleSeenAt[invoiceId];
    if (seenAt != null) {
      return [PaymentLogEntry(amount: totalAmount, time: seenAt)];
    }
    if (CalendarDate.hasClockTime(fallbackDate)) {
      _saleSeenAt[invoiceId] = fallbackDate;
    }
    return [
      PaymentLogEntry(amount: totalAmount, time: fallbackDate),
    ];
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

  bool get hasData => youGotInvoices.isNotEmpty;

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

  static void _ingestCustomerBalances(Iterable<InvoiceSummaryModel> invoices) {
    for (final inv in invoices) {
      final name = _normName(inv.displayCustomer);
      if (name.isEmpty) continue;
      if (InvoiceSummaryModel.isWalkInCustomerName(name)) continue;
      if (inv.advanceAmount == null && inv.oldBalance == null) continue;
      // Weak list-API merge only fills gaps — never blocks a later Odoo overwrite.
      final existing = _balancesByCustomer[name];
      if (existing != null && existing.hasUseful && existing.isFresh) continue;
      _balancesByCustomer[name] = _CustomerBalance(
        advance: _preferAmount(existing?.advance, inv.advanceAmount),
        oldBalance: _preferAmount(existing?.oldBalance, inv.oldBalance),
        fetchedAt: existing?.fetchedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
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
        if (inv.balance == null) continue;
        final bal = inv.balance!;
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
          CustomerPaymentRecord(
            id: payment.id,
            name: payment.name,
            customerName: payment.customerName,
            amount: payment.amount,
            dateTime: payment.dateTime,
            paymentMode: payment.paymentMode,
            invoices: [
              for (final inv in linked)
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
    payments = CustomerPaymentListService.cached;
    _trackNewlySeenInvoices(youGotInvoices);
    if (_advanceCache != null && _advanceCache!.isNotEmpty) {
      _ingestCustomerBalances(_advanceCache!);
    }
    youGotInvoices = _applyCustomerBalances(youGotInvoices);
    _loadedAt = PaymentHistoryService.cachedAt ?? DateTime.now();
    error = '';
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

  double get allYouGave {
    var sum = 0.0;
    for (final s in allCustomerSummaries) {
      sum += s.lastBalance ?? 0;
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
      // Pull-to-refresh / force: drop sticky balances so website edits apply.
      _balancesByCustomer.clear();
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

      // Prefer fast head refresh when we already have a full list.
      final useHead = headOnly ||
          (silent && youGotInvoices.isNotEmpty && !forceRefresh) ||
          (silent && forceRefresh && youGotInvoices.isNotEmpty);

      final invoices = useHead
          ? await PaymentHistoryService.refreshHead(sessionId: sessionId)
          : await PaymentHistoryService.fetchInvoices(
        sessionId: sessionId,
        forceRefresh: forceRefresh && !PaymentHistoryService.hasAnyCache
            ? true
            : forceRefresh,
      );

      if (_disposed) return;

      CustomerInvoiceViewModel.seedFromPaymentHistory();

      _paymentBatchTime = DateTime.now();
      List<CustomerPaymentRecord> paymentRows = payments;
      String? webSid;
      try {
        webSid = await _webSession(loginModel);
        paymentRows = await CustomerPaymentListService.fetch(
          sessionId: sessionId,
          webSessionId: webSid,
          forceRefresh: forceRefresh,
          headOnly: useHead && !forceRefresh,
        );
        if (webSid != null && webSid.isNotEmpty) {
          paymentRows = await _enrichMissingPaymentInvoices(
            webSid,
            paymentRows,
          );
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('AmountBookViewModel payments: $e');
        }
      }

      var rows = invoices.map(NetAmountRow.fromInvoice).toList(growable: false);
      if (_advanceCache != null && _advanceCache!.isNotEmpty) {
        _ingestCustomerBalances(_advanceCache!);
      }
      rows = _applyCustomerBalances(rows);

      youGotInvoices = rows;
      _trackNewlySeenInvoices(youGotInvoices);
      youGaveBills = const [];
      payments = paymentRows;
      youGotInvoices = _applyPaymentInvoiceResiduals(youGotInvoices, payments);
      reportDate = null;
      error = invoices.isEmpty ? 'No customer invoices found' : '';
      _loadedAt = DateTime.now();
      loading = false;
      _safeNotify();

      // Warm / refresh advance/old so website edits show up on live sync.
      // Use login captured before awaits — page context may be deactivated.
      unawaited(
        prefetchBalancesForLogin(loginModel, refreshStale: true),
      );

      // List API does not reliably carry advance/old; enrich only on cold
      // loads (not every head refresh) so Cash Book stays responsive.
      if (!useHead) {
        unawaited(_enrichAdvanceInBackground(sessionId));
      }
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
  /// Pass [force] to re-read Odoo even when a cached value exists (live sync /
  /// pull-to-refresh after website edits).
  Future<void> ensureBalancesForCustomer(
      BuildContext context,
      String customerName, {
        bool force = false,
      }) async {
    if (_disposed) return;
    final key = _normName(customerName);
    if (key.isEmpty) return;

    final existing = _balancesByCustomer[key];
    if (!force &&
        existing != null &&
        existing.hasUseful &&
        existing.isFresh) {
      final merged = _applyCustomerBalances(youGotInvoices);
      if (!identical(merged, youGotInvoices)) {
        youGotInvoices = merged;
        _safeNotify();
      }
      return;
    }

    final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
    final flutterSid = loginModel.sessionId;
    if (flutterSid == null || flutterSid.isEmpty) return;

    try {
      final webSid = await _webSession(loginModel);
      if (webSid == null || webSid.isEmpty) {
        await _enrichAdvanceInBackground(flutterSid);
        return;
      }

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
        return;
      }

      await _enrichAdvanceInBackground(flutterSid);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('cash book ensureBalancesForCustomer($customerName): $e');
      }
    }
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
    final missing = _customersNeedingBalances(includeStale: refreshStale);
    if (missing.isEmpty) return;

    if (loginModel.sessionId == null || loginModel.sessionId!.isEmpty) return;

    _prefetchBalancesBusy = true;
    try {
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

  /// Lazy-load website invoice table for a payment (bill icon).
  Future<List<AmountBookInvoiceLine>> loadPaymentInvoiceLines(
    BuildContext context,
    int paymentId,
  ) async {
    try {
      final login = Provider.of<LoginViewmodel>(context, listen: false);
      final webSid = await _webSession(login);
      if (webSid == null || webSid.isEmpty) return const [];

      CustomerPaymentRecord? payment;
      for (final p in payments) {
        if (p.id == paymentId) {
          payment = p;
          break;
        }
      }

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
    if (match != null) return match.toInvoiceSummary();

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
