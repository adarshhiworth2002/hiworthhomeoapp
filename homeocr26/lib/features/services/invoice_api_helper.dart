import 'invoice_helper.dart';
import 'invoice_suggestion.dart';

class InvoiceApiHelper {
  /// Rich list keys first; `invoice_numbers` is fallback when no object exists
  /// for that prefix. `data` is handled explicitly (nested wrapper), not here.
  static const List<String> _listKeys = [
    'invoice_list',
    'invoices',
    'invoice_numbers',
    'records',
    'items',
    'results',
  ];

  static const List<String> _itemKeys = [
    'invoice_name',
    'invoice_number',
    'invoice_no',
    'name',
    'number',
    'display_name',
    'label',
  ];

  static List<String> parseInvoicePrefixes(dynamic data) {
    if (data is! List) return [];

    return data
        .map((item) => _prefixFromItem(item))
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
  }

  static List<String> parseSearchResponse(Map<String, dynamic> response) {
    return parseSuggestions(response).map((item) => item.prefix).toList();
  }

  static List<InvoiceSuggestion> parseSuggestions(
    Map<String, dynamic> response, {
    String? defaultState,
  }) {
    final suggestions = _parseSuggestionNode(
      response['result'],
      defaultState: defaultState,
    );
    if (suggestions.isNotEmpty) return suggestions;

    final topLevel = _parseSuggestionNode(
      response['data'],
      defaultState: defaultState,
    );
    if (topLevel.isNotEmpty) return topLevel;

    return [];
  }

  static List<InvoiceSuggestion> _parseSuggestionNode(
    dynamic node, {
    String? defaultState,
  }) {
    if (node == null) return [];

    if (node is List) {
      return parseInvoiceSuggestions(node, defaultState: defaultState);
    }

    if (node is String && node.trim().isNotEmpty) {
      return [_suggestionFromString(node, defaultState: defaultState)];
    }

    if (node is Map) {
      final merged = <String, InvoiceSuggestion>{};

      for (final key in _listKeys) {
        if (!node.containsKey(key)) continue;
        final found = _parseSuggestionNode(
          node[key],
          defaultState: defaultState,
        );
        for (final item in found) {
          _mergeByPriority(merged, item);
        }
      }

      if (node.containsKey('data')) {
        final found = _parseSuggestionNode(
          node['data'],
          defaultState: defaultState,
        );
        for (final item in found) {
          _mergeByPriority(merged, item);
        }
      }

      if (merged.isNotEmpty) {
        return merged.values.toList();
      }

      final single = _suggestionFromItem(node, defaultState: defaultState);
      if (single != null) return [single];
    }

    return [];
  }

  static List<InvoiceSuggestion> parseInvoiceSuggestions(
    dynamic data, {
    String? defaultState,
  }) {
    if (data is! List) return [];

    final merged = <String, InvoiceSuggestion>{};
    for (final item in data) {
      final suggestion = _suggestionFromItem(item, defaultState: defaultState);
      if (suggestion != null) {
        _mergeByPriority(merged, suggestion);
      }
    }

    return merged.values.toList();
  }

  /// When the same prefix appears as a plain string and as a rich object,
  /// keep the entry with the stronger (posted/paid) state.
  static void _mergeByPriority(
    Map<String, InvoiceSuggestion> merged,
    InvoiceSuggestion item,
  ) {
    if (item.prefix.isEmpty) return;

    final existing = merged[item.prefix];
    if (existing == null) {
      merged[item.prefix] = item;
      return;
    }

    if (_statePriority(item) >= _statePriority(existing)) {
      merged[item.prefix] = item;
    }
  }

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

  static InvoiceSuggestion _suggestionFromString(
    String value, {
    String? defaultState,
  }) {
    return InvoiceSuggestion(
      prefix: InvoiceHelper.prefixFromFull(value),
      state: defaultState ?? 'draft',
    );
  }

  static InvoiceSuggestion? _suggestionFromItem(
    dynamic item, {
    String? defaultState,
  }) {
    if (item is String) {
      return _suggestionFromString(item, defaultState: defaultState);
    }
    if (item is num) {
      return InvoiceSuggestion(
        prefix: item.toString(),
        state: defaultState ?? 'draft',
      );
    }
    if (item is Map) {
      if (!_looksLikeInvoiceRecord(item)) return null;

      final prefix = _prefixFromItem(item);
      if (prefix.isEmpty) return null;

      final state = _resolveInvoiceState(item, defaultState: defaultState);
      final paymentState = _firstNonEmpty(item, const [
        'payment_state',
        'payment_status',
      ]);
      final isPaid = item['is_paid'] == true ||
          item['is_paid'] == 1 ||
          paymentState?.toLowerCase().trim() == 'paid';

      return InvoiceSuggestion(
        prefix: prefix,
        state: state,
        paymentState: paymentState,
        isPaid: isPaid,
      );
    }
    return null;
  }

  static String _resolveInvoiceState(
    Map item, {
    String? defaultState,
  }) {
    final raw = _firstNonEmpty(item, const [
      'state',
      'invoice_state',
      'status',
    ]);
    if (raw != null) {
      final normalized = raw.toLowerCase().trim();
      if (normalized != 'success' && normalized != 'error') {
        return raw;
      }
    }
    return defaultState ?? 'draft';
  }

  static bool _looksLikeInvoiceRecord(Map item) {
    for (final key in _itemKeys) {
      final value = item[key];
      if (value != null && value.toString().trim().isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  static String? _firstNonEmpty(Map item, List<String> keys) {
    for (final key in keys) {
      final value = item[key];
      if (value == null) continue;
      final trimmed = value.toString().trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return null;
  }

  static String _prefixFromItem(dynamic item) {
    if (item is String) {
      return InvoiceHelper.prefixFromFull(item);
    }
    if (item is num) {
      return item.toString();
    }
    if (item is Map) {
      for (final key in _itemKeys) {
        final value = item[key];
        if (value != null && value.toString().trim().isNotEmpty) {
          return InvoiceHelper.prefixFromFull(value.toString());
        }
      }
    }
    return '';
  }

  static String? parseInvoiceNumber(Map<String, dynamic> response) {
    final result = response['result'];
    if (result is! Map) return null;

    final invoiceName = result['invoice_name'];
    if (invoiceName != null && invoiceName.toString().trim().isNotEmpty) {
      return invoiceName.toString().trim();
    }

    final direct = result['invoice_number'] ?? result['invoice_no'];
    if (direct != null && direct.toString().trim().isNotEmpty) {
      return direct.toString().trim();
    }

    final data = result['data'];
    if (data is String && data.trim().isNotEmpty) {
      return data.trim();
    }
    if (data is Map) {
      final nestedName = data['invoice_name'] ?? data['invoice_no'];
      if (nestedName != null && nestedName.toString().trim().isNotEmpty) {
        return nestedName.toString().trim();
      }
      final nested = data['invoice_number'];
      if (nested != null && nested.toString().trim().isNotEmpty) {
        return nested.toString().trim();
      }
    }
    return null;
  }

  static String? parseInvoicePrefix(Map<String, dynamic> response) {
    final full = parseInvoiceNumber(response);
    if (full == null) return null;
    return InvoiceHelper.prefixFromFull(full);
  }
}
