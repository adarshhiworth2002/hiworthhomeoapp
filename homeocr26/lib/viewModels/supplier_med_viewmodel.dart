import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:homeocr26/viewModels/login_viewmodel.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../features/services/WebApi/web_api_impl.dart';
import '../features/services/api_request_helper.dart';
import '../features/services/api_response_helper.dart';
import '../features/services/invoice_helper.dart';
import '../features/services/invoice_search_service.dart';
import '../features/services/invoice_suggestion.dart';

import '../features/widgets/show_dialog_custom.dart';
import '../models/supplier_data_model.dart';

class SupplierMedViewModel extends ChangeNotifier {
  final http.Client httpClient;

  SupplierMedViewModel({http.Client? client})
      : httpClient = client ?? http.Client();

  bool qrFetchLoading = false;
  bool addingLoading = false;
  String qrFetchError = "";
  String qrValue = "";
  List<SupplierDataModel> medicine = [];

  void resetQr() {
    qrValue = "";
    qrFetchError = "";
    medicine = [];
    notifyListeners();
  }

  void setQrValue(String value) {
    qrValue = value;
    notifyListeners();
  }

  void parseMedicines(String qrData) {
    qrFetchLoading = true;
    qrFetchError = "";
    notifyListeners();

    final lines = qrData
        .split(RegExp(r'\r?\n'))
        .map((e) => e.trim())
        .where((e) => e.toUpperCase().startsWith('ITEM:'))
        .toList();

    medicine = lines.map((e) => SupplierDataModel.fromQr(e)).toList();

    if (medicine.isEmpty) {
      qrFetchError =
          'Invalid supplier invoice QR. Scan the invoice QR with ITEM: lines. '
          'Product QRs from the supplier portal should be scanned in Add to Customer.';
    }

    qrFetchLoading = false;
    notifyListeners();
  }

  Future<List<String>> searchInvoiceSuggestions(
    BuildContext context,
    String prefix,
  ) async {
    return InvoiceSearchService.searchPrefixes(
      context,
      prefix,
      type: InvoiceSearchType.supplier,
    );
  }

  Future<List<InvoiceSuggestion>> searchInvoiceSuggestionsDetailed(
    BuildContext context,
    String prefix,
  ) async {
    return InvoiceSearchService.searchSuggestions(
      context,
      prefix,
      type: InvoiceSearchType.supplier,
    );
  }

  Future<bool> supplierInvoiceExists(
    BuildContext context,
    String prefix,
  ) async {
    return InvoiceSearchService.invoicePrefixExists(
      context,
      prefix,
      type: InvoiceSearchType.supplier,
    );
  }

  Future<bool> addRequiredMedicineQtySupplier({
    required BuildContext context,
    required String invoiceNumber,
  }) async {
    try {
      addingLoading = true;
      notifyListeners();
      final loginModel = Provider.of<LoginViewmodel>(context, listen: false);

      if (loginModel.sessionId == null || loginModel.sessionId!.isEmpty) {
        if (context.mounted) {
          StatusDialog.show(
            context: context,
            title: 'Session Expired',
            message: 'Please log in again to continue.',
            type: StatusType.error,
          );
        }
        return false;
      }

      final prefix = InvoiceHelper.prefixFromFull(invoiceNumber);
      final suggestion = await InvoiceSearchService.resolveForSupplierAdd(
        context,
        prefix,
      );
      if (suggestion == null) {
        if (context.mounted) {
          StatusDialog.show(
            context: context,
            title: 'Cannot Add',
            message:
                'Invoice $prefix was not found among draft supplier bills. '
                'Paid or posted bills cannot be modified.',
            type: StatusType.error,
          );
        }
        return false;
      }
      if (!suggestion.isDraft) {
        if (context.mounted) {
          StatusDialog.show(
            context: context,
            title: 'Cannot Add',
            message: suggestion.warningMessage,
            type: StatusType.error,
          );
        }
        return false;
      }

      final requestBody = ApiRequestHelper.jsonRpcCall({
        'invoice_number': invoiceNumber,
        'qr_data': qrValue,
      });

      final webApi = WebApiImpl();
      final response = await webApi.addMedicineQtySupplier(
        userDetails: requestBody,
        sessionId: loginModel.sessionId ?? '',
      );

      print('AddMedicine API Response: ${response.body}');

      if (!context.mounted) return false;

      if (response.statusCode == 200) {
        final Map<String, dynamic> respo = json.decode(response.body);
        print('object $respo');

        if (ApiResponseHelper.isSuccess(respo)) {
          await StatusDialog.show(
            context: context,
            title: 'Success',
            message: 'Medicines added to invoice',
            type: StatusType.success,
          );
          return true;
        } else {
          var message = ApiResponseHelper.errorMessage(
            respo,
            fallback: 'Failed to add medicines to invoice',
          );
          final lowered = message.toLowerCase();
          final isMissingInvoice = lowered.contains('not exist') ||
              lowered.contains('not found') ||
              lowered.contains('create');
          final isReconciled = lowered.contains('reconciled');
          await StatusDialog.show(
            context: context,
            title: 'Failed',
            message: isMissingInvoice
                ? 'Invoice does not exist. Please create it in the system first.'
                : isReconciled
                    ? 'This supplier bill is paid or reconciled and cannot be '
                        'modified. Please select a draft bill.'
                    : message,
            type: StatusType.error,
          );
        }
      } else {
        await StatusDialog.show(
          context: context,
          title: 'Failed',
          message: 'Unable to add medicines (HTTP ${response.statusCode})',
          type: StatusType.error,
        );
      }
    } catch (e, s) {
      print(s);
      if (context.mounted) {
        await StatusDialog.show(
          context: context,
          title: 'Failed',
          message: 'Network error. Please check your connection and try again.',
          type: StatusType.error,
        );
      }
    } finally {
      addingLoading = false;
      notifyListeners();
    }
    return false;
  }
}
