/// Substring search used across list screens (same behaviour as filter sheets).
class PrefixSearch {
  const PrefixSearch._();

  /// True when [value] contains [query] (case-insensitive).
  /// Empty [query] matches everything.
  static bool matches(String? value, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    final v = (value ?? '').trim().toLowerCase();
    if (v.isEmpty) return false;
    return v.contains(q);
  }

  /// True when any of [values] contains [query].
  static bool matchesAny(Iterable<String?> values, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    for (final value in values) {
      if (matches(value, q)) return true;
    }
    return false;
  }

  /// Customer name + invoice number (Payment History / Customer Invoice search).
  static bool matchesCustomerOrInvoice({
    required String query,
    String? customer,
    String? displayCustomer,
    String? displayNumber,
    String? invoiceNumber,
    String? listCustomerLabel,
  }) {
    final q = query.trim().toLowerCase().replaceAll(RegExp(r'[\s_-]+'), '');
    final nameless = (displayCustomer ?? '').trim().isEmpty &&
        ((customer ?? '').trim().isEmpty ||
            (listCustomerLabel ?? '').toLowerCase().contains('walkin'));
    if (nameless &&
        (q.contains('walkin') || q == 'walk' || q.contains('demo'))) {
      return true;
    }
    return matchesAny(
      [
        displayCustomer,
        customer,
        listCustomerLabel,
        displayNumber,
        invoiceNumber,
      ],
      query,
    );
  }
}
