class QrDataHelper {
  /// Extracts the product UID / qr_data token for customer APIs.
  static String? extractCustomerQrUid(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    for (final line in trimmed.split('\n')) {
      final normalized = line.trim();
      if (normalized.toUpperCase().startsWith('UID:')) {
        final uid = normalized.substring(4).trim();
        if (uid.isNotEmpty) return uid;
      }
    }

    if (!trimmed.contains('\n')) {
      return trimmed;
    }

    return null;
  }

  /// Stock from QR text lines like `STOCK:100` or `QTY:100`.
  static double? extractStockQuantity(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    for (final line in trimmed.split('\n')) {
      final normalized = line.trim();
      final upper = normalized.toUpperCase();
      for (final prefix in ['STOCK:', 'QTY:', 'QUANTITY:']) {
        if (upper.startsWith(prefix)) {
          final value = double.tryParse(
            normalized.substring(prefix.length).trim(),
          );
          if (value != null) return value;
        }
      }
    }
    return null;
  }

  /// Product-level barcode used by add_to_invoice (e.g. BK_a2d250b7).
  static String? extractProductBarcode(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.toUpperCase().startsWith('BK_')) return trimmed;

    for (final line in trimmed.split('\n')) {
      final normalized = line.trim();
      final upper = normalized.toUpperCase();
      for (final prefix in ['BK:', 'BARCODE:', 'PRODUCT:']) {
        if (upper.startsWith(prefix)) {
          final value = normalized.substring(prefix.length).trim();
          if (value.isNotEmpty) return value;
        }
      }
    }

    return null;
  }
}
