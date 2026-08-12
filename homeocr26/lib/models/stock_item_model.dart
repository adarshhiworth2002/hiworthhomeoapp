class StockItemModel {
  const StockItemModel({
    this.stockDisplayId,
    this.entryStockId,
    this.qrToken,
    this.stockDate,
    this.medicine,
    this.potency,
    this.packing,
    this.company,
    this.group,
    this.itemQty,
    this.stock,
    this.mrp,
    this.batch,
    this.mfd,
    this.exp,
    this.expSortRaw,
    this.mfdSortRaw,
    this.rack,
    this.hsn,
    this.gst,
    this.holdQty,
    this.availableStock,
    this.expiryColorState,
  });

  /// Pharmacy display id (`stock_display_id`) — use for search/UI, not Odoo row id.
  final int? stockDisplayId;

  /// Odoo `entry.stock` row id when the API returns it separately.
  final int? entryStockId;

  /// Barcode / uid token for `add_to_invoice` (`qr_data`).
  final String? qrToken;

  /// Back-compat alias for [stockDisplayId].
  int? get stockId => stockDisplayId;
  final String? stockDate;
  final String? medicine;
  final String? potency;
  final String? packing;
  final String? company;
  final String? group;
  final double? itemQty;
  final double? stock;
  final double? mrp;
  final String? batch;
  final String? mfd;
  final String? exp;
  final String? expSortRaw;
  final String? mfdSortRaw;
  final String? rack;
  final String? hsn;
  final double? gst;
  final double? holdQty;
  final double? availableStock;
  final String? expiryColorState;

  factory StockItemModel.fromJson(Map<String, dynamic> json) {
    final displayId = _asInt(json['stock_display_id'] ?? json['display_id']);
    final rowId = _asInt(json['id'] ?? json['stock_entry_id']);
    final legacyStockId = _asInt(json['stock_id']);

    // `stock_display_id` is the pharmacy display number; `id` is the Odoo row.
    // Never treat Odoo row id as display id when a separate display id exists.
    final resolvedDisplayId = displayId ?? legacyStockId;
    final resolvedEntryId = rowId;

    return StockItemModel(
      stockDisplayId: resolvedDisplayId,
      entryStockId: resolvedEntryId,
      qrToken: _firstDisplay(json, const [
        'uid',
        'qr_data',
        'product_barcode',
        'barcode',
        'default_code',
      ]),
      stockDate: _display(json['stock_date'] ?? json['date']),
      medicine: _display(
        json['medicine_name'] ??
            json['medicine'] ??
            json['product_name'] ??
            json['name'],
      ),
      potency: _firstDisplay(json, const [
        'potency_name',
        'potency_id_name',
        'potency',
        'power',
        'drug_potency',
      ]),
      packing: _firstDisplay(json, const [
        'packing_name',
        'pack_id_name',
        'packing',
        'pack',
        'pack_size',
      ]),
      company: _firstDisplay(json, const [
        'company_name',
        'pharmacy_company_id_name',
        'company',
        'medicine_company',
        'brand',
        'comp',
      ]),
      group: _firstDisplay(json, const [
        'group_name',
        'pharmacy_group_id_name',
        'medicine_group',
        'product_group',
        'group_id_name',
        'group',
      ]),
      itemQty: _asDouble(json['item_qty'] ?? json['qty']),
      stock: _asDouble(
        json['stock'] ?? json['stock_qty'] ?? json['available_stock'],
      ),
      mrp: _asDouble(json['mrp']),
      batch: _display(json['batch']),
      mfd: _display(json['mfd_date'] ?? json['mfd'] ?? json['manufacturing_date']),
      exp: _display(
        json['exp_date_display'] ??
            json['exp_date'] ??
            json['exp'] ??
            json['expiry'],
      ),
      // Prefer ISO exp_date for reliable sorting when display format varies.
      expSortRaw: _display(json['exp_date'] ?? json['exp_date_display']),
      mfdSortRaw: _display(json['mfd_date'] ?? json['mfd']),
      rack: _firstDisplay(json, const [
        'rack_name',
        'rack_id_name',
        'rack',
        'rack_no',
      ]),
      hsn: _firstDisplay(json, const [
        'hsn_code',
        'hsn',
      ]),
      gst: _asDouble(json['gst'] ?? json['gst_percent']),
      holdQty: _asDouble(json['hold_qty'] ?? json['hold_quantity']),
      availableStock: _asDouble(json['available_stock']),
      expiryColorState: _display(json['expiry_color_state']),
    );
  }

  static List<StockItemModel> parseList(Map<String, dynamic> response) {
    final result = response['result'];
    if (result is! Map) return [];

    final candidates = <dynamic>[
      result['stock_list'],
      result['stocks'],
      result['data'],
      result['records'],
      result['items'],
      result['results'],
    ];

    for (final candidate in candidates) {
      if (candidate is List) {
        return candidate
            .whereType<Map>()
            .map((item) => StockItemModel.fromJson(
                  Map<String, dynamic>.from(item),
                ))
            .toList();
      }
      if (candidate is Map) {
        final nested = candidate['stock_list'] ??
            candidate['stocks'] ??
            candidate['records'] ??
            candidate['items'];
        if (nested is List) {
          return nested
              .whereType<Map>()
              .map((item) => StockItemModel.fromJson(
                    Map<String, dynamic>.from(item),
                  ))
              .toList();
        }
      }
    }

    return [];
  }

  String get medicineLabel {
    if (medicine != null && medicine!.trim().isNotEmpty) return medicine!;
    return 'Unknown';
  }

  DateTime? get mfdDate => _parseDate(mfdSortRaw ?? mfd);
  DateTime? get expDate => _parseDate(expSortRaw ?? exp);

  static String money(double? value) {
    if (value == null) return '0.00';
    return value.toStringAsFixed(2);
  }

  static String qty(double? value) {
    if (value == null) return '0.00';
    return value.toStringAsFixed(2);
  }

  static String idLabel(int? value) {
    if (value == null) return '—';
    return value.toString().replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (m) => '${m[1]},',
    );
  }

  static DateTime? _parseDate(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final text = raw.trim();
    final iso = DateTime.tryParse(text);
    if (iso != null) return iso;

    // Handles values like 1/10/2030 or 01/10/2030
    final parts = text.split(RegExp(r'[/-]'));
    if (parts.length == 3) {
      final a = int.tryParse(parts[0]);
      final b = int.tryParse(parts[1]);
      final c = int.tryParse(parts[2]);
      if (a != null && b != null && c != null) {
        if (parts[0].length == 4) {
          return DateTime(a, b, c);
        }
        // Prefer D/M/YYYY when day > 12, else treat as M/D/YYYY (Odoo display).
        if (a > 12) return DateTime(c, b, a);
        return DateTime(c, a, b);
      }
    }
    return null;
  }

  static String? _firstDisplay(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final value = _display(json[key]);
      if (value != null && value.isNotEmpty) return value;
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

  static int? _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString().replaceAll(',', '') ?? '');
  }

  static double? _asDouble(dynamic value) {
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString().replaceAll(',', '') ?? '');
  }
}
