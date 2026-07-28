import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/invoice_summary_model.dart';

/// Local "Settled" bills on Payment History — swipe to settle / restore.
/// Survives logout/login (not cleared with session caches).
class SettledPaymentStore {
  SettledPaymentStore._();

  static const _prefsKey = 'payment_history_settled_v1';

  static final Map<String, Map<String, dynamic>> _memory = {};
  static bool _loaded = false;
  static bool _prefsUnavailable = false;

  /// Stable key for an invoice (id preferred, else bill number).
  static String keyFor(InvoiceSummaryModel invoice) {
    if (invoice.id != null && invoice.id! > 0) {
      return 'id:${invoice.id}';
    }
    final no = invoice.displayNumber.trim();
    if (no.isNotEmpty && no.toLowerCase() != 'unknown') {
      return 'no:${no.toLowerCase()}';
    }
    return 'hash:${invoice.hashCode}';
  }

  static bool matchesKey(InvoiceSummaryModel invoice, String key) {
    return keyFor(invoice) == key;
  }

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
      for (final e in decoded.entries) {
        final k = e.key.toString();
        final v = e.value;
        if (v is Map) {
          _memory[k] = Map<String, dynamic>.from(v);
        }
      }
    } catch (e) {
      _prefsUnavailable = true;
      if (kDebugMode) debugPrint('SettledPaymentStore load: $e');
    }
  }

  static Future<void> _persist() async {
    if (_prefsUnavailable) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(_memory));
    } catch (e) {
      _prefsUnavailable = true;
      if (kDebugMode) debugPrint('SettledPaymentStore persist: $e');
    }
  }

  static Future<Set<String>> settledKeys() async {
    await ensureLoaded();
    return _memory.keys.toSet();
  }

  static Future<bool> isSettled(InvoiceSummaryModel invoice) async {
    await ensureLoaded();
    return _memory.containsKey(keyFor(invoice));
  }

  static Future<void> settle(InvoiceSummaryModel invoice) async {
    await ensureLoaded();
    final key = keyFor(invoice);
    _memory[key] = _snapshot(invoice);
    await _persist();
  }

  static Future<void> restore(InvoiceSummaryModel invoice) async {
    await ensureLoaded();
    _memory.remove(keyFor(invoice));
    await _persist();
  }

  static Future<void> restoreByKey(String key) async {
    await ensureLoaded();
    _memory.remove(key);
    await _persist();
  }

  /// Settled invoices for UI. Prefer live API row when present; else snapshot.
  static Future<List<InvoiceSummaryModel>> settledInvoices(
    List<InvoiceSummaryModel> liveItems,
  ) async {
    await ensureLoaded();
    if (_memory.isEmpty) return const [];

    final byKey = <String, InvoiceSummaryModel>{
      for (final inv in liveItems) keyFor(inv): inv,
    };

    final out = <InvoiceSummaryModel>[];
    for (final e in _memory.entries) {
      final live = byKey[e.key];
      if (live != null) {
        out.add(live);
        continue;
      }
      try {
        out.add(InvoiceSummaryModel.fromJson(e.value));
      } catch (err) {
        if (kDebugMode) debugPrint('SettledPaymentStore parse: $err');
      }
    }

    out.sort((a, b) {
      final da = (a.invoiceDate ?? '').compareTo(b.invoiceDate ?? '');
      if (da != 0) return -da;
      return b.displayNumber.compareTo(a.displayNumber);
    });
    return out;
  }

  static Map<String, dynamic> _snapshot(InvoiceSummaryModel inv) {
    return {
      if (inv.id != null) 'id': inv.id,
      if (inv.invoiceNumber != null) 'invoice_number': inv.invoiceNumber,
      if (inv.customer != null) 'customer_name': inv.customer,
      if (inv.pharmacyCustomerId != null)
        'pharmacy_customer_id': inv.pharmacyCustomerId,
      if (inv.invoiceDate != null) 'invoice_date': inv.invoiceDate,
      if (inv.balance != null) 'amount_residual': inv.balance,
      if (inv.subtotal != null) 'amount_untaxed': inv.subtotal,
      if (inv.total != null) 'amount_total': inv.total,
      if (inv.taxAmount != null) 'amount_tax': inv.taxAmount,
      if (inv.status != null) 'status': inv.status,
      if (inv.moveState != null) 'state': inv.moveState,
      if (inv.paymentState != null) 'payment_state': inv.paymentState,
      'is_paid': inv.isPaid,
      if (inv.paymentMode != null) 'payment_mode': inv.paymentMode,
      'settled_locally': true,
      'settled_at': DateTime.now().toIso8601String(),
    };
  }
}
