import 'dart:convert';

import 'package:homeocr26/features/services/invoice_api_helper.dart';

void main() {
  final jsonStr = '''
  {"jsonrpc": "2.0", "id": 1, "result": {"status": "success", "data": {"invoice_list": [
    {"invoice_id": 1464, "invoice_number": "0092/2026-27", "state": "posted", "payment_state": "paid", "is_paid": true},
    {"invoice_id": 1440, "invoice_number": "0091/2026-27", "state": "draft", "payment_state": "not_paid", "is_paid": false}
  ], "invoice_numbers": ["0092/2026-27", "0091/2026-27"]}}}
  ''';
  final res = json.decode(jsonStr) as Map<String, dynamic>;
  final suggestions = InvoiceApiHelper.parseSuggestions(res);
  for (final s in suggestions) {
    print(
      '${s.prefix} state=${s.state} paid=${s.isPaid} isDraft=${s.isDraft} label=${s.statusLabel}',
    );
  }

  final emptyPaid = '''
  {"jsonrpc": "2.0", "id": 1, "result": {"status": "success", "data": {"invoice_list": [], "invoice_numbers": [], "count": 0}}}
  ''';
  final emptyRes = json.decode(emptyPaid) as Map<String, dynamic>;
  final emptySuggestions = InvoiceApiHelper.parseSuggestions(emptyRes);
  print('empty paid count: ${emptySuggestions.length}');

  final postedNoState = '''
  {"jsonrpc": "2.0", "id": 1, "result": {"status": "success", "data": {"invoice_list": [
    {"invoice_id": 1464, "invoice_number": "0092/2026-27", "payment_state": "paid", "is_paid": true},
    {"invoice_id": 1400, "invoice_number": "0087/2026-27", "payment_state": "paid", "is_paid": true}
  ], "invoice_numbers": ["0092/2026-27", "0087/2026-27"]}}}
  ''';
  final postedRes = json.decode(postedNoState) as Map<String, dynamic>;
  final postedSuggestions = InvoiceApiHelper.parseSuggestions(
    postedRes,
    defaultState: 'posted',
  );
  print('--- posted fetch without state field on objects ---');
  for (final s in postedSuggestions) {
    print(
      '${s.prefix} state=${s.state} paid=${s.isPaid} isDraft=${s.isDraft} label=${s.statusLabel}',
    );
  }
}
