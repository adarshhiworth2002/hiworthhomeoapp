import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../models/customer_payment_model.dart';
import 'WebApi/web_api_impl.dart';
import 'api_request_helper.dart';
import 'endPoints.dart';
import 'invoice_list_pager.dart';

/// Shared cache for customer payments used by Cash Book YOU GOT rows.
/// Uses Laravel `api/flutter/get_customer_payment_list` only.
class CustomerPaymentListService {
  const CustomerPaymentListService._();

  static List<CustomerPaymentRecord>? _cache;
  static DateTime? _cachedAt;
  static Future<List<CustomerPaymentRecord>>? _inFlight;
  static const _cacheTtl = Duration(seconds: 12);

  static bool get hasFreshCache =>
      _cache != null &&
      _cachedAt != null &&
      DateTime.now().difference(_cachedAt!) < _cacheTtl;

  static List<CustomerPaymentRecord> get cached =>
      _cache ?? const <CustomerPaymentRecord>[];

  static Future<List<CustomerPaymentRecord>> fetch({
    required String sessionId,
    String? webSessionId,
    bool forceRefresh = false,
    bool headOnly = false,
  }) async {
    if (!forceRefresh && !headOnly && hasFreshCache) {
      return _cache!;
    }
    if (!forceRefresh &&
        !headOnly &&
        _cache != null &&
        _cache!.isNotEmpty) {
      return _cache!;
    }

    final pending = _inFlight;
    if (!forceRefresh && pending != null) return pending;

    final future = _fetchPreferred(
      flutterSessionId: sessionId,
      webSessionId: webSessionId,
      headOnly: headOnly && !forceRefresh,
    );
    _inFlight = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlight, future)) {
        _inFlight = null;
      }
    }
  }

  static Future<List<CustomerPaymentRecord>> _fetchPreferred({
    required String flutterSessionId,
    String? webSessionId,
    required bool headOnly,
  }) async {
    // Laravel / Flutter API only (no Odoo).
    try {
      final fromApi = headOnly
          ? await _refreshHead(flutterSessionId)
          : await _fetchAllFlutter(flutterSessionId);
      if (fromApi.isNotEmpty) {
        _cache = fromApi;
        _cachedAt = DateTime.now();
        return fromApi;
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('CustomerPaymentListService flutter api: $e');
      }
    }

    return _cache ?? const [];
  }

  static List<CustomerPaymentRecord> _mergeNewestFirst(
    List<CustomerPaymentRecord> head,
    List<CustomerPaymentRecord>? previous,
  ) {
    if (previous == null || previous.isEmpty) {
      final copy = [...head]..sort(_compareNewestFirst);
      return copy;
    }
    final byId = <int, CustomerPaymentRecord>{};
    final withoutId = <CustomerPaymentRecord>[];
    for (final payment in head) {
      final id = payment.id;
      if (id == null) {
        withoutId.add(payment);
      } else {
        byId[id] = payment;
      }
    }
    // Drop cancelled/missing ids that used to be in head.
    final headIds = byId.keys.toSet();
    for (final payment in previous) {
      final id = payment.id;
      if (id == null) {
        withoutId.add(payment);
        continue;
      }
      if (headIds.isNotEmpty && !byId.containsKey(id)) {
        // Keep older pages not in this head refresh.
        byId.putIfAbsent(id, () => payment);
      } else {
        byId.putIfAbsent(id, () => payment);
      }
    }
    // If a previous id is absent from a full (non-head) fetch, it was cancelled.
    // Head refresh already putIfAbsent above; full replace happens when previous=null.

    final merged = [...byId.values, ...withoutId];
    merged.sort(_compareNewestFirst);
    return merged;
  }

  static Future<List<CustomerPaymentRecord>> _fetchAllFlutter(
    String sessionId,
  ) async {
    final byId = <int, CustomerPaymentRecord>{};
    final withoutId = <CustomerPaymentRecord>[];
    var offset = 0;

    for (var page = 0; page < InvoiceListPager.maxPages; page++) {
      final batch = await _fetchPage(
        sessionId: sessionId,
        limit: InvoiceListPager.pageSize,
        offset: offset,
      );
      if (batch.isEmpty) break;

      var added = 0;
      for (final payment in batch) {
        final id = payment.id;
        if (id == null) {
          withoutId.add(payment);
          added++;
          continue;
        }
        if (byId.containsKey(id)) continue;
        byId[id] = payment;
        added++;
      }
      if (kDebugMode) {
        debugPrint(
          'get_customer_payment_list page=$page offset=$offset '
          'got=${batch.length} added=$added total=${byId.length + withoutId.length}',
        );
      }
      if (added == 0) break;
      if (batch.length < InvoiceListPager.pageSize) break;
      offset += InvoiceListPager.pageSize;
    }

    final merged = [...byId.values, ...withoutId];
    merged.sort(_compareNewestFirst);
    return merged;
  }

  static Future<List<CustomerPaymentRecord>> _refreshHead(
    String sessionId,
  ) async {
    try {
      final page = await _fetchPage(
        sessionId: sessionId,
        limit: InvoiceListPager.pageSize,
        offset: 0,
      );
      if (page.isEmpty) return _cache ?? const [];
      return _mergeNewestFirst(page, _cache);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('get_customer_payment_list head refresh: $e');
      }
      return _cache ?? const [];
    }
  }

  static Future<List<CustomerPaymentRecord>> _fetchPage({
    required String sessionId,
    required int limit,
    required int offset,
  }) async {
    final params = <String, dynamic>{
      'state': 'all',
      'limit': limit,
      'offset': offset,
      'skip': offset,
      'page': (offset ~/ limit) + 1,
    };
    final response = await WebApiImpl().fetchInvoiceList(
      endpointPath: EndPoint.customerPaymentList.path,
      userDetails: ApiRequestHelper.jsonRpcCall(params),
      sessionId: sessionId,
      logResponseBody: kDebugMode,
    );
    if (response.statusCode != 200) {
      if (kDebugMode) {
        debugPrint(
          'get_customer_payment_list HTTP ${response.statusCode}',
        );
      }
      return const [];
    }
    // HTML 404 pages sometimes still return 200 with non-json.
    final body = response.body.trim();
    if (!body.startsWith('{')) return const [];
    final decoded = json.decode(body);
    if (decoded is! Map) return const [];
    final map = Map<String, dynamic>.from(decoded);
    final result = map['result'];
    final statusSource =
        result is Map ? Map<String, dynamic>.from(result) : map;
    final status = '${statusSource['status'] ?? ''}'.trim().toLowerCase();
    if (status == 'error' || status == 'fail' || status == 'failed') {
      if (kDebugMode) {
        debugPrint(
          'get_customer_payment_list error: ${statusSource['message']}',
        );
      }
      return const [];
    }
    return CustomerPaymentRecord.parseList(map)
        .where(_isActivePayment)
        .toList(growable: false);
  }

  static bool _isActivePayment(CustomerPaymentRecord payment) {
    // Cancelled website payments must not appear in Cash Book.
    final name = payment.name.toUpperCase();
    if (name.contains('CANCEL')) return false;
    return payment.amount > 0.0001 || payment.invoices.isNotEmpty;
  }

  static int _compareNewestFirst(
    CustomerPaymentRecord a,
    CustomerPaymentRecord b,
  ) {
    final da = a.dateTime ?? DateTime(1970);
    final db = b.dateTime ?? DateTime(1970);
    final byDate = db.compareTo(da);
    if (byDate != 0) return byDate;
    return (b.id ?? 0).compareTo(a.id ?? 0);
  }

  /// Drop cache so cancelled payments disappear on next force refresh.
  static void clearCache() {
    _cache = null;
    _cachedAt = null;
  }
}
