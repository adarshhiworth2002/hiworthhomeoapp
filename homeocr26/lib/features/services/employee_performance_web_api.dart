import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../models/employee_performance_model.dart';
import '../../models/invoice_summary_model.dart';
import 'appConfig.dart';
import 'auth_session_store.dart';
import 'calendar_date.dart';
import 'session_helper.dart';

/// Website fallback when `/api/flutter/get_employee_performance*` is empty.
///
/// Mirrors `/employee-performance` (worker list) and
/// `/employee-performance/{id}/bills` (per-worker invoices).
class EmployeePerformanceWebApi {
  const EmployeePerformanceWebApi._();

  /// Workers plus Today/Month bill counts (website table has name only).
  static Future<
      ({
        List<EmployeePerformanceRow> workers,
        Map<int, List<InvoiceSummaryModel>> billsByWorker,
      })> fetchWorkersWithStats({
    required String email,
    required String password,
    String? apiToken,
  }) async {
    final session = await _WebSession.open(
      email: email,
      password: password,
      apiToken: apiToken,
    );
    if (session == null) {
      return (
        workers: const <EmployeePerformanceRow>[],
        billsByWorker: const <int, List<InvoiceSummaryModel>>{},
      );
    }
    try {
      final html = await session.getHtml('/employee-performance');
      if (html == null || html.isEmpty) {
        return (
          workers: const <EmployeePerformanceRow>[],
          billsByWorker: const <int, List<InvoiceSummaryModel>>{},
        );
      }
      var rows = parseWorkersHtml(html);
      if (kDebugMode) {
        debugPrint(
          'EmployeePerformanceWebApi: workers=${rows.length} '
          '[${rows.map((e) => e.displayName).join(", ")}]',
        );
      }
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final monthStart = DateTime(now.year, now.month, 1);
      final billsByWorker = <int, List<InvoiceSummaryModel>>{};
      final enriched = <EmployeePerformanceRow>[];
      for (final row in rows) {
        final wid = row.workerId ?? row.id;
        if (wid <= 0) {
          enriched.add(row);
          continue;
        }
        final bills = await session.getWorkerBills(
          workerId: wid,
          workerName: row.displayName,
          dateFrom: monthStart,
          dateTo: today,
        );
        billsByWorker[wid] = bills;
        var todayCount = 0;
        for (final inv in bills) {
          final day = CalendarDate.parse(inv.invoiceDate);
          if (day != null &&
              day.year == today.year &&
              day.month == today.month &&
              day.day == today.day) {
            todayCount += 1;
          }
        }
        enriched.add(
          row.copyWith(
            billsToday: todayCount,
            billsMonth: bills.length,
            totalBills: bills.length,
          ),
        );
      }
      if (kDebugMode) {
        debugPrint(
          'EmployeePerformanceWebApi: stats '
          '${enriched.map((e) => '${e.displayName}:t${e.billsToday}/m${e.billsMonth}').join(", ")}',
        );
      }
      return (workers: enriched, billsByWorker: billsByWorker);
    } finally {
      session.close();
    }
  }

  static Future<List<EmployeePerformanceRow>> fetchWorkers({
    required String email,
    required String password,
    String? apiToken,
  }) async {
    final packed = await fetchWorkersWithStats(
      email: email,
      password: password,
      apiToken: apiToken,
    );
    return packed.workers;
  }

  static Future<List<InvoiceSummaryModel>> fetchWorkerBills({
    required String email,
    required String password,
    required int workerId,
    String? workerName,
    DateTime? dateFrom,
    DateTime? dateTo,
    String? apiToken,
  }) async {
    if (workerId <= 0) return const [];
    final session = await _WebSession.open(
      email: email,
      password: password,
      apiToken: apiToken,
    );
    if (session == null) return const [];
    try {
      return await session.getWorkerBills(
        workerId: workerId,
        workerName: workerName,
        dateFrom: dateFrom,
        dateTo: dateTo,
      );
    } finally {
      session.close();
    }
  }

  /// Parses website table rows (`KIRAN`, `Pharmacy Admin`, …).
  static List<EmployeePerformanceRow> parseWorkersHtml(String html) {
    final rows = <EmployeePerformanceRow>[];
    final seen = <String>{};

    final paired = RegExp(
      r'<td class="cell-strong">\s*([^<]+?)\s*</td>[\s\S]*?'
      r'employee-performance/(\d+)/bills',
      caseSensitive: false,
    );
    for (final m in paired.allMatches(html)) {
      final name = _decodeHtml(m.group(1)?.trim() ?? '');
      final id = int.tryParse(m.group(2) ?? '') ?? 0;
      final key = name.toLowerCase();
      if (name.isEmpty || !seen.add(key)) continue;
      rows.add(
        EmployeePerformanceRow(
          id: id,
          displayName: name,
          workerId: id > 0 ? id : null,
        ),
      );
    }

    if (rows.isNotEmpty) return rows;

    final nameOnly = RegExp(
      r'<td class="cell-strong">\s*([^<]+?)\s*</td>',
      caseSensitive: false,
    );
    var i = 0;
    for (final m in nameOnly.allMatches(html)) {
      final name = _decodeHtml(m.group(1)?.trim() ?? '');
      final key = name.toLowerCase();
      if (name.isEmpty || !seen.add(key)) continue;
      i += 1;
      rows.add(EmployeePerformanceRow(id: i, displayName: name));
    }
    return rows;
  }

  /// Parses `/employee-performance/{id}/bills` table into invoice rows.
  static List<InvoiceSummaryModel> parseBillsHtml(
    String html, {
    String? billedBy,
  }) {
    final out = <InvoiceSummaryModel>[];
    final seen = <String>{};
    final rowRe = RegExp(r'<tr[^>]*>([\s\S]*?)</tr>', caseSensitive: false);
    final cellRe = RegExp(r'<t[dh][^>]*>([\s\S]*?)</t[dh]>', caseSensitive: false);
    final invRe = RegExp(r'\bR\d{2,}\b', caseSensitive: false);
    final idRe = RegExp(
      r'(?:customer-invoices|invoices?|bills?)/(\d+)',
      caseSensitive: false,
    );

    for (final row in rowRe.allMatches(html)) {
      final rowHtml = row.group(1) ?? '';
      if (rowHtml.contains('<th') || rowHtml.toLowerCase().contains('invoice number')) {
        continue;
      }
      final cells = cellRe
          .allMatches(rowHtml)
          .map((m) => _stripTags(m.group(1) ?? '').trim())
          .where((t) => t.isNotEmpty)
          .toList(growable: false);
      if (cells.isEmpty) continue;

      String? number;
      for (final c in cells) {
        final m = invRe.firstMatch(c);
        if (m != null) {
          number = m.group(0)!.toUpperCase();
          break;
        }
      }
      if (number == null || number.isEmpty) continue;
      if (!seen.add(number)) continue;

      final idMatch = idRe.firstMatch(rowHtml);
      final id = int.tryParse(idMatch?.group(1) ?? '');

      String? date;
      String? customer;
      String? status;
      String? workHours;
      for (final c in cells) {
        if (invRe.hasMatch(c)) continue;
        if (c.toLowerCase() == 'view') continue;
        if (_looksLikeDate(c)) {
          date ??= _normalizeDate(c);
          continue;
        }
        if (_looksLikeStatus(c)) {
          status ??= c;
          continue;
        }
        if (_looksLikeTime(c)) {
          workHours ??= c;
          continue;
        }
        if (c == '-' || c == '—') continue;
        customer ??= c;
      }

      final state = (status ?? '').toLowerCase();
      out.add(
        InvoiceSummaryModel(
          id: id,
          invoiceNumber: number,
          invoiceDate: date,
          customer: customer,
          status: status,
          moveState: state.contains('draft')
              ? 'draft'
              : (state.contains('paid') || state.contains('posted')
                  ? 'posted'
                  : null),
          paymentState: state.contains('paid') ? 'paid' : null,
          isPaid: state.contains('paid'),
          workHours: workHours,
          billedBy: (billedBy ?? '').trim().isEmpty ? null : billedBy!.trim(),
        ),
      );
    }
    return out;
  }

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static String _stripTags(String raw) {
    return _decodeHtml(
      raw
          .replaceAll(RegExp(r'<[^>]+>'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim(),
    );
  }

  static String _decodeHtml(String raw) {
    return raw
        .replaceAll('&amp;', '&')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&quot;', '"')
        .replaceAll('&#039;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .trim();
  }

  static bool _looksLikeDate(String raw) {
    final t = raw.trim();
    if (RegExp(r'^\d{1,2}[/-]\d{1,2}[/-]\d{2,4}$').hasMatch(t)) return true;
    if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(t)) return true;
    if (RegExp(r'^\d{1,2}-[A-Za-z]{3}-\d{4}$').hasMatch(t)) return true;
    return false;
  }

  static bool _looksLikeTime(String raw) {
    return RegExp(r'^\d{1,2}:\d{2}(:\d{2})?$').hasMatch(raw.trim());
  }

  static bool _looksLikeStatus(String raw) {
    final t = raw.trim().toLowerCase();
    return t == 'draft' ||
        t == 'paid' ||
        t == 'posted' ||
        t == 'partial' ||
        t == 'cancel' ||
        t == 'cancelled' ||
        t == 'unpaid';
  }

  static String _normalizeDate(String raw) {
    final t = raw.trim();
    final iso = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(t);
    if (iso != null) return t;
    final dmy = RegExp(r'^(\d{1,2})[/-](\d{1,2})[/-](\d{2,4})$').firstMatch(t);
    if (dmy != null) {
      final d = int.parse(dmy.group(1)!);
      final m = int.parse(dmy.group(2)!);
      var y = int.parse(dmy.group(3)!);
      if (y < 100) y += 2000;
      return '${y.toString().padLeft(4, '0')}-'
          '${m.toString().padLeft(2, '0')}-'
          '${d.toString().padLeft(2, '0')}';
    }
    return t;
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
    final login = email.trim();
    final pass = password;
    if (login.isEmpty || pass.isEmpty) {
      if (kDebugMode) {
        debugPrint(
          'EmployeePerformanceWebApi: missing credentials '
          'emailEmpty=${login.isEmpty} passEmpty=${pass.isEmpty}',
        );
      }
      return null;
    }

    final base = AppConfig.webViewBaseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.isEmpty) return null;

    final client = http.Client();
    final cookies = <String, String>{};
    final bearer = (apiToken ?? AuthSessionStore.currentApiToken).trim();

    try {
      final loginGet = await _request(
        client,
        method: 'GET',
        uri: Uri.parse('$base/login'),
        cookies: cookies,
        bearerToken: bearer,
      );
      _storeCookies(cookies, loginGet.headers);
      final loginToken =
          _extractCsrf(loginGet.body) ?? _xsrfFromCookies(cookies);
      if (loginToken == null || loginToken.isEmpty) {
        if (kDebugMode) {
          debugPrint('EmployeePerformanceWebApi: no login CSRF');
        }
        client.close();
        return null;
      }

      final loginPost = await _request(
        client,
        method: 'POST',
        uri: Uri.parse('$base/login'),
        cookies: cookies,
        form: {
          '_token': loginToken,
          'email': login,
          'login': login,
          'password': pass,
        },
        xsrfToken: _xsrfFromCookies(cookies) ?? loginToken,
        bearerToken: bearer,
        followRedirects: false,
        referer: '$base/login',
      );
      _storeCookies(cookies, loginPost.headers);
      final loginLoc = loginPost.headers['location'];
      final loginOk = _looksLoggedIn(
        statusCode: loginPost.statusCode,
        location: loginLoc,
        body: loginPost.body,
      );
      if (!loginOk) {
        if (kDebugMode) {
          debugPrint(
            'EmployeePerformanceWebApi: web login failed '
            'HTTP ${loginPost.statusCode} loc=$loginLoc',
          );
        }
        client.close();
        return null;
      }

      if (loginLoc != null && loginLoc.isNotEmpty && !_isLoginUrl(loginLoc)) {
        final next = loginLoc.startsWith('http')
            ? Uri.parse(loginLoc)
            : Uri.parse(
                '$base${loginLoc.startsWith('/') ? '' : '/'}$loginLoc',
              );
        final land = await _request(
          client,
          method: 'GET',
          uri: next,
          cookies: cookies,
          bearerToken: bearer,
          referer: '$base/login',
          followRedirects: true,
        );
        _storeCookies(cookies, land.headers);
      }

      if (kDebugMode) {
        debugPrint(
          'EmployeePerformanceWebApi: web session ok '
          'cookies=${cookies.keys.join(",")}',
        );
      }
      return _WebSession(
        client: client,
        base: base,
        cookies: cookies,
        bearer: bearer,
      );
    } catch (e, s) {
      if (kDebugMode) debugPrint('EmployeePerformanceWebApi.open: $e\n$s');
      client.close();
      return null;
    }
  }

  Future<List<InvoiceSummaryModel>> getWorkerBills({
    required int workerId,
    String? workerName,
    DateTime? dateFrom,
    DateTime? dateTo,
  }) async {
    final qp = <String, String>{};
    if (dateFrom != null) {
      qp['date_from'] = EmployeePerformanceWebApi._ymd(dateFrom);
      qp['from'] = EmployeePerformanceWebApi._ymd(dateFrom);
    }
    if (dateTo != null) {
      qp['date_to'] = EmployeePerformanceWebApi._ymd(dateTo);
      qp['to'] = EmployeePerformanceWebApi._ymd(dateTo);
    }
    final path = '/employee-performance/$workerId/bills';
    final query = qp.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    final uri = qp.isEmpty ? path : '$path?$query';
    final html = await getHtml(uri);
    if (html == null || html.isEmpty) return const [];
    final bills = EmployeePerformanceWebApi.parseBillsHtml(
      html,
      billedBy: workerName,
    );
    if (kDebugMode) {
      debugPrint(
        'EmployeePerformanceWebApi: worker=$workerId bills=${bills.length} '
        'range=${qp['date_from'] ?? "-"}..${qp['date_to'] ?? "-"}',
      );
    }
    return bills;
  }

  Future<String?> getHtml(String pathOrUrl) async {
    try {
      final uri = pathOrUrl.startsWith('http')
          ? Uri.parse(pathOrUrl)
          : Uri.parse(
              '$base${pathOrUrl.startsWith('/') ? '' : '/'}$pathOrUrl',
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
      if (res.statusCode < 200 || res.statusCode >= 400) {
        if (kDebugMode) {
          debugPrint(
            'EmployeePerformanceWebApi: GET $uri HTTP ${res.statusCode}',
          );
        }
        return null;
      }
      final html = res.body;
      final looksLikeLogin = html.contains('Login —') &&
          !html.contains('employee-performance') &&
          !html.contains('Employee Performance');
      if (looksLikeLogin) {
        if (kDebugMode) {
          debugPrint('EmployeePerformanceWebApi: GET $uri got login page');
        }
        return null;
      }
      return html;
    } catch (e, s) {
      if (kDebugMode) debugPrint('EmployeePerformanceWebApi.getHtml: $e\n$s');
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
    int attempt = 0,
  }) async {
    final headers = <String, String>{
      'Accept': 'text/html,application/xhtml+xml',
      'User-Agent': SessionHelper.jsonUserAgent,
      'Connection': 'keep-alive',
    };
    if (referer != null && referer.isNotEmpty) {
      headers['Referer'] = referer;
    }
    final token = (bearerToken ?? '').trim();
    if (token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    final xsrf = (xsrfToken ?? _xsrfFromCookies(cookies) ?? '').trim();
    if (xsrf.isNotEmpty) {
      headers['X-XSRF-TOKEN'] = xsrf;
      headers['X-CSRF-TOKEN'] = xsrf;
    }
    if (cookies.isNotEmpty) {
      headers['Cookie'] =
          cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
    }

    try {
      late final http.Response res;
      if (method == 'POST') {
        headers['Content-Type'] = 'application/x-www-form-urlencoded';
        res = await client
            .post(
              uri,
              headers: headers,
              body: form ?? const <String, String>{},
            )
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
    } catch (e) {
      if (attempt < 2) {
        await Future<void>.delayed(Duration(milliseconds: 400 * (attempt + 1)));
        return _request(
          client,
          method: method,
          uri: uri,
          cookies: cookies,
          form: form,
          xsrfToken: xsrfToken,
          bearerToken: bearerToken,
          referer: referer,
          followRedirects: followRedirects,
          attempt: attempt + 1,
        );
      }
      rethrow;
    }
  }

  static void _storeCookies(
    Map<String, String> jar,
    Map<String, String> headers,
  ) {
    void absorb(String? raw) {
      if (raw == null || raw.isEmpty) return;
      for (final piece in raw.split(RegExp(r',(?=[^ ;]+=)'))) {
        final part = piece.split(';').first;
        final eq = part.indexOf('=');
        if (eq <= 0) continue;
        jar[part.substring(0, eq).trim()] = part.substring(eq + 1).trim();
      }
    }

    absorb(headers['set-cookie']);
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'set-cookie') absorb(entry.value);
    }
  }

  static String? _extractCsrf(String html) {
    final patterns = <RegExp>[
      RegExp(r'name="_token"\s+value="([^"]+)"', caseSensitive: false),
      RegExp(r'name="csrf-token"\s+content="([^"]+)"', caseSensitive: false),
      RegExp(r'csrf-token"\s+content="([^"]+)"', caseSensitive: false),
    ];
    for (final re in patterns) {
      final m = re.firstMatch(html);
      final v = m?.group(1)?.trim();
      if (v != null && v.isNotEmpty) return v;
    }
    return null;
  }

  static String? _xsrfFromCookies(Map<String, String> cookies) {
    for (final key in const ['XSRF-TOKEN', 'xsrf-token']) {
      final raw = cookies[key];
      if (raw == null || raw.isEmpty) continue;
      try {
        return Uri.decodeComponent(raw);
      } catch (_) {
        return raw;
      }
    }
    return null;
  }

  static bool _isLoginUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('/login') || lower.endsWith('login');
  }

  static bool _looksLoggedIn({
    required int statusCode,
    required String? location,
    required String body,
  }) {
    if (location != null && location.isNotEmpty && !_isLoginUrl(location)) {
      return true;
    }
    if (statusCode >= 200 &&
        statusCode < 400 &&
        body.contains('Logout') &&
        !body.contains('Login —')) {
      return true;
    }
    if (statusCode >= 300 && statusCode < 400) {
      return location != null && !_isLoginUrl(location);
    }
    return false;
  }
}
