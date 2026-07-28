import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:homeocr26/viewModels/login_viewmodel.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../features/services/WebApi/web_api_impl.dart';
import '../features/services/api_request_helper.dart';
import '../features/services/api_response_helper.dart';
import '../features/services/invoice_search_service.dart';
import '../features/services/qr_data_helper.dart';
import '../features/services/appConfig.dart';
import '../features/services/endPoints.dart';
import '../models/qr_model.dart';

class CustomerMedViewmodel extends ChangeNotifier {
  final http.Client httpClient;

  CustomerMedViewmodel({http.Client? client})
      : httpClient = client ?? http.Client();

  bool qrFetchLoading = false;
  bool addingLoading = false;
  bool userLoginLoading = false;

  String qrFetchError = "";
  String qrValue = "";
  String qrUid = "";
  QrResponseModel? qrResponse;

  /// From the last successful add_to_invoice (draft `name` is often `/`).
  int? lastAddedInvoiceId;
  String? lastAddedInvoiceName;

  /// Stock Quantity = Odoo sellable stock (`available_stock` / `stock_qty`).
  /// This is the same field add_to_invoice uses (`available_stock: 0`).
  double availableScanQuantity(QrData? data) => _odooAvailableStock(data);

  /// Prefer available_stock, then stock_qty / entry — never invoice `quantity`.
  double _odooAvailableStock(QrData? data) {
    if (data == null) return 0;
    if (data.availableStock != null) return data.availableStock!;
    if (data.stockQty != null) return data.stockQty!;
    if (data.warehouseStockQty != null) return data.warehouseStockQty!;
    if (data.entryStockQty != null) return data.entryStockQty!;
    return 0;
  }

  void resetQr() {
    qrValue = "";
    qrUid = "";
    qrFetchError = "";
    qrResponse = null;
    notifyListeners();
  }

  void setQrValue(String value) {
    qrValue = value;
    qrUid = QrDataHelper.extractCustomerQrUid(value) ?? "";
    notifyListeners();
  }

  Future<void> fetchQrDetails(BuildContext context) async {
    try {
      qrFetchLoading = true;
      qrFetchError = "";
      notifyListeners();

      print('cccc ${AppConfig.baseAppUrl}${EndPoint.qrFetch.path}');

      final qrData = qrUid.isNotEmpty
          ? qrUid
          : QrDataHelper.extractCustomerQrUid(qrValue);
      if (qrData == null || qrData.isEmpty) {
        qrFetchError = 'Invalid QR code. Product UID not found.';
        return;
      }
      qrUid = qrData;

      final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
      final webApi = WebApiImpl();
      if (loginModel.sessionId == null || loginModel.sessionId!.isEmpty) {
        qrFetchError = 'Session expired. Please log in again.';
        return;
      }

      final requestBody = ApiRequestHelper.jsonRpcCall({'qr_data': qrData});
      final response = await webApi.qrFetch(
        userDetails: requestBody,
        sessionId: loginModel.sessionId ?? "",
      );

      print('medicine API Response: ${response.body}');

      if (response.statusCode == 200) {
        final Map<String, dynamic> respo = json.decode(response.body);
        print("object $respo");

        if (respo.containsKey("result")) {
          final result = respo["result"];

          if (result is Map && result["status"] == "error") {
            qrFetchError = ApiResponseHelper.errorMessage(
              respo,
              fallback: 'Failed to fetch medicine details',
            );
          } else {
            qrResponse = QrResponseModel.fromJson(respo);
            final data = qrResponse?.result?.data;
            final responseUid = data?.uid;
            if (responseUid != null && responseUid.isNotEmpty) {
              qrUid = responseUid;
            }
            if (kDebugMode) {
              debugPrint(
                'Stock Quantity from API: available_stock=${data?.availableStock} '
                'stock_qty=${data?.warehouseStockQty} '
                'entry_stock_qty=${data?.entryStockQty} '
                'invoice_quantity=${data?.quantity} (not shown) '
                'shown=${availableScanQuantity(data)} '
                'uid=${data?.uid} barcode=${data?.productBarcode}',
              );
            }
          }
        } else if (respo.containsKey("error")) {
          qrFetchError = ApiResponseHelper.errorMessage(
            respo,
            fallback: 'Server error',
          );
        }
      } else {
        qrFetchError =
            'Unable to fetch medicine details (HTTP ${response.statusCode})';
      }
    } catch (e, s) {
      print(s);
      qrFetchError = 'Network error. Please check your connection and try again.';
    } finally {
      qrFetchLoading = false;
      notifyListeners();
    }
  }

  Future<List<String>> searchInvoiceSuggestions(
    BuildContext context,
    String prefix,
  ) async {
    return InvoiceSearchService.searchPrefixes(
      context,
      prefix,
      type: InvoiceSearchType.customer,
    );
  }

  Future<bool> customerInvoiceExists(
    BuildContext context,
    String prefix,
  ) async {
    return InvoiceSearchService.invoicePrefixExists(
      context,
      prefix,
      type: InvoiceSearchType.customer,
    );
  }

  Future<String> addRequiredMedicineQty({
    required double qty,
    required BuildContext context,
    required String invoiceNumber,
  }) async {
    lastAddedInvoiceId = null;
    lastAddedInvoiceName = null;
    try {
      addingLoading = true;
      notifyListeners();
      final loginModel = Provider.of<LoginViewmodel>(context, listen: false);

      final qrData = _resolveAddToInvoiceQrData();
      if (qrData == null || qrData.isEmpty) {
        return 'Invalid QR code. Product identifier not found.';
      }

      final trimmedInvoice = invoiceNumber.trim();
      if (trimmedInvoice.isEmpty) {
        return 'Invoice number is required';
      }

      final webApi = WebApiImpl();
      if (loginModel.sessionId == null || loginModel.sessionId!.isEmpty) {
        return 'Session expired. Please log in again.';
      }

      // Same as home-page / Postman flow:
      // { invoice_number, qr_data, quantity }
      final qtyValue = qty == qty.roundToDouble() ? qty.toInt() : qty;
      final params = <String, dynamic>{
        'invoice_number': trimmedInvoice,
        'qr_data': qrData,
        'quantity': qtyValue,
      };
      if (kDebugMode) {
        debugPrint('add_to_invoice params: $params');
      }

      final response = await webApi.addMedicineQty(
        userDetails: ApiRequestHelper.jsonRpcCall(params),
        sessionId: loginModel.sessionId ?? '',
      );
      print('AddMedicine API Response: ${response.body}');

      if (response.statusCode == 200) {
        final respo = json.decode(response.body) as Map<String, dynamic>;
        print('object $respo');

        if (ApiResponseHelper.isSuccess(respo)) {
          _captureAddInvoiceMeta(respo);
          return 'success';
        }

        var message = ApiResponseHelper.errorMessage(
          respo,
          fallback: 'Failed to add medicine quantity',
        );

        // Home-era retry: if barcode failed, try UID (or the reverse).
        final alt = _alternativeAddQrData(qrData);
        if (alt != null &&
            (message.toLowerCase().contains('insufficient stock') ||
                message.toLowerCase().contains('not found') ||
                message.toLowerCase().contains('item'))) {
          final retryParams = <String, dynamic>{
            'invoice_number': trimmedInvoice,
            'qr_data': alt,
            'quantity': qtyValue,
          };
          if (kDebugMode) {
            debugPrint(
              'add_to_invoice retry with alternate qr_data: $alt '
              '(was $qrData)',
            );
            debugPrint('add_to_invoice params: $retryParams');
          }
          final retry = await webApi.addMedicineQty(
            userDetails: ApiRequestHelper.jsonRpcCall(retryParams),
            sessionId: loginModel.sessionId ?? '',
          );
          print('AddMedicine API Retry Response: ${retry.body}');
          if (retry.statusCode == 200) {
            final retryBody = json.decode(retry.body) as Map<String, dynamic>;
            if (ApiResponseHelper.isSuccess(retryBody)) {
              _captureAddInvoiceMeta(retryBody);
              return 'success';
            }
            message = ApiResponseHelper.errorMessage(
              retryBody,
              fallback: message,
            );
          }
        }

        if (message.contains('entry.stock')) {
          final batch = qrResponse?.result?.data?.batch;
          return 'Server could not find a unique stock entry for this QR. '
              'Check duplicate stock records for batch ${batch ?? qrData}.';
        }
        if (message.toLowerCase().contains('insufficient stock')) {
          final available = respo['result'] is Map
              ? respo['result']['available_stock']
              : null;
          final qrStock = availableScanQuantity(qrResponse?.result?.data);
          return 'Insufficient stock on server '
              '(available: ${available ?? 0}). '
              'QR Stock Quantity is ${_qtyLabel(qrStock)}.';
        }
        return message;
      }
      return 'Unable to add medicine (HTTP ${response.statusCode})';
    } catch (e, s) {
      print(s);
      return 'Network error. Please check your connection and try again.';
    } finally {
      addingLoading = false;
      notifyListeners();
    }
  }

  void _captureAddInvoiceMeta(Map<String, dynamic> respo) {
    final result = respo['result'];
    if (result is! Map) return;
    final idRaw = result['invoice_id'] ?? result['id'];
    if (idRaw is int) {
      lastAddedInvoiceId = idRaw;
    } else {
      lastAddedInvoiceId = int.tryParse(idRaw?.toString() ?? '');
    }
    final name = (result['invoice_name'] ?? result['invoice_number'] ?? '')
        .toString()
        .trim();
    if (name.isNotEmpty) lastAddedInvoiceName = name;
  }

  /// Home / Postman style: prefer product barcode (e.g. BK_a2d250b7), else UID.
  String? _resolveAddToInvoiceQrData() {
    final data = qrResponse?.result?.data;

    final apiBarcode = data?.productBarcode?.trim();
    if (apiBarcode != null && apiBarcode.isNotEmpty) return apiBarcode;

    final scanBarcode = QrDataHelper.extractProductBarcode(qrValue);
    if (scanBarcode != null && scanBarcode.isNotEmpty) return scanBarcode;

    if (qrUid.isNotEmpty) return qrUid;

    final uid = data?.uid?.trim();
    if (uid != null && uid.isNotEmpty) return uid;

    final lineUid = data?.lineUid?.trim();
    if (lineUid != null && lineUid.isNotEmpty) return lineUid;

    return QrDataHelper.extractCustomerQrUid(qrValue);
  }

  String? _alternativeAddQrData(String used) {
    final data = qrResponse?.result?.data;
    final candidates = <String?>[
      data?.uid,
      data?.lineUid,
      qrUid,
      QrDataHelper.extractCustomerQrUid(qrValue),
      data?.productBarcode,
      QrDataHelper.extractProductBarcode(qrValue),
    ];
    for (final candidate in candidates) {
      final trimmed = candidate?.trim();
      if (trimmed != null && trimmed.isNotEmpty && trimmed != used) {
        return trimmed;
      }
    }
    return null;
  }

  static String _qtyLabel(double? value) {
    if (value == null) return '0';
    return value == value.roundToDouble()
        ? value.toInt().toString()
        : value.toString();
  }
}
