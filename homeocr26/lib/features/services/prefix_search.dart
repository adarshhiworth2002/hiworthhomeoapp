/// Prefix / first-letter search used across list screens.
class PrefixSearch {
  const PrefixSearch._();

  /// True when [value] starts with [query] (case-insensitive).
  /// Empty [query] matches everything.
  static bool matches(String? value, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    final v = (value ?? '').trim().toLowerCase();
    if (v.isEmpty) return false;
    return v.startsWith(q);
  }

  /// True when any of [values] starts with [query].
  static bool matchesAny(Iterable<String?> values, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    for (final value in values) {
      if (matches(value, q)) return true;
    }
    return false;
  }
}
