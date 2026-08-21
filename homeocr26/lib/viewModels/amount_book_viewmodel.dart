import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/services/endPoints.dart';
import '../features/services/invoice_list_pager.dart';
import '../features/services/odoo_rpc_helper.dart';
import '../features/services/payment_history_service.dart';
import '../models/amount_book_model.dart';
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

  static const _cacheTtl = Duration(seconds: 20);
  static const _advanceTtl = Duration(seconds: 45);
  /// How long advance/old balance may stay without re-reading Odoo.
  static const balanceTtl = Duration(seconds: 12);

  static List<InvoiceSummaryModel>? _advanceCache;
  static DateTime? _advanceCachedAt;
  static final Map<String, _CustomerBalance> _balancesByCustomer = {};

  bool loading = false;
  String error = '';
  bool _disposed = false;

  List<NetAmountRow> youGotInvoices = [];
  List<NetAmountRow> youGaveBills = [];
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
      final name = _normName(inv.displayCustomer ?? inv.customer);
      if (name.isEmpty) continue;
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

  /// Instant open from home-prefetch / payment-history cache.
  void hydrateFromSharedCache() {
    final cached = PaymentHistoryService.cachedInvoices;
    if (cached == null || cached.isEmpty) return;
    if (youGotInvoices.isNotEmpty) return;
    youGotInvoices = cached.map(NetAmountRow.fromInvoice).toList(growable: false);
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
      );

  List<AmountBookCustomerSummary> get customerSummaries =>
      AmountBookLedgerBuilder.buildCustomerSummaries(
        youGotRows: youGotInvoices,
        youGaveRows: youGaveBills,
        filter: filter,
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
    }

    // Already fresh — paint and skip network.
    if (!forceRefresh && !headOnly && _hasFreshData) {
      if (!silent) {
        loading = false;
        _safeNotify();
      }
      unawaited(prefetchBalances(context, refreshStale: true));
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

      var rows = invoices.map(NetAmountRow.fromInvoice).toList(growable: false);
      if (_advanceCache != null && _advanceCache!.isNotEmpty) {
        _ingestCustomerBalances(_advanceCache!);
      }
      rows = _applyCustomerBalances(rows);

      youGotInvoices = rows;
      youGaveBills = const [];
      reportDate = null;
      error = invoices.isEmpty ? 'No customer invoices found' : '';
      _loadedAt = DateTime.now();
      loading = false;
      _safeNotify();

      // Warm / refresh advance/old so website edits show up on live sync.
      unawaited(prefetchBalances(context, refreshStale: true));

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
    final missing = _customersNeedingBalances(includeStale: refreshStale);
    if (missing.isEmpty) return;

    final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
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
        // Always overwrite from Odoo (including changed non-zero amounts).
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
    );
  }

  List<AmountBookInvoiceLine> invoicesForLedgerTap({
    required String customerName,
    required bool isYouGave,
    DateTime? date,
    required List<String> numbers,
  }) {
    final wanted = numbers.where((n) => n.trim().isNotEmpty).toSet();
    final day = AmountBookLedgerBuilder.dayKey(date);
    for (final entry in ledgerForCustomer(customerName)) {
      if (entry.isYouGave != isYouGave) continue;
      if (AmountBookLedgerBuilder.dayKey(entry.sortDate) != day) continue;
      if (wanted.isEmpty) return entry.invoices;
      if (entry.invoices.any((line) => wanted.contains(line.number))) {
        return entry.invoices;
      }
    }
    return const [];
  }

  AmountBookCustomerFooter footerForCustomer(String customerName) {
    final base = AmountBookLedgerBuilder.footerForCustomer(
      customerName: customerName,
      invoiceRows: youGotInvoices,
      filter: filter,
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
