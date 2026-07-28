import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/services/WebApi/web_api_impl.dart';
import '../features/services/api_request_helper.dart';
import '../features/services/api_response_helper.dart';
import '../features/services/endPoints.dart';
import '../features/services/odoo_rpc_helper.dart';
import '../models/invoice_summary_model.dart';
import 'login_viewmodel.dart';

class CustomerInvoiceViewModel extends ChangeNotifier {
  bool loading = false;
  String error = '';

  /// UI filter: `all` | `draft` | `open` | `paid` (website-aligned).
  String selectedState = 'all';
  List<InvoiceSummaryModel> items = [];

  List<InvoiceSummaryModel> _catalog = [];
  DateTime? _catalogLoadedAt;
  static const _catalogTtl = Duration(seconds: 60);

  static List<InvoiceSummaryModel> _sharedCatalog = [];
  static DateTime? _sharedCatalogLoadedAt;

  /// Warm the catalog from the home screen so the list opens instantly.
  static Future<void> prefetchCatalog(
    BuildContext context, {
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh &&
        _isCacheFresh(_sharedCatalogLoadedAt, _sharedCatalog)) {
      return;
    }

    try {
      final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
      if (loginModel.sessionId == null || loginModel.sessionId!.isEmpty) {
        return;
      }

      final catalog = await _loadCatalogFromApi(
        sessionId: loginModel.sessionId!,
        login: loginModel.loginEmail,
        password: loginModel.loginPassword,
        db: LoginViewmodel.dbName,
      );
      _sharedCatalog = catalog;
      _sharedCatalogLoadedAt = DateTime.now();
    } catch (e, s) {
      if (kDebugMode) debugPrint('Customer invoice prefetch: $e\n$s');
    }
  }

  static void clearGlobalCache() {
    _sharedCatalog = [];
    _sharedCatalogLoadedAt = null;
  }

  Future<void> fetch(
    BuildContext context, {
    String? state,
    bool forceRefresh = false,
    bool silent = false,
  }) async {
    if (state != null) selectedState = state;

    if (forceRefresh) {
      clearGlobalCache();
      _catalog = [];
      _catalogLoadedAt = null;
    } else if (_isCacheFresh(_catalogLoadedAt, _catalog)) {
      items = _filterCatalog(selectedState);
      error = '';
      notifyListeners();
      return;
    } else if (_isCacheFresh(_sharedCatalogLoadedAt, _sharedCatalog)) {
      _catalog = List<InvoiceSummaryModel>.from(_sharedCatalog);
      _catalogLoadedAt = _sharedCatalogLoadedAt;
      items = _filterCatalog(selectedState);
      error = '';
      notifyListeners();
      return;
    }

    try {
      if (!silent) {
        loading = true;
        error = '';
        if (_catalog.isEmpty) {
          items = [];
        }
        notifyListeners();
      }

      final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
      if (loginModel.sessionId == null || loginModel.sessionId!.isEmpty) {
        error = 'Session expired. Please log in again.';
        return;
      }

      _catalog = await _loadCatalogFromApi(
        sessionId: loginModel.sessionId!,
        login: loginModel.loginEmail,
        password: loginModel.loginPassword,
        db: LoginViewmodel.dbName,
      );
      _catalogLoadedAt = DateTime.now();
      _sharedCatalog = List<InvoiceSummaryModel>.from(_catalog);
      _sharedCatalogLoadedAt = _catalogLoadedAt;
      items = _filterCatalog(selectedState);
      error = '';
    } catch (e, s) {
      if (kDebugMode) debugPrint('$e\n$s');
      error = 'Network error. Please check your connection and try again.';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  static bool _isCacheFresh(
    DateTime? loadedAt,
    List<InvoiceSummaryModel> catalog,
  ) {
    return catalog.isNotEmpty &&
        loadedAt != null &&
        DateTime.now().difference(loadedAt) < _catalogTtl;
  }

  static Future<List<InvoiceSummaryModel>> _loadCatalogFromApi({
    required String sessionId,
    String? login,
    String? password,
    String db = 'HOMEO_JULY',
  }) async {
    final webApi = WebApiImpl();

    // Fetch draft / posted / paid buckets in parallel (was 3 sequential calls).
    final batches = await Future.wait([
      _fetchApiState(webApi, sessionId, 'draft'),
      _fetchApiState(webApi, sessionId, 'posted'),
      _fetchApiState(webApi, sessionId, 'paid'),
    ]);

    for (final batch in batches) {
      if (batch.error != null) {
        throw StateError(batch.error!);
      }
    }

    var merged = _mergeBatches(batches);

    // Flutter draft API often returns empty for pharmacy drafts (name='/').
    // Always supplement from Odoo when Flutter returned few/no drafts.
    final apiDrafts =
        merged.where((e) => e.sectionKey == 'draft').length;
    if (apiDrafts < 5) {
      try {
        var odooSid = sessionId;
        final email = (login ?? '').trim();
        final pass = password ?? '';
        if (email.isNotEmpty && pass.isNotEmpty) {
          final webSid = await OdooRpcHelper.cachedWebSessionId(
            db: db,
            login: email,
            password: pass,
          );
          if (webSid != null && webSid.isNotEmpty) odooSid = webSid;
        }
        final odooDrafts =
            await OdooRpcHelper.listDraftCustomerInvoices(odooSid);
        if (kDebugMode) {
          debugPrint(
            'invoice catalog: flutterDrafts=$apiDrafts '
            'odooDrafts=${odooDrafts.length}',
          );
        }
        if (odooDrafts.isNotEmpty) {
          merged = _mergeBatches([
            _InvoiceBatch(invoices: merged),
            _InvoiceBatch(invoices: odooDrafts),
          ]);
        }
      } catch (e) {
        if (kDebugMode) debugPrint('odoo draft supplement failed: $e');
      }
    }

    return merged;
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

  static Future<_InvoiceBatch> _fetchApiState(
    WebApiImpl webApi,
    String sessionId,
    String apiState,
  ) async {
    final response = await webApi.fetchInvoiceList(
      endpointPath: EndPoint.customerInvoiceList.path,
      userDetails: ApiRequestHelper.jsonRpcCall({
        'limit': 100,
        'state': apiState,
      }),
      sessionId: sessionId,
      logResponseBody: false,
    );

    if (response.statusCode != 200) {
      return _InvoiceBatch.error(
        'Unable to load customer invoices (HTTP ${response.statusCode})',
      );
    }

    final Map<String, dynamic> body = json.decode(response.body);
    if (body['result'] is Map &&
        (body['result'] as Map)['status'] == 'error') {
      return _InvoiceBatch.error(
        ApiResponseHelper.errorMessage(
          body,
          fallback: 'Failed to load customer invoices',
        ),
      );
    }

    return _InvoiceBatch(
      invoices: InvoiceSummaryModel.parseList(body),
    );
  }

  static List<InvoiceSummaryModel> _mergeBatches(List<_InvoiceBatch> batches) {
    final merged = <int, InvoiceSummaryModel>{};
    final withoutId = <InvoiceSummaryModel>[];

    for (final batch in batches) {
      for (final inv in batch.invoices) {
        final id = inv.id;
        if (id == null) {
          withoutId.add(inv);
          continue;
        }
        final existing = merged[id];
        if (existing == null ||
            _sectionPriority(inv) >= _sectionPriority(existing)) {
          merged[id] = inv;
        }
      }
    }

    final list = [...merged.values, ...withoutId];
    list.sort((a, b) {
      final da = a.invoiceDate ?? '';
      final db = b.invoiceDate ?? '';
      final byDate = db.compareTo(da);
      if (byDate != 0) return byDate;
      return b.displayNumber.compareTo(a.displayNumber);
    });
    return list;
  }

  static int _sectionPriority(InvoiceSummaryModel inv) {
    switch (inv.sectionKey) {
      case 'paid':
        return 3;
      case 'open':
        return 2;
      case 'draft':
        return 1;
      default:
        return 0;
    }
  }

  void clearCache() {
    _catalog = [];
    _catalogLoadedAt = null;
    clearGlobalCache();
  }
}

class _InvoiceBatch {
  const _InvoiceBatch({this.invoices = const [], this.error});

  factory _InvoiceBatch.error(String message) =>
      _InvoiceBatch(error: message);

  final List<InvoiceSummaryModel> invoices;
  final String? error;
}
