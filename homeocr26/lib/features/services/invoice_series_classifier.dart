import '../../models/invoice_summary_model.dart';
import '../../models/net_amount_model.dart';
import 'invoice_b2b_index.dart';
import 'invoice_gst_kind.dart';

export 'invoice_gst_kind.dart' show InvoiceGstKind;

/// B2B / B2C for the Customer Type filter (no extra list column).
///
/// B2B comes from the website/backend checkbox on the customer invoice.
/// B2C is every other customer bill.
class InvoiceSeriesClassifier {
  InvoiceSeriesClassifier._();

  static InvoiceGstKind ofInvoice(InvoiceSummaryModel invoice) {
    return kindOf(
      moveId: invoice.id,
      b2bFlag: invoice.b2bFlag,
    );
  }

  static InvoiceGstKind ofRow(NetAmountRow row) {
    return kindOf(
      moveId: row.id,
      b2bFlag: row.b2bFlag,
    );
  }

  static InvoiceGstKind kindOf({
    int? moveId,
    bool? b2bFlag,
  }) {
    if (b2bFlag == true || InvoiceB2bIndex.isB2bMove(moveId)) {
      return InvoiceGstKind.b2b;
    }
    if (InvoiceB2bIndex.isReady) return InvoiceGstKind.b2c;
    if (b2bFlag == false) return InvoiceGstKind.b2c;
    return InvoiceGstKind.unknown;
  }

  static bool isB2bInvoice(InvoiceSummaryModel invoice) =>
      ofInvoice(invoice) == InvoiceGstKind.b2b;

  static bool isB2cInvoice(InvoiceSummaryModel invoice) =>
      ofInvoice(invoice) == InvoiceGstKind.b2c;

  static bool isB2bRow(NetAmountRow row) => ofRow(row) == InvoiceGstKind.b2b;

  static bool isB2cRow(NetAmountRow row) => ofRow(row) == InvoiceGstKind.b2c;
}
