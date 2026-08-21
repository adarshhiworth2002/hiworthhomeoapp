/// Bill totals matching Cash/Credit Tax Invoice (website) behaviour.
///
/// Line: Qty × Mrp (gross), then line Dis (%). Unit P is display-only.
/// Bill discount: Percentage of line subtotal, or fixed Amount.
/// GST MINUS: amounts are tax-inclusive (tax extracted).
/// GST PLUS / IGST: tax added on exclusive base.
/// No GST: no tax.
class InvoiceCalcHelper {
  const InvoiceCalcHelper._();

  static InvoiceCalcResult compute({
    required List<InvoiceCalcLine> lines,
    required String? discountType,
    required double discountRate,
    required String? gstType,
    required double expenseAmt,
  }) {
    var lineDiscTotal = 0.0;
    var grossSubtotal = 0.0;
    final nets = <({double net, double taxPct})>[];

    for (final line in lines) {
      final qty = line.qty;
      if (qty <= 0 || line.mrp <= 0) continue;

      final gross = qty * line.mrp;
      final lineDisc =
          line.discountPercent > 0 ? gross * line.discountPercent / 100.0 : 0.0;
      final net = (gross - lineDisc).clamp(0.0, double.infinity);
      grossSubtotal += gross;
      lineDiscTotal += lineDisc;
      nets.add((net: net, taxPct: line.taxPercent.clamp(0.0, 100.0)));
    }

    final linesSubtotal = nets.fold<double>(0, (s, e) => s + e.net);
    final type = (discountType ?? 'Percentage').toLowerCase();
    var billDisc = 0.0;
    if (discountRate > 0 && linesSubtotal > 0) {
      if (type.contains('amount') ||
          type.contains('rupee') ||
          type == 'fixed') {
        billDisc = discountRate;
      } else {
        billDisc = linesSubtotal * discountRate / 100.0;
      }
      if (billDisc > linesSubtotal) billDisc = linesSubtotal;
    }

    final discountTotal = lineDiscTotal + billDisc;
    final factor =
        linesSubtotal > 0 ? (linesSubtotal - billDisc) / linesSubtotal : 0.0;

    final gst = (gstType ?? 'GST MINUS').toUpperCase();
    var untaxed = 0.0;
    var taxAmount = 0.0;

    for (final e in nets) {
      final adj = e.net * factor;
      if (gst.contains('MINUS')) {
        // Tax inclusive
        final tax =
            e.taxPct > 0 ? adj * e.taxPct / (100.0 + e.taxPct) : 0.0;
        taxAmount += tax;
        untaxed += adj - tax;
      } else if (gst.contains('NO GST') || gst == 'NONE') {
        untaxed += adj;
      } else {
        // GST PLUS / IGST — tax exclusive
        final tax = adj * e.taxPct / 100.0;
        untaxed += adj;
        taxAmount += tax;
      }
    }

    final expense = expenseAmt < 0 ? 0.0 : expenseAmt;
    final total = untaxed + taxAmount + expense;

    return InvoiceCalcResult(
      // Website: Qty × Mrp before line / bill discounts.
      subtotal: _r2(grossSubtotal),
      discountTotal: _r2(discountTotal),
      tax: _r2(taxAmount),
      taxAmount: _r2(taxAmount),
      expenseAmt: _r2(expense),
      total: _r2(total),
      balance: _r2(total),
      untaxed: _r2(untaxed),
    );
  }

  static double parseNum(String? raw) {
    if (raw == null) return 0;
    final t = raw.trim().replaceAll(',', '');
    if (t.isEmpty) return 0;
    return double.tryParse(t) ?? 0;
  }

  /// Customer / packing / quotation lines only allow GST 5%, 12%, or 18%.
  /// Stock/QR can return invalid rates (e.g. 100 from supplier); snap to nearest.
  static const List<double> customerTaxPercents = [5, 12, 18];

  static bool isAllowedCustomerTax(double? tax) {
    if (tax == null) return false;
    for (final allowed in customerTaxPercents) {
      if ((tax - allowed).abs() < 0.01) return true;
    }
    return false;
  }

  /// Returns 5, 12, or 18. Defaults to 12 when [raw] is null/invalid.
  static double normalizeCustomerTaxPercent(double? raw) {
    if (isAllowedCustomerTax(raw)) return raw!;
    // Supplier / bad master data often stores 100 — not a real GST slab.
    if (raw == null || raw <= 0 || raw > 18) return 12;
    var best = customerTaxPercents.first;
    var bestDist = (raw - best).abs();
    for (final allowed in customerTaxPercents.skip(1)) {
      final d = (raw - allowed).abs();
      if (d < bestDist) {
        best = allowed;
        bestDist = d;
      }
    }
    return best;
  }

  static double _r2(double v) => (v * 100).roundToDouble() / 100.0;
}

class InvoiceCalcLine {
  const InvoiceCalcLine({
    required this.qty,
    required this.mrp,
    required this.discountPercent,
    required this.unitP,
    required this.taxPercent,
  });

  final double qty;
  final double mrp;
  final double discountPercent;
  final double unitP;
  final double taxPercent;
}

class InvoiceCalcResult {
  const InvoiceCalcResult({
    required this.subtotal,
    required this.discountTotal,
    required this.tax,
    required this.taxAmount,
    required this.expenseAmt,
    required this.total,
    required this.balance,
    required this.untaxed,
  });

  final double subtotal;
  final double discountTotal;
  final double tax;
  final double taxAmount;
  final double expenseAmt;
  final double total;
  final double balance;
  final double untaxed;

  static const zero = InvoiceCalcResult(
    subtotal: 0,
    discountTotal: 0,
    tax: 0,
    taxAmount: 0,
    expenseAmt: 0,
    total: 0,
    balance: 0,
    untaxed: 0,
  );
}
