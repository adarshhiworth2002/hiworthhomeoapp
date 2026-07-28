import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/cheque_clearance_model.dart';
import '../../models/invoice_summary_model.dart';
import '../../viewModels/login_viewmodel.dart';
import 'odoo_rpc_helper.dart';
import 'payment_history_service.dart';

/// Loads Customer Payment + linked invoice (e.g. PAY/0236 → 0458/2026-27)
/// for cheque detail and payment screens.
class ChequePaymentEnrichment {
  const ChequePaymentEnrichment._();

  static Future<ChequeClearanceModel> enrich(
    BuildContext context,
    ChequeClearanceModel cheque,
  ) async {
    var enriched = cheque;

    try {
      final login = Provider.of<LoginViewmodel>(context, listen: false);
      var sessionId = login.sessionId ?? '';
      final email = (login.loginEmail ?? '').trim();
      final pass = login.loginPassword ?? '';
      if (email.isNotEmpty && pass.isNotEmpty) {
        final webSid = await OdooRpcHelper.cachedWebSessionId(
          db: LoginViewmodel.dbName,
          login: email,
          password: pass,
        );
        if (webSid != null && webSid.isNotEmpty) sessionId = webSid;
      }

      if (sessionId.isNotEmpty) {
        final fromOdoo = await OdooRpcHelper.enrichChequeClearance(
          sessionId,
          cheque,
        );
        if (fromOdoo != null) enriched = fromOdoo;
      }
    } catch (e, s) {
      if (kDebugMode) debugPrint('ChequePaymentEnrichment odoo: $e\n$s');
    }

    if (!context.mounted) return enriched;

    // Only fill gaps from payment-history when Odoo left invoices empty.
    if (enriched.invoices.isNotEmpty) return enriched;

    enriched = await _enrichFromPaymentHistory(context, enriched);
    return enriched;
  }

  static Future<ChequeClearanceModel> _enrichFromPaymentHistory(
    BuildContext context,
    ChequeClearanceModel cheque,
  ) async {
    try {
      final login = Provider.of<LoginViewmodel>(context, listen: false);
      final sid = login.sessionId;
      if (sid == null || sid.isEmpty) return cheque;

      final invoices = await PaymentHistoryService.fetchInvoices(
        sessionId: sid,
        limit: 500,
      );
      final partner = (cheque.partnerName ?? '').trim().toLowerCase();
      if (partner.isEmpty && cheque.invoices.isNotEmpty) return cheque;

      final matches = <InvoiceSummaryModel>[];
      for (final inv in invoices) {
        final customer = (inv.displayCustomer ?? '').trim().toLowerCase();
        if (partner.isNotEmpty &&
            customer.isNotEmpty &&
            (customer.contains(partner) || partner.contains(customer))) {
          matches.add(inv);
          continue;
        }
        // Amount hint: outstanding balance on cheque matches invoice residual.
        final bal = cheque.balance;
        if (bal != null && inv.balance != null && (inv.balance! - bal).abs() < 0.02) {
          if (partner.isEmpty ||
              customer.isEmpty ||
              customer.contains(partner.split(',').first.trim())) {
            matches.add(inv);
          }
        }
      }

      if (matches.isEmpty) return cheque;

      // Prefer exact residual match, then most recent.
      matches.sort((a, b) {
        final aBal = a.balance ?? -1;
        final bBal = b.balance ?? -1;
        final target = cheque.balance ?? -1;
        final aDiff = (aBal - target).abs();
        final bDiff = (bBal - target).abs();
        final cmp = aDiff.compareTo(bDiff);
        if (cmp != 0) return cmp;
        return (b.id ?? 0).compareTo(a.id ?? 0);
      });

      final best = matches.first;
      final linked = ChequeLinkedInvoice(
        number: best.displayNumber,
        invoiceDate: best.invoiceDate,
        total: best.total,
        balance: best.balance,
        payAmount: cheque.displayPaymentAmount,
        status: best.displayPaymentHistoryStatus.isNotEmpty
            ? best.displayPaymentHistoryStatus
            : (best.paymentState ?? best.status),
        responsiblePerson: best.responsiblePerson ?? best.billedBy,
        partnerName: best.displayCustomer,
        narration: best.remarks,
      );

      return cheque.copyWith(
        responsiblePerson:
            cheque.responsiblePerson ?? best.responsiblePerson ?? best.billedBy,
        validatedBy: cheque.validatedBy ?? best.verifiedBy ?? best.billedBy,
        paymentMode: cheque.paymentMode ?? best.paymentMode ?? 'Cheque',
        invoices: cheque.invoices.isNotEmpty ? cheque.invoices : [linked],
        customerPayment: cheque.hasCustomerPayment
            ? cheque.displayCustomerPayment
            : cheque.customerPayment,
      );
    } catch (e, s) {
      if (kDebugMode) debugPrint('enrichFromPaymentHistory: $e\n$s');
      return cheque;
    }
  }
}
