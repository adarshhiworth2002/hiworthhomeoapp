class CaptureResponse {
  final String jsonrpc;
  final dynamic id;
  final Result result;

  CaptureResponse({
    required this.jsonrpc,
    this.id,
    required this.result,
  });

  factory CaptureResponse.fromJson(Map<String, dynamic> json) {
    return CaptureResponse(
      jsonrpc: json['jsonrpc'] ?? '',
      id: json['id'],
      result: Result.fromJson(json['result'] ?? {}),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'jsonrpc': jsonrpc,
      'id': id,
      'result': result.toJson(),
    };
  }
}
class Result {
  final String status;
  final List<ProductData> data;

  Result({
    required this.status,
    required this.data,
  });

  factory Result.fromJson(Map<String, dynamic> json) {
    return Result(
      status: json['status'] ?? '',
      data: (json['data'] as List? ?? [])
          .map((e) => ProductData.fromJson(e))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'status': status,
      'data': data.map((e) => e.toJson()).toList(),
    };
  }
}
class ProductData {
  final String uid;
  final double stockQty;
  final String hsn;
  final String company;
  final double tax;
  final String expiry;
  final String packing;
  final String potency;
  final String group;
  final int productId;
  final double mrp;
  final String batch;
  final String productName;
  final String rack;

  ProductData({
    required this.uid,
    required this.stockQty,
    required this.hsn,
    required this.company,
    required this.tax,
    required this.expiry,
    required this.packing,
    required this.potency,
    required this.group,
    required this.productId,
    required this.mrp,
    required this.batch,
    required this.productName,
    required this.rack,
  });

  factory ProductData.fromJson(Map<String, dynamic> json) {
    return ProductData(
      uid: json['uid'] ?? '',
      stockQty: (json['stock_qty'] ?? 0).toDouble(),
      hsn: json['hsn'] ?? '',
      company: json['company'] ?? '',
      tax: (json['tax'] ?? 0).toDouble(),
      expiry: json['expiry'] ?? '',
      packing: json['packing'] ?? '',
      potency: json['potency'] ?? '',
      group: json['group'] ?? '',
      productId: json['product_id'] ?? 0,
      mrp: (json['mrp'] ?? 0).toDouble(),
      batch: json['batch'] ?? '',
      productName: json['product_name'] ?? '',
      rack: json['rack'] ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'uid': uid,
      'stock_qty': stockQty,
      'hsn': hsn,
      'company': company,
      'tax': tax,
      'expiry': expiry,
      'packing': packing,
      'potency': potency,
      'group': group,
      'product_id': productId,
      'mrp': mrp,
      'batch': batch,
      'product_name': productName,
      'rack': rack,
    };
  }
}