import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';

import '../../models/invoice_summary_model.dart';
import '../../viewModels/login_viewmodel.dart';
import 'WebApi/web_api_impl.dart';
import 'api_request_helper.dart';
import 'appConfig.dart';
import 'auth_session_store.dart';
import 'endPoints.dart';
import 'session_helper.dart';

/// Shares a customer invoice / payment receipt PDF.
///
/// Prefers the server print PDF when available; otherwise builds a local
/// receipt so Share still works when Laravel print routes fail.
class CustomerInvoicePdfService {
  const CustomerInvoicePdfService._();

  static Future<void> shareInvoice(
    BuildContext context, {
    required InvoiceSummaryModel invoice,
    double? payAmount,
    String? paymentName,
  }) async {
    final id = invoice.id;
    final login = Provider.of<LoginViewmodel>(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      const SnackBar(content: Text('Preparing receipt PDF…')),
    );

    try {
      Uint8List? bytes;

      final flutterSid = login.sessionId;
      if (id != null &&
          id > 0 &&
          flutterSid != null &&
          flutterSid.isNotEmpty) {
        // Laravel route: GET /api/pharmacy_mgmnt/auto_print_invoice/{moveId}
        bytes = await _fromAutoPrintApi(
          sessionId: flutterSid,
          invoiceId: id,
        );
        bytes ??= await _fromFlutterApi(
          sessionId: flutterSid,
          invoiceId: id,
          invoiceNumber: invoice.displayNumber,
        );
      }

      // Server print is often HTML/login/500 — always keep a local receipt.
      bytes ??= await _buildLocalReceiptPdf(
        invoice: invoice,
        payAmount: payAmount,
        paymentName: paymentName,
      );

      if (!context.mounted) return;
      messenger.hideCurrentSnackBar();

      if (bytes.isEmpty) {
        _toast(context, 'Could not generate receipt PDF.');
        return;
      }

      final name = invoice.displayNumber
          .replaceAll(RegExp(r'[^\w\-./]+'), '_')
          .replaceAll('/', '-');
      final fileId = id != null && id > 0
          ? id.toString()
          : (name.isEmpty ? 'receipt' : name);
      await Printing.sharePdf(
        bytes: bytes,
        filename: 'invoice_${name.isEmpty ? fileId : name}.pdf',
      );
    } catch (e) {
      if (kDebugMode) debugPrint('CustomerInvoicePdfService.shareInvoice: $e');
      if (!context.mounted) return;
      messenger.hideCurrentSnackBar();
      _toast(context, 'Share PDF failed.');
    }
  }

  static Future<Uint8List?> _fromAutoPrintApi({
    required String sessionId,
    required int invoiceId,
  }) async {
    try {
      final url =
          '${AppConfig.baseAppUrl}${EndPoint.customerInvoiceAutoPrint.path}/$invoiceId';
      final response = await http
          .get(
            Uri.parse(url),
            headers: SessionHelper.jsonHeaders(
              sessionId: sessionId,
              apiToken: AuthSessionStore.currentApiToken,
            ),
          )
          .timeout(const Duration(seconds: 60));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      if (_looksLikePdf(response.bodyBytes)) return response.bodyBytes;
      final body = response.body.trim();
      if (body.startsWith('{')) {
        return _pdfFromJson(jsonDecode(body));
      }
      // HTML print wrapper is not a shareable PDF.
      return null;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('CustomerInvoicePdfService auto_print: $e');
      }
      return null;
    }
  }

  static Future<Uint8List?> _fromFlutterApi({
    required String sessionId,
    required int invoiceId,
    required String invoiceNumber,
  }) async {
    try {
      final webApi = WebApiImpl();
      final response = await webApi.fetchInvoiceList(
        endpointPath: EndPoint.customerInvoicePdf.path,
        sessionId: sessionId,
        userDetails: ApiRequestHelper.jsonRpcCall({
          'invoice_id': invoiceId,
          'id': invoiceId,
          'invoice_number': invoiceNumber,
          'number': invoiceNumber,
        }),
        timeout: const Duration(seconds: 60),
        logResponseBody: false,
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      if (_looksLikePdf(response.bodyBytes)) return response.bodyBytes;

      final decoded = jsonDecode(response.body);
      return _pdfFromJson(decoded);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('CustomerInvoicePdfService flutter api: $e');
      }
      return null;
    }
  }

  static Future<Uint8List> _buildLocalReceiptPdf({
    required InvoiceSummaryModel invoice,
    double? payAmount,
    String? paymentName,
  }) async {
    final doc = pw.Document();
    final number = invoice.displayNumber;
    final customer = (invoice.displayCustomer ?? invoice.customer ?? '').trim();
    final date = (invoice.invoiceDate ?? '').trim();
    final mode = (invoice.paymentMode ?? '').trim();
    final status = invoice.displayStatus.trim();
    final payLabel = (paymentName ?? '').trim();

    pw.Widget row(String label, String value, {bool bold = false}) {
      return pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 8),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.SizedBox(
              width: 130,
              child: pw.Text(
                label,
                style: const pw.TextStyle(
                  fontSize: 12,
                  color: PdfColors.grey700,
                ),
              ),
            ),
            pw.Expanded(
              child: pw.Text(
                value.isEmpty ? '—' : value,
                style: pw.TextStyle(
                  fontSize: 13,
                  fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
                ),
              ),
            ),
          ],
        ),
      );
    }

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(36),
        build: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              'Payment Receipt',
              style: pw.TextStyle(
                fontSize: 22,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.SizedBox(height: 6),
            pw.Text(
              'Athurasramam Homeo Medicals',
              style: const pw.TextStyle(
                fontSize: 12,
                color: PdfColors.grey700,
              ),
            ),
            pw.SizedBox(height: 18),
            pw.Divider(),
            pw.SizedBox(height: 12),
            if (payLabel.isNotEmpty) row('Payment', payLabel, bold: true),
            row('Invoice', number, bold: true),
            row('Customer', customer.isEmpty ? '—' : customer),
            row('Date', date.isEmpty ? '—' : date),
            if (mode.isNotEmpty) row('Payment Mode', mode),
            if (status.isNotEmpty) row('Status', status),
            row('Bill Total', InvoiceSummaryModel.formatMoney(invoice.total)),
            row('Balance', InvoiceSummaryModel.formatMoney(invoice.balance)),
            if (payAmount != null && payAmount > 0.0001)
              row(
                'Pay Amount',
                InvoiceSummaryModel.formatMoney(payAmount),
                bold: true,
              ),
            pw.SizedBox(height: 24),
            pw.Text(
              'Shared from Homeo app',
              style: const pw.TextStyle(
                fontSize: 10,
                color: PdfColors.grey600,
              ),
            ),
          ],
        ),
      ),
    );

    return doc.save();
  }

  static Uint8List? _pdfFromJson(dynamic decoded) {
    if (decoded is! Map) return null;
    final result = decoded['result'] ?? decoded['data'] ?? decoded;
    if (result is Map) {
      for (final key in const [
        'pdf',
        'pdf_base64',
        'file',
        'content',
        'data',
        'report',
      ]) {
        final raw = result[key];
        final bytes = _decodePdfPayload(raw);
        if (bytes != null) return bytes;
      }
    }
    return _decodePdfPayload(result);
  }

  static Uint8List? _decodePdfPayload(dynamic raw) {
    if (raw == null) return null;
    if (raw is Uint8List) return _looksLikePdf(raw) ? raw : null;
    if (raw is List) {
      try {
        final bytes = Uint8List.fromList(raw.cast<int>());
        return _looksLikePdf(bytes) ? bytes : null;
      } catch (_) {
        return null;
      }
    }
    if (raw is String) {
      var s = raw.trim();
      if (s.startsWith('data:application/pdf')) {
        final idx = s.indexOf('base64,');
        if (idx >= 0) s = s.substring(idx + 7);
      }
      try {
        final bytes = base64Decode(s);
        return _looksLikePdf(bytes) ? bytes : null;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  static bool _looksLikePdf(Uint8List bytes) {
    if (bytes.length < 5) return false;
    return bytes[0] == 0x25 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x44 &&
        bytes[3] == 0x46;
  }

  static void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}
