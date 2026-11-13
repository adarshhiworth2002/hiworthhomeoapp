import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists first-seen wall-clock times for Cash Book invoices and payments.
///
/// Laravel list payloads often send date-only stamps (no clock). The app
/// records when each id first appeared so ledger order does not reshuffle.
class CashBookSeenAtStore {
  CashBookSeenAtStore._();

  static const _prefsKey = 'cash_book_seen_at_v1';

  static final Map<int, DateTime> sales = {};
  static final Map<int, DateTime> payments = {};

  static bool _loaded = false;
  static bool _prefsUnavailable = false;
  static bool _dirty = false;

  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    if (_prefsUnavailable) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      _readBucket(decoded['sales'], sales);
      _readBucket(decoded['payments'], payments);
    } catch (e) {
      _prefsUnavailable = true;
      if (kDebugMode) debugPrint('CashBookSeenAtStore load: $e');
    }
  }

  static void _readBucket(dynamic raw, Map<int, DateTime> into) {
    if (raw is! Map) return;
    for (final e in raw.entries) {
      final id = int.tryParse(e.key.toString());
      if (id == null) continue;
      final ms = e.value is num
          ? (e.value as num).toInt()
          : int.tryParse(e.value?.toString() ?? '');
      if (ms == null || ms <= 0) continue;
      into[id] = DateTime.fromMillisecondsSinceEpoch(ms);
    }
  }

  static Future<void> persist() async {
    if (!_dirty || _prefsUnavailable) return;
    _dirty = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsKey,
        jsonEncode({
          'sales': {
            for (final e in sales.entries) '${e.key}': e.value.millisecondsSinceEpoch,
          },
          'payments': {
            for (final e in payments.entries)
              '${e.key}': e.value.millisecondsSinceEpoch,
          },
        }),
      );
    } catch (e) {
      _prefsUnavailable = true;
      _dirty = true;
      if (kDebugMode) debugPrint('CashBookSeenAtStore persist: $e');
    }
  }

  /// Remember [at] for [id] only if we have never seen it before.
  static DateTime rememberSale(int id, DateTime at) {
    final existing = sales[id];
    if (existing != null) return existing;
    sales[id] = at;
    _dirty = true;
    return at;
  }

  static DateTime rememberPayment(int id, DateTime at) {
    final existing = payments[id];
    if (existing != null) return existing;
    payments[id] = at;
    _dirty = true;
    return at;
  }

  static DateTime? saleAt(int id) => sales[id];

  static DateTime? paymentAt(int id) => payments[id];
}
