import '../features/services/invoice_calc_helper.dart';
import '../features/services/invoice_gst_kind.dart';

class InvoiceLineModel {
  const InvoiceLineModel({
    this.id,
    this.productName,
    this.potency,
    this.company,
    this.batch,
    this.manufacturer,
    this.mfd,
    this.expiry,
    this.packing,
    this.group,
    this.qty,
    this.orderedQty,
    this.freeQty,
    this.mrp,
    this.discount,
    this.dis2Percent,
    this.unit,
    this.unitPrice,
    this.uPrice,
    this.tax,
    this.taxAmount,
    this.total,
    this.hsn,
    this.rack,
  });

  final int? id;
  final String? productName;
  final String? potency;
  final String? company;
  final String? batch;
  final String? manufacturer;
  /// Manufacture date (website column MFD).
  final String? mfd;
  final String? expiry;
  final String? packing;
  final String? group;
  /// Received Qty on supplier (You Gave) bills; Qty on customer bills.
  final double? qty;
  /// Supplier invoice: Ordered Qty.
  final double? orderedQty;
  /// Supplier invoice: Free Qty.
  final double? freeQty;
  final double? mrp;
  final double? discount;
  /// Supplier invoice: Dis2(%).
  final double? dis2Percent;
  final String? unit;
  final double? unitPrice;
  /// Supplier invoice: U Price (falls back to [unitPrice] when absent).
  final double? uPrice;
  final double? tax;
  final double? taxAmount;
  final double? total;
  final String? hsn;
  final String? rack;

  /// Received Qty alias used by You Gave / supplier line UI.
  double? get receivedQty => qty;

  /// Display unit price for supplier lines.
  double? get displayUPrice => uPrice ?? unitPrice;

  factory InvoiceLineModel.fromJson(Map<String, dynamic> json) {
    return InvoiceLineModel(
      id: json['id'] is int
          ? json['id'] as int
          : int.tryParse('${json['id']}'),
      productName: _str(json, const [
        'product_name',
        'product_id_name',
        'medicine_id_name',
        'product',
        'display_name',
        'name',
      ]),
      potency: _str(json, const [
        'potency',
        'potency_id_name',
        'potency_name',
        'power',
        'drug_potency',
      ]),
      company: _str(json, const [
        'company',
        'pharmacy_company_id_name',
        'comp',
        'medicine_company',
        'brand',
        'company_name',
      ]),
      batch: _str(json, const [
        'batch',
        'batch_no',
        'batch_id',
        'lot',
        'lot_name',
        'lot_id_name',
      ]),
      manufacturer: _str(json, const [
        'manufacturer',
        'manuf',
        'manf',
      ]),
      mfd: _str(json, const [
        'mfd',
        'mfd_date',
        'manufacturing_date',
      ]),
      expiry: _str(json, const [
        'expiry',
        'expiry_date',
        'exp_date',
        'expiration_date',
      ]),
      packing: _str(json, const [
        'packing',
        'pack_id_name',
        'pack',
        'pack_size',
      ]),
      group: _str(json, const [
        'group',
        'pharmacy_group_id_name',
        'medicine_group',
        'product_group',
        'group_id_name',
      ]),
      qty: _num(json, const ['qty', 'quantity', 'product_uom_qty', 'received_qty']),
      orderedQty: _num(json, const ['ordered_qty', 'ordered_quantity']),
      freeQty: _num(json, const ['free_qty', 'free_quantity']),
      mrp: _num(json, const ['mrp']),
      discount: _num(json, const ['discount', 'dis', 'discount_percent']),
      dis2Percent: _num(json, const ['dis2_percent', 'dis2', 'discount2']),
      unit: _str(json, const [
        'unit',
        'uom',
        'uom_name',
        'product_uom_id_name',
      ]),
      unitPrice: _num(json, const [
        'unit_price',
        'price_unit',
        'unit_p',
        'unitP',
      ]),
      uPrice: _num(json, const ['u_price', 'uprice']),
      tax: _num(json, const ['tax', 'tax_percent', 'tax_rate', 'gst']),
      taxAmount: _num(json, const [
        'tax_amount',
        'amount_tax',
        'tax_amt',
        'taxAmt',
      ]),
      total: _num(json, const [
        'price_total',
        'total',
        'price_subtotal',
        'amount_total',
        'line_total',
      ]),
      hsn: _str(json, const ['hsn', 'hsn_code']),
      rack: _str(json, const [
        'rack',
        'rack_id_name',
        'rack_no',
        'location',
      ]),
    );
  }

  static String? _str(Map json, List<String> keys) {
    for (final key in keys) {
      final value = json[key];
      if (value == null || value == false) continue;
      if (value is List && value.length >= 2) {
        final name = value[1]?.toString().trim() ?? '';
        if (name.isNotEmpty && name != 'false') return name;
        continue;
      }
      final text = value.toString().trim();
      if (text.isNotEmpty && text != 'false') return text;
    }
    return null;
  }

  static double? _num(Map json, List<String> keys) {
    for (final key in keys) {
      final value = json[key];
      if (value is num) return value.toDouble();
      final parsed = double.tryParse(value?.toString() ?? '');
      if (parsed != null) return parsed;
    }
    return null;
  }
}

class InvoiceSummaryModel {
  const InvoiceSummaryModel({
    this.id,
    this.invoiceNumber,
    this.customer,
    this.pharmacyCustomerId,
    this.address,
    this.phone,
    this.responsiblePerson,
    this.doctor,
    this.invoiceDate,
    this.expiryMedicineBill = false,
    this.verifyStatus,
    this.billedBy,
    this.taxAmount,
    this.balance,
    this.subtotal,
    this.discountTotal,
    this.total,
    this.supplierInvoiceNo,
    this.poNumber,
    this.supplierInvoiceAmount,
    this.previousInvoice,
    this.deliveryDate,
    this.status,
    this.moveState,
    this.paymentState,
    this.isPaid = false,
    this.paymentMode,
    this.advanceAmount,
    this.oldBalance,
    this.gstType,
    this.discountCategory,
    this.discountType,
    this.discountRate,
    this.verifiedBy,
    this.expense,
    this.expenseAmt,
    this.remarks,
    this.workMinutes,
    this.workHours,
    this.isCreditCustomer = false,
    this.sequencePrefix,
    this.invoiceType,
    this.b2bFlag,
    this.lines = const [],
  });

  final int? id;
  final String? invoiceNumber;
  final String? customer;
  final int? pharmacyCustomerId;
  final String? address;
  final String? phone;
  final String? responsiblePerson;
  final String? doctor;
  final String? invoiceDate;
  final bool expiryMedicineBill;
  final String? verifyStatus;
  final String? billedBy;
  final double? taxAmount;
  final double? balance;
  final double? subtotal;
  final double? discountTotal;
  final double? total;
  /// You Gave / supplier bill: Invoice No (supplier_invoice_no).
  final String? supplierInvoiceNo;
  /// You Gave: PO Number.
  final String? poNumber;
  /// You Gave: Inv Amount.
  final double? supplierInvoiceAmount;
  /// You Gave: Previous Invoice.
  final String? previousInvoice;
  /// You Gave: Delivery Date.
  final String? deliveryDate;
  /// Raw status string from API (best-effort). Prefer [sectionKey] / [displayStatus].
  final String? status;
  /// Odoo `account.move` state: draft / posted / cancel.
  final String? moveState;
  /// Odoo payment_state: not_paid / partial / in_payment / paid / …
  final String? paymentState;
  final bool isPaid;
  final String? paymentMode;
  final double? advanceAmount;
  final double? oldBalance;
  final String? gstType;
  final String? discountCategory;
  final String? discountType;
  final double? discountRate;
  final String? verifiedBy;
  final String? expense;
  final double? expenseAmt;
  final String? remarks;
  final String? workMinutes;
  final String? workHours;
  final bool isCreditCustomer;
  /// Backend sequence / journal series (`A`, `R`, …) when provided.
  final String? sequencePrefix;
  /// Backend bill type when provided (`b2b`, `b2c`, GST treatment, …).
  final String? invoiceType;
  /// Explicit B2B (`true`) / B2C (`false`) flag from the API, if any.
  final bool? b2bFlag;
  final List<InvoiceLineModel> lines;

  String get displayNumber => invoiceNumber?.trim().isNotEmpty == true
      ? invoiceNumber!.trim()
      : 'Unknown';

  static InvoiceSummaryModel? matchInList(
    List<InvoiceSummaryModel> items,
    InvoiceSummaryModel seed,
  ) {
    if (seed.id != null) {
      for (final item in items) {
        if (item.id == seed.id) return item;
      }
    }
    final number = seed.displayNumber.trim().toLowerCase();
    if (number.isEmpty || number == 'unknown') return null;
    for (final item in items) {
      if (item.displayNumber.trim().toLowerCase() == number) return item;
    }
    return null;
  }

  /// Website footer totals — prefer API values; recompute from lines when needed.
  InvoiceCalcResult websiteTotals() {
    final expense = expenseAmt ?? 0;
    if (lines.isNotEmpty) {
      final calc = InvoiceCalcHelper.compute(
        lines: lines
            .map(
              (line) => InvoiceCalcLine(
                qty: line.qty ?? 0,
                mrp: line.mrp ?? line.total ?? 0,
                discountPercent: line.discount ?? 0,
                unitP: line.unitPrice ?? 0,
                taxPercent: line.tax ?? 0,
              ),
            )
            .toList(),
        discountType: discountType,
        discountRate: discountRate ?? 0,
        gstType: gstType,
        expenseAmt: expense,
      );

      final lineSubtotal = lines.fold<double>(
        0,
        (sum, line) => sum + (line.total ?? 0),
      );
      final lineTax = lines.fold<double>(
        0,
        (sum, line) => sum + (line.taxAmount ?? 0),
      );

      return InvoiceCalcResult(
        subtotal: subtotal ?? (lineSubtotal > 0 ? lineSubtotal : calc.subtotal),
        discountTotal: discountTotal ?? calc.discountTotal,
        tax: taxAmount ?? (lineTax > 0 ? lineTax : calc.tax),
        taxAmount: taxAmount ?? (lineTax > 0 ? lineTax : calc.taxAmount),
        expenseAmt: expense,
        total: total ?? calc.total,
        balance: balance ?? total ?? calc.balance,
        untaxed: calc.untaxed,
      );
    }

    return InvoiceCalcResult(
      subtotal: subtotal ?? 0,
      discountTotal: discountTotal ?? 0,
      tax: taxAmount ?? 0,
      taxAmount: taxAmount ?? 0,
      expenseAmt: expense,
      total: total ?? 0,
      balance: balance ?? total ?? 0,
      untaxed: (subtotal ?? 0) - (taxAmount ?? 0),
    );
  }

  InvoiceSummaryModel mergedWith(InvoiceSummaryModel other) {
    return InvoiceSummaryModel(
      id: id ?? other.id,
      invoiceNumber: _preferPharmacyInvoiceNumber(
        invoiceNumber,
        other.invoiceNumber,
      ),
      customer: other.customer ?? customer,
      pharmacyCustomerId: other.pharmacyCustomerId ?? pharmacyCustomerId,
      address: other.address ?? address,
      phone: other.phone ?? phone,
      responsiblePerson: other.responsiblePerson ?? responsiblePerson,
      doctor: other.doctor ?? doctor,
      invoiceDate: other.invoiceDate ?? invoiceDate,
      expiryMedicineBill:
          other.expiryMedicineBill || expiryMedicineBill,
      verifyStatus: other.verifyStatus ?? verifyStatus,
      billedBy: other.billedBy ?? billedBy,
      taxAmount: other.taxAmount ?? taxAmount,
      balance: other.balance ?? balance,
      subtotal: other.subtotal ?? subtotal,
      discountTotal: other.discountTotal ?? discountTotal,
      total: other.total ?? total,
      supplierInvoiceNo: other.supplierInvoiceNo ?? supplierInvoiceNo,
      poNumber: other.poNumber ?? poNumber,
      supplierInvoiceAmount:
          other.supplierInvoiceAmount ?? supplierInvoiceAmount,
      previousInvoice: other.previousInvoice ?? previousInvoice,
      deliveryDate: other.deliveryDate ?? deliveryDate,
      status: other.status ?? status,
      moveState: other.moveState ?? moveState,
      paymentState: other.paymentState ?? paymentState,
      isPaid: other.isPaid || isPaid,
      paymentMode: other.paymentMode ?? paymentMode,
      advanceAmount: other.advanceAmount ?? advanceAmount,
      oldBalance: other.oldBalance ?? oldBalance,
      gstType: other.gstType ?? gstType,
      discountCategory: other.discountCategory ?? discountCategory,
      discountType: other.discountType ?? discountType,
      discountRate: other.discountRate ?? discountRate,
      verifiedBy: other.verifiedBy ?? verifiedBy,
      expense: other.expense ?? expense,
      expenseAmt: other.expenseAmt ?? expenseAmt,
      remarks: other.remarks ?? remarks,
      workMinutes: other.workMinutes ?? workMinutes,
      workHours: other.workHours ?? workHours,
      isCreditCustomer: other.isCreditCustomer || isCreditCustomer,
      sequencePrefix: other.sequencePrefix ?? sequencePrefix,
      invoiceType: other.invoiceType ?? invoiceType,
      b2bFlag: other.b2bFlag ?? b2bFlag,
      lines: other.lines.isNotEmpty ? other.lines : lines,
    );
  }

  /// Website-aligned customer label. When no partner is set, Odoo stores
  /// `invoice_partner_display_name` as `#Created by: Administrator` — blank.
  String? get displayCustomer {
    final raw = (customer ?? '').trim();
    if (raw.isEmpty) return null;
    if (isPlaceholderCustomerName(raw)) return null;
    return raw;
  }

  /// True for Odoo defaults / computed placeholders (not a real customer).
  static bool isPlaceholderCustomerName(String? name) {
    var n = (name ?? '').trim().toLowerCase();
    if (n.isEmpty) return true;
    // Odoo: "#Created by: Administrator" / "Created by: Admin"
    n = n.replaceFirst(RegExp(r'^#\s*'), '');
    if (n.contains('created by')) return true;
    if (n.startsWith('@from:')) return true;
    return n == 'administrator' ||
        n == 'admin' ||
        n == 'false' ||
        n == 'odoobot' ||
        n == 'public user' ||
        n == 'default user';
  }

  /// Matches website filters: `draft` | `open` | `paid` | `cancel`.
  /// Paid invoices stay `state: posted` with `payment_state: paid` / `is_paid: true`.
  String get sectionKey {
    final move = (moveState ?? status ?? '').toLowerCase().trim();
    final payment = (paymentState ?? '').toLowerCase().trim();

    if (move == 'cancel' ||
        move == 'cancelled' ||
        move == 'canceled' ||
        payment == 'cancelled' ||
        payment == 'canceled') {
      return 'cancel';
    }
    if (isPaid ||
        payment == 'paid' ||
        move == 'paid' ||
        verifyStatus?.toLowerCase().trim() == 'paid') {
      return 'paid';
    }
    if (move == 'draft') return 'draft';
    if (move == 'posted' ||
        move == 'open' ||
        payment == 'not_paid' ||
        payment == 'partial' ||
        payment == 'in_payment') {
      return 'open';
    }
    if (move.isEmpty && payment.isEmpty) return 'unknown';
    return move.isNotEmpty ? move : payment;
  }

  /// Website-aligned label: Draft / Open / Paid / Cancel.
  String get displayStatus {
    switch (sectionKey) {
      case 'draft':
        return 'Draft';
      case 'open':
        return 'Open';
      case 'paid':
        return 'Paid';
      case 'cancel':
        return 'Cancel';
      default:
        final raw = (status ?? moveState ?? paymentState ?? '').trim();
        if (raw.isEmpty) return 'Unknown';
        if (raw.toLowerCase() == 'posted') return 'Open';
        if (raw.toLowerCase().startsWith('cancel')) return 'Cancel';
        return _titleCase(raw);
    }
  }

  /// Totals for footer: when [includeCancel] is false (All tab), cancel bills
  /// are excluded so the bottom total is net of cancelled invoices.
  static double sumTotals(
    Iterable<InvoiceSummaryModel> items, {
    bool includeCancel = false,
  }) {
    var sum = 0.0;
    for (final item in items) {
      if (!includeCancel && item.sectionKey == 'cancel') continue;
      sum += item.total ?? 0;
    }
    return sum;
  }

  static double sumBalances(
    Iterable<InvoiceSummaryModel> items, {
    bool includeCancel = false,
  }) {
    var sum = 0.0;
    for (final item in items) {
      if (!includeCancel && item.sectionKey == 'cancel') continue;
      sum += item.balance ?? 0;
    }
    return sum;
  }

  static int countBills(
    Iterable<InvoiceSummaryModel> items, {
    bool includeCancel = false,
  }) {
    var n = 0;
    for (final item in items) {
      if (!includeCancel && item.sectionKey == 'cancel') continue;
      n++;
    }
    return n;
  }

  /// Payment History → Verify Status column: Verified | Draft.
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

  /// Payment History → Status column:
  /// Paid | Draft | Move to Holding Invoice (website values).
  String get displayPaymentHistoryStatus {
    final raw = (status ?? '').trim().toLowerCase().replaceAll('_', ' ');
    if (raw.contains('hold')) return 'Move to Holding Invoice';
    if (raw == 'paid' || raw == 'payment done' || raw == 'fully paid') {
      return 'Paid';
    }
    if (raw == 'draft') return 'Draft';

    // Fallbacks when API omits website `status` but sends payment/move flags.
    final payment = (paymentState ?? '').toLowerCase().trim();
    final move = (moveState ?? '').toLowerCase().trim();
    if (isPaid || payment == 'paid') return 'Paid';
    if (move == 'draft' || payment == 'not_paid') return 'Draft';
    if (raw.isNotEmpty) return _titleCase(status!);
    return 'Draft';
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

  factory InvoiceSummaryModel.fromJson(Map<String, dynamic> json) {
    final linesNode = json['invoice_lines'] ??
        json['order_lines'] ??
        json['lines'] ??
        json['line_ids'] ??
        json['products'];
    final lines = <InvoiceLineModel>[];
    if (linesNode is List) {
      for (final item in linesNode) {
        if (item is Map) {
          lines.add(InvoiceLineModel.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }

    final moveState = _str(json, const [
      'state',
      'invoice_state',
      'move_state',
    ]);
    final paymentState = _str(json, const [
      'payment_state',
      'payment_status',
    ]);
    final isPaid = json['is_paid'] == true ||
        json['is_paid'] == 1 ||
        paymentState?.toLowerCase().trim() == 'paid';

    return InvoiceSummaryModel(
      id: _asInt(json['id'] ?? json['invoice_id']),
      invoiceNumber: _parseInvoiceNumber(json),
      customer: () {
        final c = _str(json, const [
          'customer',
          'customer_name',
          'partner_name',
          'invoice_partner_display_name',
          'partner_id_name',
          'partner',
        ]);
        if (c != null && InvoiceSummaryModel.isPlaceholderCustomerName(c)) {
          return null;
        }
        return c;
      }(),
      pharmacyCustomerId: _asInt(
        json['pharmacy_customer_id'] ??
            json['customer_id'] ??
            (json['partner_id'] is num ? json['partner_id'] : null),
      ),
      address: _str(json, const [
        'address',
        'manual_address',
        'partner_address',
        'street',
      ]),
      phone: _str(json, const ['phone', 'phone_no', 'mobile']),
      responsiblePerson: _str(json, const [
        'responsible_person',
        'responsible',
      ]),
      doctor: _str(json, const ['doctor', 'doctor_name']),
      invoiceDate: _str(json, const [
        'invoice_date',
        'date_invoice',
        'bill_date',
        // Never fall back to create_date (UTC datetime → wrong local day).
        'date',
      ]),
      expiryMedicineBill: json['expiry_medicine_bill'] == true ||
          json['expiry_medicine_bill'] == 1,
      verifyStatus: _str(json, const [
        'verify_status',
        'verification_status',
        'verified_status',
      ]),
      billedBy: _str(json, const [
        'billed_by',
        'billed_by_name',
        'create_uid_name',
        'user_name',
      ]),
      taxAmount: _num(json, const [
        'tax_amount',
        'amount_tax',
        'tax',
      ]),
      balance: _num(json, const [
        'balance',
        'amount_residual',
        'residual',
      ]),
      subtotal: _num(json, const [
        'subtotal',
        'amount_untaxed',
        'untaxed_amount',
      ]),
      discountTotal: _num(json, const [
        'discount_total',
        'amount_discount',
      ]),
      total: _num(json, const [
        'total',
        'amount_total',
        'total_amount',
      ]),
      supplierInvoiceNo: _str(json, const [
        'supplier_invoice_no',
        'supplier_invoice_number',
      ]),
      poNumber: _str(json, const [
        'po_number',
        'pharmacy_purchase_order_id_name',
        'purchase_order',
        'purchase_id_name',
      ]),
      supplierInvoiceAmount: _num(json, const [
        'supplier_invoice_amount',
        'inv_amount',
      ]),
      previousInvoice: _str(json, const [
        'previous_invoice',
        'select_previous_invoice_id_name',
      ]),
      deliveryDate: _str(json, const ['delivery_date']),
      // Website Payment History "Status" column — do not fall back to Odoo
      // move `state` / `payment_state` (those are used separately below).
      status: _str(json, const [
        'status',
        'bill_status',
        'invoice_status',
        'hold_status',
        'holding_status',
      ]),
      moveState: moveState,
      paymentState: paymentState,
      isPaid: isPaid,
      paymentMode: _str(json, const ['payment_mode', 'payment_type']),
      advanceAmount: _num(json, const [
        'customer_advance_amount',
        'advance_amount',
        'advance_amt',
        'advance',
      ]),
      oldBalance: _num(json, const [
        'customer_old_balance',
        'old_balance',
        'previous_balance',
        'opening_balance',
      ]),
      gstType: _str(json, const ['gst_type', 'gst_type_name']),
      discountCategory: _str(json, const [
        'discount_category',
        'discount_cat',
      ]),
      discountType: _str(json, const ['discount_type']),
      discountRate: _num(json, const ['discount_rate', 'discount_percent']),
      verifiedBy: _str(json, const ['verified_by', 'verified_by_name']),
      expense: _str(json, const ['expense']),
      expenseAmt: _num(json, const ['expense_amt', 'expense_amount']),
      remarks: _str(json, const ['remarks', 'narration', 'note']),
      workMinutes: _str(json, const [
        'work_minutes',
        'work_minute',
        'time_minutes',
      ]),
      workHours: _str(json, const [
        'work_hours',
        'work_hour',
        'time_taken',
        'time_hours',
      ]),
      isCreditCustomer: json['is_credit_customer'] == true ||
          json['is_credit_customer'] == 1,
      sequencePrefix: _str(json, const [
        'sequence_prefix',
        'invoice_series',
        'series',
        'journal_code',
        'journal_id_name',
      ]),
      invoiceType: InvoiceGstKindParser.labelFromJson(json),
      b2bFlag: InvoiceSummaryModel.b2bFlagFromJson(json),
      lines: lines,
    );
  }

  static bool? b2bFlagFromJson(Map json) {
    return InvoiceGstKindParser.flagFromJson(json);
  }

  /// Prefer website-style `0514/2026-27` over Odoo `INV/2026/00161`.
  static String? _preferPharmacyInvoiceNumber(String? a, String? b) {
    final aPharm = _extractPharmacyBillNo(a);
    final bPharm = _extractPharmacyBillNo(b);
    if (aPharm != null) return aPharm;
    if (bPharm != null) return bPharm;
    if (a != null && a.trim().isNotEmpty && !a.trim().startsWith('INV/')) {
      return a.trim();
    }
    if (b != null && b.trim().isNotEmpty && !b.trim().startsWith('INV/')) {
      return b.trim();
    }
    return a ?? b;
  }

  static String? _extractPharmacyBillNo(String? value) {
    if (value == null) return null;
    final match =
        RegExp(r'(\d{2,5}/\d{4}(?:-\d{2})?)').firstMatch(value);
    return match?.group(1);
  }

  static String? _parseInvoiceNumber(Map json) {
    for (final key in const [
      'invoice_number',
      'invoice_name',
      'invoice_no',
      'display_name',
      'number',
      'name',
    ]) {
      final raw = json[key];
      if (raw == null || raw == false) continue;
      final text = raw.toString().trim();
      if (text.isEmpty || text == 'false') continue;
      final pharmacy = _extractPharmacyBillNo(text);
      if (pharmacy != null) return pharmacy;
      if ((key == 'invoice_number' || key == 'invoice_no') &&
          text != '/' &&
          !text.startsWith('INV/')) {
        return text;
      }
    }
    for (final key in const [
      'invoice_number',
      'invoice_name',
      'invoice_no',
      'number',
      'name',
      'display_name',
    ]) {
      final raw = json[key];
      if (raw == null || raw == false) continue;
      final text = raw.toString().trim();
      if (text.isEmpty || text == 'false' || text == '/') continue;
      return text;
    }
    return null;
  }

  static List<InvoiceSummaryModel> parseList(Map<String, dynamic> response) {
    final result = response['result'];
    if (result is! Map) return [];

    final root = Map<String, dynamic>.from(result);
    final candidates = <dynamic>[
      root['payment_history'],
      root['payments'],
      root['invoice_list'],
      root['invoices'],
      root['records'],
      root['items'],
      root['data'],
      root['results'],
    ];

    for (final candidate in candidates) {
      if (candidate is List) {
        return candidate
            .whereType<Map>()
            .map((item) => InvoiceSummaryModel.fromJson(
                  Map<String, dynamic>.from(item),
                ))
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
              .map((item) => InvoiceSummaryModel.fromJson(
                    Map<String, dynamic>.from(item),
                  ))
              .toList();
        }
      }
    }
    return [];
  }

  static String formatMoney(double? value) {
    if (value == null) return '0.00';
    return value.toStringAsFixed(2);
  }

  static String? _str(Map json, List<String> keys) {
    for (final key in keys) {
      final value = json[key];
      if (value == null || value == false) continue;
      // Odoo many2one: [id, "Name"]
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

  static int? _asInt(dynamic value) {
    if (value == null || value == false || value == true) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  static double? _num(Map json, List<String> keys) {
    for (final key in keys) {
      final value = json[key];
      if (value is num) return value.toDouble();
      final parsed = double.tryParse(
        value?.toString().replaceAll(',', '') ?? '',
      );
      if (parsed != null) return parsed;
    }
    return null;
  }
}
