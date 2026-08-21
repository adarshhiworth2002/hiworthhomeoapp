import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/services/WebApi/web_api_impl.dart';
import '../features/services/api_request_helper.dart';
import '../features/services/api_response_helper.dart';
import '../features/services/endPoints.dart';
import '../features/services/payment_history_service.dart';
import '../models/net_amount_model.dart';
import 'login_viewmodel.dart';

enum NetAmountSection { youGot, youGave }

class NetAmountViewModel extends ChangeNotifier {
  static const String sectionYouGot = 'all';
  static const String sectionYouGave = 'you_gave';
  static const _cacheTtl = Duration(seconds: 60);

  bool homeLoading = false;
  bool detailLoading = false;
  String error = '';

  double? youGotAmount;
  double? youGaveAmount;
  List<NetAmountRow> youGotInvoices = [];
  List<NetAmountRow> youGaveBills = [];
  String? reportDate;

  /// Shared All / Draft / Open / Paid chip on Net Amount screens.
  String statusFilter = 'all';

  DateTime? _loadedAt;

  bool get _hasCachedData =>
      _loadedAt != null &&
      DateTime.now().difference(_loadedAt!) < _cacheTtl &&
      (youGotAmount != null || youGaveAmount != null);

  Future<void> fetchHomePreview(BuildContext context) async {
    if (_hasCachedData) {
      homeLoading = false;
      notifyListeners();
      return;
    }

    homeLoading = true;
    notifyListeners();
    try {
      await fetchAmountsOnly(context, silent: true);
      error = '';
    } catch (e) {
      if (kDebugMode) debugPrint('net amount home preview: $e');
    } finally {
      homeLoading = false;
      notifyListeners();
    }
  }

  /// Home-tile refresh: only the two amount endpoints (no invoice enrichment).
  Future<void> fetchAmountsOnly(
    BuildContext context, {
    bool forceRefresh = false,
    bool silent = false,
  }) async {
    if (!forceRefresh && _hasCachedData) {
      if (!silent) notifyListeners();
      return;
    }

    if (!silent) {
      homeLoading = true;
      notifyListeners();
    }

    try {
      final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
      if (loginModel.sessionId == null || loginModel.sessionId!.isEmpty) {
        throw Exception('Session expired');
      }

      final results = await Future.wait([
        _fetchParsed(context, sectionYouGot),
        _fetchParsed(context, sectionYouGave),
      ]);

      final got = results[0];
      final gave = results[1];

      youGotAmount = got?.youGot ?? got?.amount ?? youGotAmount;
      youGaveAmount = gave?.youGave ?? gave?.amount ?? youGaveAmount;
      reportDate = got?.date ?? gave?.date ?? reportDate;

      if (got != null) {
        youGotAmount ??= got.youGot;
        youGaveAmount ??= got.youGave;
      }

      if (youGotInvoices.isNotEmpty) {
        youGotAmount = sumPaidInvoices(youGotInvoices);
      }

      if (youGotAmount == null && youGaveAmount == null) {
        error = 'Unable to load net amounts';
      } else {
        error = '';
        _loadedAt = DateTime.now();
      }
    } catch (e, s) {
      if (kDebugMode) debugPrint('fetchAmountsOnly: $e\n$s');
      if (!silent || youGotAmount == null) {
        error = 'Network error. Please check your connection and try again.';
      }
    } finally {
      homeLoading = false;
      notifyListeners();
    }
  }

  Future<void> fetchBoth(
    BuildContext context, {
    bool forceRefresh = false,
    bool silent = false,
  }) async {
    if (!forceRefresh && _hasCachedData) {
      if (!silent) notifyListeners();
      return;
    }

    if (!silent) {
      detailLoading = true;
      error = '';
      notifyListeners();
    } else if (!forceRefresh && !_hasCachedData) {
      homeLoading = true;
      notifyListeners();
    }

    try {
      final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
      if (loginModel.sessionId == null || loginModel.sessionId!.isEmpty) {
        throw Exception('Session expired');
      }
      final sessionId = loginModel.sessionId!;

      final results = await Future.wait([
        _fetchParsed(context, sectionYouGot),
        _fetchParsed(context, sectionYouGave),
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
      youGotInvoices = NetAmountRow.enrichRows(
        got?.youGotInvoices ?? [],
        paymentHistoryMaps,
      );
      youGaveBills = NetAmountRow.enrichRows(
        gave?.youGaveBills ?? [],
        supplierListMaps,
      );
      reportDate = got?.date ?? gave?.date;

      if (got != null) {
        youGaveAmount ??= got.youGave;
        if (youGaveBills.isEmpty && got.youGaveBills.isNotEmpty) {
          youGaveBills = NetAmountRow.enrichRows(
            got.youGaveBills,
            supplierListMaps,
          );
        }
      }

      // Home + main page show fully paid collections only (not open + paid).
      if (youGotInvoices.isNotEmpty) {
        youGotAmount = sumPaidInvoices(youGotInvoices);
      } else {
        youGotAmount = got?.youGot ?? got?.amount ?? youGotAmount;
      }

      if (youGotAmount == null && youGaveAmount == null) {
        error = 'Unable to load net amounts';
      } else {
        error = '';
        _loadedAt = DateTime.now();
      }
    } catch (e, s) {
      if (kDebugMode) debugPrint('$e\n$s');
      if (!silent || youGotAmount == null) {
        error = 'Network error. Please check your connection and try again.';
      }
    } finally {
      if (!silent) {
        detailLoading = false;
        notifyListeners();
      } else {
        homeLoading = false;
        notifyListeners();
      }
    }
  }

  static void clearGlobalCache() {
    // No static cache; use [clearInstanceCache] on the active ViewModel.
  }

  void clearInstanceCache() {
    _loadedAt = null;
  }

  List<NetAmountRow> rowsFor(NetAmountSection section) {
    switch (section) {
      case NetAmountSection.youGot:
        return _filterByStatus(youGotInvoices);
      case NetAmountSection.youGave:
        return _filterByStatus(youGaveBills);
    }
  }

  List<NetAmountRow> _filterByStatus(List<NetAmountRow> rows) {
    if (statusFilter == 'all') return List<NetAmountRow>.from(rows);
    return rows.where((row) => row.sectionKey == statusFilter).toList();
  }

  void setStatusFilter(String key) {
    if (statusFilter == key) return;
    statusFilter = key;
    notifyListeners();
  }

  static double sumPaidInvoices(List<NetAmountRow> rows) {
    return rows
        .where((row) => row.sectionKey == 'paid')
        .fold<double>(0, (sum, row) => sum + (row.total ?? row.paidAmount));
  }

  int get youGotPaidCount =>
      youGotInvoices.where((row) => row.sectionKey == 'paid').length;

  /// Paid collections only — used on home and the Net Amount main tile.
  double get displayYouGotPaid {
    if (youGotInvoices.isNotEmpty) return sumPaidInvoices(youGotInvoices);
    return youGotAmount ?? 0;
  }

  /// Outstanding supplier payables (balance still to pay) — not paid totals.
  double get displayYouGaveUnpaid {
    if (youGaveBills.isEmpty) return youGaveAmount ?? 0;
    return sumUnpaidBalances(youGaveBills);
  }

  static double sumUnpaidBalances(List<NetAmountRow> rows) {
    return rows.fold<double>(0, (sum, row) {
      if (row.sectionKey == 'paid' || row.sectionKey == 'cancel') {
        return sum;
      }
      final bal = row.balance;
      if (bal != null) return sum + bal;
      return sum + (row.total ?? 0);
    });
  }

  double? amountFor(NetAmountSection section) {
    switch (section) {
      case NetAmountSection.youGot:
        return displayYouGotPaid;
      case NetAmountSection.youGave:
        return displayYouGaveUnpaid;
    }
  }

  Future<NetAmountModel?> _fetchParsed(
    BuildContext context,
    String section,
  ) async {
    final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
    if (loginModel.sessionId == null || loginModel.sessionId!.isEmpty) {
      throw Exception('Session expired');
    }

    final webApi = WebApiImpl();
    final response = await webApi.fetchInvoiceList(
      endpointPath: EndPoint.netAmountYesterday.path,
      userDetails: ApiRequestHelper.jsonRpcCall({'section': section}),
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
      if (kDebugMode) debugPrint('net amount enrich [$endpointPath]: $e');
      return const [];
    }
  }

  static String formatAmount(double? value) {
    if (value == null) return '—';
    final isWhole = value == value.roundToDouble();
    final number = isWhole
        ? value.toInt().toString()
        : value.toStringAsFixed(2);
    return '₹$number';
  }

  static String sectionTitle(NetAmountSection section) {
    switch (section) {
      case NetAmountSection.youGot:
        return 'You Got (Customer)';
      case NetAmountSection.youGave:
        return 'You Gave (Supplier)';
    }
  }
}
