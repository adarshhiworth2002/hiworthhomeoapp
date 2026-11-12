import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/services/WebApi/web_api_impl.dart';
import '../features/services/api_request_helper.dart';
import '../features/services/auth_session_store.dart';
import '../features/services/employee_performance_web_api.dart';
import '../features/services/endPoints.dart';
import '../features/services/payment_history_service.dart';
import '../models/employee_performance_model.dart';
import '../models/employee_timer_log_model.dart';
import '../models/invoice_summary_model.dart';
import 'login_viewmodel.dart';

class EmployeePerformanceViewModel extends ChangeNotifier {
  bool loading = false;
  String error = '';
  String info = '';
  EmployeePerformanceSummary summary = const EmployeePerformanceSummary();
  List<EmployeeBillsGroup> employees = [];
  bool _disposed = false;

  static List<EmployeeBillsGroup> _sharedEmployees = [];
  static EmployeePerformanceSummary _sharedSummary =
      const EmployeePerformanceSummary();
  static DateTime? _sharedLoadedAt;
  static const _cacheTtl = Duration(seconds: 60);

  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  static Future<void> prefetch(
    BuildContext context, {
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _isSharedFresh()) return;

    try {
      final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
      final sessionId = loginModel.sessionId;
      if (sessionId == null || sessionId.isEmpty) return;

      final webApi = WebApiImpl();
      final results = await Future.wait([
        _loadInvoices(
          sessionId,
          forceRefresh: forceRefresh && !PaymentHistoryService.hasAnyCache,
        ),
        _loadSummaryFromApi(webApi, sessionId),
      ]);

      var invoices = results[0] as List<InvoiceSummaryModel>;
      var loadedSummary = results[1] as EmployeePerformanceSummary;
      if (loadedSummary.apiEmployees.isEmpty) {
        final web = await _loadWorkersWithStatsFromWebsite(loginModel);
        if (web.workers.isNotEmpty) {
          loadedSummary = _summaryWithWebWorkers(loadedSummary, web.workers);
          invoices = _mergeInvoiceLists(invoices, web.billsByWorker);
        }
      }
      _sharedSummary = loadedSummary;
      _sharedEmployees = _mergeEmployees(loadedSummary, invoices);
      _sharedLoadedAt = DateTime.now();
    } catch (e, s) {
      if (kDebugMode) debugPrint('Employee performance prefetch: $e\n$s');
    }
  }

  static void clearGlobalCache({bool clearTimerOnly = false}) {
    if (!clearTimerOnly) {
      _sharedEmployees = [];
      _sharedSummary = const EmployeePerformanceSummary();
      _sharedLoadedAt = null;
    }
    _timerCache = null;
    _timerCacheAt = null;
  }

  static bool _isSharedFresh() {
    return (_sharedEmployees.isNotEmpty ||
            _sharedSummary.kpiCards.isNotEmpty ||
            _sharedSummary.apiEmployees.isNotEmpty) &&
        _sharedLoadedAt != null &&
        DateTime.now().difference(_sharedLoadedAt!) < _cacheTtl;
  }

  Future<void> fetch(
    BuildContext context, {
    bool forceRefresh = false,
    bool silent = false,
    /// When false, return after KPI summary so pull-to-refresh spinner ends
    /// quickly; invoice attach continues in the background.
    bool waitForInvoices = true,
  }) async {
    if (forceRefresh) {
      // Keep payment-history invoice cache if still fresh — the heavy 500-row
      // download is what makes pull-to-refresh feel stuck. Summary API is
      // always re-fetched below.
      clearGlobalCache(clearTimerOnly: true);
      _sharedLoadedAt = null;
    } else if (_isSharedFresh()) {
      employees = List<EmployeeBillsGroup>.from(_sharedEmployees);
      summary = _sharedSummary;
      error = '';
      info = '';
      _safeNotify();
      return;
    }

    if (!silent) {
      loading = true;
      error = '';
      info = '';
      _safeNotify();
    }

    try {
      if (_disposed) return;
      final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
      final sessionId = loginModel.sessionId;
      if (sessionId == null || sessionId.isEmpty) {
        error = 'Session expired. Please log in again.';
        return;
      }

      final webApi = WebApiImpl();

      // 1) Summary first — KPIs / employee rows show quickly.
      var loadedSummary = await _loadSummaryFromApi(webApi, sessionId);
      if (_disposed) return;
      // Flutter API often returns empty workers while the website list has
      // people (e.g. KIRAN, Pharmacy Admin). Fill from website HTML + bills.
      Map<int, List<InvoiceSummaryModel>> webBills = const {};
      if (loadedSummary.apiEmployees.isEmpty) {
        final web = await _loadWorkersWithStatsFromWebsite(loginModel);
        if (_disposed) return;
        if (web.workers.isNotEmpty) {
          loadedSummary = _summaryWithWebWorkers(loadedSummary, web.workers);
          webBills = web.billsByWorker;
        }
      }
      summary = loadedSummary;
      final cachedInvoices = PaymentHistoryService.cachedInvoices;
      final seedInvoices = _mergeInvoiceLists(
        cachedInvoices ?? const <InvoiceSummaryModel>[],
        webBills,
      );
      employees = _mergeEmployees(summary, seedInvoices);
      loading = false;
      _safeNotify();

      if (!waitForInvoices) {
        unawaited(_refreshInvoiceAttach(
          sessionId,
          forceRefresh: forceRefresh,
          extraInvoices: seedInvoices,
        ));
        return;
      }

      await _refreshInvoiceAttach(
        sessionId,
        forceRefresh: forceRefresh,
        extraInvoices: seedInvoices,
      );
    } catch (e, s) {
      if (kDebugMode) debugPrint('$e\n$s');
      if (employees.isEmpty) {
        error = 'Network error. Please check your connection and try again.';
      }
    } finally {
      loading = false;
      _safeNotify();
    }
  }

  Future<void> _refreshInvoiceAttach(
    String sessionId, {
    required bool forceRefresh,
    List<InvoiceSummaryModel> extraInvoices = const [],
  }) async {
    final invoices = await _loadInvoices(
      sessionId,
      forceRefresh: forceRefresh && !PaymentHistoryService.hasFreshCache,
    );
    // Prefer website worker bills (have billed_by) over anonymous history.
    final byKey = <String, InvoiceSummaryModel>{};
    void put(InvoiceSummaryModel inv) {
      final key = (inv.id != null && inv.id! > 0)
          ? 'id:${inv.id}'
          : 'no:${inv.displayNumber}';
      if (key == 'no:' || key == 'id:0') return;
      byKey[key] = inv;
    }

    for (final inv in invoices) {
      put(inv);
    }
    for (final inv in extraInvoices) {
      put(inv);
    }
    employees = _mergeEmployees(summary, byKey.values.toList(growable: false));
    _sharedEmployees = List<EmployeeBillsGroup>.from(employees);
    _sharedSummary = summary;
    _sharedLoadedAt = DateTime.now();

    if (employees.isEmpty &&
        summary.effectiveKpiCards.isEmpty &&
        error.isEmpty) {
      error = 'No employee performance data found';
    }
    _safeNotify();
  }

  List<InvoiceSummaryModel> get allInvoices {
    final seen = <String>{};
    final out = <InvoiceSummaryModel>[];
    for (final group in employees) {
      for (final inv in group.invoices) {
        final key =
            '${inv.id ?? ''}|${inv.displayNumber}|${inv.invoiceDate ?? ''}';
        if (seen.add(key)) out.add(inv);
      }
    }
    out.sort((a, b) {
      final d = (b.invoiceDate ?? '').compareTo(a.invoiceDate ?? '');
      if (d != 0) return d;
      return (b.invoiceNumber ?? '').compareTo(a.invoiceNumber ?? '');
    });
    return out;
  }

  /// Paid bills only — matches website "Bills Completed Today".
  List<InvoiceSummaryModel> get paidInvoices =>
      allInvoices.where(_isPaidBill).toList(growable: false);

  static bool _isPaidBill(InvoiceSummaryModel inv) {
    if (inv.isPaid) return true;
    if (inv.sectionKey == 'paid') return true;
    final status = inv.displayPaymentHistoryStatus.toLowerCase().trim();
    if (status == 'paid') return true;
    final payment = (inv.paymentState ?? '').toLowerCase().trim();
    return payment == 'paid' || payment == 'in_payment';
  }

  static List<EmployeeTimerLog>? _timerCache;
  static DateTime? _timerCacheAt;
  static const _timerCacheTtl = Duration(seconds: 45);

  Future<List<EmployeeTimerLog>> fetchActiveTimerLogs(
    BuildContext context, {
    bool forceRefresh = false,
  }) async {
    final kpiLimit = summary.activeSessions > 0 ? summary.activeSessions : 1;

    if (!forceRefresh &&
        _timerCache != null &&
        _timerCacheAt != null &&
        DateTime.now().difference(_timerCacheAt!) < _timerCacheTtl) {
      return _capLogs(_timerCache!, kpiLimit);
    }

    // Instant local rows from already-loaded performance summary.
    final local = _localActiveSessionLogs();
    List<EmployeeTimerLog> running = local;

    try {
      final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
      final sessionId = loginModel.sessionId;

      // Laravel get_employee_performance_list; else local Flutter KPI rows.
      if (sessionId != null && sessionId.isNotEmpty) {
        final fromApi = await _loadActiveTimersFromApi(sessionId);
        if (fromApi.isNotEmpty) {
          running = fromApi;
        }
      }
    } catch (e, s) {
      if (kDebugMode) debugPrint('fetchActiveTimerLogs: $e\n$s');
    }

    if (running.isEmpty) running = local;

    running = _capLogs(running, kpiLimit);
    _timerCache = running;
    _timerCacheAt = DateTime.now();
    return running;
  }

  /// Immediate rows from KPI employee data (no network).
  List<EmployeeTimerLog> quickActiveSessionLogs() {
    final kpiLimit = summary.activeSessions > 0 ? summary.activeSessions : 1;
    if (_timerCache != null &&
        _timerCacheAt != null &&
        DateTime.now().difference(_timerCacheAt!) < _timerCacheTtl) {
      return _capLogs(_timerCache!, kpiLimit);
    }
    return _capLogs(_localActiveSessionLogs(), kpiLimit);
  }

  /// Immediate rows from KPI employee data (no network).
  List<EmployeeTimerLog> _localActiveSessionLogs() {
    return employees
        .where((e) => e.activeSessions > 0)
        .map((e) {
          final billing = (e.performance?.fullBillingMonth ?? 0) > 0
              ? 'Full Billing'
              : ((e.performance?.halfBillingMonth ?? 0) > 0
                  ? 'Half Billing'
                  : 'Full Billing');
          return EmployeeTimerLog.fromEmployee(
            employeeName: e.employeeName,
            invoiceNo: e.invoices.isNotEmpty
                ? e.invoices.first.displayNumber
                : null,
            activeSessions: e.activeSessions,
            billing: billing,
            workDuration: null,
          ).enriched();
        })
        .toList(growable: false);
  }

  static List<EmployeeTimerLog> _capLogs(
    List<EmployeeTimerLog> logs,
    int kpiLimit,
  ) {
    if (logs.length <= kpiLimit) return logs;
    return logs.take(kpiLimit).toList(growable: false);
  }

  static List<EmployeeTimerLog> _onlyRunningLogs(List<EmployeeTimerLog> logs) {
    return logs.where((log) {
      final status = (log.status ?? '').toLowerCase().trim();
      if (status.contains('run') || status.contains('progress')) return true;
      if (status.isEmpty || status == 'false') {
        final end = (log.end ?? '').trim();
        return end.isEmpty || end == 'false';
      }
      return false;
    }).toList(growable: false);
  }

  static Future<List<InvoiceSummaryModel>> _loadInvoices(
    String sessionId, {
    bool forceRefresh = false,
  }) async {
    try {
      return await PaymentHistoryService.fetchInvoices(
        sessionId: sessionId,
        limit: 500,
        forceRefresh: forceRefresh,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('employee invoices: $e');
      return const [];
    }
  }

  Future<List<EmployeeTimerLog>> _loadActiveTimersFromApi(
    String sessionId,
  ) async {
    try {
      final response = await WebApiImpl().fetchInvoiceList(
        endpointPath: EndPoint.employeePerformanceList.path,
        userDetails: ApiRequestHelper.jsonRpcCall({
          'section': 'active_timers',
          'type': 'active_timers',
        }),
        sessionId: sessionId,
        logResponseBody: false,
      );
      if (response.statusCode != 200) return const [];
      final body = _decodeMap(response.body);
      if (body == null) return const [];
      final result = body['result'];
      final root = result is Map
          ? Map<String, dynamic>.from(result)
          : Map<String, dynamic>.from(body);
      final status = '${root['status'] ?? ''}'.trim().toLowerCase();
      if (status == 'error' || status == 'fail' || status == 'failed') {
        return const [];
      }
      final data = root['data'];
      final candidates = <dynamic>[
        if (data is Map) data['active_timers'],
        if (data is Map) data['timers'],
        if (data is Map) data['records'],
        if (data is Map) data['items'],
        if (data is List) data,
        root['active_timers'],
        root['timers'],
        root['records'],
        root['items'],
      ];
      for (final candidate in candidates) {
        if (candidate is! List) continue;
        final logs = candidate
            .whereType<Map>()
            .map((e) => EmployeeTimerLog.fromJson(Map<String, dynamic>.from(e)))
            .map((e) => e.enriched())
            .toList(growable: false);
        final running = _onlyRunningLogs(logs);
        if (running.isNotEmpty) return running;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('active timers api: $e');
    }
    return const [];
  }

  static Future<({String email, String password, String? token})>
      _webCredentials(LoginViewmodel loginModel) async {
    var email = (loginModel.loginEmail ?? '').trim();
    var password = loginModel.loginPassword ?? '';
    var token = AuthSessionStore.currentApiToken;
    if (email.isEmpty || password.isEmpty || token.isEmpty) {
      final saved = await AuthSessionStore.load();
      if (saved != null) {
        if (email.isEmpty) email = saved.email.trim();
        if (password.isEmpty) password = saved.password;
        if (token.isEmpty) token = saved.apiToken.trim();
      }
    }
    return (email: email, password: password, token: token);
  }

  static Future<
      ({
        List<EmployeePerformanceRow> workers,
        Map<int, List<InvoiceSummaryModel>> billsByWorker,
      })> _loadWorkersWithStatsFromWebsite(
    LoginViewmodel loginModel,
  ) async {
    final empty = (
      workers: const <EmployeePerformanceRow>[],
      billsByWorker: const <int, List<InvoiceSummaryModel>>{},
    );
    final creds = await _webCredentials(loginModel);
    if (creds.email.isEmpty || creds.password.isEmpty) {
      if (kDebugMode) {
        debugPrint(
          'employee web workers: missing credentials '
          'emailEmpty=${creds.email.isEmpty} passEmpty=${creds.password.isEmpty}',
        );
      }
      return empty;
    }
    try {
      if (kDebugMode) {
        debugPrint('employee web workers: fetching via website…');
      }
      return await EmployeePerformanceWebApi.fetchWorkersWithStats(
        email: creds.email,
        password: creds.password,
        apiToken: creds.token,
      );
    } catch (e, s) {
      if (kDebugMode) debugPrint('employee web workers: $e\n$s');
      return empty;
    }
  }

  static EmployeePerformanceSummary _summaryWithWebWorkers(
    EmployeePerformanceSummary base,
    List<EmployeePerformanceRow> workers,
  ) {
    final todayTotal =
        workers.fold<int>(0, (sum, w) => sum + w.billsToday);
    return base.copyWith(
      apiEmployees: workers,
      employeeCount: base.employeeCount > 0 ? base.employeeCount : workers.length,
      homeCount: base.homeCount > 0 ? base.homeCount : workers.length,
      billsCompletedToday:
          base.billsCompletedToday > 0 ? base.billsCompletedToday : todayTotal,
    );
  }

  static List<InvoiceSummaryModel> _mergeInvoiceLists(
    List<InvoiceSummaryModel> base,
    Map<int, List<InvoiceSummaryModel>> byWorker,
  ) {
    final byKey = <String, InvoiceSummaryModel>{};
    void put(InvoiceSummaryModel inv) {
      final key = (inv.id != null && inv.id! > 0)
          ? 'id:${inv.id}'
          : 'no:${inv.displayNumber}';
      if (key == 'no:' || key == 'id:0') return;
      byKey[key] = inv;
    }

    for (final inv in base) {
      put(inv);
    }
    for (final list in byWorker.values) {
      for (final inv in list) {
        put(inv);
      }
    }
    return byKey.values.toList(growable: false);
  }

  /// Website `/employee-performance/{id}/bills` — Flutter invoice APIs omit
  /// `billed_by`, so local merge often has zero rows for a worker.
  Future<List<InvoiceSummaryModel>> fetchWorkerBills(
    BuildContext context, {
    required EmployeeBillsGroup group,
    DateTime? dateFrom,
    DateTime? dateTo,
  }) async {
    final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
    final workerId = group.performance?.workerId ??
        group.performance?.id ??
        0;
    if (workerId <= 0) {
      return group.invoices;
    }
    final creds = await _webCredentials(loginModel);
    if (creds.email.isEmpty || creds.password.isEmpty) {
      return group.invoices;
    }
    try {
      final fromWeb = await EmployeePerformanceWebApi.fetchWorkerBills(
        email: creds.email,
        password: creds.password,
        workerId: workerId,
        workerName: group.employeeName,
        dateFrom: dateFrom,
        dateTo: dateTo,
        apiToken: creds.token,
      );
      if (fromWeb.isEmpty) return group.invoices;

      // Prefer website rows for this worker; keep any extras already attached.
      final byNumber = <String, InvoiceSummaryModel>{};
      for (final inv in group.invoices) {
        final key = (inv.displayNumber).trim().toUpperCase();
        if (key.isNotEmpty) byNumber[key] = inv;
      }
      for (final inv in fromWeb) {
        final key = (inv.displayNumber).trim().toUpperCase();
        if (key.isEmpty) continue;
        byNumber[key] = inv;
      }
      final merged = byNumber.values.toList()
        ..sort((a, b) {
          final d = (b.invoiceDate ?? '').compareTo(a.invoiceDate ?? '');
          if (d != 0) return d;
          return (b.invoiceNumber ?? '').compareTo(a.invoiceNumber ?? '');
        });
      return merged;
    } catch (e, s) {
      if (kDebugMode) debugPrint('fetchWorkerBills: $e\n$s');
      return group.invoices;
    }
  }

  static Future<EmployeePerformanceSummary> _loadSummaryFromApi(
    WebApiImpl webApi,
    String sessionId,
  ) async {
    try {
      final response = await webApi.fetchInvoiceList(
        endpointPath: EndPoint.employeePerformance.path,
        userDetails: ApiRequestHelper.jsonRpcCall({}),
        sessionId: sessionId,
        logResponseBody: false,
      );

      if (response.statusCode != 200) {
        return const EmployeePerformanceSummary();
      }

      final body = _decodeMap(response.body);
      if (body == null) {
        return const EmployeePerformanceSummary();
      }

      final result = body['result'];
      final statusSource =
          result is Map ? Map<String, dynamic>.from(result) : body;
      final status = '${statusSource['status'] ?? ''}'.trim().toLowerCase();
      if (status == 'error' || status == 'fail' || status == 'failed') {
        return const EmployeePerformanceSummary();
      }

      return EmployeePerformanceSummary.fromResponse(body);
    } catch (e) {
      if (kDebugMode) debugPrint('employee performance summary: $e');
      return const EmployeePerformanceSummary();
    }
  }

  static Map<String, dynamic>? _decodeMap(String body) {
    final trimmed = body.trim();
    if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return null;
    try {
      final decoded = json.decode(trimmed);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (e) {
      if (kDebugMode) debugPrint('json decode failed: $e');
    }
    return null;
  }

  /// Prefer website employee rows; attach invoices by billed_by name.
  static List<EmployeeBillsGroup> _mergeEmployees(
    EmployeePerformanceSummary summary,
    List<InvoiceSummaryModel> invoices,
  ) {
    final byBilledBy = <String, List<InvoiceSummaryModel>>{};
    for (final invoice in invoices) {
      final billedBy = invoice.billedBy?.trim();
      if (billedBy == null || billedBy.isEmpty) continue;
      byBilledBy.putIfAbsent(billedBy.toLowerCase(), () => []).add(invoice);
    }

    List<InvoiceSummaryModel> invoicesFor(String name) {
      final list = byBilledBy[name.trim().toLowerCase()] ?? const [];
      return List<InvoiceSummaryModel>.from(list)
        ..sort((a, b) {
          final dateCompare =
              (b.invoiceDate ?? '').compareTo(a.invoiceDate ?? '');
          if (dateCompare != 0) return dateCompare;
          return (b.invoiceNumber ?? '').compareTo(a.invoiceNumber ?? '');
        });
    }

    if (summary.apiEmployees.isNotEmpty) {
      return summary.apiEmployees
          .map(
            (row) => EmployeeBillsGroup(
              employeeName: row.displayName,
              invoices: invoicesFor(row.displayName),
              performance: row,
            ),
          )
          .toList(growable: false);
    }

    return byBilledBy.entries
        .map((entry) {
          final name = entry.value.first.billedBy?.trim() ?? entry.key;
          return EmployeeBillsGroup(
            employeeName: name,
            invoices: List<InvoiceSummaryModel>.from(entry.value)
              ..sort((a, b) {
                final dateCompare =
                    (b.invoiceDate ?? '').compareTo(a.invoiceDate ?? '');
                if (dateCompare != 0) return dateCompare;
                return (b.invoiceNumber ?? '')
                    .compareTo(a.invoiceNumber ?? '');
              }),
          );
        })
        .toList()
      ..sort((a, b) => a.employeeName.compareTo(b.employeeName));
  }
}
