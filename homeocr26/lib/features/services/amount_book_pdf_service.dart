import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../models/amount_book_model.dart';
import '../../viewModels/amount_book_viewmodel.dart';

class AmountBookPdfService {
  const AmountBookPdfService._();

  static Future<void> shareCustomerLedger({
    required String customerName,
    required List<AmountBookLedgerEntry> entries,
    DateTime? dateFrom,
    DateTime? dateTo,
  }) async {
    final doc = pw.Document();
    final rangeLabel = _rangeLabel(dateFrom, dateTo);

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        build: (context) => [
          pw.Text(
            'Amount Book — $customerName',
            style: pw.TextStyle(
              fontSize: 18,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
          if (rangeLabel.isNotEmpty) ...[
            pw.SizedBox(height: 4),
            pw.Text(rangeLabel, style: const pw.TextStyle(fontSize: 10)),
          ],
          pw.SizedBox(height: 16),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.end,
            children: [
              pw.Text(
                'YOU GAVE',
                style: pw.TextStyle(
                  fontSize: 9,
                  color: PdfColors.red800,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(width: 24),
              pw.Text(
                'YOU GOT',
                style: pw.TextStyle(
                  fontSize: 9,
                  color: PdfColors.green800,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ],
          ),
          pw.SizedBox(height: 8),
          pw.Divider(),
          ..._buildEntryWidgets(entries),
        ],
      ),
    );

    await Printing.sharePdf(
      bytes: await doc.save(),
      filename: _safeFilename(customerName),
    );
  }

  static List<pw.Widget> _buildEntryWidgets(List<AmountBookLedgerEntry> entries) {
    if (entries.isEmpty) {
      return [
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 12),
          child: pw.Text('No entries in selected range.'),
        ),
      ];
    }

    final widgets = <pw.Widget>[];
    String? lastDayKey;

    for (final entry in entries) {
      final dayKey = _dayKey(entry.sortDate);
      if (dayKey != lastDayKey) {
        lastDayKey = dayKey;
        widgets.add(
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 10, bottom: 4),
            child: pw.Text(
              _formatDayHeader(entry.sortDate),
              style: pw.TextStyle(
                fontSize: 10,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.grey700,
              ),
            ),
          ),
        );
      }

      widgets.add(
        pw.Container(
          margin: const pw.EdgeInsets.only(bottom: 6),
          padding: const pw.EdgeInsets.all(8),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: PdfColors.grey300),
            borderRadius: pw.BorderRadius.circular(4),
          ),
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Expanded(
                flex: 3,
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      entry.displayNumber,
                      style: pw.TextStyle(
                        fontSize: 11,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.SizedBox(height: 2),
                    pw.Text(
                      'Bal. ₹ ${AmountBookViewModel.formatAmountPlain(entry.balance)}',
                      style: const pw.TextStyle(
                        fontSize: 9,
                        color: PdfColors.red800,
                      ),
                    ),
                  ],
                ),
              ),
              pw.Expanded(
                flex: 2,
                child: pw.Align(
                  alignment: pw.Alignment.centerRight,
                  child: pw.Text(
                    entry.isYouGave
                        ? AmountBookViewModel.formatAmountPlain(
                            entry.youGaveAmount,
                          )
                        : '',
                    style: pw.TextStyle(
                      fontSize: 11,
                      color: PdfColors.red800,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ),
              ),
              pw.SizedBox(width: 16),
              pw.Expanded(
                flex: 2,
                child: pw.Align(
                  alignment: pw.Alignment.centerRight,
                  child: pw.Text(
                    !entry.isYouGave
                        ? AmountBookViewModel.formatAmountPlain(
                            entry.youGotAmount,
                          )
                        : '',
                    style: pw.TextStyle(
                      fontSize: 11,
                      color: PdfColors.green800,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return widgets;
  }

  static String _rangeLabel(DateTime? from, DateTime? to) {
    if (from == null && to == null) return '';
    final f = from != null ? _formatDayHeader(from) : '…';
    final t = to != null ? _formatDayHeader(to) : '…';
    return 'Period: $f — $t';
  }

  static String _dayKey(DateTime? date) {
    if (date == null) return 'unknown';
    return '${date.year}-${date.month}-${date.day}';
  }

  static String _formatDayHeader(DateTime? date) {
    if (date == null) return '—';
    final months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final d = date.day.toString().padLeft(2, '0');
    final m = months[date.month - 1];
    final y = (date.year % 100).toString().padLeft(2, '0');
    return '$d $m $y';
  }

  static String _safeFilename(String customerName) {
    final safe = customerName
        .replaceAll(RegExp(r'[^\w\s-]'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), '_');
    return 'amount_book_${safe.isEmpty ? 'customer' : safe}.pdf';
  }
}
