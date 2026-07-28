import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:homeocr26/viewModels/login_viewmodel.dart';
import 'package:provider/provider.dart';

import 'WebApi/web_api_impl.dart';
import 'api_request_helper.dart';
import 'api_response_helper.dart';
import 'endPoints.dart';
import 'invoice_helper.dart';
import 'invoice_api_helper.dart';
import 'invoice_suggestion.dart';

enum InvoiceSearchType { customer, supplier }

class InvoiceSearchService {
  static const int defaultLimit = 5;
  static const int listFetchLimit = 100;
  static const String draftState = 'draft';
  // Posted fetch includes paid bills (`is_paid: true`); paid filter is often empty.
  static const List<String> _supplierStates = ['posted', 'paid', 'draft'];

  static final Map<InvoiceSearchType, List<InvoiceSuggestion>> _suggestionCache =
      {};
  static final Map<InvoiceSearchType, Future<List<InvoiceSuggestion>>?>
      _loadFuture = {};

  static EndPoint _endpointFor(InvoiceSearchType type) {
    return type == InvoiceSearchType.customer
        ? EndPoint.customerInvoiceList
        : EndPoint.supplierInvoiceList;
  }

  /// Higher priority wins when the same invoice appears in multiple state fetches.
  static int _statePriority(InvoiceSuggestion suggestion) {
    if (suggestion.isPaid) return 4;

    final payment = suggestion.paymentState?.toLowerCase().trim();
    if (payment == 'paid' || payment == 'in_payment') return 4;

    switch (suggestion.state.toLowerCase().trim()) {
      case 'paid':
        return 4;
      case 'posted':
      case 'open':
        return 3;
      case 'draft':
        return 1;
      default:
        return 0;
    }
  }

  static void _mergeSuggestion(
    Map<String, InvoiceSuggestion> merged,
    InvoiceSuggestion item,
  ) {
    final existing = merged[item.prefix];
    if (existing == null) {
      merged[item.prefix] = item;
      return;
    }

    if (_statePriority(item) >= _statePriority(existing)) {
      merged[item.prefix] = item;
    }
  }

  static bool _prefixMatches(String item, String needle) {
    return InvoiceHelper.prefixStartsWith(item, needle);
  }

  static Future<List<InvoiceSuggestion>> _loadAllSuggestions(
    BuildContext context,
    InvoiceSearchType type,
  ) async {
    if (type == InvoiceSearchType.supplier) {
      final merged = <String, InvoiceSuggestion>{};
      for (final state in _supplierStates) {
        final batch = await _loadSuggestionsForState(context, type, state);
        for (final item in batch) {
          _mergeSuggestion(merged, item);
        }
      }
      return merged.values.toList()..sort((a, b) => a.prefix.compareTo(b.prefix));
    }

    return _loadSuggestionsForState(context, type, draftState);
  }

  static Future<List<InvoiceSuggestion>> _loadSuggestionsForState(
    BuildContext context,
    InvoiceSearchType type,
    String state,
  ) async {
    try {
      final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
      if (loginModel.sessionId == null || loginModel.sessionId!.isEmpty) {
        return [];
      }

      final webApi = WebApiImpl();
      final endpoint = _endpointFor(type);
      final response = await webApi.fetchInvoiceList(
        endpointPath: endpoint.path,
        userDetails: ApiRequestHelper.jsonRpcCall({
          'limit': listFetchLimit,
          'state': state,
        }),
        sessionId: loginModel.sessionId ?? '',
      );

      if (response.statusCode != 200) {
        if (kDebugMode) {
          debugPrint(
            '${endpoint.path} HTTP ${response.statusCode}: ${response.body}',
          );
        }
        return [];
      }

      final Map<String, dynamic> respo = json.decode(response.body);
      final suggestions = InvoiceApiHelper.parseSuggestions(
        respo,
        defaultState: state,
      );

      if (suggestions.isNotEmpty) {
        if (kDebugMode) {
          debugPrint(
            '${endpoint.path} [$state] loaded ${suggestions.length} invoices',
          );
        }
        return suggestions;
      }

      if (!ApiResponseHelper.isSuccess(respo)) {
        if (kDebugMode) {
          debugPrint(
            '${endpoint.path} error: ${ApiResponseHelper.errorMessage(respo)}',
          );
        }
      } else if (kDebugMode) {
        debugPrint('${endpoint.path} returned success but no invoice numbers');
      }

      return [];
    } catch (e) {
      if (kDebugMode) {
        debugPrint('invoice list error: $e');
      }
      return [];
    }
  }

  static Future<List<InvoiceSuggestion>> _ensureSuggestionCache(
    BuildContext context,
    InvoiceSearchType type,
  ) async {
    final cached = _suggestionCache[type];
    if (cached != null && cached.isNotEmpty) return cached;

    final inFlight = _loadFuture[type];
    if (inFlight != null) return inFlight;

    final future = _loadAllSuggestions(context, type).then((suggestions) {
      _loadFuture[type] = null;
      if (suggestions.isNotEmpty) {
        _suggestionCache[type] = suggestions;
      }
      return suggestions;
    });

    _loadFuture[type] = future;
    return future;
  }

  static void clearCache() {
    _suggestionCache.clear();
    _loadFuture.clear();
  }

  static Future<List<InvoiceSuggestion>> searchSuggestions(
    BuildContext context,
    String prefix, {
    required InvoiceSearchType type,
    int limit = defaultLimit,
  }) async {
    final trimmed = prefix.trim();
    if (trimmed.isEmpty) return [];

    final allSuggestions = await _ensureSuggestionCache(context, type);
    if (allSuggestions.isEmpty) return [];

    final matches = allSuggestions
        .where((item) => _prefixMatches(item.prefix, trimmed))
        .toList();
    matches.sort((a, b) {
      final priority = _statePriority(b).compareTo(_statePriority(a));
      if (priority != 0) return priority;
      return a.prefix.compareTo(b.prefix);
    });
    if (matches.length <= limit) return matches;
    return matches.sublist(0, limit);
  }

  static Future<List<String>> searchPrefixes(
    BuildContext context,
    String prefix, {
    required InvoiceSearchType type,
    int limit = defaultLimit,
  }) async {
    final suggestions = await searchSuggestions(
      context,
      prefix,
      type: type,
      limit: limit,
    );
    return suggestions.map((item) => item.prefix).toList();
  }

  static Future<bool> invoicePrefixExists(
    BuildContext context,
    String prefix, {
    required InvoiceSearchType type,
  }) async {
    final trimmed = prefix.trim();
    if (trimmed.isEmpty) return false;

    final allSuggestions = await _ensureSuggestionCache(context, type);
    return allSuggestions.any((item) => _prefixEquals(item.prefix, trimmed));
  }

  static Future<InvoiceSuggestion?> findSuggestion(
    BuildContext context,
    String prefix, {
    required InvoiceSearchType type,
  }) async {
    final trimmed = prefix.trim();
    if (trimmed.isEmpty) return null;

    final allSuggestions = await _ensureSuggestionCache(context, type);
    InvoiceSuggestion? best;
    for (final item in allSuggestions) {
      if (!_prefixEquals(item.prefix, trimmed)) continue;
      if (best == null || _statePriority(item) >= _statePriority(best)) {
        best = item;
      }
    }
    return best;
  }

  /// Re-fetches posted/paid lists before add so paid bills are never treated
  /// as draft because of stale cache or plain `invoice_numbers` strings.
  static Future<InvoiceSuggestion?> resolveForSupplierAdd(
    BuildContext context,
    String prefix,
  ) async {
    final trimmed = prefix.trim();
    if (trimmed.isEmpty) return null;

    InvoiceSuggestion? best;

    for (final state in const ['posted', 'paid']) {
      final batch = await _loadSuggestionsForState(
        context,
        InvoiceSearchType.supplier,
        state,
      );
      for (final item in batch) {
        if (!_prefixEquals(item.prefix, trimmed)) continue;
        if (best == null || _statePriority(item) >= _statePriority(best)) {
          best = item;
        }
      }
    }

    if (best != null) {
      _upsertCacheSuggestion(InvoiceSearchType.supplier, best);
      return best;
    }

    final draftBatch = await _loadSuggestionsForState(
      context,
      InvoiceSearchType.supplier,
      draftState,
    );
    for (final item in draftBatch) {
      if (_prefixEquals(item.prefix, trimmed)) {
        _upsertCacheSuggestion(InvoiceSearchType.supplier, item);
        return item;
      }
    }

    return findSuggestion(
      context,
      trimmed,
      type: InvoiceSearchType.supplier,
    );
  }

  static void _upsertCacheSuggestion(
    InvoiceSearchType type,
    InvoiceSuggestion item,
  ) {
    final cache = _suggestionCache[type] ?? <InvoiceSuggestion>[];
    final merged = <String, InvoiceSuggestion>{};
    for (final existing in cache) {
      _mergeSuggestion(merged, existing);
    }
    _mergeSuggestion(merged, item);
    _suggestionCache[type] = merged.values.toList()
      ..sort((a, b) => a.prefix.compareTo(b.prefix));
  }

  static bool _prefixEquals(String item, String needle) {
    return InvoiceHelper.prefixesMatch(item, needle);
  }
}
