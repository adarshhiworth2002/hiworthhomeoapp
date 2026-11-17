import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../models/invoice_summary_model.dart';
import '../../viewModels/login_viewmodel.dart';
import 'api_request_helper.dart';
import 'appConfig.dart';
import 'auth_session_store.dart';
import 'endPoints.dart';
import 'flutter_customer_invoice_web_api.dart';
import 'session_helper.dart';

/// Shares customer invoice / payment receipt PDFs.
///
/// [shareInvoice] — tax invoice `/customer-invoices/{id}/print`
/// (optional `partner_payment=` for paid/balance from a PAY nest bill).
///
/// [sharePayment] — payment receipt `/partner-payments/{id}/print`
/// (app-bar Share on PAY nest).
class CustomerInvoicePdfService {
  const CustomerInvoicePdfService._();

  /// A4 with no extra engine margins — Laravel HTML/@page owns spacing.
  static final PdfPageFormat _printPageFormat = PdfPageFormat(
    210 * PdfPageFormat.mm,
    297 * PdfPageFormat.mm,
    marginAll: 0,
  );

  static Future<void> shareInvoice(
    BuildContext context, {
    required InvoiceSummaryModel invoice,
    double? payAmount,
    String? paymentName,
    /// When sharing a bill under a PAY nest — adds `?partner_payment=`.
    int? partnerPaymentId,
  }) async {
    await _deliverInvoicePdf(
      context,
      invoice: invoice,
      payAmount: payAmount,
      paymentName: paymentName,
      partnerPaymentId: partnerPaymentId,
      viaWhatsApp: false,
    );
  }

  /// Same bill tax invoice (`partner_payment=` when set) → WhatsApp.
  static Future<void> shareInvoiceToWhatsApp(
    BuildContext context, {
    required InvoiceSummaryModel invoice,
    double? payAmount,
    String? paymentName,
    int? partnerPaymentId,
  }) async {
    await _deliverInvoicePdf(
      context,
      invoice: invoice,
      payAmount: payAmount,
      paymentName: paymentName,
      partnerPaymentId: partnerPaymentId,
      viaWhatsApp: true,
    );
  }

  static Future<void> _deliverInvoicePdf(
    BuildContext context, {
    required InvoiceSummaryModel invoice,
    double? payAmount,
    String? paymentName,
    int? partnerPaymentId,
    required bool viaWhatsApp,
  }) async {
    final id = invoice.id;
    final login = Provider.of<LoginViewmodel>(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          viaWhatsApp
              ? 'Preparing WhatsApp invoice…'
              : 'Preparing invoice PDF…',
        ),
      ),
    );

    try {
      final built = await _buildInvoicePdfBytes(
        login: login,
        invoice: invoice,
        payAmount: payAmount,
        paymentName: paymentName,
        partnerPaymentId: partnerPaymentId,
      );
      if (!context.mounted) return;
      messenger.hideCurrentSnackBar();

      final bytes = built.bytes;
      if (bytes == null || bytes.isEmpty) {
        _toast(context, 'Could not generate invoice PDF.');
        return;
      }

      if (built.usedLocalFallback) {
        _toast(
          context,
          'Server print layout unavailable — sharing a simple receipt.',
        );
      }

      final name = invoice.displayNumber
          .replaceAll(RegExp(r'[^\w\-./]+'), '_')
          .replaceAll('/', '-');
      final fileId = id != null && id > 0
          ? id.toString()
          : (name.isEmpty ? 'invoice' : name);
      final filename = (built.filename != null &&
              built.filename!.trim().isNotEmpty)
          ? built.filename!.trim()
          : 'invoice_${name.isEmpty ? fileId : name}.pdf';

      if (viaWhatsApp) {
        final ok = await _sharePdfFileToWhatsApp(bytes, filename);
        if (!context.mounted) return;
        if (!ok) {
          _toast(context, 'WhatsApp not available — use Share instead.');
        }
        return;
      }

      await Printing.sharePdf(bytes: bytes, filename: filename);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('CustomerInvoicePdfService._deliverInvoicePdf: $e');
      }
      if (!context.mounted) return;
      messenger.hideCurrentSnackBar();
      _toast(
        context,
        viaWhatsApp ? 'WhatsApp share failed.' : 'Share PDF failed.',
      );
    }
  }

  static Future<({Uint8List? bytes, String? filename, bool usedLocalFallback})>
      _buildInvoicePdfBytes({
    required LoginViewmodel login,
    required InvoiceSummaryModel invoice,
    double? payAmount,
    String? paymentName,
    int? partnerPaymentId,
  }) async {
    final id = invoice.id;
    Uint8List? bytes;
    String? serverName;
    var usedLocalFallback = false;

    final payQ = (partnerPaymentId != null && partnerPaymentId > 0)
        ? '?partner_payment=$partnerPaymentId'
        : '';
    final invoicePrintPath =
        (id != null && id > 0) ? '/customer-invoices/$id/print$payQ' : null;

    // Prefer website HTML when partner_payment is set (browser tax invoice).
    if (invoicePrintPath != null && payQ.isNotEmpty) {
      bytes = await _pdfFromWebsiteHtml(
        login: login,
        path: '$invoicePrintPath&html=1',
      );
      if (bytes != null && kDebugMode) {
        debugPrint(
          'CustomerInvoicePdfService: website HTML PDF '
          '$invoicePrintPath (${bytes.length} bytes)',
        );
      }
    }

    if (bytes == null && invoicePrintPath != null) {
      bytes = await _pdfFromWebsitePrint(
        login: login,
        path: invoicePrintPath,
      );
      if (bytes != null) {
        if (payQ.isNotEmpty) bytes = await _normalizeToA4(bytes);
        if (kDebugMode) {
          debugPrint(
            'CustomerInvoicePdfService: website print PDF '
            '$invoicePrintPath (${bytes.length} bytes)',
          );
        }
      }
    }

    final token = _bearerToken(login);
    if (bytes == null && id != null && id > 0 && token.isNotEmpty) {
      final fetched = await _fetchPdf(
        endpoint: EndPoint.customerInvoicePdf.path,
        token: token,
        body: ApiRequestHelper.jsonRpcCall({
          'invoice_id': id,
          'id': id,
          'invoice_number': invoice.displayNumber,
          'number': invoice.displayNumber,
          if (partnerPaymentId != null && partnerPaymentId > 0)
            'partner_payment': partnerPaymentId,
        }),
      );
      bytes = fetched.bytes;
      serverName = fetched.filename;
      if (bytes != null && kDebugMode) {
        debugPrint(
          'CustomerInvoicePdfService: API invoice PDF '
          '(${bytes.length} bytes)',
        );
      }
    }

    if (bytes == null && invoicePrintPath != null) {
      final htmlPath = payQ.isEmpty
          ? '$invoicePrintPath?html=1'
          : '$invoicePrintPath&html=1';
      bytes = await _pdfFromWebsiteHtml(login: login, path: htmlPath);
      if (bytes != null && kDebugMode) {
        debugPrint(
          'CustomerInvoicePdfService: website HTML PDF '
          '(${bytes.length} bytes)',
        );
      }
    }

    if (bytes == null) {
      bytes = await _buildLocalReceiptPdf(
        invoice: invoice,
        payAmount: payAmount,
        paymentName: paymentName,
      );
      usedLocalFallback = true;
    }

    return (
      bytes: bytes,
      filename: serverName,
      usedLocalFallback: usedLocalFallback,
    );
  }

  static const _shareChannel = MethodChannel('com.example.homeocr26/share');

  /// Shares the Laravel payment receipt (website Open PDF / print preview).
  ///
  /// Preferred URL (matches admin PAY00007 screenshot):
  /// `/partner-payments/{paymentId}/print?html=1`
  static Future<void> sharePayment(
    BuildContext context, {
    required int paymentId,
    int? invoiceId,
    String? paymentName,
    String? customerName,
    double? amount,
  }) async {
    await _deliverPaymentPdf(
      context,
      paymentId: paymentId,
      invoiceId: invoiceId,
      paymentName: paymentName,
      customerName: customerName,
      amount: amount,
      viaWhatsApp: false,
    );
  }

  /// Same partner-payment receipt PDF, opened in WhatsApp with the file attached.
  static Future<void> sharePaymentToWhatsApp(
    BuildContext context, {
    required int paymentId,
    int? invoiceId,
    String? paymentName,
    String? customerName,
    double? amount,
  }) async {
    await _deliverPaymentPdf(
      context,
      paymentId: paymentId,
      invoiceId: invoiceId,
      paymentName: paymentName,
      customerName: customerName,
      amount: amount,
      viaWhatsApp: true,
    );
  }

  static Future<void> _deliverPaymentPdf(
    BuildContext context, {
    required int paymentId,
    int? invoiceId,
    String? paymentName,
    String? customerName,
    double? amount,
    required bool viaWhatsApp,
  }) async {
    final login = Provider.of<LoginViewmodel>(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          viaWhatsApp
              ? 'Preparing WhatsApp receipt…'
              : 'Preparing payment PDF…',
        ),
      ),
    );

    try {
      final built = await _buildPaymentPdfBytes(
        login: login,
        paymentId: paymentId,
        invoiceId: invoiceId,
        paymentName: paymentName,
        customerName: customerName,
        amount: amount,
      );
      if (!context.mounted) return;
      messenger.hideCurrentSnackBar();

      final bytes = built.bytes;
      if (bytes == null || bytes.isEmpty) {
        _toast(context, 'Could not generate payment PDF.');
        return;
      }

      if (built.usedLocalFallback) {
        _toast(
          context,
          'Server print layout unavailable — sharing a simple receipt.',
        );
      }

      final safeName = (paymentName ?? 'PAY_$paymentId')
          .replaceAll(RegExp(r'[^\w\-./]+'), '_')
          .replaceAll('/', '-');
      final filename = (built.filename != null && built.filename!.trim().isNotEmpty)
          ? built.filename!.trim()
          : '$safeName.pdf';

      if (viaWhatsApp) {
        final ok = await _sharePdfFileToWhatsApp(bytes, filename);
        if (!context.mounted) return;
        if (!ok) {
          _toast(context, 'WhatsApp not available — use Share instead.');
        }
        return;
      }

      await Printing.sharePdf(bytes: bytes, filename: filename);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('CustomerInvoicePdfService._deliverPaymentPdf: $e');
      }
      if (!context.mounted) return;
      messenger.hideCurrentSnackBar();
      _toast(context, viaWhatsApp ? 'WhatsApp share failed.' : 'Share PDF failed.');
    }
  }

  static Future<({Uint8List? bytes, String? filename, bool usedLocalFallback})>
      _buildPaymentPdfBytes({
    required LoginViewmodel login,
    required int paymentId,
    int? invoiceId,
    String? paymentName,
    String? customerName,
    double? amount,
  }) async {
    Uint8List? bytes;
    String? serverName;
    var usedLocalFallback = false;

    // Website payment receipt — same as Share / Chrome print.
    final paymentPrintPath =
        paymentId > 0 ? '/partner-payments/$paymentId/print' : null;

    if (paymentPrintPath != null) {
      bytes = await _pdfFromWebsiteHtml(
        login: login,
        path: '$paymentPrintPath?html=1',
      );
      if (bytes != null && kDebugMode) {
        debugPrint(
          'CustomerInvoicePdfService: website HTML receipt '
          '$paymentPrintPath (${bytes.length} bytes)',
        );
      }
    }

    if (bytes == null && paymentPrintPath != null) {
      bytes = await _pdfFromWebsitePrint(
        login: login,
        path: paymentPrintPath,
      );
      if (bytes != null) {
        bytes = await _normalizeToA4(bytes);
        if (kDebugMode) {
          debugPrint(
            'CustomerInvoicePdfService: website print PDF '
            '$paymentPrintPath (${bytes.length} bytes)',
          );
        }
      }
    }

    final token = _bearerToken(login);
    if (bytes == null && token.isNotEmpty && paymentId > 0) {
      final fetched = await _fetchPdf(
        endpoint: EndPoint.customerPaymentPdf.path,
        token: token,
        body: ApiRequestHelper.jsonRpcCall({
          'payment_id': paymentId,
          'id': paymentId,
          'partner_payment_id': paymentId,
          if (invoiceId != null && invoiceId > 0) 'invoice_id': invoiceId,
        }),
      );
      bytes = fetched.bytes;
      serverName = fetched.filename;
      if (bytes != null) {
        bytes = await _normalizeToA4(bytes);
        if (kDebugMode) {
          debugPrint(
            'CustomerInvoicePdfService: API payment PDF '
            '(${bytes.length} bytes)',
          );
        }
      }
    }

    if (bytes == null) {
      bytes = await _buildLocalPaymentPdf(
        paymentId: paymentId,
        paymentName: paymentName,
        customerName: customerName,
        amount: amount,
      );
      usedLocalFallback = true;
    }

    return (
      bytes: bytes,
      filename: serverName,
      usedLocalFallback: usedLocalFallback,
    );
  }

  /// Writes PDF to cache, opens WhatsApp with attachment (Android).
  /// Falls back to the system share sheet if WhatsApp is missing.
  static Future<bool> _sharePdfFileToWhatsApp(
    Uint8List bytes,
    String filename,
  ) async {
    final safe = filename.trim().isEmpty
        ? 'payment_receipt.pdf'
        : filename.replaceAll(RegExp(r'[^\w\-./]+'), '_');
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$safe');
    await file.writeAsBytes(bytes, flush: true);

    if (!kIsWeb && Platform.isAndroid) {
      try {
        final opened = await _shareChannel.invokeMethod<bool>(
          'sharePdfToWhatsApp',
          {'path': file.path},
        );
        if (opened == true) return true;
      } catch (e) {
        if (kDebugMode) {
          debugPrint('CustomerInvoicePdfService WhatsApp channel: $e');
        }
      }
    }

    // iOS / fallback: share sheet (user picks WhatsApp).
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'application/pdf', name: safe)],
        text: safe,
      ),
    );
    return true;
  }

  /// Laravel admin `/print` PDF bytes (not phone HTML conversion).
  static Future<Uint8List?> _pdfFromWebsitePrint({
    required LoginViewmodel login,
    required String path,
  }) async {
    try {
      final creds = await _printCredentials(login);
      if (creds == null) return null;
      return FlutterCustomerInvoiceWebApi.fetchPrintPdf(
        path: path,
        email: creds.email,
        password: creds.password,
        apiToken: _bearerToken(login),
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('CustomerInvoicePdfService._pdfFromWebsitePrint: $e');
      }
      return null;
    }
  }

  /// Convert Laravel website `print?html=1` to PDF on device (browser layout).
  static Future<Uint8List?> _pdfFromWebsiteHtml({
    required LoginViewmodel login,
    required String path,
  }) async {
    try {
      final creds = await _printCredentials(login);
      if (creds == null) {
        if (kDebugMode) {
          debugPrint(
            'CustomerInvoicePdfService: no email/password for HTML print',
          );
        }
        return null;
      }

      // Android printing plugin omits `canConvertHtml` (defaults false) even
      // though WebView convertHtml works. Use canPrint / try convert anyway.
      final info = await Printing.info();
      final canTryHtml =
          info.canConvertHtml || info.canPrint || info.dynamicLayout;
      if (!canTryHtml) {
        if (kDebugMode) {
          debugPrint(
            'CustomerInvoicePdfService: convertHtml not available on device '
            '(canConvertHtml=${info.canConvertHtml} canPrint=${info.canPrint})',
          );
        }
        return null;
      }

      final html = await FlutterCustomerInvoiceWebApi.fetchPrintHtml(
        path: path,
        email: creds.email,
        password: creds.password,
        apiToken: _bearerToken(login),
      );
      if (html == null || html.trim().isEmpty) return null;

      final base = AppConfig.webViewBaseUrl.trim().replaceAll(RegExp(r'/+$'), '');
      final prepared = _preparePrintHtml(html, base);
      // ignore: deprecated_member_use
      final bytes = await Printing.convertHtml(
        html: prepared,
        baseUrl: base.isEmpty ? null : '$base/',
        format: _printPageFormat,
      );
      if (!_looksLikePdf(bytes) || bytes.length < 500) {
        if (kDebugMode) {
          debugPrint(
            'CustomerInvoicePdfService: convertHtml returned non-PDF '
            '(${bytes.length} bytes)',
          );
        }
        return null;
      }
      // Android WebView print often emits Letter even when format is A4.
      return _normalizeToA4(bytes);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('CustomerInvoicePdfService._pdfFromWebsiteHtml: $e');
      }
      return null;
    }
  }

  /// Re-wrap any Letter/odd PDF onto A4 so Android print isn't letterboxed.
  static Future<Uint8List> _normalizeToA4(Uint8List bytes) async {
    try {
      final doc = pw.Document();
      var pages = 0;
      await for (final page in Printing.raster(bytes, dpi: 144)) {
        pages++;
        final png = await page.toPng();
        final image = pw.MemoryImage(png);
        doc.addPage(
          pw.Page(
            pageFormat: _printPageFormat,
            margin: pw.EdgeInsets.zero,
            build: (_) => pw.SizedBox(
              width: _printPageFormat.width,
              height: _printPageFormat.height,
              child: pw.FittedBox(
                fit: pw.BoxFit.fitWidth,
                alignment: pw.Alignment.topCenter,
                child: pw.Image(image),
              ),
            ),
          ),
        );
      }
      if (pages == 0) return bytes;
      final out = await doc.save();
      if (kDebugMode) {
        debugPrint(
          'CustomerInvoicePdfService._normalizeToA4: $pages page(s) '
          '${bytes.length}→${out.length} bytes',
        );
      }
      return out;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('CustomerInvoicePdfService._normalizeToA4: $e');
      }
      return bytes;
    }
  }

  static String _preparePrintHtml(String html, String base) {
    var out = html;
    // Drop auto-print / window.print so WebView conversion is not interrupted.
    out = out.replaceAll(
      RegExp(
        r'<script\b[^>]*>[\s\S]*?(?:autoprint|window\.print)[\s\S]*?</script>',
        caseSensitive: false,
      ),
      '',
    );
    final headRe = RegExp(r'<head([^>]*)>', caseSensitive: false);
    // Phone WebView reflows at ~360px and breaks fixed A4 invoice CSS.
    // Force desktop A4 width (210mm / ~794px) so layout matches Laravel
    // browser print — not Letter with a small content box.
    const printCss = '''
<meta name="viewport" content="width=794, initial-scale=1, maximum-scale=1">
<style>
@page { size: A4 portrait; margin: 0 !important; }
html {
  width: 210mm !important;
  min-width: 210mm !important;
  max-width: 210mm !important;
  margin: 0 !important;
  padding: 0 !important;
}
body {
  width: 210mm !important;
  min-width: 210mm !important;
  max-width: 210mm !important;
  margin: 0 auto !important;
  padding: 0 !important;
  box-sizing: border-box !important;
  -webkit-print-color-adjust: exact !important;
  print-color-adjust: exact !important;
}
body > * {
  max-width: 100% !important;
  box-sizing: border-box !important;
}
table {
  max-width: 100% !important;
}
*, *::before, *::after {
  -webkit-print-color-adjust: exact !important;
  print-color-adjust: exact !important;
}
</style>
''';
    if (headRe.hasMatch(out)) {
      out = out.replaceFirstMapped(
        headRe,
        (m) => '<head${m.group(1)}>$printCss',
      );
    }
    if (base.isNotEmpty &&
        !RegExp(r'<base\s', caseSensitive: false).hasMatch(out)) {
      out = out.replaceFirstMapped(
        headRe,
        (m) => '<head${m.group(1)}><base href="$base/">',
      );
    }
    return out;
  }

  static Future<({String email, String password})?> _printCredentials(
    LoginViewmodel login,
  ) async {
    var email = (login.loginEmail ?? '').trim();
    var password = login.loginPassword ?? '';
    if (email.isEmpty || password.isEmpty) {
      final saved = await AuthSessionStore.load();
      if (saved != null) {
        if (email.isEmpty) email = saved.email.trim();
        if (password.isEmpty) password = saved.password;
      }
    }
    if (email.isEmpty || password.isEmpty) return null;
    return (email: email, password: password);
  }

  static String _bearerToken(LoginViewmodel login) {
    final fromLogin = (login.apiToken ?? '').trim();
    if (fromLogin.isNotEmpty) return fromLogin;
    return AuthSessionStore.currentApiToken;
  }

  static Future<({Uint8List? bytes, String? filename})> _fetchPdf({
    required String endpoint,
    required String token,
    required Map<String, dynamic> body,
  }) async {
    try {
      final url = '${AppConfig.baseAppUrl}$endpoint';
      final response = await http
          .post(
            Uri.parse(url),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/pdf, application/json',
              'Authorization': 'Bearer $token',
              'User-Agent': SessionHelper.jsonUserAgent,
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 90));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (kDebugMode) {
          debugPrint(
            'PDF $endpoint HTTP ${response.statusCode}: '
            '${response.body.length > 200 ? response.body.substring(0, 200) : response.body}',
          );
        }
        return (bytes: null, filename: null);
      }

      if (_looksLikePdf(response.bodyBytes)) {
        return (
          bytes: response.bodyBytes,
          filename: _filenameFromHeaders(response.headers),
        );
      }

      final trimmed = response.body.trim();
      if (trimmed.startsWith('{')) {
        final decoded = jsonDecode(trimmed);
        final bytes = _pdfFromJson(decoded);
        final name = _filenameFromJson(decoded);
        return (bytes: bytes, filename: name);
      }
      return (bytes: null, filename: null);
    } catch (e) {
      if (kDebugMode) debugPrint('PDF $endpoint: $e');
      return (bytes: null, filename: null);
    }
  }

  static String? _filenameFromHeaders(Map<String, String> headers) {
    final raw = headers['content-disposition'] ??
        headers['Content-Disposition'] ??
        '';
    final m = RegExp(
      r'''filename\*?=(?:UTF-8'')?"?([^";]+)''',
      caseSensitive: false,
    ).firstMatch(raw);
    final name = m?.group(1)?.trim();
    if (name == null || name.isEmpty) return null;
    return name.replaceAll('"', '');
  }

  static String? _filenameFromJson(dynamic decoded) {
    if (decoded is! Map) return null;
    final data = decoded['data'];
    if (data is Map) {
      final name = '${data['filename'] ?? ''}'.trim();
      if (name.isNotEmpty) return name;
    }
    final name = '${decoded['filename'] ?? ''}'.trim();
    return name.isEmpty ? null : name;
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

  static Future<Uint8List> _buildLocalPaymentPdf({
    required int paymentId,
    String? paymentName,
    String? customerName,
    double? amount,
  }) async {
    final doc = pw.Document();
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
            pw.SizedBox(height: 18),
            pw.Divider(),
            pw.SizedBox(height: 12),
            row('Payment', paymentName ?? 'PAY/$paymentId', bold: true),
            row('Customer', (customerName ?? '').trim()),
            if (amount != null && amount > 0.0001)
              row(
                'Amount',
                InvoiceSummaryModel.formatMoney(amount),
                bold: true,
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
