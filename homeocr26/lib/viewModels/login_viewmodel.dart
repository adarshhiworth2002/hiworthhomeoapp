import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../features/services/WebApi/web_api_impl.dart';
import '../features/services/api_request_helper.dart';
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

  LoginViewmodel({http.Client? client})
      : httpClient = client ?? http.Client();


  bool userLoginLoading=false;
String loginError="";
String? sessionId;
String?userName;
  /// Kept in memory so Odoo `/web` can be opened with a real browser session.
  String? loginEmail;
  String? loginPassword;
  static const String dbName = 'HOMEO_JULY';


  Future<String> userLogin({required String email,required String password, }) async {
    try {
      userLoginLoading = true;
      notifyListeners();


      final requestBody = ApiRequestHelper.loginCall(
        db: dbName,
        login: email,
        password: password,
      );


      final webApi = WebApiImpl();


      http.Response response =await webApi.login(userDetails: requestBody);

      print('userLogin API Response: ${response.body}');

      if (response.statusCode == 200) {
        final jsonData = json.decode(response.body);
        Map<String, dynamic> respo = json.decode(response.body);
        if (respo.containsKey("result")) {
          if(respo["result"]["status"]=="error"){
            return respo["result"]["message"];
          }else{
            sessionId=respo["result"]["session_id"];
            userName=respo["result"]["name"];
            loginEmail = email;
            loginPassword = password;
            InvoiceSearchService.clearCache();
            InvoiceDetailService.clearCache();
            PaymentHistoryService.clearCache();
            PaymentBookService.clearCache();
            ChequeClearanceService.clearCache();
            ChequeNotificationService.resetSession();
            CustomerInvoiceViewModel.clearGlobalCache();
            EmployeePerformanceViewModel.clearGlobalCache();
            StockViewModel.clearGlobalCache();
            return "success";
          }
        }
        print("object $jsonData ");
        if (respo.containsKey("error")) {
          sessionId=null;
          loginError = 'Failed to  User Login';
          userName=null;
          return loginError;
        } else {
          sessionId=null;
          loginError = 'Failed to  User Login';
          userName=null;
          return loginError;
          // qrResponse=loadCalendarModel;
          // return "success";
        }
      }
      else {
        sessionId=null;
        userName=null;
        loginError="error User Login";
        return loginError;
      }
    } catch (e, s) {
      print(s);
      sessionId=null;
      loginError = 'Error  User Login:';
      return loginError;
    } finally {
      userLoginLoading = false;
      notifyListeners();
    }
  }


}