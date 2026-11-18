import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
// Android CookieManager needs a real URL + raw cookie values; the public
// WebViewCookie helper encodes values and passes a bare host, which breaks
// Laravel session cookies (and SSO) on IP hosts.
// ignore: implementation_imports
import 'package:webview_flutter_android/src/android_webkit.g.dart'
    as android_webkit;

import '../../models/invoice_summary_model.dart';
import '../../viewModels/login_viewmodel.dart';
import '../services/WebApi/web_api_impl.dart';
import '../services/api_request_helper.dart';
import '../services/appConfig.dart';
import '../services/auth_session_store.dart';
import '../services/endPoints.dart';
import '../services/flutter_customer_invoice_web_api.dart';
import 'add_to_customer.dart';
import '../theme.dart';

/// Opens the same Laravel pharmacy website used by the Flutter APIs.
class CustomerWebViewPage extends StatefulWidget {
  const CustomerWebViewPage({super.key});

  static String get baseUrl {
    final raw = AppConfig.webViewBaseUrl.trim();
    if (raw.endsWith('/')) return raw.substring(0, raw.length - 1);
    return raw;
  }

  static String get cookieOrigin => '$baseUrl/';
  static String get homeUrl => '$baseUrl/';
  static String get loginUrl => '$baseUrl/login';

  @override
  State<CustomerWebViewPage> createState() => _CustomerWebViewPageState();
}

class _CustomerWebViewPageState extends State<CustomerWebViewPage> {
  WebViewController? _controller;
  late final WebViewCookieManager _cookieManager;

  bool _isLoading = true;
  bool _signingIn = true;
  /// Hybrid composition draws above Flutter overlays — keep the platform
  /// WebView out of the tree until SSO has landed off /login.
  bool _webViewVisible = false;
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
          // Avoid bridge/JS work during hidden SSO — it races hybrid composition
          // teardown and can throw on the JavaScriptChannel pigeon handler.
          if (_signingIn || !_webViewVisible) {
            await _tryAutoLoginIfNeeded(url);
            return;
          }
          await _injectInvoiceTracker();
        },
        onWebResourceError: (error) {
          if (!mounted || error.isForMainFrame != true) return;
          if (_signingIn) {
            debugPrint('[CustomerWebView] load error during SSO: ${error.description}');
            return;
          }
          setState(() {
            _error = error.description;
            _isLoading = false;
            _signingIn = false;
          });
        },
        onNavigationRequest: (request) {
          final url = request.url.toLowerCase();
          final baseHost =
              Uri.tryParse(CustomerWebViewPage.baseUrl)?.host.toLowerCase();
          final host = Uri.tryParse(url)?.host.toLowerCase();
          // Stay on the pharmacy website; allow login + in-app navigation.
          if (baseHost != null &&
              host != null &&
              host.isNotEmpty &&
              host != baseHost) {
            debugPrint('[CustomerWebView] blocked external: ${request.url}');
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ),
    );

    if (!mounted) return;
    setState(() => _controller = controller);
    // Let the 1×1 platform view attach before the first navigation.
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!mounted) return;
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

  String? _autoLoginEmail;
  String? _autoLoginPassword;
  bool _autoLoginAttempted = false;

  bool _isLoginPageUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('/login');
  }

  String _cookieValueForWebView(String raw) {
    // Prefer the decoded form browsers store/send. Raw Set-Cookie lines may
    // still be percent-encoded from the HTTP jar.
    if (!raw.contains('%')) return raw;
    try {
      return Uri.decodeComponent(raw);
    } catch (_) {
      return raw;
    }
  }

  Future<void> _applyWebsiteCookies(Map<String, String> cookies) async {
    final origin = CustomerWebViewPage.cookieOrigin;
    final host = Uri.tryParse(CustomerWebViewPage.baseUrl)?.host;
    if (host == null || host.isEmpty) return;

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final cm = android_webkit.CookieManager.instance;
      for (final entry in cookies.entries) {
        if (entry.key.isEmpty) continue;
        final value = _cookieValueForWebView(entry.value);
        try {
          // Full URL required; do not re-encode Laravel cookie payloads.
          await cm.setCookie(origin, '${entry.key}=$value; Path=/');
        } catch (e) {
          debugPrint('[CustomerWebView] setCookie ${entry.key}: $e');
        }
      }
      // Let CookieManager settle before the first authenticated navigation.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return;
    }

    for (final entry in cookies.entries) {
      if (entry.key.isEmpty) continue;
      try {
        await _cookieManager.setCookie(
          WebViewCookie(
            name: entry.key,
            value: _cookieValueForWebView(entry.value),
            domain: host,
            path: '/',
          ),
        );
      } catch (e) {
        debugPrint('[CustomerWebView] setCookie ${entry.key}: $e');
      }
    }
  }

  Future<void> _tryAutoLoginIfNeeded(String url) async {
    final controller = _controller;
    final email = (_autoLoginEmail ?? '').trim();
    final password = _autoLoginPassword ?? '';
    if (controller == null) return;

    // Authenticated — keep WebView hidden until _openInvoices reveals it.
    if (!_isLoginPageUrl(url)) {
      if (mounted && _signingIn) {
        setState(() => _status = 'Website ready');
      }
      return;
    }

    // Still on /login — fill+submit while WebView is 1×1 (no flash).
    if (email.isEmpty || password.isEmpty || _autoLoginAttempted) return;
    _autoLoginAttempted = true;
    final emailJs = jsonEncode(email);
    final passwordJs = jsonEncode(password);
    try {
      await controller.runJavaScript('''
(function tryLogin(attempt) {
  var email = document.querySelector('input[name="email"], #email');
  var password = document.querySelector('input[name="password"], #password');
  var form = document.querySelector('form.login-form, form[action*="login"], form');
  if (!email || !password || !form) {
    if (attempt < 25) setTimeout(function () { tryLogin(attempt + 1); }, 120);
    return;
  }
  email.focus();
  email.value = $emailJs;
  password.value = $passwordJs;
  email.dispatchEvent(new Event('input', { bubbles: true }));
  password.dispatchEvent(new Event('input', { bubbles: true }));
  var btn = form.querySelector('button[type="submit"], input[type="submit"], button');
  if (btn) { btn.click(); } else { form.submit(); }
})(0);
''');
      if (mounted) {
        setState(() => _status = 'Signing in to website…');
      }
    } catch (e) {
      debugPrint('[CustomerWebView] auto-login inject err: $e');
      _autoLoginAttempted = false;
    }
  }

  Future<bool> _waitUntilAuthenticated({
    required WebViewController controller,
    required bool allowFormFallback,
  }) async {
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (!mounted) return false;
      final current = await controller.currentUrl() ?? '';
      if (current.isNotEmpty && !_isLoginPageUrl(current)) {
        return true;
      }
      if (allowFormFallback && (i == 1 || i == 8 || i == 16)) {
        _autoLoginAttempted = false;
        await _tryAutoLoginIfNeeded(
          current.isEmpty ? CustomerWebViewPage.loginUrl : current,
        );
      }
    }
    final landed = await controller.currentUrl() ?? '';
    return landed.isNotEmpty && !_isLoginPageUrl(landed);
  }

  Future<void> _revealWebView() async {
    if (!mounted) return;
    setState(() {
      _signingIn = false;
      _webViewVisible = true;
      _status = 'Website ready';
    });
    // One more frame so layout expands 1×1 → full before injecting trackers.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    await _injectInvoiceTracker();
    unawaited(_prefetchInvoiceNumbers());
  }

  Future<void> _openInvoices() async {
    final controller = _controller;
    if (controller == null || !mounted || _busy) return;
    _busy = true;

    setState(() {
      _signingIn = true;
      _webViewVisible = false;
      _isLoading = true;
      _error = null;
      _status = 'Signing in to website…';
      _onInvoiceForm = false;
      _currentMoveId = null;
      _currentInvoiceNumber = null;
      _currentBillIsPaid = false;
    });

    final vm = context.read<LoginViewmodel>();
    var login = (vm.loginEmail ?? '').trim();
    var password = vm.loginPassword ?? '';
    if (login.isEmpty || password.isEmpty) {
      final saved = await AuthSessionStore.load();
      login = (saved?.email ?? login).trim();
      if (password.isEmpty) password = saved?.password ?? '';
    }
    _autoLoginEmail = login;
    _autoLoginPassword = password;
    _autoLoginAttempted = false;

    try {
      await _cookieManager.clearCookies();

      // Cookie SSO is best-effort on Android IP hosts; form login in a 1×1
      // WebView is the reliable path and never paints the login screen.
      var cookieSso = false;
      if (login.isNotEmpty && password.isNotEmpty) {
        final cookies =
            await FlutterCustomerInvoiceWebApi.obtainWebsiteSessionCookies(
          email: login,
          password: password,
          apiToken: AuthSessionStore.currentApiToken.isNotEmpty
              ? AuthSessionStore.currentApiToken
              : vm.sessionId,
          forceRefresh: true,
        );
        if (cookies != null && cookies.isNotEmpty) {
          await _applyWebsiteCookies(cookies);
          cookieSso = true;
          if (kDebugMode) {
            debugPrint(
              '[CustomerWebView] SSO cookies applied (${cookies.keys.join(', ')})',
            );
          }
        }
      }

      if (cookieSso) {
        if (mounted) setState(() => _status = 'Opening website…');
        final waitHome = _waitForPage(CustomerWebViewPage.baseUrl);
        await controller.loadRequest(Uri.parse(CustomerWebViewPage.homeUrl));
        await waitHome;
        if (!mounted) return;
        final current = await controller.currentUrl() ?? '';
        if (current.isNotEmpty && !_isLoginPageUrl(current)) {
          await _revealWebView();
          return;
        }
        if (kDebugMode) {
          debugPrint(
            '[CustomerWebView] cookie SSO bounced to login — form login in 1x1',
          );
        }
      }

      // Hidden form login with the same app credentials.
      _autoLoginAttempted = false;
      if (mounted) setState(() => _status = 'Signing in to website…');
      final loginTarget = login.isNotEmpty && password.isNotEmpty
          ? CustomerWebViewPage.loginUrl
          : CustomerWebViewPage.homeUrl;
      final waitLogin = _waitForPage(CustomerWebViewPage.baseUrl);
      await controller.loadRequest(Uri.parse(loginTarget));
      await waitLogin;
      if (!mounted) return;

      await _tryAutoLoginIfNeeded(loginTarget);
      final ok = await _waitUntilAuthenticated(
        controller: controller,
        allowFormFallback: login.isNotEmpty && password.isNotEmpty,
      );
      if (!mounted) return;
      if (kDebugMode) {
        debugPrint('[CustomerWebView] auth ok=$ok url=${await controller.currentUrl()}');
      }
      await _revealWebView();
    } catch (e, st) {
      debugPrint('[CustomerWebView] failed: $e\n$st');
      if (!mounted) return;
      setState(() {
        _signingIn = false;
        _webViewVisible = true;
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
        : 'Website';

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
          // Hybrid composition paints above Flutter widgets and often ignores
          // negative offsets — keep a 1×1 attached WebView during SSO so /login
          // cannot flash, then expand to full size after /home.
          if (_error == null && controller != null)
            Positioned(
              left: 0,
              top: 0,
              width: _webViewVisible ? MediaQuery.sizeOf(context).width : 1,
              height: _webViewVisible
                  ? MediaQuery.sizeOf(context).height
                  : 1,
              child: _buildWebView(controller),
            ),
          if (_signingIn || (!_webViewVisible && _error == null))
            Positioned.fill(
              child: ColoredBox(
                color: Colors.white,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(
                        color: Color(0xFF00BCF8),
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
          if (!_signingIn && _webViewVisible && _isLoading && _error == null)
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
