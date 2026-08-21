import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/services/invoice_b2b_index.dart';
import '../features/services/payment_history_service.dart';
import '../models/invoice_summary_model.dart';
import '../models/payment_book_model.dart';
import 'customer_invoice_viewmodel.dart';
import 'login_viewmodel.dart';

class PaymentHistoryViewModel extends ChangeNotifier {
  PaymentHistoryViewModel() {
    final cached = PaymentHistoryService.cachedInvoices;
    if (cached != null && cached.isNotEmpty) {
      items = List<InvoiceSummaryModel>.from(cached);
      loading = false;
    }
  }

  bool _disposed = false;
  bool loading = false;
  String error = '';
  List<InvoiceSummaryModel> items = [];
  PaymentBookFilter filter = const PaymentBookFilter();

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
    CustomerInvoiceViewModel.seedFromPaymentHistory();
  }

  Future<void> fetch(
    BuildContext context, {
    bool forceRefresh = false,
    bool silent = false,
  }) async {
    final cached = PaymentHistoryService.cachedInvoices;
    if (cached != null && cached.isNotEmpty) {
      items = List<InvoiceSummaryModel>.from(cached);
      error = '';
      loading = false;
      _notify();
    }

    try {
      final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
      if (!InvoiceB2bIndex.isReady) {
        await InvoiceB2bIndex.loadFromCredentials(
          db: LoginViewmodel.dbName,
          login: loginModel.loginEmail,
          password: loginModel.loginPassword,
        );
      }
      if (!context.mounted) return;
      if (cached != null && cached.isNotEmpty && !forceRefresh) {
        _notify();
        return;
      }

      // Keep existing rows visible while pull-to-refresh runs.
      if (!silent && items.isEmpty) {
        loading = true;
        error = '';
        _notify();
      }

      if (loginModel.sessionId == null || loginModel.sessionId!.isEmpty) {
        error = 'Session expired. Please log in again.';
        return;
      }

      items = await PaymentHistoryService.fetchInvoices(
        sessionId: loginModel.sessionId!,
        forceRefresh: forceRefresh,
      );
      error = '';
    } catch (e, s) {
      if (kDebugMode) debugPrint('$e\n$s');
      error = 'Network error. Please check your connection and try again.';
    } finally {
      loading = false;
      _notify();
    }
  }

  void applyFilter(PaymentBookFilter newFilter) {
    filter = newFilter;
    _notify();
  }

  void clearFilter() {
    filter = const PaymentBookFilter();
    _notify();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  List<InvoiceSummaryModel> visibleOf(List<InvoiceSummaryModel> source) {
    return source.where(filter.matches).toList(growable: false);
  }
}
