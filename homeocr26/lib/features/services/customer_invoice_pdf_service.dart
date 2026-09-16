import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';

import '../../models/invoice_summary_model.dart';
import '../../viewModels/login_viewmodel.dart';
import 'WebApi/web_api_impl.dart';
import 'api_request_helper.dart';
import 'endPoints.dart';
import 'odoo_rpc_helper.dart';

/// Shares the server-generated customer invoice PDF (website layout + QR).
class CustomerInvoicePdfService {
  const CustomerInvoicePdfService._();

  static Future<void> shareInvoice(
    BuildContext context, {
    required InvoiceSummaryModel invoice,
  }) async {
    final id = invoice.id;
    if (id == null || id <= 0) {
      _toast(context, 'Invoice id missing — open the bill first.');
      return;
    }

    final login = Provider.of<LoginViewmodel>(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      const SnackBar(content: Text('Preparing invoice PDF…')),
    );

    try {
      Uint8List? bytes;

      final flutterSid = login.sessionId;
      if (flutterSid != null && flutterSid.isNotEmpty) {
        bytes = await _fromFlutterApi(
          sessionId: flutterSid,
          invoiceId: id,
          invoiceNumber: invoice.displayNumber,
        );
      }

      if (bytes == null) {
        final email = (login.loginEmail ?? '').trim();
        final password = login.loginPassword ?? '';
        if (email.isNotEmpty && password.isNotEmpty) {
          final webSid = await OdooRpcHelper.cachedWebSessionId(
            db: LoginViewmodel.dbName,
            login: email,
            password: password,
          );
          if (webSid != null && webSid.isNotEmpty) {
            bytes = await OdooRpcHelper.fetchAccountMovePdfBytes(webSid, id);
          }
        }
      }

      if (!context.mounted) return;
      messenger.hideCurrentSnackBar();

      if (bytes == null || bytes.isEmpty) {
        _toast(context, 'Could not generate invoice PDF.');
        return;
      }

      final name = invoice.displayNumber
          .replaceAll(RegExp(r'[^\w\-./]+'), '_')
          .replaceAll('/', '-');
      await Printing.sharePdf(
        bytes: bytes,
        filename: 'invoice_${name.isEmpty ? id : name}.pdf',
      );
    } catch (e) {
      if (kDebugMode) debugPrint('CustomerInvoicePdfService.shareInvoice: $e');
      if (!context.mounted) return;
      messenger.hideCurrentSnackBar();
      _toast(context, 'Share PDF failed.');
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
      final url = result['pdf_url'] ?? result['url'] ?? result['report_url'];
      if (url is String && url.trim().isNotEmpty) {
        // Absolute or site-relative URL — caller may fetch separately.
        // Handled below only when absolute http(s).
        return null;
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
