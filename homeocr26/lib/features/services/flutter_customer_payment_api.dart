import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../models/cheque_clearance_model.dart';
import 'WebApi/web_api_impl.dart';
import 'api_request_helper.dart';
import 'api_response_helper.dart';
import 'endPoints.dart';

/// Laravel Flutter payment endpoints. Returns null/false when unavailable
/// so callers can keep the existing Odoo flow.
class FlutterCustomerPaymentApi {
  const FlutterCustomerPaymentApi._();

  static Future<List<ChequeLinkedInvoice>> getOpenBills({
    required String sessionId,
    int? partnerId,
    String? partnerName,
    int? responsiblePersonId,
  }) async {
    try {
      final params = <String, dynamic>{
        if (partnerId != null) 'partner_id': partnerId,
        if (partnerId != null) 'customer_id': partnerId,
        if ((partnerName ?? '').trim().isNotEmpty)
          'partner_name': partnerName!.trim(),
        if (responsiblePersonId != null)
          'responsible_person_id': responsiblePersonId,
      };
      final response = await WebApiImpl().fetchInvoiceList(
        endpointPath: EndPoint.customerOpenBills.path,
        sessionId: sessionId,
        userDetails: ApiRequestHelper.jsonRpcCall(params),
        logResponseBody: kDebugMode,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return const [];
      }
      final body = response.body.trim();
      if (!body.startsWith('{')) return const [];
      final decoded = json.decode(body);
      if (decoded is! Map) return const [];
      final map = Map<String, dynamic>.from(decoded);
      if (ApiResponseHelper.payloadMap(map)?['status'] == 'error') {
        return const [];
      }
      return _parseOpenBills(map);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('FlutterCustomerPaymentApi.getOpenBills: $e');
      }
      return const [];
    }
  }

  /// Returns created payment id, or null if the API is unavailable/failed.
  static Future<int?> createPayment({
    required String sessionId,
    required Map<String, dynamic> params,
  }) async {
    try {
      final response = await WebApiImpl().fetchInvoiceList(
        endpointPath: EndPoint.createCustomerPayment.path,
        sessionId: sessionId,
        userDetails: ApiRequestHelper.jsonRpcCall(params),
        logResponseBody: kDebugMode,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      final body = response.body.trim();
      if (!body.startsWith('{')) return null;
      final decoded = json.decode(body);
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded);
      if (!ApiResponseHelper.isSuccess(map)) return null;
      final data = ApiResponseHelper.dataMap(map);
      final payload = ApiResponseHelper.payloadMap(map) ?? map;
      for (final source in [data, payload]) {
        final id = source['payment_id'] ??
            source['id'] ??
            (source['payment'] is Map ? source['payment']['id'] : null);
        if (id is int) return id;
        final parsed = int.tryParse('$id');
        if (parsed != null && parsed > 0) return parsed;
      }
      return null;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('FlutterCustomerPaymentApi.createPayment: $e');
      }
      return null;
    }
  }

  static Future<bool> processPayment({
    required String sessionId,
    required int paymentId,
  }) async {
    return _postAction(
      endpoint: EndPoint.processCustomerPayment.path,
      sessionId: sessionId,
      paymentId: paymentId,
    );
  }

  static Future<bool> actionPayment({
    required String sessionId,
    required int paymentId,
    required String action,
  }) async {
    return _postAction(
      endpoint: EndPoint.actionCustomerPayment.path,
      sessionId: sessionId,
      paymentId: paymentId,
      extra: {
        'action': action,
        'action_name': action,
      },
    );
  }

  static Future<bool> _postAction({
    required String endpoint,
    required String sessionId,
    required int paymentId,
    Map<String, dynamic>? extra,
  }) async {
    try {
      final params = <String, dynamic>{
        'payment_id': paymentId,
        'id': paymentId,
        ...?extra,
      };
      final response = await WebApiImpl().fetchInvoiceList(
        endpointPath: endpoint,
        sessionId: sessionId,
        userDetails: ApiRequestHelper.jsonRpcCall(params),
        logResponseBody: kDebugMode,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return false;
      }
      final body = response.body.trim();
      if (!body.startsWith('{')) return response.statusCode == 200;
      final decoded = json.decode(body);
      if (decoded is! Map) return false;
      final map = Map<String, dynamic>.from(decoded);
      return ApiResponseHelper.isSuccess(map);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('FlutterCustomerPaymentApi.$endpoint: $e');
      }
      return false;
    }
  }

  static List<ChequeLinkedInvoice> _parseOpenBills(Map<String, dynamic> map) {
    final payload = ApiResponseHelper.payloadMap(map) ?? map;
    final data = payload['data'];
    final root = data is Map ? Map<String, dynamic>.from(data) : payload;
    final candidates = <dynamic>[
      root['open_bills'],
      root['open_invoices'],
      root['invoices'],
      root['bills'],
      root['records'],
      root['items'],
      if (data is List) data,
    ];
    for (final candidate in candidates) {
      if (candidate is! List) continue;
      return candidate
          .whereType<Map>()
          .map((e) => ChequeLinkedInvoice.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    return const [];
  }
}
