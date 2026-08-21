import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../models/invoice_summary_model.dart';
import '../../models/net_amount_model.dart';
import 'WebApi/web_api_impl.dart';
import 'api_request_helper.dart';

/// Walks `limit` + `offset` until the Flutter list API returns every row.
class InvoiceListPager {
  const InvoiceListPager._();

  static const int pageSize = 200;
  static const int maxPages = 100;

  static Future<InvoiceListPageResult> fetchAll({
    required String endpointPath,
    required String sessionId,
    Map<String, dynamic> extraParams = const {},
  }) async {
    final webApi = WebApiImpl();
    final byId = <int, InvoiceSummaryModel>{};
    final withoutId = <InvoiceSummaryModel>[];
    final raw = <Map<String, dynamic>>[];
    final seenRaw = <String>{};
    var offset = 0;

    for (var page = 0; page < maxPages; page++) {
      final batch = await _fetchPage(
        webApi: webApi,
        endpointPath: endpointPath,
        sessionId: sessionId,
        extraParams: extraParams,
        limit: pageSize,
        offset: offset,
      );
      if (batch.error != null) {
        if (byId.isEmpty && withoutId.isEmpty) {
          return InvoiceListPageResult(error: batch.error);
        }
        break;
      }
      if (batch.invoices.isEmpty) break;

      var added = 0;
      for (final inv in batch.invoices) {
        final id = inv.id;
        if (id == null) {
          withoutId.add(inv);
          added++;
          continue;
        }
        if (byId.containsKey(id)) continue;
        byId[id] = inv;
        added++;
      }
      for (final row in batch.raw) {
        final key = '${row['id'] ?? ''}|${row['invoice_number'] ?? row['name'] ?? ''}';
        if (seenRaw.add(key)) raw.add(row);
      }

      if (kDebugMode) {
        debugPrint(
          'invoice pager $endpointPath page=$page offset=$offset '
          'got=${batch.invoices.length} added=$added total=${byId.length + withoutId.length}',
        );
      }

      if (added == 0) break;
      if (batch.invoices.length < pageSize) break;
      offset += pageSize;
    }

    final invoices = [...byId.values, ...withoutId];
    invoices.sort((a, b) {
      final da = a.invoiceDate ?? '';
      final db = b.invoiceDate ?? '';
      final byDate = db.compareTo(da);
      if (byDate != 0) return byDate;
      return b.displayNumber.compareTo(a.displayNumber);
    });
    return InvoiceListPageResult(invoices: invoices, raw: raw);
  }

  /// Single page (used for fast live head-refresh).
  static Future<InvoiceListPageResult> fetchPage({
    required String endpointPath,
    required String sessionId,
    Map<String, dynamic> extraParams = const {},
    int limit = pageSize,
    int offset = 0,
  }) async {
    final batch = await _fetchPage(
      webApi: WebApiImpl(),
      endpointPath: endpointPath,
      sessionId: sessionId,
      extraParams: extraParams,
      limit: limit,
      offset: offset,
    );
    if (batch.error != null) {
      return InvoiceListPageResult(error: batch.error);
    }
    return InvoiceListPageResult(
      invoices: batch.invoices,
      raw: batch.raw,
    );
  }

  static Future<_Page> _fetchPage({
    required WebApiImpl webApi,
    required String endpointPath,
    required String sessionId,
    required Map<String, dynamic> extraParams,
    required int limit,
    required int offset,
  }) async {
    final params = <String, dynamic>{
      ...extraParams,
      'limit': limit,
      'offset': offset,
      'skip': offset,
      'page': (offset ~/ limit) + 1,
      'page_number': (offset ~/ limit) + 1,
    };
    final response = await webApi.fetchInvoiceList(
      endpointPath: endpointPath,
      userDetails: ApiRequestHelper.jsonRpcCall(params),
      sessionId: sessionId,
      logResponseBody: false,
    );
    if (response.statusCode != 200) {
      return _Page.error(
        'Unable to load invoices (HTTP ${response.statusCode})',
      );
    }
    final decoded = json.decode(response.body);
    if (decoded is! Map) return const _Page();
    final map = Map<String, dynamic>.from(decoded);
    if (map['result'] is Map &&
        (map['result'] as Map)['status'] == 'error') {
      return _Page.error(
        (map['result'] as Map)['message']?.toString() ??
            'Failed to load invoices',
      );
    }
    return _Page(
      invoices: InvoiceSummaryModel.parseList(map),
      raw: NetAmountRow.extractRecordMaps(map),
    );
  }
}

class InvoiceListPageResult {
  const InvoiceListPageResult({
    this.invoices = const [],
    this.raw = const [],
    this.error,
  });

  final List<InvoiceSummaryModel> invoices;
  final List<Map<String, dynamic>> raw;
  final String? error;
}

class _Page {
  const _Page({this.invoices = const [], this.raw = const [], this.error});

  factory _Page.error(String message) => _Page(error: message);

  final List<InvoiceSummaryModel> invoices;
  final List<Map<String, dynamic>> raw;
  final String? error;
}
