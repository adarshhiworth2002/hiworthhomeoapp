import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:homeocr26/features/services/WebApi/web_api.dart';
import 'package:http/http.dart';

import '../appConfig.dart';
import '../endPoints.dart';
import '../session_helper.dart';

class WebApiImpl implements WebAPI {

  @override
  Future<Response> login({required Map<String, dynamic> userDetails}) async {
    if (kDebugMode) {
      print('url::: ${AppConfig.baseAppUrl}${EndPoint.login.path}');
    }
    print(userDetails);
    final response = await post(
        Uri.parse('${AppConfig.baseAppUrl}${EndPoint.login.path}'),
        headers: <String, String>{
          'Content-Type': 'application/json'
        },
        body: jsonEncode(userDetails));
    print({"----${response.body}---"});
    return response;
  }

  @override
  Future<Response> qrFetch({required Map<String, dynamic> userDetails,required String sessionId}) async {
    if (kDebugMode) {
      print('cccc ${AppConfig.baseAppUrl}${EndPoint.qrFetch.path}');
    }
    print(userDetails);
    final response = await post(
        Uri.parse('${AppConfig.baseAppUrl}${EndPoint.qrFetch.path}'),
        headers: <String, String>{
          'Content-Type': 'application/json',
          'Cookie': SessionHelper.cookie(sessionId),
        },
        body: jsonEncode(userDetails));
    return response;
  }

  @override
  Future<Response> addMedicineQty(
      {required Map<String, dynamic> userDetails,required String sessionId}) async {
    print('${AppConfig.baseAppUrl}${EndPoint.addMedicineQty.path}');
    print(userDetails);
    final response = await post(
        Uri.parse('${AppConfig.baseAppUrl}${EndPoint.addMedicineQty.path}'),
        headers: <String, String>{
          'Content-Type': 'application/json',
          'Cookie': SessionHelper.cookie(sessionId),
        },
        body: jsonEncode(userDetails));
    return response;
  }

  @override
  Future<Response> fetchInvoiceList({
    required String endpointPath,
    required Map<String, dynamic> userDetails,
    required String sessionId,
    Duration timeout = const Duration(seconds: 60),
    bool logResponseBody = true,
  }) async {
    if (kDebugMode) {
      print('${AppConfig.baseAppUrl}$endpointPath');
      print(userDetails);
    }
    final response = await post(
      Uri.parse('${AppConfig.baseAppUrl}$endpointPath'),
      headers: <String, String>{
        'Content-Type': 'application/json',
        'Cookie': SessionHelper.cookie(sessionId),
        'Connection': 'keep-alive',
      },
      body: jsonEncode(userDetails),
    ).timeout(timeout);
    if (kDebugMode) {
      if (logResponseBody) {
        final body = response.body;
        if (body.length > 4000) {
          print(
            '$endpointPath response: ${body.substring(0, 4000)}… '
            '(${body.length} chars truncated)',
          );
        } else {
          print('$endpointPath response: $body');
        }
      } else {
        print(
          '$endpointPath response: HTTP ${response.statusCode}, '
          '${response.bodyBytes.length} bytes',
        );
      }
    }
    return response;
  }

  @override
  Future<Response> addMedicineQtySupplier(
      {required Map<String, dynamic> userDetails,required String sessionId}) async {
    print('${AppConfig.baseAppUrl}${EndPoint.supplierAdd.path}');
    print(userDetails);
    final response = await post(
        Uri.parse('${AppConfig.baseAppUrl}${EndPoint.supplierAdd.path}'),
        headers: <String, String>{
          'Content-Type': 'application/json',
          'Cookie': SessionHelper.cookie(sessionId),
        },
        body: jsonEncode(userDetails));
    print(":::::::${response.body}:::::");
    return response;
  }

}