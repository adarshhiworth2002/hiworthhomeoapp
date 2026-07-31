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
import '../features/services/label_ocr_parser.dart';
import '../features/services/label_stock_service.dart';
import '../features/services/odoo_rpc_helper.dart';
import '../features/services/qr_data_helper.dart';
import '../features/services/appConfig.dart';
import '../features/services/endPoints.dart';
import '../models/qr_model.dart';
import '../models/stock_item_model.dart';

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

  bool labelOcrLoading = false;
  bool labelScanActive = false;
  bool labelNotFound = false;
  String labelOcrError = "";
  List<StockItemModel> labelStockPool = [];
  String? labelMedicine;
  String? labelPotency;
  String? labelPacking;

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

  void resetLabelScan() {
    labelOcrLoading = false;
    labelScanActive = false;
    labelNotFound = false;
    labelOcrError = "";
    labelStockPool = [];
    labelMedicine = null;
    labelPotency = null;
    labelPacking = null;
    notifyListeners();
  }

  void resetAllScan() {
    resetLabelScan();
    resetQr();
  }

  List<String> get labelMedicineOptions =>
      LabelStockService.uniqueMedicines(labelStockPool);

  List<String> get labelPotencyOptions {
    final med = labelMedicine;
    if (med == null || med.trim().isEmpty) return const [];
    return LabelStockService.potenciesFor(labelStockPool, med);
  }

  List<String> get labelPackingOptions {
    final med = labelMedicine;
    if (med == null || med.trim().isEmpty) return const [];
    return LabelStockService.packingsFor(
      labelStockPool,
      med,
      labelPotency,
    );
  }

  StockItemModel? get selectedLabelStock => LabelStockService.resolveSelection(
        labelStockPool,
        medicine: labelMedicine,
        potency: labelPotency,
        packing: labelPacking,
      );

  double availableLabelStockQuantity() {
    final item = selectedLabelStock;
    if (item == null) return 0;
    return item.availableStock ?? item.stock ?? item.itemQty ?? 0;
  }

  Future<void> applyLabelOcrText(
    BuildContext context,
    String ocrText,
  ) async {
    labelOcrLoading = true;
    labelOcrError = "";
    labelNotFound = false;
    labelScanActive = false;
    notifyListeners();

    try {
      final parsed = LabelOcrParser.parse(ocrText);
      if (kDebugMode) {
        debugPrint(
          'label parsed: name=${parsed.medicineName} '
          'potency=${parsed.potency} packing=${parsed.packing}',
        );
      }
      if (!parsed.hasAnyField) {
        labelNotFound = true;
        labelOcrError = 'Could not read medicine details from the label.';
        return;
      }

      final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
      final sessionId = loginModel.sessionId ?? '';
      if (sessionId.isEmpty) {
        labelOcrError = 'Session expired. Please log in again.';
        return;
      }

      final matches = await LabelStockService.findMatches(sessionId, parsed);
      if (matches.isEmpty) {
        labelNotFound = true;
        labelOcrError = 'Product not found';
        return;
      }

      labelStockPool = matches;
      labelScanActive = true;

      final best = matches.first;
      labelMedicine = best.medicineLabel;

      final parsedPot = parsed.potency?.trim();
      final potencyOptions =
          LabelStockService.potenciesFor(labelStockPool, labelMedicine!);
      if (parsedPot != null &&
          parsedPot.isNotEmpty &&
          potencyOptions.any(
            (p) => p.toLowerCase() == parsedPot.toLowerCase(),
          )) {
        labelPotency = potencyOptions.firstWhere(
          (p) => p.toLowerCase() == parsedPot.toLowerCase(),
        );
      } else if (potencyOptions.length == 1) {
        labelPotency = potencyOptions.first;
      } else {
        labelPotency = best.potency?.trim().isNotEmpty == true
            ? best.potency
            : null;
      }

      final parsedPack = parsed.packing?.trim();
      final packingOptions = LabelStockService.packingsFor(
        labelStockPool,
        labelMedicine!,
        labelPotency,
      );
      if (parsedPack != null &&
          parsedPack.isNotEmpty &&
          packingOptions.any(
            (p) => p.toLowerCase() == parsedPack.toLowerCase(),
          )) {
        labelPacking = packingOptions.firstWhere(
          (p) => p.toLowerCase() == parsedPack.toLowerCase(),
        );
      } else if (packingOptions.length == 1) {
        labelPacking = packingOptions.first;
      } else {
        labelPacking = best.packing?.trim().isNotEmpty == true
            ? best.packing
            : null;
      }
    } catch (e, s) {
      if (kDebugMode) debugPrint('applyLabelOcrText: $e\n$s');
      labelOcrError = 'Failed to read label. Please try again.';
    } finally {
      labelOcrLoading = false;
      notifyListeners();
    }
  }

  Future<void> setLabelMedicine(BuildContext context, String? medicine) async {
    labelMedicine = medicine;
    labelPotency = null;
    labelPacking = null;

    if (medicine != null && medicine.trim().isNotEmpty) {
      final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
      final sessionId = loginModel.sessionId ?? '';
      if (sessionId.isNotEmpty) {
        final rows = await LabelStockService.searchStock(sessionId, medicine);
        if (rows.isNotEmpty) {
          labelStockPool = rows;
        }
      }

      final potencyOptions = labelPotencyOptions;
      if (potencyOptions.length == 1) {
        labelPotency = potencyOptions.first;
      }

      final packingOptions = labelPackingOptions;
      if (packingOptions.length == 1) {
        labelPacking = packingOptions.first;
      }
    }

    notifyListeners();
  }

  void setLabelPotency(String? potency) {
    labelPotency = potency;
    final packingOptions = labelPackingOptions;
    if (packingOptions.length == 1) {
      labelPacking = packingOptions.first;
    } else if (labelPacking != null &&
        !packingOptions.any(
          (p) => p.toLowerCase() == labelPacking!.toLowerCase(),
        )) {
      labelPacking = null;
    }
    notifyListeners();
  }

  void setLabelPacking(String? packing) {
    labelPacking = packing;
    notifyListeners();
  }

  Future<String?> _resolveOdooWebSession(
    BuildContext context, {
    bool forceRefresh = false,
  }) async {
    if (forceRefresh) OdooRpcHelper.invalidateWebSession();

    final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
    var sid = loginModel.sessionId ?? '';
    final email = (loginModel.loginEmail ?? '').trim();
    final pass = loginModel.loginPassword ?? '';
    if (email.isNotEmpty && pass.isNotEmpty) {
      final webSid = await OdooRpcHelper.cachedWebSessionId(
        db: LoginViewmodel.dbName,
        login: email,
        password: pass,
      );
      if (webSid != null && webSid.isNotEmpty) sid = webSid;
    }
    return sid.isEmpty ? null : sid;
  }

  Future<String> _tryAddToInvoice({
    required WebApiImpl webApi,
    required String sessionId,
    required String invoiceNumber,
    required num qtyValue,
    required Map<String, dynamic> params,
  }) async {
    if (kDebugMode) {
      debugPrint('label add_to_invoice params: $params');
    }

    final response = await webApi.addMedicineQty(
      userDetails: ApiRequestHelper.jsonRpcCall(params),
      sessionId: sessionId,
    );

    if (response.statusCode != 200) {
      return 'Unable to add medicine (HTTP ${response.statusCode})';
    }

    final respo = json.decode(response.body) as Map<String, dynamic>;
    if (ApiResponseHelper.isSuccess(respo)) {
      _captureAddInvoiceMeta(respo);
      return 'success';
    }

    return ApiResponseHelper.errorMessage(
      respo,
      fallback: 'Failed to add medicine quantity',
    );
  }

  Future<String> addLabelStockToInvoice({
    required double qty,
    required BuildContext context,
    required String invoiceNumber,
  }) async {
    lastAddedInvoiceId = null;
    lastAddedInvoiceName = null;

    final stock = selectedLabelStock;
    if (stock == null) {
      return 'Select medicine, potency, and packing from stock.';
    }

    try {
      addingLoading = true;
      notifyListeners();

      final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
      final flutterSid = loginModel.sessionId ?? '';
      if (flutterSid.isEmpty) {
        return 'Session expired. Please log in again.';
      }

      final trimmedInvoice = invoiceNumber.trim();
      if (trimmedInvoice.isEmpty) {
        return 'Invoice number is required';
      }

      final qtyValue = qty == qty.roundToDouble() ? qty.toInt() : qty;
      final webApi = WebApiImpl();

      // Path 1: Flutter add_to_invoice (uses app session — no Odoo web RPC).
      if (stock.stockId != null && stock.stockId! > 0) {
        for (final key in const ['stock_display_id', 'stock_id']) {
          final result = await _tryAddToInvoice(
            webApi: webApi,
            sessionId: flutterSid,
            invoiceNumber: trimmedInvoice,
            qtyValue: qtyValue,
            params: {
              'invoice_number': trimmedInvoice,
              key: stock.stockId,
              'quantity': qtyValue,
            },
          );
          if (result == 'success') return result;
        }

        final detailResult = await _tryAddToInvoice(
          webApi: webApi,
          sessionId: flutterSid,
          invoiceNumber: trimmedInvoice,
          qtyValue: qtyValue,
          params: {
            'invoice_number': trimmedInvoice,
            'stock_display_id': stock.stockId,
            'medicine_name': stock.medicineLabel,
            if ((stock.potency ?? '').trim().isNotEmpty)
              'potency': stock.potency!.trim(),
            if ((stock.packing ?? '').trim().isNotEmpty)
              'packing': stock.packing!.trim(),
            'quantity': qtyValue,
          },
        );
        if (detailResult == 'success') return detailResult;
      }

      // Path 2: QR token from Odoo web session (optional).
      final odooSid = await _resolveOdooWebSession(context);
      if (odooSid != null) {
        final token = await OdooRpcHelper.findEntryStockQrToken(
          odooSid,
          stockDisplayId: stock.stockId,
          medicine: stock.medicineLabel,
          potency: stock.potency,
        );

        if (token != null && token.isNotEmpty) {
          final result = await _tryAddToInvoice(
            webApi: webApi,
            sessionId: flutterSid,
            invoiceNumber: trimmedInvoice,
            qtyValue: qtyValue,
            params: {
              'invoice_number': trimmedInvoice,
              'qr_data': token,
              'quantity': qtyValue,
            },
          );
          if (result == 'success') return result;
        }
      }

      // Path 3: Odoo RPC write (refresh web session once on failure).
      for (var attempt = 0; attempt < 2; attempt++) {
        final rpcSid = await _resolveOdooWebSession(
          context,
          forceRefresh: attempt > 0,
        );
        if (rpcSid == null || rpcSid.isEmpty) break;

        final stockRow = await OdooRpcHelper.findEntryStockRow(
          rpcSid,
          stockDisplayId: stock.stockId,
          medicine: stock.medicineLabel,
          potency: stock.potency,
        );
        if (stockRow == null) continue;

        final invoiceId = await OdooRpcHelper.findCustomerInvoiceId(
          rpcSid,
          trimmedInvoice,
        );
        if (invoiceId == null || invoiceId <= 0) {
          return 'Invoice not found on server.';
        }

        final ok = await OdooRpcHelper.addStockLineToCustomerInvoice(
          rpcSid,
          invoiceId: invoiceId,
          stockRow: stockRow,
          quantity: qty,
        );
        if (ok) {
          lastAddedInvoiceId = invoiceId;
          lastAddedInvoiceName = trimmedInvoice;
          return 'success';
        }
      }

      return 'Failed to add medicine to invoice. Please log in again and retry.';
    } catch (e, s) {
      if (kDebugMode) debugPrint('addLabelStockToInvoice: $e\n$s');
      final message = e.toString().toLowerCase();
      if (message.contains('session expired')) {
        return 'Session expired. Please log in again and retry.';
      }
      return 'Network error. Please check your connection and try again.';
    } finally {
      addingLoading = false;
      notifyListeners();
    }
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
