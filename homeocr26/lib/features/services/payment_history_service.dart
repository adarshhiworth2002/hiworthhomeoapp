import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../models/invoice_summary_model.dart';
import '../../models/net_amount_model.dart';
import '../services/WebApi/web_api_impl.dart';
import 'api_request_helper.dart';
import 'endPoints.dart';

/// Shared payment-history cache used by list screens, employee performance,
/// invoice detail enrichment, and net-amount row enrichment.
class PaymentHistoryService {
  const PaymentHistoryService._();

  static List<InvoiceSummaryModel>? _invoiceCache;
  static List<Map<String, dynamic>>? _rawCache;
  static DateTime? _cachedAt;
  static Future<List<InvoiceSummaryModel>>? _inFlight;
  static const _cacheTtl = Duration(seconds: 60);

  static bool get hasFreshCache =>
      _invoiceCache != null &&
      _cachedAt != null &&
      DateTime.now().difference(_cachedAt!) < _cacheTtl;

  static List<InvoiceSummaryModel>? get cachedInvoices => _invoiceCache;

  static Future<List<InvoiceSummaryModel>> fetchInvoices({
    required String sessionId,
    int limit = 500,
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && hasFreshCache) {
      return _invoiceCache!;
    }

    final pending = _inFlight;
    if (!forceRefresh && pending != null) {
      return pending;
    }

    final future = _fetchFromApi(sessionId: sessionId, limit: limit);
    _inFlight = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlight, future)) {
        _inFlight = null;
      }
    }
  }

  static Future<List<InvoiceSummaryModel>> _fetchFromApi({
    required String sessionId,
    required int limit,
  }) async {
    final webApi = WebApiImpl();
    final response = await webApi.fetchInvoiceList(
      endpointPath: EndPoint.paymentHistory.path,
      userDetails: ApiRequestHelper.jsonRpcCall({'limit': limit}),
      sessionId: sessionId,
      logResponseBody: false,
    );

    if (response.statusCode != 200) {
      return _invoiceCache ?? const [];
    }

    final body = json.decode(response.body);
    if (body is! Map) return _invoiceCache ?? const [];

    final map = Map<String, dynamic>.from(body);
    if (map['result'] is Map && (map['result'] as Map)['status'] == 'error') {
      return _invoiceCache ?? const [];
    }

    final items = InvoiceSummaryModel.parseList(map);
    _invoiceCache = items;
    _rawCache = NetAmountRow.extractRecordMaps(map);
    _cachedAt = DateTime.now();
    return items;
  }

  static Future<List<Map<String, dynamic>>> fetchRecordMaps({
    required String sessionId,
    int limit = 500,
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _rawCache != null && hasFreshCache) {
      return _rawCache!;
    }
    await fetchInvoices(
      sessionId: sessionId,
      limit: limit,
      forceRefresh: forceRefresh,
    );
    return _rawCache ?? const [];
  }

  /// Warm cache from the home screen so dependent tabs open instantly.
  static Future<void> prefetch(
    String sessionId, {
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && hasFreshCache) return;
    try {
      await fetchInvoices(
        sessionId: sessionId,
        limit: 200,
        forceRefresh: forceRefresh,
      );
    } catch (e, s) {
      if (kDebugMode) debugPrint('Payment history prefetch: $e\n$s');
    }
  }

  static void clearCache() {
    _invoiceCache = null;
    _rawCache = null;
    _cachedAt = null;
    _inFlight = null;
  }
}
