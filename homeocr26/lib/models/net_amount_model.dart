import '../features/services/calendar_date.dart';
import '../features/services/invoice_gst_kind.dart';
import 'invoice_summary_model.dart';

class NetAmountModel {
  const NetAmountModel({
    this.amount,
    this.youGot,
    this.youGave,
    this.currency,
    this.date,
    this.youGotInvoices = const [],
    this.youGaveBills = const [],
    this.raw = const {},
  });

  final double? amount;
  final double? youGot;
  final double? youGave;
  final String? currency;
  final String? date;
  final List<NetAmountRow> youGotInvoices;
  final List<NetAmountRow> youGaveBills;
  final Map<String, dynamic> raw;

  factory NetAmountModel.fromResponse(
    Map<String, dynamic> response, {
    String? section,
  }) {
    final result = response['result'];
    if (result is! Map) {
      return const NetAmountModel();
    }

    final root = Map<String, dynamic>.from(result);
    final dataNode = root['data'];
    final Map<String, dynamic> data = dataNode is Map
        ? Map<String, dynamic>.from(dataNode)
        : root;

    final youGot = _pickDouble(data, const [
      'you_got',
      'you_got_paid',
      'you_got_amount',
      'got',
      'got_amount',
      'paid_in',
      'incoming',
      'credit',
      'receipt_amount',
    ]);
    final youGave = _pickDouble(data, const [
      'you_gave',
      'you_gave_paid',
      'you_gave_amount',
      'gave',
      'gave_amount',
      'paid_out',
      'outgoing',
      'debit',
      'payment_amount',
    ]);
    final amount = _pickDouble(data, const [
      'net_amount',
      'amount',
      'total',
      'total_amount',
      'balance',
      'value',
    ]);

    final gotRows = NetAmountRow.parseList(data, const [
      'you_got_invoices',
      'invoices',
      'customer_invoices',
      'you_got_list',
      'got_invoices',
    ]);
    final gaveRows = NetAmountRow.parseList(data, const [
      'you_gave_bills',
      'bills',
      'supplier_bills',
      'vendor_bills',
      'you_gave_list',
      'gave_bills',
    ]);

    return NetAmountModel(
      amount: amount ??
          (section == 'you_gave' ? youGave : youGot) ??
          youGot ??
          youGave,
      youGot: youGot ?? (section == 'all' || section == 'you_got' ? amount : null),
      youGave: youGave ?? (section == 'you_gave' ? amount : null),
      currency: _pickString(data, const ['currency', 'currency_symbol']),
      date: _pickString(data, const [
        'report_date',
        'date',
        'yesterday',
        'as_of',
      ]),
      youGotInvoices: gotRows,
      youGaveBills: gaveRows,
      raw: data,
    );
  }

  static double? _pickDouble(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      if (!map.containsKey(key)) continue;
      final value = map[key];
      if (value is num) return value.toDouble();
      final parsed = double.tryParse(
        value?.toString().replaceAll(RegExp(r'[,\s₹]'), '') ?? '',
      );
      if (parsed != null) return parsed;
    }
    return null;
  }

  static String? _pickString(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value == null) continue;
      final text = _display(value);
      if (text != null && text.isNotEmpty) return text;
    }
    return null;
  }

  static String? _display(dynamic value) {
    if (value == null) return null;
    if (value is bool) return null;
    if (value is List) {
      if (value.length >= 2) {
        final name = value[1]?.toString().trim();
        if (name != null && name.isNotEmpty && name != 'false') return name;
      }
      return null;
    }
    final text = value.toString().trim();
    if (text.isEmpty || text == 'false') return null;
    return text;
  }
}

/// One row from you_got_invoices / you_gave_bills.
class NetAmountRow {
  const NetAmountRow({
    this.id,
    this.supplier,
    this.customer,
    this.invoiceNumber,
    this.invoicePaid,
    this.invoicePaidFlag = false,
    this.number,
    this.invoiceDate,
    this.expiry,
    this.expiryMedicineBill = false,
    this.verifyStatus,
    this.billedBy,
    this.taxAmount,
    this.balance,
    this.subtotal,
    this.total,
    this.status,
    this.moveState,
    this.paymentState,
    this.isPaid = false,
    this.paymentMode,
    this.advanceAmount,
    this.oldBalance,
    this.isCreditCustomer = false,
    this.sequencePrefix,
    this.invoiceType,
    this.b2bFlag,
  });

  final int? id;
  final String? supplier;
  final String? customer;
  final String? invoiceNumber;
  final String? invoicePaid;
  /// Website "Invoice Paid?" checkbox on You Gave.
  final bool invoicePaidFlag;
  final String? number;
  final String? invoiceDate;
  final String? expiry;
  final bool expiryMedicineBill;
  final String? verifyStatus;
  final String? billedBy;
  final double? taxAmount;
  final double? balance;
  final double? subtotal;
  final double? total;
  final String? status;
  final String? moveState;
  final String? paymentState;
  final bool isPaid;
  final String? paymentMode;
  final double? advanceAmount;
  final double? oldBalance;
  final bool isCreditCustomer;
  final String? sequencePrefix;
  final String? invoiceType;
  final bool? b2bFlag;

  String get displayNumber {
    for (final v in [invoiceNumber, number, invoicePaid]) {
      final t = (v ?? '').trim();
      if (t.isNotEmpty && t != '—') return t;
    }
    return '—';
  }

  /// Customer Invoice-style bucket: `draft` | `open` | `paid` | `cancel`.
  String get sectionKey => toInvoiceSummary().sectionKey;

  String get displayBillStatus {
    switch (sectionKey) {
      case 'paid':
        return 'Paid';
      case 'draft':
        return 'Draft';
      case 'open':
        return 'Open';
      case 'cancel':
        return 'Cancel';
      default:
        final raw = displayPaymentHistoryStatus;
        if (raw.toLowerCase() == 'posted') return 'Open';
        if (raw.toLowerCase().startsWith('cancel')) return 'Cancel';
        return raw;
    }
  }

  /// Amount already collected (total minus open balance).
  double get paidAmount {
    final t = total ?? 0;
    final b = balance ?? 0;
    if (isPaid || invoicePaidFlag) {
      return b.abs() <= 0.0001 ? t : (t - b).clamp(0, t);
    }
    final paid = t - b;
    return paid < 0 ? 0 : paid;
  }

  /// Seed for the shared Cash/Credit Tax Invoice detail (with line items).
  InvoiceSummaryModel toInvoiceSummary({bool asSupplier = false}) {
    final number = displayNumber == '—' ? null : displayNumber;
    return InvoiceSummaryModel(
      id: id,
      invoiceNumber: number,
      customer: asSupplier ? supplier : (customer ?? supplier),
      invoiceDate: invoiceDate,
      expiryMedicineBill: expiryMedicineBill,
      verifyStatus: verifyStatus,
      billedBy: billedBy,
      taxAmount: taxAmount,
      balance: balance,
      subtotal: subtotal,
      total: total,
      status: status,
      moveState: moveState,
      paymentState: paymentState,
      isPaid: isPaid || invoicePaidFlag,
      paymentMode: paymentMode,
      advanceAmount: advanceAmount,
      oldBalance: oldBalance,
      isCreditCustomer: isCreditCustomer,
      sequencePrefix: sequencePrefix,
      invoiceType: invoiceType,
      b2bFlag: b2bFlag,
    );
  }

  factory NetAmountRow.fromInvoice(InvoiceSummaryModel invoice) {
    return NetAmountRow(
      id: invoice.id,
      customer: invoice.displayCustomer ?? invoice.customer,
      invoiceNumber: invoice.displayNumber == 'Unknown'
          ? invoice.invoiceNumber
          : invoice.displayNumber,
      invoiceDate: invoice.invoiceDate,
      billedBy: invoice.billedBy ?? invoice.responsiblePerson,
      taxAmount: invoice.taxAmount,
      balance: invoice.balance,
      subtotal: invoice.subtotal,
      total: invoice.total,
      status: invoice.status,
      moveState: invoice.moveState,
      paymentState: invoice.paymentState,
      isPaid: invoice.isPaid,
      invoicePaidFlag: invoice.isPaid,
      paymentMode: invoice.paymentMode,
      advanceAmount: invoice.advanceAmount,
      oldBalance: invoice.oldBalance,
      isCreditCustomer: invoice.isCreditCustomer,
      sequencePrefix: invoice.sequencePrefix,
      invoiceType: invoice.invoiceType,
      b2bFlag: invoice.b2bFlag,
    );
  }

  /// Prefer API tax; else Total − Subtotal (website parity).
  double? get displayTaxAmount {
    if (taxAmount != null) return taxAmount;
    if (total != null && subtotal != null) {
      final diff = total! - subtotal!;
      if (diff.abs() >= 0.005) return diff;
      return 0;
    }
    return null;
  }

  double? get displayBalance => balance;

  double? get displaySubtotal => subtotal ?? total;

  /// Website Verify Status: Verified | Draft.
  String get displayVerifyStatus {
    final raw = (verifyStatus ?? '').trim().toLowerCase();
    if (raw.isEmpty ||
        raw == 'draft' ||
        raw == 'unverified' ||
        raw == 'false' ||
        raw == '0' ||
        raw == 'no') {
      return 'Draft';
    }
    if (raw == 'verified' ||
        raw == 'verify' ||
        raw == 'true' ||
        raw == '1' ||
        raw == 'yes' ||
        raw.contains('verif')) {
      return 'Verified';
    }
    return _titleCase(verifyStatus!);
  }

  /// Website Status: Paid | Draft | Move to Holding Invoice.
  String get displayPaymentHistoryStatus {
    final raw = (status ?? '').trim().toLowerCase().replaceAll('_', ' ');
    if (raw.contains('hold')) return 'Move to Holding Invoice';
    if (raw == 'paid' || raw == 'payment done' || raw == 'fully paid') {
      return 'Paid';
    }
    if (raw == 'draft') return 'Draft';

    final payment = (paymentState ?? '').toLowerCase().trim();
    final move = (moveState ?? '').toLowerCase().trim();
    if (isPaid || payment == 'paid' || invoicePaidFlag) return 'Paid';
    if (move == 'draft' || payment == 'not_paid') return 'Draft';
    if (raw.isNotEmpty) return _titleCase(status!);
    return 'Draft';
  }

  /// Merge sparse net-amount API rows with full payment-history / invoice-list records.
  static List<NetAmountRow> enrichRows(
    List<NetAmountRow> rows,
    List<Map<String, dynamic>> details,
  ) {
    if (rows.isEmpty || details.isEmpty) return rows;

    final byId = <int, Map<String, dynamic>>{};
    for (final item in details) {
      final id = _asInt(item['id'] ?? item['invoice_id']);
      if (id != null) byId[id] = item;
    }

    return rows.map((row) {
      if (row.id == null) return row;
      final detail = byId[row.id!];
      if (detail == null) return row;
      return row.mergedWith(detail);
    }).toList();
  }

  /// Extract invoice/bill maps from standard Flutter API responses.
  static List<Map<String, dynamic>> extractRecordMaps(
    Map<String, dynamic> response,
  ) {
    final result = response['result'];
    if (result is! Map) return [];

    final root = Map<String, dynamic>.from(result);
    final candidates = <dynamic>[
      root['data'],
      root['payment_history'],
      root['payments'],
      root['invoice_list'],
      root['invoices'],
      root['records'],
      root['items'],
      root['results'],
    ];

    for (final candidate in candidates) {
      if (candidate is List) {
        return candidate
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
      if (candidate is Map) {
        final nested = candidate['payment_history'] ??
            candidate['invoice_list'] ??
            candidate['invoices'] ??
            candidate['records'] ??
            candidate['items'];
        if (nested is List) {
          return nested
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
        }
      }
    }
    return [];
  }

  NetAmountRow mergedWith(Map<String, dynamic> detailJson) {
    final detail = NetAmountRow.fromJson(detailJson);
    return copyWith(
      supplier: detail.supplier ?? supplier,
      customer: detail.customer ?? customer,
      invoiceNumber: detail.invoiceNumber ?? invoiceNumber,
      invoicePaid: detail.invoicePaid ?? invoicePaid,
      invoicePaidFlag: detail.invoicePaidFlag || invoicePaidFlag,
      number: detail.number ?? number,
      invoiceDate: detail.invoiceDate ?? invoiceDate,
      expiry: detail.expiry ?? expiry,
      expiryMedicineBill:
          detail.expiryMedicineBill || expiryMedicineBill,
      verifyStatus: detail.verifyStatus ?? verifyStatus,
      billedBy: detail.billedBy ?? billedBy,
      taxAmount: detail.taxAmount ?? taxAmount,
      balance: detail.balance ?? balance,
      subtotal: detail.subtotal ?? subtotal,
      total: detail.total ?? total,
      status: detail.status ?? status,
      moveState: detail.moveState ?? moveState,
      paymentState: detail.paymentState ?? paymentState,
      isPaid: detail.isPaid || isPaid,
      paymentMode: detail.paymentMode ?? paymentMode,
      advanceAmount: detail.advanceAmount ?? advanceAmount,
      oldBalance: detail.oldBalance ?? oldBalance,
      isCreditCustomer: detail.isCreditCustomer || isCreditCustomer,
      sequencePrefix: detail.sequencePrefix ?? sequencePrefix,
      invoiceType: detail.invoiceType ?? invoiceType,
      b2bFlag: detail.b2bFlag ?? b2bFlag,
    );
  }

  NetAmountRow copyWith({
    int? id,
    String? supplier,
    String? customer,
    String? invoiceNumber,
    String? invoicePaid,
    bool? invoicePaidFlag,
    String? number,
    String? invoiceDate,
    String? expiry,
    bool? expiryMedicineBill,
    String? verifyStatus,
    String? billedBy,
    double? taxAmount,
    double? balance,
    double? subtotal,
    double? total,
    String? status,
    String? moveState,
    String? paymentState,
    bool? isPaid,
    String? paymentMode,
    double? advanceAmount,
    double? oldBalance,
    bool? isCreditCustomer,
    String? sequencePrefix,
    String? invoiceType,
    bool? b2bFlag,
  }) {
    return NetAmountRow(
      id: id ?? this.id,
      supplier: supplier ?? this.supplier,
      customer: customer ?? this.customer,
      invoiceNumber: invoiceNumber ?? this.invoiceNumber,
      invoicePaid: invoicePaid ?? this.invoicePaid,
      invoicePaidFlag: invoicePaidFlag ?? this.invoicePaidFlag,
      number: number ?? this.number,
      invoiceDate: invoiceDate ?? this.invoiceDate,
      expiry: expiry ?? this.expiry,
      expiryMedicineBill: expiryMedicineBill ?? this.expiryMedicineBill,
      verifyStatus: verifyStatus ?? this.verifyStatus,
      billedBy: billedBy ?? this.billedBy,
      taxAmount: taxAmount ?? this.taxAmount,
      balance: balance ?? this.balance,
      subtotal: subtotal ?? this.subtotal,
      total: total ?? this.total,
      status: status ?? this.status,
      moveState: moveState ?? this.moveState,
      paymentState: paymentState ?? this.paymentState,
      isPaid: isPaid ?? this.isPaid,
      paymentMode: paymentMode ?? this.paymentMode,
      advanceAmount: advanceAmount ?? this.advanceAmount,
      oldBalance: oldBalance ?? this.oldBalance,
      isCreditCustomer: isCreditCustomer ?? this.isCreditCustomer,
      sequencePrefix: sequencePrefix ?? this.sequencePrefix,
      invoiceType: invoiceType ?? this.invoiceType,
      b2bFlag: b2bFlag ?? this.b2bFlag,
    );
  }

  static String _titleCase(String value) {
    final t = value.trim();
    if (t.isEmpty) return t;
    return t
        .split(RegExp(r'[\s_]+'))
        .where((p) => p.isNotEmpty)
        .map((p) => p[0].toUpperCase() + p.substring(1).toLowerCase())
        .join(' ');
  }

  factory NetAmountRow.fromJson(Map<String, dynamic> json) {
    // Flatten common nested wrappers from Odoo API.
    final flat = <String, dynamic>{...json};
    for (final nestKey in const [
      'invoice',
      'move',
      'bill',
      'data',
      'record',
    ]) {
      final nested = json[nestKey];
      if (nested is Map) {
        flat.addAll(Map<String, dynamic>.from(nested));
      }
    }

    final moveState = _str(flat, const [
      'state',
      'invoice_state',
      'move_state',
    ]);
    final paymentState = _str(flat, const [
      'payment_state',
      'payment_status',
      'invoice_payment_state',
    ]);
    final isPaid = flat['is_paid'] == true ||
        flat['is_paid'] == 1 ||
        paymentState?.toLowerCase().trim() == 'paid' ||
        _bool(flat, const ['invoice_paid', 'paid']);

    final subtotal = _num(flat, const [
      'subtotal',
      'amount_untaxed',
      'untaxed_amount',
      'amount_untaxed_signed',
      'price_subtotal',
    ]);
    final total = _num(flat, const [
      'total',
      'amount_total',
      'amount',
      'amount_total_signed',
      'price_total',
    ]);
    var taxAmount = _num(flat, const [
      'tax_amount',
      'amount_tax',
      'tax',
      'amount_tax_signed',
      'taxes',
    ]);
    if (taxAmount == null && subtotal != null && total != null) {
      taxAmount = total - subtotal;
    }

    return NetAmountRow(
      id: _asInt(flat['id'] ?? flat['invoice_id'] ?? flat['move_id']),
      supplier: _str(flat, const [
        'supplier',
        'supplier_name',
        'partner_name',
        'partner_id',
        'vendor',
        'vendor_name',
        'partner',
      ]),
      customer: () {
        final c = _str(flat, const [
          'customer',
          'customer_name',
          'partner_name',
          'partner_id',
          'partner',
          'invoice_partner_display_name',
        ]);
        if (c != null && InvoiceSummaryModel.isPlaceholderCustomerName(c)) {
          return null;
        }
        return c;
      }(),
      invoiceNumber: _str(flat, const [
        'invoice_number',
        'invoice_no',
        'invoice_name',
        'name',
        'display_name',
        'move_name',
      ]),
      invoicePaid: _str(flat, const [
        'invoice_paid_name',
        'paid_invoice',
        'payment_invoice',
        'amount_paid_display',
      ]),
      invoicePaidFlag: _bool(flat, const [
        'invoice_paid',
        'is_paid',
        'paid',
      ]),
      number: _str(flat, const [
        'number',
        'supplier_invoice_no',
        'vendor_reference',
        'ref',
        'reference',
        'payment_reference',
        'narration',
        'doc_number',
        'bill_number',
      ]),
      invoiceDate: _str(flat, const [
        'invoice_date',
        'bill_date',
        'date_invoice',
        'invoice_bill_date',
        // Prefer accounting `date` only after real invoice dates.
        // Never use create_date here — it is UTC and shifts the calendar day.
        'date',
      ]),
      expiry: _str(flat, const [
        'expiry',
        'exp_date',
        'invoice_date_due',
        'due_date',
        'expiration_date',
      ]),
      expiryMedicineBill: _bool(flat, const [
        'expiry_medicine_bill',
        'is_expiry_medicine_bill',
      ]),
      verifyStatus: _str(flat, const [
        'verify_status',
        'verification_status',
        'verified_status',
        'verified',
      ]),
      billedBy: _str(flat, const [
        'billed_by',
        'billed_by_name',
        'billed_by_id',
        'responsible_person',
        'responsible_person_name',
        'responsible',
        'invoice_user_id',
        'user_id',
        'create_uid',
        'create_uid_name',
        'salesperson',
        'sales_person',
        'user_name',
        'cashier',
      ]),
      taxAmount: taxAmount,
      balance: _num(flat, const [
            'balance',
            'amount_residual',
            'residual',
            'amount_due',
            'amount_residual_signed',
          ]) ??
          (isPaid ? 0.0 : null),
      subtotal: subtotal,
      total: total,
      status: _str(flat, const [
        'status',
        'bill_status',
        'invoice_status',
        'hold_status',
        'holding_status',
      ]),
      moveState: moveState,
      paymentState: paymentState,
      isPaid: isPaid,
      paymentMode: _str(flat, const [
        'payment_mode',
        'payment_type',
        'journal_type',
      ]),
      // Cash Book / website: only partner-level fields. Generic advance/old
      // keys are often 0 on payment-history rows and would hide real values.
      advanceAmount: _num(flat, const [
        'customer_advance_amount',
      ]),
      oldBalance: _num(flat, const [
        'customer_old_balance',
      ]),
      isCreditCustomer: flat['is_credit_customer'] == true ||
          flat['is_credit_customer'] == 1 ||
          (flat['customer_type']?.toString().toLowerCase().trim() ==
              'credit'),
      sequencePrefix: _str(flat, const [
        'sequence_prefix',
        'invoice_series',
        'series',
        'journal_code',
      ]),
      invoiceType: InvoiceGstKindParser.labelFromJson(flat),
      b2bFlag: InvoiceSummaryModel.b2bFlagFromJson(flat),
    );
  }

  static bool _bool(Map json, List<String> keys) {
    for (final key in keys) {
      if (!json.containsKey(key)) continue;
      final value = json[key];
      if (value == true || value == 1 || value == '1' || value == 'true') {
        return true;
      }
      if (value is String && value.toLowerCase().trim() == 'yes') return true;
    }
    return false;
  }

  static List<NetAmountRow> parseList(
    Map<String, dynamic> data,
    List<String> keys,
  ) {
    for (final key in keys) {
      final value = data[key];
      if (value is! List) continue;
      return value
          .whereType<Map>()
          .map((e) => NetAmountRow.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    return const [];
  }

  static String money(double? value) {
    if (value == null) return '—';
    return value.toStringAsFixed(2);
  }

  /// Website-style date from ISO / Odoo date strings (calendar-safe).
  static String formatDate(String? value) {
    final parsed = CalendarDate.parse(value);
    if (parsed == null) {
      final t = (value ?? '').trim();
      return t.isEmpty ? '—' : t;
    }
    final month = parsed.month.toString().padLeft(2, '0');
    final day = parsed.day.toString().padLeft(2, '0');
    return '$month/$day/${parsed.year}';
  }

  static String text(String? value) {
    if (value == null || value.trim().isEmpty) return '—';
    return value.trim();
  }

  static String? _str(Map json, List<String> keys) {
    for (final key in keys) {
      if (!json.containsKey(key)) continue;
      final text = NetAmountModel._display(json[key]);
      if (text != null && text.isNotEmpty) return text;
    }
    return null;
  }

  static double? _num(Map json, List<String> keys) {
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

  static int? _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }
}
