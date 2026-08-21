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
        Map<String, dynamic> respo = json.decode(response.body);
        if (respo.containsKey('result')) {
          if (respo['result']['status'] == 'error') {
            return respo['result']['message'];
          } else {
            sessionId = '${respo['result']['session_id'] ?? ''}'.trim();
            userName = '${respo['result']['name'] ?? ''}'.trim();
            loginEmail = email;
            loginPassword = password;
            await AuthSessionStore.save(
              sessionId: sessionId,
              userName: userName,
              email: email,
              password: password,
            );
            InvoiceSearchService.clearCache();
            InvoiceDetailService.clearCache();
            PaymentHistoryService.clearCache();
            PaymentBookService.clearCache();
            ChequeClearanceService.clearCache();
            ChequeNotificationService.resetSession();
            CustomerInvoiceViewModel.clearGlobalCache();
            EmployeePerformanceViewModel.clearGlobalCache();
            StockViewModel.clearGlobalCache();
            return 'success';
          }
        }
        print('object $jsonData ');
        if (respo.containsKey('error')) {
          sessionId = null;
          loginError = 'Failed to  User Login';
          userName = null;
          return loginError;
        } else {
          sessionId = null;
          loginError = 'Failed to  User Login';
          userName = null;
          return loginError;
        }
      } else {
        sessionId = null;
        userName = null;
        loginError = 'error User Login';
        return loginError;
      }
    } catch (e, s) {
      print(s);
      sessionId = null;
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

  Future<void> logout() async {
    sessionId = null;
    userName = null;
    loginEmail = null;
    loginPassword = null;
    loginError = '';
    InvoiceSearchService.clearCache();
    InvoiceDetailService.clearCache();
    PaymentHistoryService.clearCache();
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
