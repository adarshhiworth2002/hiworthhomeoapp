import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/invoice_summary_model.dart';
import '../../models/stock_item_model.dart';
import '../../viewModels/customer_invoice_viewmodel.dart';
import '../../viewModels/customer_med_viewModel.dart';
import '../../viewModels/login_viewmodel.dart';
import '../services/WebApi/web_api_impl.dart';
import '../services/api_request_helper.dart';
import '../services/api_response_helper.dart';
import '../services/bill_name_store.dart';
import '../services/calendar_date.dart';
import '../services/endPoints.dart';
import '../services/invoice_calc_helper.dart';
import '../services/invoice_detail_service.dart';
import '../services/invoice_draft_helper.dart';
import '../services/invoice_helper.dart';
import '../services/appConfig.dart';
import '../services/auth_session_store.dart';
import '../services/flutter_customer_invoice_web_api.dart';
import '../services/invoice_stock_restore_helper.dart';
import '../services/live_data_sync.dart';
import '../services/odoo_rpc_helper.dart';
import '../services/payment_book_service.dart';
import '../services/payment_history_service.dart';
import '../services/stock_date_parser.dart';
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
    this.creditLimitAmount,
  });

  final String name;
  final int? id;
  final String? address;
  final String? phone;
  /// Website payment mode label: Cash / Credit / …
  final String? defaultPaymentMode;
  /// `pharmacy.customer.credit_limit_amount` from Odoo.
  final double? creditLimitAmount;

  _NamedOption copyWith({
    String? name,
    int? id,
    String? address,
    String? phone,
    String? defaultPaymentMode,
    double? creditLimitAmount,
  }) {
    return _NamedOption(
      name: name ?? this.name,
      id: id ?? this.id,
      address: address ?? this.address,
      phone: phone ?? this.phone,
      defaultPaymentMode: defaultPaymentMode ?? this.defaultPaymentMode,
      creditLimitAmount: creditLimitAmount ?? this.creditLimitAmount,
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
  /// True when [discount] was filled from Price Category Group Discount rules.
  bool discountAutoFromCategory = false;
  /// True only when the user typed Dis manually (do not overwrite).
  bool discountUserEdited = false;
  /// Tax-inclusive trade price (MRP − line discount).
  String unitTp = '';
  /// Tax-exclusive unit price.
  String unitP = '';
  String tax = '';
  String hsn = '';
  String rack = '';
  /// Read-only sellable qty shown when product is picked From stock.
  String? availableStock;
  /// Warehouse sellable qty from last QR/stock fetch (before this bill's reserve).
  /// Available Stock = [warehouseStockBase] − reserved line qty on this bill.
  double? warehouseStockBase;
  /// When true, product is taken from stock and save deducts sellable qty.
  /// When false, free-text medicine name; bill line does not affect stock.
  bool fromStock = true;

  double get taxAmtValue {
    final tp = InvoiceCalcHelper.parseNum(unitTp);
    final up = InvoiceCalcHelper.parseNum(unitP);
    if (tp <= 0) return 0;
    final diff = tp - up;
    return diff < 0 ? 0 : diff;
  }

  /// Set when this line was added via QR / add_to_invoice (stock already deducted).
  bool serverCommitted = false;
  /// Qty already deducted on the server for this line.
  double serverCommittedQty = 0;
  /// True when QR-added during this page session (restore on Close without Save).
  bool addedThisSession = false;
  /// True only when [OdooRpcHelper.addStockLineToCustomerInvoice] deducted
  /// `item_qty`. Flutter `add_to_invoice` leaves `item_qty` alone and Odoo
  /// restores sellable `stock` on unlink — bumping `item_qty` then double-counts.
  bool rpcAdjustedItemQty = false;
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

  /// Empty "Add a line" draft — no product and not yet on the server.
  bool get isBlankDraft =>
      !serverCommitted && (product ?? '').trim().isEmpty;

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
        bool preserveCompany = false,
        bool preservePack = false,
      }) {
    final keptPotency = potency;
    final keptProduct = product;
    final keptCompany = company;
    final keptPack = pack;
    if (!preserveProduct && t.product != null) product = t.product;
    if (!preservePotency && t.potency != null) potency = t.potency;
    if (!preserveCompany && t.company != null) company = t.company;
    if (t.batch != null) batch = t.batch;
    if (t.manuf != null) manuf = t.manuf;
    if (t.expiry != null) expiry = t.expiry;
    if (!preservePack && t.pack != null) pack = t.pack;
    if (t.group != null) group = t.group;
    if (t.mrp != null) mrp = t.mrp!;
    if (t.tax != null) tax = t.tax!;
    if (t.hsn != null) hsn = t.hsn!;
    if (t.rack != null) rack = t.rack!;
    if (preserveProduct) product = keptProduct;
    if (preservePotency) potency = keptPotency;
    if (preserveCompany) company = keptCompany;
    if (preservePack) pack = keptPack;
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
    unitTp = '';
    unitP = '';
    availableStock = null;
    warehouseStockBase = null;
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
    String? displayDate(String? raw) {
      final t = (raw ?? '').trim();
      if (t.isEmpty) return null;
      return StockDateParser.tryParse(t) ?? t;
    }

    // Bill UI "MFD" column stores manufacture date in [manuf], not company name.
    return _LineTemplate(
      product: l.productName,
      potency: l.potency,
      company: l.company,
      batch: l.batch,
      manuf: displayDate(l.mfd) ?? displayDate(l.manufacturer),
      expiry: displayDate(l.expiry),
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
  final _expenseTextCtrl = TextEditingController();
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
  /// Website "Billed By". Defaults to Pharmacy Admin; overwritten when the
  /// Laravel/web invoice payload returns a non-empty billed_by.
  String? _billedBy;
  static const String _kDefaultBilledBy =
      InvoiceSummaryModel.defaultBilledBy;
  String? _paymentMode = 'Cash';
  String? _gstType = 'GST MINUS';
  String? _discountType = 'Percentage';
  _DiscountCategoryOption? _discountCategory;
  String? _pendingDiscountCategoryName;
  List<_DiscountCategoryOption> _discountCategories = [];
  /// Group Discount matrix for the selected Price Category (Company/Group/…).
  List<PriceCategoryGroupDiscountRule> _categoryGroupRules = const [];
  bool _saving = false;
  bool _removingLine = false;
  /// True after user taps Save (keep bill). Close without this restores stock.
  bool _billKept = false;
  /// True once add_to_invoice has committed products to [_invoiceNumber].
  bool _invoiceCommittedOnServer = false;
  /// Empty Odoo draft was created this session (delete on discard, not keep as draft).
  bool _draftCreatedThisSession = false;
  /// True when [_invoiceNumber] was restored from a discarded bill.
  bool _reusedDiscardedNumber = false;
  /// Odoo move id for this bill (from add_to_invoice).
  int? _serverInvoiceId;
  /// Server-committed lines removed locally; zeroed on Save (not on Discard).
  final List<_BillLine> _deferredServerRemovals = [];
  InvoiceCalcResult _totals = InvoiceCalcResult.zero;
  /// Which invoice line shows the full edit form; others use draft-style summary.
  int? _editingLineIndex;
  /// Qty when the current line edit started (for local Available Stock).
  double? _editingLineStartQty;
  /// Warehouse remaining + start qty (local reserve baseline while editing).
  double? _editingAvailBase;
  /// Required field labels to highlight in red on the expanded line.
  Set<String> _lineRequiredErrors = {};
  double? _customerAdvance;
  double? _customerOldBalance;
  /// Soft banner when outstanding + bill total exceeds credit limit (API).
  String? _creditLimitWarningBanner;

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

  static String _normalizePaymentMode(String? raw) {
    final pay = (raw ?? '').trim();
    if (pay.isEmpty) return 'Cash';
    final lower = pay.toLowerCase();
    return _paymentModes.firstWhere(
          (m) => m.toLowerCase() == lower || lower.contains(m.toLowerCase()),
      orElse: () => 'Cash',
    );
  }

  static String _normalizeGstType(String? raw) {
    final g = (raw ?? '').trim().toLowerCase();
    if (g.isEmpty) return 'GST MINUS';
    if (g.contains('plus')) return 'GST PLUS';
    if (g.contains('igst')) return 'IGST';
    if (g.contains('no')) return 'No GST';
    return 'GST MINUS';
  }

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _invoiceDateDisplay = CalendarDate.dmy(now);
    final edit = widget.editInvoice;
    if (edit != null) {
      _applyEditInvoice(edit);
    } else {
      // Prefer a number freed by Discard (e.g. discard R0159 → next is R0159).
      String? reused;
      try {
        reused = Provider.of<CustomerMedViewmodel>(context, listen: false)
            .takeReuseInvoiceNumber();
      } catch (_) {}
      if ((reused ?? '').trim().isNotEmpty) {
        _invoiceNumber = reused!.trim();
        _reusedDiscardedNumber = true;
      } else {
        _invoiceNumber = InvoiceHelper.nextFromLatest(
          ids: widget.existingInvoices.map((e) => e.id),
          numbers: widget.existingInvoices.map((e) => e.displayNumber),
        );
        if (_invoiceNumber.isEmpty) {
          _invoiceNumber = InvoiceHelper.nextInvoiceNumber([
            ...widget.existingNumbers,
            ...widget.existingInvoices.map((e) => e.displayNumber),
          ]);
        }
      }
    }
    _seedFromExistingInvoices();
    _discountRateCtrl.addListener(_recalculate);
    _expenseCtrl.addListener(_recalculate);
    // Background only — UI is already visible.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // New bill must not inherit a discarded move id from a prior scan.
      if (widget.editInvoice == null) {
        try {
          Provider.of<CustomerMedViewmodel>(context, listen: false)
              .clearLastAddedInvoice();
        } catch (_) {}
      }
      _seedDefaultBilledBy();
      _loadSavedNames();
      _loadPartnerNames();
      _loadPharmacyCustomers();
      _loadResponsiblePeople();
      _loadMasterDropdowns();
      _loadDiscountCategories();
      _loadStockSuggestionPools();
      _loadNextInvoiceNumber();
      _refreshEditHeaderFromServer();
      _recalculate();
    });
  }

  /// List/seed payloads often omit responsible_person; reload detail and apply.
  Future<void> _refreshEditHeaderFromServer() async {
    final seed = widget.editInvoice;
    if (seed == null) return;
    try {
      final loaded = await InvoiceDetailService.fetchCustomerInvoice(
        context,
        seed: seed,
      );
      if (!mounted) return;
      setState(() {
        final responsible = (loaded.responsiblePerson ?? '').trim();
        if (responsible.isNotEmpty) {
          _responsible = _NamedOption(name: responsible);
          final lower = responsible.toLowerCase();
          if (!_responsiblePeople.any((r) => r.name.toLowerCase() == lower)) {
            _responsiblePeople = [..._responsiblePeople, _responsible!]
              ..sort(
                (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
              );
          }
        }
        _applyBilledByFromServer(loaded.billedBy);
        final doctor = (loaded.doctor ?? '').trim();
        if (doctor.isNotEmpty) _doctor = _NamedOption(name: doctor);
        final verified = (loaded.verifiedBy ?? '').trim();
        if (verified.isNotEmpty) _verifiedByCtrl.text = verified;
      });
    } catch (e) {
      if (kDebugMode) debugPrint('refresh edit header: $e');
    }
  }

  String get _displayBilledBy {
    final billed = (_billedBy ?? '').trim();
    return billed.isEmpty ? _kDefaultBilledBy : billed;
  }

  void _seedDefaultBilledBy() {
    if ((_billedBy ?? '').trim().isNotEmpty) return;
    if (!mounted) return;
    setState(() => _billedBy = _kDefaultBilledBy);
  }

  /// Prefer website/API billed-by; keep Pharmacy Admin when server omits it.
  void _applyBilledByFromServer(String? raw, {bool forceDefaultIfEmpty = false}) {
    final billed = (raw ?? '').trim();
    if (billed.isNotEmpty) {
      _billedBy = billed;
      return;
    }
    if (forceDefaultIfEmpty || (_billedBy ?? '').trim().isEmpty) {
      _billedBy = _kDefaultBilledBy;
    }
  }

  void _applyEditInvoice(InvoiceSummaryModel inv) {
    _invoiceNumber = inv.displayNumber;
    _serverInvoiceId = inv.id;
    _invoiceCommittedOnServer = inv.id != null;
    // Existing bill — Close must not wipe pre-existing lines; only session QR adds.
    _billKept = true;
    // Demo / Walkin / empty → leave Customer blank on the opened bill.
    final customer = (inv.displayCustomer ?? '').trim();
    if (customer.isNotEmpty) {
      _customer = _NamedOption(
        name: customer,
        id: inv.pharmacyCustomerId,
        address: inv.address,
        phone: inv.phone,
      );
    } else {
      _customer = null;
    }
    _addressCtrl.text = (inv.address ?? '').trim();
    _phoneCtrl.text = (inv.phone ?? '').trim();
    final doctor = (inv.doctor ?? '').trim();
    if (doctor.isNotEmpty) _doctor = _NamedOption(name: doctor);
    final responsible = (inv.responsiblePerson ?? '').trim();
    if (responsible.isNotEmpty) {
      _responsible = _NamedOption(name: responsible);
    }
    _applyBilledByFromServer(inv.billedBy);
    final pay = (inv.paymentMode ?? '').trim();
    if (pay.isNotEmpty) {
      _paymentMode = _normalizePaymentMode(pay);
    }
    if (inv.gstType != null && inv.gstType!.trim().isNotEmpty) {
      _gstType = _normalizeGstType(inv.gstType);
    }
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
    _expenseTextCtrl.text = (inv.expense ?? '').trim();
    _remarksCtrl.text = (inv.remarks ?? '').trim();
    _verifiedByCtrl.text = (inv.verifiedBy ?? '').trim();
    if (inv.invoiceDate != null && inv.invoiceDate!.trim().isNotEmpty) {
      final parsed = CalendarDate.parse(inv.invoiceDate);
      _invoiceDateDisplay =
      parsed != null ? CalendarDate.dmy(parsed) : inv.invoiceDate!.trim();
    }

    _lines = inv.lines.map((l) {
      final line = _BillLine();
      line.odooLineId = l.id;
      line.applyFromStock(_LineTemplate.fromInvoiceLine(l));
      // Preserve QR uid so qty reduce can rebuild via add_to_invoice.
      final uid = (l.lineUid ?? l.productBarcode ?? '').trim();
      if (uid.isNotEmpty) {
        line.addQrData = uid;
      }
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
      if (l.discount != null || l.dis2Percent != null) {
        final d = (l.discount != null && l.discount! > 0)
            ? l.discount!
            : (l.dis2Percent ?? l.discount!);
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
    if (_customer != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_loadCustomerBalances(_customer!));
      });
    }
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
    _expenseTextCtrl.dispose();
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
    final banner = _buildCreditLimitBanner(result);
    if (!mounted) {
      _totals = result;
      _creditLimitWarningBanner = banner;
      return;
    }
    setState(() {
      _totals = result;
      _creditLimitWarningBanner = banner;
    });
  }

  String? _buildCreditLimitBanner(InvoiceCalcResult totals) {
    final limit = _customer?.creditLimitAmount ?? 0;
    if (limit <= 0) return null;
    final bill = totals.total > 0 ? totals.total : totals.balance;
    if (bill <= 0) return null;
    final info = CustomerCreditLimitInfo(
      creditLimit: limit,
      outstanding: _customerOldBalance ?? 0,
      availableCredit: limit - (_customerOldBalance ?? 0),
      customerId: _customer?.id,
      customerName: _customer?.name,
    );
    if (!info.wouldExceed(bill)) return null;
    final remaining = limit - (_customerOldBalance ?? 0);
    String money(double v) =>
        v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);
    return 'Credit limit warning: limit Rs ${money(limit)}, '
        'outstanding Rs ${money(_customerOldBalance ?? 0)}, '
        'available Rs ${money(remaining < 0 ? 0 : remaining)}, '
        'this bill Rs ${money(bill)}.';
  }

  static String _formatLineNum(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

  /// Website: Unit TP = MRP − Dis%; Unit P = exclusive of line tax.
  /// Example: Unit TP 100 @ 5% → Unit P 95.24, Tax Amt 4.76.
  void _recalcLinePrices(_BillLine line) {
    final mrp = InvoiceCalcHelper.parseNum(line.mrp);
    if (mrp <= 0) {
      line.unitTp = '';
      line.unitP = '';
      line.revision++;
      return;
    }
    final disc = InvoiceCalcHelper.parseNum(line.discount);
    final unitTp = disc > 0 ? mrp * (1 - disc / 100.0) : mrp;
    line.unitTp = _formatLineNum(unitTp);
    final taxPct = InvoiceCalcHelper.parseNum(line.tax);
    if (taxPct > 0) {
      final exclusive = unitTp * 100.0 / (100.0 + taxPct);
      line.unitP = _formatLineNum(exclusive);
    } else {
      line.unitP = line.unitTp;
    }
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
    final byResponsible = <String, _NamedOption>{};

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
      final responsible = (inv.responsiblePerson ?? '').trim();
      if (responsible.isNotEmpty) {
        byResponsible[responsible.toLowerCase()] =
            _NamedOption(name: responsible);
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
    if (byResponsible.isNotEmpty) {
      _responsiblePeople = byResponsible.values.toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }
  }

  Future<void> _loadSavedNames() async {
    final byCustomer = {
      for (final c in _customers)
        '${c.id ?? ''}|${c.name.toLowerCase()}': c,
    };
    final byDoctor = {
      for (final d in _doctors) d.name.toLowerCase(): d,
    };
    final byResponsible = {
      for (final r in _responsiblePeople) r.name.toLowerCase(): r,
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
    for (final name in await BillNameStore.loadResponsible()) {
      final t = name.trim();
      if (t.isEmpty) continue;
      byResponsible.putIfAbsent(t.toLowerCase(), () => _NamedOption(name: t));
    }

    if (!mounted) return;
    setState(() {
      _customers = byCustomer.values.toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      _doctors = byDoctor.values.toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      _responsiblePeople = byResponsible.values.toList()
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

  Future<void> _loadNextInvoiceNumber() async {
    if (widget.editInvoice != null) return;
    // Keep the number freed by Discard (do not jump ahead).
    if (_reusedDiscardedNumber) return;
    try {
      final sid = await _odooSessionId();
      if (sid.isEmpty || !mounted) return;
      final next = await OdooRpcHelper.peekNextCustomerInvoiceNumber(sid);
      if (!mounted) return;
      if (next == null || next.isEmpty) return;
      if (next == _invoiceNumber) return;
      setState(() => _invoiceNumber = next);
    } catch (e) {
      if (kDebugMode) debugPrint('load next invoice number: $e');
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
      final byName = <String, _NamedOption>{
        for (final r in _responsiblePeople) r.name.toLowerCase(): r,
      };
      // Keep the value already applied from a saved invoice in the list.
      final selected = (_responsible?.name ?? '').trim();
      if (selected.isNotEmpty) {
        byName.putIfAbsent(
          selected.toLowerCase(),
          () => _responsible!,
        );
      }
      for (final name in await BillNameStore.loadResponsible()) {
        final t = name.trim();
        if (t.isEmpty) continue;
        byName.putIfAbsent(t.toLowerCase(), () => _NamedOption(name: t));
      }

      final sid = await _odooSessionId();
      if (sid.isNotEmpty) {
        final rows = await OdooRpcHelper.searchResponsiblePersons(sid);
        for (final row in rows) {
          final id = row['id'];
          final name = (row['name'] ?? row['display_name'] ?? '')
              .toString()
              .trim();
          if (name.isEmpty) continue;
          byName[name.toLowerCase()] = _NamedOption(
            name: name,
            id: id is num ? id.toInt() : int.tryParse('$id'),
          );
        }
      }

      if (!mounted || byName.isEmpty) return;
      setState(() {
        _responsiblePeople = byName.values.toList()
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
      if (selected == null) {
        _categoryGroupRules = const [];
        for (final line in _lines) {
          if (!line.discountAutoFromCategory) continue;
          line.discount = '';
          line.discountAutoFromCategory = false;
          line.revision++;
          _recalcLinePrices(line);
        }
        return;
      }
      // Header rate is applied only after group rules load (if none exist).
      _discountType = selected.uiDiscountType;
    });
    if (selected != null) {
      unawaited(_loadCategoryGroupRules(selected.id, applyHeaderIfNoRules: true));
    } else {
      _recalculate();
    }
    _dismissKeyboardAfterFrame();
  }

  Future<void> _loadCategoryGroupRules(
    int categoryId, {
    bool applyHeaderIfNoRules = false,
  }) async {
    try {
      final sid = await _odooSessionId();
      if (sid.isEmpty) return;
      final info = await OdooRpcHelper.readPriceCategoryInfo(sid, categoryId);
      if (!mounted) return;
      setState(() {
        _categoryGroupRules = info?.groupRules ?? const [];
        if (_categoryGroupRules.isNotEmpty) {
          // Line Dis from Group Discount must drive totals (header % would hide them).
          _discountRateCtrl.text = '';
        } else if (applyHeaderIfNoRules && info != null) {
          var rate = info.headerPercentage ?? 0;
          if (rate <= 0) {
            for (final c in _discountCategories) {
              if (c.id == categoryId) {
                rate = c.rate;
                break;
              }
            }
          }
          if (rate > 0) {
            _discountType =
                (info.discountType == 'amount') ? 'Rupees' : 'Percentage';
            _discountRateCtrl.text = rate == rate.roundToDouble()
                ? rate.toInt().toString()
                : rate.toStringAsFixed(2);
          }
        }
      });
      await _reapplyCategoryDiscountsToAllLines();
    } catch (e) {
      if (kDebugMode) debugPrint('load category group rules: $e');
      _recalculate();
    }
  }

  Future<void> _applyCustomerPriceCategory(_NamedOption customer) async {
    try {
      final sid = await _odooSessionId();
      if (sid.isEmpty) return;
      final info = await OdooRpcHelper.readCustomerPriceCategory(
        sid,
        customerId: customer.id,
        customerName: customer.name,
      );
      if (!mounted) return;
      if (info == null) return;

      _DiscountCategoryOption? option;
      for (final c in _discountCategories) {
        if (c.id == info.categoryId) {
          option = c;
          break;
        }
      }
      option ??= _DiscountCategoryOption(
        id: info.categoryId,
        name: info.categoryName,
        discountType: info.discountType,
        rate: info.headerPercentage ?? 0,
        displayName: info.categoryName,
      );
      final resolved = option;

      setState(() {
        if (!_discountCategories.any((c) => c.id == resolved.id)) {
          _discountCategories = [..._discountCategories, resolved];
        }
        _discountCategory = resolved;
        _categoryGroupRules = info.groupRules;
        if (info.hasGroupRules) {
          _discountRateCtrl.text = '';
        } else if ((info.headerPercentage ?? 0) > 0) {
          _discountType =
              info.discountType == 'amount' ? 'Rupees' : 'Percentage';
          final rate = info.headerPercentage!;
          _discountRateCtrl.text = rate == rate.roundToDouble()
              ? rate.toInt().toString()
              : rate.toStringAsFixed(2);
        }
      });
      await _reapplyCategoryDiscountsToAllLines();
    } catch (e) {
      if (kDebugMode) debugPrint('apply customer price category: $e');
    }
  }

  Future<void> _reapplyCategoryDiscountsToAllLines() async {
    if (!mounted) return;
    for (final line in _lines) {
      await _maybeApplyLineDiscount(line, forceCategoryRefresh: true);
    }
    _recalculate();
  }

  /// Prefer Price Category Group Discount rules; fall back to company/group %.
  Future<void> _maybeApplyLineDiscount(
    _BillLine line, {
    bool forceCategoryRefresh = false,
  }) async {
    // Never overwrite a Dis% the user typed in Add a line.
    if (line.discountUserEdited) {
      _recalculate();
      return;
    }

    final canOverwrite = line.discount.trim().isEmpty ||
        line.discountAutoFromCategory ||
        forceCategoryRefresh;
    if (!canOverwrite) {
      _recalculate();
      return;
    }

    // 1) Customer Price Category → Group Discount matrix (screenshot rules).
    if (_categoryGroupRules.isNotEmpty) {
      final matched = OdooRpcHelper.matchGroupDiscountPercent(
        rules: _categoryGroupRules,
        company: line.company,
        group: line.group,
        potency: line.potency,
        packing: line.pack,
      );
      if (matched != null && matched > 0) {
        final text = matched == matched.roundToDouble()
            ? matched.toInt().toString()
            : matched.toStringAsFixed(2);
        if (!mounted) return;
        setState(() {
          line.discount = text;
          line.discountAutoFromCategory = true;
          line.revision++;
        });
        if (kDebugMode) {
          debugPrint(
            'group discount match '
            '${line.company}/${line.group}/${line.potency}/${line.pack} → $text%',
          );
        }
        _recalcLinePrices(line);
        _recalculate();
        return;
      }
      // No rule matched — clear previous auto discount for this category.
      if (forceCategoryRefresh && line.discountAutoFromCategory) {
        if (!mounted) return;
        setState(() {
          line.discount = '';
          line.discountAutoFromCategory = false;
          line.revision++;
        });
        _recalcLinePrices(line);
      }
    }

    // 2) Fallback: flat discount on pharmacy.group / pharmacy.company.
    await _maybeApplyCompanyOrGroupDiscount(line);
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
      creditLimitAmount: creditAmt > 0 ? creditAmt : null,
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
      _customerAdvance = null;
      _customerOldBalance = null;
      _creditLimitWarningBanner = null;
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
    unawaited(_loadCustomerBalances(selected));
    if (selected.name.isNotEmpty) {
      unawaited(_applyCustomerPriceCategory(selected));
    }
  }

  Future<void> _loadCustomerBalances(_NamedOption customer) async {
    final name = customer.name.trim();
    if (name.isEmpty) return;
    try {
      final sid = await _odooSessionId();
      if (sid.isEmpty) return;
      final hit = await OdooRpcHelper.readCustomerFormBalances(
        sid,
        customerName: name,
        moveIds: [
          if (_serverInvoiceId != null) _serverInvoiceId!,
          if (widget.editInvoice?.id != null) widget.editInvoice!.id!,
        ],
      );
      if (!mounted) return;

      // Refresh credit limit from pharmacy.customer (API).
      final credit = await OdooRpcHelper.readCustomerCreditLimitInfo(
        sid,
        customerId: customer.id,
        customerName: name,
        oldBalance: hit?.oldBalance ?? _customerOldBalance,
      );
      if (!mounted) return;

      setState(() {
        if (hit != null) {
          _customerAdvance = hit.advance;
          _customerOldBalance = hit.oldBalance;
        }
        if (credit != null &&
            credit.hasLimit &&
            _customer != null &&
            _customer!.name.toLowerCase() == name.toLowerCase()) {
          _customer = _customer!.copyWith(
            creditLimitAmount: credit.creditLimit,
          );
        }
      });
      _recalculate();
    } catch (e) {
      if (kDebugMode) debugPrint('load customer balances: $e');
    }
  }

  /// Non-blocking credit-limit warning (same rule as website / API fields).
  /// Returns true to continue; never blocks save.
  Future<bool> _warnIfCreditLimitExceeded() async {
    final customer = _customer;
    if (customer == null) return true;

    final billAmount = _totals.total > 0 ? _totals.total : _totals.balance;
    if (billAmount <= 0) return true;

    CustomerCreditLimitInfo? info;
    try {
      final sid = await _odooSessionId();
      if (sid.isNotEmpty) {
        info = await OdooRpcHelper.readCustomerCreditLimitInfo(
          sid,
          customerId: customer.id,
          customerName: customer.name,
          oldBalance: _customerOldBalance,
        );
      }
    } catch (e) {
      if (kDebugMode) debugPrint('credit limit check: $e');
    }

    final limit = info?.creditLimit ?? customer.creditLimitAmount ?? 0;
    if (limit <= 0) return true;

    info ??= CustomerCreditLimitInfo(
      creditLimit: limit,
      outstanding: _customerOldBalance ?? 0,
      availableCredit: limit - (_customerOldBalance ?? 0),
      customerId: customer.id,
      customerName: customer.name,
    );

    if (!info.wouldExceed(billAmount)) return true;
    if (!mounted) return true;

    final message = info.warningMessage(billAmount);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: sectionBg,
        title: const Text(
          'Credit Limit Warning',
          style: TextStyle(color: sectionText, fontWeight: FontWeight.w700),
        ),
        content: Text(
          message,
          style: const TextStyle(color: sectionText, height: 1.35),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'OK',
              style: TextStyle(
                color: Color(0xFFE07A2F),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
    return true;
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

  String? _formatAvailableStock(StockItemModel stock) {
    final v = stock.availableStock ?? stock.stock ?? stock.itemQty;
    if (v == null) return null;
    return v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);
  }

  /// Warehouse qty minus this bill's reserved qty (and other matching lines).
  String? _formatAvailableAfterReserve(
    _BillLine line,
    double? warehouseQty,
  ) {
    if (warehouseQty == null) return null;
    final reserved = _reservedQtyForStockIdentity(line);
    final remaining =
        (warehouseQty - reserved).clamp(0, double.infinity).toDouble();
    return remaining == remaining.roundToDouble()
        ? remaining.toInt().toString()
        : remaining.toStringAsFixed(2);
  }

  /// Keep Available Stock in sync with Qty using the stored warehouse baseline.
  void _recomputeLineAvailableStock(_BillLine line) {
    if (!line.fromStock) {
      line.availableStock = null;
      return;
    }
    final base = line.warehouseStockBase;
    if (base == null) return;
    line.availableStock = _formatAvailableAfterReserve(line, base);
  }

  /// Sum qty of bill lines that share the same stock identity as [line].
  double _reservedQtyForStockIdentity(_BillLine line) {
    return _reservedQtyForIdentity(
      product: line.product,
      potency: line.potency,
      batch: line.batch,
      pack: line.pack,
    );
  }

  /// Local-until-Save: qty already on this open bill for the same stock row.
  double _reservedQtyForIdentity({
    String? product,
    String? potency,
    String? batch,
    String? pack,
  }) {
    final productKey = _normField(product);
    final potencyKey = _normField(potency);
    final batchKey = _normField(batch);
    final packKey = _normField(pack);
    if (productKey.isEmpty) return 0;
    var total = 0.0;
    for (final other in _lines) {
      if (_normField(other.product) != productKey) continue;
      if (potencyKey.isNotEmpty &&
          _normField(other.potency).isNotEmpty &&
          !_potencyEquals(other.potency, potency)) {
        continue;
      }
      if (batchKey.isNotEmpty &&
          _normField(other.batch).isNotEmpty &&
          !_fieldEquals(other.batch, batch)) {
        continue;
      }
      if (packKey.isNotEmpty &&
          _normField(other.pack).isNotEmpty &&
          !_fieldEquals(other.pack, pack)) {
        continue;
      }
      total += InvoiceCalcHelper.parseNum(other.qty);
    }
    return total;
  }

  void _applyStockToLine(
      _BillLine line,
      StockItemModel stock, {
        bool preservePotency = false,
        bool preserveProduct = false,
        bool linkStockIds = true,
      }) {
    final t = _LineTemplate.fromStock(stock);
    line.applyFromStock(
      t,
      preservePotency: preservePotency,
      preserveProduct: preserveProduct,
    );
    final warehouse = stock.availableStock ?? stock.stock ?? stock.itemQty;
    if (warehouse != null && warehouse >= 0) {
      line.warehouseStockBase = warehouse;
    }
    line.availableStock = _formatAvailableAfterReserve(line, warehouse) ??
        _formatAvailableStock(stock);
    if (linkStockIds) {
      if (stock.stockId != null) {
        line.stockDisplayId = stock.stockId;
      }
      if (stock.entryStockId != null) {
        line.entryStockId = stock.entryStockId;
      }
    }
    _mergeTemplateIntoPools(t);
    _templates.add(t);
  }

  Future<void> _applyWebsiteStockId(_BillLine line) async {
    final sid = await _odooSessionId();
    if (sid.isEmpty) return;
    final row = await OdooRpcHelper.findEntryStockRow(
      sid,
      stockDisplayId: line.stockDisplayId,
      entryStockId: line.entryStockId,
      medicine: line.product,
      batch: line.batch,
      potency: line.potency,
    );
    if (row == null || !mounted) return;
    final entryRaw = row['id'];
    final entryId = entryRaw is int
        ? entryRaw
        : int.tryParse('$entryRaw');
    if (entryId == null || entryId <= 0) return;
    setState(() {
      line.stockDisplayId = entryId;
      line.entryStockId = entryId;
    });
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
  /// Prefer rows that also match company / pack / batch when those are set.
  StockItemModel? _exactStockMatch(_BillLine line, List<StockItemModel> rows) {
    return _matchStockForAvailable(line, rows, requirePotency: true);
  }

  bool _fieldEquals(String? a, String? b) {
    final left = _normField(a);
    final right = _normField(b);
    if (left.isEmpty || right.isEmpty) return false;
    return left == right;
  }

  /// Match stock for Available Stock using product + potency + company +
  /// batch + pack. All five must be set and match before a qty is shown.
  StockItemModel? _matchStockForAvailable(
    _BillLine line,
    List<StockItemModel> rows, {
    bool requirePotency = false,
  }) {
    if (rows.isEmpty) return null;
    final product = _normField(line.product);
    final potency = _normField(line.potency);
    final company = _normField(line.company);
    final batch = _normField(line.batch);
    final pack = _normField(line.pack);
    if (product.isEmpty) return null;

    // Available Stock UI: only when the full identity is chosen.
    if (!requirePotency &&
        (potency.isEmpty ||
            company.isEmpty ||
            batch.isEmpty ||
            pack.isEmpty)) {
      return null;
    }

    // Sync / defaults: product+potency required; company/pack/batch optional filters.
    if (requirePotency && potency.isEmpty) return null;

    final needCompany = company.isNotEmpty;
    final needBatch = batch.isNotEmpty;
    final needPack = pack.isNotEmpty;

    final matches = <StockItemModel>[];
    for (final row in rows) {
      final name = _normField(row.medicineLabel);
      final productOk = name == product || name.startsWith(product);
      if (!productOk) continue;
      if (!_potencyEquals(row.potency, line.potency)) continue;
      if (needCompany && !_fieldEquals(row.company, line.company)) continue;
      if (needBatch && !_fieldEquals(row.batch, line.batch)) continue;
      if (needPack && !_fieldEquals(row.packing, line.pack)) continue;
      matches.add(row);
    }
    return _pickBestStockRow(matches);
  }

  /// Refresh Available Stock from the row that matches product / potency /
  /// company / batch / pack (From stock lines only).
  Future<void> _refreshAvailableStockForLine(_BillLine line) async {
    if (!line.fromStock) {
      if (line.availableStock != null) {
        setState(() => line.availableStock = null);
      }
      return;
    }
    final product = (line.product ?? '').trim();
    if (product.isEmpty) {
      setState(() => line.availableStock = null);
      return;
    }
    final rows = await _stockRowsForProduct(product);
    if (!mounted) return;
    final match = _matchStockForAvailable(line, rows);
    setState(() {
      if (match == null) {
        line.availableStock = null;
        return;
      }
      final warehouse = match.availableStock ?? match.stock ?? match.itemQty;
      if (warehouse != null && warehouse >= 0) {
        line.warehouseStockBase = warehouse;
      }
      // Keep column in sync with Qty: warehouse minus reserved on this bill.
      line.availableStock = _formatAvailableAfterReserve(line, warehouse) ??
          _formatAvailableStock(match);
      if (match.stockId != null) line.stockDisplayId = match.stockId;
      if (match.entryStockId != null) line.entryStockId = match.entryStockId;
    });
  }

  Future<void> _syncLineFromStock(
      _BillLine line, {
        bool potencyOnly = false,
      }) async {
    final product = (line.product ?? '').trim();
    final potency = (line.potency ?? '').trim();
    if (product.isEmpty && potency.isEmpty) return;

    // Product + potency → exact medicine row (not when potency-only pick).
    // Prefer company / pack / batch when already chosen so Available Stock
    // reflects the matching stock entry.
    if (!potencyOnly && product.isNotEmpty && potency.isNotEmpty) {
      final rows = await _stockRowsForProduct(product);
      if (!mounted) return;
      final match = _exactStockMatch(line, rows);
      if (match == null) {
        if (kDebugMode) {
          debugPrint(
            'No stock defaults for product="$product" potency="$potency" '
            '— falling back to potency HSN/Group/Tax',
          );
        }
        // Non-stock / free-text medicine: still fill Group / HSN / Tax from potency.
        await _syncLineFromStock(line, potencyOnly: true);
        if (line.fromStock) {
          await _refreshAvailableStockForLine(line);
        }
        return;
      }
      setState(
            () => _applyStockToLine(
          line,
          match,
          preservePotency: true,
          // Free-text (From stock off): fill HSN/group/tax/etc., do not link stock.
          linkStockIds: line.fromStock,
        ),
      );
      if (line.fromStock) {
        await _applyWebsiteStockId(line);
        await _refreshAvailableStockForLine(line);
      } else {
        setState(() {
          line.stockDisplayId = null;
          line.entryStockId = null;
        });
      }
      await _maybeApplyLineDiscount(line);
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
    if (!line.fromStock) {
      await _pickFreeProductForLine(line);
      return;
    }

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
        line.entryStockId = null;
        line.addQrData = null;
        line.addQrDataAlt = null;
      }
      if (stock.stockId != null) {
        line.stockDisplayId = stock.stockId;
      }
      if (stock.entryStockId != null) {
        line.entryStockId = stock.entryStockId;
      }
      // Available Stock waits until potency + company + batch + pack match.
      line.availableStock = null;
      line.warehouseStockBase = null;
      line.revision++;
      _addOpt(_products, _productKeys, name);
    });

    await _applyWebsiteStockId(line);
    await _enrichOptionsForProduct(line.product);
    if (!mounted) return;
    await _refreshAvailableStockForLine(line);
    if (!mounted) return;
    _recalculate();
  }

  /// Free-text product (From stock off): master/create dropdown, no stock link.
  Future<void> _pickFreeProductForLine(_BillLine line) async {
    if (_products.length < 20) {
      await _loadStockSuggestionPools();
      if (!mounted) return;
    }
    final picked = await _pickLineValue(
      title: 'Product',
      options: List<String>.from(_products),
      selected: line.product,
      rememberInto: _products,
      rememberKeys: _productKeys,
      matchContains: true,
    );
    if (picked == null || !mounted) return;
    setState(() {
      final productChanged =
          (line.product ?? '').trim().toLowerCase() != picked.trim().toLowerCase();
      line.product = picked.isEmpty ? null : picked;
      if (productChanged) {
        line.clearRelatedExceptProduct();
      }
      line.stockDisplayId = null;
      line.entryStockId = null;
      line.addQrData = null;
      line.addQrDataAlt = null;
      line.revision++;
    });
    // Same HSN / group / tax fill as From stock on (without linking stock).
    final potency = (line.potency ?? '').trim();
    if (potency.isNotEmpty) {
      await _syncLineFromStock(line, potencyOnly: true);
    } else if ((line.product ?? '').trim().isNotEmpty) {
      await _syncLineFromStock(line);
    } else {
      _recalculate();
    }
  }

  void _setLineFromStock(_BillLine line, bool value) {
    if (line.fromStock == value) return;
    setState(() {
      line.fromStock = value;
      if (!value) {
        // Keep product / HSN / potency / group / etc. — only unlink stock.
        line.stockDisplayId = null;
        line.entryStockId = null;
        line.addQrData = null;
        line.addQrDataAlt = null;
        line.availableStock = null;
        line.warehouseStockBase = null;
      } else {
        // Switching back to stock: clear free-text product so user re-picks.
        line.clearRelatedExceptProduct();
        line.product = null;
        line.stockDisplayId = null;
        line.entryStockId = null;
        line.availableStock = null;
        line.warehouseStockBase = null;
      }
      line.revision++;
      _lineRequiredErrors = {};
    });
    // After turning From stock off, fill missing HSN/group/tax from product/potency
    // (same lookup as From stock on). Existing filled values stay.
    if (!value &&
        line.hsn.trim().isEmpty &&
        ((line.product ?? '').trim().isNotEmpty ||
            (line.potency ?? '').trim().isNotEmpty)) {
      unawaited(
        _syncLineFromStock(
          line,
          potencyOnly: (line.potency ?? '').trim().isNotEmpty,
        ),
      );
    }
    _recalculate();
  }

  /// Full master list for Company / Pack (all API names + free-text create).
  Future<void> _pickMasterNameForLine(
      _BillLine line, {
        required String title,
        required String? Function() readValue,
        required void Function(String? v) assign,
        required List<String> pool,
        required Set<String> poolKeys,
      }) async {
    if (pool.length < 30) {
      await _loadMasterDropdowns();
      if (!mounted) return;
    }
    final picked = await _pickLineValue(
      title: title,
      options: List<String>.from(pool),
      selected: readValue(),
      rememberInto: pool,
      rememberKeys: poolKeys,
      matchContains: true,
    );
    if (picked == null || !mounted) return;
    setState(() {
      assign(picked.isEmpty ? null : picked);
      line.revision++;
    });
    // Do not re-sync from stock — that overwrites a manually chosen Company/Pack.
    if (line.fromStock) {
      await _refreshAvailableStockForLine(line);
    }
    if ((title == 'Company' || title == 'Pack') && picked.isNotEmpty) {
      await _maybeApplyLineDiscount(line);
    } else {
      _recalculate();
    }
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

    // Related options from matching stock rows (same lists with From stock on/off).
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

    // From stock + product: only values from that medicine's stock rows.
    // Otherwise (free-text / no product): master + pool create lists.
    if (!(line.fromStock && product.isNotEmpty)) {
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

    // Potency → Group / Tax / HSN (same with From stock on or off).
    if (title == 'Potency') {
      await _syncLineFromStock(line, potencyOnly: true);
      await _maybeApplyLineDiscount(line);
    } else if (title == 'Company' ||
        title == 'Group' ||
        title == 'Pack' ||
        title == 'BATCH') {
      if (line.fromStock &&
          (title == 'Company' || title == 'Pack' || title == 'BATCH')) {
        await _refreshAvailableStockForLine(line);
      }
      await _maybeApplyLineDiscount(line);
    } else {
      _recalculate();
    }
  }

  Future<void> _pickPotencyForLine(_BillLine line) async {
    // From stock + product: only potencies that exist on that medicine in stock.
    if (line.fromStock && (line.product ?? '').trim().isNotEmpty) {
      await _pickRelatedForLine(
        line,
        title: 'Potency',
        readField: (s) => s.potency,
        assignField: (v) => line.potency = v,
        pool: _potencies,
        poolKeys: _potencyKeys,
        fallbackOptions: const [],
      );
      return;
    }

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
    await _maybeApplyLineDiscount(line);
  }

  /// When line discount is empty, fill from pharmacy.group / pharmacy.company.
  Future<void> _maybeApplyCompanyOrGroupDiscount(_BillLine line) async {
    if (line.discount.trim().isNotEmpty) {
      _recalculate();
      return;
    }
    final group = (line.group ?? '').trim();
    final company = (line.company ?? '').trim();
    if (group.isEmpty && company.isEmpty) {
      _recalculate();
      return;
    }
    try {
      final sid = await _odooSessionId();
      if (sid.isEmpty) {
        _recalculate();
        return;
      }
      double? disc;
      if (group.isNotEmpty) {
        disc = await OdooRpcHelper.fetchGroupDiscount(sid, group);
      }
      if ((disc == null || disc <= 0) && company.isNotEmpty) {
        disc = await OdooRpcHelper.fetchCompanyDiscount(sid, company);
      }
      if (!mounted) return;
      if (disc != null && disc > 0) {
        final text = disc == disc.roundToDouble()
            ? disc.toInt().toString()
            : disc.toStringAsFixed(2);
        setState(() {
          line.discount = text;
          line.discountAutoFromCategory = false;
          line.revision++;
        });
        _recalcLinePrices(line);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('company/group discount: $e');
    }
    _recalculate();
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

  void _attachLocalQrMeta(
    _BillLine line,
    QrData data, {
    double? reserveQty,
  }) {
    line.fromStock = true;
    line.addedThisSession = true;
    final primary = _primaryAddQrToken(data);
    if (primary != null && primary.isNotEmpty) {
      line.addQrData = primary;
    }
    if (data.stockEntryId != null) {
      line.stockDisplayId = data.stockDisplayId ?? data.stockEntryId;
      line.entryStockId ??= data.stockEntryId;
    } else if (data.stockDisplayId != null) {
      line.stockDisplayId ??= data.stockDisplayId;
    } else if (data.productId != null) {
      line.stockDisplayId ??= data.productId;
    }
    final stock = data.availableStock ?? data.stockQty;
    if (stock != null && stock >= 0) {
      // Remember warehouse so Qty edits can raise/lower Available Stock.
      line.warehouseStockBase = stock;
      // Fresh scan: show warehouse remaining after this line's qty.
      final reserved = reserveQty ?? InvoiceCalcHelper.parseNum(line.qty);
      final remaining = (stock - reserved).clamp(0, double.infinity);
      line.availableStock = remaining == remaining.roundToDouble()
          ? remaining.toInt().toString()
          : remaining.toStringAsFixed(2);
    }
    final alt = _alternateAddQrToken(data, line.addQrData);
    if (alt != null && alt.isNotEmpty) {
      line.addQrDataAlt ??= alt;
    }
  }

  void _markLineServerCommitted(
      _BillLine line,
      QrData data,
      double qty, {
        int? invoiceId,
        bool rpcAdjustedItemQty = false,
      }) {
    _attachLocalQrMeta(line, data);
    line.serverCommitted = true;
    line.serverCommittedQty += qty;
    if (rpcAdjustedItemQty) line.rpcAdjustedItemQty = true;
    if (invoiceId != null) {
      line.serverInvoiceId = invoiceId;
      _serverInvoiceId = invoiceId;
    }
  }

  void _addOrUpdateLineFromQr(
      QrData data,
      double qty, {
        int? invoiceId,
        bool rpcAdjustedItemQty = false,
        bool commitToServer = true,
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
    String? displayDate(String? raw) {
      final t = (raw ?? '').trim();
      if (t.isEmpty) return null;
      // Keep pharmacy MM/yyyy when that is what the API sent.
      if (RegExp(r'^\d{1,2}[/\-.]\d{2,4}$').hasMatch(t)) {
        final parsed = StockDateParser.tryParse(t);
        if (parsed == null || parsed.isEmpty) return t;
        final parts = parsed.split('/');
        if (parts.length == 3) return '${parts[1]}/${parts[2]}';
        return parsed;
      }
      return StockDateParser.tryParse(t) ?? t;
    }

    final manuf = displayDate(data.mfd);
    final expiry = displayDate(data.expiry);
    final unitP = money(data.unitPrice);
    // Do not auto-fill line discount from QR — only show when user enters it.

    late final int existingIndex;
    setState(() {
      // Drop unused blank "Add a line" drafts so QR results aren't mixed with
      // an empty expanded card. User can tap Add a line again when needed.
      if (_lines.any((l) => l.isBlankDraft)) {
        _lines = _lines.where((l) => !l.isBlankDraft).toList();
      }
      _editingLineIndex = null;
      _lineRequiredErrors = {};
      if ((_billedBy ?? '').trim().isEmpty) {
        _billedBy = _kDefaultBilledBy;
      }

      existingIndex = _lines.indexWhere((l) {
        final sameProduct = (l.product ?? '').trim().toLowerCase() ==
            (product ?? '').toLowerCase();
        final samePotency = (l.potency ?? '').trim().toLowerCase() ==
            (potency ?? '').toLowerCase();
        final sameBatch = (l.batch ?? '').trim().toLowerCase() ==
            (batch ?? '').toLowerCase();
        return sameProduct &&
            samePotency &&
            sameBatch &&
            (product ?? '').isNotEmpty;
      });

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
        if ((line.expiry == null || line.expiry!.trim().isEmpty) &&
            expiry != null &&
            expiry.isNotEmpty) {
          line.expiry = expiry;
        }
        if (line.unitP.trim().isEmpty && unitP != null) {
          // unitP from scan may be tax-inclusive — recalc from MRP instead.
          _recalcLinePrices(line);
        }
        if (commitToServer) {
          _markLineServerCommitted(
            line,
            data,
            qty,
            invoiceId: invoiceId,
            rpcAdjustedItemQty: rpcAdjustedItemQty,
          );
        } else {
          _attachLocalQrMeta(line, data);
          // Warehouse from QR minus total reserved qty for this identity.
          _recomputeLineAvailableStock(line);
          if ((line.availableStock ?? '').trim().isEmpty) {
            _bumpLineAvailableStock(line, restored: -qty);
          }
        }
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
          manuf: manuf,
          expiry: expiry,
          pack: data.packing?.trim().isEmpty == true
              ? null
              : data.packing?.trim(),
          group: data.group?.trim().isEmpty == true ? null : data.group?.trim(),
          mrp: money(data.mrp),
          tax: money(
            InvoiceCalcHelper.normalizeCustomerTaxPercent(data.tax),
          ),
          hsn: data.hsn?.trim().isEmpty == true ? null : data.hsn?.trim(),
          rack: data.rack?.trim().isEmpty == true ? null : data.rack?.trim(),
        );
        line.applyFromStock(t);
        // Force MFD/EXPIRY even if template merge skipped blanks.
        line.manuf = manuf ?? line.manuf;
        line.expiry = expiry ?? line.expiry;
        line.qty = qtyText;
        _recalcLinePrices(line);
        if (commitToServer) {
          _markLineServerCommitted(
            line,
            data,
            qty,
            invoiceId: invoiceId,
            rpcAdjustedItemQty: rpcAdjustedItemQty,
          );
        } else {
          _attachLocalQrMeta(line, data, reserveQty: qty);
        }
        line.revision++;
        _mergeTemplateIntoPools(t);
        _templates.add(t);
        _lines = [..._lines, line];
      }
    });
    _recalculate();
    final target = existingIndex >= 0
        ? existingIndex
        : _lines.length - 1;
    if (target >= 0 && target < _lines.length) {
      // Ensure Available Stock reflects the qty just reserved locally.
      _recomputeLineAvailableStock(_lines[target]);
      if (kDebugMode) {
        debugPrint(
          'scan stock line=${_lines[target].product} '
          'qty=${_lines[target].qty} '
          'warehouse=${_lines[target].warehouseStockBase} '
          'available=${_lines[target].availableStock}',
        );
      }
      setState(() {});
      unawaited(_applyWebsiteStockId(_lines[target]));
      unawaited(_enrichQrLine(_lines[target]));
      if (commitToServer) {
        unawaited(_resolveOdooLineIdAfterQr(_lines[target]));
        unawaited(_reloadInvoiceHeaderAfterQr(invoiceId ?? _serverInvoiceId));
      }
    }
  }

  /// Bind QR-added bill lines to `account.move.line` so Dis% can be written.
  Future<void> _resolveOdooLineIdAfterQr(_BillLine line) async {
    try {
      final sid = await _odooSessionId();
      if (sid.isEmpty) return;
      await _ensureOdooLineId(line, sid);
    } catch (e) {
      if (kDebugMode) debugPrint('resolveOdooLineIdAfterQr: $e');
    }
  }

  /// After QR add, pull invoice header (customer/address/billed by/…) from Laravel.
  Future<void> _reloadInvoiceHeaderAfterQr(int? invoiceId) async {
    final id = invoiceId;
    if (id == null || id <= 0) return;
    try {
      if (!mounted) return;
      final inv = await InvoiceDetailService.fetchCustomerInvoice(
        context,
        seed: InvoiceSummaryModel(
          id: id,
          invoiceNumber: _invoiceNumber,
          billedBy: _billedBy,
        ),
      );
      if (!mounted) return;
      setState(() {
        final cust = (inv.displayCustomer ?? '').trim();
        if (cust.isNotEmpty &&
            !InvoiceSummaryModel.isPlaceholderCustomerName(cust)) {
          _customer = _NamedOption(
            name: cust,
            id: inv.pharmacyCustomerId,
            address: inv.address,
            phone: inv.phone,
          );
          if ((inv.address ?? '').trim().isNotEmpty) {
            _addressCtrl.text = inv.address!.trim();
          }
          if ((inv.phone ?? '').trim().isNotEmpty) {
            _phoneCtrl.text = inv.phone!.trim();
          }
        }
        final doctor = (inv.doctor ?? '').trim();
        if (doctor.isNotEmpty) {
          _doctor = _NamedOption(name: doctor);
        }
        if ((inv.expense ?? '').trim().isNotEmpty) {
          _expenseTextCtrl.text = inv.expense!.trim();
        }
        if (inv.expenseAmt != null) {
          final e = inv.expenseAmt!;
          _expenseCtrl.text =
              e == e.roundToDouble() ? e.toInt().toString() : e.toString();
        }
        final pay = (inv.paymentMode ?? '').trim();
        if (pay.isNotEmpty) {
          _paymentMode = _normalizePaymentMode(pay);
        }
        if ((inv.gstType ?? '').trim().isNotEmpty) {
          _gstType = _normalizeGstType(inv.gstType);
        }
        if ((inv.invoiceDate ?? '').trim().isNotEmpty) {
          final parsed = CalendarDate.parse(inv.invoiceDate);
          _invoiceDateDisplay =
          parsed != null ? CalendarDate.dmy(parsed) : inv.invoiceDate!.trim();
        }
        // Server value wins when present (e.g. another user billed the invoice).
        _applyBilledByFromServer(inv.billedBy);
        final responsible = (inv.responsiblePerson ?? '').trim();
        if (responsible.isNotEmpty) {
          _responsible = _NamedOption(name: responsible);
        }
        if ((inv.verifiedBy ?? '').trim().isNotEmpty) {
          _verifiedByCtrl.text = inv.verifiedBy!.trim();
        }
      });
      if (_customer != null) unawaited(_loadCustomerBalances(_customer!));
    } catch (e) {
      if (kDebugMode) debugPrint('reload invoice header after QR: $e');
    }
  }

  Future<void> _enrichQrLine(_BillLine line) async {
    if (line.hasRequiredLineFields) {
      await _maybeApplyLineDiscount(line);
      return;
    }
    await _syncLineFromStock(line);
    if (!mounted) return;
    await _maybeApplyLineDiscount(line);
    if (!mounted) return;
    setState(() {});
    _recalculate();
  }

  Future<StockItemModel?> _pickProductFromStock({String? selected}) async {
    _dismissKeyboard();

    final result = await showModalBottomSheet<StockItemModel>(
      context: context,
      isScrollControlled: true,
      backgroundColor: sectionBg,
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
                if (item.stockDisplayId != null) 'ID ${item.stockDisplayId}',
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
                                  fontSize: 18,
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
                          style: const TextStyle(color: sectionText),
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
                            fillColor: sectionCard,
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
                                  style: const TextStyle(color: sectionText),
                                ),
                                subtitle: sub.isEmpty
                                    ? null
                                    : Text(
                                  sub,
                                  style: const TextStyle(
                                    color: sectionTextMuted,
                                    fontSize: 14,
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
      backgroundColor: sectionBg,
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
                                  fontSize: 18,
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
                                    fontSize: 14,
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
                          style: const TextStyle(color: sectionText),
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
                            fillColor: sectionCard,
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
                            color: sectionTextMuted,
                          ),
                        ),
                        onTap: () =>
                            Navigator.pop(ctx, const _NamedOption(name: '')),
                      ),
                      const Divider(color: sectionCardBorder),
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
                                const TextStyle(color: sectionText),
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
    if (_isPaidEdit) {
      _toast('This bill is paid. Scanning is not allowed.');
      return;
    }
    FocusScope.of(context).unfocus();
    SystemChannels.textInput.invokeMethod('TextInput.hide');

    // Local-until-Save: scan only fills the phone bill. Save commits.
    _serverInvoiceId ??= widget.editInvoice?.id;
    if (!mounted) return;

    final result = await AddToCustomerPage.showPopup(
      context,
      lockedInvoiceNumber: _invoiceNumber,
      lockedInvoiceId: _serverInvoiceId ?? widget.editInvoice?.id,
      deferServerCommit: true,
      localReservedQty: ({
        String? product,
        String? potency,
        String? batch,
        String? pack,
      }) =>
          _reservedQtyForIdentity(
            product: product,
            potency: potency,
            batch: batch,
            pack: pack,
          ),
    );
    if (result != null && mounted) {
      _addOrUpdateLineFromQr(
        result.data,
        result.qty,
        invoiceId: result.invoiceId ?? _serverInvoiceId,
        rpcAdjustedItemQty: false,
        commitToServer: false,
      );
    }
  }

  bool get _isCreditPayment =>
      (_paymentMode ?? '').trim().toLowerCase().contains('credit');

  bool get _isPaidEdit => widget.editInvoice?.sectionKey == 'paid';

  /// True when this bill already exists as an Odoo `account.move`.
  bool get _hasServerInvoice =>
      _serverInvoiceId != null ||
          _invoiceCommittedOnServer ||
          widget.editInvoice?.id != null;

  /// Create the draft on the server when the UI only has a local preview number.
  ///
  /// With Odoo RPC off, Laravel `add_to_invoice` creates the bill on first
  /// Save — we only need a non-empty invoice number here.
  Future<bool> _ensureServerInvoice(LoginViewmodel login) async {
    _serverInvoiceId ??= widget.editInvoice?.id;
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

    if (!AppConfig.odooRpcEnabled) {
      return _invoiceNumber.trim().isNotEmpty;
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
        _draftCreatedThisSession = true;
      });
    } else {
      _invoiceNumber = draft.invoiceNumber;
      _serverInvoiceId = draft.invoiceId;
      _invoiceCommittedOnServer = true;
      _draftCreatedThisSession = true;
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

    var moveId = _serverInvoiceId;
    if ((moveId == null || moveId <= 0) && AppConfig.odooRpcEnabled) {
      _toast('Invoice was not created on server. Try Save again.');
      return false;
    }

    final webApi = WebApiImpl();

    for (var i = 0; i < pending.length; i++) {
      final line = pending[i];
      final qty = InvoiceCalcHelper.parseNum(line.qty);

      // Free-text line: write without stock_entry_id / stock deduction.
      if (!line.fromStock) {
        if (moveId == null || moveId <= 0) {
          _toast(
            'Line ${i + 1}: save a stock/QR product first, then add manual lines.',
          );
          return false;
        }
        final unit = InvoiceCalcHelper.parseNum(line.mrp);
        final disc = InvoiceCalcHelper.parseNum(line.discount);
        final taxPct = InvoiceCalcHelper.normalizeCustomerTaxPercent(
          InvoiceCalcHelper.parseNum(line.tax),
        );
        final ok = await OdooRpcHelper.addManualLineToCustomerInvoice(
          odooSid,
          invoiceId: moveId,
          productName: line.product ?? '',
          quantity: qty,
          potency: line.potency,
          company: line.company,
          pack: line.pack,
          group: line.group,
          batch: line.batch,
          hsn: line.hsn,
          rack: line.rack,
          mfd: line.manuf,
          expiry: line.expiry,
          priceUnit: unit > 0 ? unit : null,
          discount: disc > 0 ? disc : null,
          taxPercent: taxPct,
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
        line.rpcAdjustedItemQty = false;
        line.serverInvoiceId = moveId;
        _invoiceCommittedOnServer = true;
        continue;
      }

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

      if (stockRow != null) {
        final display = OdooRpcHelper.displayIdFromEntryStockRow(stockRow);
        if (display != null) line.stockDisplayId = display;
      }

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
        final disc = InvoiceCalcHelper.parseNum(line.discount);
        final mrp = InvoiceCalcHelper.parseNum(line.mrp);
        final params = <String, dynamic>{
          if (moveId != null && moveId > 0) 'invoice_id': moveId,
          'invoice_number': _invoiceNumber.trim(),
          'qr_data': token,
          'quantity': qtyValue,
        };
        final taxPct = InvoiceCalcHelper.normalizeCustomerTaxPercent(
          InvoiceCalcHelper.parseNum(line.tax),
        );
        params['tax_percent'] = taxPct;
        params['tax'] = taxPct;
        params['gst'] = taxPct;
        params['gst_percent'] = taxPct;
        if (disc > 0) {
          params['discount'] = disc;
          params['dis2_percent'] = disc;
          params['discount_percent'] = disc;
        }
        if (mrp > 0) {
          params['mrp'] = mrp;
          params['price_unit'] = mrp;
        }
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
          final meta = result is Map ? result : body;
          if (meta is Map) {
            final idRaw = meta['invoice_id'] ?? meta['id'];
            final id = idRaw is int
                ? idRaw
                : int.tryParse(idRaw?.toString() ?? '');
            if (id != null && id > 0) {
              line.serverInvoiceId = id;
              // If API spawned a different move, abandon the empty draft we made.
              if (moveId != null &&
                  id != moveId &&
                  _draftCreatedThisSession) {
                try {
                  final loginVm = context.read<LoginViewmodel>();
                  await OdooRpcHelper.deleteCustomerInvoiceDraft(
                    odooSid,
                    moveId,
                    login: loginVm.loginEmail,
                    password: loginVm.loginPassword,
                  );
                } catch (e) {
                  if (kDebugMode) {
                    debugPrint('cleanup abandoned draft #$moveId: $e');
                  }
                }
                _draftCreatedThisSession = false;
              }
              moveId = id;
              _serverInvoiceId = id;
            }
            final lineIdRaw = meta['line_id'];
            final lineId = lineIdRaw is int
                ? lineIdRaw
                : int.tryParse(lineIdRaw?.toString() ?? '');
            if (lineId != null && lineId > 0) {
              line.odooLineId = lineId;
            }
            final name =
            (meta['invoice_name'] ?? meta['invoice_number'] ?? '')
                .toString()
                .trim();
            if (name.isNotEmpty) {
              final match =
                  RegExp(r'(\d{3,5}/\d{4}-\d{2}|R\d+)').firstMatch(name);
              if (match != null) {
                _invoiceNumber = match.group(1)!;
              } else if (_invoiceNumber.trim().isEmpty) {
                _invoiceNumber = name;
              }
            }
          }
          // add_to_invoice often ignores Dis% — write it onto the new line now.
          await _ensureOdooLineId(line, odooSid);
          if (line.odooLineId != null && line.odooLineId! > 0) {
            await OdooRpcHelper.updateCustomerInvoiceLine(
              odooSid,
              lineId: line.odooLineId!,
              quantity: qty,
              priceUnit: mrp > 0 ? mrp : null,
              discount: disc,
              batch: line.batch,
              hsn: line.hsn.trim().isEmpty ? null : line.hsn.trim(),
              rack: line.rack.trim().isEmpty ? null : line.rack.trim(),
              taxPercent: taxPct,
            );
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
      if (moveId == null || moveId <= 0) {
        _toast(
          'Line ${i + 1}: could not add ${line.product ?? 'product'} '
          '(scan QR so Save can create the bill).',
        );
        return false;
      }

      final unit = InvoiceCalcHelper.parseNum(line.mrp);
      final disc = InvoiceCalcHelper.parseNum(line.discount);
      final taxPct = InvoiceCalcHelper.normalizeCustomerTaxPercent(
        InvoiceCalcHelper.parseNum(line.tax),
      );
      final ok = await OdooRpcHelper.addStockLineToCustomerInvoice(
        odooSid,
        invoiceId: moveId,
        stockRow: stockRow,
        quantity: qty,
        priceUnit: unit > 0 ? unit : null,
        discount: disc > 0 ? disc : null,
        taxPercent: taxPct,
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
      line.rpcAdjustedItemQty = true;
      line.serverInvoiceId = moveId;
      _invoiceCommittedOnServer = true;
    }

    return true;
  }

  /// Resolve [odooLineId] for QR-added lines that never loaded edit metadata.
  ///
  /// `add_to_invoice` often links a different `stock_entry_id` than the QR
  /// scan row, so stock-entry lookup alone fails — fall back to product/batch
  /// / newest product line on the move.
  Future<void> _ensureOdooLineId(
    _BillLine line,
    String sid, {
    Set<int>? excludeLineIds,
  }) async {
    if (line.odooLineId != null && line.odooLineId! > 0) return;
    final moveId = line.serverInvoiceId ?? _serverInvoiceId;
    if (moveId == null || moveId <= 0) return;

    final id = await OdooRpcHelper.resolveCustomerInvoiceLineId(
      sessionId: sid,
      invoiceId: moveId,
      stockEntryId: line.entryStockId,
      stockDisplayId: line.stockDisplayId,
      productName: line.product,
      batch: line.batch,
      excludeLineIds: excludeLineIds,
    );
    if (id != null && id > 0) {
      line.odooLineId = id;
      if (kDebugMode) {
        debugPrint(
          'ensureOdooLineId product=${line.product} batch=${line.batch} '
          '→ $id entry=${line.entryStockId} display=${line.stockDisplayId}',
        );
      }
    }
  }

  /// Resolve every committed bill line to an Odoo `account.move.line` id.
  Future<void> _resolveAllOdooLineIds(String sid, int moveId) async {
    final claimed = <int>{};
    for (final line in _lines) {
      final existing = line.odooLineId;
      if (existing != null && existing > 0) claimed.add(existing);
    }
    for (final line in _lines) {
      if (!line.serverCommitted && !line.hasRequiredLineFields) continue;
      if (line.odooLineId != null && line.odooLineId! > 0) continue;
      line.serverInvoiceId ??= moveId;
      await _ensureOdooLineId(line, sid, excludeLineIds: claimed);
      final id = line.odooLineId;
      if (id != null && id > 0) claimed.add(id);
    }
  }

  /// Push one committed line's qty/price to the server.
  ///
  /// With Odoo RPC on, writing `quantity` on `account.move.line` restores /
  /// deducts sellable stock — do not double-adjust client-side.
  /// With RPC off, Laravel `add_to_invoice` (increase) / website line update
  /// (decrease/set) must run so stock matches the new qty.
  Future<bool> _syncOneCommittedLine(_BillLine line, String sid) async {
    if (!line.hasRequiredLineFields) return false;

    await _ensureOdooLineId(line, sid);

    final qty = InvoiceCalcHelper.parseNum(line.qty);
    final mrp = InvoiceCalcHelper.parseNum(line.mrp);
    final disc = InvoiceCalcHelper.parseNum(line.discount);
    final newQty = qty > 0 ? qty : 0.0;
    final prev = line.serverCommitted ? line.serverCommittedQty : newQty;
    final delta = newQty - prev;

    if (!AppConfig.odooRpcEnabled) {
      final ok = await _syncOneCommittedLineLaravel(
        line,
        newQty: newQty,
        prevQty: prev,
        delta: delta,
        discount: disc,
        mrp: mrp,
      );
      if (!ok) return false;
      // Rebuild may clear serverCommitted when newQty is 0; still update
      // local committed qty + sellable stock display from the delta.
      line.serverCommittedQty = line.serverCommitted ? newQty : 0;
      _bumpLineAvailableStock(line, restored: -delta);
      if (kDebugMode && delta.abs() > 0.0001) {
        debugPrint(
          'line qty synced product=${line.product} '
          'prevCommitted=$prev → $newQty (stock via Laravel)',
        );
      }
      return true;
    }

    if (line.odooLineId == null || line.odooLineId! <= 0) {
      // Without a line id we cannot persist Dis% — fail loudly when Dis set.
      if (disc > 0.01) {
        if (kDebugMode) {
          debugPrint(
            'syncOneCommittedLine: no odooLineId for '
            '${line.product} Dis=$disc — cannot write',
          );
        }
        return false;
      }
    } else {
      final taxPct = InvoiceCalcHelper.normalizeCustomerTaxPercent(
        InvoiceCalcHelper.parseNum(line.tax),
      );
      final ok = await OdooRpcHelper.updateCustomerInvoiceLine(
        sid,
        lineId: line.odooLineId!,
        quantity: qty > 0 ? qty : null,
        priceUnit: mrp > 0 ? mrp : null,
        discount: disc,
        batch: line.batch,
        hsn: line.hsn.trim().isEmpty ? null : line.hsn.trim(),
        rack: line.rack.trim().isEmpty ? null : line.rack.trim(),
        taxPercent: taxPct,
      );
      if (!ok) return false;
    }

    if (line.serverCommitted) {
      line.serverCommittedQty = newQty;
      if (kDebugMode && (prev - newQty).abs() > 0.0001) {
        debugPrint(
          'line qty synced product=${line.product} '
          'prevCommitted=$prev → $newQty (stock via Odoo line write)',
        );
      }
    }
    return true;
  }

  void _bumpLineAvailableStock(_BillLine line, {required double restored}) {
    if (restored.abs() < 0.0001) return;
    if (line.warehouseStockBase != null) {
      // Server changed warehouse; keep baseline aligned then recompute.
      line.warehouseStockBase =
          (line.warehouseStockBase! + restored).clamp(0, double.infinity);
      _recomputeLineAvailableStock(line);
      return;
    }
    final raw = (line.availableStock ?? '').trim();
    if (raw.isEmpty) return;
    final current = double.tryParse(raw);
    if (current == null) return;
    final next = (current + restored).clamp(0, double.infinity).toDouble();
    line.availableStock = next == next.roundToDouble()
        ? next.toInt().toString()
        : next.toStringAsFixed(2);
  }

  /// Laravel-only qty sync: increase via `add_to_invoice`, decrease/set via
  /// website invoice update (same stock rules as the pharmacy site).
  Future<bool> _syncOneCommittedLineLaravel(
    _BillLine line, {
    required double newQty,
    required double prevQty,
    required double delta,
    required double discount,
    required double mrp,
  }) async {
    final login = context.read<LoginViewmodel>();
    final flutterSid = login.sessionId ?? '';
    if (flutterSid.isEmpty) return false;

    // Qty unchanged — nothing to push for stock (Dis%/price ignored here).
    if (delta.abs() < 0.0001) return true;

    final moveId = line.serverInvoiceId ?? _serverInvoiceId ?? widget.editInvoice?.id;

    // Increase: add_to_invoice deducts the delta (same as another QR add).
    if (delta > 0.0001) {
      final qr = (line.addQrData ?? line.addQrDataAlt ?? '').trim();
      if (qr.isEmpty) {
        if (kDebugMode) {
          debugPrint(
            'syncOneCommittedLineLaravel: no qr_data to increase '
            '${line.product}',
          );
        }
        return false;
      }
      final taxPct = InvoiceCalcHelper.normalizeCustomerTaxPercent(
        InvoiceCalcHelper.parseNum(line.tax),
      );
      final qtyValue =
          delta == delta.roundToDouble() ? delta.toInt() : delta;
      final params = <String, dynamic>{
        'invoice_number': _invoiceNumber.trim(),
        'qr_data': qr,
        'quantity': qtyValue,
        if (moveId != null && moveId > 0) 'invoice_id': moveId,
        'tax_percent': taxPct,
        'tax': taxPct,
        'gst': taxPct,
        'gst_percent': taxPct,
      };
      if (kDebugMode) {
        debugPrint('syncOneCommittedLineLaravel add delta params: $params');
      }
      final response = await WebApiImpl().addMedicineQty(
        userDetails: {
          'jsonrpc': '2.0',
          'method': 'call',
          'params': params,
          'id': 1,
          ...params,
        },
        sessionId: flutterSid,
      );
      final body = response.body;
      if (kDebugMode) {
        debugPrint(
          'syncOneCommittedLineLaravel add delta response: '
          '${body.length > 240 ? '${body.substring(0, 240)}…' : body}',
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return false;
      }
      try {
        final decoded = jsonDecode(body);
        if (decoded is Map) {
          final status = '${decoded['status'] ?? ''}'.toLowerCase();
          if (status == 'error' || status == 'fail' || status == 'failed') {
            return false;
          }
        }
      } catch (_) {
        return false;
      }
      return true;
    }

    // Decrease: prefer website line qty write when it restores stock; otherwise
    // hard-discard + rebuild (never cancel — cancel burns invoice numbers).
    if (moveId == null || moveId <= 0) {
      if (kDebugMode) {
        debugPrint(
          'syncOneCommittedLineLaravel: no invoice id to reduce '
          '${line.product}',
        );
      }
      return false;
    }

    var email = (login.loginEmail ?? '').trim();
    var pass = login.loginPassword ?? '';
    if (email.isEmpty || pass.isEmpty) {
      final saved = await AuthSessionStore.load();
      email = (saved?.email ?? '').trim();
      pass = saved?.password ?? '';
    }
    if (email.isEmpty || pass.isEmpty) {
      if (kDebugMode) {
        debugPrint(
          'syncOneCommittedLineLaravel: missing login for qty reduce',
        );
      }
      return false;
    }

    final needRestore = -delta;
    // Refresh live line id + entry_stock_id + qr (website form rewrites
    // line ids; qty writes must key off entry_stock_id like the site).
    final lineId = await _resolveLineIdFromCustomerInvoice(
          sessionId: flutterSid,
          invoiceId: moveId,
          line: line,
        ) ??
        line.odooLineId;
    final qr = (line.addQrData ?? line.addQrDataAlt ?? '').trim();
    final stockBefore = qr.isEmpty
        ? null
        : await _fetchQrAvailableStock(sessionId: flutterSid, qrData: qr);

    if (kDebugMode) {
      debugPrint(
        'syncOneCommittedLineLaravel: decrease ${line.product} '
        'prev=$prevQty → $newQty needStock=+$needRestore '
        'stockBefore=$stockBefore lineId=$lineId '
        'entry=${line.entryStockId} '
        'qr=${qr.isEmpty ? '(none)' : qr}',
      );
    }

    if (lineId != null && lineId > 0) {
      final wrote = await FlutterCustomerInvoiceWebApi.updateInvoiceLineQuantity(
        invoiceId: moveId,
        lineId: lineId,
        quantity: newQty,
        email: email,
        password: pass,
        entryStockId: line.entryStockId,
        sessionId: flutterSid,
        apiToken: AuthSessionStore.currentApiToken,
      );
      if (wrote) {
        if (stockBefore == null || qr.isEmpty) {
          line.odooLineId = lineId;
          return true;
        }
        final stockAfter = await _fetchQrAvailableStock(
          sessionId: flutterSid,
          qrData: qr,
        );
        if (stockAfter != null &&
            stockAfter + 0.0001 >= stockBefore + needRestore) {
          if (kDebugMode) {
            debugPrint(
              'syncOneCommittedLineLaravel: website qty ok '
              'stock $stockBefore → $stockAfter',
            );
          }
          line.odooLineId = lineId;
          return true;
        }
        if (kDebugMode) {
          debugPrint(
            'syncOneCommittedLineLaravel: website qty wrote but stock '
            'not restored (before=$stockBefore after=$stockAfter) '
            '— falling back to discard+rebuild',
          );
        }
      }
    }

    final rebuilt = await _rebuildLaravelInvoiceAtCurrentQtys(
      flutterSid: flutterSid,
      email: email,
      password: pass,
      moveId: moveId,
    );
    if (!rebuilt) return false;

    if (stockBefore != null && qr.isNotEmpty) {
      final stockAfter = await _fetchQrAvailableStock(
        sessionId: flutterSid,
        qrData: qr,
      );
      if (stockAfter != null &&
          stockAfter + 0.0001 < stockBefore + needRestore) {
        if (kDebugMode) {
          debugPrint(
            'syncOneCommittedLineLaravel: rebuild ok but stock short '
            'before=$stockBefore after=$stockAfter need=+$needRestore',
          );
        }
        return false;
      }
    }
    return true;
  }

  /// Discard the Laravel draft (restores all committed stock) and re-add every
  /// server-committed line at its current UI qty via `add_to_invoice`.
  Future<bool> _rebuildLaravelInvoiceAtCurrentQtys({
    required String flutterSid,
    required String email,
    required String password,
    required int moveId,
  }) async {
    final committed = _lines.where((l) => l.serverCommitted).toList();
    if (committed.isEmpty) return true;

    for (final l in committed) {
      final q = InvoiceCalcHelper.parseNum(l.qty);
      if (q <= 0.0001) continue;
      final qr = (l.addQrData ?? l.addQrDataAlt ?? '').trim();
      if (qr.isEmpty) {
        if (kDebugMode) {
          debugPrint(
            'rebuildLaravelInvoice: cannot re-add ${l.product} without qr_data',
          );
        }
        return false;
      }
    }

    final discarded = await FlutterCustomerInvoiceWebApi.discardInvoice(
      invoiceId: moveId,
      email: email,
      password: password,
      sessionId: flutterSid,
      apiToken: AuthSessionStore.currentApiToken,
    );
    if (!discarded) {
      if (kDebugMode) {
        debugPrint(
          'rebuildLaravelInvoice: discard #$moveId failed',
        );
      }
      return false;
    }

    _serverInvoiceId = null;
    _invoiceCommittedOnServer = false;
    for (final l in committed) {
      l.odooLineId = null;
      l.serverInvoiceId = null;
      l.serverCommitted = false;
      l.serverCommittedQty = 0;
    }

    int? newInvoiceId;
    final invoiceNumber = _invoiceNumber.trim();

    for (final l in committed) {
      final q = InvoiceCalcHelper.parseNum(l.qty);
      if (q <= 0.0001) continue;
      final qr = (l.addQrData ?? l.addQrDataAlt ?? '').trim();
      final taxPct = InvoiceCalcHelper.normalizeCustomerTaxPercent(
        InvoiceCalcHelper.parseNum(l.tax),
      );
      final qtyValue = q == q.roundToDouble() ? q.toInt() : q;
      final params = <String, dynamic>{
        'invoice_number': invoiceNumber,
        'qr_data': qr,
        'quantity': qtyValue,
        if (newInvoiceId != null && newInvoiceId > 0) 'invoice_id': newInvoiceId,
        'tax_percent': taxPct,
        'tax': taxPct,
        'gst': taxPct,
        'gst_percent': taxPct,
      };
      if (kDebugMode) {
        debugPrint('rebuildLaravelInvoice add_to_invoice: $params');
      }
      final response = await WebApiImpl().addMedicineQty(
        userDetails: {
          'jsonrpc': '2.0',
          'method': 'call',
          'params': params,
          'id': 1,
          ...params,
        },
        sessionId: flutterSid,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (kDebugMode) {
          debugPrint(
            'rebuildLaravelInvoice add failed HTTP ${response.statusCode}',
          );
        }
        return false;
      }
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is! Map) return false;
        final status = '${decoded['status'] ?? ''}'.toLowerCase();
        if (status == 'error' || status == 'fail' || status == 'failed') {
          return false;
        }
        final invId = decoded['invoice_id'] ?? decoded['id'];
        final parsedInv = invId is int ? invId : int.tryParse('$invId');
        if (parsedInv != null && parsedInv > 0) {
          newInvoiceId = parsedInv;
          _serverInvoiceId = parsedInv;
          _invoiceCommittedOnServer = true;
        }
        final newLineId = decoded['line_id'];
        final parsedLine =
            newLineId is int ? newLineId : int.tryParse('$newLineId');
        if (parsedLine != null && parsedLine > 0) {
          l.odooLineId = parsedLine;
        }
        l.serverInvoiceId = newInvoiceId;
        l.serverCommitted = true;
        l.serverCommittedQty = q;
        l.addedThisSession = true;
      } catch (e) {
        if (kDebugMode) debugPrint('rebuildLaravelInvoice parse: $e');
        return false;
      }
    }

    if (kDebugMode) {
      debugPrint(
        'rebuildLaravelInvoice: done old=#$moveId new=#$newInvoiceId '
        'lines=${committed.where((l) => l.serverCommitted).length}',
      );
    }
    return newInvoiceId != null ||
        committed.every((l) => InvoiceCalcHelper.parseNum(l.qty) <= 0.0001);
  }

  Future<double?> _fetchQrAvailableStock({
    required String sessionId,
    required String qrData,
  }) async {
    final token = qrData.trim();
    if (token.isEmpty) return null;
    try {
      final candidates = <String>[
        token,
        if (!token.toUpperCase().startsWith('SUPPLIER:')) 'SUPPLIER:$token',
      ];
      for (final qr in candidates) {
        final response = await WebApiImpl().qrFetch(
          sessionId: sessionId,
          userDetails: {
            'jsonrpc': '2.0',
            'method': 'call',
            'params': {'qr_data': qr},
            'id': 1,
            'qr_data': qr,
          },
        );
        if (response.statusCode < 200 || response.statusCode >= 300) continue;
        final decoded = jsonDecode(response.body);
        if (decoded is! Map) continue;
        final data = decoded['data'] ??
            (decoded['result'] is Map ? decoded['result']['data'] : null);
        if (data is! Map) continue;
        for (final key in const [
          'available_stock',
          'stock_qty',
          'entry_stock_qty',
          'batch_stock_qty',
          'total_stock_qty',
          'product_stock_qty',
        ]) {
          final v = data[key];
          if (v == null) continue;
          final n = v is num ? v.toDouble() : double.tryParse('$v');
          if (n != null) return n;
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('_fetchQrAvailableStock: $e');
    }
    return null;
  }

  // Kept for Laravel line-id lookup if a dedicated qty API appears.
  // ignore: unused_element
  Future<int?> _resolveLineIdFromCustomerInvoice({
    required int invoiceId,
    required String sessionId,
    required _BillLine line,
  }) async {
    try {
      final response = await WebApiImpl().fetchInvoiceList(
        endpointPath: EndPoint.customerInvoice.path,
        sessionId: sessionId,
        userDetails: {
          'invoice_id': invoiceId,
          'id': invoiceId,
        },
        logResponseBody: false,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return null;
      final data = decoded['data'];
      if (data is! Map) return null;
      final lines = data['lines'];
      if (lines is! List) return null;
      final product = (line.product ?? '').trim().toLowerCase();
      final batch = (line.batch ?? '').trim().toLowerCase();
      final uid = (line.addQrData ?? line.addQrDataAlt ?? '').trim().toLowerCase();
      int? fallback;
      String? fallbackUid;
      int? fallbackEntry;
      void applyMeta(Map raw, String lineUidRaw) {
        if ((line.addQrData ?? '').trim().isEmpty && lineUidRaw.isNotEmpty) {
          line.addQrData = lineUidRaw;
        }
        final entryRaw = raw['entry_stock_id'] ??
            raw['stock_entry_id'] ??
            raw['entry_id'];
        final entryId = entryRaw is int
            ? entryRaw
            : int.tryParse('$entryRaw');
        if (entryId != null && entryId > 0) {
          line.entryStockId = entryId;
        }
        line.odooLineId = raw['id'] is int
            ? raw['id'] as int
            : int.tryParse('${raw['id'] ?? raw['line_id']}') ?? line.odooLineId;
      }

      for (final raw in lines) {
        if (raw is! Map) continue;
        final id = raw['id'] ?? raw['line_id'];
        final parsed = id is int ? id : int.tryParse('$id');
        if (parsed == null || parsed <= 0) continue;
        final lineUidRaw =
            '${raw['line_uid'] ?? raw['uid'] ?? raw['product_barcode'] ?? ''}'
                .trim();
        final lineUid = lineUidRaw.toLowerCase();
        final entryRaw = raw['entry_stock_id'] ??
            raw['stock_entry_id'] ??
            raw['entry_id'];
        final entryId = entryRaw is int
            ? entryRaw
            : int.tryParse('$entryRaw');
        fallback ??= parsed;
        fallbackEntry ??= entryId;
        if (fallbackUid == null && lineUidRaw.isNotEmpty) {
          fallbackUid = lineUidRaw;
        }
        if (uid.isNotEmpty && lineUid == uid) {
          applyMeta(Map<String, dynamic>.from(raw), lineUidRaw);
          return parsed;
        }
        final name = '${raw['product_name'] ?? raw['name'] ?? ''}'
            .trim()
            .toLowerCase();
        final b = '${raw['batch'] ?? raw['batch_no'] ?? ''}'
            .trim()
            .toLowerCase();
        if (product.isNotEmpty && name == product) {
          if (batch.isEmpty || b.isEmpty || b == batch) {
            applyMeta(Map<String, dynamic>.from(raw), lineUidRaw);
            return parsed;
          }
        }
      }
      if ((line.addQrData ?? '').trim().isEmpty &&
          fallbackUid != null &&
          fallbackUid.isNotEmpty) {
        line.addQrData = fallbackUid;
      }
      if (fallbackEntry != null &&
          fallbackEntry > 0 &&
          (line.entryStockId == null || line.entryStockId! <= 0)) {
        line.entryStockId = fallbackEntry;
      }
      return fallback;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('_resolveLineIdFromCustomerInvoice: $e');
      }
      return null;
    }
  }

  /// Push edits on lines that already exist on the server (edit bill / QR).
  Future<bool> _syncCommittedLines(LoginViewmodel login) async {
    final sid = await _odooSessionId();
    final flutterSid = login.sessionId ?? '';
    if (sid.isEmpty && flutterSid.isEmpty) return false;
    final session = sid.isNotEmpty ? sid : flutterSid;

    final moveId = _serverInvoiceId ?? widget.editInvoice?.id;
    if (moveId != null && moveId > 0) {
      await _resolveAllOdooLineIds(session, moveId);
    }

    // Zero lines removed locally since last Save.
    for (final line in List<_BillLine>.from(_deferredServerRemovals)) {
      line.qty = '0';
      final ok = await _syncOneCommittedLine(line, session);
      if (!ok) {
        _toast(
          'Could not remove ${line.product ?? 'line'} on the server.',
        );
        return false;
      }
    }
    _deferredServerRemovals.clear();

    final committed = _lines
        .where(
          (l) => l.serverCommitted && l.hasRequiredLineFields,
        )
        .toList(growable: false);
    if (committed.isEmpty) return true;

    for (final line in committed) {
      final ok = await _syncOneCommittedLine(line, session);
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
      var email = (login.loginEmail ?? '').trim();
      var pass = login.loginPassword ?? '';
      if (email.isEmpty || pass.isEmpty) {
        final saved = await AuthSessionStore.load();
        email = (saved?.email ?? '').trim();
        pass = saved?.password ?? '';
      }
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
      final billed = (_billedBy ?? '').trim().isEmpty
          ? _kDefaultBilledBy
          : (_billedBy ?? '').trim();
      final clearCustomer = customerName.isEmpty ||
          InvoiceSummaryModel.isPlaceholderCustomerName(customerName);

      // Laravel path: website PUT (Odoo write no-ops when RPC is off).
      if (!AppConfig.odooRpcEnabled) {
        if (email.isEmpty || pass.isEmpty) return false;
        final ok = await FlutterCustomerInvoiceWebApi.updateInvoiceHeader(
          invoiceId: moveId,
          email: email,
          password: pass,
          customerName: clearCustomer ? null : customerName,
          customerId: clearCustomer ? null : _customer?.id,
          clearCustomer: clearCustomer,
          billedBy: billed,
          address: _addressCtrl.text.trim(),
          phone: _phoneCtrl.text.trim(),
          paymentMode: _paymentMode,
          sessionId: sid,
          apiToken: AuthSessionStore.currentApiToken,
        );
        if (kDebugMode) {
          debugPrint(
            'syncHeader Laravel #$moveId ok=$ok '
            'customer=${clearCustomer ? '(walk-in)' : customerName} '
            'billedBy=$billed',
          );
        }
        return ok;
      }

      final rate = double.tryParse(_discountRateCtrl.text.trim());
      final ok = await OdooRpcHelper.updateCustomerInvoiceHeader(
        sessionId: sid,
        invoiceId: moveId,
        customerName: clearCustomer ? '' : customerName,
        pharmacyCustomerId: clearCustomer ? null : _customer?.id,
        clearCustomer: clearCustomer,
        address: _addressCtrl.text.trim(),
        phone: _phoneCtrl.text.trim(),
        doctor: (_doctor?.name ?? '').trim(),
        doctorId: _doctor?.id,
        responsiblePersonId: _responsible?.id,
        responsiblePersonName: (_responsible?.name ?? '').trim(),
        paymentMode: _paymentMode,
        gstType: _gstType,
        discountCategoryId: _discountCategory?.id,
        clearDiscountCategory: _discountCategory == null,
        discountType: _discountType,
        discountRate: rate,
        expense: _expenseTextCtrl.text.trim(),
        expenseAmt: () {
          final raw = _expenseCtrl.text.trim();
          if (raw.isEmpty) return null;
          final n = InvoiceCalcHelper.parseNum(raw);
          return n == 0 && raw != '0' && raw != '0.0' ? null : n;
        }(),
        remarks: _remarksCtrl.text.trim(),
        verifiedBy: _verifiedByCtrl.text.trim(),
      );
      // Keep local customer id in sync with pharmacy.customer created/resolved.
      // Skip when we already have a pharmacy.customer id (avoids slow re-reads).
      if (ok &&
          customerName.isNotEmpty &&
          mounted &&
          (_customer?.id == null || _customer!.id! <= 0)) {
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

    // Never create/save an invoice without at least one product line.
    // This check must happen before _ensureServerInvoice(), otherwise an empty
    // Odoo draft gets created even when the user has entered no bill data.
    if (_lines.isEmpty) {
      _toast('Please add at least one product before saving the bill.');
      return;
    }

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

    // Block double-taps before any await (credit warning / server calls).
    setState(() => _saving = true);
    FocusScope.of(context).unfocus();

    // Warning only — never blocks create / save.
    await _warnIfCreditLimitExceeded();
    if (!mounted) {
      _saving = false;
      return;
    }
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
      if (responsibleName.isNotEmpty) {
        await BillNameStore.rememberResponsible(responsibleName);
      }

      // Local preview number is not a real bill until create / first add.
      final ensured = await _ensureServerInvoice(login);
      if (!ensured) {
        _toast(
          'Could not create the bill on the server. Please try again.',
        );
        return;
      }

      final hasServerId =
          (_serverInvoiceId ?? widget.editInvoice?.id ?? 0) > 0;

      // When the bill already exists, sync header first. On a brand-new
      // Laravel bill there is no id yet — commit lines first (add_to_invoice
      // creates the draft), then push header.
      if (hasServerId) {
        final headerBeforeLines = await _syncHeaderToOdoo(login);
        if (!headerBeforeLines) {
          _toast(
            'Could not save customer details to the bill. Please try again.',
          );
          return;
        }
      }

      // Manually / QR-scanned products go through add_to_invoice on Save.
      final linesOk = await _commitPendingLines(login);
      if (!linesOk) return;

      final syncedLines = await _syncCommittedLines(login);
      if (!syncedLines) return;

      // Always write header after lines so customer/billed_by stick on the
      // move id returned by add_to_invoice.
      final synced = await _syncHeaderToOdoo(login);
      if (!synced) {
        _toast(
          'Bill was created but customer details could not be saved. '
              'Open the bill and try again.',
        );
      }

      // Website TOTAL/DIS: push app Dis% (not stale Odoo 0) via parent onchange.
      final moveId = _serverInvoiceId ?? widget.editInvoice?.id;
      if (moveId != null && moveId > 0) {
        final sid = await _odooSessionId();
        if (sid.isNotEmpty) {
          // Resolve line ids for QR lines before website Dis% sync.
          // Stock-entry match often fails after add_to_invoice — use product.
          await _resolveAllOdooLineIds(sid, moveId);
          final appLines = <Map<String, dynamic>>[];
          for (final line in _lines) {
            if (!line.hasRequiredLineFields) continue;
            var lineId = line.odooLineId;
            if (lineId == null || lineId <= 0) {
              await _ensureOdooLineId(line, sid);
              lineId = line.odooLineId;
            }
            final mrp = InvoiceCalcHelper.parseNum(line.mrp);
            final disc = InvoiceCalcHelper.parseNum(line.discount);
            if (lineId == null || lineId <= 0 || mrp <= 0) {
              if (kDebugMode && disc > 0.01) {
                debugPrint(
                  'save sync skip Dis=$disc — no line id for ${line.product}',
                );
              }
              continue;
            }
            appLines.add(
              OdooRpcHelper.pharmacyLineDiscountSpec(
                lineId: lineId,
                mrp: mrp,
                discount: disc,
                quantity: InvoiceCalcHelper.parseNum(line.qty),
                taxPercent: InvoiceCalcHelper.normalizeCustomerTaxPercent(
                  InvoiceCalcHelper.parseNum(line.tax),
                ),
              ),
            );
          }
          if (kDebugMode) {
            debugPrint(
              'save sync website Dis% move=$moveId lines=${appLines.length} '
              'total=${_totals.total} '
              'dis=${appLines.map((e) => e['discount']).join(",")}',
            );
          }
          await OdooRpcHelper.syncPharmacyWebsiteTotals(
            sid,
            invoiceId: moveId,
            total: _totals.total,
            balance: _totals.balance,
            untaxed: _totals.untaxed > 0 ? _totals.untaxed : _totals.subtotal,
            taxAmount: _totals.taxAmount,
            discountTotal: _totals.discountTotal,
            appLines: appLines,
          );
        }
      }

      if (!mounted) return;
      final shown = _invoiceNumber.trim().isEmpty
          ? 'draft'
          : _invoiceNumber.trim();
      _publishSavedInvoiceLocally();
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

  /// Push local Dis% + expense totals into list caches so the Customer Invoice
  /// / Payment Book screens show the bill amount immediately (without waiting
  /// for a full payment-history refetch).
  void _publishSavedInvoiceLocally() {
    final id = _serverInvoiceId ?? widget.editInvoice?.id;
    if (id == null || id <= 0) return;
    final total = _totals.total;
    final dateRaw = _invoiceDateDisplay.trim();
    final parsedDate = CalendarDate.parse(dateRaw);
    final responsible = (_responsible?.name ?? '').trim();
    final billed = (_billedBy ?? '').trim();
    final verified = _verifiedByCtrl.text.trim();
    final remarks = _remarksCtrl.text.trim();
    final discCat = (_discountCategory?.name ?? '').trim();
    final summary = InvoiceSummaryModel(
      id: id,
      invoiceNumber: _invoiceNumber.trim().isEmpty
          ? null
          : _invoiceNumber.trim(),
      customer: (_customer?.name ?? '').trim().isEmpty
          ? null
          : _customer!.name.trim(),
      pharmacyCustomerId: _customer?.id,
      address: _addressCtrl.text.trim().isEmpty
          ? null
          : _addressCtrl.text.trim(),
      phone: _phoneCtrl.text.trim().isEmpty ? null : _phoneCtrl.text.trim(),
      responsiblePerson: responsible.isEmpty ? null : responsible,
      doctor: (_doctor?.name ?? '').trim().isEmpty
          ? null
          : _doctor!.name.trim(),
      invoiceDate: parsedDate != null
          ? CalendarDate.ymd(parsedDate)
          : CalendarDate.ymd(),
      billedBy: billed.isEmpty ? _kDefaultBilledBy : billed,
      status: 'draft',
      moveState: 'draft',
      paymentState: 'not_paid',
      paymentMode: _paymentMode,
      gstType: _gstType,
      discountCategory: discCat.isEmpty ? null : discCat,
      discountType: _discountType,
      discountRate: InvoiceCalcHelper.parseNum(_discountRateCtrl.text),
      verifiedBy: verified.isEmpty ? null : verified,
      expense: _expenseTextCtrl.text.trim().isEmpty
          ? null
          : _expenseTextCtrl.text.trim(),
      expenseAmt: InvoiceCalcHelper.parseNum(_expenseCtrl.text),
      remarks: remarks.isEmpty ? null : remarks,
      taxAmount: _totals.taxAmount,
      subtotal: _totals.subtotal,
      discountTotal: _totals.discountTotal,
      total: total,
      balance: _totals.balance,
    );
    CustomerInvoiceViewModel.upsertInvoice(summary);
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

  void _refreshLocalAvailableWhileEditing(_BillLine line) {
    if (!line.fromStock) return;
    // Prefer warehouse baseline so Available Stock rises/falls with Qty.
    if (line.warehouseStockBase != null) {
      _recomputeLineAvailableStock(line);
      return;
    }
    final base = _editingAvailBase;
    if (base == null) return;
    final newQty = InvoiceCalcHelper.parseNum(line.qty);
    final remaining = (base - newQty).clamp(0, double.infinity).toDouble();
    line.availableStock = remaining == remaining.roundToDouble()
        ? remaining.toInt().toString()
        : remaining.toStringAsFixed(2);
  }

  void _editLine(int index) {
    if (index == _editingLineIndex) return;
    if (!_warnIfEditingLineIncomplete()) return;
    setState(() {
      _editingLineIndex = index;
      if (index >= 0 && index < _lines.length) {
        final line = _lines[index];
        final startQty = InvoiceCalcHelper.parseNum(line.qty);
        _editingLineStartQty = startQty;
        if (line.warehouseStockBase != null) {
          _editingAvailBase = line.warehouseStockBase;
          _recomputeLineAvailableStock(line);
        } else {
          final avail =
              double.tryParse((line.availableStock ?? '').trim()) ?? 0;
          _editingAvailBase = avail + startQty;
        }
      } else {
        _editingLineStartQty = null;
        _editingAvailBase = null;
      }
      _lineRequiredErrors = {};
    });
  }

  Future<void> _doneEditingLine(int index) async {
    if (!_warnIfEditingLineIncomplete(forLineIndex: index)) return;
    if (index < 0 || index >= _lines.length) return;
    final line = _lines[index];

    // Apply Customer Group Discount once more after all Add-a-line fields are set.
    await _maybeApplyLineDiscount(line);

    // Local-until-Save: qty/price stay on the phone; Save pushes deltas.
    _refreshLocalAvailableWhileEditing(line);
    _recalcLinePrices(line);
    _recalculate();

    if (!mounted) return;
    setState(() {
      _editingLineIndex = null;
      _editingLineStartQty = null;
      _editingAvailBase = null;
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
    // Local-until-Save: never touch server stock here. If the line was already
    // committed, remember it so Save can zero it; Discard abandons the list.
    if (line.serverCommitted && line.serverCommittedQty > 0) {
      _deferredServerRemovals.add(line);
    }

    setState(() {
      final next = [..._lines]..removeAt(index);
      _lines = next;
      _adjustEditingIndexAfterRemove(index);
      if (_lines.every((l) => !l.serverCommitted)) {
        _invoiceCommittedOnServer = false;
      }
    });
    _recalculate();
  }

  Future<bool> _restoreLineStock(_BillLine line) async {
    final login = context.read<LoginViewmodel>();
    final sessionId = login.sessionId ?? '';
    if (sessionId.isEmpty) {
      _toast('Session expired. Please log in again.');
      return false;
    }
    // Resolve AML id before remove — QR display stock id often ≠ line
    // stock_entry_id, so matching by entry alone used to miss.
    final odooSid = await _odooSessionId();
    if (odooSid.isNotEmpty) {
      await _ensureOdooLineId(line, odooSid);
    }

    return InvoiceStockRestoreHelper.restoreAfterLineDelete(
      flutterSessionId: sessionId,
      invoiceNumber: _invoiceNumber,
      invoiceId: line.serverInvoiceId ?? _serverInvoiceId,
      invoiceLineId: line.odooLineId,
      quantity: line.serverCommittedQty,
      productName: line.product,
      batch: line.batch,
      potency: line.potency,
      stockEntryId: line.entryStockId,
      stockDisplayId: line.stockDisplayId,
      restoreItemQty: line.rpcAdjustedItemQty,
      sellableStockDeducted: line.fromStock,
      login: login.loginEmail,
      password: login.loginPassword,
      db: LoginViewmodel.dbName,
    );
  }

  bool get _hasLocalBillContent =>
      _lines.isNotEmpty ||
      _deferredServerRemovals.isNotEmpty ||
      _customer != null ||
      _addressCtrl.text.trim().isNotEmpty ||
      _phoneCtrl.text.trim().isNotEmpty ||
      _remarksCtrl.text.trim().isNotEmpty;

  bool get _shouldWarnBeforeLeave {
    if (_billKept) return false;
    // Editing an existing draft: warn only when local edits would be abandoned.
    if (widget.editInvoice != null) {
      return _hasLocalEditsVsServer;
    }
    return _hasLocalBillContent || _draftCreatedThisSession;
  }

  /// True when edit-mode UI differs from what was loaded / last saved.
  bool get _hasLocalEditsVsServer {
    if (_deferredServerRemovals.isNotEmpty) return true;
    for (final l in _lines) {
      if (!l.serverCommitted && l.hasRequiredLineFields) return true;
      if (l.serverCommitted) {
        final q = InvoiceCalcHelper.parseNum(l.qty);
        if ((q - l.serverCommittedQty).abs() > 0.0001) return true;
      }
    }
    return false;
  }

  Future<bool> _confirmLeaveWithoutSave() async {
    final editingExisting = widget.editInvoice != null;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: sectionBg,
        title: Text(
          editingExisting ? 'Discard local changes?' : 'Leave without saving?',
          style: const TextStyle(color: sectionText, fontWeight: FontWeight.w700),
        ),
        content: Text(
          editingExisting
              ? 'Changes on this phone will be discarded. The server bill stays as it was.'
              : 'This bill will not be saved. Nothing is written to the server, and the bill number can be used again.',
          style: const TextStyle(color: sectionText),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Stay', style: TextStyle(color: sectionTextMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Discard',
              style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
    return result == true;
  }

  /// Close without Save — phone-only. Never deletes/cancels a server bill.
  Future<void> _discardAndClose() async {
    if (_removingLine || _saving) return;

    if (_shouldWarnBeforeLeave) {
      final ok = await _confirmLeaveWithoutSave();
      if (!ok || !mounted) return;
    }

    try {
      Provider.of<CustomerMedViewmodel>(context, listen: false)
          .clearLastAddedInvoice();
    } catch (_) {}

    // New bill: free the preview number for the next draft.
    if (widget.editInvoice == null) {
      try {
        final med = Provider.of<CustomerMedViewmodel>(context, listen: false);
        final freed = _invoiceNumber.trim();
        if (freed.isNotEmpty) {
          med.rememberDiscardedInvoiceNumber(freed);
        }
      } catch (_) {}
      _serverInvoiceId = null;
      _invoiceCommittedOnServer = false;
      _draftCreatedThisSession = false;
    }

    _deferredServerRemovals.clear();

    if (!mounted) return;
    Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (_billKept) {
          if (mounted) Navigator.of(context).pop(true);
          return;
        }
        if (_removingLine || _saving) return;
        await _discardAndClose();
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
              fontSize: 18,
            ),
          ),
          actions: [
            if (!_isPaidEdit)
              IconButton(
                tooltip: 'Scan QR into this bill',
                onPressed: _saving || _removingLine ? null : _openScanner,
                icon: const Icon(Icons.qr_code_scanner, color: sectionAccent),
              ),
          ],
        ),
        body: ResponsiveBody(
          child: ListView(
            padding: SystemSafe.listPadding(context, extraBottom: 110),
            children: [
              Row(
                children: [
                  _StatusChip(
                    label: 'Draft',
                    selected: (widget.editInvoice?.sectionKey ?? 'draft') == 'draft',
                  ),
                  const SizedBox(width: 8),
                  _StatusChip(
                    label: 'Open',
                    selected: widget.editInvoice?.sectionKey == 'open',
                  ),
                  const SizedBox(width: 8),
                  _StatusChip(
                    label: 'Paid',
                    selected: _isPaidEdit,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              const Center(
                child: Text(
                  'CASH/CREDIT TAX INVOICE',
                  style: TextStyle(
                    color: Color(0xFFE53935),
                    fontWeight: FontWeight.w800,
                    fontSize: 17,
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
                        fontSize: 18,
                      ),
                    ),
                  ),
                  Text(
                    _invoiceDateDisplay,
                    style: const TextStyle(color: sectionTextMuted, fontSize: 15),
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
                          onCreate: BillNameStore.rememberResponsible,
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
                          TextStyle(color: sectionTextMuted, fontSize: 14),
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
                        onPickCompany: () => line.fromStock
                            ? _pickRelatedForLine(
                          line,
                          title: 'Company',
                          readField: (s) => s.company,
                          assignField: (v) => line.company = v,
                          pool: _companies,
                          poolKeys: _companyKeys,
                          fallbackOptions: const [],
                        )
                            : _pickMasterNameForLine(
                          line,
                          title: 'Company',
                          readValue: () => line.company,
                          assign: (v) => line.company = v,
                          pool: _companies,
                          poolKeys: _companyKeys,
                        ),
                        onPickPack: () => line.fromStock
                            ? _pickRelatedForLine(
                          line,
                          title: 'Pack',
                          readField: (s) => s.packing,
                          assignField: (v) => line.pack = v,
                          pool: _packs,
                          poolKeys: _packKeys,
                          fallbackOptions: const [],
                        )
                            : _pickMasterNameForLine(
                          line,
                          title: 'Pack',
                          readValue: () => line.pack,
                          assign: (v) => line.pack = v,
                          pool: _packs,
                          poolKeys: _packKeys,
                        ),
                        onPickGroup: () => _pickRelatedForLine(
                          line,
                          title: 'Group',
                          readField: (s) => s.group,
                          assignField: (v) => line.group = v,
                          pool: _groups,
                          poolKeys: _groupKeys,
                          fallbackOptions: line.fromStock
                              ? const []
                              : List<String>.from(_groups),
                        ),
                        onPickBatch: () => _pickRelatedForLine(
                          line,
                          title: 'BATCH',
                          readField: (s) => s.batch,
                          assignField: (v) => line.batch = v,
                          pool: _batches,
                          poolKeys: _batchKeys,
                          fallbackOptions: line.fromStock
                              ? const []
                              : List<String>.from(_batches),
                        ),
                        onPickHsn: () => _pickRelatedForLine(
                          line,
                          title: 'HSN',
                          readField: (s) => s.hsn,
                          assignField: (v) => line.hsn = v ?? '',
                          pool: _hsns,
                          poolKeys: _hsnKeys,
                          fallbackOptions: line.fromStock
                              ? const []
                              : List<String>.from(_hsns),
                        ),
                        onPickRack: () => _pickRelatedForLine(
                          line,
                          title: 'Rack',
                          readField: (s) => s.rack,
                          assignField: (v) => line.rack = v ?? '',
                          pool: _racks,
                          poolKeys: _rackKeys,
                          fallbackOptions: line.fromStock
                              ? const []
                              : List<String>.from(_racks),
                        ),
                        onFromStockChanged: (v) => _setLineFromStock(line, v),
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
                          if (_editingLineIndex == i) {
                            _refreshLocalAvailableWhileEditing(line);
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
                    Align(
                      alignment: Alignment.center,
                      child: TextButton.icon(
                        onPressed: _addLine,
                        style: TextButton.styleFrom(
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                        ),
                        icon: const Icon(
                          Icons.add,
                          color: Color(0xFFE07A2F),
                        ),
                        label: const Text(
                          'Add a line',
                          style: TextStyle(
                            color: Color(0xFFE07A2F),
                            fontWeight: FontWeight.w700,
                          ),
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
                                  if (c.name.toLowerCase() ==
                                      v.toLowerCase()) {
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
                    _ReadRow(
                      'Billed By',
                      _displayBilledBy,
                    ),
                    _ReadRow(
                      'Status',
                      widget.editInvoice?.displayStatus ?? 'Draft',
                    ),
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
                      label: 'Expense',
                      controller: _expenseTextCtrl,
                    ),
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
                    if (_customerOldBalance != null &&
                        _customerOldBalance != 0)
                      _MoneyRow('Old Balance', _customerOldBalance!),
                    if (_customerAdvance != null && _customerAdvance != 0)
                      _MoneyRow('Advance Amount', _customerAdvance!),
                    if (_creditLimitWarningBanner != null) ...[
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF3E0),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: const Color(0xFFE07A2F).withValues(alpha: 0.45),
                          ),
                        ),
                        child: Text(
                          _creditLimitWarningBanner!,
                          style: const TextStyle(
                            color: Color(0xFF8A4B12),
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ],
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
                      foregroundColor: sectionText,
                      side: const BorderSide(color: sectionTextMuted),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed:
                    _saving || _removingLine ? null : _discardAndClose,
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
    required this.onFromStockChanged,
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
  final ValueChanged<bool> onFromStockChanged;
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
  String? _manufError;
  String? _expiryError;

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
    _manufFocus.addListener(() {
      if (!_manufFocus.hasFocus) _commitLineDate(widget.line, manuf: true);
    });
    _expiryFocus.addListener(() {
      if (!_expiryFocus.hasFocus) _commitLineDate(widget.line, manuf: false);
    });
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
    final line = widget.line;
    // Same mutable _BillLine instance is reused across rebuilds, so revision
    // on oldWidget/widget can already match after QR qty bumps. Sync whenever
    // controllers drift, or when the row expands for edit.
    final becameExpanded = !oldWidget.expanded && widget.expanded;
    final drifted = _qtyCtrl.text != line.qty ||
        _mrpCtrl.text != line.mrp ||
        _disCtrl.text != line.discount ||
        _unitPCtrl.text != line.unitP ||
        _taxCtrl.text != line.tax ||
        _manufCtrl.text != (line.manuf ?? '') ||
        _expiryCtrl.text != (line.expiry ?? '');
    if (becameExpanded ||
        drifted ||
        oldWidget.line.revision != widget.line.revision) {
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
    final unitTp = InvoiceCalcHelper.parseNum(line.unitTp) > 0
        ? InvoiceCalcHelper.parseNum(line.unitTp)
        : (disc > 0 ? mrp * (1 - disc / 100.0) : mrp);
    final unitP = InvoiceCalcHelper.parseNum(line.unitP) > 0
        ? InvoiceCalcHelper.parseNum(line.unitP)
        : unitTp;
    final taxAmt = line.taxAmtValue;
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
                  fontSize: 15,
                ),
              ),
            ),
            if (!line.fromStock)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(
                  'No stock',
                  style: TextStyle(
                    color: sectionTextMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
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
          left: _CompactField('Pack', line.pack),
          right: _CompactField('BATCH', line.batch),
        ),
        _CompactLineRow(
          left: _CompactField('MFD', line.manuf),
          right: _CompactField('EXPIRY', line.expiry),
        ),
        _CompactLineRow(
          left: _CompactField('Group', line.group),
          right: _CompactField(
            'Rack',
            line.rack.trim().isEmpty ? null : line.rack,
          ),
        ),
        if (line.fromStock && (line.availableStock ?? '').trim().isNotEmpty)
          _CompactLineRow(
            left: _CompactField('Available Stock', line.availableStock),
            right: const _CompactField.spacer(),
          ),
        _CompactLineRow(
          left: _CompactField('Qty', fmtNum(qty > 0 ? qty : null)),
          right: _CompactField('Mrp', fmtMoney(mrp > 0 ? mrp : null)),
        ),
        _CompactLineRow(
          left: _CompactField('Dis', fmtNum(disc > 0 ? disc : null)),
          right: _CompactField('Unit TP', fmtMoney(unitTp > 0 ? unitTp : null)),
        ),
        _CompactLineRow(
          left: _CompactField('Unit P', fmtMoney(unitP > 0 ? unitP : null)),
          right: _CompactField(
            'Tax Amt',
            taxAmt > 0 ? taxAmt.toStringAsFixed(2) : null,
          ),
        ),
        _CompactLineRow(
          left: _CompactField('Tax', fmtNum(taxPct > 0 ? taxPct : null)),
          right: _CompactField('Hsn', line.hsn.isEmpty ? null : line.hsn),
        ),
        _CompactLineRow(
          left: _CompactField('Total', fmtMoney(total > 0 ? total : null),
              emphasize: true),
          right: const _CompactField.spacer(),
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
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'From stock',
                  style: TextStyle(
                    color: sectionTextMuted,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Switch(
                value: line.fromStock,
                activeThumbColor: const Color(0xFFE07A2F),
                onChanged: line.serverCommitted
                    ? null
                    : widget.onFromStockChanged,
              ),
            ],
          ),
        ),
        _LineDropdownRow(
          label: line.fromStock ? 'Product *' : 'Product * (free text)',
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
          label: 'Pack',
          value: line.pack,
          onTap: () async {
            await widget.onPickPack();
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
          label: 'MANUF',
          controller: _manufCtrl,
          focusNode: _manufFocus,
          textInputAction: TextInputAction.next,
          onChanged: (v) {
            line.manuf = v;
            widget.onChanged();
          },
          onNext: () {
            _commitLineDate(line, manuf: true);
            _moveTo(_expiryFocus);
          },
          errorText: _manufError,
        ),
        _LineTextRow(
          label: 'EXPIRY',
          controller: _expiryCtrl,
          focusNode: _expiryFocus,
          textInputAction: TextInputAction.next,
          onChanged: (v) {
            line.expiry = v;
            widget.onChanged();
          },
          onNext: () {
            _commitLineDate(line, manuf: false);
            _moveTo(_qtyFocus);
          },
          errorText: _expiryError,
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
        if (line.fromStock)
          _LineReadOnlyRow(
            label: 'Available Stock',
            value: line.availableStock,
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
            line.discountAutoFromCategory = false;
            line.discountUserEdited = true;
            widget.onChanged();
          },
          onNext: () => _moveTo(_taxFocus),
        ),
        _LineReadOnlyRow(
          label: 'Unit TP',
          value: line.unitTp.trim().isEmpty ? null : line.unitTp,
        ),
        _LineReadOnlyRow(
          label: 'Unit P',
          value: line.unitP.trim().isEmpty ? null : line.unitP,
        ),
        _LineReadOnlyRow(
          label: 'Tax Amt',
          value: line.taxAmtValue > 0
              ? line.taxAmtValue.toStringAsFixed(2)
              : null,
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
      ],
    );
  }

  void _commitLineDate(_BillLine line, {required bool manuf}) {
    final ctrl = manuf ? _manufCtrl : _expiryCtrl;
    final raw = ctrl.text.trim();
    // Focus-loss with an empty controller must not wipe a QR-filled value.
    if (raw.isEmpty) {
      final existing = manuf ? line.manuf : line.expiry;
      if ((existing ?? '').trim().isNotEmpty) {
        ctrl.text = existing!.trim();
        return;
      }
    }
    final parsed = StockDateParser.tryParse(ctrl.text);
    if (parsed == null) {
      setState(() {
        if (manuf) {
          _manufError = 'Invalid date (e.g. 1222 → 01/12/2022)';
        } else {
          _expiryError = 'Invalid date (e.g. 1222 → 01/12/2022)';
        }
      });
      return;
    }
    setState(() {
      // Keep MM/yyyy when user/API entered month+year only.
      final display = RegExp(r'^\d{1,2}[/\-.]\d{2,4}$').hasMatch(raw) &&
              parsed.isNotEmpty
          ? () {
              final parts = parsed.split('/');
              return parts.length == 3 ? '${parts[1]}/${parts[2]}' : parsed;
            }()
          : parsed;
      ctrl.text = display;
      if (manuf) {
        line.manuf = display.isEmpty ? null : display;
        _manufError = null;
      } else {
        line.expiry = display.isEmpty ? null : display;
        _expiryError = null;
      }
      line.revision++;
    });
    widget.onChanged();
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
  const _CompactField(this.label, this.value, {this.emphasize = true})
      : spacer = false;

  /// Empty half of a row — avoids showing a blank `: —` field.
  const _CompactField.spacer()
      : label = '',
        value = null,
        emphasize = false,
        spacer = true;

  final String label;
  final String? value;
  final bool emphasize;
  final bool spacer;

  @override
  Widget build(BuildContext context) {
    if (spacer || label.trim().isEmpty) {
      return const SizedBox.shrink();
    }
    final text = (value == null || value!.trim().isEmpty) ? '—' : value!;
    return RichText(
      text: TextSpan(
        style: TextStyle(
          color: sectionTextMuted,
          fontSize: 12,
        ),
        children: [
          TextSpan(text: '$label: '),
          TextSpan(
            text: text,
            style: TextStyle(
              color: sectionText,
              fontWeight: FontWeight.w700,
              fontSize: emphasize ? 14 : 13,
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
                        : sectionTextMuted,
                    fontSize: 14,
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
                        : sectionCardBorder,
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        (value == null || value!.isEmpty) ? 'Select' : value!,
                        style: TextStyle(
                          color: (value == null || value!.isEmpty)
                              ? sectionTextMuted
                              : sectionText,
                          fontSize: 15,
                          fontWeight: (value == null || value!.isEmpty)
                              ? FontWeight.w500
                              : FontWeight.w700,
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
                fontSize: 14,
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
                border: Border.all(color: sectionCardBorder),
              ),
              child: Text(
                (value == null || value!.trim().isEmpty) ? '—' : value!,
                style: TextStyle(
                  color: (value == null || value!.trim().isEmpty)
                      ? sectionTextMuted
                      : sectionText,
                  fontSize: 15,
                  fontWeight: (value == null || value!.trim().isEmpty)
                      ? FontWeight.w500
                      : FontWeight.w700,
                ),
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
    this.errorText,
  });

  final String label;
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onNext;
  final TextInputType? keyboardType;
  final TextInputAction textInputAction;
  final bool highlightError;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    final showError = highlightError ||
        (errorText != null && errorText!.isNotEmpty);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 110,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                  decoration: showError
                      ? BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.redAccent),
                  )
                      : null,
                  child: Text(
                    label,
                    style: TextStyle(
                      color: showError ? Colors.redAccent : sectionTextMuted,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
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
                  style: const TextStyle(
                    color: sectionText,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                  onChanged: onChanged,
                  onSubmitted: (_) => onNext(),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: sectionCard,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(
                        color: showError ? Colors.redAccent : sectionCardBorder,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(
                        color: showError
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
          if (errorText != null && errorText!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 110, top: 4),
              child: Text(
                errorText!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
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
              ? sectionAccent
              : Colors.black.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selected) ...[
            const Icon(Icons.check, size: 14, color: sectionAccent),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: const TextStyle(
              color: Colors.black,
              fontWeight: FontWeight.w700,
              fontSize: 14,
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
                fontSize: 15,
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
              fontSize: 14,
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
            style: const TextStyle(
              color: sectionText,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: sectionCard,
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
              fontSize: 14,
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
                              ? sectionTextMuted
                              : sectionText,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
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
    final safeValue =
    value != null && items.contains(value) ? value : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: sectionTextMuted,
              fontSize: 14,
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
                value: safeValue,
                hint: Text(
                  'Optional',
                  style: TextStyle(
                    color: sectionTextMuted,
                  ),
                ),
                isExpanded: true,
                dropdownColor: sectionCard,
                iconEnabledColor: sectionTextMuted,
                style: const TextStyle(
                  color: sectionText,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
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
                fontSize: 14,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: sectionText, fontSize: 14),
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
                fontSize: 14,
              ),
            ),
          ),
          Text(
            InvoiceSummaryModel.formatMoney(value),
            style: TextStyle(
              color: sectionText,
              fontSize: emphasize ? 17 : 14,
              fontWeight: emphasize ? FontWeight.w800 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
