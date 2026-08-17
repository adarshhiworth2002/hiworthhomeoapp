import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/stock_item_model.dart';
import '../../viewModels/login_viewmodel.dart';
import '../services/odoo_rpc_helper.dart';
import '../widgets/app_responsive.dart';
import '../widgets/system_safe.dart';
import '../theme.dart';

/// Full stock record detail with optional edit → Odoo `entry.stock` write.
class StockDetailPage extends StatefulWidget {
  const StockDetailPage({super.key, required this.item});

  final StockItemModel item;

  @override
  State<StockDetailPage> createState() => _StockDetailPageState();
}

class _StockDetailPageState extends State<StockDetailPage> {
  late StockItemModel _item;
  bool _editing = false;
  bool _saving = false;

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

  @override
  void initState() {
    super.initState();
    _item = widget.item;
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

  void _syncControllersFromItem() {
    _medicineCtrl.text = _item.medicine ?? '';
    _potencyCtrl.text = _item.potency ?? '';
    _packingCtrl.text = _item.packing ?? '';
    _companyCtrl.text = _item.company ?? '';
    _groupCtrl.text = _item.group ?? '';
    _batchCtrl.text = _item.batch ?? '';
    _mfdCtrl.text = _item.mfd ?? '';
    _expCtrl.text = _item.exp ?? '';
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

  void _toggleEdit() {
    if (_editing) {
      _syncControllersFromItem();
    }
    setState(() => _editing = !_editing);
  }

  Future<void> _save() async {
    final entryId = _item.entryStockId;
    if (entryId == null || entryId <= 0) {
      _toast('Cannot edit: stock row id missing on server.');
      return;
    }

    final sid = await _odooSessionId();
    if (sid == null) {
      _toast('Session expired. Please log in again.');
      return;
    }

    setState(() => _saving = true);
    try {
      final ok = await OdooRpcHelper.updateEntryStock(
        sid,
        entryStockId: entryId,
        medicine: _medicineCtrl.text,
        potency: _potencyCtrl.text,
        packing: _packingCtrl.text,
        company: _companyCtrl.text,
        group: _groupCtrl.text,
        batch: _batchCtrl.text,
        mfd: _mfdCtrl.text,
        exp: _expCtrl.text,
        rack: _rackCtrl.text,
        hsn: _hsnCtrl.text,
        itemQty: _parseNum(_itemQtyCtrl.text),
        stock: _parseNum(_stockCtrl.text),
        mrp: _parseNum(_mrpCtrl.text),
        holdQty: _parseNum(_holdQtyCtrl.text),
        gst: _parseNum(_gstCtrl.text),
      );
      if (!mounted) return;
      if (!ok) {
        _toast('Could not save changes on server.');
        return;
      }

      setState(() {
        _item = StockItemModel(
          stockDisplayId: _item.stockDisplayId,
          entryStockId: _item.entryStockId,
          qrToken: _item.qrToken,
          stockDate: _item.stockDate,
          medicine: _medicineCtrl.text.trim().isEmpty
              ? null
              : _medicineCtrl.text.trim(),
          potency: _potencyCtrl.text.trim().isEmpty
              ? null
              : _potencyCtrl.text.trim(),
          packing: _packingCtrl.text.trim().isEmpty
              ? null
              : _packingCtrl.text.trim(),
          company: _companyCtrl.text.trim().isEmpty
              ? null
              : _companyCtrl.text.trim(),
          group:
              _groupCtrl.text.trim().isEmpty ? null : _groupCtrl.text.trim(),
          itemQty: _parseNum(_itemQtyCtrl.text),
          stock: _parseNum(_stockCtrl.text),
          mrp: _parseNum(_mrpCtrl.text),
          batch:
              _batchCtrl.text.trim().isEmpty ? null : _batchCtrl.text.trim(),
          mfd: _mfdCtrl.text.trim().isEmpty ? null : _mfdCtrl.text.trim(),
          exp: _expCtrl.text.trim().isEmpty ? null : _expCtrl.text.trim(),
          expSortRaw: _item.expSortRaw,
          mfdSortRaw: _item.mfdSortRaw,
          rack: _rackCtrl.text.trim().isEmpty ? null : _rackCtrl.text.trim(),
          hsn: _hsnCtrl.text.trim().isEmpty ? null : _hsnCtrl.text.trim(),
          gst: _parseNum(_gstCtrl.text),
          holdQty: _parseNum(_holdQtyCtrl.text),
          availableStock: _parseNum(_stockCtrl.text),
          expiryColorState: _item.expiryColorState,
        );
        _editing = false;
      });
      _toast('Stock updated.');
      Navigator.of(context).pop(_item);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
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
        title: const Text(
          'Stock Details',
          style: TextStyle(
            color: stockText,
            fontWeight: FontWeight.w500,
            fontSize: 15,
          ),
        ),
        backgroundColor: stockBg,
        elevation: 0,
        actions: [
          if (_editing)
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
                  _EditField(label: 'Name', controller: _medicineCtrl)
                else
                  Text(
                    _item.medicineLabel,
                    style: const TextStyle(
                      color: stockText,
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                const SizedBox(height: 8),
                _Meta('Stock Date', _item.stockDate ?? '—'),
                _field('Potency', _potencyCtrl, _item.potency ?? '—'),
                _field('Packing', _packingCtrl, _item.packing ?? '—'),
                _field('Company', _companyCtrl, _item.company ?? '—'),
                _field('Group', _groupCtrl, _item.group ?? '—'),
                _field('Batch', _batchCtrl, _item.batch ?? '—'),
                _field('Mfd', _mfdCtrl, _item.mfd ?? '—'),
                _field('Exp', _expCtrl, _item.exp ?? '—'),
                _field('Rack', _rackCtrl, _item.rack ?? '—'),
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
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _EditField(
                          label: 'Stock',
                          controller: _stockCtrl,
                          keyboardType: TextInputType.number,
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
                      const SizedBox(width: 8),
                      Expanded(
                        child: _EditField(
                          label: 'Hold Qty',
                          controller: _holdQtyCtrl,
                          keyboardType: TextInputType.number,
                        ),
                      ),
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
  StockItemModel item,
) {
  return Navigator.of(context).push<StockItemModel>(
    MaterialPageRoute(builder: (_) => StockDetailPage(item: item)),
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
                fontSize: 11,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: stockText, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _EditField extends StatelessWidget {
  const _EditField({
    required this.label,
    required this.controller,
    this.keyboardType,
  });

  final String label;
  final TextEditingController controller;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        style: const TextStyle(color: stockText, fontSize: 13),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(
            color: stockTextMuted,
            fontSize: 12,
          ),
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
              color: stockCard,
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFFE07A2F)),
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
                fontSize: 10,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              StockItemModel.money(value),
              style: const TextStyle(
                color: stockText,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
