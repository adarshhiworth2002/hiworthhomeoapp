import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../viewModels/cheque_clearance_viewmodel.dart';
import '../../viewModels/customer_invoice_viewmodel.dart';
import '../../viewModels/employee_performance_viewmodel.dart';
import '../../viewModels/login_viewmodel.dart';
import '../../viewModels/net_amount_viewmodel.dart';
import '../../viewModels/payment_book_viewmodel.dart';
import '../../viewModels/payment_history_viewmodel.dart';
import '../../viewModels/stock_viewmodel.dart';
import 'invoice_b2b_index.dart';
import 'odoo_rpc_helper.dart';
import 'payment_history_service.dart';

/// Prefetches data for all home tiles after login / live sync.
class HomePrefetchService {
  const HomePrefetchService._();

  /// Fast pull-to-refresh for the home grid.
  /// Updates the visible Net Amount tile immediately, then warms other
  /// sections in the background so the spinner is not blocked by stock /
  /// invoice / employee catalog fetches.
  static Future<void> refreshHome(
    BuildContext context, {
    required NetAmountViewModel netAmountViewModel,
  }) async {
    await netAmountViewModel.fetchAmountsOnly(
      context,
      forceRefresh: true,
      silent: true,
    );

    if (!context.mounted) return;

    // Background warm — RefreshIndicator already completed.
    unawaited(
      warmAll(
        context,
        netAmountViewModel: netAmountViewModel,
        forceRefresh: true,
        includeNetAmount: false,
      ),
    );
  }

  static Future<void> warmAll(
    BuildContext context, {
    NetAmountViewModel? netAmountViewModel,
    bool forceRefresh = false,
    bool includeNetAmount = true,
  }) async {
    final login = Provider.of<LoginViewmodel>(context, listen: false);
    final sessionId = login.sessionId;
    if (sessionId == null || sessionId.isEmpty) return;

    if (forceRefresh) {
      if (includeNetAmount) {
        netAmountViewModel?.clearInstanceCache();
      }
    }

    // Authenticate Odoo web session first (needed for invoice line items).
    // Running it in parallel with heavy stock probes caused connection drops.
    if (login.loginEmail != null &&
        login.loginEmail!.isNotEmpty &&
        login.loginPassword != null &&
        login.loginPassword!.isNotEmpty) {
      final webSid = await OdooRpcHelper.cachedWebSessionId(
        db: LoginViewmodel.dbName,
        login: login.loginEmail!,
        password: login.loginPassword!,
      );
      if (webSid != null && webSid.isNotEmpty) {
        unawaited(InvoiceB2bIndex.load(webSid));
      }
    }

    if (!context.mounted) return;

    await Future.wait([
      if (includeNetAmount && netAmountViewModel != null)
        netAmountViewModel.fetchBoth(
          context,
          silent: true,
          forceRefresh: forceRefresh,
        ),
      CustomerInvoiceViewModel.prefetchCatalog(
        context,
        forceRefresh: false,
      ),
      PaymentHistoryViewModel.prefetch(
        context,
        forceRefresh: forceRefresh && !PaymentHistoryService.hasAnyCache,
      ),
      PaymentBookViewModel.prefetch(
        context,
        forceRefresh: forceRefresh,
      ),
      ChequeClearanceViewModel.prefetch(
        context,
        forceRefresh: forceRefresh,
      ),
      EmployeePerformanceViewModel.prefetch(
        context,
        forceRefresh: forceRefresh,
      ),
      StockViewModel.prefetchFirstPage(
        context,
        forceRefresh: forceRefresh,
      ),
    ]);
  }
}
