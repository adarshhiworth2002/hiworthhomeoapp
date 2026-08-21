enum InvoiceGstKind { b2b, b2c, unknown }

/// Reads B2B / B2C from customer-invoice API fields (not A/R bill series).
class InvoiceGstKindParser {
  InvoiceGstKindParser._();

  static InvoiceGstKind kindFromValue(dynamic raw) {
    final text = _stringify(raw);
    if (text == null) return InvoiceGstKind.unknown;
    if (_isOdooMoveType(text)) return InvoiceGstKind.unknown;
    if (text.contains('b2b') ||
        text == 'regular' ||
        text == 'registered' ||
        text == 'composition' ||
        text == 'business' ||
        text == 'sez' ||
        text == 'deemed_export' ||
        text == 'deemed export') {
      return InvoiceGstKind.b2b;
    }
    if (text.contains('b2c') ||
        text == 'consumer' ||
        text == 'unregistered' ||
        text == 'un-registered' ||
        text == 'unregistered_business') {
      return InvoiceGstKind.b2c;
    }
    return InvoiceGstKind.unknown;
  }

  static InvoiceGstKind kindFromJson(Map json) {
    final flat = flattenInvoiceJson(json);

    for (final key in const [
      'invoice_gst_type',
      'gst_invoice_type',
      'invoice_gst_category',
      'gst_bill_type',
      'b2b_b2c',
      'b2b_b2c_type',
      'is_b2b',
      'is_b2c',
      'b2b',
      'b2c',
      'l10n_in_gst_treatment',
      'gst_treatment',
      'customer_gst_type',
      'invoice_nature',
      'tax_invoice_type',
      'bill_category',
      'invoice_category',
      'bill_type',
    ]) {
      if (!flat.containsKey(key)) continue;
      final kind = _kindFromKeyValue(key, flat[key]);
      if (kind != InvoiceGstKind.unknown) return kind;
    }

    for (final entry in flat.entries) {
      final kind = _kindFromKeyValue(entry.key, entry.value);
      if (kind != InvoiceGstKind.unknown) return kind;
    }
    return InvoiceGstKind.unknown;
  }

  static String? labelFromJson(Map json) {
    switch (kindFromJson(json)) {
      case InvoiceGstKind.b2b:
        return 'b2b';
      case InvoiceGstKind.b2c:
        return 'b2c';
      case InvoiceGstKind.unknown:
        return null;
    }
  }

  static bool? flagFromJson(Map json) {
    switch (kindFromJson(json)) {
      case InvoiceGstKind.b2b:
        return true;
      case InvoiceGstKind.b2c:
        return false;
      case InvoiceGstKind.unknown:
        return null;
    }
  }

  static Map<String, dynamic> flattenInvoiceJson(Map json) {
    final out = <String, dynamic>{};
    void add(String key, dynamic value, [int depth = 0]) {
      if (value is Map && depth < 2) {
        for (final entry in value.entries) {
          add(entry.key.toString(), entry.value, depth + 1);
        }
        return;
      }
      out[key] = value;
    }

    json.forEach((key, value) => add(key.toString(), value));
    return out;
  }

  static InvoiceGstKind _kindFromKeyValue(String key, dynamic value) {
    final k = key.toLowerCase().trim();
    if (k == 'gst_type' ||
        k == 'move_type' ||
        k == 'state' ||
        k == 'payment_state' ||
        k == 'payment_mode' ||
        k == 'discount_type' ||
        k == 'type_tax_use') {
      return InvoiceGstKind.unknown;
    }
    if (k == 'customer_type' || k == 'invoice_type' || k == 'type') {
      return kindFromValue(value);
    }

    final text = _stringify(value);
    if (k.contains('b2b') && !k.contains('b2c')) {
      if (text == 'b2c') return InvoiceGstKind.b2c;
      if (_isTruthy(value) || text == 'b2b') return InvoiceGstKind.b2b;
      return InvoiceGstKind.unknown;
    }
    if (k.contains('b2c')) {
      if (text == 'b2b') return InvoiceGstKind.b2b;
      if (_isTruthy(value) || text == 'b2c') return InvoiceGstKind.b2c;
      return InvoiceGstKind.unknown;
    }

    final looksLikeGstColumn = k.contains('gst') ||
        k.contains('treatment') ||
        ((k.contains('invoice') || k.contains('bill')) &&
            (k.contains('type') ||
                k.contains('category') ||
                k.contains('nature') ||
                k.contains('kind')));
    if (looksLikeGstColumn) {
      return kindFromValue(value);
    }
    return InvoiceGstKind.unknown;
  }

  static bool _isOdooMoveType(String text) {
    return text == 'out_invoice' ||
        text == 'in_invoice' ||
        text == 'out_refund' ||
        text == 'in_refund' ||
        text == 'out_receipt' ||
        text == 'in_receipt' ||
        text == 'entry' ||
        text == 'invoice' ||
        text == 'credit_note';
  }

  static bool _isTruthy(dynamic value) {
    if (value == true || value == 1 || value == 1.0) return true;
    final text = _stringify(value);
    return text == '1' || text == 'true' || text == 'yes';
  }

  static String? _stringify(dynamic value) {
    if (value == null || value == false) return null;
    if (value is List && value.length >= 2) {
      return _stringify(value[1]);
    }
    final text = value.toString().trim().toLowerCase();
    if (text.isEmpty || text == 'false' || text == 'null') return null;
    return text;
  }
}
