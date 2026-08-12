import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/services/WebApi/web_api_impl.dart';
import '../features/services/api_request_helper.dart';
import '../features/services/api_response_helper.dart';
import '../features/services/endPoints.dart';
import '../features/services/payment_history_service.dart';
import '../models/amount_book_model.dart';
import '../models/net_amount_model.dart';
import 'login_viewmodel.dart';

class AmountBookViewModel extends ChangeNotifier {
  static const String sectionYouGot = 'all';
  static const String sectionYouGave = 'you_gave';
  static const _cacheTtl = Duration(seconds: 60);

  bool loading = false;
  String error = '';

  double? youGotAmount;
  double? youGaveAmount;
  List<NetAmountRow> youGotInvoices = [];
  List<NetAmountRow> youGaveBills = [];
  String? reportDate;

  AmountBookFilter filter = const AmountBookFilter();

  DateTime? _loadedAt;
  DateTime? _fetchDateFrom;
  DateTime? _fetchDateTo;

  bool get _hasCachedData =>
      _loadedAt != null &&
      DateTime.now().difference(_loadedAt!) < _cacheTtl &&
      (youGotAmount != null || youGaveAmount != null);

  List<AmountBookCustomerSummary> get customerSummaries =>
      AmountBookLedgerBuilder.buildCustomerSummaries(
        youGotRows: youGotInvoices,
        youGaveRows: youGaveBills,
        filter: filter,
      );

  Future<void> fetch(
    BuildContext context, {
    bool forceRefresh = false,
    bool silent = false,
    DateTime? dateFrom,
    DateTime? dateTo,
  }) async {
    final effectiveFrom = dateFrom ?? filter.dateFrom;
    final effectiveTo = dateTo ?? filter.dateTo;

    if (!forceRefresh &&
        _hasCachedData &&
        _fetchDateFrom == effectiveFrom &&
        _fetchDateTo == effectiveTo) {
      if (!silent) notifyListeners();
      return;
    }

    if (!silent) {
      loading = true;
      error = '';
      notifyListeners();
    }

    try {
      final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
      if (loginModel.sessionId == null || loginModel.sessionId!.isEmpty) {
        throw Exception('Session expired');
      }
      final sessionId = loginModel.sessionId!;

      final results = await Future.wait([
        _fetchParsed(
          context,
          sectionYouGot,
          dateFrom: effectiveFrom,
          dateTo: effectiveTo,
        ),
        _fetchParsed(
          context,
          sectionYouGave,
          dateFrom: effectiveFrom,
          dateTo: effectiveTo,
        ),
        PaymentHistoryService.fetchRecordMaps(sessionId: sessionId, limit: 200),
        _fetchRecordMaps(
          context,
          sessionId,
          EndPoint.supplierInvoiceList.path,
          {'state': 'posted'},
        ),
      ]);

      final got = results[0] as NetAmountModel?;
      final gave = results[1] as NetAmountModel?;
      final paymentHistoryMaps = results[2] as List<Map<String, dynamic>>;
      final supplierListMaps = results[3] as List<Map<String, dynamic>>;

      youGotAmount = got?.youGot ?? got?.amount;
      youGaveAmount = gave?.youGave ?? gave?.amount;
      youGotInvoices = _applyClientDateFilter(
        NetAmountRow.enrichRows(got?.youGotInvoices ?? [], paymentHistoryMaps),
        effectiveFrom,
        effectiveTo,
      );
      youGaveBills = _applyClientDateFilter(
        NetAmountRow.enrichRows(
          gave?.youGaveBills ?? [],
          supplierListMaps,
        ),
        effectiveFrom,
        effectiveTo,
      );
      reportDate = got?.date ?? gave?.date;

      if (got != null) {
        youGotAmount ??= got.youGot;
        youGaveAmount ??= got.youGave;
        if (youGaveBills.isEmpty && got.youGaveBills.isNotEmpty) {
          youGaveBills = _applyClientDateFilter(
            NetAmountRow.enrichRows(got.youGaveBills, supplierListMaps),
            effectiveFrom,
            effectiveTo,
          );
        }
      }

      _fetchDateFrom = effectiveFrom;
      _fetchDateTo = effectiveTo;

      if (youGotAmount == null && youGaveAmount == null) {
        error = 'Unable to load amount book data';
      } else {
        error = '';
        _loadedAt = DateTime.now();
      }
    } catch (e, s) {
      if (kDebugMode) debugPrint('AmountBookViewModel.fetch: $e\n$s');
      if (!silent || youGotAmount == null) {
        error = 'Network error. Please check your connection and try again.';
      }
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  void applyFilter(AmountBookFilter newFilter) {
    filter = newFilter;
    notifyListeners();
  }

  void clearFilter() {
    filter = const AmountBookFilter();
    notifyListeners();
  }

  List<AmountBookLedgerEntry> ledgerForCustomer(String customerName) {
    return AmountBookLedgerBuilder.entriesForCustomer(
      customerName: customerName,
      youGotRows: youGotInvoices,
      youGaveRows: youGaveBills,
      filter: filter,
    );
  }

  List<NetAmountRow> _applyClientDateFilter(
    List<NetAmountRow> rows,
    DateTime? from,
    DateTime? to,
  ) {
    if (from == null && to == null) return rows;
    return rows
        .where((r) => AmountBookLedgerBuilder.rowInDateRange(r, from, to))
        .toList(growable: false);
  }

  Future<NetAmountModel?> _fetchParsed(
    BuildContext context,
    String section, {
    DateTime? dateFrom,
    DateTime? dateTo,
  }) async {
    final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
    if (loginModel.sessionId == null || loginModel.sessionId!.isEmpty) {
      throw Exception('Session expired');
    }

    final params = <String, dynamic>{'section': section};
    if (dateFrom != null) {
      params['date_from'] = _formatApiDate(dateFrom);
      params['from_date'] = _formatApiDate(dateFrom);
    }
    if (dateTo != null) {
      params['date_to'] = _formatApiDate(dateTo);
      params['to_date'] = _formatApiDate(dateTo);
    }

    final webApi = WebApiImpl();
    final response = await webApi.fetchInvoiceList(
      endpointPath: EndPoint.netAmountYesterday.path,
      userDetails: ApiRequestHelper.jsonRpcCall(params),
      sessionId: loginModel.sessionId ?? '',
      logResponseBody: false,
    );

    if (response.statusCode != 200) return null;

    final Map<String, dynamic> body = json.decode(response.body);
    if (body['result'] is Map &&
        (body['result'] as Map)['status'] == 'error') {
      if (kDebugMode) {
        debugPrint(ApiResponseHelper.errorMessage(body));
      }
      return null;
    }

    return NetAmountModel.fromResponse(body, section: section);
  }

  Future<List<Map<String, dynamic>>> _fetchRecordMaps(
    BuildContext context,
    String sessionId,
    String endpointPath,
    Map<String, dynamic> params,
  ) async {
    try {
      final webApi = WebApiImpl();
      final response = await webApi.fetchInvoiceList(
        endpointPath: endpointPath,
        userDetails: ApiRequestHelper.jsonRpcCall(params),
        sessionId: sessionId,
        logResponseBody: false,
      );

      if (response.statusCode != 200) return const [];

      final Map<String, dynamic> body = json.decode(response.body);
      if (body['result'] is Map &&
          (body['result'] as Map)['status'] == 'error') {
        return const [];
      }

      return NetAmountRow.extractRecordMaps(body);
    } catch (e) {
      if (kDebugMode) debugPrint('amount book enrich [$endpointPath]: $e');
      return const [];
    }
  }

  static String _formatApiDate(DateTime date) {
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  static String formatAmount(double? value) {
    if (value == null) return '—';
    final isWhole = value == value.roundToDouble();
    final number = isWhole
        ? value.toInt().toString()
        : value.toStringAsFixed(2);
    return '₹$number';
  }

  static String formatAmountPlain(double? value) {
    if (value == null) return '—';
    final isWhole = value == value.roundToDouble();
    return isWhole ? value.toInt().toString() : value.toStringAsFixed(2);
  }
}
