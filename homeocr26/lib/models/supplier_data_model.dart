class SupplierDataModel {
  final String code;
  final String name;
  final String quantity;
  final String batchNo;
  final String mrp;
  final String rate;

  SupplierDataModel({
    required this.code,
    required this.name,
    required this.quantity,
    required this.batchNo,
    required this.mrp,
    required this.rate,
  });

  factory SupplierDataModel.fromQr(String line) {
    final normalized = line.trim();
    final payload = normalized.toUpperCase().startsWith('ITEM:')
        ? normalized.substring(5)
        : normalized;
    final data = payload.split('|');

    String at(int index) =>
        index < data.length ? data[index].trim() : '';

    return SupplierDataModel(
      code: at(0),
      name: at(1),
      quantity: at(2),
      batchNo: at(3),
      mrp: at(4),
      rate: at(5),
    );
  }
}