import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/services/payment_book_service.dart';
import '../features/services/prefix_search.dart';
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
    var list = List<InvoiceSummaryModel>.from(book.invoices);

    if (filter.hasCustomer) {
      final q = filter.customerQuery.trim();
      list = list
          .where(
            (item) => PrefixSearch.matchesAny(
              [
                item.displayCustomer,
                item.customer,
                item.displayNumber,
                item.invoiceNumber,
              ],
              q,
            ),
          )
          .toList(growable: false);
    }

    if (filter.hasCustomerType) {
      list = list.where((item) {
        switch (filter.customerType) {
          case PaymentBookCustomerType.all:
            return true;
          case PaymentBookCustomerType.credit:
            return item.isCreditCustomer;
          case PaymentBookCustomerType.normal:
            return !item.isCreditCustomer;
        }
      }).toList(growable: false);
    }

    if (filter.hasPaymentMode) {
      final mode = filter.paymentModeApiValue!;
      list = list.where((item) {
        final raw = (item.paymentMode ?? '').toLowerCase().trim();
        return raw == mode || raw.contains(mode);
      }).toList(growable: false);
    }

    return list;
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

  Future<void> fetch(
    BuildContext context, {
    bool forceRefresh = false,
    bool silent = false,
    PaymentBookFilter? applyFilter,
  }) async {
    if (applyFilter != null) {
      filter = applyFilter;
    }

    try {
      if (!silent) {
        loading = true;
        error = '';
        if (book.isEmpty) {
          notifyListeners();
        }
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

  Future<void> resetToToday(BuildContext context) async {
    await fetch(
      context,
      forceRefresh: true,
      applyFilter: PaymentBookFilter.today(),
    );
  }

  static String _formatApiDate(DateTime date) {
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  static DateTime? _parseApiDate(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final iso = DateTime.tryParse(raw.trim());
    if (iso != null) return DateTime(iso.year, iso.month, iso.day);
    final parts = raw.trim().split(RegExp(r'[/-]'));
    if (parts.length == 3) {
      final d = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      final y = int.tryParse(parts[2]);
      if (d != null && m != null && y != null) {
        return DateTime(y, m, d);
      }
    }
    return null;
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
