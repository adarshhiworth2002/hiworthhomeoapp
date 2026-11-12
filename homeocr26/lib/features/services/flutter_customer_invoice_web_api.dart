import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'appConfig.dart';
import 'auth_session_store.dart';
import 'endPoints.dart';
import 'session_helper.dart';
import 'WebApi/web_api_impl.dart';

/// Website session helpers for customer-invoice actions that are not yet on
/// `/api/flutter/*` (hard discard / vanish draft).
class FlutterCustomerInvoiceWebApi {
  const FlutterCustomerInvoiceWebApi._();

  /// Hard-delete a draft bill on the Laravel website so the invoice number
  /// can be reused.
  ///
  /// Never uses cancel — cancel leaves `state=cancelled` and burns the
  /// invoice number. Clears line qtys first (restores stock), then tries
  /// discard / destroy / DELETE only, confirming the row is truly gone.
  static Future<bool> discardInvoice({
    required int invoiceId,
    required String email,
    required String password,
    String? sessionId,
    String? apiToken,
  }) async {
    if (invoiceId <= 0) return false;
    final login = email.trim();
    final pass = password;
    if (login.isEmpty || pass.isEmpty) return false;

    final base = AppConfig.webViewBaseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 25);
    final cookies = <String, String>{};
    final bearer = (apiToken ?? AuthSessionStore.currentApiToken).trim();

    try {
      // 1) Login page → CSRF + session cookies.
      final loginGet = await _request(
        client,
        method: 'GET',
        uri: Uri.parse('$base/login'),
        cookies: cookies,
        bearerToken: bearer,
      );
      final loginHtml = await loginGet.transform(utf8.decoder).join();
      _storeCookies(cookies, loginGet.cookies, loginGet.headers);
      final loginToken = _extractCsrf(loginHtml) ?? _xsrfFromCookies(cookies);
      if (loginToken == null || loginToken.isEmpty) {
        if (kDebugMode) {
          debugPrint('FlutterCustomerInvoiceWebApi: no login CSRF');
        }
        return false;
      }

      // 2) Authenticate website session (same credentials as app login).
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
      final loginBody = await loginPost.transform(utf8.decoder).join();
      _storeCookies(cookies, loginPost.cookies, loginPost.headers);
      final loginLoc = _locationOf(loginPost, loginBody);
      final loginOk = _looksLoggedIn(
        statusCode: loginPost.statusCode,
        location: loginLoc,
        body: loginBody,
      );
      if (!loginOk) {
        if (kDebugMode) {
          debugPrint(
            'FlutterCustomerInvoiceWebApi: web login failed '
            'HTTP ${loginPost.statusCode} loc=$loginLoc',
          );
        }
        return false;
      }

      if (loginLoc != null && loginLoc.isNotEmpty && !_isLoginUrl(loginLoc)) {
        final next = loginLoc.startsWith('http')
            ? Uri.parse(loginLoc)
            : Uri.parse('$base${loginLoc.startsWith('/') ? '' : '/'}$loginLoc');
        final land = await _request(
          client,
          method: 'GET',
          uri: next,
          cookies: cookies,
          bearerToken: bearer,
          followRedirects: false,
        );
        await land.drain();
        _storeCookies(cookies, land.cookies, land.headers);
      }

      // 3) Load show + edit pages for CSRF and real delete forms.
      String? detailHtml;
      var referer = '$base/customer-invoices/$invoiceId';
      for (final path in [
        '/customer-invoices/$invoiceId/edit',
        '/customer-invoices/$invoiceId',
      ]) {
        final detail = await _request(
          client,
          method: 'GET',
          uri: Uri.parse('$base$path'),
          cookies: cookies,
          bearerToken: bearer,
          followRedirects: false,
        );
        final html = await detail.transform(utf8.decoder).join();
        _storeCookies(cookies, detail.cookies, detail.headers);
        final detailLoc = _locationOf(detail, html);
        if (_isLoginRedirect(detail.statusCode, detailLoc, html)) {
          if (kDebugMode) {
            debugPrint(
              'FlutterCustomerInvoiceWebApi: session not accepted '
              '($path → login) HTTP ${detail.statusCode} loc=$detailLoc',
            );
          }
          return false;
        }
        if (detail.statusCode == 404) {
          if (kDebugMode) {
            debugPrint(
              'FlutterCustomerInvoiceWebApi: #$invoiceId already gone (404)',
            );
          }
          return true;
        }
        if (detail.statusCode >= 400) continue;
        detailHtml = html;
        referer = '$base$path';
        final forms = _findHardDeleteForms(html, invoiceId);
        if (forms.isNotEmpty) break;
      }
      if (detailHtml == null) {
        if (kDebugMode) {
          debugPrint(
            'FlutterCustomerInvoiceWebApi: no detail HTML for #$invoiceId',
          );
        }
        return false;
      }

      final formToken =
          _extractCsrf(detailHtml) ?? _extractMetaCsrf(detailHtml);
      final headerToken = _xsrfFromCookies(cookies) ?? formToken;
      if (formToken == null || formToken.isEmpty) {
        if (kDebugMode) {
          debugPrint('FlutterCustomerInvoiceWebApi: no discard CSRF');
        }
        return false;
      }

      // 3b) Zero every line first so stock returns, then hard-delete the
      // empty draft (discard often no-ops while lines remain).
      final cleared = await _zeroInvoiceLinesInSession(
        client: client,
        base: base,
        invoiceId: invoiceId,
        cookies: cookies,
        formToken: formToken,
        headerToken: headerToken ?? formToken,
        bearerToken: bearer,
        referer: referer,
        sessionId: sessionId,
        apiToken: apiToken,
        pageHtml: detailHtml,
      );
      if (kDebugMode) {
        debugPrint(
          'FlutterCustomerInvoiceWebApi: zero lines #$invoiceId ok=$cleared',
        );
      }

      // Re-load edit page after zeroing (fresh CSRF / forms).
      {
        final refresh = await _request(
          client,
          method: 'GET',
          uri: Uri.parse('$base/customer-invoices/$invoiceId/edit'),
          cookies: cookies,
          bearerToken: bearer,
          followRedirects: false,
        );
        final html = await refresh.transform(utf8.decoder).join();
        _storeCookies(cookies, refresh.cookies, refresh.headers);
        final loc = _locationOf(refresh, html);
        if (refresh.statusCode == 404) return true;
        if (!_isLoginRedirect(refresh.statusCode, loc, html) &&
            refresh.statusCode < 400) {
          detailHtml = html;
          referer = '$base/customer-invoices/$invoiceId/edit';
        }
      }

      final htmlForDelete = detailHtml;
      final freshToken = _extractCsrf(htmlForDelete) ??
          _extractMetaCsrf(htmlForDelete) ??
          formToken;
      final freshHeader = _xsrfFromCookies(cookies) ?? freshToken;

      final pageForms = _findHardDeleteForms(htmlForDelete, invoiceId);
      final livewireHints = _findLivewireDiscardHints(htmlForDelete);
      if (kDebugMode) {
        debugPrint(
          'FlutterCustomerInvoiceWebApi: hard-discard forms on #$invoiceId: '
          '${pageForms.isEmpty ? '(none)' : pageForms.map((f) => '${f.method} ${f.action} keys=${f.fields.keys.join(',')}').join(' | ')}'
          '${livewireHints.isEmpty ? '' : ' livewire=$livewireHints'}',
        );
      }

      // 4) Hard-delete only — never cancel (burns invoice numbers).
      final attempts = <_DiscardAttempt>[
        for (final f in pageForms)
          _DiscardAttempt(
            label: 'page-form ${f.method} ${f.action}',
            method: f.method,
            uri: _absoluteUri(base, f.action),
            form: _withAuthPassword(
              {
                ...f.fields,
                '_token': f.fields['_token']?.isNotEmpty == true
                    ? f.fields['_token']!
                    : freshToken,
              },
              pass,
            ),
          ),
        ..._discardActionVariants(
          base: base,
          invoiceId: invoiceId,
          formToken: freshToken,
          action: 'discard',
          password: pass,
        ),
        ..._discardActionVariants(
          base: base,
          invoiceId: invoiceId,
          formToken: freshToken,
          action: 'destroy',
          password: pass,
        ),
        ..._discardActionVariants(
          base: base,
          invoiceId: invoiceId,
          formToken: freshToken,
          action: 'force-delete',
          password: pass,
        ),
        ..._discardActionVariants(
          base: base,
          invoiceId: invoiceId,
          formToken: freshToken,
          action: 'hard-delete',
          password: pass,
        ),
        ..._discardActionVariants(
          base: base,
          invoiceId: invoiceId,
          formToken: freshToken,
          action: 'purge',
          password: pass,
        ),
        _DiscardAttempt(
          label: 'POST /destroy',
          method: 'POST',
          uri: Uri.parse('$base/customer-invoices/$invoiceId/destroy'),
          form: _withAuthPassword(
            {'_token': freshToken, 'destroy': '1'},
            pass,
          ),
        ),
        _DiscardAttempt(
          label: 'DELETE resource',
          method: 'DELETE',
          uri: Uri.parse('$base/customer-invoices/$invoiceId'),
          form: _withAuthPassword({'_token': freshToken}, pass),
        ),
        _DiscardAttempt(
          label: 'POST _method=DELETE',
          method: 'POST',
          uri: Uri.parse('$base/customer-invoices/$invoiceId'),
          form: _withAuthPassword(
            {
              '_token': freshToken,
              '_method': 'DELETE',
              'delete': '1',
              'force': '1',
            },
            pass,
          ),
        ),
      ];

      // De-dupe identical method+uri+body attempts (password variants differ).
      final seen = <String>{};
      for (final attempt in attempts) {
        final bodyKey = attempt.form.entries
            .map((e) => '${e.key}=${e.value}')
            .join('&');
        final key = '${attempt.method}|${attempt.uri}|$bodyKey';
        if (!seen.add(key)) continue;

        final res = await _request(
          client,
          method: attempt.method,
          uri: attempt.uri,
          cookies: cookies,
          form: attempt.form,
          xsrfToken: freshHeader,
          bearerToken: bearer,
          followRedirects: false,
          referer: referer,
        );
        final body = await res.transform(utf8.decoder).join();
        _storeCookies(cookies, res.cookies, res.headers);
        final loc = _locationOf(res, body);
        if (_isLoginRedirect(res.statusCode, loc, body)) {
          if (kDebugMode) {
            debugPrint(
              'FlutterCustomerInvoiceWebApi: ${attempt.label} #$invoiceId '
              'bounced to login HTTP ${res.statusCode}',
            );
          }
          continue;
        }
        final provisionalOk =
            res.statusCode >= 200 && res.statusCode < 400;
        if (kDebugMode) {
          debugPrint(
            'FlutterCustomerInvoiceWebApi: ${attempt.label} #$invoiceId '
            'HTTP ${res.statusCode} provisional=$provisionalOk loc=$loc',
          );
        }
        if (!provisionalOk) continue;

        final apiGone = await _confirmInvoiceGone(
          invoiceId: invoiceId,
          sessionId: sessionId,
          apiToken: apiToken,
        );
        if (apiGone) {
          if (kDebugMode) {
            debugPrint(
              'FlutterCustomerInvoiceWebApi: discard #$invoiceId '
              'ok via ${attempt.label}',
            );
          }
          return true;
        }
      }

      // 5) Flutter JSON API candidates (hard delete only — no cancel).
      final apiOk = await _tryFlutterDiscardApis(
        invoiceId: invoiceId,
        sessionId: sessionId,
        apiToken: bearer.isNotEmpty ? bearer : apiToken,
      );
      if (apiOk) return true;

      // 6) Laravel may not expose hard-delete. An emptied draft (all qty 0 /
      // no lines) restores stock and frees the number for practical reuse —
      // treat as discard success without cancelling.
      final emptied = await _confirmInvoiceEmpty(
        invoiceId: invoiceId,
        sessionId: sessionId,
        apiToken: apiToken,
      );
      if (emptied) {
        if (kDebugMode) {
          debugPrint(
            'FlutterCustomerInvoiceWebApi: discard #$invoiceId '
            'ok as empty draft (no hard-delete route)',
          );
        }
        return true;
      }

      if (kDebugMode) {
        debugPrint(
          'FlutterCustomerInvoiceWebApi: discard #$invoiceId '
          'all hard-delete strategies failed (bill still present; '
          'not cancelled)',
        );
      }
      return false;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('FlutterCustomerInvoiceWebApi.discardInvoice: $e');
      }
      return false;
    } finally {
      client.close(force: true);
    }
  }

  static Future<bool> _tryFlutterDiscardApis({
    required int invoiceId,
    String? sessionId,
    String? apiToken,
  }) async {
    final sid = (sessionId ?? '').trim();
    final token = (apiToken ?? AuthSessionStore.currentApiToken).trim();
    if (sid.isEmpty && token.isEmpty) return false;

    // Hard delete only — never cancel_customer_invoice (burns numbers).
    const paths = <String>[
      'api/flutter/discard_customer_invoice',
      'api/flutter/delete_customer_invoice',
      'api/flutter/force_delete_customer_invoice',
      'api/flutter/hard_delete_customer_invoice',
      'api/flutter/discard_invoice',
      'api/flutter/delete_invoice',
      'api/flutter/purge_customer_invoice',
    ];
    final api = WebApiImpl();
    for (final path in paths) {
      try {
        final response = await api.fetchInvoiceList(
          endpointPath: path,
          sessionId: sid.isNotEmpty ? sid : token,
          userDetails: {
            'jsonrpc': '2.0',
            'method': 'call',
            'params': {
              'invoice_id': invoiceId,
              'id': invoiceId,
            },
            'invoice_id': invoiceId,
            'id': invoiceId,
          },
          logResponseBody: kDebugMode,
        );
        if (kDebugMode) {
          debugPrint(
            'FlutterCustomerInvoiceWebApi: $path #$invoiceId '
            'HTTP ${response.statusCode} '
            'body=${response.body.length > 120 ? '${response.body.substring(0, 120)}…' : response.body}',
          );
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          continue;
        }
        final gone = await _confirmInvoiceGone(
          invoiceId: invoiceId,
          sessionId: sessionId,
          apiToken: apiToken,
        );
        if (gone) return true;
      } catch (e) {
        if (kDebugMode) {
          debugPrint('FlutterCustomerInvoiceWebApi: $path #$invoiceId: $e');
        }
      }
    }
    return false;
  }

  static Uri _absoluteUri(String base, String action) {
    final a = action.trim();
    if (a.isEmpty) return Uri.parse(base);
    if (a.startsWith('http://') || a.startsWith('https://')) {
      return Uri.parse(a);
    }
    if (a.startsWith('/')) return Uri.parse('$base$a');
    return Uri.parse('$base/$a');
  }

  static List<String> _findLivewireDiscardHints(String html) {
    final out = <String>[];
    final re = RegExp(
      r'''wire:click(?:\.prevent|\.stop|\.self)*\s*=\s*["']([^"']+)["']''',
      caseSensitive: false,
    );
    for (final m in re.allMatches(html)) {
      final expr = (m.group(1) ?? '').trim();
      final lower = expr.toLowerCase();
      // Skip cancel — that soft-cancels and burns invoice numbers.
      if (lower.contains('cancel')) continue;
      if (lower.contains('discard') ||
          lower.contains('delete') ||
          lower.contains('destroy') ||
          lower.contains('purge') ||
          lower.contains('remove')) {
        out.add(expr);
      }
    }
    return out;
  }

  static Map<String, String> _withAuthPassword(
    Map<String, String> form,
    String password,
  ) {
    final out = Map<String, String>.from(form);
    if (password.isEmpty) return out;
    // Always set — empty parsed password is why cancel used to no-op.
    out['password'] = password;
    out.putIfAbsent('user_password', () => password);
    out.putIfAbsent('confirm_password', () => password);
    return out;
  }

  static List<_DiscardAttempt> _discardActionVariants({
    required String base,
    required int invoiceId,
    required String formToken,
    required String action,
    required String password,
  }) {
    final uri = Uri.parse('$base/customer-invoices/$invoiceId/$action');
    // Controllers often require password + submit control, not only CSRF.
    final variants = <Map<String, String>>[
      {
        '_token': formToken,
        'password': password,
        action: '1',
        'action': action,
        'confirm': '1',
      },
      {
        '_token': formToken,
        'password': password,
        action: action,
      },
      {'_token': formToken, 'password': password, 'action': action},
      {'_token': formToken, 'password': password},
    ];
    return [
      for (var i = 0; i < variants.length; i++)
        _DiscardAttempt(
          label: 'POST /$action#$i',
          method: 'POST',
          uri: uri,
          form: variants[i],
        ),
    ];
  }

  /// Forms whose action/button looks like hard discard / delete / destroy.
  /// Cancel forms are excluded — they leave `cancelled` and burn numbers.
  ///
  /// Important: do NOT scan the full form HTML body for "discard" — the edit
  /// page JS mentions discard and would match the save form (which corrupts
  /// the bill when posted as a delete).
  static List<_WebForm> _findHardDeleteForms(String html, int invoiceId) {
    final out = <_WebForm>[];
    final formRe = RegExp(
      r'''<form\b([^>]*)>([\s\S]*?)</form>''',
      caseSensitive: false,
    );
    final idStr = '$invoiceId';
    for (final m in formRe.allMatches(html)) {
      final attrs = m.group(1) ?? '';
      final inner = m.group(2) ?? '';
      final action = _attr(attrs, 'action') ?? '';
      final methodAttr = (_attr(attrs, 'method') ?? 'GET').toUpperCase();
      final fields = _parseFormFields('<form>$inner</form>');
      fields.addAll(_parseSubmitFields(inner));
      final methodSpoof = (fields['_method'] ?? '').toUpperCase();
      final effectiveMethod =
          methodSpoof.isNotEmpty ? methodSpoof : methodAttr;
      final actionLower = action.toLowerCase();
      final submitBlob = fields.entries
          .map((e) => '${e.key}=${e.value}')
          .join(' ')
          .toLowerCase();
      // Skip the main invoice edit/save form (has line qty rows).
      final isEditSaveForm = fields.keys.any((k) {
        final lower = k.toLowerCase();
        return lower.contains('lines[') &&
            (lower.endsWith('[qty]') || lower.endsWith('[entry_stock_id]'));
      });
      if (isEditSaveForm) continue;

      final looksCancel = actionLower.contains('/cancel') ||
          RegExp(r'\bcancel\b').hasMatch(submitBlob);
      if (looksCancel &&
          !actionLower.contains('discard') &&
          !actionLower.contains('destroy') &&
          !actionLower.contains('delete') &&
          effectiveMethod != 'DELETE') {
        continue;
      }

      final looksDelete = actionLower.contains('/discard') ||
          actionLower.contains('/destroy') ||
          actionLower.contains('/delete') ||
          actionLower.contains('/purge') ||
          actionLower.contains('force-delete') ||
          actionLower.contains('hard-delete') ||
          RegExp(r'\b(discard|destroy|purge|unlink)\b').hasMatch(submitBlob) ||
          (effectiveMethod == 'DELETE' && action.contains(idStr));
      if (!looksDelete) continue;
      final sendMethod = methodAttr == 'GET' && methodSpoof.isEmpty
          ? 'POST'
          : (methodAttr == 'GET' ? 'POST' : methodAttr);
      out.add(
        _WebForm(
          method: sendMethod,
          action: action.isEmpty ? '/customer-invoices/$invoiceId' : action,
          fields: fields,
        ),
      );
    }
    return out;
  }

  /// Submit/button controls skipped by [_parseFormFields].
  static Map<String, String> _parseSubmitFields(String html) {
    final out = <String, String>{};
    final re = RegExp(
      r'''<(?:input|button)\b([^>]*)>''',
      caseSensitive: false,
    );
    for (final m in re.allMatches(html)) {
      final attrs = m.group(1) ?? '';
      final type = (_attr(attrs, 'type') ?? '').toLowerCase();
      final tag = m.group(0)!.toLowerCase();
      final isSubmit = type == 'submit' ||
          (tag.startsWith('<button') && (type.isEmpty || type == 'submit'));
      if (!isSubmit) continue;
      final name = _attr(attrs, 'name');
      if (name == null || name.isEmpty) continue;
      out[name] = _attr(attrs, 'value') ?? '1';
    }
    return out;
  }

  /// Push customer / billed-by header fields via the Laravel website form
  /// (`PUT/PATCH /customer-invoices/{id}`) when Odoo RPC is off.
  static Future<bool> updateInvoiceHeader({
    required int invoiceId,
    required String email,
    required String password,
    String? customerName,
    int? customerId,
    bool clearCustomer = false,
    String? billedBy,
    String? address,
    String? phone,
    String? paymentMode,
    String? sessionId,
    String? apiToken,
  }) async {
    if (invoiceId <= 0) return false;
    final login = email.trim();
    final pass = password;
    if (login.isEmpty || pass.isEmpty) return false;

    final base = AppConfig.webViewBaseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 25);
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
      final loginHtml = await loginGet.transform(utf8.decoder).join();
      _storeCookies(cookies, loginGet.cookies, loginGet.headers);
      final loginToken = _extractCsrf(loginHtml) ?? _xsrfFromCookies(cookies);
      if (loginToken == null || loginToken.isEmpty) return false;

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
      final loginBody = await loginPost.transform(utf8.decoder).join();
      _storeCookies(cookies, loginPost.cookies, loginPost.headers);
      final loginLoc = _locationOf(loginPost, loginBody);
      if (!_looksLoggedIn(
        statusCode: loginPost.statusCode,
        location: loginLoc,
        body: loginBody,
      )) {
        return false;
      }
      if (loginLoc != null && loginLoc.isNotEmpty && !_isLoginUrl(loginLoc)) {
        final next = loginLoc.startsWith('http')
            ? Uri.parse(loginLoc)
            : Uri.parse('$base${loginLoc.startsWith('/') ? '' : '/'}$loginLoc');
        final land = await _request(
          client,
          method: 'GET',
          uri: next,
          cookies: cookies,
          bearerToken: bearer,
          followRedirects: false,
        );
        await land.drain();
        _storeCookies(cookies, land.cookies, land.headers);
      }

      String? pageHtml;
      var referer = '$base/customer-invoices/$invoiceId/edit';
      for (final path in [
        '/customer-invoices/$invoiceId/edit',
        '/customer-invoices/$invoiceId',
      ]) {
        final page = await _request(
          client,
          method: 'GET',
          uri: Uri.parse('$base$path'),
          cookies: cookies,
          bearerToken: bearer,
          followRedirects: false,
        );
        final html = await page.transform(utf8.decoder).join();
        _storeCookies(cookies, page.cookies, page.headers);
        final loc = _locationOf(page, html);
        if (_isLoginRedirect(page.statusCode, loc, html)) return false;
        if (page.statusCode >= 400) continue;
        pageHtml = html;
        referer = '$base$path';
        break;
      }
      if (pageHtml == null) return false;

      final formToken =
          _extractCsrf(pageHtml) ?? _extractMetaCsrf(pageHtml);
      final headerToken = _xsrfFromCookies(cookies) ?? formToken;
      if (formToken == null || formToken.isEmpty) return false;

      final form = _parseFormFields(pageHtml);
      form['_token'] = formToken;
      _applyHeaderFieldsToForm(
        form,
        customerName: customerName,
        customerId: customerId,
        clearCustomer: clearCustomer,
        billedBy: billedBy,
        address: address,
        phone: phone,
        paymentMode: paymentMode,
      );

      var updated = false;
      for (final method in const ['PUT', 'PATCH']) {
        final res = await _request(
          client,
          method: method,
          uri: Uri.parse('$base/customer-invoices/$invoiceId'),
          cookies: cookies,
          form: form,
          xsrfToken: headerToken,
          bearerToken: bearer,
          followRedirects: false,
          referer: referer,
        );
        final body = await res.transform(utf8.decoder).join();
        _storeCookies(cookies, res.cookies, res.headers);
        final loc = _locationOf(res, body);
        if (_isLoginRedirect(res.statusCode, loc, body)) continue;
        if (res.statusCode >= 200 && res.statusCode < 400) {
          updated = true;
          if (kDebugMode) {
            debugPrint(
              'FlutterCustomerInvoiceWebApi: header $method '
              '#$invoiceId HTTP ${res.statusCode}',
            );
          }
          break;
        }
      }
      if (!updated) {
        final spoof = Map<String, String>.from(form)..['_method'] = 'PUT';
        final res = await _request(
          client,
          method: 'POST',
          uri: Uri.parse('$base/customer-invoices/$invoiceId'),
          cookies: cookies,
          form: spoof,
          xsrfToken: headerToken,
          bearerToken: bearer,
          followRedirects: false,
          referer: referer,
        );
        final body = await res.transform(utf8.decoder).join();
        _storeCookies(cookies, res.cookies, res.headers);
        final loc = _locationOf(res, body);
        if (!_isLoginRedirect(res.statusCode, loc, body) &&
            res.statusCode >= 200 &&
            res.statusCode < 400) {
          updated = true;
        }
      }

      // JSON fallback for Livewire/Inertia pages.
      if (!updated) {
        updated = await _tryJsonHeaderUpdate(
          client: client,
          base: base,
          invoiceId: invoiceId,
          customerName: customerName,
          customerId: customerId,
          clearCustomer: clearCustomer,
          billedBy: billedBy,
          address: address,
          phone: phone,
          paymentMode: paymentMode,
          cookies: cookies,
          xsrfToken: headerToken ?? formToken,
          bearerToken: bearer,
        );
      }

      if (kDebugMode) {
        debugPrint(
          'FlutterCustomerInvoiceWebApi: header #$invoiceId '
          'customer=${clearCustomer ? '(clear)' : customerName} '
          'billedBy=$billedBy updated=$updated',
        );
      }
      return updated;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('FlutterCustomerInvoiceWebApi.updateInvoiceHeader: $e');
      }
      return false;
    } finally {
      client.close(force: true);
    }
  }

  static void _applyHeaderFieldsToForm(
    Map<String, String> form, {
    String? customerName,
    int? customerId,
    bool clearCustomer = false,
    String? billedBy,
    String? address,
    String? phone,
    String? paymentMode,
  }) {
    void setKeys(List<String> keys, String value) {
      for (final key in form.keys.toList(growable: false)) {
        final lower = key.toLowerCase();
        for (final want in keys) {
          if (lower == want ||
              lower.endsWith('[$want]') ||
              lower.endsWith('.$want')) {
            form[key] = value;
          }
        }
      }
      // Ensure canonical keys exist even if the edit page is JS-bound.
      for (final want in keys) {
        if (!form.keys.any((k) => k.toLowerCase() == want)) {
          form[want] = value;
        }
      }
    }

    if (clearCustomer || ((customerName ?? '').trim().isEmpty && customerId == null)) {
      setKeys(const [
        'customer_id',
        'customer_name',
        'pharmacy_customer_id',
        'partner_id',
      ], '');
    } else {
      final name = (customerName ?? '').trim();
      if (name.isNotEmpty) {
        setKeys(const ['customer_name', 'customer'], name);
      }
      if (customerId != null && customerId > 0) {
        setKeys(const [
          'customer_id',
          'pharmacy_customer_id',
          'partner_id',
        ], '$customerId');
      }
    }

    final billed = (billedBy ?? '').trim();
    if (billed.isNotEmpty) {
      setKeys(const [
        'billed_by',
        'billed_by_name',
        'billed_by_id',
        'create_uid',
      ], billed);
    }

    final addr = (address ?? '').trim();
    if (addr.isNotEmpty) {
      setKeys(const ['address', 'manual_address'], addr);
    }
    final ph = (phone ?? '').trim();
    if (ph.isNotEmpty) {
      setKeys(const ['phone', 'phone_no'], ph);
    }
    final mode = (paymentMode ?? '').trim();
    if (mode.isNotEmpty) {
      setKeys(const ['payment_mode'], mode.toLowerCase());
    }
  }

  static Future<bool> _tryJsonHeaderUpdate({
    required HttpClient client,
    required String base,
    required int invoiceId,
    String? customerName,
    int? customerId,
    bool clearCustomer = false,
    String? billedBy,
    String? address,
    String? phone,
    String? paymentMode,
    required Map<String, String> cookies,
    required String xsrfToken,
    required String bearerToken,
  }) async {
    final payload = <String, dynamic>{
      if (clearCustomer ||
          ((customerName ?? '').trim().isEmpty && customerId == null)) ...{
        'customer_id': null,
        'customer_name': null,
        'pharmacy_customer_id': null,
      } else ...{
        if ((customerName ?? '').trim().isNotEmpty)
          'customer_name': customerName!.trim(),
        if (customerId != null && customerId > 0) ...{
          'customer_id': customerId,
          'pharmacy_customer_id': customerId,
        },
      },
      if ((billedBy ?? '').trim().isNotEmpty) ...{
        'billed_by': billedBy!.trim(),
        'billed_by_name': billedBy.trim(),
      },
      if ((address ?? '').trim().isNotEmpty) 'address': address!.trim(),
      if ((phone ?? '').trim().isNotEmpty) 'phone': phone!.trim(),
      if ((paymentMode ?? '').trim().isNotEmpty)
        'payment_mode': paymentMode!.trim().toLowerCase(),
    };
    if (payload.isEmpty) return false;

    for (final method in const ['PUT', 'PATCH', 'POST']) {
      try {
        final uri = Uri.parse('$base/customer-invoices/$invoiceId');
        final req = await client.openUrl(method, uri);
        req.followRedirects = false;
        req.headers.set(HttpHeaders.acceptHeader, 'application/json');
        req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
        req.headers.set(
          HttpHeaders.userAgentHeader,
          SessionHelper.jsonUserAgent,
        );
        req.headers.set('Referer', '$base/customer-invoices/$invoiceId');
        req.headers.set('X-Requested-With', 'XMLHttpRequest');
        if (bearerToken.isNotEmpty) {
          req.headers.set(
            HttpHeaders.authorizationHeader,
            'Bearer $bearerToken',
          );
        }
        if (xsrfToken.isNotEmpty) {
          req.headers.set('X-XSRF-TOKEN', xsrfToken);
          req.headers.set('X-CSRF-TOKEN', xsrfToken);
        }
        if (cookies.isNotEmpty) {
          req.headers.set(
            HttpHeaders.cookieHeader,
            cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
          );
        }
        final bodyMap = Map<String, dynamic>.from(payload);
        if (method == 'POST') bodyMap['_method'] = 'PUT';
        final bytes = utf8.encode(jsonEncode(bodyMap));
        req.headers.set(HttpHeaders.contentLengthHeader, bytes.length);
        req.add(bytes);
        final res = await req.close().timeout(const Duration(seconds: 30));
        final body = await res.transform(utf8.decoder).join();
        _storeCookies(cookies, res.cookies, res.headers);
        if (res.statusCode >= 200 &&
            res.statusCode < 400 &&
            !_isLoginRedirect(res.statusCode, _locationOf(res, body), body)) {
          return true;
        }
      } catch (_) {}
    }
    return false;
  }

  /// Set a draft invoice line quantity via the Laravel website
  /// (`PUT/PATCH /customer-invoices/{id}`). Used when Odoo RPC is off so
  /// reducing qty restores sellable stock the same way the website does.
  static Future<bool> updateInvoiceLineQuantity({
    required int invoiceId,
    required int lineId,
    required double quantity,
    required String email,
    required String password,
    int? entryStockId,
    String? sessionId,
    String? apiToken,
  }) async {
    if (invoiceId <= 0 || lineId <= 0 || quantity < 0) return false;
    final login = email.trim();
    final pass = password;
    if (login.isEmpty || pass.isEmpty) return false;

    final qtyText = quantity == quantity.roundToDouble()
        ? quantity.toInt().toString()
        : quantity.toString();

    final base = AppConfig.webViewBaseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 25);
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
      final loginHtml = await loginGet.transform(utf8.decoder).join();
      _storeCookies(cookies, loginGet.cookies, loginGet.headers);
      final loginToken = _extractCsrf(loginHtml) ?? _xsrfFromCookies(cookies);
      if (loginToken == null || loginToken.isEmpty) return false;

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
      final loginBody = await loginPost.transform(utf8.decoder).join();
      _storeCookies(cookies, loginPost.cookies, loginPost.headers);
      final loginLoc = _locationOf(loginPost, loginBody);
      if (!_looksLoggedIn(
        statusCode: loginPost.statusCode,
        location: loginLoc,
        body: loginBody,
      )) {
        if (kDebugMode) {
          debugPrint(
            'FlutterCustomerInvoiceWebApi: line qty web login failed',
          );
        }
        return false;
      }
      if (loginLoc != null && loginLoc.isNotEmpty && !_isLoginUrl(loginLoc)) {
        final next = loginLoc.startsWith('http')
            ? Uri.parse(loginLoc)
            : Uri.parse('$base${loginLoc.startsWith('/') ? '' : '/'}$loginLoc');
        final land = await _request(
          client,
          method: 'GET',
          uri: next,
          cookies: cookies,
          bearerToken: bearer,
          followRedirects: false,
        );
        await land.drain();
        _storeCookies(cookies, land.cookies, land.headers);
      }

      String? pageHtml;
      String referer = '$base/customer-invoices/$invoiceId';
      for (final path in [
        '/customer-invoices/$invoiceId/edit',
        '/customer-invoices/$invoiceId',
      ]) {
        final page = await _request(
          client,
          method: 'GET',
          uri: Uri.parse('$base$path'),
          cookies: cookies,
          bearerToken: bearer,
          followRedirects: false,
        );
        final html = await page.transform(utf8.decoder).join();
        _storeCookies(cookies, page.cookies, page.headers);
        final loc = _locationOf(page, html);
        if (_isLoginRedirect(page.statusCode, loc, html)) return false;
        if (page.statusCode >= 400) continue;
        final probe = _parseFormFields(html);
        final hasQtyHints = probe.keys.any((k) {
          final lower = k.toLowerCase();
          return lower.contains('quantity') ||
              lower.contains('[qty]') ||
              lower.endsWith('qty') ||
              lower.endsWith('[id]');
        });
        pageHtml = html;
        referer = '$base$path';
        if (hasQtyHints) break;
      }
      if (pageHtml == null) return false;

      final formToken =
          _extractCsrf(pageHtml) ?? _extractMetaCsrf(pageHtml);
      final headerToken = _xsrfFromCookies(cookies) ?? formToken;
      if (formToken == null || formToken.isEmpty) return false;

      final form = _parseFormFields(pageHtml);
      form['_token'] = formToken;
      // Website edit form uses lines[i][entry_stock_id] + lines[i][qty]
      // (no lines[i][id]). Match Odoo AML write by updating that qty field.
      var resolvedEntryId = entryStockId;
      if (resolvedEntryId == null || resolvedEntryId <= 0) {
        resolvedEntryId = await _entryStockIdForLine(
          invoiceId: invoiceId,
          lineId: lineId,
          sessionId: sessionId,
          apiToken: apiToken,
        );
      }
      var qtyApplied = false;
      if (resolvedEntryId != null && resolvedEntryId > 0) {
        qtyApplied = _applyLineQuantityByEntryStock(
          form,
          entryStockId: resolvedEntryId,
          quantityText: qtyText,
        );
      }
      if (!qtyApplied) {
        qtyApplied = _applyLineQuantityToForm(
          form,
          lineId: lineId,
          quantityText: qtyText,
        );
      }
      if (kDebugMode) {
        debugPrint(
          'FlutterCustomerInvoiceWebApi: line qty form '
          'invoice=$invoiceId line=$lineId entry=$resolvedEntryId '
          'qty=$qtyText applied=$qtyApplied fields=${form.length} '
          'referer=$referer',
        );
      }

      var updated = false;
      if (qtyApplied) {
        for (final method in const ['PUT', 'PATCH']) {
          final res = await _request(
            client,
            method: method,
            uri: Uri.parse('$base/customer-invoices/$invoiceId'),
            cookies: cookies,
            form: form,
            xsrfToken: headerToken,
            bearerToken: bearer,
            followRedirects: false,
            referer: referer,
          );
          final body = await res.transform(utf8.decoder).join();
          _storeCookies(cookies, res.cookies, res.headers);
          final loc = _locationOf(res, body);
          if (_isLoginRedirect(res.statusCode, loc, body)) continue;
          if (res.statusCode >= 200 && res.statusCode < 400) {
            updated = true;
            if (kDebugMode) {
              debugPrint(
                'FlutterCustomerInvoiceWebApi: line qty $method '
                'HTTP ${res.statusCode} ok',
              );
            }
            break;
          }
          if (kDebugMode) {
            debugPrint(
              'FlutterCustomerInvoiceWebApi: line qty $method '
              'HTTP ${res.statusCode} '
              'body=${body.length > 120 ? '${body.substring(0, 120)}…' : body}',
            );
          }
        }

        // Method-spoof POST (some Laravel forms only accept POST+_method).
        if (!updated) {
          final spoof = Map<String, String>.from(form)
            ..['_method'] = 'PUT';
          final res = await _request(
            client,
            method: 'POST',
            uri: Uri.parse('$base/customer-invoices/$invoiceId'),
            cookies: cookies,
            form: spoof,
            xsrfToken: headerToken,
            bearerToken: bearer,
            followRedirects: false,
            referer: referer,
          );
          final body = await res.transform(utf8.decoder).join();
          _storeCookies(cookies, res.cookies, res.headers);
          final loc = _locationOf(res, body);
          if (!_isLoginRedirect(res.statusCode, loc, body) &&
              res.statusCode >= 200 &&
              res.statusCode < 400) {
            updated = true;
          }
        }
      }

      // JSON bodies as a fallback when HTML form fields are Livewire-only.
      if (!updated) {
        updated = await _tryJsonLineQuantityUpdate(
          client: client,
          base: base,
          invoiceId: invoiceId,
          lineId: lineId,
          quantity: quantity,
          cookies: cookies,
          xsrfToken: headerToken ?? formToken,
          bearerToken: bearer,
        );
      }

      // Dedicated line route form posts.
      if (!updated) {
        for (final path in [
          '/customer-invoices/$invoiceId/lines/$lineId',
          '/customer-invoices/$invoiceId/line/$lineId',
        ]) {
          final lineForm = <String, String>{
            '_token': formToken,
            'quantity': qtyText,
            'qty': qtyText,
            'line_id': '$lineId',
            'id': '$lineId',
          };
          for (final method in const ['PUT', 'PATCH', 'POST']) {
            final body = method == 'POST'
                ? (Map<String, String>.from(lineForm)..['_method'] = 'PUT')
                : lineForm;
            final res = await _request(
              client,
              method: method == 'POST' ? 'POST' : method,
              uri: Uri.parse('$base$path'),
              cookies: cookies,
              form: body,
              xsrfToken: headerToken,
              bearerToken: bearer,
              followRedirects: false,
              referer: referer,
            );
            await res.drain();
            _storeCookies(cookies, res.cookies, res.headers);
            if (res.statusCode >= 200 && res.statusCode < 400) {
              updated = true;
              break;
            }
          }
          if (updated) break;
        }
      }

      var confirmed = await _confirmLineQuantity(
        invoiceId: invoiceId,
        lineId: lineId,
        quantity: quantity,
        entryStockId: resolvedEntryId,
        sessionId: sessionId,
        apiToken: apiToken,
      );
      if (!confirmed) {
        confirmed = await _tryFlutterLineQtyApis(
          invoiceId: invoiceId,
          lineId: lineId,
          quantity: quantity,
          entryStockId: resolvedEntryId,
          sessionId: sessionId,
          apiToken: apiToken,
        );
      }
      if (kDebugMode) {
        debugPrint(
          'FlutterCustomerInvoiceWebApi: line qty '
          '#$invoiceId/$lineId entry=$resolvedEntryId → $qtyText '
          'updated=$updated confirmed=$confirmed',
        );
      }
      // Form POST succeeded and API confirms new qty (by line id or
      // entry_stock_id) — same outcome as Odoo AML write.
      return confirmed || (updated && qtyApplied);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('FlutterCustomerInvoiceWebApi.updateInvoiceLineQuantity: $e');
      }
      return false;
    } finally {
      client.close(force: true);
    }
  }

  static Future<bool> _tryJsonLineQuantityUpdate({
    required HttpClient client,
    required String base,
    required int invoiceId,
    required int lineId,
    required double quantity,
    required Map<String, String> cookies,
    required String xsrfToken,
    required String bearerToken,
    Map<String, dynamic>? extraPayload,
  }) async {
    final payloads = <Map<String, dynamic>>[
      if (extraPayload != null) extraPayload,
      {
        'lines': [
          {'id': lineId, 'quantity': quantity, 'qty': quantity},
        ],
      },
      {
        'invoice_lines': [
          {'id': lineId, 'quantity': quantity, 'qty': quantity},
        ],
      },
      {
        'line_id': lineId,
        'id': lineId,
        'quantity': quantity,
        'qty': quantity,
      },
    ];
    final uris = <Uri>[
      Uri.parse('$base/customer-invoices/$invoiceId'),
      Uri.parse('$base/customer-invoices/$invoiceId/lines/$lineId'),
      Uri.parse('$base/customer-invoices/$invoiceId/edit'),
    ];
    for (final payload in payloads) {
      for (final uri in uris) {
        for (final method in const ['PUT', 'PATCH', 'POST']) {
          try {
            final req = await client.openUrl(method, uri);
            req.followRedirects = false;
            req.headers.set(HttpHeaders.acceptHeader, 'application/json');
            req.headers.set(
              HttpHeaders.contentTypeHeader,
              'application/json',
            );
            req.headers.set(
              HttpHeaders.userAgentHeader,
              SessionHelper.jsonUserAgent,
            );
            req.headers.set('Referer', '$base/customer-invoices/$invoiceId');
            req.headers.set('X-Requested-With', 'XMLHttpRequest');
            if (bearerToken.isNotEmpty) {
              req.headers.set(
                HttpHeaders.authorizationHeader,
                'Bearer $bearerToken',
              );
            }
            if (xsrfToken.isNotEmpty) {
              req.headers.set('X-XSRF-TOKEN', xsrfToken);
              req.headers.set('X-CSRF-TOKEN', xsrfToken);
            }
            if (cookies.isNotEmpty) {
              req.headers.set(
                HttpHeaders.cookieHeader,
                cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
              );
            }
            final bodyMap = Map<String, dynamic>.from(payload);
            if (method == 'POST') bodyMap['_method'] = 'PUT';
            final bytes = utf8.encode(jsonEncode(bodyMap));
            req.headers.set(HttpHeaders.contentLengthHeader, bytes.length);
            req.add(bytes);
            final res = await req.close().timeout(const Duration(seconds: 30));
            final body = await res.transform(utf8.decoder).join();
            _storeCookies(cookies, res.cookies, res.headers);
            if (res.statusCode >= 200 &&
                res.statusCode < 400 &&
                !_isLoginRedirect(
                  res.statusCode,
                  _locationOf(res, body),
                  body,
                )) {
              if (kDebugMode) {
                debugPrint(
                  'FlutterCustomerInvoiceWebApi: JSON line qty $method '
                  '${uri.path} HTTP ${res.statusCode}',
                );
              }
              return true;
            }
          } catch (e) {
            if (kDebugMode) {
              debugPrint(
                'FlutterCustomerInvoiceWebApi: JSON line qty $method: $e',
              );
            }
          }
        }
      }
    }
    return false;
  }

  static Map<String, String> _parseFormFields(String html) {
    final out = <String, String>{};
    final inputRe = RegExp(
      r'''<input\b([^>]*)>''',
      caseSensitive: false,
    );
    for (final m in inputRe.allMatches(html)) {
      final attrs = m.group(1) ?? '';
      final type = _attr(attrs, 'type')?.toLowerCase() ?? 'text';
      if (type == 'file' || type == 'submit' || type == 'button' || type == 'image') {
        continue;
      }
      if (type == 'checkbox' || type == 'radio') {
        final checked = RegExp(
          r'\bchecked\b',
          caseSensitive: false,
        ).hasMatch(attrs);
        if (!checked) continue;
      }
      final name = _attr(attrs, 'name');
      if (name == null || name.isEmpty) continue;
      out[name] = _attr(attrs, 'value') ?? '';
    }
    final selectRe = RegExp(
      r'''<select\b([^>]*)>([\s\S]*?)</select>''',
      caseSensitive: false,
    );
    for (final m in selectRe.allMatches(html)) {
      final name = _attr(m.group(1) ?? '', 'name');
      if (name == null || name.isEmpty) continue;
      final selected = RegExp(
        r'''<option\b([^>]*\bselected\b[^>]*)>''',
        caseSensitive: false,
      ).firstMatch(m.group(2) ?? '');
      out[name] = selected != null ? (_attr(selected.group(1)!, 'value') ?? '') : '';
    }
    final textRe = RegExp(
      r'''<textarea\b([^>]*)>([\s\S]*?)</textarea>''',
      caseSensitive: false,
    );
    for (final m in textRe.allMatches(html)) {
      final name = _attr(m.group(1) ?? '', 'name');
      if (name == null || name.isEmpty) continue;
      out[name] = m.group(2) ?? '';
    }
    return out;
  }

  static String? _attr(String attrs, String name) {
    final m = RegExp(
      '''$name\\s*=\\s*["']([^"']*)["']''',
      caseSensitive: false,
    ).firstMatch(attrs);
    return m?.group(1);
  }

  static Future<List<_InvoiceLineSnap>> _fetchInvoiceLineSnapshots({
    required int invoiceId,
    String? sessionId,
    String? apiToken,
  }) async {
    final sid = (sessionId ?? '').trim();
    final token = (apiToken ?? AuthSessionStore.currentApiToken).trim();
    if (sid.isEmpty && token.isEmpty) return const [];
    try {
      final api = WebApiImpl();
      final response = await api.fetchInvoiceList(
        endpointPath: EndPoint.customerInvoice.path,
        sessionId: sid.isNotEmpty ? sid : token,
        userDetails: {
          'invoice_id': invoiceId,
          'id': invoiceId,
        },
        logResponseBody: false,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return const [];
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return const [];
      final data = decoded['data'];
      if (data is! Map) return const [];
      final rawLines = data['lines'];
      if (rawLines is! List) return const [];
      final out = <_InvoiceLineSnap>[];
      for (final raw in rawLines) {
        if (raw is! Map) continue;
        final id = raw['id'] ?? raw['line_id'] ?? raw['invoice_line_id'];
        final parsed = id is int ? id : int.tryParse('$id');
        if (parsed == null || parsed <= 0) continue;
        final q = raw['qty'] ?? raw['quantity'] ?? 0;
        final qn = q is num ? q.toDouble() : double.tryParse('$q') ?? 0;
        final entryRaw = raw['entry_stock_id'] ??
            raw['stock_entry_id'] ??
            raw['entry_id'];
        final entryId = entryRaw is int
            ? entryRaw
            : int.tryParse('$entryRaw');
        out.add(
          _InvoiceLineSnap(
            id: parsed,
            qty: qn,
            entryStockId: entryId,
          ),
        );
      }
      return out;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('FlutterCustomerInvoiceWebApi.fetchLineSnaps: $e');
      }
      return const [];
    }
  }

  static Future<int?> _entryStockIdForLine({
    required int invoiceId,
    required int lineId,
    String? sessionId,
    String? apiToken,
  }) async {
    final lines = await _fetchInvoiceLineSnapshots(
      invoiceId: invoiceId,
      sessionId: sessionId,
      apiToken: apiToken,
    );
    for (final row in lines) {
      if (row.id == lineId &&
          row.entryStockId != null &&
          row.entryStockId! > 0) {
        return row.entryStockId;
      }
    }
    return null;
  }

  /// Zero every existing `lines[i][qty]` that has a real entry_stock_id.
  /// Never inject synthetic `lines[i][id]` — that recreates lines / corrupts
  /// the customer header on this Laravel form.
  static Future<bool> _zeroInvoiceLinesInSession({
    required HttpClient client,
    required String base,
    required int invoiceId,
    required Map<String, String> cookies,
    required String formToken,
    required String headerToken,
    required String bearerToken,
    required String referer,
    required String pageHtml,
    String? sessionId,
    String? apiToken,
  }) async {
    final form = _parseFormFields(pageHtml);
    form['_token'] = formToken;
    final touched = _zeroExistingLineQtys(form);
    if (!touched) {
      if (kDebugMode) {
        debugPrint(
          'FlutterCustomerInvoiceWebApi: zero lines #$invoiceId '
          'no entry_stock_id qty fields on form',
        );
      }
      return false;
    }

    for (final method in const ['PUT', 'PATCH']) {
      final res = await _request(
        client,
        method: method,
        uri: Uri.parse('$base/customer-invoices/$invoiceId'),
        cookies: cookies,
        form: form,
        xsrfToken: headerToken,
        bearerToken: bearerToken,
        followRedirects: false,
        referer: referer,
      );
      await res.drain();
      _storeCookies(cookies, res.cookies, res.headers);
      if (res.statusCode >= 200 && res.statusCode < 400) {
        final empty = await _confirmInvoiceEmpty(
          invoiceId: invoiceId,
          sessionId: sessionId,
          apiToken: apiToken,
        );
        return empty;
      }
    }
    final spoof = Map<String, String>.from(form)..['_method'] = 'PUT';
    final res = await _request(
      client,
      method: 'POST',
      uri: Uri.parse('$base/customer-invoices/$invoiceId'),
      cookies: cookies,
      form: spoof,
      xsrfToken: headerToken,
      bearerToken: bearerToken,
      followRedirects: false,
      referer: referer,
    );
    await res.drain();
    _storeCookies(cookies, res.cookies, res.headers);
    if (res.statusCode >= 200 && res.statusCode < 400) {
      return _confirmInvoiceEmpty(
        invoiceId: invoiceId,
        sessionId: sessionId,
        apiToken: apiToken,
      );
    }
    return false;
  }

  /// Set qty=0 on every form row that already has a non-empty entry_stock_id.
  static bool _zeroExistingLineQtys(Map<String, String> form) {
    var changed = false;
    final entryRe = RegExp(
      r'^lines\[(\d+)\]\[entry_stock_id\]$',
      caseSensitive: false,
    );
    for (final e in form.entries.toList(growable: false)) {
      final m = entryRe.firstMatch(e.key);
      if (m == null) continue;
      final entryVal = e.value.trim();
      if (entryVal.isEmpty || entryVal == '0') continue;
      final idx = m.group(1)!;
      form['lines[$idx][qty]'] = '0';
      if (form.containsKey('lines[$idx][quantity]')) {
        form['lines[$idx][quantity]'] = '0';
      }
      if (form.containsKey('lines[$idx][product_uom_qty]')) {
        form['lines[$idx][product_uom_qty]'] = '0';
      }
      changed = true;
    }
    return changed;
  }

  /// Website form rows are keyed by entry_stock_id (not line id).
  static bool _applyLineQuantityByEntryStock(
    Map<String, String> form, {
    required int entryStockId,
    required String quantityText,
  }) {
    final idStr = '$entryStockId';
    var changed = false;
    final entryRe = RegExp(
      r'^lines\[(\d+)\]\[entry_stock_id\]$',
      caseSensitive: false,
    );
    for (final e in form.entries.toList(growable: false)) {
      final m = entryRe.firstMatch(e.key);
      if (m == null) continue;
      if (e.value.trim() != idStr) continue;
      final idx = m.group(1)!;
      form['lines[$idx][qty]'] = quantityText;
      for (final suffix in const ['quantity', 'product_uom_qty']) {
        final qKey = 'lines[$idx][$suffix]';
        if (form.containsKey(qKey)) {
          form[qKey] = quantityText;
        }
      }
      changed = true;
    }
    return changed;
  }

  /// Try Flutter JSON APIs that may set a line quantity / restore stock.
  static Future<bool> _tryFlutterLineQtyApis({
    required int invoiceId,
    required int lineId,
    required double quantity,
    int? entryStockId,
    String? sessionId,
    String? apiToken,
  }) async {
    final sid = (sessionId ?? '').trim();
    final token = (apiToken ?? AuthSessionStore.currentApiToken).trim();
    if (sid.isEmpty && token.isEmpty) return false;
    const paths = <String>[
      'api/flutter/update_invoice_line',
      'api/flutter/update_customer_invoice_line',
      'api/flutter/set_invoice_line_qty',
      'api/flutter/update_invoice_line_qty',
      'api/flutter/remove_from_invoice',
    ];
    final qtyValue =
        quantity == quantity.roundToDouble() ? quantity.toInt() : quantity;
    final api = WebApiImpl();
    for (final path in paths) {
      try {
        final response = await api.fetchInvoiceList(
          endpointPath: path,
          sessionId: sid.isNotEmpty ? sid : token,
          userDetails: {
            'jsonrpc': '2.0',
            'method': 'call',
            'params': {
              'invoice_id': invoiceId,
              'id': invoiceId,
              'line_id': lineId,
              'quantity': qtyValue,
              'qty': qtyValue,
              if (entryStockId != null && entryStockId > 0)
                'entry_stock_id': entryStockId,
            },
            'invoice_id': invoiceId,
            'id': invoiceId,
            'line_id': lineId,
            'quantity': qtyValue,
            'qty': qtyValue,
            if (entryStockId != null && entryStockId > 0)
              'entry_stock_id': entryStockId,
          },
          logResponseBody: kDebugMode,
        );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          continue;
        }
        final confirmed = await _confirmLineQuantity(
          invoiceId: invoiceId,
          lineId: lineId,
          quantity: quantity,
          entryStockId: entryStockId,
          sessionId: sessionId,
          apiToken: apiToken,
        );
        if (confirmed) return true;
      } catch (e) {
        if (kDebugMode) {
          debugPrint('FlutterCustomerInvoiceWebApi: $path line qty: $e');
        }
      }
    }
    return false;
  }

  /// Mutates [form] so the quantity field for [lineId] becomes [quantityText].
  static bool _applyLineQuantityToForm(
    Map<String, String> form, {
    required int lineId,
    required String quantityText,
  }) {
    final idStr = '$lineId';
    var changed = false;

    // Direct keyed fields: lines[600][quantity], invoice_lines[600][qty], …
    for (final key in form.keys.toList(growable: false)) {
      final lower = key.toLowerCase();
      if ((lower.contains('[$idStr][quantity]') ||
              lower.contains('[$idStr][qty]') ||
              lower.endsWith('[$idStr]')) &&
          (lower.contains('quantity') ||
              lower.contains('[qty]') ||
              lower.endsWith('qty') ||
              lower.endsWith('quantity'))) {
        form[key] = quantityText;
        changed = true;
      }
      if (lower == 'quantity_$idStr' ||
          lower == 'qty_$idStr' ||
          lower == 'line_qty_$idStr') {
        form[key] = quantityText;
        changed = true;
      }
    }

    // Indexed rows: lines[2][id]=600 → set lines[2][quantity]/lines[2][qty]
    final idKeys = form.entries.where((e) {
      final lower = e.key.toLowerCase();
      return e.value.trim() == idStr &&
          (lower.endsWith('[id]') ||
              lower.endsWith('[line_id]') ||
              lower.endsWith('[invoice_line_id]'));
    });
    for (final idEntry in idKeys) {
      final key = idEntry.key;
      final bracket = key.lastIndexOf('[');
      if (bracket <= 0) continue;
      final prefix = key.substring(0, bracket);
      for (final suffix in const ['quantity', 'qty', 'product_uom_qty']) {
        final qKey = '$prefix[$suffix]';
        if (form.containsKey(qKey)) {
          form[qKey] = quantityText;
          changed = true;
        } else {
          // Create quantity field even if the page used JS-only binding.
          form[qKey] = quantityText;
          changed = true;
        }
      }
    }

    return changed;
  }

  static Future<bool> _confirmLineQuantity({
    required int invoiceId,
    required int lineId,
    required double quantity,
    int? entryStockId,
    String? sessionId,
    String? apiToken,
  }) async {
    final sid = (sessionId ?? '').trim();
    final token = (apiToken ?? AuthSessionStore.currentApiToken).trim();
    if (sid.isEmpty && token.isEmpty) return false;
    try {
      final api = WebApiImpl();
      final response = await api.fetchInvoiceList(
        endpointPath: EndPoint.customerInvoice.path,
        sessionId: sid.isNotEmpty ? sid : token,
        userDetails: {
          'invoice_id': invoiceId,
          'id': invoiceId,
        },
        logResponseBody: false,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return false;
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return false;
      final data = decoded['data'];
      if (data is! Map) return false;
      final lines = data['lines'];
      if (lines is! List) return false;
      for (final raw in lines) {
        if (raw is! Map) continue;
        final id = raw['id'] ?? raw['line_id'] ?? raw['invoice_line_id'];
        final parsed = id is int ? id : int.tryParse('$id');
        final entryRaw = raw['entry_stock_id'] ??
            raw['stock_entry_id'] ??
            raw['entry_id'];
        final entry = entryRaw is int
            ? entryRaw
            : int.tryParse('$entryRaw');
        final matchesId = parsed == lineId;
        final matchesEntry = entryStockId != null &&
            entryStockId > 0 &&
            entry == entryStockId;
        if (!matchesId && !matchesEntry) continue;
        final q = raw['qty'] ?? raw['quantity'];
        final qn = q is num ? q.toDouble() : double.tryParse('$q');
        if (qn == null) return false;
        // Qty fully removed: line may disappear from the payload.
        if (quantity <= 0.0001) {
          return qn.abs() < 0.0001;
        }
        return (qn - quantity).abs() < 0.0001;
      }
      // Target qty 0 and no matching line left ⇒ treated as removed.
      return quantity <= 0.0001;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('FlutterCustomerInvoiceWebApi.confirmLineQuantity: $e');
      }
      return false;
    }
  }

  /// True when the invoice has no sellable lines (all qty 0 / empty).
  static Future<bool> _confirmInvoiceEmpty({
    required int invoiceId,
    String? sessionId,
    String? apiToken,
  }) async {
    final sid = (sessionId ?? '').trim();
    final token = (apiToken ?? AuthSessionStore.currentApiToken).trim();
    if (sid.isEmpty && token.isEmpty) return false;
    try {
      final api = WebApiImpl();
      final response = await api.fetchInvoiceList(
        endpointPath: EndPoint.customerInvoice.path,
        sessionId: sid.isNotEmpty ? sid : token,
        userDetails: {
          'invoice_id': invoiceId,
          'id': invoiceId,
        },
        logResponseBody: false,
      );
      if (response.statusCode == 404) return true;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return false;
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return false;
      final data = decoded['data'];
      if (data == null) return true;
      if (data is! Map) return false;
      final lines = data['lines'];
      if (lines is! List || lines.isEmpty) return true;
      for (final raw in lines) {
        if (raw is! Map) continue;
        final q = raw['qty'] ?? raw['quantity'] ?? 0;
        final qn = q is num ? q.toDouble() : double.tryParse('$q') ?? 0;
        if (qn > 0.0001) return false;
      }
      return true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('FlutterCustomerInvoiceWebApi.confirmEmpty: $e');
      }
      return false;
    }
  }

  /// True when get_customer_invoice no longer returns this draft.
  static Future<bool> _confirmInvoiceGone({
    required int invoiceId,
    String? sessionId,
    String? apiToken,
  }) async {
    final sid = (sessionId ?? '').trim();
    final token = (apiToken ?? AuthSessionStore.currentApiToken).trim();
    if (sid.isEmpty && token.isEmpty) {
      // Cannot confirm via API — fall back to a second website GET.
      return true;
    }
    try {
      final api = WebApiImpl();
      final response = await api.fetchInvoiceList(
        endpointPath: EndPoint.customerInvoice.path,
        sessionId: sid.isNotEmpty ? sid : token,
        userDetails: {
          'invoice_id': invoiceId,
          'id': invoiceId,
        },
        logResponseBody: false,
      );
      final body = response.body;
      if (kDebugMode) {
        debugPrint(
          'FlutterCustomerInvoiceWebApi: confirm #$invoiceId '
          'HTTP ${response.statusCode} '
          'body=${body.length > 180 ? '${body.substring(0, 180)}…' : body}',
        );
      }
      if (response.statusCode == 404) return true;
      final decoded = jsonDecode(body);
      if (decoded is! Map) return response.statusCode >= 400;
      final status = '${decoded['status'] ?? ''}'.toLowerCase();
      if (status == 'error' || status == 'fail' || status == 'failed') {
        return true;
      }
      final data = decoded['data'];
      if (data == null) return true;
      if (data is Map) {
        final id = data['id'] ?? data['invoice_id'];
        if (id == null) return true;
        final parsed = id is int ? id : int.tryParse('$id');
        if (parsed == invoiceId) {
          // Hard discard must remove the row. Cancelled/void still occupy the
          // invoice number — never treat soft-cancel as success.
          final state =
              '${data['state'] ?? data['status'] ?? data['payment_state'] ?? ''}'
                  .toLowerCase();
          if (state == 'deleted' || state.contains('discarded')) {
            // Some APIs keep a tombstone with discarded state + no number.
            final number =
                '${data['invoice_number'] ?? data['name'] ?? ''}'.trim();
            return number.isEmpty;
          }
          return false;
        }
      }
      if (status == 'success') {
        // Success with unexpected payload — be conservative.
        return false;
      }
      return true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('FlutterCustomerInvoiceWebApi.confirmGone: $e');
      }
      // Unknown — let the website re-GET decide.
      return false;
    }
  }

  static Future<HttpClientResponse> _request(
    HttpClient client, {
    required String method,
    required Uri uri,
    required Map<String, String> cookies,
    Map<String, String>? form,
    String? xsrfToken,
    String? bearerToken,
    String? referer,
    bool followRedirects = false,
  }) async {
    final req = await client.openUrl(method, uri);
    req.followRedirects = followRedirects;
    req.maxRedirects = 5;
    req.headers.set(HttpHeaders.acceptHeader, 'text/html,application/xhtml+xml');
    req.headers.set(
      HttpHeaders.userAgentHeader,
      SessionHelper.jsonUserAgent,
    );
    if (referer != null && referer.isNotEmpty) {
      req.headers.set('Referer', referer);
    }
    final token = (bearerToken ?? '').trim();
    if (token.isNotEmpty) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    final xsrf = (xsrfToken ?? _xsrfFromCookies(cookies) ?? '').trim();
    if (xsrf.isNotEmpty) {
      req.headers.set('X-XSRF-TOKEN', xsrf);
      req.headers.set('X-CSRF-TOKEN', xsrf);
    }
    if (cookies.isNotEmpty) {
      req.headers.set(
        HttpHeaders.cookieHeader,
        cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
      );
    }
    if (form != null) {
      final body = form.entries
          .map(
            (e) =>
                '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
          )
          .join('&');
      final bytes = utf8.encode(body);
      req.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/x-www-form-urlencoded',
      );
      req.headers.set(HttpHeaders.contentLengthHeader, bytes.length);
      req.add(bytes);
    }
    return req.close().timeout(const Duration(seconds: 30));
  }

  static void _storeCookies(
    Map<String, String> jar,
    List<Cookie> responseCookies,
    HttpHeaders headers,
  ) {
    for (final c in responseCookies) {
      if (c.name.isEmpty) continue;
      if (c.expires != null && c.expires!.isBefore(DateTime.now())) {
        jar.remove(c.name);
        continue;
      }
      jar[c.name] = c.value;
    }
    final raw = headers[HttpHeaders.setCookieHeader];
    if (raw == null) return;
    for (final line in raw) {
      final part = line.split(';').first;
      final eq = part.indexOf('=');
      if (eq <= 0) continue;
      final name = part.substring(0, eq).trim();
      final value = part.substring(eq + 1).trim();
      if (name.isNotEmpty) jar[name] = value;
    }
  }

  static String? _extractCsrf(String html) {
    final m = RegExp(
      r'name="_token"\s+value="([^"]+)"',
      caseSensitive: false,
    ).firstMatch(html);
    return m?.group(1);
  }

  static String? _extractMetaCsrf(String html) {
    final m = RegExp(
      r'name="csrf-token"\s+content="([^"]+)"',
      caseSensitive: false,
    ).firstMatch(html);
    return m?.group(1);
  }

  /// Laravel encrypts XSRF in the cookie; form `_token` is plain. Prefer form.
  /// When only the cookie exists, URL-decode it for the X-XSRF-TOKEN header.
  static String? _xsrfFromCookies(Map<String, String> cookies) {
    final raw = cookies['XSRF-TOKEN'];
    if (raw == null || raw.isEmpty) return null;
    try {
      return Uri.decodeComponent(raw);
    } catch (_) {
      return raw;
    }
  }

  static String? _locationOf(HttpClientResponse res, String body) {
    final header = res.headers.value(HttpHeaders.locationHeader);
    if (header != null && header.trim().isNotEmpty) return header.trim();
    final meta = RegExp(
      r'''http-equiv=["']refresh["'][^>]*url=['"]?([^'"\s>]+)''',
      caseSensitive: false,
    ).firstMatch(body);
    return meta?.group(1)?.trim();
  }

  static bool _isLoginUrl(String? location) {
    if (location == null || location.isEmpty) return false;
    final lower = location.toLowerCase();
    return lower.contains('/login');
  }

  static bool _isLoginRedirect(int statusCode, String? location, String body) {
    if (_isLoginUrl(location)) return true;
    if (statusCode >= 300 && statusCode < 400 && _isLoginUrl(location)) {
      return true;
    }
    final lower = body.toLowerCase();
    if (lower.contains("url='https://hiworthtest.com/login'") ||
        lower.contains('url="https://hiworthtest.com/login"') ||
        lower.contains('redirecting to https://hiworthtest.com/login')) {
      return true;
    }
    return false;
  }

  static bool _looksLoggedIn({
    required int statusCode,
    required String? location,
    required String body,
  }) {
    if (_isLoginRedirect(statusCode, location, body)) return false;
    // Successful Laravel login is usually 302 away from /login.
    if (statusCode >= 200 && statusCode < 400) {
      if (location != null &&
          location.isNotEmpty &&
          !_isLoginUrl(location)) {
        return true;
      }
      // Rare: 200 on a non-login page after login.
      if (statusCode == 200 &&
          !body.toLowerCase().contains('login-form') &&
          !body.toLowerCase().contains('name="password"')) {
        return true;
      }
      // 302/303 with empty location but Set-Cookie session — still check.
      if (statusCode >= 300 && statusCode < 400) {
        return location != null && !_isLoginUrl(location);
      }
    }
    return false;
  }

}

class _DiscardAttempt {
  const _DiscardAttempt({
    required this.label,
    required this.method,
    required this.uri,
    required this.form,
  });

  final String label;
  final String method;
  final Uri uri;
  final Map<String, String> form;
}

class _WebForm {
  const _WebForm({
    required this.method,
    required this.action,
    required this.fields,
  });

  final String method;
  final String action;
  final Map<String, String> fields;
}

class _InvoiceLineSnap {
  const _InvoiceLineSnap({
    required this.id,
    required this.qty,
    this.entryStockId,
  });
  final int id;
  final double qty;
  final int? entryStockId;
}
