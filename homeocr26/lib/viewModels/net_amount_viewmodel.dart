import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/services/WebApi/web_api_impl.dart';
import '../features/services/api_request_helper.dart';
import '../features/services/api_response_helper.dart';
import '../features/services/calendar_date.dart';
import '../features/services/endPoints.dart';
import '../models/net_amount_model.dart';
import 'login_viewmodel.dart';

enum NetAmountSection { youGot, youGave }

class NetAmountViewModel extends ChangeNotifier {
  static const String sectionYouGot = 'all';
  static const String sectionYouGave = 'you_gave';
  static const _cacheTtl = Duration(seconds: 12);

  bool homeLoading = false;
  bool detailLoading = false;
  String error = '';

  double? youGotAmount;
  /// Paid-only total for the home Net Amount tile.
  double? youGotPaidHomeAmount;
  double? youGaveAmount;
  List<NetAmountRow> youGotInvoices = [];
  List<NetAmountRow> youGaveBills = [];
  String? reportDate;

  /// Shared status chips on Net Amount screens.
  /// You Got defaults to Draft + Open (Incomplete / Credit Pending).
  Set<String> statusFilters = const {'draft', 'open'};

  /// Legacy single-key view (first selected, or `all`).
  String get statusFilter =>
      statusFilters.contains('all') || statusFilters.isEmpty
          ? 'all'
          : (statusFilters.length == 1
              ? statusFilters.first
              : statusFilters.join(','));

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

      // List outstanding for You Got section; paid-only for home tile.
      youGotAmount = got?.youGot ?? got?.amount ?? youGotAmount;
      youGotPaidHomeAmount =
          got?.youGotPaidTotal ?? gave?.youGotPaidTotal ?? youGotPaidHomeAmount;
      youGaveAmount = gave?.youGave ?? gave?.amount ?? youGaveAmount;
      reportDate = got?.date ?? gave?.date ?? reportDate;

      if (got != null) {
        youGotAmount ??= got.youGot;
        youGotPaidHomeAmount ??= got.youGotPaidTotal;
        youGaveAmount ??= got.youGave;
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
        // YOU GOT list enrichment — customer invoices.
        _fetchRecordMaps(
          context,
          sessionId,
          EndPoint.customerInvoiceList.path,
          {'limit': 200, 'offset': 0},
        ),
        // YOU GAVE list — supplier invoices (website Supplier Invoices).
        // Do not filter state=posted: yesterday's bills are often still draft.
        _fetchRecordMaps(
          context,
          sessionId,
          EndPoint.supplierInvoiceList.path,
          {'limit': 500, 'offset': 0},
        ),
      ]);

      final got = results[0] as NetAmountModel?;
      final gave = results[1] as NetAmountModel?;
      final customerInvoiceMaps = results[2] as List<Map<String, dynamic>>;
      final supplierListMaps = results[3] as List<Map<String, dynamic>>;

      reportDate = got?.date ?? gave?.date;

      // YOU GOT = all customer invoices for report date (draft/open/paid).
      // Net-amount API lists are often paid-only — fill from customer list.
      final apiGotRows = _preferNonEmpty(
        got?.youGotInvoices ?? const [],
        gave?.youGotInvoices ?? const [],
      );
      final customerDayRows = _customerRowsForReportDate(
        customerInvoiceMaps,
        reportDate,
      );
      youGotInvoices = _mergeYouGotRows(
        apiRows: NetAmountRow.enrichRows(apiGotRows, customerInvoiceMaps),
        listRows: customerDayRows,
      );

      // YOU GAVE = supplier invoices for report date (yesterday).
      final supplierRows = _supplierRowsForReportDate(
        supplierListMaps,
        reportDate,
      );
      youGaveBills = supplierRows.isNotEmpty
          ? supplierRows
          : NetAmountRow.enrichRows(
              gave?.youGaveBills ?? got?.youGaveBills ?? const [],
              supplierListMaps,
            );

      // You Got section outstanding; home Paid uses paid-only totals (unchanged).
      youGotAmount = got?.youGot ??
          (youGotInvoices.isNotEmpty
              ? sumUnpaidBalances(youGotInvoices)
              : got?.amount);
      // Prefer API paid total so expanding the list with drafts never shifts
      // the home-screen Paid figure.
      youGotPaidHomeAmount = got?.youGotPaidTotal ??
          gave?.youGotPaidTotal ??
          youGotPaidHomeAmount ??
          (youGotInvoices.isNotEmpty ? sumPaidInvoices(youGotInvoices) : null);
      youGaveAmount = youGaveBills.isNotEmpty
          ? sumUnpaidBalances(youGaveBills)
          : (gave?.youGave ?? got?.youGave);

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
    if (statusFilters.isEmpty || statusFilters.contains('all')) {
      return List<NetAmountRow>.from(rows);
    }
    return rows
        .where((row) => statusFilters.contains(row.sectionKey))
        .toList();
  }

  bool get isStatusFilterAll =>
      statusFilters.isEmpty || statusFilters.contains('all');

  bool isStatusSelected(String key) {
    if (key == 'all') return isStatusFilterAll;
    if (isStatusFilterAll) return false;
    return statusFilters.contains(key);
  }

  void setStatusFilter(String key) {
    final next = Set<String>.from(statusFilters);
    if (key == 'all') {
      if (isStatusFilterAll) return;
      statusFilters = const {'all'};
      notifyListeners();
      return;
    }

    // Leave "all" when picking a concrete status.
    next.remove('all');
    if (next.contains(key)) {
      next.remove(key);
      // Never leave empty — fall back to all.
      statusFilters = next.isEmpty ? const {'all'} : Set<String>.unmodifiable(next);
    } else {
      next.add(key);
      statusFilters = Set<String>.unmodifiable(next);
    }
    notifyListeners();
  }

  void setStatusFilters(Set<String> keys) {
    final cleaned = keys.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
    if (cleaned.isEmpty || cleaned.contains('all')) {
      if (isStatusFilterAll && statusFilters.contains('all')) return;
      statusFilters = const {'all'};
    } else {
      statusFilters = Set<String>.unmodifiable(cleaned);
    }
    notifyListeners();
  }

  static double sumPaidInvoices(List<NetAmountRow> rows) {
    return rows
        .where((row) => row.sectionKey == 'paid')
        .fold<double>(0, (sum, row) => sum + (row.total ?? row.paidAmount));
  }

  int get youGotPaidCount =>
      youGotInvoices.where((row) => row.sectionKey == 'paid').length;

  /// Home tile only — sum of yesterday bills with Paid status.
  /// Prefers API `you_got_paid_total` so list enrichment (drafts/open) does
  /// not change the home Paid amount.
  double get displayYouGotPaid {
    if (youGotPaidHomeAmount != null) return youGotPaidHomeAmount!;
    if (youGotInvoices.isNotEmpty) return sumPaidInvoices(youGotInvoices);
    return 0;
  }

  /// You Got (Customer) section card — full list outstanding (~7618).
  double get displayYouGotListTotal {
    if (youGotInvoices.isNotEmpty) return sumUnpaidBalances(youGotInvoices);
    if (youGotAmount != null) return youGotAmount!;
    return 0;
  }

  /// You Gave card — same total as the supplier invoice list on screen.
  double get displayYouGaveUnpaid {
    if (youGaveBills.isNotEmpty) return sumUnpaidBalances(youGaveBills);
    if (youGaveAmount != null) return youGaveAmount!;
    return 0;
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
        return displayYouGotListTotal;
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

  static List<NetAmountRow> _preferNonEmpty(
    List<NetAmountRow> primary,
    List<NetAmountRow> fallback,
  ) {
    if (primary.isNotEmpty) return primary;
    return fallback;
  }

  /// Keep supplier bills whose invoice date matches Net Amount report day.
  static List<NetAmountRow> _supplierRowsForReportDate(
    List<Map<String, dynamic>> maps,
    String? reportDate,
  ) {
    return _rowsForReportDate(maps, reportDate);
  }

  /// All customer invoices for the Net Amount report day (any status).
  static List<NetAmountRow> _customerRowsForReportDate(
    List<Map<String, dynamic>> maps,
    String? reportDate,
  ) {
    return _rowsForReportDate(maps, reportDate);
  }

  static List<NetAmountRow> _rowsForReportDate(
    List<Map<String, dynamic>> maps,
    String? reportDate,
  ) {
    if (maps.isEmpty) return const [];
    final rows = maps
        .map(NetAmountRow.fromJson)
        .toList(growable: false);
    final day = CalendarDate.parse(reportDate);
    if (day == null) return rows;
    return rows.where((row) {
      final d = CalendarDate.parse(row.invoiceDate);
      if (d == null) return false;
      return d.year == day.year && d.month == day.month && d.day == day.day;
    }).toList(growable: false);
  }

  /// Union API net-amount rows with full customer list for that day.
  /// List rows fill drafts/open that the paid-focused API omitted.
  static List<NetAmountRow> _mergeYouGotRows({
    required List<NetAmountRow> apiRows,
    required List<NetAmountRow> listRows,
  }) {
    if (listRows.isEmpty) return apiRows;
    if (apiRows.isEmpty) return listRows;

    final byKey = <String, NetAmountRow>{};
    String keyOf(NetAmountRow row) {
      if (row.id != null && row.id! > 0) return 'id:${row.id}';
      final num = row.displayNumber.trim().toLowerCase();
      if (num.isNotEmpty && num != '—') return 'no:$num';
      return 'row:${row.customer}|${row.invoiceDate}|${row.total}';
    }

    for (final row in listRows) {
      byKey[keyOf(row)] = row;
    }
    for (final row in apiRows) {
      final key = keyOf(row);
      final existing = byKey[key];
      byKey[key] = existing == null
          ? row
          : existing.copyWith(
              // Keep list status/balance; fill sparse API fields.
              customer: row.customer ?? existing.customer,
              invoiceNumber: row.invoiceNumber ?? existing.invoiceNumber,
              billedBy: row.billedBy ?? existing.billedBy,
              taxAmount: row.taxAmount ?? existing.taxAmount,
              balance: existing.balance ?? row.balance,
              subtotal: existing.subtotal ?? row.subtotal,
              total: existing.total ?? row.total,
              status: existing.status ?? row.status,
              moveState: existing.moveState ?? row.moveState,
              paymentState: existing.paymentState ?? row.paymentState,
              isPaid: existing.isPaid || row.isPaid,
              invoicePaidFlag:
                  existing.invoicePaidFlag || row.invoicePaidFlag,
              paymentMode: existing.paymentMode ?? row.paymentMode,
            );
    }
    final merged = byKey.values.toList();
    merged.sort((a, b) {
      final da = CalendarDate.parse(a.invoiceDate);
      final db = CalendarDate.parse(b.invoiceDate);
      if (da != null && db != null) {
        final c = db.compareTo(da);
        if (c != 0) return c;
      }
      return (b.id ?? 0).compareTo(a.id ?? 0);
    });
    return merged;
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
