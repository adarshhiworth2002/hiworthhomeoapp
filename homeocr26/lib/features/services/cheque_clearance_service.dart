import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../models/cheque_clearance_model.dart';
import '../services/WebApi/web_api_impl.dart';
import 'api_request_helper.dart';
import 'endPoints.dart';

class ChequeClearanceService {
  const ChequeClearanceService._();

  static List<ChequeClearanceModel>? _cache;
  static DateTime? _cachedAt;
  static Future<List<ChequeClearanceModel>>? _inFlight;
  static const _cacheTtl = Duration(seconds: 60);

  static bool get hasFreshCache =>
      _cache != null &&
      _cachedAt != null &&
      DateTime.now().difference(_cachedAt!) < _cacheTtl;

  static List<ChequeClearanceModel>? get cachedItems => _cache;

  static Future<List<ChequeClearanceModel>> fetch({
    required String sessionId,
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && hasFreshCache) {
      return _cache!;
    }

    final pending = _inFlight;
    if (!forceRefresh && pending != null) {
      return pending;
    }

    final future = _fetchFromApi(sessionId: sessionId);
    _inFlight = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlight, future)) {
        _inFlight = null;
      }
    }
  }

  static Future<List<ChequeClearanceModel>> _fetchFromApi({
    required String sessionId,
  }) async {
    final webApi = WebApiImpl();
    final response = await webApi.fetchInvoiceList(
      endpointPath: EndPoint.chequeClearance.path,
      userDetails: ApiRequestHelper.jsonRpcCall(<String, dynamic>{}),
      sessionId: sessionId,
      logResponseBody: false,
    );

    if (response.statusCode != 200) {
      return _cache ?? const [];
    }

    final body = json.decode(response.body);
    if (body is! Map) return _cache ?? const [];

    final map = Map<String, dynamic>.from(body);
    if (map['result'] is Map && (map['result'] as Map)['status'] == 'error') {
      return _cache ?? const [];
    }

    final items = ChequeClearanceModel.parseList(map);
    if (kDebugMode) {
      debugPrint(
        'get_cheque_clearance parsed ${items.length} cheques '
        '(body ${response.bodyBytes.length} bytes)',
      );
      if (items.isNotEmpty) {
        final first = items.first;
        debugPrint(
          'cheque[0]=${first.serialNumber} total=${first.totalAmount} '
          'balance=${first.balance} pay=${first.displayCustomerPayment}',
        );
      } else {
        final preview = response.body.length > 600
            ? '${response.body.substring(0, 600)}…'
            : response.body;
        debugPrint('get_cheque_clearance empty parse preview: $preview');
      }
    }
    _cache = items;
    _cachedAt = DateTime.now();
    return items;
  }

  static Future<void> prefetch(
    String sessionId, {
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && hasFreshCache) return;
    try {
      await fetch(sessionId: sessionId, forceRefresh: forceRefresh);
    } catch (e, s) {
      if (kDebugMode) debugPrint('Cheque clearance prefetch: $e\n$s');
    }
  }

  static void clearCache() {
    _cache = null;
    _cachedAt = null;
    _inFlight = null;
  }
}
