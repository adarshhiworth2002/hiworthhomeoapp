import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../models/invoice_summary_model.dart';
import 'appConfig.dart';
import 'auth_session_store.dart';
import 'session_helper.dart';

/// Loads supplier invoice line items from the website edit form
/// (`/supplier-invoices/{id}`) when Flutter has no supplier detail API.
class SupplierInvoiceWebApi {
  const SupplierInvoiceWebApi._();

  static Future<InvoiceSummaryModel?> fetchDetail({
    required int invoiceId,
    InvoiceSummaryModel? seed,
    String? email,
    String? password,
    String? apiToken,
  }) async {
    if (invoiceId <= 0) return null;
    final auth = await AuthSessionStore.load();
    final login = (email ?? auth?.email ?? '').trim();
    final pass = password ?? auth?.password ?? '';
    final token = (apiToken ?? auth?.apiToken ?? AuthSessionStore.currentApiToken)
        .trim();
    if (login.isEmpty || pass.isEmpty) return null;

    final session = await _WebSession.open(
      email: login,
      password: pass,
      apiToken: token,
    );
    if (session == null) return null;
    try {
      final html = await session.getHtml('/supplier-invoices/$invoiceId');
      if (html == null || html.isEmpty) return null;
      final lines = parseLinesHtml(html);
      if (kDebugMode) {
        debugPrint(
          'SupplierInvoiceWebApi: #$invoiceId lines=${lines.length}',
        );
      }
      final base = seed ??
          InvoiceSummaryModel(
            id: invoiceId,
          );
      return base.mergedWith(
        InvoiceSummaryModel(
          id: invoiceId,
          lines: lines,
        ),
      );
    } finally {
      session.close();
    }
  }

  /// Parses `invoice-line-row` inputs from the supplier invoice form HTML.
  static List<InvoiceLineModel> parseLinesHtml(String html) {
    final bodyStart = html.indexOf('id="invoice-lines-body"');
    if (bodyStart < 0) return const [];
    final bodyEnd = html.indexOf('</tbody>', bodyStart);
    var body = bodyEnd > bodyStart
        ? html.substring(bodyStart, bodyEnd)
        : html.substring(bodyStart);

    // Collapse huge <select> lists to the selected option only.
    body = body.replaceAllMapped(
      RegExp(r'<select([\s\S]*?)</select>', caseSensitive: false),
      (match) {
        final block = match.group(0) ?? '';
        final name = RegExp(r'name="([^"]+)"').firstMatch(block)?.group(1) ?? '';
        final opt = RegExp(
          r'<option([^>]*\bselected\b[^>]*)>([^<]*)',
          caseSensitive: false,
        ).firstMatch(block);
        final text = (opt?.group(2) ?? '').trim();
        final val = RegExp(r'value="([^"]*)"')
                .firstMatch(opt?.group(1) ?? '')
                ?.group(1) ??
            '';
        return '<select name="$name" data-selected-text="$text" '
            'data-selected-value="$val"></select>';
      },
    );

    final parts = body.split(RegExp(r'class="invoice-line-row"'));
    final out = <InvoiceLineModel>[];
    for (var i = 1; i < parts.length; i++) {
      final row = parts[i];
      final medicine = _selected(row, 'medicine_id');
      final received = _num(_input(row, 'received_qty'));
      final ordered = _num(_input(row, 'ordered_qty'));
      final mrp = _num(_input(row, 'mrp'));
      final uPrice = _num(_input(row, 'u_price'));
      if ((medicine == null || medicine.isEmpty) &&
          (received == null || received == 0) &&
          (mrp == null || mrp == 0) &&
          (ordered == null || ordered == 0)) {
        continue;
      }
      final free = _num(_input(row, 'free_qty')) ?? 0;
      final discount = _num(_input(row, 'discount'));
      final tax = _num(_input(row, 'tax'));
      var total = _num(
        _input(row, 'amount') ??
            _input(row, 'line_total') ??
            _input(row, 'total') ??
            _input(row, 'price_total'),
      );
      final qty = received ?? ordered ?? 0;
      final unit = uPrice ?? mrp;
      if (total == null && unit != null && qty > 0) {
        total = unit * qty;
      }
      final lineId = int.tryParse(
        RegExp(r'data-line-id="(\d+)"').firstMatch(row)?.group(1) ?? '',
      );
      out.add(
        InvoiceLineModel(
          id: lineId,
          productName: medicine,
          potency: _selected(row, 'potency_id'),
          packing: _selected(row, 'packing_id'),
          company: _selected(row, 'company_id'),
          group: _selected(row, 'group_id'),
          batch: _input(row, 'batch'),
          mrp: mrp,
          orderedQty: ordered,
          qty: received ?? ordered,
          freeQty: free,
          unitPrice: unit,
          uPrice: unit,
          discount: discount,
          tax: tax,
          total: total,
          hsn: _input(row, 'hsn'),
        ),
      );
    }
    return out;
  }

  static String? _input(String row, String field) {
    final named = RegExp(
      'name="lines\\[\\d+\\]\\[$field\\]"[^>]*value="([^"]*)"',
    ).firstMatch(row);
    if (named != null) return named.group(1);
    final valued = RegExp(
      'value="([^"]*)"[^>]*name="lines\\[\\d+\\]\\[$field\\]"',
    ).firstMatch(row);
    return valued?.group(1);
  }

  static String? _selected(String row, String field) {
    final m = RegExp(
      'name="lines\\[\\d+\\]\\[$field\\]"[^>]*data-selected-text="([^"]*)"',
    ).firstMatch(row);
    final text = m?.group(1)?.trim();
    if (text == null || text.isEmpty || text == '—') return null;
    return text;
  }

  static double? _num(String? raw) {
    if (raw == null) return null;
    final t = raw.trim().replaceAll(',', '');
    if (t.isEmpty) return null;
    return double.tryParse(t);
  }
}

class _WebSession {
  _WebSession({
    required this.client,
    required this.base,
    required this.cookies,
    required this.bearer,
  });

  final http.Client client;
  final String base;
  final Map<String, String> cookies;
  final String bearer;

  static Future<_WebSession?> open({
    required String email,
    required String password,
    String? apiToken,
  }) async {
    final client = http.Client();
    final base = AppConfig.webViewBaseUrl.replaceAll(RegExp(r'/$'), '');
    final cookies = <String, String>{};
    final bearer = (apiToken ?? '').trim();
    try {
      final loginPage = await _request(
        client,
        method: 'GET',
        uri: Uri.parse('$base/login'),
        cookies: cookies,
        bearerToken: bearer,
        followRedirects: true,
      );
      _storeCookies(cookies, loginPage.headers);
      final loginToken = RegExp(
            r'name="_token"\s+value="([^"]+)"',
          ).firstMatch(loginPage.body)?.group(1) ??
          '';

      final loginPost = await _request(
        client,
        method: 'POST',
        uri: Uri.parse('$base/login'),
        cookies: cookies,
        form: {
          '_token': loginToken,
          'email': email,
          'login': email,
          'password': password,
        },
        xsrfToken: _xsrfFromCookies(cookies) ?? loginToken,
        bearerToken: bearer,
        followRedirects: false,
        referer: '$base/login',
      );
      _storeCookies(cookies, loginPost.headers);
      final loc = loginPost.headers['location'] ?? '';
      final ok = (loginPost.statusCode >= 200 && loginPost.statusCode < 400) &&
          !loc.contains('/login');
      if (!ok && loginPost.statusCode != 302) {
        // Some builds return 200 with redirect body; accept cookie session.
        if (!cookies.containsKey('homeo_session') &&
            !cookies.keys.any((k) => k.toLowerCase().contains('session'))) {
          client.close();
          return null;
        }
      }
      return _WebSession(
        client: client,
        base: base,
        cookies: cookies,
        bearer: bearer,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('SupplierInvoiceWebApi.open: $e');
      client.close();
      return null;
    }
  }

  Future<String?> getHtml(String path) async {
    try {
      final uri = Uri.parse(
        '$base${path.startsWith('/') ? '' : '/'}$path',
      );
      final res = await _request(
        client,
        method: 'GET',
        uri: uri,
        cookies: cookies,
        bearerToken: bearer,
        referer: '$base/home',
        followRedirects: true,
      );
      _storeCookies(cookies, res.headers);
      if (res.statusCode < 200 || res.statusCode >= 400) return null;
      if (res.body.contains('Login —') &&
          !res.body.contains('invoice-lines-body')) {
        return null;
      }
      return res.body;
    } catch (e) {
      if (kDebugMode) debugPrint('SupplierInvoiceWebApi.getHtml: $e');
      return null;
    }
  }

  void close() => client.close();

  static Future<http.Response> _request(
    http.Client client, {
    required String method,
    required Uri uri,
    required Map<String, String> cookies,
    Map<String, String>? form,
    String? xsrfToken,
    String? bearerToken,
    String? referer,
    bool followRedirects = false,
  }) async {
    final headers = <String, String>{
      'Accept': 'text/html,application/xhtml+xml',
      'User-Agent': SessionHelper.jsonUserAgent,
    };
    if (referer != null) headers['Referer'] = referer;
    final token = (bearerToken ?? '').trim();
    if (token.isNotEmpty) headers['Authorization'] = 'Bearer $token';
    final xsrf = (xsrfToken ?? _xsrfFromCookies(cookies) ?? '').trim();
    if (xsrf.isNotEmpty) {
      headers['X-XSRF-TOKEN'] = xsrf;
      headers['X-CSRF-TOKEN'] = xsrf;
    }
    if (cookies.isNotEmpty) {
      headers['Cookie'] =
          cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
    }
    late final http.Response res;
    if (method == 'POST') {
      headers['Content-Type'] = 'application/x-www-form-urlencoded';
      res = await client
          .post(uri, headers: headers, body: form ?? const <String, String>{})
          .timeout(const Duration(seconds: 30));
    } else {
      res = await client
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 30));
    }
    if (followRedirects &&
        res.statusCode >= 300 &&
        res.statusCode < 400 &&
        (res.headers['location'] ?? '').isNotEmpty) {
      final loc = res.headers['location']!;
      final next = loc.startsWith('http') ? Uri.parse(loc) : uri.resolve(loc);
      _storeCookies(cookies, res.headers);
      return _request(
        client,
        method: 'GET',
        uri: next,
        cookies: cookies,
        bearerToken: bearerToken,
        referer: referer,
        followRedirects: true,
      );
    }
    return res;
  }

  static void _storeCookies(
    Map<String, String> cookies,
    Map<String, String> headers,
  ) {
    final raw = headers['set-cookie'] ?? headers['Set-Cookie'];
    if (raw == null || raw.isEmpty) return;
    for (final part in raw.split(',')) {
      final first = part.split(';').first.trim();
      final eq = first.indexOf('=');
      if (eq <= 0) continue;
      cookies[first.substring(0, eq)] = first.substring(eq + 1);
    }
  }

  static String? _xsrfFromCookies(Map<String, String> cookies) {
    for (final key in const ['XSRF-TOKEN', 'xsrf-token']) {
      final v = cookies[key];
      if (v != null && v.isNotEmpty) {
        try {
          return Uri.decodeComponent(v);
        } catch (_) {
          return v;
        }
      }
    }
    return null;
  }
}
