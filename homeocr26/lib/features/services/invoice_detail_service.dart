import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/invoice_summary_model.dart';
import '../../viewModels/customer_invoice_viewmodel.dart';
import '../../viewModels/login_viewmodel.dart';
import 'WebApi/web_api_impl.dart';
import 'api_request_helper.dart';
import 'api_response_helper.dart';
import 'appConfig.dart';
import 'auth_session_store.dart';
import 'endPoints.dart';
import 'flutter_customer_invoice_web_api.dart';
import 'payment_history_service.dart';
import 'supplier_invoice_web_api.dart';

/// Loads a full customer invoice (header + lines) for the detail screen.
/// Uses Laravel Flutter APIs + local Flutter merge only (no Odoo).
class InvoiceDetailService {
  const InvoiceDetailService._();

  static Future<List<InvoiceSummaryModel>> _paymentHistoryItems(
    String sessionId,
  ) async {
    return PaymentHistoryService.fetchInvoices(sessionId: sessionId, limit: 200);
  }

  static Future<InvoiceSummaryModel> fetchCustomerInvoice(
    BuildContext context, {
    required InvoiceSummaryModel seed,
    bool asSupplier = false,
  }) async {
    final login = Provider.of<LoginViewmodel>(context, listen: false);
    if (login.sessionId == null || login.sessionId!.isEmpty) return seed;

    // Supplier bills share numeric ids with customer invoices — never call
    // get_customer_invoice for You Gave or list totals get wiped to 0.
    if (asSupplier) {
      final id = seed.id;
      if (id == null || id <= 0) return seed;
      final loaded = await SupplierInvoiceWebApi.fetchDetail(
        invoiceId: id,
        seed: seed,
        email: login.loginEmail,
        password: login.loginPassword,
        apiToken: login.sessionId,
      );
      if (loaded == null) return seed;
      return loaded.withComputedSectionAmounts();
    }

    final needsHistory = _needsPaymentHistory(seed);
    final needsLines = seed.id != null;

    if (!needsHistory && !needsLines) return seed;

    final historyFuture = needsHistory
        ? _enrichFromPaymentHistory(
            sessionId: login.sessionId!,
            seed: seed,
          )
        : Future<InvoiceSummaryModel?>.value(null);

    final linesFuture = needsLines
        ? _loadFlutterInvoice(
            sessionId: login.sessionId!,
            invoiceId: seed.id!,
          )
        : Future<InvoiceSummaryModel?>.value(null);

    final results = await Future.wait([historyFuture, linesFuture]);

    var merged = seed;
    if (results[0] != null) merged = merged.mergedWith(results[0]!);
    if (results[1] != null) merged = merged.mergedWith(results[1]!);

    // Laravel detail/list often omit responsible_person — scrape edit form.
    if (!AppConfig.odooRpcEnabled &&
        (merged.responsiblePerson ?? '').trim().isEmpty &&
        merged.id != null &&
        merged.id! > 0) {
      try {
        var email = (login.loginEmail ?? '').trim();
        var pass = login.loginPassword ?? '';
        if (email.isEmpty || pass.isEmpty) {
          final saved = await AuthSessionStore.load();
          email = (saved?.email ?? '').trim();
          pass = saved?.password ?? '';
        }
        if (email.isNotEmpty && pass.isNotEmpty) {
          final web =
              await FlutterCustomerInvoiceWebApi.fetchSelectedResponsible(
            invoiceId: merged.id!,
            email: email,
            password: pass,
            apiToken: AuthSessionStore.currentApiToken,
          );
          final name = web?.name.trim() ?? '';
          if (name.isNotEmpty) {
            merged = merged.mergedWith(
              InvoiceSummaryModel(responsiblePerson: name),
            );
          }
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('InvoiceDetailService responsible web: $e');
        }
      }
    }

    final sectioned = merged.withComputedSectionAmounts();
    if (sectioned.id != null &&
        sectioned.lines.isNotEmpty &&
        sectioned.total != null) {
      CustomerInvoiceViewModel.upsertInvoice(sectioned);
    }
    return sectioned;
  }

  static bool _needsPaymentHistory(InvoiceSummaryModel seed) {
    final billed = (seed.billedBy ?? '').trim();
    final responsible = (seed.responsiblePerson ?? '').trim();
    return billed.isEmpty ||
        responsible.isEmpty ||
        seed.taxAmount == null ||
        seed.subtotal == null ||
        seed.total == null;
  }

  /// Advance / old balance from `get_customer_invoice` (list often omits these).
  static Future<({double? advance, double? oldBalance})?>
      fetchCustomerBalances({
    required String sessionId,
    required int invoiceId,
  }) async {
    if (invoiceId <= 0 || sessionId.trim().isEmpty) return null;
    final parsed = await _loadFlutterInvoice(
      sessionId: sessionId,
      invoiceId: invoiceId,
    );
    if (parsed == null) return null;
    if (parsed.advanceAmount == null && parsed.oldBalance == null) {
      return null;
    }
    return (advance: parsed.advanceAmount, oldBalance: parsed.oldBalance);
  }

  static Future<InvoiceSummaryModel?> _loadFlutterInvoice({
    required String sessionId,
    required int invoiceId,
  }) async {
    // Try Laravel-friendly flat body first, then JSON-RPC envelope.
    final attempts = <Map<String, dynamic>>[
      {
        'invoice_id': invoiceId,
        'id': invoiceId,
      },
      ApiRequestHelper.jsonRpcCall({
        'invoice_id': invoiceId,
        'id': invoiceId,
      }),
    ];

    for (final payload in attempts) {
      final parsed = await _fetchInvoiceOnce(
        sessionId: sessionId,
        invoiceId: invoiceId,
        endpointPath: EndPoint.customerInvoice.path,
        userDetails: payload,
      );
      if (parsed != null) return parsed;
    }

    // Fallback: paged list filtered by id (some Laravel builds ignore detail id).
    return _fetchInvoiceOnce(
      sessionId: sessionId,
      invoiceId: invoiceId,
      endpointPath: EndPoint.customerInvoices.path,
      userDetails: ApiRequestHelper.jsonRpcCall({
        'invoice_id': invoiceId,
        'id': invoiceId,
        'limit': 1,
        'offset': 0,
      }),
    );
  }

  static Future<InvoiceSummaryModel?> _fetchInvoiceOnce({
    required String sessionId,
    required int invoiceId,
    required String endpointPath,
    required Map<String, dynamic> userDetails,
  }) async {
    try {
      final response = await WebApiImpl().fetchInvoiceList(
        endpointPath: endpointPath,
        sessionId: sessionId,
        userDetails: userDetails,
        logResponseBody: kDebugMode,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      final body = response.body.trim();
      if (!body.startsWith('{')) return null;
      final decoded = json.decode(body);
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded);
      if (!ApiResponseHelper.isSuccess(map) &&
          ApiResponseHelper.payloadMap(map)?['status'] == 'error') {
        return null;
      }
      InvoiceSummaryModel? parsed = InvoiceSummaryModel.parseOne(map);
      if (parsed == null) {
        final list = InvoiceSummaryModel.parseList(map);
        for (final item in list) {
          if (item.id == invoiceId) {
            parsed = item;
            break;
          }
        }
        parsed ??= list.isEmpty ? null : list.first;
      }
      if (parsed == null) return null;
      // Laravel sometimes ignores invoice_id and returns invoice #1 — reject.
      final gotId = parsed.id;
      if (gotId != null && gotId > 0 && gotId != invoiceId) {
        if (kDebugMode) {
          debugPrint(
            '$endpointPath id mismatch: asked=$invoiceId got=$gotId',
          );
        }
        return null;
      }
      if (parsed.lines.isEmpty) {
        if (kDebugMode) {
          debugPrint('$endpointPath id=$invoiceId returned 0 lines');
        }
      }
      return parsed;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('InvoiceDetailService $endpointPath: $e');
      }
      return null;
    }
  }

  static Future<InvoiceSummaryModel?> _enrichFromPaymentHistory({
    required String sessionId,
    required InvoiceSummaryModel seed,
  }) async {
    try {
      final items = await _paymentHistoryItems(sessionId);
      for (final item in items) {
        final sameId = seed.id != null && item.id == seed.id;
        final sameNumber = seed.invoiceNumber != null &&
            item.invoiceNumber != null &&
            item.invoiceNumber!.trim() == seed.invoiceNumber!.trim();
        if (sameId || sameNumber) {
          return seed.mergedWith(item);
        }
      }
    } catch (_) {}
    return seed;
  }

  static void clearCache() {
    PaymentHistoryService.clearCache();
  }
}
