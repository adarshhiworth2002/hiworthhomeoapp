class InvoiceHelper {
  /// Returns suffix e.g. `2026-27` (updates each calendar year on Jan 1).
  static String yearSuffix([DateTime? date]) {
    final now = date ?? DateTime.now();
    final nextYearShort = (now.year + 1) % 100;
    return '${now.year}-${nextYearShort.toString().padLeft(2, '0')}';
  }

  static String prefixFromFull(String? full) {
    if (full == null || full.trim().isEmpty) return '';
    final parts = full.split('/');
    return parts.first.trim();
  }

  static String formatFull(String prefix, [DateTime? date]) {
    final trimmed = prefix.trim();
    if (trimmed.isEmpty) return '';
    return '$trimmed/${yearSuffix(date)}';
  }

  /// Next customer invoice for the current fiscal suffix, e.g. `0505/2026-27`.
  static String nextInvoiceNumber(
    Iterable<String> existingNumbers, [
    DateTime? date,
  ]) {
    final year = yearSuffix(date);
    var maxPrefix = 0;
    var pad = 4;

    for (final raw in existingNumbers) {
      final full = raw.trim();
      if (full.isEmpty) continue;
      final parts = full.split('/');
      final prefix = parts.first.trim();
      final suffix = parts.length > 1 ? parts.sublist(1).join('/') : '';
      if (suffix.isNotEmpty && suffix != year) continue;
      final n = int.tryParse(prefix);
      if (n == null) continue;
      if (prefix.length > pad) pad = prefix.length;
      if (n > maxPrefix) maxPrefix = n;
    }

    return formatFull((maxPrefix + 1).toString().padLeft(pad, '0'), date);
  }

  /// True when [a] and [b] refer to the same invoice prefix (e.g. `92` vs `0092`).
  static bool prefixesMatch(String a, String b) {
    final left = a.trim().toLowerCase();
    final right = b.trim().toLowerCase();
    if (left == right) return true;

    final leftDigits = left.replaceFirst(RegExp(r'^0+'), '');
    final rightDigits = right.replaceFirst(RegExp(r'^0+'), '');
    return leftDigits.isNotEmpty &&
        rightDigits.isNotEmpty &&
        leftDigits == rightDigits;
  }

  /// True when typed [needle] matches invoice prefix [item] for autocomplete.
  static bool prefixStartsWith(String item, String needle) {
    final itemLower = item.toLowerCase();
    final needleLower = needle.toLowerCase();
    if (itemLower.startsWith(needleLower)) return true;

    final itemDigits = itemLower.replaceFirst(RegExp(r'^0+'), '');
    final needleDigits = needleLower.replaceFirst(RegExp(r'^0+'), '');
    if (needleDigits.isNotEmpty && itemDigits.startsWith(needleDigits)) {
      return true;
    }

    return false;
  }
}
