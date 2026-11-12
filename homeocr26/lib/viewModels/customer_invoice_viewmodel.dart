import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/services/invoice_b2b_index.dart';
import '../features/services/payment_book_service.dart';
import '../features/services/payment_history_service.dart';
import '../models/invoice_summary_model.dart';
import '../models/payment_book_model.dart';
import 'login_viewmodel.dart';

class CustomerInvoiceViewModel extends ChangeNotifier {
  CustomerInvoiceViewModel() {
    _hydrateFromCaches();
  }

  bool _disposed = false;
  bool loading = false;
  String error = '';

  /// UI filter: `all` | `draft` | `open` | `paid` | `cancel`.
  String selectedState = 'all';
  List<InvoiceSummaryModel> items = [];
  PaymentBookFilter listFilter = const PaymentBookFilter();

  List<InvoiceSummaryModel> _catalog = [];
  /// When Search is active, rows come from Payment Book (same API as that page).
  List<InvoiceSummaryModel>? _filterOverride;
  DateTime? _catalogLoadedAt;

  static List<InvoiceSummaryModel> _sharedCatalog = [];
  static DateTime? _sharedCatalogLoadedAt;
  static Future<List<InvoiceSummaryModel>>? _inFlight;

  /// Warm the catalog from the home screen so the list opens instantly.
  static Future<void> prefetchCatalog(
    BuildContext context, {
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _sharedCatalog.isNotEmpty) return;

    try {
      final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
      final sessionId = loginModel.sessionId;
      if (sessionId == null || sessionId.isEmpty) return;

      await PaymentHistoryService.prefetch(
        sessionId,
        forceRefresh: forceRefresh,
      );
      seedFromPaymentHistory();
    } catch (e, s) {
      if (kDebugMode) debugPrint('Customer invoice prefetch: $e\n$s');
    }
  }

  static void seedFromPaymentHistory() {
    final cached = PaymentHistoryService.cachedInvoices;
    if (cached == null || cached.isEmpty) return;
    _sharedCatalog =
        PaymentHistoryService.applyTrustedToList(List.from(cached));
    _sharedCatalogLoadedAt = DateTime.now();
    _mergePaymentBookIntoSharedCatalog();
  }

  /// Payment Book often has today's drafts before history cache catches up.
  static void _mergePaymentBookIntoSharedCatalog() {
    final book = PaymentBookService.cachedBook;
    if (book == null || book.invoices.isEmpty) return;
    final byId = <int, InvoiceSummaryModel>{};
    for (final inv in _sharedCatalog) {
      final id = inv.id;
      if (id != null && id > 0) byId[id] = inv;
    }
    var changed = false;
    for (final inv in book.invoices) {
      final id = inv.id;
      if (id == null || id <= 0) continue;
      final patched = PaymentHistoryService.withTrustedTotals(inv);
      final existing = byId[id];
      if (existing == null) {
        byId[id] = patched;
        changed = true;
      } else {
        final merged = PaymentHistoryService.withTrustedTotals(
          existing.mergedWith(patched),
        );
        if (!identical(merged, existing)) {
          byId[id] = merged;
          changed = true;
        }
      }
    }
    if (!changed && byId.length == _sharedCatalog.length) return;
    _sharedCatalog = byId.values.toList(growable: false);
    _sharedCatalogLoadedAt = DateTime.now();
  }

  /// Same Search path as Payment Book: fetch via `get_payment_book` /
  /// history fallback, then keep a client pass for invoice # / dates.
  Future<void> applyListFilter(
    BuildContext context,
    PaymentBookFilter filter, {
    bool forceRefresh = true,
  }) async {
    listFilter = filter;
    if (filter.isActive) {
      selectedState = 'all';
    }
    if (!filter.isActive) {
      await clearListFilter(context);
      return;
    }

    loading = true;
    error = '';
    _notify();

    try {
      final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
      final sessionId = loginModel.sessionId;
      if (sessionId == null || sessionId.isEmpty) {
        error = 'Session expired. Please log in again.';
        return;
      }
      if (!InvoiceB2bIndex.isReady) {
        await InvoiceB2bIndex.loadFromCredentials(
          db: LoginViewmodel.dbName,
          login: loginModel.loginEmail,
          password: loginModel.loginPassword,
        );
      }
      if (!context.mounted || _disposed) return;

      final book = await PaymentBookService.fetch(
        sessionId: sessionId,
        dateFrom: filter.dateFrom == null
            ? null
            : _formatApiDate(filter.dateFrom!),
        dateTo:
            filter.dateTo == null ? null : _formatApiDate(filter.dateTo!),
        customer: filter.hasCustomer ? filter.customerQuery.trim() : null,
        customerType: filter.customerTypeApiValue,
        paymentMode: filter.paymentModeApiValue,
        forceRefresh: forceRefresh,
      );
      if (_disposed) return;

      // Keep full catalog intact; override only the filtered view.
      _filterOverride = PaymentHistoryService.applyTrustedToList(
        book.invoices.where(filter.matches).toList(growable: false),
      );
      items = _filterCatalog(selectedState);
      error = '';
    } catch (e, s) {
      if (kDebugMode) debugPrint('CustomerInvoice applyListFilter: $e\n$s');
      error = 'Network error. Please check your connection and try again.';
    } finally {
      loading = false;
      _notify();
    }
  }

  Future<void> clearListFilter(BuildContext context) async {
    listFilter = const PaymentBookFilter();
    _filterOverride = null;
    _hydrateFromCaches();
    items = _filterCatalog(selectedState);
    _notify();
    if (!context.mounted) return;
    unawaited(fetch(context, forceRefresh: true, silent: true));
  }

  static String _formatApiDate(DateTime date) {
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  /// Switch Draft/Open/Paid/… without a network round-trip.
  void setSelectedState(String state) {
    selectedState = state;
    items = _filterCatalog(selectedState);
    _notify();
  }

  List<InvoiceSummaryModel> get visibleItems {
    // Status chip on top of Payment Book Search results (or full catalog).
    return _filterCatalog(selectedState);
  }

  static Future<List<InvoiceSummaryModel>> fetchCatalog({
    required String sessionId,
    String? login,
    String? password,
    String db = 'HOMEO_JULY',
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _sharedCatalog.isNotEmpty) {
      return PaymentHistoryService.applyTrustedToList(
        List<InvoiceSummaryModel>.from(_sharedCatalog),
      );
    }
    final catalog = await _loadCatalogFromApi(
      sessionId: sessionId,
      login: login,
      password: password,
      db: db,
      forceRefresh: forceRefresh,
    );
    _sharedCatalog = PaymentHistoryService.applyTrustedToList(catalog);
    _sharedCatalogLoadedAt = DateTime.now();
    return List<InvoiceSummaryModel>.from(_sharedCatalog);
  }

  static void clearGlobalCache() {
    _sharedCatalog = [];
    _sharedCatalogLoadedAt = null;
  }

  /// Drop a discarded draft from shared + instance catalogs immediately.
  static void evictInvoice(int invoiceId) {
    if (invoiceId <= 0) return;
    _sharedCatalog =
        _sharedCatalog.where((i) => i.id != invoiceId).toList(growable: false);
    PaymentHistoryService.removeInvoice(invoiceId);
  }

  /// Patch / insert one invoice into the shared catalog (instant list update).
  static void upsertInvoice(InvoiceSummaryModel invoice) {
    final id = invoice.id;
    if (id == null || id <= 0) return;
    PaymentHistoryService.upsertInvoice(invoice);
    PaymentBookService.upsertInvoice(invoice);
    final patched = PaymentHistoryService.withTrustedTotals(invoice);
    final list = List<InvoiceSummaryModel>.from(_sharedCatalog);
    final idx = list.indexWhere((i) => i.id == id);
    if (idx >= 0) {
      list[idx] = PaymentHistoryService.withTrustedTotals(
        list[idx].mergedWith(patched),
      );
    } else {
      list.insert(0, patched);
    }
    _sharedCatalog = list;
    _sharedCatalogLoadedAt = DateTime.now();
  }

  void removeInvoiceLocally(int invoiceId) {
    if (invoiceId <= 0) return;
    evictInvoice(invoiceId);
    _catalog = _catalog.where((i) => i.id != invoiceId).toList(growable: false);
    items = _filterCatalog(selectedState);
    _notify();
  }

  void upsertInvoiceLocally(InvoiceSummaryModel invoice) {
    upsertInvoice(invoice);
    _hydrateFromCaches();
    _notify();
  }

  bool _hydrateFromCaches() {
    if (_sharedCatalog.isEmpty) seedFromPaymentHistory();
    if (_sharedCatalog.isEmpty) {
      final history = PaymentHistoryService.cachedInvoices;
      if (history == null || history.isEmpty) {
        // Still try Payment Book drafts (today) when history is cold.
        _mergePaymentBookIntoSharedCatalog();
        if (_sharedCatalog.isEmpty) return false;
      } else {
        _sharedCatalog =
            PaymentHistoryService.applyTrustedToList(List.from(history));
        _sharedCatalogLoadedAt = DateTime.now();
      }
    } else {
      _sharedCatalog =
          PaymentHistoryService.applyTrustedToList(_sharedCatalog);
    }
    _mergePaymentBookIntoSharedCatalog();
    _catalog = List<InvoiceSummaryModel>.from(_sharedCatalog);
    _catalogLoadedAt = _sharedCatalogLoadedAt;
    items = _filterCatalog(selectedState);
    loading = false;
    error = '';
    return _catalog.isNotEmpty;
  }

  Future<void> fetch(
    BuildContext context, {
    String? state,
    bool forceRefresh = false,
    bool silent = false,
  }) async {
    if (state != null) selectedState = state;

    // Keep Payment Book Search results in sync on live refresh.
    if (listFilter.isActive && forceRefresh) {
      await applyListFilter(context, listFilter, forceRefresh: true);
      return;
    }

    final shown = _hydrateFromCaches();
    if (shown) _notify();

    try {
      final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
      if (!InvoiceB2bIndex.isReady) {
        await InvoiceB2bIndex.loadFromCredentials(
          db: LoginViewmodel.dbName,
          login: loginModel.loginEmail,
          password: loginModel.loginPassword,
        );
      }
      if (!context.mounted) return;
      if (shown && !forceRefresh) {
        _notify();
        return;
      }

      if (!silent && !shown) {
        loading = true;
        error = '';
        _notify();
      }

      if (loginModel.sessionId == null || loginModel.sessionId!.isEmpty) {
        error = 'Session expired. Please log in again.';
        return;
      }

      _catalog = PaymentHistoryService.applyTrustedToList(
        await _loadCatalogFromApi(
          sessionId: loginModel.sessionId!,
          login: loginModel.loginEmail,
          password: loginModel.loginPassword,
          db: LoginViewmodel.dbName,
          forceRefresh: forceRefresh,
        ),
      );
      _catalogLoadedAt = DateTime.now();
      _sharedCatalog = List<InvoiceSummaryModel>.from(_catalog);
      _sharedCatalogLoadedAt = _catalogLoadedAt;
      items = _filterCatalog(selectedState);
      error = '';
    } catch (e, s) {
      if (kDebugMode) debugPrint('$e\n$s');
      if (!shown) {
        error = 'Network error. Please check your connection and try again.';
      }
    } finally {
      loading = false;
      _notify();
    }
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  static Future<List<InvoiceSummaryModel>> _loadCatalogFromApi({
    required String sessionId,
    String? login,
    String? password,
    String db = 'HOMEO_JULY',
    bool forceRefresh = false,
  }) async {
    final pending = _inFlight;
    if (!forceRefresh && pending != null) return pending;

    final future = () async {
      // After save/discard: refresh only the newest page instead of paging
      // hundreds of invoices (was causing 60s+ waits on the list screen).
      if (forceRefresh && PaymentHistoryService.hasAnyCache) {
        final head = await PaymentHistoryService.refreshHead(
          sessionId: sessionId,
        );
        seedFromPaymentHistory();
        return head;
      }
      final merged = await PaymentHistoryService.fetchInvoices(
        sessionId: sessionId,
        forceRefresh: forceRefresh,
      );
      seedFromPaymentHistory();
      return merged;
    }();

    _inFlight = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlight, future)) {
        _inFlight = null;
      }
    }
  }

  List<InvoiceSummaryModel> _filterCatalog(String state) {
    final source = _filterOverride ?? _catalog;
    final catalog = PaymentHistoryService.applyTrustedToList(source);
    var list = state == 'all'
        ? List<InvoiceSummaryModel>.from(catalog)
        : catalog.where((inv) => inv.sectionKey == state).toList();

    list.sort((a, b) {
      final da = a.invoiceDate ?? '';
      final db = b.invoiceDate ?? '';
      final byDate = db.compareTo(da);
      if (byDate != 0) return byDate;
      return b.displayNumber.compareTo(a.displayNumber);
    });
    return list;
  }

  void clearCache() {
    _catalog = [];
    _catalogLoadedAt = null;
    clearGlobalCache();
  }
}
