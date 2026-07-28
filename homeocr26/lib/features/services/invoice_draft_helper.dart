import 'package:flutter/foundation.dart';

import 'odoo_rpc_helper.dart';

export 'odoo_rpc_helper.dart' show InvoiceDraftResult;

/// Creates an empty customer invoice draft via Odoo (fast path).
///
/// Flutter `add_to_invoice` generate-only calls return "Item not found" on this
/// server, so we skip them and create `account.move` directly.
class InvoiceDraftHelper {
  /// Returns the created bill id + pharmacy number (e.g. `0620/2026-27`).
  static Future<InvoiceDraftResult?> createEmptyDraft({
    required String sessionId,
    required Set<String> knownNumbers,
    String? login,
    String? password,
    String db = 'HOMEO_JULY',
  }) async {
    try {
      var odooSid = sessionId;
      final email = (login ?? '').trim();
      final pass = password ?? '';
      if (email.isNotEmpty && pass.isNotEmpty) {
        final webSid = await OdooRpcHelper.cachedWebSessionId(
          db: db,
          login: email,
          password: pass,
        );
        if (webSid != null && webSid.isNotEmpty) odooSid = webSid;
      }

      return OdooRpcHelper.createEmptyCustomerInvoiceDraft(odooSid);
    } catch (e) {
      if (kDebugMode) debugPrint('empty_draft failed: $e');
      return null;
    }
  }
}
