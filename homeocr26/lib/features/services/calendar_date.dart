/// Business calendar dates (invoice / payment / stock) without UTC off-by-one.
///
/// Odoo date fields are `YYYY-MM-DD`. Dart's [DateTime.parse] treats those as
/// **UTC midnight**, which shifts the calendar day when converted to local in
/// many timezones. Always prefer [parseCalendarDate] for bill dates.
class CalendarDate {
  const CalendarDate._();

  /// Local calendar day for "today".
  static DateTime today() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  /// `YYYY-MM-DD` for API writes (local calendar components).
  static String ymd([DateTime? date]) {
    final d = date ?? today();
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  /// `DD/MM/YYYY` for display.
  static String dmy([DateTime? date]) {
    final d = date ?? today();
    final day = d.day.toString().padLeft(2, '0');
    final m = d.month.toString().padLeft(2, '0');
    return '$day/$m/${d.year}';
  }

  /// Parse API / display date strings into a local calendar [DateTime] (time 00:00).
  static DateTime? parse(String? raw) {
    final s = (raw ?? '').trim();
    if (s.isEmpty || s == 'false') return null;

    // Pure Odoo date: use components as calendar day (never UTC).
    final dateOnly = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');
    final dm = dateOnly.firstMatch(s);
    if (dm != null) {
      return DateTime(
        int.parse(dm.group(1)!),
        int.parse(dm.group(2)!),
        int.parse(dm.group(3)!),
      );
    }

    // Datetime starting with YYYY-MM-DD.
    final prefixed = RegExp(r'^(\d{4})-(\d{2})-(\d{2})[ T]');
    final pm = prefixed.firstMatch(s);
    if (pm != null) {
      final y = int.parse(pm.group(1)!);
      final mo = int.parse(pm.group(2)!);
      final d = int.parse(pm.group(3)!);
      final hour = _hour(s);
      final minute = _minute(s);
      final second = _second(s);
      final hasZone = s.endsWith('Z') ||
          RegExp(r'[+-]\d{2}:?\d{2}$').hasMatch(s);

      // Midnight with no zone → calendar date (Odoo date cast to datetime).
      if (!hasZone && hour == 0 && minute == 0 && second == 0) {
        return DateTime(y, mo, d);
      }

      if (!hasZone) {
        // Naive Odoo create_date is UTC — convert to local calendar day.
        final naive = DateTime.utc(y, mo, d, hour, minute, second);
        final local = naive.toLocal();
        return DateTime(local.year, local.month, local.day);
      }
    }

    // DD/MM/YYYY or D/M/YYYY (India app default).
    final slash = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{4})');
    final sm = slash.firstMatch(s);
    if (sm != null) {
      final a = int.parse(sm.group(1)!);
      final b = int.parse(sm.group(2)!);
      final y = int.parse(sm.group(3)!);
      if (a > 12) return DateTime(y, b, a); // DD/MM
      if (b > 12) return DateTime(y, a, b); // MM/DD
      return DateTime(y, b, a); // prefer DD/MM
    }

    final parsed = DateTime.tryParse(s.replaceFirst(' ', 'T'));
    if (parsed == null) return null;
    final local = parsed.toLocal();
    return DateTime(local.year, local.month, local.day);
  }

  /// Parse API datetime strings while keeping the clock time.
  ///
  /// Use this for ledger timestamps. [parse] always returns midnight so it
  /// can never drive a visible time-of-day.
  static DateTime? parseDateTime(String? raw) {
    final s = (raw ?? '').trim();
    if (s.isEmpty || s == 'false') return null;

    final dateOnly = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');
    final dm = dateOnly.firstMatch(s);
    if (dm != null) {
      return DateTime(
        int.parse(dm.group(1)!),
        int.parse(dm.group(2)!),
        int.parse(dm.group(3)!),
      );
    }

    final prefixed = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?',
    );
    final pm = prefixed.firstMatch(s);
    if (pm != null) {
      final y = int.parse(pm.group(1)!);
      final mo = int.parse(pm.group(2)!);
      final d = int.parse(pm.group(3)!);
      final hour = int.parse(pm.group(4)!);
      final minute = int.parse(pm.group(5)!);
      final second = int.tryParse(pm.group(6) ?? '') ?? 0;
      final hasZone = s.endsWith('Z') ||
          RegExp(r'[+-]\d{2}:?\d{2}$').hasMatch(s);

      if (!hasZone && hour == 0 && minute == 0 && second == 0) {
        return DateTime(y, mo, d);
      }
      if (!hasZone) {
        return DateTime.utc(y, mo, d, hour, minute, second).toLocal();
      }
    }

    final slash = RegExp(
      r'^(\d{1,2})/(\d{1,2})/(\d{4})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?',
    );
    final sm = slash.firstMatch(s);
    if (sm != null) {
      final a = int.parse(sm.group(1)!);
      final b = int.parse(sm.group(2)!);
      final y = int.parse(sm.group(3)!);
      final hour = int.tryParse(sm.group(4) ?? '') ?? 0;
      final minute = int.tryParse(sm.group(5) ?? '') ?? 0;
      final second = int.tryParse(sm.group(6) ?? '') ?? 0;
      final day = a > 12 ? a : (b > 12 ? b : a);
      final month = a > 12 ? b : (b > 12 ? a : b);
      return DateTime(y, month, day, hour, minute, second);
    }

    final parsed = DateTime.tryParse(s.replaceFirst(' ', 'T'));
    return parsed?.toLocal();
  }

  static bool hasClockTime(DateTime? date) {
    if (date == null) return false;
    return date.hour != 0 ||
        date.minute != 0 ||
        date.second != 0 ||
        date.millisecond != 0;
  }

  static String formatTime(DateTime? date) {
    if (!hasClockTime(date)) return '';
    final h = date!.hour;
    final m = date.minute.toString().padLeft(2, '0');
    final period = h >= 12 ? 'PM' : 'AM';
    final hour12 = h % 12 == 0 ? 12 : h % 12;
    return '$hour12:$m $period';
  }

  static int _hour(String s) {
    final m = RegExp(r'[T ](\d{2}):').firstMatch(s);
    return m == null ? 0 : int.tryParse(m.group(1)!) ?? 0;
  }

  static int _minute(String s) {
    final m = RegExp(r'[T ]\d{2}:(\d{2})').firstMatch(s);
    return m == null ? 0 : int.tryParse(m.group(1)!) ?? 0;
  }

  static int _second(String s) {
    final m = RegExp(r'[T ]\d{2}:\d{2}:(\d{2})').firstMatch(s);
    return m == null ? 0 : int.tryParse(m.group(1)!) ?? 0;
  }
}
