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
    this.stockEntryId,
    this.lineUid,
    this.productBarcode,
  });

  final int? id;
  final int? stockEntryId;
  /// QR / stock UID used by `add_to_invoice` (`line_uid` from Laravel).
  final String? lineUid;
  final String? productBarcode;
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
    // Laravel sometimes nests stock dates under stock / lot objects.
    final flat = Map<String, dynamic>.from(json);
    for (final nestKey in const [
      'stock',
      'stock_entry',
      'entry_stock',
      'product',
      'lot',
    ]) {
      final nest = json[nestKey];
      if (nest is Map) {
        nest.forEach((key, value) {
          flat.putIfAbsent('$key', () => value);
        });
      }
    }

    final mfdRaw = _str(flat, const [
      'mfd',
      'mfd_date',
      'manufacturing_date',
      'manufacture_date',
      'manuf_date',
      'mf_date',
      'mfg_date',
      'mfg',
      'mfdate',
      'manuf',
    ]);
    final manufacturerRaw = _str(flat, const [
      'manufacturer',
      'manufacturer_name',
      'manf',
    ]);
    // Prefer real dates for MFD; ignore non-date "manuf" brand strings.
    final mfdResolved = _looksLikeDate(mfdRaw)
        ? mfdRaw
        : (_looksLikeDate(manufacturerRaw) ? manufacturerRaw : mfdRaw);

    return InvoiceLineModel(
      id: flat['id'] is int
          ? flat['id'] as int
          : int.tryParse('${flat['id']}'),
      productName: _str(flat, const [
        'product_name',
        'product_id_name',
        'medicine_id_name',
        'product',
        'display_name',
        'name',
      ]),
      potency: _str(flat, const [
        'potency',
        'potency_id_name',
        'potency_name',
        'power',
        'drug_potency',
      ]),
      company: _str(flat, const [
        'company',
        'pharmacy_company_id_name',
        'comp',
        'medicine_company',
        'brand',
        'company_name',
      ]),
      batch: _str(flat, const [
        'batch',
        'batch_no',
        'batch_id',
        'lot',
        'lot_name',
        'lot_id_name',
      ]),
      manufacturer: manufacturerRaw,
      mfd: mfdResolved,
      expiry: _str(flat, const [
        'expiry',
        'expiry_date',
        'exp_date',
        'exp',
        'expiration_date',
        'expire_date',
        'expiry_dt',
      ]),
      packing: _str(flat, const [
        'packing',
        'pack_id_name',
        'pack',
        'pack_size',
      ]),
      group: _str(flat, const [
        'group',
        'pharmacy_group_id_name',
        'medicine_group',
        'product_group',
        'group_id_name',
      ]),
      qty: _num(flat, const ['qty', 'quantity', 'product_uom_qty', 'received_qty']),
      orderedQty: _num(flat, const ['ordered_qty', 'ordered_quantity']),
      freeQty: _num(flat, const ['free_qty', 'free_quantity']),
      mrp: _num(flat, const ['mrp']),
      discount: _lineDiscountPercent(flat),
      dis2Percent: _num(flat, const [
        'dis2_percent',
        'dis2',
        'discount2',
        'dis',
        'dis_percent',
        'discount_percent',
        'discount',
      ]),
      unit: _str(flat, const [
        'unit',
        'uom',
        'uom_name',
        'product_uom_id_name',
      ]),
      unitPrice: _num(flat, const [
        'unit_price',
        'price_unit',
        'unit_p',
        'unitP',
      ]),
      uPrice: _num(flat, const ['u_price', 'uprice']),
      tax: _num(flat, const ['tax', 'tax_percent', 'tax_rate', 'gst']),
      taxAmount: _num(flat, const [
        'tax_amount',
        'amount_tax',
        'tax_amt',
        'taxAmt',
      ]),
      total: _num(flat, const [
        'price_total',
        'total',
        'price_subtotal',
        'amount_total',
        'line_total',
      ]),
      hsn: _str(flat, const ['hsn', 'hsn_code']),
      rack: _str(flat, const [
        'rack',
        'rack_id_name',
        'rack_no',
        'location',
      ]),
      stockEntryId: flat['stock_entry_id'] is int
          ? flat['stock_entry_id'] as int
          : flat['entry_stock_id'] is int
              ? flat['entry_stock_id'] as int
              : flat['stock_entry_id'] is List &&
                      (flat['stock_entry_id'] as List).isNotEmpty
                  ? int.tryParse('${(flat['stock_entry_id'] as List).first}')
                  : int.tryParse(
                      '${flat['stock_entry_id'] ?? flat['entry_stock_id']}',
                    ),
      lineUid: _str(flat, const [
        'line_uid',
        'uid',
        'qr_data',
        'qr_data_product',
        'product_uid',
      ]),
      productBarcode: _str(flat, const [
        'product_barcode',
        'barcode',
        'ean',
      ]),
    );
  }

  static bool _looksLikeDate(String? raw) {
    final t = (raw ?? '').trim();
    if (t.isEmpty) return false;
    if (RegExp(r'\d').hasMatch(t) &&
        RegExp(r'[/\-.]').hasMatch(t) &&
        t.length >= 4) {
      return true;
    }
    if (RegExp(r'^\d{4,8}$').hasMatch(t.replaceAll(RegExp(r'\D'), ''))) {
      return true;
    }
    return false;
  }

  static String? _str(Map json, List<String> keys) {
    for (final key in keys) {
      final value = json[key];
      if (value == null || value == false) continue;
      if (value is num) continue;
      if (value is List && value.length >= 2) {
        final name = value[1]?.toString().trim() ?? '';
        if (name.isNotEmpty && name != 'false') return name;
        continue;
      }
      if (value is Map) {
        for (final k in const [
          'name',
          'display_name',
          'date',
          'value',
        ]) {
          final name = value[k]?.toString().trim();
          if (name != null && name.isNotEmpty && name != 'false') return name;
        }
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

  /// Prefer pharmacy Dis% aliases over standard `discount` (often 0 when Unit TP
  /// already includes the cut).
  static double? _lineDiscountPercent(Map json) {
    const keys = [
      'dis',
      'dis_percent',
      'discount_percent',
      'dis2_percent',
      'dis2',
      'discount2',
      'discount',
    ];
    double? first;
    for (final key in keys) {
      final value = json[key];
      double? parsed;
      if (value is num) {
        parsed = value.toDouble();
      } else {
        parsed = double.tryParse(value?.toString() ?? '');
      }
      if (parsed == null) continue;
      first ??= parsed;
      if (parsed > 0) return parsed;
    }
    return first;
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
    this.createdAt,
    this.createDateDisplay,
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
  /// Laravel `create_date` / `created_at` (IST wall clock). Cash Book sort key.
  final String? createdAt;
  /// Laravel `create_date_display` — UI text only, never sort with this.
  final String? createDateDisplay;
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

  /// Website footer totals — prefer line-based calc when lines exist so Dis%
  /// and expense match what the user entered (Odoo amount_total often ignores
  /// pharmacy line discount / expense mapping).
  InvoiceCalcResult websiteTotals() {
    final expense = expenseAmt ?? 0;
    if (lines.isNotEmpty) {
      final calc = InvoiceCalcHelper.compute(
        lines: lines
            .map(
              (line) => InvoiceCalcLine(
                qty: line.qty ?? 0,
                mrp: line.mrp ?? line.total ?? 0,
                discountPercent: line.discount ?? line.dis2Percent ?? 0,
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

      // Keep Odoo / cash-book residual when known. Line calc always sets
      // balance == total, which wrongly replaces amount_residual after refresh.
      return InvoiceCalcResult(
        subtotal: calc.subtotal,
        discountTotal: calc.discountTotal,
        tax: calc.tax,
        taxAmount: calc.taxAmount,
        expenseAmt: expense,
        total: calc.total,
        balance: balance ?? calc.balance,
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

  /// Copy with [total]/[balance]/[subtotal] from [websiteTotals] so list
  /// screens match the bill detail (Odoo list APIs ignore line Dis%).
  InvoiceSummaryModel withComputedSectionAmounts() {
    if (lines.isEmpty) return this;
    final calc = websiteTotals();
    return InvoiceSummaryModel(
      id: id,
      invoiceNumber: invoiceNumber,
      customer: customer,
      pharmacyCustomerId: pharmacyCustomerId,
      address: address,
      phone: phone,
      responsiblePerson: responsiblePerson,
      doctor: doctor,
      invoiceDate: invoiceDate,
      createdAt: createdAt,
      createDateDisplay: createDateDisplay,
      expiryMedicineBill: expiryMedicineBill,
      verifyStatus: verifyStatus,
      billedBy: billedBy,
      taxAmount: calc.taxAmount,
      balance: balance ?? calc.balance,
      subtotal: calc.subtotal,
      discountTotal: calc.discountTotal,
      total: calc.total,
      supplierInvoiceNo: supplierInvoiceNo,
      poNumber: poNumber,
      supplierInvoiceAmount: supplierInvoiceAmount,
      previousInvoice: previousInvoice,
      deliveryDate: deliveryDate,
      status: status,
      moveState: moveState,
      paymentState: paymentState,
      isPaid: isPaid,
      paymentMode: paymentMode,
      advanceAmount: advanceAmount,
      oldBalance: oldBalance,
      gstType: gstType,
      discountCategory: discountCategory,
      discountType: discountType,
      discountRate: discountRate,
      verifiedBy: verifiedBy,
      expense: expense,
      expenseAmt: expenseAmt ?? calc.expenseAmt,
      remarks: remarks,
      workMinutes: workMinutes,
      workHours: workHours,
      isCreditCustomer: isCreditCustomer,
      sequencePrefix: sequencePrefix,
      invoiceType: invoiceType,
      b2bFlag: b2bFlag,
      lines: lines,
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
      createdAt: other.createdAt ?? createdAt,
      createDateDisplay: other.createDateDisplay ?? createDateDisplay,
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

  /// List/card label when the bill has no real customer name.
  static const String walkinCustomerLabel = 'Walkin Customer';

  /// Website-aligned customer for forms/detail. Empty / Demo / walk-in → null
  /// so the Customer field stays blank when the bill is opened.
  String? get displayCustomer {
    final raw = (customer ?? '').trim();
    if (raw.isEmpty) return null;
    if (isPlaceholderCustomerName(raw)) return null;
    if (isWalkInCustomerName(raw)) return null;
    return raw;
  }

  /// Invoice / payment-book list label. Nameless bills show [walkinCustomerLabel].
  String get listCustomerLabel {
    final named = displayCustomer;
    if (named != null && named.isNotEmpty) return named;
    return walkinCustomerLabel;
  }

  bool get isWalkInOrNamelessCustomer {
    return isWalkInCustomerName(customer) ||
        isPlaceholderCustomerName(customer);
  }

  /// Website "Billed By". Defaults to Pharmacy Admin when the API omits it;
  /// shows the server value whenever it is set (including overrides).
  static const String defaultBilledBy = 'Pharmacy Admin';

  String get displayBilledBy {
    final raw = (billedBy ?? '').trim();
    return raw.isEmpty ? defaultBilledBy : raw;
  }

  /// True for Odoo defaults / computed placeholders (not a real customer).
  static bool isPlaceholderCustomerName(String? name) {
    var n = (name ?? '').trim().toLowerCase();
    if (n.isEmpty) return true;
    // Odoo: "#Created by: Administrator" / "Created by: Admin"
    n = n.replaceFirst(RegExp(r'^#\s*'), '');
    if (n.contains('created by')) return true;
    if (n.startsWith('@from:')) return true;
    // Laravel often seeds a demo partner when no customer was chosen.
    if (n == 'demo customer' || n == 'demo' || n == 'test customer') {
      return true;
    }
    return n == 'administrator' ||
        n == 'admin' ||
        n == 'false' ||
        n == 'odoobot' ||
        n == 'public user' ||
        n == 'default user';
  }

  /// Walk-in / nameless customer names (any spelling).
  static bool isWalkInCustomerName(String? name) {
    final raw = (name ?? '').trim();
    if (raw.isEmpty) return true;
    if (isPlaceholderCustomerName(raw)) return true;
    final lower = raw.toLowerCase().replaceAll(RegExp(r'[\s_-]+'), '');
    return lower == 'walkin' ||
        lower == 'walkincustomer' ||
        lower.startsWith('walkin');
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
    // Lift nested billed-by / user relations so _str can read a plain name.
    final flat = Map<String, dynamic>.from(json);
    void liftBilledByName(dynamic value) {
      if (value == null || value == false) return;
      if (value is Map) {
        for (final k in const [
          'name',
          'display_name',
          'full_name',
          'user_name',
          'username',
        ]) {
          final name = value[k]?.toString().trim();
          if (name != null && name.isNotEmpty && name != 'false') {
            flat.putIfAbsent('billed_by_name', () => name);
            return;
          }
        }
        return;
      }
      if (value is List && value.length >= 2) {
        final name = value[1]?.toString().trim() ?? '';
        if (name.isNotEmpty && name != 'false') {
          flat.putIfAbsent('billed_by_name', () => name);
        }
      }
    }

    for (final key in const [
      'billed_by',
      'billed_by_id',
      'billed_by_user',
      'invoice_user',
      'invoice_user_id',
      'user',
      'user_id',
      'create_uid',
      'created_by',
      'salesperson_id',
      'cashier',
    ]) {
      liftBilledByName(json[key]);
    }

    final linesNode = flat['invoice_lines'] ??
        flat['order_lines'] ??
        flat['lines'] ??
        flat['line_ids'] ??
        flat['products'];
    final lines = <InvoiceLineModel>[];
    if (linesNode is List) {
      for (final item in linesNode) {
        if (item is Map) {
          lines.add(InvoiceLineModel.fromJson(Map<String, dynamic>.from(item)));
        }
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
    ]);
    final isPaid = flat['is_paid'] == true ||
        flat['is_paid'] == 1 ||
        paymentState?.toLowerCase().trim() == 'paid';

    return InvoiceSummaryModel(
      id: _asInt(flat['id'] ?? flat['invoice_id']),
      invoiceNumber: _parseInvoiceNumber(flat),
      customer: () {
        final c = _str(flat, const [
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
        flat['pharmacy_customer_id'] ??
            flat['customer_id'] ??
            (flat['partner_id'] is num ? flat['partner_id'] : null),
      ),
      address: _str(flat, const [
        'address',
        'manual_address',
        'partner_address',
        'street',
      ]),
      phone: _str(flat, const ['phone', 'phone_no', 'mobile']),
      responsiblePerson: _str(flat, const [
        'responsible_person',
        'responsible_person_name',
        'responsiblePerson',
        'responsiblePersonName',
        'responsible',
        'responsible_name',
        // Nested Laravel relation {id, name} — _str reads Map.name.
        'responsible_person_id',
        'responsible_person_id_name',
        'responsiblePersonId',
        'responsible_id',
        'responsible_id_name',
      ]),
      doctor: _str(flat, const [
        'doctor_name',
        'doctor_id_name',
        'physician_name',
        'physician_id_name',
        'prescriber_name',
        'prescriber_id_name',
        'doctor',
        'physician',
        'prescriber',
        'dr_name',
        'doc_name',
      ]),
      invoiceDate: _str(flat, const [
        'invoice_date',
        'date_invoice',
        'bill_date',
        // Never fall back to create_date (UTC datetime → wrong local day).
        'date',
      ]),
      createdAt: _str(flat, const [
        'create_date',
        'created_at',
        'create_datetime',
      ]),
      createDateDisplay: _str(flat, const ['create_date_display']),
      expiryMedicineBill: flat['expiry_medicine_bill'] == true ||
          flat['expiry_medicine_bill'] == 1,
      verifyStatus: _str(flat, const [
        'verify_status',
        'verification_status',
        'verified_status',
      ]),
      billedBy: _str(flat, const [
        'billed_by',
        'billed_by_name',
        'billed_by_id_name',
        'billed_by_id',
        'invoice_user_id_name',
        'invoice_user_name',
        'invoice_user',
        'user_id_name',
        'create_uid_name',
        'salesperson',
        'salesperson_id_name',
        'sales_person',
        'cashier',
        'cashier_name',
        'user_name',
        'created_by',
        'created_by_name',
        'billed_by_user',
        'user',
      ]),
      taxAmount: _num(flat, const [
        'tax_amount',
        'amount_tax',
        'tax',
      ]),
      balance: _num(flat, const [
        'balance',
        'amount_residual',
        'residual',
      ]),
      subtotal: _num(flat, const [
        'subtotal',
        'amount_untaxed',
        'untaxed_amount',
      ]),
      discountTotal: _num(flat, const [
        'discount_total',
        'amount_discount',
      ]),
      total: _num(flat, const [
        'total',
        'amount_total',
        'total_amount',
      ]),
      supplierInvoiceNo: _str(flat, const [
        'supplier_invoice_no',
        'supplier_invoice_number',
      ]),
      poNumber: _str(flat, const [
        'po_number',
        'pharmacy_purchase_order_id_name',
        'purchase_order',
        'purchase_id_name',
      ]),
      supplierInvoiceAmount: _num(flat, const [
        'supplier_invoice_amount',
        'inv_amount',
      ]),
      previousInvoice: _str(flat, const [
        'previous_invoice',
        'select_previous_invoice_id_name',
      ]),
      deliveryDate: _str(flat, const ['delivery_date']),
      // Website Payment History "Status" column — do not fall back to Odoo
      // move `state` / `payment_state` (those are used separately below).
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
      paymentMode: _str(flat, const ['payment_mode', 'payment_type']),
      advanceAmount: _num(flat, const [
        'customer_advance_amount',
        'advance_amount',
        'advance_amt',
        'advance',
      ]),
      oldBalance: _num(flat, const [
        'customer_old_balance',
        'old_balance',
        'previous_balance',
        'opening_balance',
      ]),
      gstType: _str(flat, const ['gst_type', 'gst_type_name']),
      discountCategory: _str(flat, const [
        'discount_category',
        'discount_category_id_name',
        'discount_cat',
      ]),
      discountType: _str(flat, const ['discount_type', 'discount_mode']),
      discountRate: _num(flat, const [
        'discount_rate',
        'discount_percent',
        'discount_percentage',
      ]),
      verifiedBy: _str(flat, const ['verified_by', 'verified_by_name']),
      expense: _str(flat, const [
        'customer_expense',
        'expense',
        'expense_note',
        'expense_text',
        'expenses',
        'expense_description',
      ]),
      expenseAmt: _num(flat, const [
        'customer_expense_amount',
        'expense_amt',
        'expense_amount',
        'expenses_amt',
        'expense_total',
        'other_charge',
        'other_charges',
      ]),
      remarks: _str(flat, const ['remarks', 'narration', 'note']),
      workMinutes: _str(flat, const [
        'work_minutes',
        'work_minute',
        'time_minutes',
      ]),
      workHours: _str(flat, const [
        'work_hours',
        'work_hour',
        'time_taken',
        'time_hours',
      ]),
      isCreditCustomer: flat['is_credit_customer'] == true ||
          flat['is_credit_customer'] == 1,
      sequencePrefix: _str(flat, const [
        'sequence_prefix',
        'invoice_series',
        'series',
        'journal_code',
        'journal_id_name',
      ]),
      invoiceType: InvoiceGstKindParser.labelFromJson(flat),
      b2bFlag: InvoiceSummaryModel.b2bFlagFromJson(flat),
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
    // Laravel flat: {status, data:{invoices:[...]}} or Odoo: {result:{...}}
    final result = response['result'];
    final root = result is Map
        ? Map<String, dynamic>.from(result)
        : Map<String, dynamic>.from(response);
    final dataNode = root['data'];
    final candidates = <dynamic>[
      root['payment_history'],
      root['payments'],
      root['invoice_list'],
      root['invoices'],
      root['records'],
      root['items'],
      if (dataNode is List) dataNode,
      if (dataNode is Map) dataNode,
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

  /// Single invoice from Laravel `{status,data:{...}}` or list wrappers.
  static InvoiceSummaryModel? parseOne(Map<String, dynamic> response) {
    final list = parseList(response);
    if (list.isNotEmpty) return list.first;

    final result = response['result'];
    final root = result is Map
        ? Map<String, dynamic>.from(result)
        : Map<String, dynamic>.from(response);
    final dataNode = root['data'];
    final candidates = <dynamic>[
      if (dataNode is Map) dataNode,
      root['invoice'],
      root['customer_invoice'],
      root['record'],
      root,
    ];
    for (final candidate in candidates) {
      if (candidate is! Map) continue;
      final map = Map<String, dynamic>.from(candidate);
      if (map.containsKey('id') ||
          map.containsKey('invoice_id') ||
          map.containsKey('invoice_number') ||
          map.containsKey('name') ||
          map.containsKey('lines') ||
          map.containsKey('invoice_lines')) {
        return InvoiceSummaryModel.fromJson(map);
      }
    }
    return null;
  }

  static String formatMoney(double? value) {
    if (value == null) return '0.00';
    return value.toStringAsFixed(2);
  }

  static String? _str(Map json, List<String> keys) {
    for (final key in keys) {
      final value = json[key];
      if (value == null || value == false) continue;
      // Bare numeric ids (Many2one after normalize) are not display names.
      if (value is num) continue;
      // Odoo many2one: [id, "Name"]
      if (value is List && value.length >= 2) {
        final name = value[1]?.toString().trim();
        if (name == null || name.isEmpty || name == 'false') continue;
        return name;
      }
      // Laravel nested user/relation: {id, name}
      if (value is Map) {
        for (final k in const [
          'name',
          'display_name',
          'full_name',
          'user_name',
          'username',
        ]) {
          final name = value[k]?.toString().trim();
          if (name != null && name.isNotEmpty && name != 'false') return name;
        }
        continue;
      }
      final text = value.toString().trim();
      if (text.isEmpty || text == 'false') continue;
      // Skip Map.toString() leftovers like "{id: 1}"
      if (text.startsWith('{') && text.endsWith('}')) continue;
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
