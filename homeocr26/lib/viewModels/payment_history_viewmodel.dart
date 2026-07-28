import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/services/payment_history_service.dart';
import '../models/invoice_summary_model.dart';
import 'login_viewmodel.dart';

class PaymentHistoryViewModel extends ChangeNotifier {
  bool loading = false;
  String error = '';
  List<InvoiceSummaryModel> items = [];

  static Future<void> prefetch(
    BuildContext context, {
    bool forceRefresh = false,
  }) async {
    final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
    final sessionId = loginModel.sessionId;
    if (sessionId == null || sessionId.isEmpty) return;
    await PaymentHistoryService.prefetch(
      sessionId,
      forceRefresh: forceRefresh,
    );
  }

  Future<void> fetch(
    BuildContext context, {
    bool forceRefresh = false,
    bool silent = false,
  }) async {
    if (!forceRefresh && PaymentHistoryService.hasFreshCache) {
      items = List<InvoiceSummaryModel>.from(
        PaymentHistoryService.cachedInvoices ?? const [],
      );
      error = '';
      notifyListeners();
      return;
    }

    try {
      if (!silent) {
        loading = true;
        error = '';
        if (items.isEmpty) {
          notifyListeners();
        }
      }

      final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
      if (loginModel.sessionId == null || loginModel.sessionId!.isEmpty) {
        error = 'Session expired. Please log in again.';
        return;
      }

      items = await PaymentHistoryService.fetchInvoices(
        sessionId: loginModel.sessionId!,
        limit: 200,
        forceRefresh: forceRefresh,
      );
      error = '';
    } catch (e, s) {
      if (kDebugMode) debugPrint('$e\n$s');
      error = 'Network error. Please check your connection and try again.';
    } finally {
      loading = false;
      notifyListeners();
    }
  }
}
