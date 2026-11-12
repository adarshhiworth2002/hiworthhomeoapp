import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../features/services/WebApi/web_api_impl.dart';
import '../features/services/api_request_helper.dart';
import '../features/services/auth_session_store.dart';
import '../features/services/cheque_clearance_service.dart';
import '../features/services/cheque_notification_service.dart';
import '../features/services/invoice_detail_service.dart';
import '../features/services/invoice_search_service.dart';
import '../features/services/payment_book_service.dart';
import '../features/services/payment_history_service.dart';
import 'customer_invoice_viewmodel.dart';
import 'employee_performance_viewmodel.dart';
import 'stock_viewmodel.dart';

class LoginViewmodel extends ChangeNotifier {
  final http.Client httpClient;

  LoginViewmodel({http.Client? client, SavedAuth? saved})
      : httpClient = client ?? http.Client() {
    applySaved(saved);
  }

  bool userLoginLoading = false;
  String loginError = '';
  String? sessionId;
  String? userName;
  /// Laravel Sanctum token when login returns `data.token` / `token`.
  String? apiToken;

  /// Kept in memory so Odoo `/web` can be opened with a real browser session.
  String? loginEmail;
  String? loginPassword;
  static const String dbName = 'HOMEO_JULY';

  bool get isLoggedIn =>
      (sessionId ?? '').trim().isNotEmpty &&
      (loginEmail ?? '').trim().isNotEmpty;

  Future<String> userLogin({
    required String email,
    required String password,
  }) async {
    try {
      userLoginLoading = true;
      notifyListeners();

      final requestBody = ApiRequestHelper.loginCall(
        db: dbName,
        login: email,
        password: password,
      );

      final webApi = WebApiImpl();

      http.Response response = await webApi.login(userDetails: requestBody);

      print('userLogin API Response: ${response.body}');

      if (response.statusCode == 200) {
        final jsonData = json.decode(response.body);
        if (jsonData is! Map) {
          sessionId = null;
          userName = null;
          apiToken = null;
          loginError = 'Failed to  User Login';
          return loginError;
        }
        final respo = Map<String, dynamic>.from(jsonData);
        print('object $jsonData ');

        // Odoo-wrapped: { result: { status, session_id, ... } }
        // Laravel flat: { status, session_id, name, data: { token } }
        final payload = respo['result'] is Map
            ? Map<String, dynamic>.from(respo['result'] as Map)
            : respo;

        final status = '${payload['status'] ?? ''}'.trim().toLowerCase();
        if (status == 'error' || status == 'fail' || status == 'failed') {
          return '${payload['message'] ?? 'Failed to  User Login'}';
        }
        if (respo.containsKey('error') && payload['session_id'] == null) {
          sessionId = null;
          loginError = 'Failed to  User Login';
          userName = null;
          apiToken = null;
          return loginError;
        }

        final sid = '${payload['session_id'] ?? payload['session'] ?? ''}'.trim();
        final dataNode = payload['data'];
        String token = '';
        if (dataNode is Map) {
          token = '${dataNode['token'] ?? dataNode['api_token'] ?? ''}'.trim();
        }
        if (token.isEmpty) {
          token = '${payload['token'] ?? payload['api_token'] ?? ''}'.trim();
        }
        // Sanctum-only login: use token as session key so the app stays logged in.
        final effectiveSid = sid.isNotEmpty ? sid : token;
        if (effectiveSid.isEmpty) {
          sessionId = null;
          userName = null;
          apiToken = null;
          loginError = 'Failed to  User Login';
          return loginError;
        }

        sessionId = effectiveSid;
        userName = _extractLoginDisplayName(payload, email);
        apiToken = token.isNotEmpty ? token : null;
        loginEmail = email;
        loginPassword = password;
        await AuthSessionStore.save(
          sessionId: sessionId,
          userName: userName,
          email: email,
          password: password,
          apiToken: apiToken,
        );
        InvoiceSearchService.clearCache();
        InvoiceDetailService.clearCache();
        PaymentHistoryService.clearCache();
        PaymentHistoryService.clearTrustedTotals();
        PaymentBookService.clearCache();
        ChequeClearanceService.clearCache();
        ChequeNotificationService.resetSession();
        CustomerInvoiceViewModel.clearGlobalCache();
        EmployeePerformanceViewModel.clearGlobalCache();
        StockViewModel.clearGlobalCache();
        return 'success';
      } else {
        sessionId = null;
        userName = null;
        apiToken = null;
        loginError = 'error User Login';
        return loginError;
      }
    } catch (e, s) {
      print(s);
      sessionId = null;
      apiToken = null;
      loginError = 'Error  User Login:';
      return loginError;
    } finally {
      userLoginLoading = false;
      notifyListeners();
    }

    // --- Login failure handling we added (Flutter API + website fallback). ---
    // Kept commented so the original login above stays active.
    //
    // final login = email.trim();
    // final pass = password;
    // try {
    //   userLoginLoading = true;
    //   loginError = '';
    //   notifyListeners();
    //
    //   try {
    //     if (await _loginViaFlutterApi(login: login, password: pass)) {
    //       return 'success';
    //     }
    //   } catch (e, s) {
    //     if (kDebugMode) {
    //       debugPrint('Flutter /api/flutter/login failed: $e\n$s');
    //     }
    //   }
    //
    //   try {
    //     if (await _loginViaWebAuthenticate(login: login, password: pass)) {
    //       return 'success';
    //     }
    //   } catch (e, s) {
    //     if (kDebugMode) {
    //       debugPrint('Web authenticate failed: $e\n$s');
    //     }
    //     loginError = _loginErrorMessage(e);
    //     sessionId = null;
    //     userName = null;
    //     return loginError;
    //   }
    //
    //   sessionId = null;
    //   userName = null;
    //   if (loginError.isEmpty) {
    //     loginError = 'Invalid username or password';
    //   }
    //   return loginError;
    // } catch (e, s) {
    //   if (kDebugMode) debugPrint('userLogin: $e\n$s');
    //   sessionId = null;
    //   userName = null;
    //   loginError = _loginErrorMessage(e);
    //   return loginError;
    // } finally {
    //   userLoginLoading = false;
    //   notifyListeners();
    // }
  }

  // Future<bool> _loginViaFlutterApi({
  //   required String login,
  //   required String password,
  // }) async {
  //   final response = await WebApiImpl().login(
  //     userDetails: ApiRequestHelper.loginCall(
  //       db: dbName,
  //       login: login,
  //       password: password,
  //     ),
  //   );
  //
  //   if (kDebugMode) {
  //     debugPrint('userLogin API HTTP ${response.statusCode}');
  //   }
  //
  //   if (response.statusCode < 200 || response.statusCode >= 300) {
  //     throw Exception('Login HTTP ${response.statusCode}');
  //   }
  //
  //   final decoded = json.decode(response.body);
  //   if (decoded is! Map<String, dynamic>) {
  //     throw const FormatException('Unexpected login response');
  //   }
  //
  //   if (decoded.containsKey('error')) {
  //     loginError = _odooErrorMessage(decoded['error']) ?? 'Failed to login';
  //     return false;
  //   }
  //
  //   final result = decoded['result'];
  //   if (result is Map && result['status'] == 'error') {
  //     loginError = (result['message'] ?? 'Failed to login').toString();
  //     return false;
  //   }
  //
  //   String? sid;
  //   String? name;
  //   if (result is Map) {
  //     sid = result['session_id']?.toString() ??
  //         result['session']?.toString() ??
  //         result['sid']?.toString();
  //     name = result['name']?.toString() ?? result['username']?.toString();
  //     if (sid == 'false' || sid == 'null') sid = null;
  //   } else if (result is String && result.isNotEmpty && result != 'false') {
  //     sid = result;
  //   }
  //
  //   sid ??= _sessionIdFromCookie(response.headers['set-cookie']);
  //   if (sid == null || sid.isEmpty) {
  //     throw Exception('Login response had no session');
  //   }
  //
  //   _applySession(
  //     session: sid,
  //     name: (name ?? login).trim().isEmpty ? login : name,
  //     email: login,
  //     password: password,
  //   );
  //   return true;
  // }
  //
  // Future<bool> _loginViaWebAuthenticate({
  //   required String login,
  //   required String password,
  // }) async {
  //   final auth = await OdooRpcHelper.webAuthenticate(
  //     db: dbName,
  //     login: login,
  //     password: password,
  //   );
  //   if (auth == null || auth.sessionId.isEmpty) {
  //     loginError = 'Invalid username or password';
  //     return false;
  //   }
  //   _applySession(
  //     session: auth.sessionId,
  //     name: auth.name ?? login,
  //     email: login,
  //     password: password,
  //   );
  //   return true;
  // }
  //
  // void _applySession({
  //   required String session,
  //   required String? name,
  //   required String email,
  //   required String password,
  // }) {
  //   sessionId = session;
  //   userName = name;
  //   loginEmail = email;
  //   loginPassword = password;
  //   loginError = '';
  //   InvoiceSearchService.clearCache();
  //   InvoiceDetailService.clearCache();
  //   PaymentHistoryService.clearCache();
  //   PaymentBookService.clearCache();
  //   ChequeClearanceService.clearCache();
  //   ChequeNotificationService.resetSession();
  //   CustomerInvoiceViewModel.clearGlobalCache();
  //   EmployeePerformanceViewModel.clearGlobalCache();
  //   StockViewModel.clearGlobalCache();
  //   OdooRpcHelper.clearWebSessionCache();
  // }
  //
  // static String? _sessionIdFromCookie(String? setCookie) {
  //   if (setCookie == null || setCookie.isEmpty) return null;
  //   final m = RegExp(r'session_id=([^;]+)').firstMatch(setCookie);
  //   final value = m?.group(1)?.trim();
  //   if (value == null || value.isEmpty) return null;
  //   return value;
  // }
  //
  // static String? _odooErrorMessage(dynamic error) {
  //   if (error is Map) {
  //     final data = error['data'];
  //     if (data is Map && data['message'] != null) {
  //       return data['message'].toString();
  //     }
  //     if (error['message'] != null) return error['message'].toString();
  //   }
  //   return error?.toString();
  // }
  //
  // static String _loginErrorMessage(Object e) {
  //   final text = e.toString().toLowerCase();
  //   if (text.contains('timed out') || text.contains('timeout')) {
  //     return 'Login timed out. Please try again.';
  //   }
  //   if (text.contains('socket') ||
  //       text.contains('connection') ||
  //       text.contains('failed host') ||
  //       text.contains('clientexception') ||
  //       text.contains('network is unreachable') ||
  //       text.contains('connection refused') ||
  //       text.contains('connection reset') ||
  //       text.contains('connection closed') ||
  //       text.contains('software caused connection abort')) {
  //     return 'Cannot reach the server. Check your internet connection and try again.';
  //   }
  //   if (text.contains('format') || text.contains('json')) {
  //     return 'Unexpected server response. Please try again.';
  //   }
    //   return 'Login failed. Please try again.';
    // }

  /// Loads the last login from disk. Session stays until Logout.
  void applySaved(SavedAuth? saved) {
    if (saved == null || !saved.hasCredentials) return;
    sessionId = saved.sessionId;
    userName = saved.userName;
    loginEmail = saved.email;
    loginPassword = saved.password;
    apiToken = saved.apiToken.trim().isEmpty ? null : saved.apiToken.trim();
  }

  Future<void> restoreSession() async {
    applySaved(await AuthSessionStore.load());
    notifyListeners();
  }

  /// Restores saved login. Network refresh must not force a login screen.
  Future<bool> tryAutoLogin() async {
    await restoreSession();
    if (!isLoggedIn) return false;
    final email = (loginEmail ?? '').trim();
    final password = loginPassword ?? '';
    final previousSession = sessionId;
    final previousName = userName;
    final result = await userLogin(email: email, password: password);
    if (result == 'success') return true;
    sessionId = previousSession;
    userName = previousName;
    loginEmail = email;
    loginPassword = password;
    notifyListeners();
    return isLoggedIn;
  }

  /// Laravel often nests the display name under `data` / `user`.
  static String _extractLoginDisplayName(
    Map<String, dynamic> payload,
    String email,
  ) {
    String? pick(dynamic value) {
      final t = '${value ?? ''}'.trim();
      if (t.isEmpty || t == 'null' || t == 'false') return null;
      return t;
    }

    final dataNode = payload['data'];
    final userNode = payload['user'] is Map
        ? Map<String, dynamic>.from(payload['user'] as Map)
        : (dataNode is Map && dataNode['user'] is Map
            ? Map<String, dynamic>.from(dataNode['user'] as Map)
            : null);

    for (final value in [
      payload['name'],
      payload['username'],
      payload['user_name'],
      payload['full_name'],
      payload['display_name'],
      if (dataNode is Map) ...[
        dataNode['name'],
        dataNode['username'],
        dataNode['user_name'],
        dataNode['full_name'],
        dataNode['display_name'],
      ],
      if (userNode != null) ...[
        userNode['name'],
        userNode['username'],
        userNode['user_name'],
        userNode['full_name'],
        userNode['display_name'],
      ],
    ]) {
      final hit = pick(value);
      if (hit != null) return hit;
    }

    final e = email.trim();
    if (e.contains('@')) {
      final local = e.split('@').first.trim();
      if (local.isNotEmpty) return local;
    }
    return e;
  }

  Future<void> logout() async {
    sessionId = null;
    userName = null;
    apiToken = null;
    loginEmail = null;
    loginPassword = null;
    loginError = '';
    InvoiceSearchService.clearCache();
    InvoiceDetailService.clearCache();
    PaymentHistoryService.clearCache();
    PaymentHistoryService.clearTrustedTotals();
    PaymentBookService.clearCache();
    ChequeClearanceService.clearCache();
    ChequeNotificationService.resetSession();
    CustomerInvoiceViewModel.clearGlobalCache();
    EmployeePerformanceViewModel.clearGlobalCache();
    StockViewModel.clearGlobalCache();
    await AuthSessionStore.clear();
    notifyListeners();
  }
}
