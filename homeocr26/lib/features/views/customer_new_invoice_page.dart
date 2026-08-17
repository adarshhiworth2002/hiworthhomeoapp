import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/invoice_summary_model.dart';
import '../../models/stock_item_model.dart';
import '../../viewModels/login_viewmodel.dart';
import '../services/WebApi/web_api_impl.dart';
import '../services/api_request_helper.dart';
import '../services/api_response_helper.dart';
import '../services/bill_name_store.dart';
import '../services/endPoints.dart';
import '../services/invoice_calc_helper.dart';
import '../services/invoice_draft_helper.dart';
import '../services/invoice_helper.dart';
import '../services/invoice_stock_restore_helper.dart';
import '../services/odoo_rpc_helper.dart';
import '../widgets/app_responsive.dart';
import '../widgets/system_safe.dart';
import '../../models/qr_model.dart';
import 'add_to_customer.dart';
import '../theme.dart';

class _NamedOption {
  const _NamedOption({
    required this.name,
    this.id,
    this.address,
    this.phone,
    this.defaultPaymentMode,
  });

  final String name;
  final int? id;
  final String? address;
  final String? phone;
  /// Website payment mode label: Cash / Credit / …
  final String? defaultPaymentMode;

  _NamedOption copyWith({
    String? name,
    int? id,
    String? address,
    String? phone,
    String? defaultPaymentMode,
  }) {
    return _NamedOption(
      name: name ?? this.name,
      id: id ?? this.id,
      address: address ?? this.address,
      phone: phone ?? this.phone,
      defaultPaymentMode: defaultPaymentMode ?? this.defaultPaymentMode,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is _NamedOption && other.name == name && other.id == id;

  @override
  int get hashCode => Object.hash(name, id);
}

/// Website `cus.discount` row for Discount Category.
class _DiscountCategoryOption {
  const _DiscountCategoryOption({
    required this.id,
    required this.name,
    required this.discountType,
    required this.rate,
    required this.displayName,
  });

  final int id;
  final String name;
  /// `percentage` or `amount` (website selection keys).
  final String discountType;
  final double rate;
  final String displayName;

  /// App UI label: Percentage / Rupees.
  String get uiDiscountType =>
      discountType == 'amount' ? 'Rupees' : 'Percentage';

  factory _DiscountCategoryOption.fromOdoo(Map<String, dynamic> json) {
    final id = json['id'] is int
        ? json['id'] as int
        : int.tryParse('${json['id']}') ?? 0;
    final name = (json['cus_dis'] ?? json['name'] ?? '').toString().trim();
    final type = (json['discount_type'] ?? 'percentage')
        .toString()
        .trim()
        .toLowerCase();
    final rateRaw = json['percentage'];
    final rate = rateRaw is num
        ? rateRaw.toDouble()
        : double.tryParse('$rateRaw') ?? 0;
    final display = (json['display_name'] ?? name).toString().trim();
    return _DiscountCategoryOption(
      id: id,
      name: name.isEmpty ? display : name,
      discountType: type.contains('amount') ? 'amount' : 'percentage',
      rate: rate,
      displayName: display.isEmpty ? name : display,
    );
  }
}

class _BillLine {
  _BillLine();

  int revision = 0;
  String? product;
  String? potency;
  String? company;
  String? batch;
  String? manuf;
  String? expiry;
  String? pack;
  String? group;
  /// Blank by default (website-style); not 0.00.
  String qty = '';
  String mrp = '';
  String discount = '';
  String unitP = '';
  String tax = '';
  String hsn = '';
  String rack = '';

  /// Set when this line was added via QR / add_to_invoice (stock already deducted).
  bool serverCommitted = false;
  /// Qty already deducted on the server for this line.
  double serverCommittedQty = 0;
  /// True when QR-added during this page session (restore on Close without Save).
  bool addedThisSession = false;
  /// `qr_data` token used by add_to_invoice (barcode preferred).
  String? addQrData;
  /// Alternate token (UID) for restore retries.
  String? addQrDataAlt;
  /// Pharmacy stock display id (from stock picker) for save → add_to_invoice.
  int? stockDisplayId;
  /// Odoo `entry.stock` row id for precise restock.
  int? entryStockId;
  /// Odoo `account.move` id from add_to_invoice (draft name is often `/`).
  int? serverInvoiceId;
  /// Odoo `account.move.line` id when editing an existing bill line.
  int? odooLineId;

  bool get hasRequiredLineFields {
    bool filled(String? v) => (v ?? '').trim().isNotEmpty;
    return filled(product) &&
        filled(potency) &&
        filled(company) &&
        filled(group) &&
        filled(qty) &&
        filled(mrp);
  }

  /// Labels of required fields that are still empty.
  List<String> get missingRequiredFields {
    bool filled(String? v) => (v ?? '').trim().isNotEmpty;
    final missing = <String>[];
    if (!filled(product)) missing.add('Product');
    if (!filled(potency)) missing.add('Potency');
    if (!filled(company)) missing.add('Company');
    if (!filled(group)) missing.add('Group');
    if (!filled(qty)) missing.add('Qty');
    if (!filled(mrp)) missing.add('Mrp');
    return missing;
  }

  void applyTemplate(_LineTemplate t) {
    product = t.product ?? product;
    potency = t.potency ?? potency;
    company = t.company ?? company;
    batch = t.batch ?? batch;
    manuf = t.manuf ?? manuf;
    expiry = t.expiry ?? expiry;
    pack = t.pack ?? pack;
    group = t.group ?? group;
    if (t.mrp != null) mrp = t.mrp!;
    if (t.tax != null) tax = t.tax!;
    if (t.hsn != null) hsn = t.hsn!;
    if (t.rack != null) rack = t.rack!;
    revision++;
  }

  /// Website-style: fill related fields from stock, but never invent a
  /// different potency than the one the user picked.
  void applyFromStock(
    _LineTemplate t, {
    bool preservePotency = false,
    bool preserveProduct = false,
  }) {
    final keptPotency = potency;
    final keptProduct = product;
    if (!preserveProduct && t.product != null) product = t.product;
    if (!preservePotency && t.potency != null) potency = t.potency;
    if (t.company != null) company = t.company;
    if (t.batch != null) batch = t.batch;
    if (t.manuf != null) manuf = t.manuf;
    if (t.expiry != null) expiry = t.expiry;
    if (t.pack != null) pack = t.pack;
    if (t.group != null) group = t.group;
    if (t.mrp != null) mrp = t.mrp!;
    if (t.tax != null) tax = t.tax!;
    if (t.hsn != null) hsn = t.hsn!;
    if (t.rack != null) rack = t.rack!;
    if (preserveProduct) product = keptProduct;
    if (preservePotency) potency = keptPotency;
    revision++;
  }

  void clearRelatedExceptProduct() {
    potency = null;
    company = null;
    batch = null;
    manuf = null;
    expiry = null;
    pack = null;
    group = null;
    mrp = '';
    tax = '';
    hsn = '';
    rack = '';
    revision++;
  }
}

class _LineTemplate {
  const _LineTemplate({
    this.product,
    this.potency,
    this.company,
    this.batch,
    this.manuf,
    this.expiry,
    this.pack,
    this.group,
    this.mrp,
    this.tax,
    this.hsn,
    this.rack,
  });

  final String? product;
  final String? potency;
  final String? company;
  final String? batch;
  final String? manuf;
  final String? expiry;
  final String? pack;
  final String? group;
  final String? mrp;
  final String? tax;
  final String? hsn;
  final String? rack;

  factory _LineTemplate.fromStock(StockItemModel s) {
    String? money(double? v) =>
        v == null ? null : v.toStringAsFixed(2);
    return _LineTemplate(
      product: s.medicine?.trim().isEmpty == true ? null : s.medicine?.trim(),
      potency: s.potency?.trim().isEmpty == true ? null : s.potency?.trim(),
      company: s.company?.trim().isEmpty == true ? null : s.company?.trim(),
      batch: s.batch?.trim().isEmpty == true ? null : s.batch?.trim(),
      manuf: s.mfd?.trim().isEmpty == true ? null : s.mfd?.trim(),
      expiry: s.exp?.trim().isEmpty == true ? null : s.exp?.trim(),
      pack: s.packing?.trim().isEmpty == true ? null : s.packing?.trim(),
      group: s.group?.trim().isEmpty == true ? null : s.group?.trim(),
      mrp: money(s.mrp),
      tax: money(s.gst),
      hsn: s.hsn?.trim().isEmpty == true ? null : s.hsn?.trim(),
      rack: s.rack?.trim().isEmpty == true ? null : s.rack?.trim(),
    );
  }

  factory _LineTemplate.fromInvoiceLine(InvoiceLineModel l) {
    String? money(double? v) =>
        v == null ? null : v.toStringAsFixed(2);
    return _LineTemplate(
      product: l.productName,
      potency: l.potency,
      company: l.company,
      batch: l.batch,
      manuf: l.manufacturer,
      expiry: l.expiry,
      pack: l.packing,
      group: l.group,
      mrp: money(l.mrp),
      tax: money(l.tax),
      hsn: l.hsn,
      rack: l.rack,
    );
  }
}

/// Mobile UI matching the WebView Cash/Credit Tax Invoice form.
class CustomerNewInvoicePage extends StatefulWidget {
  const CustomerNewInvoicePage({
    super.key,
    this.existingNumbers = const [],
    this.existingInvoices = const [],
    this.editInvoice,
  });

  final List<String> existingNumbers;
  final List<InvoiceSummaryModel> existingInvoices;
  /// When set, page edits an existing draft/open bill (website sync on Save).
  final InvoiceSummaryModel? editInvoice;

  @override
  State<CustomerNewInvoicePage> createState() => _CustomerNewInvoicePageState();
}

class _CustomerNewInvoicePageState extends State<CustomerNewInvoicePage> {
  final _addressCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  // skipTraversal: dropdowns must not land focus here when they close.
  final _phoneFocus = FocusNode(debugLabel: 'phone', skipTraversal: true);
  final _addressFocus = FocusNode(debugLabel: 'address', skipTraversal: true);
  final _discountRateCtrl = TextEditingController();
  final _expenseCtrl = TextEditingController();
  final _remarksCtrl = TextEditingController();
  final _verifiedByCtrl = TextEditingController();

  void _dismissKeyboard() {
    FocusManager.instance.primaryFocus?.unfocus();
    SystemChannels.textInput.invokeMethod('TextInput.hide');
  }

  /// Dropdown / sheet close often restores focus onto Address — clear after frame.
  void _dismissKeyboardAfterFrame() {
    _dismissKeyboard();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _dismissKeyboard();
    });
  }

  String _invoiceNumber = '';
  String _invoiceDateDisplay = '';
  _NamedOption? _customer;
  _NamedOption? _doctor;
  _NamedOption? _responsible;
  String? _paymentMode = 'Cash';
  String? _gstType = 'GST MINUS';
  String? _discountType = 'Percentage';
  _DiscountCategoryOption? _discountCategory;
  String? _pendingDiscountCategoryName;
  List<_DiscountCategoryOption> _discountCategories = [];
  bool _expiryMedicineBill = false;
  bool _saving = false;
  bool _removingLine = false;
  /// True after user taps Save (keep bill). Close without this restores stock.
  bool _billKept = false;
  /// True once add_to_invoice has committed products to [_invoiceNumber].
  bool _invoiceCommittedOnServer = false;
  /// Odoo move id for this bill (from add_to_invoice).
  int? _serverInvoiceId;
  InvoiceCalcResult _totals = InvoiceCalcResult.zero;
  /// Which invoice line shows the full edit form; others use draft-style summary.
  int? _editingLineIndex;
  /// Required field labels to highlight in red on the expanded line.
  Set<String> _lineRequiredErrors = {};

  List<_NamedOption> _customers = [];
  List<_NamedOption> _doctors = [];
  List<_NamedOption> _responsiblePeople = [];
  List<_BillLine> _lines = [];

  // Suggestion pools for line dropdowns (website order for masters).
  final List<String> _products = [];
  final List<String> _potencies = [];
  final List<String> _companies = [];
  final List<String> _batches = [];
  final List<String> _packs = [];
  final List<String> _groups = [];
  final List<String> _hsns = [];
  final List<String> _racks = [];
  /// Website potency master (name + related group/hsn/…).
  final List<Map<String, String>> _potencyMasterRows = [];
  final Set<String> _productKeys = {};
  final Set<String> _potencyKeys = {};
  final Set<String> _companyKeys = {};
  final Set<String> _batchKeys = {};
  final Set<String> _packKeys = {};
  final Set<String> _groupKeys = {};
  final Set<String> _hsnKeys = {};
  final Set<String> _rackKeys = {};
  final List<_LineTemplate> _templates = [];

  static const _paymentModes = ['Cash', 'Credit', 'UPI', 'Card', 'Cheque'];
  static const _gstTypes = ['GST MINUS', 'GST PLUS', 'IGST', 'No GST'];
  /// Matches website selection; Amount is shown as Rupees.
  static const _discountTypes = ['Percentage', 'Rupees'];

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _invoiceDateDisplay =
        '${now.month.toString().padLeft(2, '0')}/${now.day.toString().padLeft(2, '0')}/${now.year}';
    final edit = widget.editInvoice;
    if (edit != null) {
      _applyEditInvoice(edit);
    } else {
      final numbers = <String>[
        ...widget.existingNumbers,
        ...widget.existingInvoices.map((e) => e.displayNumber),
      ];
      _invoiceNumber = InvoiceHelper.nextInvoiceNumber(numbers);
    }
    _seedFromExistingInvoices();
    _discountRateCtrl.addListener(_recalculate);
    _expenseCtrl.addListener(_recalculate);
    // Background only — UI is already visible.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadSavedNames();
      _loadPartnerNames();
      _loadPharmacyCustomers();
      _loadResponsiblePeople();
      _loadMasterDropdowns();
      _loadDiscountCategories();
      _loadStockSuggestionPools();
      _recalculate();
    });
  }

  void _applyEditInvoice(InvoiceSummaryModel inv) {
    _invoiceNumber = inv.displayNumber;
    _serverInvoiceId = inv.id;
    _invoiceCommittedOnServer = inv.id != null;
    // Existing bill — Close must not wipe pre-existing lines; only session QR adds.
    _billKept = true;
    final customer = (inv.displayCustomer ?? '').trim();
    if (customer.isNotEmpty) {
      _customer = _NamedOption(
        name: customer,
        id: inv.pharmacyCustomerId,
        address: inv.address,
        phone: inv.phone,
      );
    }
    _addressCtrl.text = (inv.address ?? '').trim();
    _phoneCtrl.text = (inv.phone ?? '').trim();
    final doctor = (inv.doctor ?? '').trim();
    if (doctor.isNotEmpty) _doctor = _NamedOption(name: doctor);
    final responsible = (inv.responsiblePerson ?? '').trim();
    if (responsible.isNotEmpty) {
      _responsible = _NamedOption(name: responsible);
    }
    final pay = (inv.paymentMode ?? '').trim();
    if (pay.isNotEmpty) {
      final lower = pay.toLowerCase();
      _paymentMode = _paymentModes.firstWhere(
        (m) => m.toLowerCase() == lower || lower.contains(m.toLowerCase()),
        orElse: () => 'Cash',
      );
    }
    if (inv.gstType != null && inv.gstType!.trim().isNotEmpty) {
      final g = inv.gstType!.trim().toLowerCase();
      _gstType = g.contains('plus')
          ? 'GST PLUS'
          : (g.contains('igst')
              ? 'IGST'
              : (g.contains('no') ? 'No GST' : 'GST MINUS'));
    }
    _expiryMedicineBill = inv.expiryMedicineBill;
    final discCat = (inv.discountCategory ?? '').trim();
    if (discCat.isNotEmpty) {
      _pendingDiscountCategoryName = discCat;
    }
    if (inv.discountType != null) {
      final t = inv.discountType!.toLowerCase();
      _discountType =
          t.contains('amount') || t.contains('rupee') ? 'Rupees' : 'Percentage';
    }
    if (inv.discountRate != null) {
      final r = inv.discountRate!;
      _discountRateCtrl.text =
          r == r.roundToDouble() ? r.toInt().toString() : r.toString();
    }
    if (inv.expenseAmt != null) {
      final e = inv.expenseAmt!;
      _expenseCtrl.text =
          e == e.roundToDouble() ? e.toInt().toString() : e.toString();
    }
    _remarksCtrl.text = (inv.remarks ?? '').trim();
    _verifiedByCtrl.text = (inv.verifiedBy ?? '').trim();
    if (inv.invoiceDate != null && inv.invoiceDate!.trim().isNotEmpty) {
      _invoiceDateDisplay = inv.invoiceDate!.trim();
    }

    _lines = inv.lines.map((l) {
      final line = _BillLine();
      line.odooLineId = l.id;
      line.applyFromStock(_LineTemplate.fromInvoiceLine(l));
      final qty = l.qty;
      if (qty != null) {
        line.qty = qty == qty.roundToDouble()
            ? qty.toInt().toString()
            : qty.toString();
        line.serverCommitted = true;
        line.serverCommittedQty = qty;
        line.addedThisSession = false;
        line.serverInvoiceId = inv.id;
      }
      if (l.discount != null) {
        final d = l.discount!;
        line.discount = d == d.roundToDouble()
            ? d.toInt().toString()
            : d.toStringAsFixed(2);
      }
      final unit = l.uPrice ?? l.unitPrice;
      if (unit != null) {
        line.unitP = unit == unit.roundToDouble()
            ? unit.toInt().toString()
            : unit.toStringAsFixed(2);
      }
      return line;
    }).toList();
    _recalcAllLinePrices();
    // Existing draft lines open collapsed (tap Edit for full form).
    _editingLineIndex = null;
  }

  @override
  void dispose() {
    _discountRateCtrl.removeListener(_recalculate);
    _expenseCtrl.removeListener(_recalculate);
    _addressCtrl.dispose();
    _phoneCtrl.dispose();
    _phoneFocus.dispose();
    _addressFocus.dispose();
    _discountRateCtrl.dispose();
    _expenseCtrl.dispose();
    _remarksCtrl.dispose();
    _verifiedByCtrl.dispose();
    super.dispose();
  }

  void _recalculate() {
    final result = InvoiceCalcHelper.compute(
      lines: _lines
          .map(
            (l) => InvoiceCalcLine(
              qty: InvoiceCalcHelper.parseNum(l.qty),
              mrp: InvoiceCalcHelper.parseNum(l.mrp),
              discountPercent: InvoiceCalcHelper.parseNum(l.discount),
              unitP: InvoiceCalcHelper.parseNum(l.unitP),
              taxPercent: InvoiceCalcHelper.parseNum(l.tax),
            ),
          )
          .toList(growable: false),
      discountType: _discountType,
      discountRate: InvoiceCalcHelper.parseNum(_discountRateCtrl.text),
      gstType: _gstType,
      expenseAmt: InvoiceCalcHelper.parseNum(_expenseCtrl.text),
    );
    if (!mounted) {
      _totals = result;
      return;
    }
    setState(() => _totals = result);
  }

  static String _formatLineNum(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

  /// Website: Unit TP / Unit P = MRP minus line discount (%); not tax-inclusive.
  void _recalcLinePrices(_BillLine line) {
    final mrp = InvoiceCalcHelper.parseNum(line.mrp);
    if (mrp <= 0) return;
    final disc = InvoiceCalcHelper.parseNum(line.discount);
    final unitTp =
        disc > 0 ? mrp * (1 - disc / 100.0) : mrp;
    line.unitP = _formatLineNum(unitTp);
    line.revision++;
  }

  void _recalcAllLinePrices() {
    for (final line in _lines) {
      _recalcLinePrices(line);
    }
  }

  void _seedFromExistingInvoices() {
    final byCustomer = <String, _NamedOption>{};
    final byDoctor = <String, _NamedOption>{};

    for (final inv in widget.existingInvoices) {
      final name = (inv.displayCustomer ?? '').trim();
      if (name.isNotEmpty) {
        byCustomer['${inv.pharmacyCustomerId ?? ''}|${name.toLowerCase()}'] =
            _NamedOption(name: name, id: inv.pharmacyCustomerId);
      }
      final doctor = (inv.doctor ?? '').trim();
      if (doctor.isNotEmpty) {
        byDoctor[doctor.toLowerCase()] = _NamedOption(name: doctor);
      }
      for (final line in inv.lines) {
        _addOpt(_products, _productKeys, line.productName);
        _addOpt(_potencies, _potencyKeys, line.potency);
        _addOpt(_companies, _companyKeys, line.company);
        _addOpt(_batches, _batchKeys, line.batch);
        _addOpt(_packs, _packKeys, line.packing);
        _addOpt(_groups, _groupKeys, line.group);
        _addOpt(_hsns, _hsnKeys, line.hsn);
        _addOpt(_racks, _rackKeys, line.rack);
        _templates.add(_LineTemplate.fromInvoiceLine(line));
      }
    }

    _customers = byCustomer.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    _doctors = byDoctor.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  Future<void> _loadSavedNames() async {
    final byCustomer = {
      for (final c in _customers)
        '${c.id ?? ''}|${c.name.toLowerCase()}': c,
    };
    final byDoctor = {
      for (final d in _doctors) d.name.toLowerCase(): d,
    };

    for (final name in await BillNameStore.loadCustomers()) {
      final t = name.trim();
      if (t.isEmpty) continue;
      byCustomer.putIfAbsent('|$t'.toLowerCase(), () => _NamedOption(name: t));
    }
    for (final name in await BillNameStore.loadDoctors()) {
      final t = name.trim();
      if (t.isEmpty) continue;
      byDoctor.putIfAbsent(t.toLowerCase(), () => _NamedOption(name: t));
    }

    if (!mounted) return;
    setState(() {
      _customers = byCustomer.values.toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      _doctors = byDoctor.values.toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    });
  }

  void _addOpt(List<String> into, Set<String> keys, String? value) {
    final t = value?.trim();
    if (t == null || t.isEmpty) return;
    final key = t.toLowerCase();
    if (keys.add(key)) into.add(t);
  }

  void _addOptsInOrder(
    List<String> into,
    Set<String> keys,
    Iterable<String> values,
  ) {
    for (final value in values) {
      _addOpt(into, keys, value);
    }
  }

  void _mergeNamedOptions(List<_NamedOption> into, Iterable<String> names) {
    final map = {
      for (final o in into) o.name.toLowerCase(): o,
    };
    for (final raw in names) {
      final t = raw.trim();
      if (t.isEmpty) continue;
      map.putIfAbsent(t.toLowerCase(), () => _NamedOption(name: t));
    }
    into
      ..clear()
      ..addAll(map.values)
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  Future<void> _loadPartnerNames() async {
    final login = context.read<LoginViewmodel>();
    final flutterSid = login.sessionId ?? '';
    if (flutterSid.isEmpty) return;
    try {
      var sid = flutterSid;
      final email = (login.loginEmail ?? '').trim();
      final pass = login.loginPassword ?? '';
      if (email.isNotEmpty && pass.isNotEmpty) {
        final webSid = await OdooRpcHelper.webSessionId(
          db: LoginViewmodel.dbName,
          login: email,
          password: pass,
        );
        if (webSid != null && webSid.isNotEmpty) sid = webSid;
      }
      final names = await OdooRpcHelper.searchPartnerNames(sid);
      if (!mounted || names.isEmpty) return;
      setState(() {
        _mergeNamedOptions(_customers, names);
        _mergeNamedOptions(_doctors, names);
      });
    } catch (e) {
      if (kDebugMode) debugPrint('partner names load: $e');
    }
  }

  Future<String> _odooSessionId() async {
    final login = context.read<LoginViewmodel>();
    var sid = login.sessionId ?? '';
    final email = (login.loginEmail ?? '').trim();
    final pass = login.loginPassword ?? '';
    if (email.isNotEmpty && pass.isNotEmpty) {
      final webSid = await OdooRpcHelper.cachedWebSessionId(
        db: LoginViewmodel.dbName,
        login: email,
        password: pass,
      );
      if (webSid != null && webSid.isNotEmpty) sid = webSid;
    }
    return sid;
  }

  Future<void> _loadPharmacyCustomers() async {
    try {
      final sid = await _odooSessionId();
      if (sid.isEmpty) return;
      final rows = await OdooRpcHelper.searchPharmacyCustomers(sid);
      if (!mounted || rows.isEmpty) return;
      setState(() {
        final map = <String, _NamedOption>{
          for (final c in _customers)
            '${c.id ?? ''}|${c.name.toLowerCase()}': c,
        };
        for (final row in rows) {
          final opt = _customerFromRow(row);
          if (opt == null) continue;
          final key = '${opt.id ?? ''}|${opt.name.toLowerCase()}';
          final existing = map[key];
          map[key] = existing == null
              ? opt
              : existing.copyWith(
                  id: opt.id ?? existing.id,
                  address: opt.address ?? existing.address,
                  phone: opt.phone ?? existing.phone,
                  defaultPaymentMode:
                      opt.defaultPaymentMode ?? existing.defaultPaymentMode,
                );
          // Also key by name-only for matches without id.
          map['|${opt.name.toLowerCase()}'] = map[key]!;
        }
        _customers = map.values.toSet().toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
      });
    } catch (e) {
      if (kDebugMode) debugPrint('pharmacy customers load: $e');
    }
  }

  Future<void> _loadResponsiblePeople() async {
    try {
      final sid = await _odooSessionId();
      if (sid.isEmpty) return;
      final rows = await OdooRpcHelper.searchResponsiblePersons(sid);
      if (!mounted || rows.isEmpty) return;
      setState(() {
        _responsiblePeople = rows
            .map((row) {
              final id = row['id'];
              final name = (row['name'] ?? row['display_name'] ?? '')
                  .toString()
                  .trim();
              if (name.isEmpty) return null;
              return _NamedOption(
                name: name,
                id: id is num ? id.toInt() : int.tryParse('$id'),
              );
            })
            .whereType<_NamedOption>()
            .toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
      });
    } catch (e) {
      if (kDebugMode) debugPrint('responsible people load: $e');
    }
  }

  Future<void> _loadDiscountCategories() async {
    try {
      final sid = await _odooSessionId();
      if (sid.isEmpty) return;
      final rows = await OdooRpcHelper.searchCustomerDiscounts(sid);
      if (!mounted || rows.isEmpty) return;
      setState(() {
        _discountCategories = rows
            .map(_DiscountCategoryOption.fromOdoo)
            .where((e) => e.name.isNotEmpty && e.id > 0)
            .toList(growable: false);
        final pending = (_pendingDiscountCategoryName ?? '').trim();
        if (pending.isNotEmpty && _discountCategory == null) {
          final want = pending.toLowerCase();
          for (final c in _discountCategories) {
            if (c.name.toLowerCase() == want ||
                c.displayName.toLowerCase() == want) {
              _discountCategory = c;
              break;
            }
          }
          _pendingDiscountCategoryName = null;
        }
      });
    } catch (e) {
      if (kDebugMode) debugPrint('discount categories load: $e');
    }
  }

  void _applyDiscountCategory(_DiscountCategoryOption? selected) {
    setState(() {
      _discountCategory = selected;
      if (selected == null) return;
      _discountType = selected.uiDiscountType;
      final rate = selected.rate;
      _discountRateCtrl.text = rate == rate.roundToDouble()
          ? rate.toInt().toString()
          : rate.toStringAsFixed(2);
    });
    _recalculate();
    _dismissKeyboardAfterFrame();
  }

  _NamedOption? _customerFromRow(Map<String, dynamic> row) {
    final name = (row['name'] ?? '').toString().trim();
    if (name.isEmpty) return null;
    final id = row['id'];
    final mobile = (row['mobile'] ?? '').toString().trim();
    final address = (row['address'] ?? '').toString().trim();
    final place = (row['place'] ?? '').toString().trim();
    final addrParts = <String>[
      if (address.isNotEmpty && address != 'false') address,
      if (place.isNotEmpty && place != 'false') place,
    ];
    final creditAmt = (row['credit_limit_amount'] is num)
        ? (row['credit_limit_amount'] as num).toDouble()
        : double.tryParse('${row['credit_limit_amount']}') ?? 0;
    final creditDays = (row['credit_limit_days'] is num)
        ? (row['credit_limit_days'] as num).toInt()
        : int.tryParse('${row['credit_limit_days']}') ?? 0;
    final isCredit = creditAmt > 0 || creditDays > 0;
    return _NamedOption(
      name: name,
      id: id is num ? id.toInt() : int.tryParse('$id'),
      phone: (mobile.isEmpty || mobile == 'false') ? null : mobile,
      address: addrParts.isEmpty ? null : addrParts.join(', '),
      defaultPaymentMode: isCredit ? 'Credit' : null,
    );
  }

  String _paymentModeFromInvoices(_NamedOption customer) {
    final nameKey = customer.name.toLowerCase();
    for (final inv in widget.existingInvoices.reversed) {
      final sameId = customer.id != null &&
          inv.pharmacyCustomerId != null &&
          customer.id == inv.pharmacyCustomerId;
      final sameName =
          (inv.displayCustomer ?? '').trim().toLowerCase() == nameKey;
      if (!sameId && !sameName) continue;
      final raw = (inv.paymentMode ?? '').trim().toLowerCase();
      if (raw.isEmpty) continue;
      if (raw.contains('credit')) return 'Credit';
      if (raw.contains('upi')) return 'UPI';
      if (raw.contains('card')) return 'Card';
      if (raw.contains('cheque') || raw.contains('check')) return 'Cheque';
      if (raw.contains('cash')) return 'Cash';
    }
    return 'Cash';
  }

  Future<void> _applyCustomerSelection(_NamedOption picked) async {
    var selected = picked;
    // Refresh details from Odoo when we have an id.
    if (picked.id != null) {
      try {
        final sid = await _odooSessionId();
        if (sid.isNotEmpty) {
          final row =
              await OdooRpcHelper.readPharmacyCustomer(sid, picked.id!);
          if (row != null) {
            selected = _customerFromRow(row) ?? picked;
          }
        }
      } catch (e) {
        if (kDebugMode) debugPrint('apply customer details: $e');
      }
    }

    final payment = selected.defaultPaymentMode ??
        _paymentModeFromInvoices(selected);

    if (!mounted) return;
    setState(() {
      _customer = selected.name.isEmpty ? null : selected;
      _addressCtrl.text = selected.address ?? '';
      _phoneCtrl.text = selected.phone ?? '';
      _paymentMode = payment;
      if (selected.name.isNotEmpty &&
          !_customers.any(
            (c) => c.name.toLowerCase() == selected.name.toLowerCase(),
          )) {
        _customers = [..._customers, selected]
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
      } else {
        // Upgrade cached option with details.
        _customers = _customers
            .map(
              (c) => c.name.toLowerCase() == selected.name.toLowerCase()
                  ? selected
                  : c,
            )
            .toList();
      }
    });
    // Filling address must not steal the caret onto that field.
    _dismissKeyboardAfterFrame();
  }

  void _mergeTemplateIntoPools(_LineTemplate t) {
    _addOpt(_products, _productKeys, t.product);
    _addOpt(_potencies, _potencyKeys, t.potency);
    _addOpt(_companies, _companyKeys, t.company);
    _addOpt(_batches, _batchKeys, t.batch);
    _addOpt(_packs, _packKeys, t.pack);
    _addOpt(_groups, _groupKeys, t.group);
    _addOpt(_hsns, _hsnKeys, t.hsn);
    _addOpt(_racks, _rackKeys, t.rack);
  }

  void _applyStockToLine(
    _BillLine line,
    StockItemModel stock, {
    bool preservePotency = false,
    bool preserveProduct = false,
  }) {
    final t = _LineTemplate.fromStock(stock);
    line.applyFromStock(
      t,
      preservePotency: preservePotency,
      preserveProduct: preserveProduct,
    );
    if (stock.stockId != null) {
      line.stockDisplayId = stock.stockId;
    }
    if (stock.entryStockId != null) {
      line.entryStockId = stock.entryStockId;
    }
    _mergeTemplateIntoPools(t);
    _templates.add(t);
  }

  String _normField(String? value) =>
      (value ?? '').trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');

  bool _potencyEquals(String? a, String? b) {
    final left = _normField(a);
    final right = _normField(b);
    if (left.isEmpty || right.isEmpty) return false;
    if (left == right) return true;
    final an = num.tryParse(left);
    final bn = num.tryParse(right);
    return an != null && bn != null && an == bn;
  }

  int _stockDefaultScore(StockItemModel s) {
    var n = 0;
    if ((s.group ?? '').trim().isNotEmpty) n += 3;
    if ((s.hsn ?? '').trim().isNotEmpty) n += 3;
    if ((s.company ?? '').trim().isNotEmpty) n++;
    if ((s.packing ?? '').trim().isNotEmpty) n++;
    if ((s.rack ?? '').trim().isNotEmpty) n++;
    if ((s.batch ?? '').trim().isNotEmpty) n++;
    if (s.mrp != null) n++;
    return n;
  }

  StockItemModel? _pickBestStockRow(List<StockItemModel> matches) {
    if (matches.isEmpty) return null;
    matches.sort(
      (a, b) => _stockDefaultScore(b).compareTo(_stockDefaultScore(a)),
    );
    return matches.first;
  }

  /// Exact product + potency stock row (when both are set).
  StockItemModel? _exactStockMatch(_BillLine line, List<StockItemModel> rows) {
    if (rows.isEmpty) return null;
    final product = _normField(line.product);
    final potency = _normField(line.potency);
    if (product.isEmpty || potency.isEmpty) return null;

    final matches = <StockItemModel>[];
    for (final row in rows) {
      final name = _normField(row.medicineLabel);
      final productOk = name == product || name.startsWith(product);
      if (!productOk) continue;
      if (!_potencyEquals(row.potency, line.potency)) continue;
      matches.add(row);
    }
    return _pickBestStockRow(matches);
  }

  Future<void> _syncLineFromStock(
    _BillLine line, {
    bool potencyOnly = false,
  }) async {
    final product = (line.product ?? '').trim();
    final potency = (line.potency ?? '').trim();
    if (product.isEmpty && potency.isEmpty) return;

    // Product + potency → exact medicine row (not when potency-only pick).
    if (!potencyOnly && product.isNotEmpty && potency.isNotEmpty) {
      final rows = await _stockRowsForProduct(product);
      if (!mounted) return;
      final match = _exactStockMatch(line, rows);
      if (match == null) {
        if (kDebugMode) {
          debugPrint(
            'No stock defaults for product="$product" potency="$potency"',
          );
        }
        setState(() => line.revision++);
        return;
      }
      setState(() => _applyStockToLine(line, match, preservePotency: true));
      _recalculate();
      return;
    }

    // Website: potency → Group / Tax / HSN only (product may be blank or set).
    if (potency.isNotEmpty && (product.isEmpty || potencyOnly)) {
      // 1) Live Odoo entry.stock by potency_id (website onchange source).
      try {
        final sid = await _odooSessionId();
        if (sid.isNotEmpty) {
          int? knownId;
          for (final r in _potencyMasterRows) {
            if ((r['name'] ?? '').trim().toLowerCase() ==
                potency.toLowerCase()) {
              knownId = int.tryParse(r['id'] ?? '');
              break;
            }
          }
          final defaults = await OdooRpcHelper.readPotencyRelatedDefaults(
            sid,
            potency,
            potencyId: knownId,
          );
          if (!mounted) return;
          if (defaults.isNotEmpty) {
            setState(() {
              _applyPotencyDefaultsToLine(line, defaults);
              final idx = _potencyMasterRows.indexWhere(
                (r) =>
                    (r['name'] ?? '').trim().toLowerCase() ==
                    potency.toLowerCase(),
              );
              if (idx >= 0) {
                _potencyMasterRows[idx] = {
                  ..._potencyMasterRows[idx],
                  ...defaults,
                };
              } else {
                _potencyMasterRows.add({'name': potency, ...defaults});
              }
            });
            _recalculate();
            return;
          }
        }
      } catch (e) {
        if (kDebugMode) debugPrint('potency defaults: $e');
      }

      // 2) Cached master row (if previously enriched).
      final master = _potencyMasterDefaults(potency);
      if (master != null && master.isNotEmpty) {
        setState(() => _applyPotencyDefaultsToLine(line, master));
        _recalculate();
        return;
      }

      // 3) Local templates from stock suggestions.
      _LineTemplate? bestTpl;
      var bestScore = -1;
      for (final t in _templates) {
        if (!_potencyEquals(t.potency, potency)) continue;
        var score = 0;
        if ((t.group ?? '').trim().isNotEmpty) score += 3;
        if ((t.hsn ?? '').trim().isNotEmpty) score += 3;
        if ((t.company ?? '').trim().isNotEmpty) score++;
        if ((t.pack ?? '').trim().isNotEmpty) score++;
        if ((t.rack ?? '').trim().isNotEmpty) score++;
        if (score > bestScore) {
          bestScore = score;
          bestTpl = t;
        }
      }
      if (bestTpl != null) {
        setState(() {
          line.applyFromStock(
            bestTpl!,
            preservePotency: true,
            preserveProduct: true,
          );
          _mergeTemplateIntoPools(bestTpl);
          line.revision++;
        });
        _recalculate();
        return;
      }

      if (kDebugMode) {
        debugPrint('No stock defaults for potency-only="$potency"');
      }
      setState(() => line.revision++);
    }
  }

  Future<void> _loadMasterDropdowns() async {
    final login = context.read<LoginViewmodel>();
    final flutterSid = login.sessionId ?? '';
    if (flutterSid.isEmpty) return;

    String? webSid;
    try {
      if ((login.loginEmail ?? '').isNotEmpty &&
          (login.loginPassword ?? '').isNotEmpty) {
        webSid = await OdooRpcHelper.cachedWebSessionId(
          db: LoginViewmodel.dbName,
          login: login.loginEmail!,
          password: login.loginPassword!,
        );
      }
    } catch (e) {
      if (kDebugMode) debugPrint('master dropdowns session: $e');
    }
    final sid = (webSid != null && webSid.isNotEmpty) ? webSid : flutterSid;

    // Load potency first (alone) so connection storms don't wipe the master list.
    List<Map<String, String>> potencyRows = const [];
    try {
      potencyRows = await OdooRpcHelper.loadPotencyMasterRows(sid);
    } catch (e) {
      if (kDebugMode) debugPrint('loadPotencyMasterRows: $e');
    }

    final others = await Future.wait([
      OdooRpcHelper.searchGroupNames(sid),
      OdooRpcHelper.searchCompanyNames(sid),
      OdooRpcHelper.searchPackingNames(sid),
    ]);
    if (!mounted) return;

    // Only merge stock/template potencies when the website master failed.
    if (potencyRows.length < 50) {
      final fromTemplates = <String, Map<String, String>>{
        for (final r in potencyRows) (r['name'] ?? '').toLowerCase(): r,
      };
      for (final t in _templates) {
        final p = (t.potency ?? '').trim();
        if (p.isEmpty) continue;
        final key = p.toLowerCase();
        final existing = fromTemplates[key] ?? {'name': p};
        if ((existing['group'] ?? '').isEmpty &&
            (t.group ?? '').trim().isNotEmpty) {
          existing['group'] = t.group!.trim();
        }
        if ((existing['hsn'] ?? '').isEmpty &&
            (t.hsn ?? '').trim().isNotEmpty) {
          existing['hsn'] = t.hsn!.trim();
        }
        if ((existing['company'] ?? '').isEmpty &&
            (t.company ?? '').trim().isNotEmpty) {
          existing['company'] = t.company!.trim();
        }
        if ((existing['pack'] ?? '').isEmpty &&
            (t.pack ?? '').trim().isNotEmpty) {
          existing['pack'] = t.pack!.trim();
        }
        if ((existing['rack'] ?? '').isEmpty &&
            (t.rack ?? '').trim().isNotEmpty) {
          existing['rack'] = t.rack!.trim();
        }
        fromTemplates[key] = existing;
      }
      try {
        final stock = await _fetchStockSearch('');
        for (final s in stock) {
          final p = (s.potency ?? '').trim();
          if (p.isEmpty) continue;
          final key = p.toLowerCase();
          final existing = fromTemplates[key] ?? {'name': p};
          if ((existing['group'] ?? '').isEmpty &&
              (s.group ?? '').trim().isNotEmpty) {
            existing['group'] = s.group!.trim();
          }
          if ((existing['hsn'] ?? '').isEmpty &&
              (s.hsn ?? '').trim().isNotEmpty) {
            existing['hsn'] = s.hsn!.trim();
          }
          if ((existing['company'] ?? '').isEmpty &&
              (s.company ?? '').trim().isNotEmpty) {
            existing['company'] = s.company!.trim();
          }
          if ((existing['pack'] ?? '').isEmpty &&
              (s.packing ?? '').trim().isNotEmpty) {
            existing['pack'] = s.packing!.trim();
          }
          if ((existing['rack'] ?? '').isEmpty &&
              (s.rack ?? '').trim().isNotEmpty) {
            existing['rack'] = s.rack!.trim();
          }
          fromTemplates[key] = existing;
        }
      } catch (e) {
        if (kDebugMode) debugPrint('potency stock fallback: $e');
      }
      potencyRows = fromTemplates.values.toList();
    }

    final potencyNames = potencyRows
        .map((e) => (e['name'] ?? '').trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);

    setState(() {
      _potencyMasterRows
        ..clear()
        ..addAll(potencyRows);
      _addOptsInOrder(_potencies, _potencyKeys, potencyNames);
      _addOptsInOrder(_groups, _groupKeys, others[0]);
      _addOptsInOrder(_companies, _companyKeys, others[1]);
      _addOptsInOrder(_packs, _packKeys, others[2]);
    });

    if (kDebugMode) {
      debugPrint('Loaded website potencies: ${potencyNames.length}');
    }
  }

  Map<String, String>? _potencyMasterDefaults(String potency) {
    final want = potency.trim().toLowerCase();
    if (want.isEmpty) return null;
    for (final row in _potencyMasterRows) {
      final name = (row['name'] ?? '').trim().toLowerCase();
      if (name == want) {
        return Map<String, String>.from(row)..remove('name');
      }
    }
    return null;
  }

  void _applyPotencyDefaultsToLine(
    _BillLine line,
    Map<String, String> defaults, {
    bool onlyEmpty = false,
  }) {
    void setStr(void Function(String? v) assign, String? value, List<String> pool, Set<String> keys) {
      final v = (value ?? '').trim();
      if (v.isEmpty) return;
      assign(v);
      _addOpt(pool, keys, v);
    }

    if (!onlyEmpty || (line.group ?? '').trim().isEmpty) {
      setStr((v) => line.group = v, defaults['group'], _groups, _groupKeys);
    }
    if (!onlyEmpty || line.hsn.trim().isEmpty) {
      final hsn = (defaults['hsn'] ?? '').trim();
      if (hsn.isNotEmpty) {
        line.hsn = hsn;
        _addOpt(_hsns, _hsnKeys, hsn);
      }
    }
    if (!onlyEmpty || line.tax.trim().isEmpty) {
      final tax = (defaults['tax'] ?? '').trim();
      if (tax.isNotEmpty) {
        line.tax = tax;
      }
    }
    line.revision++;
  }

  /// Seed extra values from stock (appended after website master order).
  Future<void> _loadStockSuggestionPools() async {
    final items = await _fetchStockSearch('');
    if (!mounted || items.isEmpty) return;
    setState(() {
      for (final s in items) {
        final t = _LineTemplate.fromStock(s);
        _templates.add(t);
        _mergeTemplateIntoPools(t);
      }
    });
  }

  Future<List<StockItemModel>> _fetchStockSearch(String query) async {
    final login = context.read<LoginViewmodel>();
    final sessionId = login.sessionId ?? '';
    if (sessionId.isEmpty) return const [];

    final trimmed = query.trim();
    final params = <String, dynamic>{
      'get_all': false,
      // Short prefixes (e.g. "PI") need a wider page — server often ignores
      // short search and returns the first page alphabetically.
      'limit': trimmed.length <= 2 ? 300 : 150,
      'offset': 0,
      if (trimmed.isNotEmpty) ...{
        'search': trimmed,
        'medicine': trimmed,
        'medicine_name': trimmed,
        'name': trimmed,
      },
    };

    try {
      final webApi = WebApiImpl();
      final response = await webApi.fetchInvoiceList(
        endpointPath: EndPoint.stockList.path,
        userDetails: ApiRequestHelper.jsonRpcCall(params),
        sessionId: sessionId,
        logResponseBody: false,
        timeout: const Duration(seconds: 45),
      );
      if (response.statusCode != 200) return const [];
      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) return const [];
      final items = StockItemModel.parseList(body);
      if (trimmed.isEmpty) return items;

      final q = trimmed.toLowerCase();
      List<StockItemModel> rank(List<StockItemModel> source) {
        final starts = <StockItemModel>[];
        final contains = <StockItemModel>[];
        for (final item in source) {
          final name = item.medicineLabel.toLowerCase();
          if (name.startsWith(q)) {
            starts.add(item);
          } else if (name.contains(q)) {
            contains.add(item);
          }
        }
        return [...starts, ...contains];
      }

      var ranked = rank(items);
      // Short prefixes often get a useless first page from the server.
      // Fall back to a wider unfiltered page and filter locally.
      if (ranked.isEmpty && trimmed.length <= 2) {
        final broadResponse = await webApi.fetchInvoiceList(
          endpointPath: EndPoint.stockList.path,
          userDetails: ApiRequestHelper.jsonRpcCall({
            'get_all': false,
            'limit': 500,
            'offset': 0,
          }),
          sessionId: sessionId,
          logResponseBody: false,
          timeout: const Duration(seconds: 45),
        );
        if (broadResponse.statusCode == 200) {
          final broadBody = jsonDecode(broadResponse.body);
          if (broadBody is Map<String, dynamic>) {
            ranked = rank(StockItemModel.parseList(broadBody));
          }
        }
      }

      if (ranked.isNotEmpty) return ranked;
      return items;
    } catch (e) {
      if (kDebugMode) debugPrint('stock search: $e');
      return const [];
    }
  }

  bool _sameMedicine(StockItemModel stock, String product) {
    final name = stock.medicineLabel.trim().toLowerCase();
    final target = product.trim().toLowerCase();
    if (name.isEmpty || target.isEmpty) return false;
    return name == target || name.startsWith(target);
  }

  Future<List<StockItemModel>> _stockRowsForProduct(String product) async {
    final target = product.trim();
    if (target.isEmpty) return const [];
    final items = await _fetchStockSearch(target);
    final exact = items
        .where((s) =>
            s.medicineLabel.trim().toLowerCase() == target.toLowerCase())
        .toList(growable: false);
    if (exact.isNotEmpty) return exact;
    return items.where((s) => _sameMedicine(s, target)).toList(growable: false);
  }

  Future<void> _enrichOptionsForProduct(String? product) async {
    if (product == null || product.trim().isEmpty) return;
    final rows = await _stockRowsForProduct(product);
    if (!mounted || rows.isEmpty) return;
    setState(() {
      for (final s in rows) {
        final t = _LineTemplate.fromStock(s);
        _templates.add(t);
        _mergeTemplateIntoPools(t);
      }
    });
  }

  Future<void> _pickProductForLine(_BillLine line) async {
    final stock = await _pickProductFromStock(selected: line.product);
    if (stock == null || !mounted) return;

    final name = stock.medicineLabel.trim();
    setState(() {
      // Website flow: pick product first, then potency.
      // Do not force a default potency from the first stock row.
      final productChanged =
          (line.product ?? '').trim().toLowerCase() != name.toLowerCase();
      line.product = name.isEmpty ? null : name;
      if (productChanged) {
        line.clearRelatedExceptProduct();
        line.stockDisplayId = null;
      }
      if (stock.stockId != null) {
        line.stockDisplayId = stock.stockId;
      }
      if (stock.entryStockId != null) {
        line.entryStockId = stock.entryStockId;
      }
      line.revision++;
      _addOpt(_products, _productKeys, name);
    });

    await _enrichOptionsForProduct(line.product);
    if (!mounted) return;
    _recalculate();
  }

  /// Pick potency / related field (website-style).
  /// Potency can be chosen without product; related fields then fill from stock
  /// rows that share that potency (Group, HSN, …) while product stays blank.
  Future<void> _pickRelatedForLine(
    _BillLine line, {
    required String title,
    required String? Function(StockItemModel s) readField,
    required void Function(String? v) assignField,
    required List<String> pool,
    required Set<String> poolKeys,
    required List<String> fallbackOptions,
  }) async {
    final product = (line.product ?? '').trim();
    final options = <String>[];
    final optionKeys = <String>{};

    if (product.isNotEmpty) {
      final related = await _stockRowsForProduct(product);
      if (!mounted) return;
      for (final s in related) {
        final v = readField(s)?.trim();
        if (v == null || v.isEmpty) continue;
        final key = v.toLowerCase();
        if (optionKeys.add(key)) {
          options.add(v);
        }
        _addOpt(pool, poolKeys, v);
        _mergeTemplateIntoPools(_LineTemplate.fromStock(s));
      }
    }

    // Website allows potency (etc.) without product — use master dropdown.
    if (options.isEmpty || product.isEmpty) {
      for (final o in fallbackOptions) {
        final v = o.trim();
        if (v.isEmpty) continue;
        if (optionKeys.add(v.toLowerCase())) options.add(v);
      }
      for (final o in pool) {
        final v = o.trim();
        if (v.isEmpty) continue;
        if (optionKeys.add(v.toLowerCase())) options.add(v);
      }
    }

    if (options.isEmpty) {
      _toast('No $title options available');
      return;
    }

    final current = switch (title) {
      'Potency' => line.potency,
      'Company' => line.company,
      'Pack' => line.pack,
      'Group' => line.group,
      'BATCH' => line.batch,
      'HSN' => line.hsn,
      'Rack' => line.rack,
      _ => null,
    };

    final picked = await _pickLineValue(
      title: title,
      options: options,
      selected: current,
      rememberInto: pool,
      rememberKeys: poolKeys,
    );
    if (picked == null || !mounted) return;

    setState(() {
      assignField(picked.isEmpty ? null : picked);
      line.revision++;
    });

    // Website: potency → Group / Tax / HSN only; company/pack sync full stock row.
    if (title == 'Potency') {
      await _syncLineFromStock(line, potencyOnly: true);
    } else if (title == 'Company' || title == 'Pack') {
      await _syncLineFromStock(line);
    } else {
      _recalculate();
    }
  }

  Future<void> _pickPotencyForLine(_BillLine line) async {
    if (_potencies.isEmpty || _potencyMasterRows.isEmpty) {
      await _loadMasterDropdowns();
      if (!mounted) return;
    }
    final picked = await _pickLineValue(
      title: 'Potency',
      options: List<String>.from(_potencies),
      selected: line.potency,
      rememberInto: _potencies,
      rememberKeys: _potencyKeys,
    );
    if (picked == null || !mounted) return;

    setState(() {
      line.potency = picked.isEmpty ? null : picked;
      line.revision++;
    });

    await _syncLineFromStock(line, potencyOnly: true);
  }

  String? _primaryAddQrToken(QrData data) {
    final barcode = data.productBarcode?.trim();
    if (barcode != null && barcode.isNotEmpty) return barcode;
    final uid = data.uid?.trim();
    if (uid != null && uid.isNotEmpty) return uid;
    final lineUid = data.lineUid?.trim();
    if (lineUid != null && lineUid.isNotEmpty) return lineUid;
    return null;
  }

  String? _alternateAddQrToken(QrData data, String? primary) {
    final candidates = <String?>[
      data.uid,
      data.lineUid,
      data.productBarcode,
    ];
    for (final c in candidates) {
      final t = c?.trim();
      if (t != null && t.isNotEmpty && t != primary) return t;
    }
    return null;
  }

  void _markLineServerCommitted(
    _BillLine line,
    QrData data,
    double qty, {
    int? invoiceId,
  }) {
    line.serverCommitted = true;
    line.serverCommittedQty += qty;
    line.addedThisSession = true;
    if (invoiceId != null) {
      line.serverInvoiceId = invoiceId;
      _serverInvoiceId = invoiceId;
    }
    final primary = _primaryAddQrToken(data);
    if (primary != null && primary.isNotEmpty) {
      line.addQrData ??= primary;
    }
    if (data.productId != null) {
      line.stockDisplayId ??= data.productId;
    }
    if (data.stockEntryId != null) {
      line.entryStockId ??= data.stockEntryId;
    }
    final alt = _alternateAddQrToken(data, line.addQrData);
    if (alt != null && alt.isNotEmpty) {
      line.addQrDataAlt ??= alt;
    }
  }

  void _addOrUpdateLineFromQr(
    QrData data,
    double qty, {
    int? invoiceId,
  }) {
    String? money(double? v) {
      if (v == null) return null;
      return v == v.roundToDouble()
          ? v.toInt().toString()
          : v.toStringAsFixed(2);
    }

    final product = data.productName?.trim();
    final potency = data.potency?.trim();
    final batch = data.batch?.trim();
    final qtyText = qty == qty.roundToDouble()
        ? qty.toInt().toString()
        : qty.toString();
    final manuf = data.mfd?.trim();
    final unitP = money(data.unitPrice);
    final discount = money(data.discountPercent);

    final existingIndex = _lines.indexWhere((l) {
      final sameProduct =
          (l.product ?? '').trim().toLowerCase() == (product ?? '').toLowerCase();
      final samePotency =
          (l.potency ?? '').trim().toLowerCase() == (potency ?? '').toLowerCase();
      final sameBatch =
          (l.batch ?? '').trim().toLowerCase() == (batch ?? '').toLowerCase();
      return sameProduct && samePotency && sameBatch && (product ?? '').isNotEmpty;
    });

    setState(() {
      if (existingIndex >= 0) {
        final line = _lines[existingIndex];
        final prev = double.tryParse(line.qty) ?? 0;
        line.qty = (prev + qty) == (prev + qty).roundToDouble()
            ? (prev + qty).toInt().toString()
            : (prev + qty).toString();
        // Fill missing website columns if a later scan has them.
        if ((line.manuf == null || line.manuf!.trim().isEmpty) &&
            manuf != null &&
            manuf.isNotEmpty) {
          line.manuf = manuf;
        }
        if (line.unitP.trim().isEmpty && unitP != null) {
          // unitP from scan may be tax-inclusive — recalc from MRP instead.
          _recalcLinePrices(line);
        }
        if (line.discount.trim().isEmpty && discount != null) {
          line.discount = discount;
        }
        _markLineServerCommitted(line, data, qty, invoiceId: invoiceId);
        line.revision++;
      } else {
        final line = _BillLine();
        final t = _LineTemplate(
          product: product?.isEmpty == true ? null : product,
          potency: potency?.isEmpty == true ? null : potency,
          company: data.company?.trim().isEmpty == true
              ? null
              : data.company?.trim(),
          batch: batch?.isEmpty == true ? null : batch,
          manuf: manuf == null || manuf.isEmpty ? null : manuf,
          expiry: data.expiry?.trim().isEmpty == true ? null : data.expiry?.trim(),
          pack: data.packing?.trim().isEmpty == true
              ? null
              : data.packing?.trim(),
          group: data.group?.trim().isEmpty == true ? null : data.group?.trim(),
          mrp: money(data.mrp),
          tax: money(data.tax),
          hsn: data.hsn?.trim().isEmpty == true ? null : data.hsn?.trim(),
          rack: data.rack?.trim().isEmpty == true ? null : data.rack?.trim(),
        );
        line.applyFromStock(t);
        line.qty = qtyText;
        if (discount != null) line.discount = discount;
        _recalcLinePrices(line);
        _markLineServerCommitted(line, data, qty, invoiceId: invoiceId);
        _mergeTemplateIntoPools(t);
        _templates.add(t);
        _lines = [..._lines, line];
        _editingLineIndex = null;
      }
    });
    _recalculate();
  }

  Future<StockItemModel?> _pickProductFromStock({String? selected}) async {
    _dismissKeyboard();

    final result = await showModalBottomSheet<StockItemModel>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xff2c505c),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        var query = '';
        var hits = <StockItemModel>[];
        var loading = false;
        Timer? debounce;
        var searchGeneration = 0;
        var initialLoadDone = false;

        Future<void> runSearch(void Function(void Function()) setModal) async {
          final generation = ++searchGeneration;
          setModal(() => loading = true);
          final items = await _fetchStockSearch(query);
          if (!ctx.mounted || generation != searchGeneration) return;
          setModal(() {
            hits = items;
            loading = false;
          });
        }

        return StatefulBuilder(
          builder: (ctx, setModal) {
            if (!initialLoadDone) {
              initialLoadDone = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                runSearch(setModal);
              });
            }

            final trimmed = query.trim();
            final canCreate = trimmed.isNotEmpty &&
                !hits.any(
                  (item) =>
                      item.medicineLabel.toLowerCase() == trimmed.toLowerCase(),
                ) &&
                !_products.any(
                  (name) => name.toLowerCase() == trimmed.toLowerCase(),
                );

            String subtitle(StockItemModel item) {
              final parts = <String>[
                if ((item.potency ?? '').trim().isNotEmpty) item.potency!.trim(),
                if ((item.company ?? '').trim().isNotEmpty) item.company!.trim(),
                if ((item.batch ?? '').trim().isNotEmpty) 'Batch ${item.batch!.trim()}',
              ];
              return parts.join(' · ');
            }

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(ctx).bottom,
              ),
              child: SafeArea(
                child: SizedBox(
                  height: MediaQuery.sizeOf(ctx).height * 0.75,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
                        child: Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'Product (from stock)',
                                style: TextStyle(
                                  color: sectionText,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: const Text('Close'),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: TextField(
                          autofocus: true,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            hintText: 'Search stock medicines…',
                            hintStyle: TextStyle(
                              color: sectionTextMuted,
                            ),
                            prefixIcon: const Icon(
                              Icons.search,
                              color: sectionTextMuted,
                            ),
                            filled: true,
                            fillColor: Colors.white.withValues(alpha: 0.08),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          onChanged: (v) {
                            setModal(() => query = v);
                            debounce?.cancel();
                            debounce = Timer(
                              const Duration(milliseconds: 350),
                              () => runSearch(setModal),
                            );
                          },
                        ),
                      ),
                      if (canCreate)
                        ListTile(
                          leading: const Icon(Icons.add, color: Color(0xFFE07A2F)),
                          title: Text(
                            'Create "$trimmed"',
                            style: const TextStyle(
                              color: Color(0xFFE07A2F),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          onTap: () {
                            _addOpt(_products, _productKeys, trimmed);
                            Navigator.pop(
                              ctx,
                              StockItemModel(medicine: trimmed),
                            );
                          },
                        ),
                      if (loading)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: CircularProgressIndicator(
                            color: Color(0xFFE07A2F),
                          ),
                        )
                      else if (hits.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            'No stock matches. Type to search or create.',
                            style: TextStyle(color: sectionTextMuted),
                          ),
                        )
                      else
                        Expanded(
                          child: ListView.builder(
                            itemCount: hits.length,
                            itemBuilder: (context, index) {
                              final item = hits[index];
                              final name = item.medicineLabel;
                              final sub = subtitle(item);
                              final isSelected =
                                  selected != null &&
                                  selected.toLowerCase() == name.toLowerCase();
                              return ListTile(
                                title: Text(
                                  name,
                                  style: const TextStyle(color: Colors.white),
                                ),
                                subtitle: sub.isEmpty
                                    ? null
                                    : Text(
                                        sub,
                                        style: const TextStyle(
                                          color: sectionTextMuted,
                                          fontSize: 12,
                                        ),
                                      ),
                                trailing: isSelected
                                    ? const Icon(
                                        Icons.check,
                                        color: Color(0xFFE07A2F),
                                      )
                                    : null,
                                onTap: () => Navigator.pop(ctx, item),
                              );
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    if (mounted) _dismissKeyboardAfterFrame();
    return result;
  }

  Future<_NamedOption?> _pickOrCreateName({
    required String title,
    required List<_NamedOption> options,
    _NamedOption? selected,
    required Future<void> Function(String name) onCreate,
    bool matchContains = false,
  }) async {
    _dismissKeyboard();

    final result = await showModalBottomSheet<_NamedOption>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xff2c505c),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        var query = '';
        return StatefulBuilder(
          builder: (ctx, setModal) {
            final q = query.trim().toLowerCase();
            final filtered = options
                .where((o) {
                  if (q.isEmpty) return true;
                  final name = o.name.toLowerCase();
                  return matchContains ? name.contains(q) : name.startsWith(q);
                })
                .toList(growable: false);
            final canCreate = query.trim().isNotEmpty &&
                !options.any(
                  (o) => o.name.toLowerCase() == query.trim().toLowerCase(),
                );
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(ctx).bottom,
              ),
              child: SafeArea(
                child: SizedBox(
                  height: MediaQuery.sizeOf(ctx).height * 0.75,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                title,
                                style: const TextStyle(
                                  color: sectionText,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                            if (options.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: Text(
                                  '${filtered.length}/${options.length}',
                                  style: TextStyle(
                                    color: sectionTextMuted,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: const Text('Close'),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: TextField(
                          autofocus: true,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            hintText: 'Search or type to create…',
                            hintStyle: TextStyle(
                              color: sectionTextMuted,
                            ),
                            prefixIcon: const Icon(
                              Icons.search,
                              color: sectionTextMuted,
                            ),
                            filled: true,
                            fillColor: Colors.white.withValues(alpha: 0.08),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          onChanged: (v) => setModal(() => query = v),
                        ),
                      ),
                      if (canCreate)
                        ListTile(
                          leading: const Icon(Icons.add, color: const Color(0xFFE07A2F)),
                          title: Text(
                            'Create "${query.trim()}"',
                            style: const TextStyle(
                              color: const Color(0xFFE07A2F),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          onTap: () async {
                            final name = query.trim();
                            await onCreate(name);
                            if (ctx.mounted) {
                              Navigator.pop(ctx, _NamedOption(name: name));
                            }
                          },
                        ),
                      ListTile(
                        title: Text(
                          'Clear selection',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.8),
                          ),
                        ),
                        onTap: () =>
                            Navigator.pop(ctx, const _NamedOption(name: '')),
                      ),
                      const Divider(color: Colors.white24),
                      Expanded(
                        child: filtered.isEmpty
                            ? Center(
                                child: Text(
                                  canCreate
                                      ? 'No matches — create above'
                                      : options.isEmpty
                                          ? 'No saved options — type to create'
                                          : 'Start typing…',
                                  style: const TextStyle(color: sectionTextMuted),
                                ),
                              )
                            : ListView.builder(
                                itemCount: filtered.length,
                                itemBuilder: (_, i) {
                                  final item = filtered[i];
                                  final isSelected =
                                      selected?.name == item.name &&
                                          selected?.id == item.id;
                                  return ListTile(
                                    title: Text(
                                      item.name,
                                      style:
                                          const TextStyle(color: Colors.white),
                                    ),
                                    trailing: isSelected
                                        ? const Icon(
                                            Icons.check,
                                            color: const Color(0xFFE07A2F),
                                          )
                                        : null,
                                    onTap: () => Navigator.pop(ctx, item),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
    // Autofocused search field in the sheet dumps focus onto Address when closed.
    if (mounted) _dismissKeyboardAfterFrame();
    return result;
  }

  Future<String?> _pickLineValue({
    required String title,
    required List<String> options,
    String? selected,
    List<String>? rememberInto,
    Set<String>? rememberKeys,
    bool matchContains = false,
  }) async {
    _dismissKeyboard();
    // Ensure full website potency master is loaded before opening the picker.
    if (title == 'Potency' &&
        (_potencies.length < 50 || _potencyMasterRows.isEmpty)) {
      await _loadMasterDropdowns();
      if (!mounted) return null;
      if (rememberInto == _potencies) {
        options = List<String>.from(_potencies);
      }
    }
    final named = options.map((e) => _NamedOption(name: e)).toList();
    final picked = await _pickOrCreateName(
      title: title == 'Potency' ? 'Search: Potency' : title,
      options: named,
      selected: selected == null || selected.isEmpty
          ? null
          : _NamedOption(name: selected),
      matchContains: matchContains || title == 'Potency',
      onCreate: (name) async {
        final t = name.trim();
        if (t.isEmpty) return;
        if (rememberInto != null) {
          _addOpt(rememberInto, rememberKeys ?? {}, t);
        }
      },
    );
    if (picked == null) return null;
    if (picked.name.isEmpty) return '';
    final t = picked.name.trim();
    if (t.isNotEmpty && rememberInto != null) {
      _addOpt(rememberInto, rememberKeys ?? {}, t);
    }
    return picked.name;
  }

  Future<void> _openScanner() async {
    FocusScope.of(context).unfocus();
    SystemChannels.textInput.invokeMethod('TextInput.hide');

    final login = Provider.of<LoginViewmodel>(context, listen: false);
    if (!await _ensureServerInvoice(login)) {
      _toast('Could not open bill on server. Try Save, then scan again.');
      return;
    }
    if (!mounted) return;

    final result = await AddToCustomerPage.showPopup(
      context,
      lockedInvoiceNumber: _invoiceNumber,
    );
    if (result != null && mounted) {
      _invoiceCommittedOnServer = true;
      if (result.invoiceId != null) _serverInvoiceId = result.invoiceId;
      _addOrUpdateLineFromQr(
        result.data,
        result.qty,
        invoiceId: result.invoiceId,
      );
    }
  }

  bool get _isCreditPayment =>
      (_paymentMode ?? '').trim().toLowerCase().contains('credit');

  /// True when this bill already exists as an Odoo `account.move`.
  bool get _hasServerInvoice =>
      _serverInvoiceId != null ||
      _invoiceCommittedOnServer ||
      widget.editInvoice?.id != null;

  /// Create the draft on the server when the UI only has a local preview number.
  Future<bool> _ensureServerInvoice(LoginViewmodel login) async {
    if (_hasServerInvoice) {
      // Prefer resolving id if we only know the number.
      if (_serverInvoiceId == null && _invoiceNumber.trim().isNotEmpty) {
        try {
          final sid = await _odooSessionId();
          final id = await OdooRpcHelper.findCustomerInvoiceId(
            sid,
            _invoiceNumber,
          );
          if (id != null) {
            _serverInvoiceId = id;
            _invoiceCommittedOnServer = true;
          }
        } catch (e) {
          if (kDebugMode) debugPrint('resolve existing invoice id: $e');
        }
      }
      return _serverInvoiceId != null || widget.editInvoice != null;
    }

    final sessionId = login.sessionId ?? '';
    if (sessionId.isEmpty) return false;

    final known = <String>{
      ...widget.existingNumbers,
      ...widget.existingInvoices.map((e) => e.displayNumber),
    };

    final draft = await InvoiceDraftHelper.createEmptyDraft(
      sessionId: sessionId,
      knownNumbers: known,
      login: login.loginEmail,
      password: login.loginPassword,
      db: LoginViewmodel.dbName,
    );

    if (draft == null) return false;

    if (mounted) {
      setState(() {
        _invoiceNumber = draft.invoiceNumber;
        _serverInvoiceId = draft.invoiceId;
        _invoiceCommittedOnServer = true;
      });
    } else {
      _invoiceNumber = draft.invoiceNumber;
      _serverInvoiceId = draft.invoiceId;
      _invoiceCommittedOnServer = true;
    }

    return true;
  }

  /// Push manually added stock lines to the Odoo draft invoice.
  /// Prefers add_to_invoice when a QR/barcode exists; otherwise writes
  /// pharmacy lines with [stock_entry_id] (manual stock pick has no barcode).
  Future<bool> _commitPendingLines(LoginViewmodel login) async {
    final pending = _lines
        .where(
          (l) =>
              !l.serverCommitted &&
              l.hasRequiredLineFields &&
              InvoiceCalcHelper.parseNum(l.qty) > 0,
        )
        .toList(growable: false);
    if (pending.isEmpty) return true;

    final sid = await _odooSessionId();
    final flutterSid = login.sessionId ?? '';
    if (flutterSid.isEmpty) {
      _toast('Session expired. Please log in again.');
      return false;
    }
    final odooSid = sid.isNotEmpty ? sid : flutterSid;

    final moveId = _serverInvoiceId;
    if (moveId == null || moveId <= 0) {
      _toast('Invoice was not created on server. Try Save again.');
      return false;
    }

    final webApi = WebApiImpl();

    for (var i = 0; i < pending.length; i++) {
      final line = pending[i];
      final qty = InvoiceCalcHelper.parseNum(line.qty);
      final existingToken = (line.addQrData ?? '').trim();
      final stockRow = existingToken.isNotEmpty
          ? null
          : await OdooRpcHelper.findEntryStockRow(
              odooSid,
              stockDisplayId: line.stockDisplayId,
              medicine: line.product,
              batch: line.batch,
              potency: line.potency,
            );

      String? token = existingToken.isNotEmpty ? existingToken : null;
      if (token == null && stockRow != null) {
        for (final key in const [
          'product_barcode',
          'barcode',
          'qr_data',
          'qr_code',
          'uid',
          'default_code',
        ]) {
          final v = stockRow[key]?.toString().trim();
          if (v != null && v.isNotEmpty && v != 'false') {
            token = v;
            break;
          }
        }
      }

      // Path A: Flutter add_to_invoice (QR / barcode).
      if (token != null && token.isNotEmpty) {
        final qtyValue = qty == qty.roundToDouble() ? qty.toInt() : qty;
        final params = <String, dynamic>{
          'invoice_number': _invoiceNumber.trim(),
          'qr_data': token,
          'quantity': qtyValue,
        };
        if (kDebugMode) {
          debugPrint('save add_to_invoice line ${i + 1}: $params');
        }

        try {
          final response = await webApi.addMedicineQty(
            userDetails: ApiRequestHelper.jsonRpcCall(params),
            sessionId: flutterSid,
          );
          if (response.statusCode != 200) {
            _toast('Line ${i + 1}: add failed (HTTP ${response.statusCode})');
            return false;
          }
          final body = json.decode(response.body);
          if (body is! Map<String, dynamic> ||
              !ApiResponseHelper.isSuccess(body)) {
            final message = ApiResponseHelper.errorMessage(
              body is Map<String, dynamic> ? body : const {},
              fallback: 'Failed to add product to bill',
            );
            _toast('Line ${i + 1}: $message');
            return false;
          }

          line.serverCommitted = true;
          line.serverCommittedQty = qty;
          line.addedThisSession = true;
          line.addQrData = token;
          _invoiceCommittedOnServer = true;

          final result = body['result'];
          if (result is Map) {
            final idRaw = result['invoice_id'] ?? result['id'];
            final id = idRaw is int
                ? idRaw
                : int.tryParse(idRaw?.toString() ?? '');
            if (id != null) {
              line.serverInvoiceId = id;
              _serverInvoiceId = id;
            }
            final name =
                (result['invoice_name'] ?? result['invoice_number'] ?? '')
                    .toString()
                    .trim();
            final match = RegExp(r'(\d{3,5}/\d{4}-\d{2})').firstMatch(name);
            if (match != null) {
              _invoiceNumber = match.group(1)!;
            }
          }
          continue;
        } catch (e) {
          if (kDebugMode) debugPrint('commit line ${i + 1} QR path failed: $e');
          // Fall through to stock_entry_id write.
        }
      }

      // Path B: write pharmacy line with stock_entry_id (manual pick).
      if (stockRow == null) {
        _toast(
          'Line ${i + 1}: could not find stock for '
          '${line.product ?? 'product'}. Pick from stock list or use QR scan.',
        );
        return false;
      }

      final unit = InvoiceCalcHelper.parseNum(line.mrp);
      final disc = InvoiceCalcHelper.parseNum(line.discount);
      final ok = await OdooRpcHelper.addStockLineToCustomerInvoice(
        odooSid,
        invoiceId: moveId,
        stockRow: stockRow,
        quantity: qty,
        priceUnit: unit > 0 ? unit : null,
        discount: disc > 0 ? disc : null,
      );
      if (!ok) {
        _toast(
          'Line ${i + 1}: could not add ${line.product ?? 'product'} to bill.',
        );
        return false;
      }

      line.serverCommitted = true;
      line.serverCommittedQty = qty;
      line.addedThisSession = true;
      line.serverInvoiceId = moveId;
      _invoiceCommittedOnServer = true;
    }

    return true;
  }

  /// Push edits on lines that already exist on the server (edit bill).
  Future<bool> _syncCommittedLines(LoginViewmodel login) async {
    final committed = _lines
        .where(
          (l) =>
              l.serverCommitted &&
              l.odooLineId != null &&
              l.odooLineId! > 0 &&
              l.hasRequiredLineFields,
        )
        .toList(growable: false);
    if (committed.isEmpty) return true;

    final sid = await _odooSessionId();
    if (sid.isEmpty) return false;

    for (final line in committed) {
      final qty = InvoiceCalcHelper.parseNum(line.qty);
      final mrp = InvoiceCalcHelper.parseNum(line.mrp);
      final disc = InvoiceCalcHelper.parseNum(line.discount);
      final ok = await OdooRpcHelper.updateCustomerInvoiceLine(
        sid,
        lineId: line.odooLineId!,
        quantity: qty > 0 ? qty : null,
        priceUnit: mrp > 0 ? mrp : null,
        discount: disc,
        batch: line.batch,
        hsn: line.hsn.trim().isEmpty ? null : line.hsn.trim(),
        rack: line.rack.trim().isEmpty ? null : line.rack.trim(),
      );
      if (!ok) {
        _toast(
          'Could not update ${line.product ?? 'line'} on the server.',
        );
        return false;
      }
    }
    return true;
  }

  Future<bool> _syncHeaderToOdoo(LoginViewmodel login) async {
    var moveId = _serverInvoiceId ?? widget.editInvoice?.id;
    if (moveId == null && _invoiceNumber.trim().isNotEmpty) {
      try {
        final email = (login.loginEmail ?? '').trim();
        final pass = login.loginPassword ?? '';
        var sid = login.sessionId ?? '';
        if (email.isNotEmpty && pass.isNotEmpty) {
          final webSid = await OdooRpcHelper.cachedWebSessionId(
            db: LoginViewmodel.dbName,
            login: email,
            password: pass,
          );
          if (webSid != null && webSid.isNotEmpty) sid = webSid;
        }
        moveId = await OdooRpcHelper.findCustomerInvoiceId(
          sid,
          _invoiceNumber,
        );
        if (moveId != null) _serverInvoiceId = moveId;
      } catch (e) {
        if (kDebugMode) debugPrint('resolve invoice id for header: $e');
      }
    }
    if (moveId == null) return false;

    try {
      final email = (login.loginEmail ?? '').trim();
      final pass = login.loginPassword ?? '';
      var sid = login.sessionId ?? '';
      if (email.isNotEmpty && pass.isNotEmpty) {
        final webSid = await OdooRpcHelper.cachedWebSessionId(
          db: LoginViewmodel.dbName,
          login: email,
          password: pass,
        );
        if (webSid != null && webSid.isNotEmpty) sid = webSid;
      }

      final customerName = (_customer?.name ?? '').trim();
      final rate = double.tryParse(_discountRateCtrl.text.trim());
      final ok = await OdooRpcHelper.updateCustomerInvoiceHeader(
        sessionId: sid,
        invoiceId: moveId,
        customerName: customerName,
        pharmacyCustomerId: _customer?.id,
        clearCustomer: customerName.isEmpty,
        address: _addressCtrl.text.trim(),
        phone: _phoneCtrl.text.trim(),
        doctor: (_doctor?.name ?? '').trim(),
        responsiblePersonId: _responsible?.id,
        responsiblePersonName: (_responsible?.name ?? '').trim(),
        paymentMode: _paymentMode,
        gstType: _gstType,
        expiryMedicineBill: _expiryMedicineBill,
        discountCategoryId: _discountCategory?.id,
        clearDiscountCategory: _discountCategory == null,
        discountType: _discountType,
        discountRate: rate,
        remarks: _remarksCtrl.text.trim(),
        verifiedBy: _verifiedByCtrl.text.trim(),
      );
      // Keep local customer id in sync with pharmacy.customer created/resolved.
      if (ok && customerName.isNotEmpty && mounted) {
        final resolved = await OdooRpcHelper.findOrCreatePharmacyCustomer(
          sessionId: sid,
          name: customerName,
          existingId: _customer?.id,
          address: _addressCtrl.text.trim(),
          phone: _phoneCtrl.text.trim(),
        );
        if (resolved != null && mounted) {
          setState(() {
            _customer = (_customer ?? _NamedOption(name: customerName))
                .copyWith(id: resolved);
            if (!_customers.any((c) => c.id == resolved)) {
              _customers = [..._customers, _customer!]
                ..sort(
                  (a, b) =>
                      a.name.toLowerCase().compareTo(b.name.toLowerCase()),
                );
            }
          });
        }
      }
      return ok;
    } catch (e) {
      if (kDebugMode) debugPrint('sync header failed: $e');
      return false;
    }
  }

  /// Save bill — does not create a second empty draft if products were
  /// already added to this invoice via QR / add_to_invoice.
  Future<void> _saveBill() async {
    if (_saving) return;

    final responsibleName = (_responsible?.name ?? '').trim();
    if (_isCreditPayment && responsibleName.isEmpty) {
      _toast('Responsible Person is required for Credit bills');
      return;
    }

    for (var i = 0; i < _lines.length; i++) {
      if (!_lines[i].hasRequiredLineFields) {
        _toast(
          'Line ${i + 1}: Product, Potency, Company, Group, Qty and Mrp are required',
        );
        return;
      }
    }

    setState(() => _saving = true);
    FocusScope.of(context).unfocus();
    SystemChannels.textInput.invokeMethod('TextInput.hide');

    try {
      final login = context.read<LoginViewmodel>();
      final sessionId = login.sessionId ?? '';
      if (sessionId.isEmpty) {
        _toast('Session expired. Please log in again.');
        return;
      }

      final customerName = (_customer?.name ?? '').trim();
      final doctorName = (_doctor?.name ?? '').trim();
      if (customerName.isNotEmpty) {
        await BillNameStore.rememberCustomer(customerName);
      }
      if (doctorName.isNotEmpty) {
        await BillNameStore.rememberDoctor(doctorName);
      }

      // Local preview number is not a real Odoo bill until create / QR add.
      final ensured = await _ensureServerInvoice(login);
      if (!ensured) {
        _toast(
          'Could not create the bill on the server. Please try again.',
        );
        return;
      }

      // Manually added products must go through add_to_invoice (like QR).
      final linesOk = await _commitPendingLines(login);
      if (!linesOk) return;

      final syncedLines = await _syncCommittedLines(login);
      if (!syncedLines) return;

      final synced = await _syncHeaderToOdoo(login);
      if (!synced) {
        _toast(
          'Bill was created but customer details could not be saved. '
          'Open the bill and try again.',
        );
      }

      if (!mounted) return;
      final shown = _invoiceNumber.trim().isEmpty
          ? 'draft'
          : _invoiceNumber.trim();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Bill $shown saved')),
      );
      _billKept = true;
      for (final line in _lines) {
        line.addedThisSession = false;
      }
      Navigator.of(context).pop(true);
    } catch (e) {
      if (kDebugMode) debugPrint('save_bill err: $e');
      _toast('Network error while saving bill');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Returns false (and shows a warning) if the currently expanded line
  /// is missing required fields. [forLineIndex] overrides the editing index.
  bool _warnIfEditingLineIncomplete({int? forLineIndex}) {
    final index = forLineIndex ?? _editingLineIndex;
    if (index == null || index < 0 || index >= _lines.length) return true;
    final line = _lines[index];
    final missing = line.missingRequiredFields;
    if (missing.isEmpty) {
      if (_lineRequiredErrors.isNotEmpty) {
        setState(() => _lineRequiredErrors = {});
      }
      return true;
    }

    setState(() => _lineRequiredErrors = missing.toSet());

    if (missing.length == 1) {
      _toast('Line ${index + 1}: ${missing.first} is required');
    } else {
      _toast(
        'Line ${index + 1}: fill ${missing.join(', ')} before continuing',
      );
    }
    return false;
  }

  void _addLine() {
    if (!_warnIfEditingLineIncomplete()) return;
    setState(() {
      _lines = [..._lines, _BillLine()];
      _editingLineIndex = _lines.length - 1;
      _lineRequiredErrors = {};
    });
    _recalculate();
  }

  void _editLine(int index) {
    if (index == _editingLineIndex) return;
    if (!_warnIfEditingLineIncomplete()) return;
    setState(() {
      _editingLineIndex = index;
      _lineRequiredErrors = {};
    });
  }

  void _doneEditingLine(int index) {
    if (!_warnIfEditingLineIncomplete(forLineIndex: index)) return;
    setState(() {
      _editingLineIndex = null;
      _lineRequiredErrors = {};
    });
  }

  void _adjustEditingIndexAfterRemove(int removedIndex) {
    final editing = _editingLineIndex;
    if (editing == null) return;
    if (editing == removedIndex) {
      _editingLineIndex = null;
    } else if (editing > removedIndex) {
      _editingLineIndex = editing - 1;
    }
  }

  Future<void> _removeLine(int index) async {
    if (_removingLine) return;
    if (index < 0 || index >= _lines.length) return;

    final line = _lines[index];
    final needsRestore =
        line.serverCommitted && line.serverCommittedQty > 0;

    if (!needsRestore) {
      setState(() {
        final next = [..._lines]..removeAt(index);
        _lines = next;
        _adjustEditingIndexAfterRemove(index);
        if (_lines.every((l) => !l.serverCommitted)) {
          _invoiceCommittedOnServer = false;
        }
      });
      _recalculate();
      return;
    }

    setState(() => _removingLine = true);
    try {
      final ok = await _restoreLineStock(line);
      if (!ok) {
        _toast('Could not restore stock for this product. Try again.');
        return;
      }

      if (!mounted) return;
      setState(() {
        final next = [..._lines]..removeAt(index);
        _lines = next;
        _adjustEditingIndexAfterRemove(index);
        if (_lines.every((l) => !l.serverCommitted)) {
          _invoiceCommittedOnServer = false;
        }
      });
      _recalculate();
      _toast('Product removed and stock restored');
    } catch (e) {
      if (kDebugMode) debugPrint('remove_line restore err: $e');
      _toast('Could not restore stock for this product. Try again.');
    } finally {
      if (mounted) setState(() => _removingLine = false);
    }
  }

  Future<bool> _restoreLineStock(_BillLine line) async {
    final login = context.read<LoginViewmodel>();
    final sessionId = login.sessionId ?? '';
    if (sessionId.isEmpty) {
      _toast('Session expired. Please log in again.');
      return false;
    }

    return InvoiceStockRestoreHelper.restoreAfterLineDelete(
      flutterSessionId: sessionId,
      invoiceNumber: _invoiceNumber,
      invoiceId: line.serverInvoiceId ?? _serverInvoiceId,
      quantity: line.serverCommittedQty,
      productName: line.product,
      batch: line.batch,
      potency: line.potency,
      stockEntryId: line.entryStockId,
      login: login.loginEmail,
      password: login.loginPassword,
      db: LoginViewmodel.dbName,
    );
  }

  bool get _hasUnsavedServerLines =>
      _lines.any(
        (l) =>
            l.addedThisSession &&
            l.serverCommitted &&
            l.serverCommittedQty > 0,
      );

  /// Close without Save → restore stock for QR lines added this session.
  Future<void> _discardAndClose() async {
    if (_removingLine || _saving) return;

    if (!_hasUnsavedServerLines) {
      if (mounted) Navigator.of(context).pop(false);
      return;
    }

    setState(() => _removingLine = true);
    try {
      final committed = _lines
          .where(
            (l) =>
                l.addedThisSession &&
                l.serverCommitted &&
                l.serverCommittedQty > 0,
          )
          .toList(growable: false);
      var allOk = true;
      for (final line in committed) {
        final ok = await _restoreLineStock(line);
        if (!ok) allOk = false;
      }
      if (!allOk) {
        _toast('Could not restore all stock. Check the bill and try again.');
        return;
      }
      if (!mounted) return;
      setState(() {
        _lines = [
          for (final l in _lines)
            if (!l.addedThisSession) l,
        ];
        if (_lines.every((l) => !l.serverCommitted)) {
          _invoiceCommittedOnServer = false;
        }
      });
      Navigator.of(context).pop(false);
    } catch (e) {
      if (kDebugMode) debugPrint('discard_and_close err: $e');
      _toast('Could not restore stock while closing. Try again.');
    } finally {
      if (mounted) setState(() => _removingLine = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_hasUnsavedServerLines && !_removingLine && !_saving,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop || _billKept) return;
        if (_hasUnsavedServerLines) {
          await _discardAndClose();
        }
      },
      child: Scaffold(
      backgroundColor: sectionBg,
      appBar: AppBar(
        iconTheme: const IconThemeData(color: sectionText),
        backgroundColor: sectionBg,
        elevation: 0,
        title: Text(
          _invoiceNumber,
          style: const TextStyle(
            color: sectionText,
            fontWeight: FontWeight.w600,
            fontSize: 16,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Scan QR into this bill',
            onPressed: _saving || _removingLine ? null : _openScanner,
            icon: const Icon(Icons.qr_code_scanner, color: Colors.white),
          ),
        ],
      ),
      body: ResponsiveBody(
      child: ListView(
        padding: SystemSafe.listPadding(context, extraBottom: 110),
        children: [
          const Row(
            children: [
              _StatusChip(label: 'Draft', selected: true),
              SizedBox(width: 8),
              _StatusChip(label: 'Open', selected: false),
              SizedBox(width: 8),
              _StatusChip(label: 'Paid', selected: false),
            ],
          ),
          const SizedBox(height: 14),
          const Center(
            child: Text(
              'CASH/CREDIT TAX INVOICE',
              style: TextStyle(
                color: Color(0xFFE53935),
                fontWeight: FontWeight.w800,
                fontSize: 15,
                letterSpacing: 0.3,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  _invoiceNumber,
                  style: const TextStyle(
                    color: Color(0xFFE53935),
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
              ),
              Text(
                _invoiceDateDisplay,
                style: const TextStyle(color: sectionTextMuted, fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _Card(
                  child: Column(
                    children: [
                      _PickerField(
                        label: 'Customer',
                        value: _customer?.name,
                        hint: 'Select or create customer',
                        onTap: () async {
                          final picked = await _pickOrCreateName(
                            title: 'Customer (Pharmacy)',
                            options: _customers,
                            selected: _customer,
                            onCreate: (name) async {
                              await BillNameStore.rememberCustomer(name);
                              // Create pharmacy.customer immediately so website
                              // Customer many2one has a real id on save.
                              try {
                                final sid = await _odooSessionId();
                                if (sid.isEmpty) return;
                                final id =
                                    await OdooRpcHelper.findOrCreatePharmacyCustomer(
                                  sessionId: sid,
                                  name: name,
                                  address: _addressCtrl.text.trim(),
                                  phone: _phoneCtrl.text.trim(),
                                );
                                if (id != null && mounted) {
                                  final opt = _NamedOption(name: name, id: id);
                                  setState(() {
                                    _customers = [..._customers, opt]
                                      ..sort(
                                        (a, b) => a.name.toLowerCase().compareTo(
                                              b.name.toLowerCase(),
                                            ),
                                      );
                                  });
                                }
                              } catch (e) {
                                if (kDebugMode) {
                                  debugPrint('create pharmacy.customer: $e');
                                }
                              }
                            },
                          );
                          if (picked == null || !mounted) return;
                          if (picked.name.isEmpty) {
                            setState(() {
                              _customer = null;
                              _addressCtrl.clear();
                              _phoneCtrl.clear();
                              _paymentMode = 'Cash';
                            });
                            return;
                          }
                          // Prefer newly created option that now has an id.
                          var resolved = picked;
                          if (picked.id == null) {
                            final match = _customers.cast<_NamedOption?>().firstWhere(
                                  (c) =>
                                      c != null &&
                                      c.name.toLowerCase() ==
                                          picked.name.toLowerCase() &&
                                      c.id != null,
                                  orElse: () => null,
                                );
                            if (match != null) resolved = match;
                          }
                          await _applyCustomerSelection(resolved);
                        },
                      ),
                      _TextField(
                        label: 'Phone No',
                        controller: _phoneCtrl,
                        focusNode: _phoneFocus,
                        keyboardType: TextInputType.phone,
                        textInputAction: TextInputAction.next,
                        onSubmitted: (_) =>
                            FocusScope.of(context).requestFocus(_addressFocus),
                      ),
                      _TextField(
                        label: 'Address',
                        controller: _addressCtrl,
                        focusNode: _addressFocus,
                        maxLines: 2,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => FocusScope.of(context).unfocus(),
                      ),
                      _StaticDropdown(
                        label: 'Payment Mode',
                        value: _paymentMode,
                        items: _paymentModes,
                        onChanged: (v) {
                          setState(() => _paymentMode = v);
                          _dismissKeyboardAfterFrame();
                        },
                      ),
                      _PickerField(
                        label: _isCreditPayment
                            ? 'Responsible Person *'
                            : 'Responsible Person',
                        value: _responsible?.name,
                        hint: _isCreditPayment
                            ? 'Required for Credit'
                            : 'Optional',
                        onTap: () async {
                          final picked = await _pickOrCreateName(
                            title: 'Responsible Person',
                            options: _responsiblePeople,
                            selected: _responsible,
                            onCreate: (name) async {
                              // Local-only until website create API exists.
                            },
                          );
                          if (picked == null || !mounted) return;
                          setState(() {
                            _responsible =
                                picked.name.isEmpty ? null : picked;
                            if (picked.name.isNotEmpty &&
                                !_responsiblePeople.any((r) =>
                                    r.name.toLowerCase() ==
                                    picked.name.toLowerCase())) {
                              _responsiblePeople = [
                                ..._responsiblePeople,
                                picked,
                              ]..sort((a, b) => a.name
                                  .toLowerCase()
                                  .compareTo(b.name.toLowerCase()));
                            }
                          });
                        },
                      ),
                      _PickerField(
                        label: 'Doctor',
                        value: _doctor?.name,
                        hint: 'Select or create doctor',
                        onTap: () async {
                          final picked = await _pickOrCreateName(
                            title: 'Doctor',
                            options: _doctors,
                            selected: _doctor,
                            onCreate: BillNameStore.rememberDoctor,
                          );
                          if (picked == null || !mounted) return;
                          setState(() {
                            _doctor = picked.name.isEmpty ? null : picked;
                            if (picked.name.isNotEmpty &&
                                !_doctors.any((d) =>
                                    d.name.toLowerCase() ==
                                    picked.name.toLowerCase())) {
                              _doctors = [..._doctors, picked]
                                ..sort((a, b) => a.name
                                    .toLowerCase()
                                    .compareTo(b.name.toLowerCase()));
                            }
                          });
                        },
                      ),
                      _StaticDropdown(
                        label: 'GST type',
                        value: _gstType,
                        items: _gstTypes,
                        onChanged: (v) {
                          setState(() => _gstType = v);
                          _recalculate();
                          _dismissKeyboardAfterFrame();
                        },
                      ),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Expiry Medicine Bill',
                                style: TextStyle(
                                  color: sectionTextMuted,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            Switch(
                              value: _expiryMedicineBill,
                              activeThumbColor: const Color(0xFFE07A2F),
                              onChanged: (v) =>
                                  setState(() => _expiryMedicineBill = v),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _Card(
                  title: 'Invoice Lines',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_lines.isEmpty)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 8),
                          child: Text(
                            'No lines yet. Add a line or scan a product.',
                            style:
                                TextStyle(color: sectionTextMuted, fontSize: 12),
                          ),
                        ),
                      ..._lines.asMap().entries.map((e) {
                        final i = e.key;
                        final line = e.value;
                        return _LineCard(
                          index: i,
                          line: line,
                          expanded: _editingLineIndex == i,
                          errorFields: _editingLineIndex == i
                              ? _lineRequiredErrors
                              : const <String>{},
                          products: List<String>.from(_products),
                          potencies: List<String>.from(_potencies),
                          companies: List<String>.from(_companies),
                          batches: List<String>.from(_batches),
                          packs: List<String>.from(_packs),
                          groups: List<String>.from(_groups),
                          hsns: List<String>.from(_hsns),
                          racks: List<String>.from(_racks),
                          productPool: _products,
                          potencyPool: _potencies,
                          companyPool: _companies,
                          batchPool: _batches,
                          packPool: _packs,
                          groupPool: _groups,
                          hsnPool: _hsns,
                          rackPool: _racks,
                          onPick: _pickLineValue,
                          onPickProduct: () => _pickProductForLine(line),
                          onPickPotency: () => _pickPotencyForLine(line),
                          onPickCompany: () => _pickRelatedForLine(
                            line,
                            title: 'Company',
                            readField: (s) => s.company,
                            assignField: (v) => line.company = v,
                            pool: _companies,
                            poolKeys: _companyKeys,
                            fallbackOptions: List<String>.from(_companies),
                          ),
                          onPickPack: () => _pickRelatedForLine(
                            line,
                            title: 'Pack',
                            readField: (s) => s.packing,
                            assignField: (v) => line.pack = v,
                            pool: _packs,
                            poolKeys: _packKeys,
                            fallbackOptions: List<String>.from(_packs),
                          ),
                          onPickGroup: () => _pickRelatedForLine(
                            line,
                            title: 'Group',
                            readField: (s) => s.group,
                            assignField: (v) => line.group = v,
                            pool: _groups,
                            poolKeys: _groupKeys,
                            fallbackOptions: List<String>.from(_groups),
                          ),
                          onPickBatch: () => _pickRelatedForLine(
                            line,
                            title: 'BATCH',
                            readField: (s) => s.batch,
                            assignField: (v) => line.batch = v,
                            pool: _batches,
                            poolKeys: _batchKeys,
                            fallbackOptions: List<String>.from(_batches),
                          ),
                          onPickHsn: () => _pickRelatedForLine(
                            line,
                            title: 'HSN',
                            readField: (s) => s.hsn,
                            assignField: (v) => line.hsn = v ?? '',
                            pool: _hsns,
                            poolKeys: _hsnKeys,
                            fallbackOptions: List<String>.from(_hsns),
                          ),
                          onPickRack: () => _pickRelatedForLine(
                            line,
                            title: 'Rack',
                            readField: (s) => s.rack,
                            assignField: (v) => line.rack = v ?? '',
                            pool: _racks,
                            poolKeys: _rackKeys,
                            fallbackOptions: List<String>.from(_racks),
                          ),
                          onChanged: () {
                            // Clear red highlights for fields the user just filled.
                            final missing = line.missingRequiredFields.toSet();
                            if (_lineRequiredErrors.isNotEmpty) {
                              final next = _lineRequiredErrors
                                  .where(missing.contains)
                                  .toSet();
                              if (next.length != _lineRequiredErrors.length) {
                                _lineRequiredErrors = next;
                              }
                            }
                            _recalcLinePrices(line);
                            setState(() {});
                            _recalculate();
                          },
                          onEdit: () => _editLine(i),
                          onDone: () => _doneEditingLine(i),
                          onDelete: _removingLine
                              ? null
                              : () {
                                  _removeLine(i);
                                },
                        );
                      }),
                      TextButton.icon(
                        onPressed: _addLine,
                        icon: const Icon(Icons.add, color: const Color(0xFFE07A2F)),
                        label: const Text(
                          'Add a line',
                          style: TextStyle(
                            color: const Color(0xFFE07A2F),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _Card(
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: _StaticDropdown(
                                label: 'Discount Category',
                                value: _discountCategory?.name,
                                items: _discountCategories
                                    .map((e) => e.name)
                                    .toList(),
                                onChanged: (v) {
                                  if (v == null || v.isEmpty) {
                                    _applyDiscountCategory(null);
                                    return;
                                  }
                                  _DiscountCategoryOption? match;
                                  for (final c in _discountCategories) {
                                    if (c.name.toLowerCase() == v.toLowerCase()) {
                                      match = c;
                                      break;
                                    }
                                  }
                                  _applyDiscountCategory(match);
                                },
                              ),
                            ),
                            if (_discountCategory != null)
                              IconButton(
                                tooltip: 'Clear discount category',
                                onPressed: () => _applyDiscountCategory(null),
                                icon: const Icon(
                                  Icons.delete_outline,
                                  color: Colors.redAccent,
                                ),
                              ),
                          ],
                        ),
                      ),
                      _StaticDropdown(
                        label: 'Discount Type',
                        value: _discountType,
                        items: _discountTypes,
                        onChanged: (v) {
                          setState(() => _discountType = v);
                          _recalculate();
                          _dismissKeyboardAfterFrame();
                        },
                      ),
                      _TextField(
                        label: (_discountType ?? 'Percentage')
                                .toLowerCase()
                                .contains('rupee')
                            ? 'Discount Rate (₹)'
                            : 'Discount Rate (%)',
                        controller: _discountRateCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                      ),
                      const _ReadRow('Billed By', 'Administrator'),
                      const _ReadRow('Status', 'Draft'),
                      _TextField(
                        label: 'Verified By',
                        controller: _verifiedByCtrl,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _Card(
                  child: Column(
                    children: [
                      _MoneyRow('Subtotal', _totals.subtotal),
                      _MoneyRow('Discount Total', _totals.discountTotal),
                      _MoneyRow('Tax', _totals.tax),
                      _TextField(
                        label: 'Expense Amt',
                        controller: _expenseCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                      ),
                      _MoneyRow('Expense Amt', _totals.expenseAmt),
                      _MoneyRow('Total', _totals.total, emphasize: true),
                      _MoneyRow('Tax Amount', _totals.taxAmount),
                      _MoneyRow('Balance', _totals.balance, emphasize: true),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _Card(
                  child: _TextField(
                    label: 'Remarks',
                    controller: _remarksCtrl,
                    maxLines: 3,
                  ),
                ),
              ],
            ),
            ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            AppResponsive.of(context).pagePadding,
            8,
            AppResponsive.of(context).pagePadding,
            SystemSafe.actionBarBottomPadding(context),
          ),
          child: Row(
            children: [
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFE07A2F),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: _saving ? null : _saveBill,
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Save'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: sectionTextMuted),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: _saving || _removingLine ? null : _discardAndClose,
                  child: const Text('Close'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
    );
  }
}

class _LineCard extends StatefulWidget {
  const _LineCard({
    required this.index,
    required this.line,
    required this.expanded,
    required this.errorFields,
    required this.products,
    required this.potencies,
    required this.companies,
    required this.batches,
    required this.packs,
    required this.groups,
    required this.hsns,
    required this.racks,
    required this.productPool,
    required this.potencyPool,
    required this.companyPool,
    required this.batchPool,
    required this.packPool,
    required this.groupPool,
    required this.hsnPool,
    required this.rackPool,
    required this.onPick,
    required this.onPickProduct,
    required this.onPickPotency,
    required this.onPickCompany,
    required this.onPickPack,
    required this.onPickGroup,
    required this.onPickBatch,
    required this.onPickHsn,
    required this.onPickRack,
    required this.onChanged,
    required this.onEdit,
    required this.onDone,
    required this.onDelete,
  });

  final int index;
  final _BillLine line;
  final bool expanded;
  final Set<String> errorFields;
  final List<String> products;
  final List<String> potencies;
  final List<String> companies;
  final List<String> batches;
  final List<String> packs;
  final List<String> groups;
  final List<String> hsns;
  final List<String> racks;
  final List<String> productPool;
  final List<String> potencyPool;
  final List<String> companyPool;
  final List<String> batchPool;
  final List<String> packPool;
  final List<String> groupPool;
  final List<String> hsnPool;
  final List<String> rackPool;
  final Future<String?> Function({
    required String title,
    required List<String> options,
    String? selected,
    List<String>? rememberInto,
    Set<String>? rememberKeys,
  }) onPick;
  final Future<void> Function() onPickProduct;
  final Future<void> Function() onPickPotency;
  final Future<void> Function() onPickCompany;
  final Future<void> Function() onPickPack;
  final Future<void> Function() onPickGroup;
  final Future<void> Function() onPickBatch;
  final Future<void> Function() onPickHsn;
  final Future<void> Function() onPickRack;
  final VoidCallback onChanged;
  final VoidCallback onEdit;
  final VoidCallback onDone;
  final VoidCallback? onDelete;

  @override
  State<_LineCard> createState() => _LineCardState();
}

class _LineCardState extends State<_LineCard> {
  late final FocusNode _manufFocus;
  late final FocusNode _expiryFocus;
  late final FocusNode _qtyFocus;
  late final FocusNode _mrpFocus;
  late final FocusNode _disFocus;
  late final FocusNode _unitPFocus;
  late final FocusNode _taxFocus;

  late final TextEditingController _manufCtrl;
  late final TextEditingController _expiryCtrl;
  late final TextEditingController _qtyCtrl;
  late final TextEditingController _mrpCtrl;
  late final TextEditingController _disCtrl;
  late final TextEditingController _unitPCtrl;
  late final TextEditingController _taxCtrl;

  @override
  void initState() {
    super.initState();
    final line = widget.line;
    _manufFocus = FocusNode();
    _expiryFocus = FocusNode();
    _qtyFocus = FocusNode();
    _mrpFocus = FocusNode();
    _disFocus = FocusNode();
    _unitPFocus = FocusNode();
    _taxFocus = FocusNode();
    _manufCtrl = TextEditingController(text: line.manuf ?? '');
    _expiryCtrl = TextEditingController(text: line.expiry ?? '');
    _qtyCtrl = TextEditingController(text: line.qty);
    _mrpCtrl = TextEditingController(text: line.mrp);
    _disCtrl = TextEditingController(text: line.discount);
    _unitPCtrl = TextEditingController(text: line.unitP);
    _taxCtrl = TextEditingController(text: line.tax);
  }

  @override
  void dispose() {
    _manufFocus.dispose();
    _expiryFocus.dispose();
    _qtyFocus.dispose();
    _mrpFocus.dispose();
    _disFocus.dispose();
    _unitPFocus.dispose();
    _taxFocus.dispose();
    _manufCtrl.dispose();
    _expiryCtrl.dispose();
    _qtyCtrl.dispose();
    _mrpCtrl.dispose();
    _disCtrl.dispose();
    _unitPCtrl.dispose();
    _taxCtrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _LineCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.line.revision != widget.line.revision) {
      _syncControllersFromLine();
    }
  }

  void _syncControllersFromLine() {
    final line = widget.line;
    _manufCtrl.text = line.manuf ?? '';
    _expiryCtrl.text = line.expiry ?? '';
    _qtyCtrl.text = line.qty;
    _mrpCtrl.text = line.mrp;
    _disCtrl.text = line.discount;
    _unitPCtrl.text = line.unitP;
    _taxCtrl.text = line.tax;
  }

  void _moveTo(FocusNode next) {
    FocusScope.of(context).requestFocus(next);
  }

  @override
  Widget build(BuildContext context) {
    final line = widget.line;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(10),
      ),
      child: widget.expanded ? _buildExpanded(line) : _buildCollapsed(line),
    );
  }

  Widget _buildCollapsed(_BillLine line) {
    final qty = InvoiceCalcHelper.parseNum(line.qty);
    final mrp = InvoiceCalcHelper.parseNum(line.mrp);
    final disc = InvoiceCalcHelper.parseNum(line.discount);
    final taxPct = InvoiceCalcHelper.parseNum(line.tax);
    final unitTp = InvoiceCalcHelper.parseNum(line.unitP) > 0
        ? InvoiceCalcHelper.parseNum(line.unitP)
        : (disc > 0 ? mrp * (1 - disc / 100.0) : mrp);
    // Column totals exclude tax (bill footer handles GST).
    final total = qty > 0 && unitTp > 0 ? qty * unitTp : 0.0;

    String fmtNum(double? v) =>
        v == null ? '—' : v.toStringAsFixed(v == v.roundToDouble() ? 0 : 2);
    String fmtMoney(double? v) => InvoiceSummaryModel.formatMoney(v);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                line.product?.trim().isNotEmpty == true
                    ? line.product!
                    : 'Line ${widget.index + 1}',
                style: const TextStyle(
                  color: sectionText,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Edit',
              onPressed: widget.onEdit,
              icon: const Icon(Icons.edit_outlined, color: sectionTextMuted, size: 20),
            ),
            IconButton(
              tooltip: 'Delete',
              onPressed: widget.onDelete,
              icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
            ),
          ],
        ),
        const SizedBox(height: 4),
        _CompactLineRow(
          left: _CompactField('Potency', line.potency),
          right: _CompactField('Company', line.company),
        ),
        _CompactLineRow(
          left: _CompactField('BATCH', line.batch),
          right: _CompactField('MFD', line.manuf),
        ),
        _CompactLineRow(
          left: _CompactField('EXPIRY', line.expiry),
          right: _CompactField('Pack', line.pack),
        ),
        _CompactLineRow(
          left: _CompactField('Group', line.group),
          right: _CompactField('Qty', fmtNum(qty > 0 ? qty : null)),
        ),
        _CompactLineRow(
          left: _CompactField('Mrp', fmtMoney(mrp > 0 ? mrp : null)),
          right: _CompactField('Dis', fmtNum(disc > 0 ? disc : null)),
        ),
        _CompactLineRow(
          left: _CompactField('Unit TP', fmtMoney(unitTp > 0 ? unitTp : null)),
          right: _CompactField('Unit P', fmtMoney(unitTp > 0 ? unitTp : null)),
        ),
        _CompactLineRow(
          left: _CompactField('Tax', fmtNum(taxPct > 0 ? taxPct : null)),
          right: _CompactField('Tax Amt', '—'),
        ),
        _CompactLineRow(
          left: _CompactField('Total', fmtMoney(total > 0 ? total : null),
              emphasize: true),
          right: _CompactField('Hsn', line.hsn.isEmpty ? null : line.hsn),
        ),
        _CompactLineRow(
          left: _CompactField('Rack', line.rack.isEmpty ? null : line.rack),
          right: _CompactField('', null),
        ),
      ],
    );
  }

  Widget _buildExpanded(_BillLine line) {
    bool err(String field) => widget.errorFields.contains(field);

    Future<void> afterPick() async {
      if (!mounted) return;
      _syncControllersFromLine();
      widget.onChanged();
      setState(() {});
    }

    return Column(
      children: [
        Row(
          children: [
            Text(
              'Line ${widget.index + 1}',
              style: const TextStyle(
                color: sectionText,
                fontWeight: FontWeight.w700,
              ),
            ),
            const Spacer(),
            TextButton(
              onPressed: widget.onDone,
              child: const Text(
                'Done',
                style: TextStyle(color: Color(0xFFE07A2F)),
              ),
            ),
            IconButton(
              onPressed: widget.onDelete,
              icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
            ),
          ],
        ),
        _LineDropdownRow(
          label: 'Product *',
          value: line.product,
          highlightError: err('Product'),
          onTap: () async {
            await widget.onPickProduct();
            await afterPick();
          },
        ),
        _LineDropdownRow(
          label: 'Potency *',
          value: line.potency,
          highlightError: err('Potency'),
          onTap: () async {
            await widget.onPickPotency();
            await afterPick();
          },
        ),
        _LineDropdownRow(
          label: 'Company *',
          value: line.company,
          highlightError: err('Company'),
          onTap: () async {
            await widget.onPickCompany();
            await afterPick();
          },
        ),
        _LineDropdownRow(
          label: 'BATCH',
          value: line.batch,
          onTap: () async {
            await widget.onPickBatch();
            await afterPick();
          },
        ),
        _LineTextRow(
          label: 'MANUF (MM/YYYY)',
          controller: _manufCtrl,
          focusNode: _manufFocus,
          textInputAction: TextInputAction.next,
          onChanged: (v) {
            line.manuf = v;
            widget.onChanged();
          },
          onNext: () => _moveTo(_expiryFocus),
        ),
        _LineTextRow(
          label: 'EXPIRY (MM/YYYY)',
          controller: _expiryCtrl,
          focusNode: _expiryFocus,
          textInputAction: TextInputAction.next,
          onChanged: (v) {
            line.expiry = v;
            widget.onChanged();
          },
          onNext: () => _moveTo(_qtyFocus),
        ),
        _LineDropdownRow(
          label: 'Pack',
          value: line.pack,
          onTap: () async {
            await widget.onPickPack();
            await afterPick();
          },
        ),
        _LineDropdownRow(
          label: 'Group *',
          value: line.group,
          highlightError: err('Group'),
          onTap: () async {
            await widget.onPickGroup();
            await afterPick();
          },
        ),
        _LineTextRow(
          label: 'Qty *',
          controller: _qtyCtrl,
          focusNode: _qtyFocus,
          highlightError: err('Qty'),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          textInputAction: TextInputAction.next,
          onChanged: (v) {
            line.qty = v;
            widget.onChanged();
          },
          onNext: () => _moveTo(_mrpFocus),
        ),
        _LineTextRow(
          label: 'Mrp *',
          controller: _mrpCtrl,
          focusNode: _mrpFocus,
          highlightError: err('Mrp'),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          textInputAction: TextInputAction.next,
          onChanged: (v) {
            line.mrp = v;
            widget.onChanged();
          },
          onNext: () => _moveTo(_disFocus),
        ),
        _LineTextRow(
          label: 'Dis',
          controller: _disCtrl,
          focusNode: _disFocus,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          textInputAction: TextInputAction.next,
          onChanged: (v) {
            line.discount = v;
            widget.onChanged();
          },
          onNext: () => _moveTo(_taxFocus),
        ),
        _LineReadOnlyRow(
          label: 'Unit TP',
          value: line.unitP.trim().isEmpty ? null : line.unitP,
        ),
        _LineReadOnlyRow(
          label: 'Unit P',
          value: line.unitP.trim().isEmpty ? null : line.unitP,
        ),
        _LineTextRow(
          label: 'Tax',
          controller: _taxCtrl,
          focusNode: _taxFocus,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          textInputAction: TextInputAction.done,
          onChanged: (v) {
            line.tax = v;
            widget.onChanged();
          },
          onNext: () => FocusScope.of(context).unfocus(),
        ),
        _LineDropdownRow(
          label: 'Hsn',
          value: line.hsn.isEmpty ? null : line.hsn,
          onTap: () async {
            await widget.onPickHsn();
            await afterPick();
          },
        ),
        _LineDropdownRow(
          label: 'Rack',
          value: line.rack.isEmpty ? null : line.rack,
          onTap: () async {
            await widget.onPickRack();
            await afterPick();
          },
        ),
      ],
    );
  }
}

class _CompactLineRow extends StatelessWidget {
  const _CompactLineRow({required this.left, required this.right});

  final _CompactField left;
  final _CompactField right;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: AdaptiveSplit(
        start: left,
        end: right,
      ),
    );
  }
}

class _CompactField extends StatelessWidget {
  const _CompactField(this.label, this.value, {this.emphasize = false});

  final String label;
  final String? value;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    final text = (value == null || value!.trim().isEmpty) ? '—' : value!;
    return RichText(
      text: TextSpan(
        style: TextStyle(
          color: sectionTextMuted,
          fontSize: 10,
        ),
        children: [
          TextSpan(text: '$label: '),
          TextSpan(
            text: text,
            style: TextStyle(
              color: sectionText,
              fontWeight: emphasize ? FontWeight.w700 : FontWeight.w500,
              fontSize: emphasize ? 12 : 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _LineDropdownRow extends StatelessWidget {
  const _LineDropdownRow({
    required this.label,
    required this.onTap,
    this.value,
    this.highlightError = false,
  });

  final String label;
  final String? value;
  final VoidCallback onTap;
  final bool highlightError;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        child: Row(
          children: [
            SizedBox(
              width: 110,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                decoration: highlightError
                    ? BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.22),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.redAccent),
                      )
                    : null,
                child: Text(
                  label,
                  style: TextStyle(
                    color: highlightError
                        ? Colors.redAccent
                        : Colors.white.withValues(alpha: 0.65),
                    fontSize: 12,
                    fontWeight:
                        highlightError ? FontWeight.w700 : FontWeight.w400,
                  ),
                ),
              ),
            ),
            Expanded(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                decoration: BoxDecoration(
                  color: sectionCard,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: highlightError
                        ? Colors.redAccent
                        : Colors.white.withValues(alpha: 0.2),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        (value == null || value!.isEmpty) ? 'Select' : value!,
                        style: TextStyle(
                          color: (value == null || value!.isEmpty)
                              ? Colors.white54
                              : Colors.white,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    const Icon(Icons.arrow_drop_down, color: sectionTextMuted),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LineReadOnlyRow extends StatelessWidget {
  const _LineReadOnlyRow({required this.label, this.value});

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: TextStyle(
                color: sectionTextMuted,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: sectionCard),
              ),
              child: Text(
                (value == null || value!.trim().isEmpty) ? '—' : value!,
                style: const TextStyle(color: sectionTextMuted, fontSize: 13),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LineTextRow extends StatelessWidget {
  const _LineTextRow({
    required this.label,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onNext,
    this.keyboardType,
    this.textInputAction = TextInputAction.next,
    this.highlightError = false,
  });

  final String label;
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onNext;
  final TextInputType? keyboardType;
  final TextInputAction textInputAction;
  final bool highlightError;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              decoration: highlightError
                  ? BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.redAccent),
                    )
                  : null,
              child: Text(
                label,
                style: TextStyle(
                  color: highlightError
                      ? Colors.redAccent
                      : Colors.white.withValues(alpha: 0.65),
                  fontSize: 12,
                  fontWeight:
                      highlightError ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              keyboardType: keyboardType,
              textInputAction: textInputAction,
              style: const TextStyle(color: sectionText, fontSize: 13),
              onChanged: onChanged,
              onSubmitted: (_) => onNext(),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.08),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                    color: highlightError
                        ? Colors.redAccent
                        : Colors.white.withValues(alpha: 0.2),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                    color: highlightError
                        ? Colors.redAccent
                        : const Color(0xFFE07A2F),
                  ),
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.selected});

  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: selected
              ? sectionBg
              : Colors.black.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selected) ...[
            const Icon(Icons.check, size: 14, color: sectionBg),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: const TextStyle(
              color: Colors.black,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child, this.title});

  final Widget child;
  final String? title;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: sectionCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: sectionCardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Text(
              title!,
              style: const TextStyle(
                color: sectionText,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 10),
          ],
          child,
        ],
      ),
    );
  }
}

class _TextField extends StatelessWidget {
  const _TextField({
    required this.label,
    required this.controller,
    this.focusNode,
    this.keyboardType,
    this.maxLines = 1,
    this.textInputAction,
    this.onSubmitted,
  });

  final String label;
  final TextEditingController controller;
  final FocusNode? focusNode;
  final TextInputType? keyboardType;
  final int maxLines;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: sectionTextMuted,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 4),
          TextField(
            controller: controller,
            focusNode: focusNode,
            keyboardType: keyboardType,
            maxLines: maxLines,
            textInputAction: textInputAction,
            onSubmitted: onSubmitted,
            style: const TextStyle(color: sectionText, fontSize: 14),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.08),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PickerField extends StatelessWidget {
  const _PickerField({
    required this.label,
    required this.onTap,
    this.value,
    this.hint,
  });

  final String label;
  final String? value;
  final String? hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = (value ?? '').trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: sectionTextMuted,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 4),
          Material(
            color: sectionCard,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: onTap,
              child: Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border:
                      Border.all(color: sectionCardBorder),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        text.isEmpty ? (hint ?? 'Select') : text,
                        style: TextStyle(
                          color: text.isEmpty
                              ? Colors.white.withValues(alpha: 0.45)
                              : Colors.white,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const Icon(Icons.arrow_drop_down, color: sectionTextMuted),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StaticDropdown extends StatelessWidget {
  const _StaticDropdown({
    required this.label,
    required this.items,
    required this.onChanged,
    this.value,
  });

  final String label;
  final String? value;
  final List<String> items;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: sectionTextMuted,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: sectionCard,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: sectionCardBorder),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: value,
                hint: Text(
                  'Optional',
                  style: TextStyle(
                    color: sectionTextMuted,
                  ),
                ),
                isExpanded: true,
                dropdownColor: const Color(0xff2c505c),
                iconEnabledColor: Colors.white70,
                style: const TextStyle(color: sectionText, fontSize: 14),
                items: items
                    .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                    .toList(),
                onChanged: (v) {
                  // Apply value first; unfocus after the dropdown finishes
                  // its own focus restore (otherwise Address steals the caret).
                  onChanged(v);
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    FocusManager.instance.primaryFocus?.unfocus();
                    SystemChannels.textInput.invokeMethod('TextInput.hide');
                  });
                },
                onTap: () {
                  FocusManager.instance.primaryFocus?.unfocus();
                  SystemChannels.textInput.invokeMethod('TextInput.hide');
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReadRow extends StatelessWidget {
  const _ReadRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(
                color: sectionTextMuted,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: sectionText, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _MoneyRow extends StatelessWidget {
  const _MoneyRow(this.label, this.value, {this.emphasize = false});

  final String label;
  final double value;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: sectionTextMuted,
                fontSize: 12,
              ),
            ),
          ),
          Text(
            InvoiceSummaryModel.formatMoney(value),
            style: TextStyle(
              color: Colors.white,
              fontSize: emphasize ? 15 : 12,
              fontWeight: emphasize ? FontWeight.w800 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
