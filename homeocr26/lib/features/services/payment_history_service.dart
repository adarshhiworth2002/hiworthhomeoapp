import 'package:flutter/foundation.dart';

import '../../models/invoice_summary_model.dart';
import 'endPoints.dart';
import 'invoice_list_pager.dart';

/// Shared payment-history cache used by list screens, employee performance,
/// invoice detail enrichment, and net-amount row enrichment.
class PaymentHistoryService {
  const PaymentHistoryService._();

  static List<InvoiceSummaryModel>? _invoiceCache;
  static List<Map<String, dynamic>>? _rawCache;
  static DateTime? _cachedAt;
  static Future<List<InvoiceSummaryModel>>? _inFlight;
  static const _cacheTtl = Duration(seconds: 8);
  /// Totals computed on-device (Dis% + expense). Prefer these over Odoo list
  /// amounts when the API still returns MRP-only. Survives [clearCache];
  /// cleared only via [clearTrustedTotals] (logout).
  static final Map<
          int,
          ({double total, double balance, double? subtotal, DateTime at})>
      _trustedTotals = {};
  static const _trustedTtl = Duration(days: 7);
  /// Bumped on trusted upsert so a stale in-flight full fetch cannot wipe
  /// corrected head rows without re-applying overrides.
  static int _trustedEpoch = 0;

  static bool get hasFreshCache =>
      _invoiceCache != null &&
      _cachedAt != null &&
      DateTime.now().difference(_cachedAt!) < _cacheTtl;

  static bool get hasAnyCache =>
      _invoiceCache != null && _invoiceCache!.isNotEmpty;

  static DateTime? get cachedAt => _cachedAt;

  static List<InvoiceSummaryModel>? get cachedInvoices => _invoiceCache;

  static Future<List<InvoiceSummaryModel>> fetchInvoices({
    required String sessionId,
    int? limit,
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && hasFreshCache) {
      return _invoiceCache!;
    }
    if (!forceRefresh && hasAnyCache) {
      // Serve stale immediately; caller can also trigger [refreshHead].
      return _invoiceCache!;
    }

    if (!forceRefresh) {
      final pending = _inFlight;
      if (pending != null) return pending;
    } else {
      // Don't reuse a stale in-flight list after discard/delete.
      final pending = _inFlight;
      if (pending != null) {
        try {
          await pending;
        } catch (_) {}
      }
    }

    final future = _fetchFromApi(sessionId: sessionId);
    _inFlight = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlight, future)) {
        _inFlight = null;
      }
    }
  }

  /// Drop a deleted draft/invoice so live refresh cannot resurrect it.
  static void removeInvoice(int invoiceId) {
    if (invoiceId <= 0) return;
    _trustedTotals.remove(invoiceId);
    final list = _invoiceCache;
    if (list != null) {
      _invoiceCache = list.where((i) => i.id != invoiceId).toList(growable: false);
    }
    final raw = _rawCache;
    if (raw != null) {
      _rawCache = raw
          .where((row) {
            final id = row['id'];
            final n = id is num ? id.toInt() : int.tryParse('$id');
            return n != invoiceId;
          })
          .toList(growable: false);
    }
  }

  /// Patch / insert one invoice so list screens update without a full refetch.
  static void upsertInvoice(InvoiceSummaryModel invoice) {
    final id = invoice.id;
    if (id == null || id <= 0) return;
    if (invoice.total != null) {
      _trustedEpoch++;
      _trustedTotals[id] = (
        total: invoice.total!,
        balance: invoice.balance ?? invoice.total!,
        subtotal: invoice.subtotal,
        at: DateTime.now(),
      );
    }
    final list = List<InvoiceSummaryModel>.from(_invoiceCache ?? const []);
    final idx = list.indexWhere((i) => i.id == id);
    if (idx >= 0) {
      list[idx] = _applyTrustedTotals(list[idx].mergedWith(invoice));
    } else {
      list.insert(0, _applyTrustedTotals(invoice));
    }
    list.sort((a, b) {
      final da = a.invoiceDate ?? '';
      final db = b.invoiceDate ?? '';
      final byDate = db.compareTo(da);
      if (byDate != 0) return byDate;
      return (b.id ?? 0).compareTo(a.id ?? 0);
    });
    _invoiceCache = list;
    _cachedAt = DateTime.now();
  }

  static InvoiceSummaryModel withTrustedTotals(InvoiceSummaryModel inv) =>
      _applyTrustedTotals(inv);

  static List<InvoiceSummaryModel> applyTrustedToList(
    List<InvoiceSummaryModel> invoices,
  ) {
    if (_trustedTotals.isEmpty || invoices.isEmpty) return invoices;
    return invoices.map(_applyTrustedTotals).toList(growable: false);
  }

  static InvoiceSummaryModel _applyTrustedTotals(InvoiceSummaryModel inv) {
    final id = inv.id;
    if (id == null) return inv;
    final trusted = _trustedTotals[id];
    if (trusted == null) return inv;
    if (DateTime.now().difference(trusted.at) > _trustedTtl) {
      _trustedTotals.remove(id);
      return inv;
    }
    // Keep override even when server momentarily matches — next list fetch
    // often flips back to MRP-only totals.
    final bal = trusted.balance;
    if (inv.total != null &&
        (inv.total! - trusted.total).abs() < 0.05 &&
        (inv.balance == null || (inv.balance! - bal).abs() < 0.05) &&
        (trusted.subtotal == null ||
            inv.subtotal == null ||
            (inv.subtotal! - trusted.subtotal!).abs() < 0.05)) {
      return inv;
    }
    return inv.mergedWith(
      InvoiceSummaryModel(
        id: id,
        total: trusted.total,
        balance: bal,
        subtotal: trusted.subtotal,
      ),
    );
  }

  static Future<List<InvoiceSummaryModel>> _fetchFromApi({
    required String sessionId,
  }) async {
    final epochAtStart = _trustedEpoch;
    final result = await InvoiceListPager.fetchAll(
      endpointPath: EndPoint.paymentHistory.path,
      sessionId: sessionId,
    );
    if (result.error != null && result.invoices.isEmpty) {
      return applyTrustedToList(_invoiceCache ?? const []);
    }
    // Stale full-fetch finished after a newer trusted upsert / refreshHead —
    // merge into existing cache instead of wiping corrected head rows.
    if (epochAtStart != _trustedEpoch && _invoiceCache != null) {
      final byId = <int, InvoiceSummaryModel>{};
      for (final inv in result.invoices) {
        final id = inv.id;
        if (id != null) byId[id] = inv;
      }
      final merged = <InvoiceSummaryModel>[];
      final seen = <int>{};
      for (final inv in _invoiceCache!) {
        final id = inv.id;
        if (id == null) {
          merged.add(inv);
          continue;
        }
        seen.add(id);
        merged.add(byId[id] ?? inv);
      }
      for (final inv in result.invoices) {
        final id = inv.id;
        if (id == null || seen.contains(id)) continue;
        merged.add(inv);
      }
      _invoiceCache = applyTrustedToList(merged);
    } else {
      _invoiceCache = applyTrustedToList(result.invoices);
      _rawCache = result.raw;
    }
    _cachedAt = DateTime.now();
    return _invoiceCache!;
  }

  /// Fast live update: reload newest page and merge into cache.
  static Future<List<InvoiceSummaryModel>> refreshHead({
    required String sessionId,
    int limit = InvoiceListPager.pageSize,
  }) async {
    try {
      final page = await InvoiceListPager.fetchPage(
        endpointPath: EndPoint.paymentHistory.path,
        sessionId: sessionId,
        limit: limit,
        offset: 0,
      );
      if (page.error != null || page.invoices.isEmpty) {
        return _invoiceCache ?? const [];
      }

      final byId = <int, InvoiceSummaryModel>{};
      final withoutId = <InvoiceSummaryModel>[];
      final headIds = <int>{};
      for (final inv in page.invoices) {
        final id = inv.id;
        if (id == null) {
          withoutId.add(_applyTrustedTotals(inv));
        } else {
          byId[id] = _applyTrustedTotals(inv);
          headIds.add(id);
        }
      }
      // Drop IDs that used to sit in the head page but are gone now (deleted).
      final old = _invoiceCache ?? const <InvoiceSummaryModel>[];
      final oldHeadIds = <int>{};
      for (var i = 0; i < old.length && i < limit; i++) {
        final id = old[i].id;
        if (id != null) oldHeadIds.add(id);
      }
      for (final inv in old) {
        final id = inv.id;
        if (id == null) {
          withoutId.add(inv);
          continue;
        }
        if (oldHeadIds.contains(id) && !headIds.contains(id)) {
          continue;
        }
        byId.putIfAbsent(id, () => inv);
      }

      final merged = [...byId.values, ...withoutId];
      merged.sort((a, b) {
        final da = a.invoiceDate ?? '';
        final db = b.invoiceDate ?? '';
        final byDate = db.compareTo(da);
        if (byDate != 0) return byDate;
        return (b.id ?? 0).compareTo(a.id ?? 0);
      });

      final rawByKey = <String, Map<String, dynamic>>{};
      for (final row in [...page.raw, ...?_rawCache]) {
        final key =
            '${row['id'] ?? ''}|${row['invoice_number'] ?? row['name'] ?? ''}';
        rawByKey.putIfAbsent(key, () => row);
      }

      final trustedMerged = applyTrustedToList(merged);
      _invoiceCache = trustedMerged;
      _rawCache = rawByKey.values.toList(growable: false);
      _cachedAt = DateTime.now();
      return trustedMerged;
    } catch (e, s) {
      if (kDebugMode) debugPrint('PaymentHistoryService.refreshHead: $e\n$s');
      return applyTrustedToList(_invoiceCache ?? const []);
    }
  }

  static Future<List<Map<String, dynamic>>> fetchRecordMaps({
    required String sessionId,
    int limit = 500,
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _rawCache != null && hasFreshCache) {
      return _rawCache!;
    }
    await fetchInvoices(
      sessionId: sessionId,
      limit: limit,
      forceRefresh: forceRefresh,
    );
    return _rawCache ?? const [];
  }

  /// Warm cache from the home screen so dependent tabs open instantly.
  static Future<void> prefetch(
    String sessionId, {
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && hasAnyCache) return;
    try {
      await fetchInvoices(
        sessionId: sessionId,
        forceRefresh: forceRefresh,
      );
    } catch (e, s) {
      if (kDebugMode) debugPrint('Payment history prefetch: $e\n$s');
    }
  }

  static void clearCache() {
    _invoiceCache = null;
    _rawCache = null;
    _cachedAt = null;
    _inFlight = null;
    // Keep [_trustedTotals] so pull-to-refresh / draft discard cannot snap
    // Customer Invoice section amounts back to Odoo MRP totals.
  }

  static void clearTrustedTotals() {
    _trustedTotals.clear();
    _trustedEpoch++;
  }
}
