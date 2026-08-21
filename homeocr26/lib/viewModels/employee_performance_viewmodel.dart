import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/services/WebApi/web_api_impl.dart';
import '../features/services/api_request_helper.dart';
import '../features/services/endPoints.dart';
import '../features/services/odoo_rpc_helper.dart';
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

  static List<EmployeeBillsGroup> _sharedEmployees = [];
  static EmployeePerformanceSummary _sharedSummary =
      const EmployeePerformanceSummary();
  static DateTime? _sharedLoadedAt;
  static const _cacheTtl = Duration(seconds: 60);

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

      final invoices = results[0] as List<InvoiceSummaryModel>;
      final loadedSummary = results[1] as EmployeePerformanceSummary;
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
      notifyListeners();
      return;
    }

    if (!silent) {
      loading = true;
      error = '';
      info = '';
      notifyListeners();
    }

    try {
      final loginModel = Provider.of<LoginViewmodel>(context, listen: false);
      final sessionId = loginModel.sessionId;
      if (sessionId == null || sessionId.isEmpty) {
        error = 'Session expired. Please log in again.';
        return;
      }

      final webApi = WebApiImpl();

      // 1) Summary first — KPIs / employee rows show quickly.
      final loadedSummary = await _loadSummaryFromApi(webApi, sessionId);
      summary = loadedSummary;
      final cachedInvoices = PaymentHistoryService.cachedInvoices;
      employees = _mergeEmployees(
        summary,
        cachedInvoices ?? const <InvoiceSummaryModel>[],
      );
      loading = false;
      notifyListeners();

      if (!waitForInvoices) {
        unawaited(_refreshInvoiceAttach(sessionId, forceRefresh: forceRefresh));
        return;
      }

      await _refreshInvoiceAttach(sessionId, forceRefresh: forceRefresh);
    } catch (e, s) {
      if (kDebugMode) debugPrint('$e\n$s');
      if (employees.isEmpty) {
        error = 'Network error. Please check your connection and try again.';
      }
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> _refreshInvoiceAttach(
    String sessionId, {
    required bool forceRefresh,
  }) async {
    final invoices = await _loadInvoices(
      sessionId,
      forceRefresh: forceRefresh && !PaymentHistoryService.hasFreshCache,
    );
    employees = _mergeEmployees(summary, invoices);
    _sharedEmployees = List<EmployeeBillsGroup>.from(employees);
    _sharedSummary = summary;
    _sharedLoadedAt = DateTime.now();

    if (employees.isEmpty &&
        summary.effectiveKpiCards.isEmpty &&
        error.isEmpty) {
      error = 'No employee performance data found';
    }
    notifyListeners();
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
  static String? _cachedTimerModel;

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
      final email = loginModel.loginEmail;
      final password = loginModel.loginPassword;

      // Prefer a single Odoo read (cached model) — skip slow multi-param Flutter probes.
      if (email != null &&
          email.isNotEmpty &&
          password != null &&
          password.isNotEmpty) {
        final webSid = await OdooRpcHelper.cachedWebSessionId(
          db: LoginViewmodel.dbName,
          login: email,
          password: password,
        ).timeout(const Duration(seconds: 8), onTimeout: () => null);

        if (webSid != null && webSid.isNotEmpty) {
          final rows = await OdooRpcHelper.searchActiveTimerLogs(
            webSid,
            preferredModel: _cachedTimerModel,
          ).timeout(const Duration(seconds: 10), onTimeout: () => const []);

          final fromOdoo = _onlyRunningLogs(
            rows
                .map(EmployeeTimerLog.fromJson)
                .map((e) => e.enriched())
                .toList(growable: false),
          );
          if (fromOdoo.isNotEmpty) {
            running = fromOdoo;
            final modelHint = OdooRpcHelper.lastTimerModelUsed;
            if (modelHint != null && modelHint.isNotEmpty) {
              _cachedTimerModel = modelHint;
            }
          }
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

      if (body['result'] is Map &&
          (body['result'] as Map)['status'] == 'error') {
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
