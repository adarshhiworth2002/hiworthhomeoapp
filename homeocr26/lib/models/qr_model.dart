class QrResponseModel {
  String? jsonrpc;
  dynamic id;
  QrResult? result;

  QrResponseModel({this.jsonrpc, this.id, this.result});

  factory QrResponseModel.fromJson(Map<String, dynamic> json) {
    return QrResponseModel(
      jsonrpc: json['jsonrpc'],
      id: json['id'],
      result: json['result'] != null ? QrResult.fromJson(json['result']) : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'jsonrpc': jsonrpc,
      'id': id,
      'result': result?.toJson(),
    };
  }
}

class QrResult {
  String? status;
  QrData? data;

  QrResult({this.status, this.data});

  factory QrResult.fromJson(Map<String, dynamic> json) {
    return QrResult(
      status: json['status'],
      data: json['data'] != null ? QrData.fromJson(json['data']) : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'status': status,
      'data': data?.toJson(),
    };
  }
}

class QrData {
  String? uid;
  String? lineUid;
  /// Stock Quantity shown in UI = Odoo sellable stock
  /// (`available_stock` / `stock_qty` from get_qr_details).
  double? stockQty;
  /// True warehouse free qty from Odoo (`stock_qty`). Often 0.
  double? warehouseStockQty;
  double? entryStockQty;
  double? availableStock;
  double? quantity;
  String? invoiceNo;
  String? documentType;
  String? hsn;
  String? company;
  double? tax;
  String? expiry;
  String? packing;
  String? potency;
  String? group;
  int? productId;
  /// Odoo `entry.stock` row id (for restock / RPC when display id differs).
  int? stockEntryId;
  double? mrp;
  String? batch;
  String? productName;
  String? rack;
  String? productBarcode;
  /// Manufacture date from get_qr_details (`mfd` / `mfd_date`), e.g. 12/2022.
  String? mfd;
  /// Unit price (`u_price` / `unit_p`).
  double? unitPrice;
  /// Line discount percent (`discount_percent`).
  double? discountPercent;

  QrData({
    this.uid,
    this.lineUid,
    this.stockQty,
    this.warehouseStockQty,
    this.entryStockQty,
    this.availableStock,
    this.quantity,
    this.invoiceNo,
    this.documentType,
    this.hsn,
    this.company,
    this.tax,
    this.expiry,
    this.packing,
    this.potency,
    this.group,
    this.productId,
    this.stockEntryId,
    this.mrp,
    this.batch,
    this.productName,
    this.rack,
    this.productBarcode,
    this.mfd,
    this.unitPrice,
    this.discountPercent,
  });

  factory QrData.fromJson(Map<String, dynamic> json) {
    final quantity = (json['quantity'] as num?)?.toDouble();
    // Warehouse / sellable stock used by add_to_invoice (`available_stock`).
    final available = (json['available_stock'] as num?)?.toDouble() ??
        (json['available_qty'] as num?)?.toDouble() ??
        (json['free_qty'] as num?)?.toDouble();
    final warehouse = (json['stock_qty'] as num?)?.toDouble();
    final entry = (json['entry_stock_qty'] as num?)?.toDouble();
    final batchQty = (json['batch_stock_qty'] as num?)?.toDouble();
    // Stock Quantity UI = same value Odoo checks on add (available/stock_qty).
    final displayStock = available ?? warehouse ?? entry ?? batchQty ?? 0;

    final uPrice = (json['u_price'] as num?)?.toDouble();
    final unitP = (json['unit_p'] as num?)?.toDouble();
    final unitTp = (json['unit_tp'] as num?)?.toDouble();
    // Website Unit P prefers u_price, then unit_p / unit_tp when > 0.
    final resolvedUnit = (uPrice != null && uPrice > 0)
        ? uPrice
        : ((unitP != null && unitP > 0)
            ? unitP
            : ((unitTp != null && unitTp > 0) ? unitTp : uPrice ?? unitP));

    return QrData(
      uid: json['uid'],
      lineUid: _resolveLineUid(json),
      productBarcode: _firstNonEmptyString(json, const [
        'qr_data_product',
        'product_barcode',
        'barcode',
        'default_code',
        'product_code',
        'internal_reference',
        'qr_product_code',
      ]),
      stockQty: displayStock,
      warehouseStockQty: warehouse,
      entryStockQty: entry,
      availableStock: available ?? warehouse,
      quantity: quantity,
      invoiceNo: json['invoice_no'],
      documentType: json['document_type'],
      hsn: json['hsn'],
      company: json['company'],
      tax: (json['tax_percent'] as num?)?.toDouble() ??
          (json['tax'] as num?)?.toDouble(),
      expiry: json['expiry'],
      packing: json['packing'],
      potency: json['potency'],
      group: json['group'],
      productId: json['product_id'] is int
          ? json['product_id'] as int
          : int.tryParse(json['product_id']?.toString() ?? ''),
      stockEntryId: json['stock_entry_id'] is int
          ? json['stock_entry_id'] as int
          : int.tryParse(json['stock_entry_id']?.toString() ?? ''),
      mrp: (json['mrp'] as num?)?.toDouble(),
      batch: json['batch'],
      productName: json['product_name'],
      rack: json['rack'],
      mfd: _firstNonEmptyString(json, const [
        'mfd',
        'mfd_date',
        'manufacturing_date',
        'manuf',
      ]),
      unitPrice: resolvedUnit,
      discountPercent: (json['discount_percent'] as num?)?.toDouble() ??
          (json['discount'] as num?)?.toDouble(),
    );
  }

  static String? _firstNonEmptyString(
    Map<String, dynamic> json,
    List<String> keys,
  ) {
    for (final key in keys) {
      final value = json[key];
      if (value == null) continue;
      final trimmed = value.toString().trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return null;
  }

  static String? _resolveLineUid(Map<String, dynamic> json) {
    final batchUid = json['uid']?.toString().trim();

    for (final key in ['line_uid', 'entry_uid', 'stock_line_uid']) {
      final value = json[key];
      if (value != null) {
        final trimmed = value.toString().trim();
        if (trimmed.isNotEmpty && trimmed != batchUid) {
          return trimmed;
        }
      }
    }

    final invoiceList = json['invoice_list'];
    if (batchUid != null && invoiceList is List) {
      for (final item in invoiceList) {
        if (item is! Map) continue;
        final itemUid = item['uid'] ?? item['qr_data'];
        if (itemUid?.toString() == batchUid) {
          final lineUid = item['line_uid']?.toString().trim();
          if (lineUid != null && lineUid.isNotEmpty && lineUid != batchUid) {
            return lineUid;
          }
        }
      }
    }

    return null;
  }

  Map<String, dynamic> toJson() {
    return {
      'uid': uid,
      'line_uid': lineUid,
      'stock_qty': stockQty,
      'warehouse_stock_qty': warehouseStockQty,
      'entry_stock_qty': entryStockQty,
      'available_stock': availableStock,
      'quantity': quantity,
      'invoice_no': invoiceNo,
      'document_type': documentType,
      'hsn': hsn,
      'company': company,
      'tax': tax,
      'expiry': expiry,
      'packing': packing,
      'potency': potency,
      'group': group,
      'product_id': productId,
      'stock_entry_id': stockEntryId,
      'mrp': mrp,
      'batch': batch,
      'product_name': productName,
      'rack': rack,
      'product_barcode': productBarcode,
      'mfd': mfd,
      'u_price': unitPrice,
      'discount_percent': discountPercent,
    };
  }
}