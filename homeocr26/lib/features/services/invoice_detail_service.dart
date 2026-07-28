import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/invoice_summary_model.dart';
import '../../viewModels/login_viewmodel.dart';
import 'odoo_rpc_helper.dart';
import 'payment_history_service.dart';

/// Loads a full customer invoice (header + lines) for the detail screen.
class InvoiceDetailService {
  const InvoiceDetailService._();

  static Future<List<InvoiceSummaryModel>> _paymentHistoryItems(
    String sessionId,
  ) async {
    return PaymentHistoryService.fetchInvoices(sessionId: sessionId, limit: 200);
  }

  static Future<InvoiceSummaryModel> fetchCustomerInvoice(
    BuildContext context, {
    required InvoiceSummaryModel seed,
  }) async {
    final login = Provider.of<LoginViewmodel>(context, listen: false);
    if (login.sessionId == null || login.sessionId!.isEmpty) return seed;

    final needsHistory = _needsPaymentHistory(seed);
    // Always refresh lines from Odoo so supplier qty fields stay current.
    final needsLines = seed.id != null;

    if (!needsHistory && !needsLines) return seed;

    final historyFuture = needsHistory
        ? _enrichFromPaymentHistory(
            sessionId: login.sessionId!,
            seed: seed,
          )
        : Future<InvoiceSummaryModel?>.value(null);

    final odooFuture = needsLines
        ? _loadOdooInvoice(
            flutterSessionId: login.sessionId!,
            db: LoginViewmodel.dbName,
            login: login.loginEmail,
            password: login.loginPassword,
            invoiceId: seed.id!,
          )
        : Future<InvoiceSummaryModel?>.value(null);

    final results = await Future.wait([historyFuture, odooFuture]);

    // Seed first so list bill no. (0514/2026-27) is kept over INV/...
    var merged = seed;
    if (results[0] != null) merged = merged.mergedWith(results[0]!);
    if (results[1] != null) merged = merged.mergedWith(results[1]!);
    return merged;
  }

  static bool _needsPaymentHistory(InvoiceSummaryModel seed) {
    return seed.billedBy == null ||
        seed.taxAmount == null ||
        seed.subtotal == null ||
        seed.total == null;
  }

  static Future<InvoiceSummaryModel?> _loadOdooInvoice({
    required String flutterSessionId,
    required String db,
    String? login,
    String? password,
    required int invoiceId,
  }) async {
    // Always prefer a fresh Odoo web session for line items.
    if (login != null &&
        login.isNotEmpty &&
        password != null &&
        password.isNotEmpty) {
      for (var attempt = 0; attempt < 2; attempt++) {
        if (attempt > 0) {
          OdooRpcHelper.invalidateWebSession();
        }
        final webSid = await OdooRpcHelper.cachedWebSessionId(
          db: db,
          login: login,
          password: password,
        );
        if (webSid == null) continue;

        final fromWeb =
            await OdooRpcHelper.readPharmacyInvoice(webSid, invoiceId);
        if (fromWeb != null && fromWeb.lines.isNotEmpty) return fromWeb;

        // Header-only from web — still useful; try Flutter session for lines.
        if (fromWeb != null) {
          final fromFlutter = await OdooRpcHelper.readPharmacyInvoice(
            flutterSessionId,
            invoiceId,
          );
          if (fromFlutter != null && fromFlutter.lines.isNotEmpty) {
            return fromWeb.mergedWith(fromFlutter);
          }
          return fromWeb;
        }
      }
    }

    return OdooRpcHelper.readPharmacyInvoice(flutterSessionId, invoiceId);
  }

  static Future<InvoiceSummaryModel?> _enrichFromPaymentHistory({
    required String sessionId,
    required InvoiceSummaryModel seed,
  }) async {
    try {
      final items = await _paymentHistoryItems(sessionId);
      for (final item in items) {
        final sameId = seed.id != null && item.id == seed.id;
        final sameNumber = seed.invoiceNumber != null &&
            item.invoiceNumber != null &&
            item.invoiceNumber!.trim() == seed.invoiceNumber!.trim();
        if (sameId || sameNumber) {
          return seed.mergedWith(item);
        }
      }
    } catch (_) {}
    return seed;
  }

  static void clearCache() {
    PaymentHistoryService.clearCache();
    OdooRpcHelper.clearWebSessionCache();
  }
}
