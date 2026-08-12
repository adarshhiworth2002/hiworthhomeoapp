import 'package:flutter/foundation.dart';

import 'odoo_rpc_helper.dart';

/// Restores pharmacy stock when a QR-added product is removed from a bill.
class InvoiceStockRestoreHelper {
  /// Returns true when the server stock / invoice line was reversed.
  ///
  /// Note: `add_to_invoice` with negative quantity often returns success
  /// without restoring `entry.stock` — do not use that path.
  static Future<bool> restoreAfterLineDelete({
    required String flutterSessionId,
    required String invoiceNumber,
    required double quantity,
    int? invoiceId,
    String? productName,
    String? batch,
    String? potency,
    int? stockEntryId,
    String? login,
    String? password,
    String db = 'HOMEO_JULY',
  }) async {
    final inv = invoiceNumber.trim();
    final qty = quantity;
    if ((inv.isEmpty && invoiceId == null) || qty <= 0) return false;

    try {
      var sid = flutterSessionId;
      final email = (login ?? '').trim();
      final pass = password ?? '';
      if (email.isNotEmpty && pass.isNotEmpty) {
        final webSid = await OdooRpcHelper.cachedWebSessionId(
          db: db,
          login: email,
          password: pass,
        );
        if (webSid != null && webSid.isNotEmpty) sid = webSid;
      }

      return await OdooRpcHelper.removeCustomerInvoiceProduct(
        sessionId: sid,
        invoiceNumber: inv,
        invoiceId: invoiceId,
        productName: (productName ?? '').trim(),
        batch: batch,
        potency: potency,
        quantity: qty,
        stockEntryId: stockEntryId,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('restoreAfterLineDelete odoo failed: $e');
      return false;
    }
  }
}
