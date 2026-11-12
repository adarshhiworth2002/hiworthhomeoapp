import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/services/invoice_b2b_index.dart';
import '../features/services/payment_book_service.dart';
import '../features/services/payment_history_service.dart';
import '../models/invoice_summary_model.dart';
import '../models/payment_book_model.dart';
import 'customer_invoice_viewmodel.dart';
import 'login_viewmodel.dart';

class PaymentHistoryViewModel extends ChangeNotifier {
  PaymentHistoryViewModel() {
    final cached = PaymentHistoryService.cachedInvoices;
    if (cached != null && cached.isNotEmpty) {
      _allItems = List<InvoiceSummaryModel>.from(cached);
      items = List<InvoiceSummaryModel>.from(cached);
      loading = false;
    }
  }

  bool _disposed = false;
  bool loading = false;
  String error = '';
  List<InvoiceSummaryModel> items = [];
  List<InvoiceSummaryModel> _allItems = [];
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
    if (filter.isActive && forceRefresh) {
      await applyFilter(context, filter, forceRefresh: true);
      return;
    }

    final cached = PaymentHistoryService.cachedInvoices;
    if (cached != null && cached.isNotEmpty) {
      _allItems = List<InvoiceSummaryModel>.from(cached);
      if (!filter.isActive) {
        items = List<InvoiceSummaryModel>.from(cached);
      }
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

      final loaded = await PaymentHistoryService.fetchInvoices(
        sessionId: loginModel.sessionId!,
        forceRefresh: forceRefresh,
      );
      if (_disposed) return;
      _allItems = List<InvoiceSummaryModel>.from(loaded);
      if (!filter.isActive) {
        items = List<InvoiceSummaryModel>.from(loaded);
      }
      error = '';
    } catch (e, s) {
      if (kDebugMode) debugPrint('$e\n$s');
      error = 'Network error. Please check your connection and try again.';
    } finally {
      loading = false;
      _notify();
    }
  }

  /// Same Search path as Payment Book.
  Future<void> applyFilter(
    BuildContext context,
    PaymentBookFilter newFilter, {
    bool forceRefresh = true,
  }) async {
    filter = newFilter;
    if (!filter.isActive) {
      await clearFilter(context);
      return;
    }

    loading = true;
    error = '';
    _notify();

    try {
      final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
      final sessionId = loginModel.sessionId;
      if (sessionId == null || sessionId.isEmpty) {
        error = 'Session expired. Please log in again.';
        return;
      }
      if (!InvoiceB2bIndex.isReady) {
        await InvoiceB2bIndex.loadFromCredentials(
          db: LoginViewmodel.dbName,
          login: loginModel.loginEmail,
          password: loginModel.loginPassword,
        );
      }
      if (!context.mounted || _disposed) return;

      final book = await PaymentBookService.fetch(
        sessionId: sessionId,
        dateFrom: filter.dateFrom == null
            ? null
            : _formatApiDate(filter.dateFrom!),
        dateTo: filter.dateTo == null ? null : _formatApiDate(filter.dateTo!),
        customer: filter.hasCustomer ? filter.customerQuery.trim() : null,
        customerType: filter.customerTypeApiValue,
        paymentMode: filter.paymentModeApiValue,
        forceRefresh: forceRefresh,
      );
      if (_disposed) return;

      items = PaymentHistoryService.applyTrustedToList(
        book.invoices.where(filter.matches).toList(growable: false),
      );
      error = '';
    } catch (e, s) {
      if (kDebugMode) debugPrint('PaymentHistory applyFilter: $e\n$s');
      error = 'Network error. Please check your connection and try again.';
    } finally {
      loading = false;
      _notify();
    }
  }

  Future<void> clearFilter(BuildContext context) async {
    filter = const PaymentBookFilter();
    items = List<InvoiceSummaryModel>.from(_allItems);
    _notify();
    if (!context.mounted) return;
    unawaited(fetch(context, forceRefresh: true, silent: true));
  }

  static String _formatApiDate(DateTime date) {
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
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
    // When Search is active, [items] is already Payment Book–filtered.
    if (filter.isActive) return source;
    return source.where(filter.matches).toList(growable: false);
  }
}
