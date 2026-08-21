import '../features/services/calendar_date.dart';
import '../features/services/invoice_series_classifier.dart';
import 'invoice_summary_model.dart';

enum PaymentBookCustomerType {
  all,
  credit,
  normal,
  b2b,
  b2c,
}

enum PaymentBookPaymentMode {
  all,
  cash,
  credit,
  cheque,
  card,
  upi,
}

/// Filters for `get_payment_book` (website Payment Book search bar).
class PaymentBookFilter {
  const PaymentBookFilter({
    this.dateFrom,
    this.dateTo,
    this.customerQuery = '',
    this.invoiceQuery = '',
    this.customerType = PaymentBookCustomerType.all,
    this.paymentMode = PaymentBookPaymentMode.all,
  });

  final DateTime? dateFrom;
  final DateTime? dateTo;
  final String customerQuery;
  final String invoiceQuery;
  final PaymentBookCustomerType customerType;
  final PaymentBookPaymentMode paymentMode;

  static DateTime todayDate() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  /// Website default: current date for both From and To.
  factory PaymentBookFilter.today() {
    final d = todayDate();
    return PaymentBookFilter(dateFrom: d, dateTo: d);
  }

  bool get hasCustomer => customerQuery.trim().isNotEmpty;
  bool get hasInvoice => invoiceQuery.trim().isNotEmpty;
  bool get hasCustomerType => customerType != PaymentBookCustomerType.all;
  bool get hasPaymentMode => paymentMode != PaymentBookPaymentMode.all;
  bool get hasDateRange => dateFrom != null || dateTo != null;
  bool get isActive =>
      hasDateRange ||
      hasCustomer ||
      hasInvoice ||
      hasCustomerType ||
      hasPaymentMode;

  PaymentBookFilter copyWith({
    DateTime? dateFrom,
    DateTime? dateTo,
    String? customerQuery,
    String? invoiceQuery,
    PaymentBookCustomerType? customerType,
    PaymentBookPaymentMode? paymentMode,
    bool clearDates = false,
  }) {
    return PaymentBookFilter(
      dateFrom: clearDates ? null : dateFrom ?? this.dateFrom,
      dateTo: clearDates ? null : dateTo ?? this.dateTo,
      customerQuery: customerQuery ?? this.customerQuery,
      invoiceQuery: invoiceQuery ?? this.invoiceQuery,
      customerType: customerType ?? this.customerType,
      paymentMode: paymentMode ?? this.paymentMode,
    );
  }

  bool matches(InvoiceSummaryModel item) {
    if (hasDateRange && !_inDateRange(item.invoiceDate, dateFrom, dateTo)) {
      return false;
    }
    if (hasCustomer &&
        !_containsAny(
          [item.displayCustomer, item.customer],
          customerQuery,
        )) {
      return false;
    }
    if (hasInvoice &&
        !_containsAny(
          [item.displayNumber, item.invoiceNumber],
          invoiceQuery,
        )) {
      return false;
    }
    if (hasCustomerType) {
      if (customerType == PaymentBookCustomerType.credit &&
          !item.isCreditCustomer) {
        return false;
      }
      if (customerType == PaymentBookCustomerType.normal &&
          item.isCreditCustomer) {
        return false;
      }
      if (customerType == PaymentBookCustomerType.b2b &&
          !InvoiceSeriesClassifier.isB2bInvoice(item)) {
        return false;
      }
      if (customerType == PaymentBookCustomerType.b2c &&
          !InvoiceSeriesClassifier.isB2cInvoice(item)) {
        return false;
      }
    }
    if (hasPaymentMode) {
      final expected = paymentModeApiValue!;
      final raw = (item.paymentMode ?? '').toLowerCase().trim();
      if (raw != expected && !raw.contains(expected)) return false;
    }
    return true;
  }

  static bool _containsAny(Iterable<String?> values, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    for (final value in values) {
      if ((value ?? '').toLowerCase().contains(q)) return true;
    }
    return false;
  }

  static bool _inDateRange(String? raw, DateTime? from, DateTime? to) {
    if (from == null && to == null) return true;
    final day = CalendarDate.parse(raw);
    if (day == null) return false;
    if (from != null) {
      final start = DateTime(from.year, from.month, from.day);
      if (day.isBefore(start)) return false;
    }
    if (to != null) {
      final end = DateTime(to.year, to.month, to.day);
      if (day.isAfter(end)) return false;
    }
    return true;
  }

  String get customerTypeLabel {
    switch (customerType) {
      case PaymentBookCustomerType.all:
        return 'All Customers';
      case PaymentBookCustomerType.credit:
        return 'Credit Customers';
      case PaymentBookCustomerType.normal:
        return 'Normal Customers';
      case PaymentBookCustomerType.b2b:
        return 'B2B';
      case PaymentBookCustomerType.b2c:
        return 'B2C';
    }
  }

  String get paymentModeLabel {
    switch (paymentMode) {
      case PaymentBookPaymentMode.all:
        return 'All';
      case PaymentBookPaymentMode.cash:
        return 'Cash';
      case PaymentBookPaymentMode.credit:
        return 'Credit';
      case PaymentBookPaymentMode.cheque:
        return 'Cheque';
      case PaymentBookPaymentMode.card:
        return 'Card';
      case PaymentBookPaymentMode.upi:
        return 'UPI';
    }
  }

  String? get paymentModeApiValue {
    switch (paymentMode) {
      case PaymentBookPaymentMode.all:
        return null;
      case PaymentBookPaymentMode.cash:
        return 'cash';
      case PaymentBookPaymentMode.credit:
        return 'credit';
      case PaymentBookPaymentMode.cheque:
        return 'cheque';
      case PaymentBookPaymentMode.card:
        return 'card';
      case PaymentBookPaymentMode.upi:
        return 'upi';
    }
  }

  String? get customerTypeApiValue {
    switch (customerType) {
      case PaymentBookCustomerType.all:
        return null;
      case PaymentBookCustomerType.credit:
        return 'credit';
      case PaymentBookCustomerType.normal:
        return 'normal';
      case PaymentBookCustomerType.b2b:
        return 'b2b';
      case PaymentBookCustomerType.b2c:
        return 'b2c';
    }
  }

  List<String> get chipParts {
    final parts = <String>[];
    if (hasDateRange) {
      String fmt(DateTime? d) {
        if (d == null) return '…';
        final dd = d.day.toString().padLeft(2, '0');
        final mm = d.month.toString().padLeft(2, '0');
        return '$dd/$mm/${d.year}';
      }
      final from = fmt(dateFrom);
      final to = fmt(dateTo);
      parts.add(from == to ? from : '$from → $to');
    }
    if (hasCustomer) parts.add(customerQuery.trim());
    if (hasInvoice) parts.add(invoiceQuery.trim());
    if (hasCustomerType) parts.add(customerTypeLabel);
    if (hasPaymentMode) parts.add(paymentModeLabel);
    return parts;
  }
}

/// Website-style row color for Payment Book lines.
enum PaymentBookRowStyle {
  /// Walk-in / no customer name.
  walkIn,

  /// Credit customer with open / unpaid balance.
  creditOpen,

  /// Credit customer payment completed.
  creditPaid,

  /// Draft invoice.
  draft,

  /// Cancelled invoice.
  cancel,

  /// Default posted / cash row (same red as walk-in).
  normal,
}

extension PaymentBookInvoiceStyle on InvoiceSummaryModel {
  bool get isWalkInCustomer {
    final raw = (customer ?? '').trim();
    if (raw.isEmpty) return true;
    if (InvoiceSummaryModel.isPlaceholderCustomerName(raw)) return true;
    final lower = raw.toLowerCase();
    return lower == 'walk-in' ||
        lower == 'walk in' ||
        lower == 'walk-in customer' ||
        lower == 'walk in customer' ||
        lower.startsWith('walk-in') ||
        lower.startsWith('walk in');
  }

  bool get isDraftInvoice {
    final move = (moveState ?? '').toLowerCase().trim();
    final raw = (status ?? '').toLowerCase().trim();
    return move == 'draft' || raw == 'draft' || sectionKey == 'draft';
  }

  bool get isCancelledInvoice {
    final move = (moveState ?? status ?? '').toLowerCase().trim();
    return move == 'cancel' ||
        move == 'cancelled' ||
        move == 'canceled' ||
        sectionKey == 'cancel';
  }

  bool get isPaidInvoice {
    if (isPaid) return true;
    final payment = (paymentState ?? '').toLowerCase().trim();
    final raw = (status ?? '').toLowerCase().trim();
    if (payment == 'paid' || raw == 'paid' || raw == 'payment done') {
      return true;
    }
    final bal = balance;
    if (bal != null && bal <= 0.0001 && !isDraftInvoice && !isCancelledInvoice) {
      return true;
    }
    return sectionKey == 'paid';
  }

  PaymentBookRowStyle get paymentBookRowStyle {
    if (isCancelledInvoice) return PaymentBookRowStyle.cancel;
    // Draft wins (website greys draft rows even when name is blank).
    if (isDraftInvoice) return PaymentBookRowStyle.draft;
    if (isWalkInCustomer) return PaymentBookRowStyle.walkIn;
    if (isCreditCustomer) {
      return isPaidInvoice
          ? PaymentBookRowStyle.creditPaid
          : PaymentBookRowStyle.creditOpen;
    }
    return PaymentBookRowStyle.normal;
  }

  String get displayPaymentBookStatus {
    final raw = (status ?? moveState ?? '').trim();
    if (raw.isEmpty) return displayStatus.toLowerCase();
    return raw.toLowerCase();
  }

  String get displayPaymentBookName {
    if (isWalkInCustomer) {
      final raw = (customer ?? '').trim();
      if (raw.isNotEmpty &&
          !InvoiceSummaryModel.isPlaceholderCustomerName(raw)) {
        return raw;
      }
      return 'Walk-in Customer';
    }
    return displayCustomer ?? '—';
  }

  String get displayPaymentBookDate {
    final parsed = CalendarDate.parse(invoiceDate);
    if (parsed != null) return CalendarDate.dmy(parsed);
    final raw = (invoiceDate ?? '').trim();
    return raw.isEmpty ? '—' : raw;
  }
}

/// Summary + invoice list from `POST /api/flutter/get_payment_book/`.
class PaymentBookModel {
  const PaymentBookModel({
    this.cardName,
    this.dateFrom,
    this.dateTo,
    this.homeCount = 0,
    this.totalCount = 0,
    this.totalBalance,
    this.totalAmount,
    this.invoices = const [],
  });

  final String? cardName;
  final String? dateFrom;
  final String? dateTo;
  final int homeCount;
  final int totalCount;
  final double? totalBalance;
  final double? totalAmount;
  final List<InvoiceSummaryModel> invoices;

  bool get isEmpty => invoices.isEmpty;

  factory PaymentBookModel.fromResponse(Map<String, dynamic> response) {
    final data = _extractData(response);
    if (data.isEmpty) return const PaymentBookModel();

    final invoices = <InvoiceSummaryModel>[];
    final raw = data['invoices'];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          invoices.add(
            InvoiceSummaryModel.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }

    return PaymentBookModel(
      cardName: _string(data['card_name']),
      dateFrom: _string(data['date_from']),
      dateTo: _string(data['date_to']),
      homeCount: _int(data['home_count']) ?? invoices.length,
      totalCount: _int(data['total_count']) ?? invoices.length,
      totalBalance: _num(data['total_balance']),
      totalAmount: _num(data['total_amount']),
      invoices: invoices,
    );
  }

  static Map<String, dynamic> _extractData(Map<String, dynamic> response) {
    final result = response['result'];
    if (result is Map) {
      final root = Map<String, dynamic>.from(result);
      final dataNode = root['data'];
      if (dataNode is Map) {
        return Map<String, dynamic>.from(dataNode);
      }
      if (root.containsKey('invoices') || root.containsKey('card_name')) {
        return root;
      }
    }
    final data = response['data'];
    if (data is Map) {
      return Map<String, dynamic>.from(data);
    }
    if (response.containsKey('invoices') || response.containsKey('card_name')) {
      return response;
    }
    return const {};
  }

  static String? _string(dynamic value) {
    if (value == null || value == false) return null;
    final text = value.toString().trim();
    if (text.isEmpty || text == 'false') return null;
    return text;
  }

  static int? _int(dynamic value) {
    if (value == null || value == false || value == true) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  static double? _num(dynamic value) {
    if (value == null || value == false || value == true) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }
}
