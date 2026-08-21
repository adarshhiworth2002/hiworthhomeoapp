import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/stock_item_model.dart';
import '../../viewModels/login_viewmodel.dart';
import '../services/calendar_date.dart';
import '../services/odoo_rpc_helper.dart';
import '../services/stock_date_parser.dart';
import '../widgets/app_responsive.dart';
import '../widgets/master_name_pick_sheet.dart';
import '../widgets/system_safe.dart';
import '../theme.dart';

/// Full stock record detail with optional edit → Odoo `entry.stock` write.
class StockDetailPage extends StatefulWidget {
  const StockDetailPage({
    super.key,
    required this.item,
    this.isNew = false,
  });

  final StockItemModel item;
  final bool isNew;

  @override
  State<StockDetailPage> createState() => _StockDetailPageState();
}

class _StockDetailPageState extends State<StockDetailPage> {
  late StockItemModel _item;
  late bool _editing;
  bool _saving = false;
  bool _loadingMasters = false;

  late final TextEditingController _medicineCtrl;
  late final TextEditingController _potencyCtrl;
  late final TextEditingController _packingCtrl;
  late final TextEditingController _companyCtrl;
  late final TextEditingController _groupCtrl;
  late final TextEditingController _batchCtrl;
  late final TextEditingController _mfdCtrl;
  late final TextEditingController _expCtrl;
  late final TextEditingController _rackCtrl;
  late final TextEditingController _hsnCtrl;
  late final TextEditingController _itemQtyCtrl;
  late final TextEditingController _stockCtrl;
  late final TextEditingController _mrpCtrl;
  late final TextEditingController _holdQtyCtrl;
  late final TextEditingController _gstCtrl;

  String? _mfdError;
  String? _expError;

  List<String> _medicines = [];
  List<String> _potencies = [];
  List<String> _packings = [];
  List<String> _companies = [];
  List<String> _groups = [];
  List<String> _racks = [];

  @override
  void initState() {
    super.initState();
    _item = widget.item;
    _editing = widget.isNew;
    _medicineCtrl = TextEditingController();
    _potencyCtrl = TextEditingController();
    _packingCtrl = TextEditingController();
    _companyCtrl = TextEditingController();
    _groupCtrl = TextEditingController();
    _batchCtrl = TextEditingController();
    _mfdCtrl = TextEditingController();
    _expCtrl = TextEditingController();
    _rackCtrl = TextEditingController();
    _hsnCtrl = TextEditingController();
    _itemQtyCtrl = TextEditingController();
    _stockCtrl = TextEditingController();
    _mrpCtrl = TextEditingController();
    _holdQtyCtrl = TextEditingController();
    _gstCtrl = TextEditingController();
    _syncControllersFromItem();
    _itemQtyCtrl.addListener(_syncStockFromItemQty);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadMasters();
      if (widget.isNew) _loadNextStockId();
    });
  }

  Future<void> _loadNextStockId() async {
    final sid = await _odooSessionId();
    if (sid == null || !mounted) return;
    final nextId = await OdooRpcHelper.nextStockDisplayId(sid);
    if (!mounted) return;
    setState(() {
      _item = StockItemModel(
        stockDisplayId: nextId,
        stockDate: CalendarDate.ymd(),
      );
    });
  }

  @override
  void dispose() {
    _medicineCtrl.dispose();
    _potencyCtrl.dispose();
    _packingCtrl.dispose();
    _companyCtrl.dispose();
    _groupCtrl.dispose();
    _batchCtrl.dispose();
    _mfdCtrl.dispose();
    _expCtrl.dispose();
    _rackCtrl.dispose();
    _hsnCtrl.dispose();
    _itemQtyCtrl.dispose();
    _stockCtrl.dispose();
    _mrpCtrl.dispose();
    _holdQtyCtrl.dispose();
    _gstCtrl.dispose();
    super.dispose();
  }

  void _syncStockFromItemQty() {
    // Add flow only: Stock mirrors Item Qty. On edit, Stock is independent.
    if (!widget.isNew) return;
    _stockCtrl.text = _itemQtyCtrl.text;
  }

  void _syncControllersFromItem() {
    _medicineCtrl.text = _item.medicine ?? '';
    _potencyCtrl.text = _item.potency ?? '';
    _packingCtrl.text = _item.packing ?? '';
    _companyCtrl.text = _item.company ?? '';
    _groupCtrl.text = _item.group ?? '';
    _batchCtrl.text = _item.batch ?? '';
    _mfdCtrl.text = _item.mfd ?? '';
    _expCtrl.text = _item.exp ?? '';
    _mfdError = null;
    _expError = null;
    _rackCtrl.text = _item.rack ?? '';
    _hsnCtrl.text = _item.hsn ?? '';
    _itemQtyCtrl.text = _formatNum(_item.itemQty);
    _stockCtrl.text = _formatNum(_item.stock);
    _mrpCtrl.text = _formatNum(_item.mrp);
    _holdQtyCtrl.text = _formatNum(_item.holdQty);
    _gstCtrl.text = _formatNum(_item.gst);
  }

  static String _formatNum(double? v) {
    if (v == null) return '';
    return v == v.roundToDouble() ? v.toInt().toString() : v.toString();
  }

  static double? _parseNum(String text) {
    final t = text.trim();
    if (t.isEmpty) return null;
    return double.tryParse(t);
  }

  Future<String?> _odooSessionId() async {
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
    return sid.isEmpty ? null : sid;
  }

  Future<void> _loadMasters() async {
    final sid = await _odooSessionId();
    if (sid == null || !mounted) return;
    setState(() => _loadingMasters = true);
    try {
      final results = await Future.wait([
        OdooRpcHelper.searchMedicineNames(sid),
        OdooRpcHelper.searchPotencyNames(sid),
        OdooRpcHelper.searchPackingNames(sid),
        OdooRpcHelper.searchCompanyNames(sid),
        OdooRpcHelper.searchGroupNames(sid),
        OdooRpcHelper.searchRackNames(sid),
      ]);
      if (!mounted) return;
      setState(() {
        _medicines = results[0];
        _potencies = results[1];
        _packings = results[2];
        _companies = results[3];
        _groups = results[4];
        _racks = results[5];
      });
    } finally {
      if (mounted) setState(() => _loadingMasters = false);
    }
  }

  void _remember(List<String> pool, String value) {
    final t = value.trim();
    if (t.isEmpty) return;
    if (pool.any((e) => e.toLowerCase() == t.toLowerCase())) return;
    pool.insert(0, t);
  }

  Future<void> _pickMaster({
    required String title,
    required List<String> options,
    required TextEditingController controller,
  }) async {
    final picked = await MasterNamePickSheet.show(
      context,
      title: title,
      options: options,
      selected: controller.text,
    );
    if (picked == null || !mounted) return;
    setState(() {
      controller.text = picked;
      _remember(options, picked);
    });
  }

  bool _commitDate(TextEditingController controller, String label) {
    final parsed = StockDateParser.tryParse(controller.text);
    final isMfd = identical(controller, _mfdCtrl);
    if (parsed == null) {
      final msg =
          'Enter a valid $label. Use MMYY (e.g. 0722) or a full date.';
      setState(() {
        if (isMfd) {
          _mfdError = msg;
        } else {
          _expError = msg;
        }
      });
      _toast(msg);
      return false;
    }
    setState(() {
      if (isMfd) {
        _mfdError = null;
      } else {
        _expError = null;
      }
      if (controller.text != parsed) {
        controller.text = parsed;
      }
    });
    return true;
  }

  void _toggleEdit() {
    if (_editing && !widget.isNew) {
      _syncControllersFromItem();
    }
    setState(() => _editing = !_editing);
  }

  Future<void> _save() async {
    if (!_commitDate(_mfdCtrl, 'Mfd date') ||
        !_commitDate(_expCtrl, 'Expiry date')) {
      return;
    }

    final sid = await _odooSessionId();
    if (sid == null) {
      _toast('Session expired. Please log in again.');
      return;
    }

    final medicine = _medicineCtrl.text.trim();
    if (medicine.isEmpty) {
      _toast('Select or create a medicine name.');
      return;
    }

    final mfdApi = StockDateParser.toApiDate(_mfdCtrl.text);
    final expApi = StockDateParser.toApiDate(_expCtrl.text);

    setState(() => _saving = true);
    try {
      StockItemModel? saved;
      final itemQty = _parseNum(_itemQtyCtrl.text);
      // Add: stock mirrors item qty. Edit: use the Stock field value.
      final stockQty =
          widget.isNew ? itemQty : _parseNum(_stockCtrl.text) ?? itemQty;
      if (widget.isNew) {
        saved = await OdooRpcHelper.createEntryStock(
          sid,
          medicine: medicine,
          potency: _potencyCtrl.text,
          packing: _packingCtrl.text,
          company: _companyCtrl.text,
          group: _groupCtrl.text,
          batch: _batchCtrl.text,
          mfd: mfdApi,
          exp: expApi,
          rack: _rackCtrl.text,
          hsn: _hsnCtrl.text,
          itemQty: itemQty,
          stock: stockQty,
          mrp: _parseNum(_mrpCtrl.text),
          gst: _parseNum(_gstCtrl.text),
        );
        if (!mounted) return;
        if (saved == null) {
          _toast('Could not create stock on server.');
          return;
        }
        _toast('Stock created (ID ${saved.stockDisplayId ?? saved.entryStockId}).');
        Navigator.of(context).pop(saved);
        return;
      }

      final entryId = _item.entryStockId;
      if (entryId == null || entryId <= 0) {
        _toast('Cannot edit: stock row id missing on server.');
        return;
      }

      final ok = await OdooRpcHelper.updateEntryStock(
        sid,
        entryStockId: entryId,
        medicine: medicine,
        potency: _potencyCtrl.text,
        packing: _packingCtrl.text,
        company: _companyCtrl.text,
        group: _groupCtrl.text,
        batch: _batchCtrl.text,
        mfd: mfdApi,
        exp: expApi,
        rack: _rackCtrl.text,
        hsn: _hsnCtrl.text,
        itemQty: itemQty,
        stock: stockQty,
        mrp: _parseNum(_mrpCtrl.text),
        holdQty: _parseNum(_holdQtyCtrl.text),
        gst: _parseNum(_gstCtrl.text),
      );
      if (!mounted) return;
      if (!ok) {
        _toast('Could not save changes on server.');
        return;
      }

      saved = StockItemModel(
        stockDisplayId: _item.stockDisplayId,
        entryStockId: _item.entryStockId,
        qrToken: _item.qrToken,
        stockDate: _item.stockDate,
        medicine: medicine,
        potency: _emptyToNull(_potencyCtrl.text),
        packing: _emptyToNull(_packingCtrl.text),
        company: _emptyToNull(_companyCtrl.text),
        group: _emptyToNull(_groupCtrl.text),
        itemQty: itemQty,
        stock: stockQty,
        mrp: _parseNum(_mrpCtrl.text),
        batch: _emptyToNull(_batchCtrl.text),
        mfd: _emptyToNull(_mfdCtrl.text),
        exp: _emptyToNull(_expCtrl.text),
        expSortRaw: _item.expSortRaw,
        mfdSortRaw: _item.mfdSortRaw,
        rack: _emptyToNull(_rackCtrl.text),
        hsn: _emptyToNull(_hsnCtrl.text),
        gst: _parseNum(_gstCtrl.text),
        holdQty: _parseNum(_holdQtyCtrl.text),
        availableStock: stockQty,
        expiryColorState: _item.expiryColorState,
      );
      _toast('Stock updated.');
      Navigator.of(context).pop(saved);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  static String? _emptyToNull(String text) {
    final t = text.trim();
    return t.isEmpty ? null : t;
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: stockTheme(),
      child: Scaffold(
      backgroundColor: stockBg,
      appBar: AppBar(
        iconTheme: const IconThemeData(color: stockText),
        title: Text(
          widget.isNew ? 'New Stock' : 'Stock Details',
          style: const TextStyle(
            color: stockText,
            fontWeight: FontWeight.w500,
            fontSize: 17,
          ),
        ),
        backgroundColor: stockBg,
        elevation: 0,
        actions: [
          if (_editing && !widget.isNew)
            TextButton(
              onPressed: _saving ? null : _toggleEdit,
              child: const Text('Cancel', style: TextStyle(color: stockTextMuted)),
            ),
          IconButton(
            tooltip: _editing ? 'Save' : 'Edit',
            onPressed: _saving
                ? null
                : () {
                    if (_editing) {
                      _save();
                    } else {
                      _toggleEdit();
                    }
                  },
            icon: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFFE07A2F),
                    ),
                  )
                : Icon(
                    _editing ? Icons.check : Icons.edit_outlined,
                    color: _editing
                        ? const Color(0xFFE07A2F)
                        : stockText,
                  ),
          ),
        ],
      ),
      body: ResponsiveBody(
        child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: SystemSafe.listPadding(context),
        children: [
          if (_loadingMasters)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: LinearProgressIndicator(
                color: Color(0xFFE07A2F),
                minHeight: 2,
              ),
            ),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: stockCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: stockCardBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_editing)
                  _DropdownField(
                    label: 'Name',
                    controller: _medicineCtrl,
                    onTap: () => _pickMaster(
                      title: 'Medicine',
                      options: _medicines,
                      controller: _medicineCtrl,
                    ),
                  )
                else
                  Text(
                    _item.medicineLabel,
                    style: const TextStyle(
                      color: stockText,
                      fontWeight: FontWeight.w700,
                      fontSize: 17,
                    ),
                  ),
                const SizedBox(height: 8),
                if (!widget.isNew) ...[
                  _Meta('Stock Date', _item.stockDate ?? '—'),
                  _Meta(
                    'Stock ID',
                    _item.stockDisplayId != null
                        ? '${_item.stockDisplayId}'
                        : '—',
                  ),
                ],
                _dropdownOrMeta(
                  'Potency',
                  _potencyCtrl,
                  _item.potency ?? '—',
                  () => _pickMaster(
                    title: 'Search: Potency',
                    options: _potencies,
                    controller: _potencyCtrl,
                  ),
                ),
                _dropdownOrMeta(
                  'Packing',
                  _packingCtrl,
                  _item.packing ?? '—',
                  () => _pickMaster(
                    title: 'Pack',
                    options: _packings,
                    controller: _packingCtrl,
                  ),
                ),
                _dropdownOrMeta(
                  'Company',
                  _companyCtrl,
                  _item.company ?? '—',
                  () => _pickMaster(
                    title: 'Company',
                    options: _companies,
                    controller: _companyCtrl,
                  ),
                ),
                _dropdownOrMeta(
                  'Group',
                  _groupCtrl,
                  _item.group ?? '—',
                  () => _pickMaster(
                    title: 'Group',
                    options: _groups,
                    controller: _groupCtrl,
                  ),
                ),
                _field('Batch', _batchCtrl, _item.batch ?? '—'),
                if (_editing) ...[
                  _DateField(
                    label: 'Mfd',
                    controller: _mfdCtrl,
                    errorText: _mfdError,
                    onCommit: () => _commitDate(_mfdCtrl, 'Mfd date'),
                  ),
                  _DateField(
                    label: 'Exp',
                    controller: _expCtrl,
                    errorText: _expError,
                    onCommit: () => _commitDate(_expCtrl, 'Expiry date'),
                  ),
                ] else ...[
                  _Meta('Mfd', _item.mfd ?? '—'),
                  _Meta('Exp', _item.exp ?? '—'),
                ],
                _dropdownOrMeta(
                  'Rack',
                  _rackCtrl,
                  _item.rack ?? '—',
                  () => _pickMaster(
                    title: 'Rack',
                    options: _racks,
                    controller: _rackCtrl,
                  ),
                ),
                _field('HSN', _hsnCtrl, _item.hsn ?? '—'),
                const SizedBox(height: 8),
                if (_editing) ...[
                  Row(
                    children: [
                      Expanded(
                        child: _EditField(
                          label: 'Item Qty',
                          controller: _itemQtyCtrl,
                          keyboardType: TextInputType.number,
                          onUnfocus: () {
                            _syncStockFromItemQty();
                            return true;
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _EditField(
                          label: 'Stock',
                          controller: _stockCtrl,
                          keyboardType: TextInputType.number,
                          // Editable when editing an existing row; add keeps mirror.
                          readOnly: widget.isNew,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _EditField(
                          label: 'Mrp',
                          controller: _mrpCtrl,
                          keyboardType: TextInputType.number,
                        ),
                      ),
                      if (!widget.isNew) ...[
                        const SizedBox(width: 8),
                        Expanded(
                          child: _EditField(
                            label: 'Hold Qty',
                            controller: _holdQtyCtrl,
                            keyboardType: TextInputType.number,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  _EditField(
                    label: 'GST(%)',
                    controller: _gstCtrl,
                    keyboardType: TextInputType.number,
                  ),
                ] else ...[
                  Row(
                    children: [
                      _AmountChip('Item Qty', _item.itemQty),
                      const SizedBox(width: 8),
                      _AmountChip('Stock', _item.stock),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      _AmountChip('Mrp', _item.mrp),
                      const SizedBox(width: 8),
                      _AmountChip('Hold Qty', _item.holdQty ?? 0),
                    ],
                  ),
                  if (_item.gst != null) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        _AmountChip('GST(%)', _item.gst),
                        const SizedBox(width: 8),
                        const Expanded(child: SizedBox()),
                      ],
                    ),
                  ],
                ],
              ],
            ),
          ),
        ],
      ),
      ),
    ),
    );
  }

  Widget _dropdownOrMeta(
    String label,
    TextEditingController controller,
    String displayValue,
    VoidCallback onPick,
  ) {
    if (_editing) {
      return _DropdownField(
        label: label,
        controller: controller,
        onTap: onPick,
      );
    }
    return _Meta(label, displayValue);
  }

  Widget _field(
    String label,
    TextEditingController controller,
    String displayValue,
  ) {
    if (_editing) {
      return _EditField(label: label, controller: controller);
    }
    return _Meta(label, displayValue);
  }
}

Future<StockItemModel?> openStockDetail(
  BuildContext context,
  StockItemModel item, {
  bool isNew = false,
}) {
  return Navigator.of(context).push<StockItemModel>(
    PageRouteBuilder(
      opaque: true,
      barrierColor: stockBg,
      pageBuilder: (context, animation, secondaryAnimation) => Theme(
        data: stockTheme(),
        child: ColoredBox(
          color: stockBg,
          child: StockDetailPage(item: item, isNew: isNew),
        ),
      ),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        return FadeTransition(
          opacity: animation,
          child: ColoredBox(color: stockBg, child: child),
        );
      },
    ),
  );
}

class _Meta extends StatelessWidget {
  const _Meta(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: TextStyle(
                color: stockTextMuted,
                fontSize: 13,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: stockText, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}

class _DropdownField extends StatelessWidget {
  const _DropdownField({
    required this.label,
    required this.controller,
    required this.onTap,
  });

  final String label;
  final TextEditingController controller;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = controller.text.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            labelStyle: TextStyle(color: stockTextMuted, fontSize: 14),
            filled: true,
            fillColor: Colors.black.withValues(alpha: 0.22),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: stockCard),
            ),
            suffixIcon: Icon(Icons.arrow_drop_down, color: stockTextMuted),
          ),
          child: Text(
            text.isEmpty ? 'Select or create' : text,
            style: TextStyle(
              color: text.isEmpty ? stockTextMuted : stockText,
              fontSize: 15,
            ),
          ),
        ),
      ),
    );
  }
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.controller,
    required this.onCommit,
    this.errorText,
  });

  final String label;
  final TextEditingController controller;
  final bool Function() onCommit;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    return _EditField(
      label: '$label (MMYY or full date)',
      controller: controller,
      keyboardType: TextInputType.number,
      textInputAction: TextInputAction.next,
      errorText: errorText,
      onUnfocus: onCommit,
    );
  }
}

class _EditField extends StatelessWidget {
  const _EditField({
    required this.label,
    required this.controller,
    this.keyboardType,
    this.textInputAction,
    this.errorText,
    this.onUnfocus,
    this.readOnly = false,
  });

  final String label;
  final TextEditingController controller;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final String? errorText;
  final bool Function()? onUnfocus;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    final hasError = errorText != null && errorText!.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Focus(
        onFocusChange: (hasFocus) {
          if (!hasFocus) onUnfocus?.call();
        },
        child: TextField(
          controller: controller,
          keyboardType: keyboardType,
          textInputAction: textInputAction ?? TextInputAction.next,
          readOnly: readOnly,
          style: TextStyle(
            color: readOnly ? stockTextMuted : stockText,
            fontSize: 15,
          ),
          decoration: InputDecoration(
            labelText: label,
            labelStyle: TextStyle(
              color: hasError ? Colors.redAccent : stockTextMuted,
              fontSize: 14,
            ),
            errorText: errorText,
            errorMaxLines: 2,
            errorStyle: const TextStyle(color: Colors.redAccent, fontSize: 13),
            filled: true,
            fillColor: Colors.black.withValues(alpha: 0.22),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(
                color: hasError ? Colors.redAccent : stockCard,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(
                color: hasError ? Colors.redAccent : const Color(0xFFE07A2F),
              ),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Colors.redAccent),
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Colors.redAccent),
            ),
          ),
        ),
      ),
    );
  }
}

class _AmountChip extends StatelessWidget {
  const _AmountChip(this.label, this.value);

  final String label;
  final double? value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                color: stockTextMuted,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              StockItemModel.money(value),
              style: const TextStyle(
                color: stockText,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
