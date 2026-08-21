/// Parse MFD / expiry shortcuts used on stock create/edit.
///
/// - `1222` → `01/12/22` (day defaults to 1 when month+year is entered)
/// - `0722` → `01/07/22`
/// - `722` is invalid (month must be two digits)
/// Full dates like `15/12/2022` are kept when valid (shown as `15/12/22`).
class StockDateParser {
  const StockDateParser._();

  static String formatDisplay(DateTime date) {
    final d = date.day.toString().padLeft(2, '0');
    final m = date.month.toString().padLeft(2, '0');
    final y = (date.year % 100).toString().padLeft(2, '0');
    return '$d/$m/$y';
  }

  /// Returns a display date, empty string if blank, or null if invalid.
  static String? tryParse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';

    final digits = trimmed.replaceAll(RegExp(r'\D'), '');
    if (digits != trimmed.replaceAll(RegExp(r'[/\-.]'), '')) {
      // Mixed garbage.
    }

    if (RegExp(r'^\d{1,2}[/\-.]\d{1,2}[/\-.]\d{2,4}$').hasMatch(trimmed)) {
      final parts = trimmed.split(RegExp(r'[/\-.]'));
      final d = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      var y = int.tryParse(parts[2]);
      if (d == null || m == null || y == null) return null;
      if (parts[2].length == 2) y = y >= 70 ? 1900 + y : 2000 + y;
      if (!_isValid(d, m, y)) return null;
      return formatDisplay(DateTime(y, m, d));
    }

    if (digits.length == 4) {
      final m = int.tryParse(digits.substring(0, 2));
      var y = int.tryParse(digits.substring(2, 4));
      if (m == null || y == null) return null;
      y = y >= 70 ? 1900 + y : 2000 + y;
      if (!_isValid(1, m, y)) return null;
      return formatDisplay(DateTime(y, m, 1));
    }

    if (digits.length == 6) {
      final d = int.tryParse(digits.substring(0, 2));
      final m = int.tryParse(digits.substring(2, 4));
      var y = int.tryParse(digits.substring(4, 6));
      if (d == null || m == null || y == null) return null;
      y = y >= 70 ? 1900 + y : 2000 + y;
      if (!_isValid(d, m, y)) return null;
      return formatDisplay(DateTime(y, m, d));
    }

    if (digits.length == 8) {
      final d = int.tryParse(digits.substring(0, 2));
      final m = int.tryParse(digits.substring(2, 4));
      final y = int.tryParse(digits.substring(4, 8));
      if (d == null || m == null || y == null) return null;
      if (!_isValid(d, m, y)) return null;
      return formatDisplay(DateTime(y, m, d));
    }

    return null;
  }

  static bool _isValid(int day, int month, int year) {
    if (month < 1 || month > 12) return false;
    if (year < 1900 || year > 2100) return false;
    if (day < 1) return false;
    final last = DateTime(year, month + 1, 0).day;
    return day <= last;
  }

  /// ISO `yyyy-MM-dd` for Odoo date fields.
  static String? toApiDate(String? display) {
    final parsed = tryParse(display ?? '');
    if (parsed == null || parsed.isEmpty) return parsed;
    final parts = parsed.split('/');
    if (parts.length != 3) return null;
    final d = parts[0].padLeft(2, '0');
    final m = parts[1].padLeft(2, '0');
    var y = parts[2];
    if (y.length == 2) {
      final yi = int.tryParse(y) ?? 0;
      y = (yi >= 70 ? 1900 + yi : 2000 + yi).toString();
    }
    return '$y-$m-$d';
  }
}
