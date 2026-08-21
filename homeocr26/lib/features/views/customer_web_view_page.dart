import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../models/invoice_summary_model.dart';
import '../../viewModels/login_viewmodel.dart';
import '../services/WebApi/web_api_impl.dart';
import '../services/api_request_helper.dart';
import '../services/endPoints.dart';
import 'add_to_customer.dart';
import '../theme.dart';

/// Opens Customer Invoices with a real Odoo backend web session.
class CustomerWebViewPage extends StatefulWidget {
  const CustomerWebViewPage({super.key});

  static const baseUrl = 'http://46.37.122.167:8069';
  static const cookieOrigin = '$baseUrl/';
  static const webShellUrl = '$baseUrl/web';

  static const invoiceFormHash =
      'id=1584&action=400&model=account.move&view_type=form&menu_id=251&cids=1';
  static const invoiceListHash =
      'action=400&model=account.move&view_type=list&menu_id=251&cids=1';

  static const invoiceFormUrl = '$webShellUrl#$invoiceFormHash';
  static const invoiceListUrl = '$webShellUrl#$invoiceListHash';

  @override
  State<CustomerWebViewPage> createState() => _CustomerWebViewPageState();
}

class _CustomerWebViewPageState extends State<CustomerWebViewPage> {
  WebViewController? _controller;
  late final WebViewCookieManager _cookieManager;

  bool _isLoading = true;
  bool _signingIn = true;
  bool _busy = false;
  String? _error;
  String _status = 'Signing in…';

  Completer<void>? _pageDone;
  String? _awaitUrlContains;

  /// Only show scanner on an opened individual bill (Odoo form).
  bool _onInvoiceForm = false;
  int? _currentMoveId;
  String? _currentInvoiceNumber;
  bool _currentBillIsPaid = false;
  final Map<int, InvoiceSummaryModel> _invoiceById = {};

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';

  @override
  void initState() {
    super.initState();
    _cookieManager = WebViewCookieManager();
    _initWebView();
  }

  Future<void> _waitForPage(String urlContains) async {
    _awaitUrlContains = urlContains;
    _pageDone = Completer<void>();
    await _pageDone!.future.timeout(
      const Duration(seconds: 45),
      onTimeout: () => throw TimeoutException('Timed out loading $urlContains'),
    );
  }

  void _completePageIfWaiting(String url) {
    final needle = _awaitUrlContains;
    final done = _pageDone;
    if (needle == null || done == null || done.isCompleted) return;
    if (url.contains(needle)) {
      done.complete();
      _awaitUrlContains = null;
    }
  }

  Future<void> _initWebView() async {
    final controller = WebViewController();
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await controller.setBackgroundColor(const Color(0xFFF0F0F0));
    await controller.setUserAgent(_ua);

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final android = controller.platform as AndroidWebViewController;
      final cookies = _cookieManager.platform;
      if (cookies is AndroidWebViewCookieManager) {
        await cookies.setAcceptThirdPartyCookies(android, true);
      }
      try {
        await AndroidWebViewController.enableDebugging(true);
      } catch (_) {}
    }

    await controller.addJavaScriptChannel(
      'FlutterInvoiceBridge',
      onMessageReceived: _onInvoiceBridgeMessage,
    );

    await controller.setNavigationDelegate(
      NavigationDelegate(
        onPageStarted: (url) {
          if (!mounted) return;
          debugPrint('[CustomerWebView] start: $url');
          setState(() => _isLoading = true);
        },
        onPageFinished: (url) async {
          if (!mounted) return;
          debugPrint('[CustomerWebView] finish: $url');
          setState(() => _isLoading = false);
          _completePageIfWaiting(url);
          await _injectInvoiceTracker();
        },
        onWebResourceError: (error) {
          if (!mounted || error.isForMainFrame != true) return;
          setState(() {
            _error = error.description;
            _isLoading = false;
            _signingIn = false;
          });
        },
        onNavigationRequest: (request) {
          final url = request.url.toLowerCase();
          // Never open website homepage or login (frontend_lazy crashes WebView).
          final base = CustomerWebViewPage.baseUrl.toLowerCase();
          if (url.contains('/web/login') ||
              url.contains('/web/signup') ||
              url.contains('/website') ||
              url == base ||
              url == '$base/') {
            debugPrint('[CustomerWebView] blocked: ${request.url}');
            if (mounted && !_signingIn) {
              setState(() {
                _error =
                    'Odoo redirected away from backend UI. Session may be missing.';
                _isLoading = false;
              });
            }
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ),
    );

    if (!mounted) return;
    setState(() => _controller = controller);
    await _openInvoices();
  }

  void _onInvoiceBridgeMessage(JavaScriptMessage message) {
    if (!mounted) return;
    try {
      final decoded = jsonDecode(message.message);
      if (decoded is! Map) return;

      final form = decoded['form'] == true;
      final id = int.tryParse('${decoded['id'] ?? ''}');
      var invoice = (decoded['invoice'] ?? '').toString().trim();
      var isPaid = false;

      if (id != null) {
        final known = _invoiceById[id];
        if (known != null) {
          if (invoice.isEmpty) {
            invoice = (known.invoiceNumber ?? '').trim();
          }
          isPaid = known.sectionKey == 'paid';
        }
      }

      // Strip "0501/2026-27 - customer" → "0501/2026-27"
      final match = RegExp(r'(\d+/\d{4}-\d{2})').firstMatch(invoice);
      if (match != null) invoice = match.group(1)!;

      if (_onInvoiceForm == form &&
          _currentMoveId == id &&
          (_currentInvoiceNumber ?? '') == invoice &&
          _currentBillIsPaid == isPaid) {
        return;
      }

      setState(() {
        _onInvoiceForm = form;
        _currentMoveId = id;
        _currentInvoiceNumber = invoice.isEmpty ? null : invoice;
        _currentBillIsPaid = isPaid;
      });

      if (form && id != null) {
        if (_invoiceById.containsKey(id)) {
          _applyKnownInvoice(id);
        } else {
          // Resolve number + paid status from API.
          unawaited(_resolveInvoiceNumber(id));
        }
      }
    } catch (e) {
      debugPrint('[CustomerWebView] bridge parse err: $e');
    }
  }

  void _applyKnownInvoice(int moveId) {
    final known = _invoiceById[moveId];
    if (known == null || !mounted) return;
    final number = (known.invoiceNumber ?? '').trim();
    final isPaid = known.sectionKey == 'paid';
    if (number == (_currentInvoiceNumber ?? '') &&
        isPaid == _currentBillIsPaid) {
      return;
    }
    setState(() {
      if (number.isNotEmpty) _currentInvoiceNumber = number;
      _currentBillIsPaid = isPaid;
    });
  }

  Future<void> _injectInvoiceTracker() async {
    final controller = _controller;
    if (controller == null) return;
    await _injectFormResponsiveFixes();
    try {
      await controller.runJavaScript(r'''
(function () {
  if (window.__flutterInvoiceTracker) {
    try { window.__flutterInvoiceTrackerExtract(); } catch (e) {}
    return;
  }
  window.__flutterInvoiceTracker = true;
  function extractInvoice() {
    var hash = location.hash || '';
    var hasFormDom = !!document.querySelector('.o_form_view .o_form_sheet, .o_form_view');
    var listOrKanban = hash.indexOf('view_type=list') >= 0 ||
      hash.indexOf('view_type=kanban') >= 0;
    // Treat as bill form when URL is form OR a form sheet is open (incl. New).
    var isForm = (hash.indexOf('view_type=form') >= 0 || hasFormDom) &&
      !(listOrKanban && !hasFormDom);
    var idMatch = hash.match(/(?:^|[?&#])id=(\d+)/);
    var id = idMatch ? idMatch[1] : null;
    var invoice = '';
    var selectors = [
      '.o_last_breadcrumb_item',
      '.o_breadcrumb .breadcrumb-item.active',
      '.breadcrumb-item.active',
      'span.o_field_char[name="name"]',
      'div[name="name"] span',
      'input[name="name"]',
      '.o_form_view .o_title span',
      '.o_control_panel .o_cp_top_left .o_last_breadcrumb_item'
    ];
    for (var i = 0; i < selectors.length; i++) {
      var el = document.querySelector(selectors[i]);
      if (!el) continue;
      var t = ((el.value || el.textContent) || '').trim();
      var m = t.match(/\d+\/\d{4}-\d{2}/);
      if (m) { invoice = m[0]; break; }
    }
    if (!invoice && document.body) {
      var text = (document.body.innerText || '').replace(/\s+/g, ' ');
      var m2 = text.match(/\b\d{3,5}\/\d{4}-\d{2}\b/);
      if (m2) invoice = m2[0];
    }
    try {
      FlutterInvoiceBridge.postMessage(JSON.stringify({
        form: !!isForm,
        id: id,
        invoice: invoice
      }));
    } catch (e) {}
  }
  window.__flutterInvoiceTrackerExtract = extractInvoice;
  window.addEventListener('hashchange', extractInvoice);
  setInterval(extractInvoice, 1200);
  extractInvoice();
})();
''');
    } catch (e) {
      debugPrint('[CustomerWebView] tracker inject err: $e');
    }
  }

  /// Makes individual bill forms usable on phones:
  /// - Single-column mobile layout (no letter-stacked labels)
  /// - Soft keyboard enabled on all editable fields (same as native app)
  /// - No extra outer boxes around Customer / dropdown fields
  /// - Tables wrap by word and scroll horizontally
  Future<void> _injectFormResponsiveFixes() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.runJavaScript(r'''
(function () {
  function ensureViewport() {
    var meta = document.querySelector('meta[name="viewport"]');
    if (!meta) {
      meta = document.createElement('meta');
      meta.setAttribute('name', 'viewport');
      (document.head || document.documentElement).appendChild(meta);
    }
    var desired =
      'width=device-width, initial-scale=1, maximum-scale=3, user-scalable=yes';
    if (meta.getAttribute('content') !== desired) {
      meta.setAttribute('content', desired);
    }
  }

  function ensureCss() {
    var id = 'flutter-homeocr-form-fix';
    var style = document.getElementById(id);
    if (!style) {
      style = document.createElement('style');
      style.id = id;
      (document.head || document.documentElement).appendChild(style);
    }
    style.textContent = `
      /* Force one field per row — stops vertical letter stacking */
      .o_form_view .o_group,
      .o_form_view .o_inner_group,
      .o_form_view .o_form_sheet .row,
      .o_form_view .o_cell.o_wrap_field,
      .o_form_view .o_wrap_field {
        display: flex !important;
        flex-direction: column !important;
        flex-wrap: nowrap !important;
        width: 100% !important;
        max-width: 100% !important;
        float: none !important;
        box-sizing: border-box !important;
      }
      .o_form_view .o_inner_group > tbody,
      .o_form_view .o_inner_group > tbody > tr,
      .o_form_view .o_group .row {
        display: flex !important;
        flex-direction: column !important;
        width: 100% !important;
      }
      .o_form_view .o_inner_group > tbody > tr > td,
      .o_form_view .o_td_label,
      .o_form_view .o_td_field,
      .o_form_view .o_wrap_label,
      .o_form_view .o_wrap_input,
      .o_form_view .o_cell {
        display: block !important;
        width: 100% !important;
        max-width: 100% !important;
        float: none !important;
        box-sizing: border-box !important;
      }
      .o_form_view .o_form_label,
      .o_form_view label.o_form_label {
        display: block !important;
        width: 100% !important;
        white-space: normal !important;
        word-break: normal !important;
        overflow-wrap: break-word !important;
        writing-mode: horizontal-tb !important;
        text-orientation: mixed !important;
        font-size: 13px !important;
        margin-bottom: 4px !important;
      }
      .o_form_view .o_field_widget,
      .o_form_view .o_input,
      .o_form_view .o_input_dropdown,
      .o_form_view select {
        width: 100% !important;
        max-width: 100% !important;
        box-sizing: border-box !important;
      }

      /* Do NOT draw a second box around Many2One / dropdown wrappers.
         Odoo already styles the inner input — extra border looked like
         duplicate boxes on Customer Name and similar fields. */
      .o_form_view .o_field_many2one,
      .o_form_view .o_field_many2one_selection,
      .o_form_view .o_field_selection,
      .o_form_view .o_input_dropdown,
      .o_form_view .o_field_widget {
        border: none !important;
        background: transparent !important;
        box-shadow: none !important;
        outline: none !important;
        padding: 0 !important;
        margin: 0 !important;
      }
      .o_form_view .o_field_many2one .o_input,
      .o_form_view .o_field_many2one_selection .o_input,
      .o_form_view .o_input_dropdown .o_input,
      .o_form_view input.o_input,
      .o_form_view textarea.o_input,
      .o_form_view select.o_input {
        min-height: 44px !important;
        font-size: 16px !important; /* avoids iOS zoom; matches app field size */
      }

      /* Hide Odoo list / kanban (grid) view switcher */
      .o_cp_switch_buttons,
      .o_cp_switch_buttons .btn,
      .o_switch_view,
      button.o_switch_view,
      .o_control_panel .o_cp_switch_buttons,
      .o_cp_action_menus .o_switch_view {
        display: none !important;
      }

      /* Tables */
      .o_list_view, .o_list_renderer, .o_content,
      .o_notebook_content, .table-responsive {
        overflow-x: auto !important;
        -webkit-overflow-scrolling: touch !important;
      }
      table.o_list_table, .o_list_table {
        table-layout: auto !important;
        width: max-content !important;
        min-width: 100% !important;
      }
      table.o_list_table th, table.o_list_table td,
      .o_list_table th, .o_list_table td, .o_data_cell {
        word-break: normal !important;
        overflow-wrap: break-word !important;
        white-space: normal !important;
        writing-mode: horizontal-tb !important;
        font-size: 13px !important;
        padding: 8px 10px !important;
        min-width: 80px !important;
      }
    `;
  }

  /** Keep soft keyboard available (undo prior keyboard-blocking injects). */
  function enableSoftKeyboard() {
    var inputs = document.querySelectorAll(
      '.o_form_view input, .o_form_view textarea, .o_form_view select, ' +
      '.modal-content input, .modal-content textarea, .modal-content select'
    );
    for (var i = 0; i < inputs.length; i++) {
      var inp = inputs[i];
      if (!inp || inp.disabled) continue;

      var field = inp.closest('.o_field_widget');
      var odooReadonly = !!(field && (
        field.classList.contains('o_readonly_modifier') ||
        field.classList.contains('o_field_readonly')
      ));
      if (odooReadonly) continue;

      if (inp.getAttribute('inputmode') === 'none') {
        inp.removeAttribute('inputmode');
        if (inp.hasAttribute('readonly')) {
          inp.removeAttribute('readonly');
        }
      }
      if (inp.dataset.flutterNoKb === '1') {
        delete inp.dataset.flutterNoKb;
        if (inp.hasAttribute('readonly')) {
          inp.removeAttribute('readonly');
        }
      }
    }
  }

  function apply() {
    try { ensureViewport(); } catch (e) {}
    try { ensureCss(); } catch (e) {}
    try { enableSoftKeyboard(); } catch (e) {}
  }

  apply();
  // v2: replaces older inject that hid the keyboard / added outer boxes
  if (!window.__flutterFormUiFixesV2) {
    window.__flutterFormUiFixesV2 = true;
    window.addEventListener('hashchange', apply);
    document.addEventListener('focusin', function () {
      try { enableSoftKeyboard(); } catch (err) {}
    }, true);
    setInterval(apply, 1500);
  }
})();
''');
    } catch (e) {
      debugPrint('[CustomerWebView] form UI inject err: $e');
    }
  }

  Future<void> _prefetchInvoiceNumbers() async {
    if (!mounted) return;
    final loginModel = context.read<LoginViewmodel>();
    final sessionId = loginModel.sessionId ?? '';
    if (sessionId.isEmpty) return;

    final webApi = WebApiImpl();
    for (final state in const ['draft', 'posted', 'paid']) {
      try {
        final response = await webApi.fetchInvoiceList(
          endpointPath: EndPoint.customerInvoiceList.path,
          userDetails: ApiRequestHelper.jsonRpcCall({
            'limit': 100,
            'state': state,
          }),
          sessionId: sessionId,
        );
        if (response.statusCode != 200) continue;
        final body = jsonDecode(response.body);
        if (body is! Map<String, dynamic>) continue;
        for (final inv in InvoiceSummaryModel.parseList(body)) {
          final id = inv.id;
          if (id == null) continue;
          final existing = _invoiceById[id];
          if (existing == null ||
              _sectionPriority(inv) >= _sectionPriority(existing)) {
            _invoiceById[id] = inv;
          }
        }
      } catch (e) {
        debugPrint('[CustomerWebView] prefetch [$state] err: $e');
      }
    }

    final id = _currentMoveId;
    if (!mounted || id == null) return;
    _applyKnownInvoice(id);
  }

  static int _sectionPriority(InvoiceSummaryModel inv) {
    switch (inv.sectionKey) {
      case 'paid':
        return 3;
      case 'open':
        return 2;
      case 'draft':
        return 1;
      default:
        return 0;
    }
  }

  Future<void> _resolveInvoiceNumber(int moveId) async {
    if (_invoiceById.containsKey(moveId)) {
      _applyKnownInvoice(moveId);
      return;
    }
    await _prefetchInvoiceNumbers();
  }

  Future<void> _openScannerForCurrentBill() async {
    if (!_onInvoiceForm) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Open or create a bill first, then scan.'),
        ),
      );
      return;
    }

    // New bills may need a moment before number appears in the form.
    final controller = _controller;
    if (controller != null) {
      try {
        await controller.runJavaScript(
          'window.__flutterInvoiceTrackerExtract && '
          'window.__flutterInvoiceTrackerExtract();',
        );
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }

    final id = _currentMoveId;
    if (id != null) {
      await _resolveInvoiceNumber(id);
    }

    if (_currentBillIsPaid) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This bill is paid. Scanning is not allowed.'),
        ),
      );
      return;
    }

    var number = (_currentInvoiceNumber ?? '').trim();
    if (number.isEmpty && id != null) {
      number = (_invoiceById[id]?.invoiceNumber ?? '').trim();
    }
    if (number.isEmpty) {
      number = await _latestDraftInvoiceNumber() ?? '';
    }

    if (number.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Invoice number not ready yet. Save/create the bill, wait a second, then scan.',
          ),
        ),
      );
      return;
    }

    if (!mounted) return;
    await AddToCustomerPage.showPopup(
      context,
      lockedInvoiceNumber: number,
    );
  }

  Future<String?> _latestDraftInvoiceNumber() async {
    try {
      final login = context.read<LoginViewmodel>();
      final sessionId = login.sessionId ?? '';
      if (sessionId.isEmpty) return null;
      final webApi = WebApiImpl();
      final response = await webApi.fetchInvoiceList(
        endpointPath: EndPoint.customerInvoiceList.path,
        userDetails: ApiRequestHelper.jsonRpcCall({
          'limit': 5,
          'state': 'draft',
        }),
        sessionId: sessionId,
        logResponseBody: false,
      );
      if (response.statusCode != 200) return null;
      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) return null;
      final list = InvoiceSummaryModel.parseList(body);
      if (list.isEmpty) return null;
      return list.first.displayNumber;
    } catch (e) {
      debugPrint('[CustomerWebView] latest draft lookup: $e');
      return null;
    }
  }

  Future<void> _injectCookie(String name, String value) async {
    final cookieUrl =
        (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
            ? CustomerWebViewPage.cookieOrigin
            : '46.37.122.167';
    await _cookieManager.setCookie(
      WebViewCookie(name: name, value: value, domain: cookieUrl, path: '/'),
    );
  }

  Future<String> _authenticate({
    required String db,
    required String login,
    required String password,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 25);
    try {
      final uri = Uri.parse(
        '${CustomerWebViewPage.baseUrl}/web/session/authenticate',
      );
      final req = await client.postUrl(uri);
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.write(
        jsonEncode({
          'jsonrpc': '2.0',
          'params': {'db': db, 'login': login, 'password': password},
        }),
      );

      final res = await req.close().timeout(const Duration(seconds: 30));
      final body = await res.transform(utf8.decoder).join();
      debugPrint(
        '[CustomerWebView] auth ${res.statusCode}: '
        '${body.length > 220 ? '${body.substring(0, 220)}…' : body}',
      );

      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw HttpException('Authenticate HTTP ${res.statusCode}', uri: uri);
      }

      final decoded = jsonDecode(body);
      if (decoded is! Map) throw Exception('Unexpected authenticate response');
      if (decoded['error'] != null) {
        final err = decoded['error'];
        final msg = err is Map
            ? (err['data'] is Map
                ? (err['data']['message'] ?? err['message'])
                : err['message'])
            : err;
        throw Exception(msg ?? 'Authentication error');
      }

      final result = decoded['result'];
      if (result is! Map || result['uid'] == null || result['uid'] == false) {
        throw Exception('Authenticate returned no uid');
      }

      for (final c in res.cookies) {
        if (c.name == 'session_id' && c.value.isNotEmpty) return c.value;
      }
      final headers = res.headers[HttpHeaders.setCookieHeader];
      if (headers != null) {
        for (final raw in headers) {
          final m = RegExp(r'session_id=([^;]+)').firstMatch(raw);
          if (m != null && m.group(1)!.isNotEmpty) return m.group(1)!;
        }
      }
      final sid = result['session_id']?.toString();
      if (sid != null && sid.isNotEmpty) return sid;
      throw Exception('No session_id in authenticate response');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _openInvoices() async {
    final controller = _controller;
    if (controller == null || !mounted || _busy) return;
    _busy = true;

    setState(() {
      _signingIn = true;
      _isLoading = true;
      _error = null;
      _status = 'Signing in…';
    });

    final vm = context.read<LoginViewmodel>();
    final login = (vm.loginEmail ?? '').trim();
    final password = vm.loginPassword ?? '';
    final db = LoginViewmodel.dbName;

    if (login.isEmpty || password.isEmpty) {
      setState(() {
        _signingIn = false;
        _isLoading = false;
        _error =
            'Please log out and log in again, then reopen Customer Invoices.';
      });
      _busy = false;
      return;
    }

    try {
      await _cookieManager.clearCookies();

      final sessionId = await _authenticate(
        db: db,
        login: login,
        password: password,
      );
      debugPrint('[CustomerWebView] session_id=$sessionId');

      setState(() => _status = 'Applying session…');
      await _injectCookie('session_id', sessionId);
      await _injectCookie('frontend_lang', 'en_US');
      await _injectCookie('cids', '1');

      // Also stamp cookies on /web document (IP hosts).
      setState(() => _status = 'Loading Odoo backend…');
      final waitShell = _waitForPage('/web');
      await controller.loadRequest(
        Uri.parse(CustomerWebViewPage.webShellUrl),
        headers: {
          'Cookie': 'session_id=$sessionId; frontend_lang=en_US; cids=1',
        },
      );
      await waitShell;

      await controller.runJavaScript('''
document.cookie = "session_id=$sessionId; path=/";
document.cookie = "frontend_lang=en_US; path=/";
document.cookie = "cids=1; path=/";
''');

      if (!mounted) return;
      setState(() {
        _signingIn = false;
        _status = 'Opening invoices…';
        _onInvoiceForm = false;
        _currentMoveId = null;
        _currentInvoiceNumber = null;
        _currentBillIsPaid = false;
      });

      // Hash routing after /web shell is ready (more reliable than first-hit #url).
      await controller.runJavaScript(
        "window.location.hash = '${CustomerWebViewPage.invoiceListHash}';",
      );
      await _injectInvoiceTracker();
      unawaited(_prefetchInvoiceNumbers());
    } catch (e, st) {
      debugPrint('[CustomerWebView] failed: $e\n$st');
      if (!mounted) return;
      setState(() {
        _signingIn = false;
        _isLoading = false;
        _error = e.toString();
      });
    } finally {
      _busy = false;
      _pageDone = null;
      _awaitUrlContains = null;
    }
  }

  Widget _buildWebView(WebViewController controller) {
    // SurfaceProducer path often paints a blank WebView for heavy sites like Odoo.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return WebViewWidget.fromPlatformCreationParams(
        params: AndroidWebViewWidgetCreationParams(
          controller: controller.platform,
          displayWithHybridComposition: true,
          gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
        ),
      );
    }
    return WebViewWidget(controller: controller);
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final billNumber = (_currentInvoiceNumber ?? '').trim();
    final onBill = _onInvoiceForm && !_signingIn && _error == null;
    // Paid bills cannot be scanned (same rule as Customer Invoice detail).
    final showScanner = onBill && !_currentBillIsPaid;
    final title = onBill && billNumber.isNotEmpty
        ? billNumber
        : 'Customer Invoices';

    return Scaffold(
      backgroundColor: const Color(0xFFF0F0F0),
      appBar: AppBar(
        backgroundColor: sectionBg,
        foregroundColor: sectionText,
        iconTheme: const IconThemeData(color: sectionText),
        title: Text(
          title,
          style: const TextStyle(
            color: sectionText,
            fontWeight: FontWeight.w600,
            fontSize: 18,
          ),
        ),
        actions: [
          // Scanner on unpaid form bills — including newly created drafts.
          if (showScanner)
            IconButton(
              tooltip: billNumber.isEmpty
                  ? 'Scan QR into this bill'
                  : 'Scan into $billNumber',
              icon: const Icon(Icons.qr_code_scanner, color: sectionAccent),
              onPressed: _openScannerForCurrentBill,
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Stack(
          children: [
          if (_error == null && controller != null) _buildWebView(controller),
          if (_signingIn)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.white,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(
                        color: Color(0xFFE07A2F),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _status,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: sectionText),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (!_signingIn && _isLoading && _error == null)
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(minHeight: 2),
            ),
          if (_error != null)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.white,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline,
                            size: 48, color: Colors.redAccent),
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: sectionText),
                        ),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: _openInvoices,
                          child: const Text('Try again'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
