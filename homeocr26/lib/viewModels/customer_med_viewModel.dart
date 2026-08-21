import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:homeocr26/viewModels/login_viewmodel.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../features/services/WebApi/web_api_impl.dart';
import '../features/services/api_request_helper.dart';
import '../features/services/api_response_helper.dart';
import '../features/services/invoice_calc_helper.dart';
import '../features/services/invoice_draft_helper.dart';
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
  /// True when the last successful add used RPC that deducted `item_qty`.
  bool lastAddUsedRpcStockAdjust = false;
  /// True when last add deducted sellable `stock` (Flutter/RPC). False after
  /// tax-error recovery when deduct failed — unlink would still bump stock.
  bool lastAddDeductedSellableStock = true;

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

  QrData qrDataFromLabelStock(StockItemModel stock) {
    return QrData(
      uid: stock.qrToken,
      lineUid: stock.qrToken,
      productBarcode: stock.qrToken,
      productName: stock.medicineLabel,
      productId: stock.stockDisplayId,
      stockDisplayId: stock.stockDisplayId,
      stockEntryId: stock.entryStockId,
      potency: stock.potency,
      packing: stock.packing,
      company: stock.company,
      group: stock.group,
      batch: stock.batch,
      mrp: stock.mrp,
      hsn: stock.hsn,
      tax: InvoiceCalcHelper.normalizeCustomerTaxPercent(stock.gst),
      rack: stock.rack,
      availableStock: stock.availableStock,
      stockQty: stock.availableStock ?? stock.stock ?? stock.itemQty,
      warehouseStockQty: stock.stock,
      entryStockQty: stock.itemQty,
      mfd: stock.mfd,
      expiry: stock.exp,
    );
  }

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
      lastAddUsedRpcStockAdjust = false;
      lastAddDeductedSellableStock = true;
      return 'success';
    }

    return ApiResponseHelper.errorMessage(
      respo,
      fallback: 'Failed to add medicine quantity',
    );
  }

  Future<String?> _ensureCustomerInvoiceNumber(
    BuildContext context,
    String invoiceNumber, {
    int? preferredInvoiceId,
  }) async {
    final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
    final flutterSid = loginModel.sessionId ?? '';
    if (flutterSid.isEmpty) return null;

    final trimmed = invoiceNumber.trim();
    if (trimmed.isEmpty &&
        (preferredInvoiceId == null || preferredInvoiceId <= 0)) {
      return null;
    }

    // Already on a known move (draft name is often "/"). Never create another.
    if (preferredInvoiceId != null && preferredInvoiceId > 0) {
      lastAddedInvoiceId = preferredInvoiceId;
      lastAddedInvoiceName =
          trimmed.isNotEmpty ? trimmed : lastAddedInvoiceName;
      return lastAddedInvoiceName ?? trimmed;
    }

    final odooSid = await _resolveOdooWebSession(context) ?? flutterSid;
    final existingId =
        await OdooRpcHelper.findCustomerInvoiceId(odooSid, trimmed);
    if (existingId != null && existingId > 0) {
      lastAddedInvoiceId = existingId;
      lastAddedInvoiceName = trimmed;
      return trimmed;
    }

    final draft = await InvoiceDraftHelper.createEmptyDraft(
      sessionId: flutterSid,
      knownNumbers: {trimmed},
      login: loginModel.loginEmail,
      password: loginModel.loginPassword,
      db: LoginViewmodel.dbName,
    );
    if (draft == null) return null;

    lastAddedInvoiceId = draft.invoiceId;
    lastAddedInvoiceName = draft.invoiceNumber;
    if (kDebugMode) {
      debugPrint(
        'label add: created draft invoice ${draft.invoiceNumber} '
        '(id=${draft.invoiceId})',
      );
    }
    return draft.invoiceNumber;
  }

  Future<String> addLabelStockToInvoice({
    required double qty,
    required BuildContext context,
    required String invoiceNumber,
    int? invoiceId,
  }) async {
    lastAddedInvoiceId = null;
    lastAddedInvoiceName = null;
    lastAddUsedRpcStockAdjust = false;
    lastAddDeductedSellableStock = true;

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
      if (trimmedInvoice.isEmpty &&
          (invoiceId == null || invoiceId <= 0)) {
        return 'Invoice number is required';
      }

      final resolvedInvoice = await _ensureCustomerInvoiceNumber(
        context,
        trimmedInvoice,
        preferredInvoiceId: invoiceId,
      );
      if (resolvedInvoice == null || resolvedInvoice.isEmpty) {
        return 'Invoice not found on server. Save the bill first, then retry.';
      }
      final moveId = lastAddedInvoiceId ?? invoiceId;

      final qtyValue = qty == qty.roundToDouble() ? qty.toInt() : qty;
      final webApi = WebApiImpl();
      final displayId = stock.stockDisplayId;
      final entryId = stock.entryStockId;

      if (kDebugMode) {
        debugPrint(
          'label add stock: medicine=${stock.medicineLabel} '
          'displayId=$displayId entryId=$entryId '
          'potency=${stock.potency} batch=${stock.batch}',
        );
      }

      // Path 1: add_to_invoice with qr_data (same as QR scan — correct product).
      var qrToken = (stock.qrToken ?? '').trim();
      final odooSid = await _resolveOdooWebSession(context);
      if (qrToken.isEmpty && odooSid != null) {
        qrToken = await OdooRpcHelper.findEntryStockQrToken(
              odooSid,
              stockDisplayId: displayId,
              entryStockId: entryId,
              medicine: stock.medicineLabel,
              potency: stock.potency,
              batch: stock.batch,
            ) ??
            '';
      }

      Map<String, dynamic> addParams(String qr) {
        final params = <String, dynamic>{
          'invoice_number': resolvedInvoice,
          'qr_data': qr,
          'quantity': qtyValue,
        };
        if (moveId != null && moveId > 0) {
          params['invoice_id'] = moveId;
        }
        _putCustomerTaxParams(
          params,
          InvoiceCalcHelper.normalizeCustomerTaxPercent(stock.gst),
        );
        return params;
      }

      if (qrToken.isNotEmpty) {
        final result = await _tryAddToInvoice(
          webApi: webApi,
          sessionId: flutterSid,
          invoiceNumber: resolvedInvoice,
          qtyValue: qtyValue,
          params: addParams(qrToken),
        );
        if (result == 'success') return result;

        final alt = _alternativeAddQrData(qrToken);
        if (alt != null && alt.isNotEmpty) {
          final retry = await _tryAddToInvoice(
            webApi: webApi,
            sessionId: flutterSid,
            invoiceNumber: resolvedInvoice,
            qtyValue: qtyValue,
            params: addParams(alt),
          );
          if (retry == 'success') return retry;
        }
      }

      // Path 2: Odoo RPC write with the exact stock row (no ambiguous stock_id).
      for (var attempt = 0; attempt < 2; attempt++) {
        final rpcSid = await _resolveOdooWebSession(
          context,
          forceRefresh: attempt > 0,
        );
        if (rpcSid == null || rpcSid.isEmpty) break;

        final stockRow = await OdooRpcHelper.findEntryStockRow(
          rpcSid,
          stockDisplayId: displayId,
          entryStockId: entryId,
          medicine: stock.medicineLabel,
          potency: stock.potency,
          batch: stock.batch,
        );
        if (stockRow == null) continue;

        if (kDebugMode) {
          final rowMed = stockRow['medicine_id_name'] ??
              (stockRow['medicine_id'] is List &&
                      (stockRow['medicine_id'] as List).length >= 2
                  ? (stockRow['medicine_id'] as List)[1]
                  : null);
          debugPrint(
            'label add RPC row id=${stockRow['id']} medicine=$rowMed',
          );
        }

        final targetId = moveId ??
            lastAddedInvoiceId ??
            await OdooRpcHelper.findCustomerInvoiceId(
              rpcSid,
              resolvedInvoice,
            );
        if (targetId == null || targetId <= 0) {
          return 'Invoice not found on server.';
        }

        final ok = await OdooRpcHelper.addStockLineToCustomerInvoice(
          rpcSid,
          invoiceId: targetId,
          stockRow: stockRow,
          quantity: qty,
          taxPercent: InvoiceCalcHelper.normalizeCustomerTaxPercent(stock.gst),
        );
        if (ok) {
          lastAddedInvoiceId = targetId;
          lastAddedInvoiceName = resolvedInvoice;
          lastAddUsedRpcStockAdjust = true;
          lastAddDeductedSellableStock = true;
          return 'success';
        }
      }

      return 'Failed to add medicine to invoice. Check potency, packing, and stock.';
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
            _normalizeQrCustomerTax();
            if (kDebugMode) {
              debugPrint(
                'Stock Quantity from API: available_stock=${data?.availableStock} '
                'stock_qty=${data?.warehouseStockQty} '
                'entry_stock_qty=${data?.entryStockQty} '
                'invoice_quantity=${data?.quantity} (not shown) '
                'shown=${availableScanQuantity(data)} '
                'uid=${data?.uid} barcode=${data?.productBarcode} '
                'tax=${qrResponse?.result?.data?.tax}',
              );
            }
            await enrichQrDataFromOdoo(context);
            _normalizeQrCustomerTax();
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

  Future<void> enrichQrDataFromOdoo(BuildContext context) async {
    final data = qrResponse?.result?.data;
    if (data == null) return;

    final odooSid = await _resolveOdooWebSession(context);
    if (odooSid == null || odooSid.isEmpty) return;

    Map<String, dynamic>? row = await OdooRpcHelper.findEntryStockRow(
      odooSid,
      stockDisplayId: data.stockDisplayId,
      entryStockId: data.stockEntryId,
      medicine: data.productName,
      batch: data.batch,
      potency: data.potency,
    );

    if (row == null) {
      final token = _resolveAddToInvoiceQrData();
      if (token != null && token.isNotEmpty) {
        row = await OdooRpcHelper.findEntryStockRowByQrToken(odooSid, token);
      }
    }

    if (row == null) return;

    final enriched = _mergeQrDataWithStockRow(data, row);
    qrResponse = QrResponseModel(
      jsonrpc: qrResponse?.jsonrpc,
      id: qrResponse?.id,
      result: QrResult(status: qrResponse?.result?.status, data: enriched),
    );
    notifyListeners();
  }

  /// Customer invoice lines only allow GST 5 / 12 / 18.
  void _normalizeQrCustomerTax() {
    final data = qrResponse?.result?.data;
    if (data == null) return;
    final fixed = InvoiceCalcHelper.normalizeCustomerTaxPercent(data.tax);
    if (data.tax != null && (data.tax! - fixed).abs() < 0.01) return;
    data.tax = fixed;
  }

  void _putCustomerTaxParams(Map<String, dynamic> params, double? rawTax) {
    final tax = InvoiceCalcHelper.normalizeCustomerTaxPercent(rawTax);
    params['tax_percent'] = tax;
    params['tax'] = tax;
    params['gst'] = tax;
    params['gst_percent'] = tax;
  }

  Future<void> _fixStockTaxIfNeeded(
    String sessionId,
    QrData? data,
  ) async {
    if (data == null) return;
    final entryId = data.stockEntryId ?? data.stockDisplayId;
    if (entryId == null || entryId <= 0) return;
    final tax = InvoiceCalcHelper.normalizeCustomerTaxPercent(data.tax);
    await OdooRpcHelper.updateEntryStock(
      sessionId,
      entryStockId: entryId,
      gst: tax,
    );
    data.tax = tax;
  }

  static String? _pickString(String? primary, dynamic fallback) {
    final left = primary?.trim();
    if (left != null && left.isNotEmpty) return left;
    final right = fallback?.toString().trim();
    if (right == null || right.isEmpty || right == 'false') return null;
    return right;
  }

  static double? _pickDouble(double? primary, dynamic fallback) {
    if (primary != null && primary > 0) return primary;
    if (fallback is num) return fallback.toDouble();
    return double.tryParse(fallback?.toString() ?? '');
  }

  QrData _mergeQrDataWithStockRow(
    QrData base,
    Map<String, dynamic> row,
  ) {
    final entryId = OdooRpcHelper.displayIdFromEntryStockRow(row) ??
        int.tryParse('${row['id']}');
    final displayId = int.tryParse('${row['stock_display_id'] ?? row['display_id']}');

    return QrData(
      uid: _pickString(base.uid, row['uid']),
      lineUid: _pickString(base.lineUid, row['uid']),
      productBarcode: _pickString(
        base.productBarcode,
        row['product_barcode'] ?? row['barcode'] ?? row['qr_data'],
      ),
      productName: _pickString(base.productName, row['medicine_id_name']),
      potency: _pickString(base.potency, row['potency_id_name']),
      packing: _pickString(base.packing, row['packing_id_name']),
      company: _pickString(base.company, row['pharmacy_company_id_name']),
      group: _pickString(base.group, row['pharmacy_group_id_name']),
      batch: _pickString(base.batch, row['batch_no'] ?? row['batch']),
      rack: _pickString(base.rack, row['rack_id_name']),
      hsn: _pickString(base.hsn, row['hsn']),
      expiry: _pickString(base.expiry, row['exp_date'] ?? row['exp']),
      mfd: _pickString(base.mfd, row['mfd_date'] ?? row['mfd']),
      mrp: _pickDouble(base.mrp, row['mrp']),
      tax: InvoiceCalcHelper.normalizeCustomerTaxPercent(
        _pickDouble(base.tax, row['gst'] ?? row['tax_percent'] ?? row['gst_percent']),
      ),
      stockDisplayId: base.stockDisplayId ?? displayId ?? entryId,
      stockEntryId: base.stockEntryId ?? entryId,
      productId: base.productId ?? entryId,
      availableStock: base.availableStock ??
          _pickDouble(null, row['stock'] ?? row['item_qty']),
      stockQty: base.stockQty ?? _pickDouble(null, row['stock'] ?? row['item_qty']),
      warehouseStockQty:
          base.warehouseStockQty ?? _pickDouble(null, row['stock']),
      entryStockQty:
          base.entryStockQty ?? _pickDouble(null, row['item_qty']),
      unitPrice: base.unitPrice,
      discountPercent: base.discountPercent,
      quantity: base.quantity,
      invoiceNo: base.invoiceNo,
      documentType: base.documentType,
    );
  }

  Future<String> addRequiredMedicineQty({
    required double qty,
    required BuildContext context,
    required String invoiceNumber,
    int? invoiceId,
  }) async {
    lastAddedInvoiceId = null;
    lastAddedInvoiceName = null;
    lastAddUsedRpcStockAdjust = false;
    lastAddDeductedSellableStock = true;
    try {
      addingLoading = true;
      notifyListeners();
      final loginModel = Provider.of<LoginViewmodel>(context, listen: false);

      final qrData = _resolveAddToInvoiceQrData();
      if (qrData == null || qrData.isEmpty) {
        return 'Invalid QR code. Product identifier not found.';
      }

      final trimmedInvoice = invoiceNumber.trim();
      if (trimmedInvoice.isEmpty &&
          (invoiceId == null || invoiceId <= 0)) {
        return 'Invoice number is required';
      }

      final resolvedInvoice = await _ensureCustomerInvoiceNumber(
        context,
        trimmedInvoice,
        preferredInvoiceId: invoiceId,
      );
      if (resolvedInvoice == null || resolvedInvoice.isEmpty) {
        return 'Invoice not found on server. Save the bill first, then retry.';
      }

      final webApi = WebApiImpl();
      if (loginModel.sessionId == null || loginModel.sessionId!.isEmpty) {
        return 'Session expired. Please log in again.';
      }

      // Same as home-page / Postman flow:
      // { invoice_number, qr_data, quantity } (+ invoice_id when locked)
      // + tax_percent (5/12/18) — stock/QR can send invalid rates like 100.
      final qtyValue = qty == qty.roundToDouble() ? qty.toInt() : qty;
      final moveId = lastAddedInvoiceId ?? invoiceId;
      final scanData = qrResponse?.result?.data;
      final rawTax = scanData?.tax;
      final taxPct = InvoiceCalcHelper.normalizeCustomerTaxPercent(rawTax);

      final odooSid = await _resolveOdooWebSession(context);
      if (odooSid != null &&
          odooSid.isNotEmpty &&
          !InvoiceCalcHelper.isAllowedCustomerTax(rawTax)) {
        await _fixStockTaxIfNeeded(odooSid, scanData);
      }
      _normalizeQrCustomerTax();

      final params = <String, dynamic>{
        'invoice_number': resolvedInvoice,
        'qr_data': qrData,
        'quantity': qtyValue,
      };
      if (moveId != null && moveId > 0) {
        params['invoice_id'] = moveId;
      }
      _putCustomerTaxParams(params, taxPct);
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
          lastAddUsedRpcStockAdjust = false;
          lastAddDeductedSellableStock = true;
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
            'invoice_number': resolvedInvoice,
            'qr_data': alt,
            'quantity': qtyValue,
          };
          if (moveId != null && moveId > 0) {
            retryParams['invoice_id'] = moveId;
          }
          _putCustomerTaxParams(retryParams, taxPct);
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
              lastAddUsedRpcStockAdjust = false;
              lastAddDeductedSellableStock = true;
              return 'success';
            }
            message = ApiResponseHelper.errorMessage(
              retryBody,
              fallback: message,
            );
          }
        }

        // Tax 100% (etc.) from QR/stock — server may still create the line.
        // Fix tax on existing lines first; only then fall back to RPC add.
        if (message.toLowerCase().contains('tax must be')) {
          final targetId = moveId ?? lastAddedInvoiceId;
          if (odooSid != null &&
              odooSid.isNotEmpty &&
              targetId != null &&
              targetId > 0) {
            final taxFix = await OdooRpcHelper.fixCustomerInvoiceLineTaxes(
              odooSid,
              invoiceId: targetId,
              taxPercent: taxPct,
            );
            if (taxFix.fixed) {
              lastAddedInvoiceId = targetId;
              lastAddedInvoiceName = resolvedInvoice;
              // Tax-error create often skips sellable stock decrement while
              // unlink still restores it — deduct stock here so delete is net-zero.
              final entryIds = <int>[...taxFix.stockEntryIds];
              final scanEntry =
                  scanData?.stockEntryId ?? scanData?.stockDisplayId;
              if (scanEntry != null &&
                  scanEntry > 0 &&
                  !entryIds.contains(scanEntry)) {
                entryIds.add(scanEntry);
              }
              if (entryIds.isEmpty && qtyValue > 0) {
                Map<String, dynamic>? row;
                final barcode = (scanData?.productBarcode ?? qrData).trim();
                // Prefer full barcode / uid (not BK_…_companyId suffix).
                if (barcode.isNotEmpty) {
                  row = await OdooRpcHelper.findEntryStockRowByQrToken(
                    odooSid,
                    barcode,
                  );
                }
                // BK_* barcodes are product keys, not entry.stock ids — resolve via
                // medicine/batch/potency (or stockDisplayId from scan enrichment).
                row ??= await OdooRpcHelper.findEntryStockRow(
                  odooSid,
                  medicine: scanData?.productName,
                  batch: scanData?.batch,
                  potency: scanData?.potency,
                  stockDisplayId: scanData?.stockDisplayId,
                  entryStockId: scanData?.stockEntryId,
                );
                final foundId = int.tryParse('${row?['id'] ?? ''}') ??
                    int.tryParse('${row?['stock_display_id'] ?? ''}');
                if (foundId != null && foundId > 0) {
                  entryIds.add(foundId);
                }
              }
              var deductedStock = false;
              for (final entryId in entryIds) {
                if (entryId <= 0 || qtyValue <= 0) continue;
                final ok = await OdooRpcHelper.deductEntrySellableStock(
                  sessionId: odooSid,
                  entryId: entryId,
                  qty: qtyValue.toDouble(),
                );
                if (ok) deductedStock = true;
              }
              lastAddUsedRpcStockAdjust = false;
              // When deduct failed/skipped, unlink still restores stock → clamp.
              lastAddDeductedSellableStock = deductedStock;
              if (kDebugMode) {
                debugPrint(
                  'add_to_invoice tax error recovered by rewriting '
                  'line tax → $taxPct on #$targetId'
                  '${deductedStock ? ' + deducted stock -$qtyValue entries=$entryIds' : ' (stock deduct skipped entries=$entryIds)'}',
                );
              }
              return 'success';
            }
          }
          final rpcOk = await _addViaOdooStockLine(
            context: context,
            invoiceNumber: resolvedInvoice,
            invoiceId: moveId,
            qty: qty,
            taxPercent: taxPct,
          );
          if (rpcOk) {
            lastAddUsedRpcStockAdjust = true;
            lastAddDeductedSellableStock = true;
            return 'success';
          }
          return 'Tax must be 5%, 12%, or 18%. '
              'This product had ${scanData?.tax ?? '?'}% — tried $taxPct%. '
              'Update GST on stock and retry.';
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

  Future<bool> _addViaOdooStockLine({
    required BuildContext context,
    required String invoiceNumber,
    required double qty,
    int? invoiceId,
    double? taxPercent,
  }) async {
    final data = qrResponse?.result?.data;
    for (var attempt = 0; attempt < 2; attempt++) {
      final rpcSid = await _resolveOdooWebSession(
        context,
        forceRefresh: attempt > 0,
      );
      if (rpcSid == null || rpcSid.isEmpty) break;

      final stockRow = await OdooRpcHelper.findEntryStockRow(
        rpcSid,
        stockDisplayId: data?.stockDisplayId,
        entryStockId: data?.stockEntryId,
        medicine: data?.productName,
        potency: data?.potency,
        batch: data?.batch,
      );
      if (stockRow == null) {
        final token = _resolveAddToInvoiceQrData();
        if (token == null || token.isEmpty) continue;
        final byToken =
            await OdooRpcHelper.findEntryStockRowByQrToken(rpcSid, token);
        if (byToken == null) continue;
        final targetId = invoiceId ??
            lastAddedInvoiceId ??
            await OdooRpcHelper.findCustomerInvoiceId(rpcSid, invoiceNumber);
        if (targetId == null || targetId <= 0) return false;
        final ok = await OdooRpcHelper.addStockLineToCustomerInvoice(
          rpcSid,
          invoiceId: targetId,
          stockRow: byToken,
          quantity: qty,
          taxPercent: taxPercent,
        );
        if (ok) {
          lastAddedInvoiceId = targetId;
          lastAddedInvoiceName = invoiceNumber;
          lastAddUsedRpcStockAdjust = true;
          lastAddDeductedSellableStock = true;
          return true;
        }
        continue;
      }

      final targetId = invoiceId ??
          lastAddedInvoiceId ??
          await OdooRpcHelper.findCustomerInvoiceId(rpcSid, invoiceNumber);
      if (targetId == null || targetId <= 0) return false;

      final ok = await OdooRpcHelper.addStockLineToCustomerInvoice(
        rpcSid,
        invoiceId: targetId,
        stockRow: stockRow,
        quantity: qty,
        taxPercent: taxPercent,
      );
      if (ok) {
        lastAddedInvoiceId = targetId;
        lastAddedInvoiceName = invoiceNumber;
        lastAddUsedRpcStockAdjust = true;
        lastAddDeductedSellableStock = true;
        return true;
      }
    }
    return false;
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
