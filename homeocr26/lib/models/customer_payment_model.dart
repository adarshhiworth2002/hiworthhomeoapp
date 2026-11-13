import '../features/services/calendar_date.dart';

/// One invoice that a customer payment was allocated against.
class CustomerPaymentInvoice {
  const CustomerPaymentInvoice({
    this.invoiceId,
    this.number = '',
    this.allocatedAmount = 0,
    this.total,
    this.balance,
    this.balanceDue,
    this.balanceAfter,
    this.selected,
    this.status = '',
    this.responsiblePerson,
    this.paymentMode,
    this.invoiceDate,
  });

  final int? invoiceId;
  final String number;
  final double allocatedAmount;
  final double? total;
  /// Preferred residual to show on the payment bill row (after this pay).
  final double? balance;
  final double? balanceDue;
  final double? balanceAfter;
  /// Laravel detail `selected` — false means open bill listed, not paid here.
  final bool? selected;
  final String status;
  final String? responsiblePerson;
  final String? paymentMode;
  final String? invoiceDate;

  factory CustomerPaymentInvoice.fromJson(Map<String, dynamic> json) {
    final allocated = _paymentNum(json, const [
          'amount_to_pay',
          'allocated_amount',
          'pay_amount',
          'paid_amount',
          'amount_paid',
          'reconciled_amount',
          'payment_amount',
        ]) ??
        0;
    final total = _paymentNum(json, const [
      'total',
      'amount_total',
      'invoice_total',
    ]);
    final balanceDue = _paymentNum(json, const [
      'balance_due',
      'amount_residual',
      'residual',
    ]);
    final balanceAfter = _paymentNum(json, const [
      'balance_after',
      'balance_remaining',
      'remaining_balance',
    ]);
    // Website payment table "Balance" = remaining after this allocation.
    // Never fall back to bill total — that made Total and Balance look identical.
    double? balance = balanceAfter;
    if (balance == null && balanceDue != null) {
      balance = balanceDue - allocated;
      if (balance < 0) balance = 0;
    }
    balance ??= _paymentNum(json, const ['balance']);
    if (balance != null &&
        total != null &&
        allocated > 0.0001 &&
        (balance - total).abs() < 0.0001) {
      // Stale payload copied total into balance — derive remaining instead.
      final due = balanceDue ?? total;
      final remaining = due - allocated;
      balance = remaining < 0 ? 0 : remaining;
    }

    return CustomerPaymentInvoice(
      // Never use payment-line `id` — that is the line row, not the invoice.
      invoiceId: _paymentAsInt(json['invoice_id'] ?? json['move_id']),
      number: _paymentStr(json, const [
            'invoice_number',
            'invoice_name',
            'move_name',
            'number',
            'name',
            'display_name',
          ]) ??
          '',
      allocatedAmount: allocated,
      total: total,
      balance: balance,
      balanceDue: balanceDue,
      balanceAfter: balanceAfter,
      selected: _paymentBool(json['selected']),
      status: _paymentStr(json, const [
            'status',
            'payment_state',
            'state',
          ]) ??
          '',
      responsiblePerson: _paymentStr(json, const [
        'responsible_person',
        'billed_by',
        'billed_by_name',
      ]),
      paymentMode: _paymentStr(json, const [
        'payment_mode',
        'journal_type',
      ]),
      invoiceDate: _paymentStr(json, const [
        'invoice_date',
        'date',
      ]),
    );
  }
}

/// One customer payment from `get_customer_payment_list`.
class CustomerPaymentRecord {
  const CustomerPaymentRecord({
    this.id,
    this.name = '',
    this.customerName = '',
    this.amount = 0,
    this.dateTime,
    this.paymentMode,
    this.advanceAmount,
    this.oldBalance,
    this.invoices = const [],
  });

  final int? id;
  final String name;
  final String customerName;
  final double amount;
  final DateTime? dateTime;
  final String? paymentMode;
  /// Partner advance on the payment form (`advance_amt`).
  final double? advanceAmount;
  /// Partner old balance on the payment form (`old_balance`).
  final double? oldBalance;
  final List<CustomerPaymentInvoice> invoices;

  CustomerPaymentRecord copyWith({
    DateTime? dateTime,
    List<CustomerPaymentInvoice>? invoices,
    double? advanceAmount,
    double? oldBalance,
  }) {
    return CustomerPaymentRecord(
      id: id,
      name: name,
      customerName: customerName,
      amount: amount,
      dateTime: dateTime ?? this.dateTime,
      paymentMode: paymentMode,
      advanceAmount: advanceAmount ?? this.advanceAmount,
      oldBalance: oldBalance ?? this.oldBalance,
      invoices: invoices ?? this.invoices,
    );
  }

  /// Amount this voucher actually applied to [inv] (never invents other bills).
  static double effectiveAllocation(
    CustomerPaymentInvoice inv,
    CustomerPaymentRecord payment,
  ) {
    if (inv.allocatedAmount > 0.0001) return inv.allocatedAmount;
    if (inv.selected == false) return 0;
    final candidates = payment.invoices
        .where((i) => i.selected != false)
        .toList(growable: false);
    if (candidates.length == 1 && identical(candidates.first, inv)) {
      return payment.amount > 0.0001 ? payment.amount : 0;
    }
    if (inv.selected == null && payment.invoices.length == 1) {
      return payment.amount > 0.0001 ? payment.amount : 0;
    }
    return 0;
  }

  factory CustomerPaymentRecord.fromJson(Map<String, dynamic> json) {
    final nested = _nestedInvoices(json);
    // Laravel sends the cash received on this voucher as `received_amount`.
    // That value is this payment only — never add it to an older payment
    // or to an invoice's cumulative paid total.
    final received = _paymentNum(json, const ['received_amount']);
    final amount = (received != null && received > 0.0001)
        ? received
        : (_paymentNum(json, const [
              'amount',
              'payment_amount',
              'amount_total',
              'paid_amount',
              'total',
              'credit',
            ]) ??
            nested.fold<double>(0, (sum, inv) => sum + inv.allocatedAmount));

    final payment = CustomerPaymentRecord(
      id: _paymentAsInt(json['id'] ?? json['payment_id'] ?? json['partner_payment_id']),
      name: _paymentStr(json, const [
            'name',
            'payment_name',
            'payment_number',
            'display_name',
            'payment_ref',
          ]) ??
          '',
      customerName: _paymentStr(json, const [
            'customer_name',
            'partner_name',
            'customer',
            'partner_id',
            'partner',
          ]) ??
          '',
      amount: amount,
      dateTime: CalendarDate.parseDateTime(
        _paymentStr(json, const [
          'create_date',
          'created_at',
          'datetime',
          'payment_datetime',
          'write_date',
          'payment_date',
          'date',
        ]),
      ),
      paymentMode: _paymentStr(json, const [
        'payment_mode',
        'journal_type',
        'payment_type',
        'journal_id',
      ]),
      advanceAmount: _paymentNum(json, const [
        'advance_amt',
        'customer_advance_amount',
        'advance_amount',
        'advance',
      ]),
      oldBalance: _paymentNum(json, const [
        'old_balance',
        'customer_old_balance',
        'previous_balance',
        'opening_balance',
      ]),
      invoices: nested,
    );
    return payment.copyWith(
      invoices: onlyAllocatedInvoices(payment),
    );
  }

  /// Detail API lists every open invoice; keep only lines this pay touched.
  static List<CustomerPaymentInvoice> onlyAllocatedInvoices(
    CustomerPaymentRecord payment,
  ) {
    if (payment.invoices.isEmpty) return payment.invoices;
    final kept = payment.invoices
        .where((inv) => effectiveAllocation(inv, payment) > 0.0001)
        .toList(growable: false);
    return kept.isNotEmpty ? kept : const [];
  }

  static List<CustomerPaymentRecord> parseList(Map<String, dynamic> response) {
    final records = _extractMaps(response);
    final payments = <CustomerPaymentRecord>[];
    for (final raw in records) {
      if (_inactivePaymentState(raw)) continue;
      final payment = CustomerPaymentRecord.fromJson(raw);
      if (payment.amount <= 0.0001 && payment.invoices.isEmpty) continue;
      if (_looksLikeInvoiceNotPayment(raw, payment)) continue;
      payments.add(payment);
    }
    return payments;
  }

  static bool _inactivePaymentState(Map<String, dynamic> raw) {
    final state = '${raw['state'] ?? raw['status'] ?? ''}'.trim().toLowerCase();
    return state == 'cancelled' ||
        state == 'cancel' ||
        state == 'canceled' ||
        state == 'bounced' ||
        state == 'rejected';
  }

  static bool _looksLikeInvoiceNotPayment(
    Map<String, dynamic> raw,
    CustomerPaymentRecord payment,
  ) {
    if (payment.invoices.isNotEmpty) return false;
    final name = payment.name.toUpperCase();
    if (name.startsWith('PAY') || name.startsWith('PMT')) return false;
    final hasInvoiceNumber = raw.containsKey('invoice_number') ||
        raw.containsKey('amount_residual');
    final hasPaymentHint = raw.containsKey('payment_amount') ||
        raw.containsKey('payment_id') ||
        raw.containsKey('partner_payment_id') ||
        raw.containsKey('reconciled_invoice_ids') ||
        raw.containsKey('invoice_ids');
    return hasInvoiceNumber && !hasPaymentHint;
  }

  static List<CustomerPaymentInvoice> _nestedInvoices(
    Map<String, dynamic> json,
  ) {
    final candidates = <dynamic>[
      json['invoices'],
      json['invoice_ids'],
      json['linked_invoices'],
      json['invoice_list'],
      json['reconciled_invoice_ids'],
      json['reconciled_invoices'],
      json['invoice_lines'],
      json['lines'], // get_customer_payment detail
      json['bills'],
    ];
    for (final candidate in candidates) {
      if (candidate is! List) continue;
      final parsed = candidate
          .whereType<Map>()
          .map((e) => CustomerPaymentInvoice.fromJson(
                Map<String, dynamic>.from(e),
              ))
          .where((e) => e.number.trim().isNotEmpty || e.allocatedAmount > 0)
          .toList(growable: false);
      if (parsed.isNotEmpty) return parsed;
    }

    final singleNo = _paymentStr(json, const [
      'invoice_number',
      'invoice_name',
      'move_name',
    ]);
    if (singleNo == null || singleNo.isEmpty) return const [];
    return [
      CustomerPaymentInvoice(
        invoiceId: _paymentAsInt(json['invoice_id'] ?? json['move_id']),
        number: singleNo,
        allocatedAmount: _paymentNum(json, const [
              'amount_to_pay',
              'allocated_amount',
              'pay_amount',
              'paid_amount',
              'amount',
            ]) ??
            0,
        total: _paymentNum(json, const ['invoice_total', 'amount_total', 'total']),
        balance: _paymentNum(json, const ['balance', 'amount_residual']),
      ),
    ];
  }

  static List<Map<String, dynamic>> _extractMaps(Map<String, dynamic> response) {
    final result = response['result'];
    final root = result is Map
        ? Map<String, dynamic>.from(result)
        : Map<String, dynamic>.from(response);
    final dataNode = root['data'];
    final data = dataNode is Map
        ? Map<String, dynamic>.from(dataNode)
        : root;

    final candidates = <dynamic>[
      data['payments'],
      data['customer_payments'],
      data['payment_list'],
      data['records'],
      data['items'],
      data['results'],
      if (dataNode is List) dataNode,
      root['payments'],
      root['customer_payments'],
      root['records'],
    ];
    for (final candidate in candidates) {
      if (candidate is! List) continue;
      return candidate
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    return const [];
  }
}

String? _paymentStr(Map json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value == null || value == false) continue;
    if (value is num) continue;
    if (value is List && value.length >= 2) {
      final name = value[1]?.toString().trim();
      if (name == null || name.isEmpty || name == 'false') continue;
      return name;
    }
    final text = value.toString().trim();
    if (text.isEmpty || text == 'false') continue;
    return text;
  }
  return null;
}

double? _paymentNum(Map json, List<String> keys) {
  for (final key in keys) {
    if (!json.containsKey(key)) continue;
    final value = json[key];
    if (value is num) return value.toDouble();
    final parsed = double.tryParse(
      value?.toString().replaceAll(RegExp(r'[,\s₹]'), '') ?? '',
    );
    if (parsed != null) return parsed;
  }
  return null;
}

int? _paymentAsInt(dynamic value) {
  if (value == null || value == false || value == true) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString());
}

bool? _paymentBool(dynamic value) {
  if (value == null) return null;
  if (value is bool) return value;
  if (value == 1 || value == '1' || value == 'true' || value == 'True') {
    return true;
  }
  if (value == 0 || value == '0' || value == 'false' || value == 'False') {
    return false;
  }
  return null;
}
