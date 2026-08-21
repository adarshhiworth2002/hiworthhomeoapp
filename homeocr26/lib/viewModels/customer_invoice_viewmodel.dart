import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/services/invoice_b2b_index.dart';
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
    _sharedCatalog = List<InvoiceSummaryModel>.from(cached);
    _sharedCatalogLoadedAt = DateTime.now();
  }

  void applyListFilter(PaymentBookFilter filter) {
    listFilter = filter;
    _notify();
  }

  void clearListFilter() {
    listFilter = const PaymentBookFilter();
    _notify();
  }

  List<InvoiceSummaryModel> get visibleItems {
    return items.where(listFilter.matches).toList(growable: false);
  }

  static Future<List<InvoiceSummaryModel>> fetchCatalog({
    required String sessionId,
    String? login,
    String? password,
    String db = 'HOMEO_JULY',
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _sharedCatalog.isNotEmpty) {
      return List<InvoiceSummaryModel>.from(_sharedCatalog);
    }
    final catalog = await _loadCatalogFromApi(
      sessionId: sessionId,
      login: login,
      password: password,
      db: db,
      forceRefresh: forceRefresh,
    );
    _sharedCatalog = catalog;
    _sharedCatalogLoadedAt = DateTime.now();
    return catalog;
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

  void removeInvoiceLocally(int invoiceId) {
    if (invoiceId <= 0) return;
    evictInvoice(invoiceId);
    _catalog = _catalog.where((i) => i.id != invoiceId).toList(growable: false);
    items = _filterCatalog(selectedState);
    _notify();
  }

  bool _hydrateFromCaches() {
    if (_sharedCatalog.isEmpty) seedFromPaymentHistory();
    if (_sharedCatalog.isEmpty) {
      final history = PaymentHistoryService.cachedInvoices;
      if (history == null || history.isEmpty) return false;
      _sharedCatalog = List<InvoiceSummaryModel>.from(history);
      _sharedCatalogLoadedAt = DateTime.now();
    }
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

      _catalog = await _loadCatalogFromApi(
        sessionId: loginModel.sessionId!,
        login: loginModel.loginEmail,
        password: loginModel.loginPassword,
        db: LoginViewmodel.dbName,
        forceRefresh: forceRefresh,
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
    var list = state == 'all'
        ? List<InvoiceSummaryModel>.from(_catalog)
        : _catalog.where((inv) => inv.sectionKey == state).toList();

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
