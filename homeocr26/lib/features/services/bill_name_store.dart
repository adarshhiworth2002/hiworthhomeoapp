import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists names created in New Bill (Customer / Doctor) for next suggestions.
/// Falls back to in-memory if the shared_preferences plugin is unavailable
/// (e.g. hot-reload after adding the dependency — needs full app restart).
class BillNameStore {
  static const _customersKey = 'bill_custom_customers';
  static const _doctorsKey = 'bill_custom_doctors';

  static final List<String> _memoryCustomers = [];
  static final List<String> _memoryDoctors = [];
  static bool _prefsUnavailable = false;

  static Future<List<String>> loadCustomers() => _load(
        _customersKey,
        _memoryCustomers,
      );

  static Future<List<String>> loadDoctors() => _load(
        _doctorsKey,
        _memoryDoctors,
      );

  static Future<void> rememberCustomer(String name) => _remember(
        _customersKey,
        _memoryCustomers,
        name,
      );

  static Future<void> rememberDoctor(String name) => _remember(
        _doctorsKey,
        _memoryDoctors,
        name,
      );

  static Future<List<String>> _load(String key, List<String> memory) async {
    if (_prefsUnavailable) {
      return List<String>.from(memory);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getStringList(key) ?? const <String>[];
      for (final name in stored) {
        final t = name.trim();
        if (t.isEmpty) continue;
        if (!memory.any((e) => e.toLowerCase() == t.toLowerCase())) {
          memory.add(t);
        }
      }
      return List<String>.from(memory);
    } catch (e) {
      _prefsUnavailable = true;
      if (kDebugMode) {
        debugPrint('BillNameStore prefs unavailable, using memory: $e');
      }
      return List<String>.from(memory);
    }
  }

  static Future<void> _remember(
    String key,
    List<String> memory,
    String name,
  ) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final lower = trimmed.toLowerCase();
    if (!memory.any((e) => e.toLowerCase() == lower)) {
      memory.add(trimmed);
      memory.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    }

    if (_prefsUnavailable) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final current = prefs.getStringList(key) ?? <String>[];
      if (!current.any((e) => e.toLowerCase() == lower)) {
        current.add(trimmed);
        current.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        await prefs.setStringList(key, current);
      }
    } catch (e) {
      _prefsUnavailable = true;
      if (kDebugMode) {
        debugPrint('BillNameStore prefs unavailable, using memory: $e');
      }
    }
  }
}
