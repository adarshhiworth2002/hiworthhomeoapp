class InvoiceHelper {
  /// Returns suffix e.g. `2026-27` (updates each calendar year on Jan 1).
  static String yearSuffix([DateTime? date]) {
    final now = date ?? DateTime.now();
    final nextYearShort = (now.year + 1) % 100;
    return '${now.year}-${nextYearShort.toString().padLeft(2, '0')}';
  }

  static bool isPlaceholderNumber(String? raw) {
    final t = (raw ?? '').trim();
    if (t.isEmpty || t == '/' || t.toLowerCase() == 'false') return true;
    final lower = t.toLowerCase();
    return lower.startsWith('draft-') || lower.startsWith('inv/');
  }

  /// Next bill after [last], keeping the backend format.
  /// `R0042` → `R0043`, `0501/2026-27` → `0502/2026-27`.
  static String nextAfter(String last, [DateTime? date]) {
    final t = last.trim();
    if (isPlaceholderNumber(t)) {
      return nextInvoiceNumber(const [], date);
    }

    final fiscal = RegExp(r'^(\d+)/(\d{4}-\d{2})$').firstMatch(t);
    if (fiscal != null) {
      final digits = fiscal.group(1)!;
      final year = fiscal.group(2)!;
      final n = int.parse(digits);
      return '${(n + 1).toString().padLeft(digits.length, '0')}/$year';
    }

    final trailing = RegExp(r'^(.*?)(\d+)$').firstMatch(t);
    if (trailing != null) {
      final prefix = trailing.group(1)!;
      final digits = trailing.group(2)!;
      final n = int.parse(digits);
      return '$prefix${(n + 1).toString().padLeft(digits.length, '0')}';
    }

    return t;
  }

  /// Prefer the highest-id invoice's format over an older numeric series.
  static String nextFromLatest({
    required Iterable<int?> ids,
    required Iterable<String> numbers,
    DateTime? date,
  }) {
    final idList = ids.toList(growable: false);
    final numList = numbers.toList(growable: false);
    final count = idList.length < numList.length ? idList.length : numList.length;
    var bestId = -1;
    String? bestNumber;
    for (var i = 0; i < count; i++) {
      final number = numList[i].trim();
      if (isPlaceholderNumber(number)) continue;
      final id = idList[i] ?? -1;
      if (bestNumber == null || id > bestId) {
        bestId = id;
        bestNumber = number;
      }
    }
    if (bestNumber != null) return nextAfter(bestNumber, date);
    return nextInvoiceNumber(numList, date);
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
