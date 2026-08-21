import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/services/calendar_date.dart';
import '../features/services/payment_book_service.dart';
import '../models/invoice_summary_model.dart';
import '../models/payment_book_model.dart';
import 'login_viewmodel.dart';

class PaymentBookViewModel extends ChangeNotifier {
  bool loading = false;
  String error = '';
  PaymentBookModel book = const PaymentBookModel();
  PaymentBookFilter filter = PaymentBookFilter.today();

  List<InvoiceSummaryModel> get invoices => book.invoices;

  /// Extra client-side pass for search typing (prefix).
  List<InvoiceSummaryModel> get visibleInvoices {
    return book.invoices
        .where(filter.matches)
        .toList(growable: false);
  }

  static Future<PaymentBookModel> prefetch(
    BuildContext context, {
    bool forceRefresh = false,
  }) async {
    final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
    final sessionId = loginModel.sessionId;
    if (sessionId == null || sessionId.isEmpty) {
      return const PaymentBookModel();
    }
    await PaymentBookService.prefetch(
      sessionId,
      forceRefresh: forceRefresh,
    );
    return PaymentBookService.cachedBook ?? const PaymentBookModel();
  }

  void applyFilter(PaymentBookFilter newFilter) {
    filter = newFilter;
    notifyListeners();
  }

  /// Clears all filters (including today’s date) and refreshes in the background.
  void clearFilter(BuildContext context) {
    filter = const PaymentBookFilter();
    notifyListeners();
    unawaited(
      fetch(context, forceRefresh: true, silent: true),
    );
  }

  Future<void> fetch(
    BuildContext context, {
    bool forceRefresh = false,
    bool silent = false,
    PaymentBookFilter? applyFilter,
  }) async {
    if (applyFilter != null) {
      filter = applyFilter;
      notifyListeners();
    }

    try {
      if (!silent) {
        loading = true;
        error = '';
        notifyListeners();
      }

      final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
      if (loginModel.sessionId == null || loginModel.sessionId!.isEmpty) {
        error = 'Session expired. Please log in again.';
        return;
      }

      book = await PaymentBookService.fetch(
        sessionId: loginModel.sessionId!,
        dateFrom: filter.dateFrom == null
            ? null
            : _formatApiDate(filter.dateFrom!),
        dateTo:
            filter.dateTo == null ? null : _formatApiDate(filter.dateTo!),
        customer: filter.hasCustomer ? filter.customerQuery.trim() : null,
        customerType: filter.customerTypeApiValue,
        paymentMode: filter.paymentModeApiValue,
        forceRefresh: forceRefresh,
      );

      // Prefer server dates when present; otherwise keep filter dates.
      final apiFrom = _parseApiDate(book.dateFrom) ?? filter.dateFrom;
      final apiTo = _parseApiDate(book.dateTo) ?? filter.dateTo;
      filter = filter.copyWith(dateFrom: apiFrom, dateTo: apiTo);
      error = '';
    } catch (e, s) {
      if (kDebugMode) debugPrint('$e\n$s');
      error = 'Network error. Please check your connection and try again.';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  static String _formatApiDate(DateTime date) {
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  static DateTime? _parseApiDate(String? raw) {
    return CalendarDate.parse(raw);
  }

  static String formatAmount(double? value) {
    if (value == null) return '—';
    final isWhole = value == value.roundToDouble();
    final number =
        isWhole ? value.toInt().toString() : value.toStringAsFixed(2);
    return '₹$number';
  }

  static String formatDisplayDate(DateTime? date) {
    if (date == null) return '—';
    final d = date.day.toString().padLeft(2, '0');
    final m = date.month.toString().padLeft(2, '0');
    return '$d/$m/${date.year}';
  }
}
