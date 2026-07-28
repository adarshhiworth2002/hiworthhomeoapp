import 'invoice_summary_model.dart';

class EmployeePerformanceSummary {
  const EmployeePerformanceSummary({
    this.reportDate,
    this.homeCount = 0,
    this.billsCompletedToday = 0,
    this.activeSessions = 0,
    this.avgWorkTimeToday,
    this.employeeCount = 0,
    this.kpiCards = const [],
    this.apiEmployees = const [],
  });

  final String? reportDate;
  final int homeCount;
  final int billsCompletedToday;
  final int activeSessions;
  final String? avgWorkTimeToday;
  final int employeeCount;
  final List<EmployeeKpiCard> kpiCards;
  final List<EmployeePerformanceRow> apiEmployees;

  factory EmployeePerformanceSummary.fromResponse(Map<String, dynamic> response) {
    Map<String, dynamic> data = const {};

    final result = response['result'];
    if (result is Map) {
      final root = Map<String, dynamic>.from(result);
      final dataNode = root['data'];
      if (dataNode is Map) {
        data = Map<String, dynamic>.from(dataNode);
      } else if (root.containsKey('report_date')) {
        data = root;
      }
    } else if (response['data'] is Map) {
      data = Map<String, dynamic>.from(response['data'] as Map);
    } else if (response.containsKey('report_date')) {
      data = response;
    }

    if (data.isEmpty) return const EmployeePerformanceSummary();

    final kpiRaw = data['kpi_cards'];
    final kpiCards = <EmployeeKpiCard>[];
    if (kpiRaw is List) {
      for (final item in kpiRaw) {
        if (item is Map) {
          kpiCards.add(EmployeeKpiCard.fromJson(Map<String, dynamic>.from(item)));
        }
      }
      kpiCards.sort((a, b) => a.sequence.compareTo(b.sequence));
    }

    final empRaw = data['employees'];
    final apiEmployees = <EmployeePerformanceRow>[];
    if (empRaw is List) {
      for (final item in empRaw) {
        if (item is Map) {
          apiEmployees.add(
            EmployeePerformanceRow.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }

    return EmployeePerformanceSummary(
      reportDate: _string(data['report_date']),
      homeCount: _int(data['home_count']) ?? apiEmployees.length,
      billsCompletedToday: _int(data['bills_completed_today']) ?? 0,
      activeSessions: _int(data['active_sessions']) ?? 0,
      avgWorkTimeToday: _string(data['avg_work_time_today']),
      employeeCount: _int(data['employee_count']) ??
          _int(data['count']) ??
          apiEmployees.length,
      kpiCards: kpiCards,
      apiEmployees: apiEmployees,
    );
  }

  /// Website-style cards when API omits `kpi_cards`.
  List<EmployeeKpiCard> get effectiveKpiCards {
    if (kpiCards.isNotEmpty) return kpiCards;
    return [
      EmployeeKpiCard(
        id: 1,
        name: 'Bills Completed Today',
        count: '$billsCompletedToday',
        icon: 'fa-check-circle',
        accent: 'accent-sales',
        sequence: 1,
      ),
      EmployeeKpiCard(
        id: 2,
        name: 'Active Sessions',
        count: '$activeSessions',
        icon: 'fa-clock-o',
        accent: 'accent-expiry',
        sequence: 2,
      ),
      EmployeeKpiCard(
        id: 5,
        name: 'Avg Work Time (Today)',
        count: avgWorkTimeToday ?? '00:00',
        icon: 'fa-hourglass-half',
        accent: 'accent-stock',
        sequence: 3,
      ),
      const EmployeeKpiCard(
        id: 6,
        name: 'Performance Graph',
        count: 'View',
        icon: 'fa-line-chart',
        accent: 'accent-payment',
        sequence: 4,
      ),
      EmployeeKpiCard(
        id: 7,
        name: 'Employee List',
        count: '${employeeCount > 0 ? employeeCount : homeCount}',
        icon: 'fa-users',
        accent: 'accent-stock',
        sequence: 5,
      ),
    ];
  }

  static int? _int(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  static String? _string(dynamic value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty || text == 'false') return null;
    return text;
  }
}

class EmployeeKpiCard {
  const EmployeeKpiCard({
    required this.id,
    required this.name,
    required this.count,
    this.icon,
    this.accent,
    this.sequence = 0,
  });

  final int id;
  final String name;
  final String count;
  final String? icon;
  final String? accent;
  final int sequence;

  factory EmployeeKpiCard.fromJson(Map<String, dynamic> json) {
    return EmployeeKpiCard(
      id: EmployeePerformanceSummary._int(json['id']) ?? 0,
      name: EmployeePerformanceSummary._string(json['name']) ?? 'KPI',
      count: EmployeePerformanceSummary._string(json['count']) ?? '0',
      icon: EmployeePerformanceSummary._string(json['icon']),
      accent: EmployeePerformanceSummary._string(json['accent']),
      sequence: EmployeePerformanceSummary._int(json['sequence']) ?? 0,
    );
  }

  EmployeeKpiKind get kind {
    final n = name.toLowerCase();
    if (n.contains('bill') && n.contains('today')) {
      return EmployeeKpiKind.billsCompletedToday;
    }
    if (n.contains('active') && n.contains('session')) {
      return EmployeeKpiKind.activeSessions;
    }
    if (n.contains('avg') || n.contains('work time')) {
      return EmployeeKpiKind.avgWorkTime;
    }
    if (n.contains('graph') || n.contains('performance')) {
      return EmployeeKpiKind.performanceGraph;
    }
    if (n.contains('employee')) return EmployeeKpiKind.employeeList;
    switch (id) {
      case 1:
        return EmployeeKpiKind.billsCompletedToday;
      case 2:
        return EmployeeKpiKind.activeSessions;
      case 5:
        return EmployeeKpiKind.avgWorkTime;
      case 6:
        return EmployeeKpiKind.performanceGraph;
      case 7:
        return EmployeeKpiKind.employeeList;
      default:
        return EmployeeKpiKind.employeeList;
    }
  }
}

enum EmployeeKpiKind {
  billsCompletedToday,
  activeSessions,
  avgWorkTime,
  performanceGraph,
  employeeList,
}

class EmployeePerformanceRow {
  const EmployeePerformanceRow({
    required this.id,
    required this.displayName,
    this.employeeId,
    this.workerId,
    this.billsToday = 0,
    this.billsMonth = 0,
    this.totalBills = 0,
    this.activeSessions = 0,
    this.halfBillingMonth = 0,
    this.fullBillingMonth = 0,
    this.avgWorkMinutesToday = 0,
    this.avgWorkTimeToday,
    this.workMinutesTotal = 0,
  });

  final int id;
  final String displayName;
  final int? employeeId;
  final int? workerId;
  final int billsToday;
  final int billsMonth;
  final int totalBills;
  final int activeSessions;
  final int halfBillingMonth;
  final int fullBillingMonth;
  final double avgWorkMinutesToday;
  final String? avgWorkTimeToday;
  final double workMinutesTotal;

  factory EmployeePerformanceRow.fromJson(Map<String, dynamic> json) {
    final workerName = EmployeePerformanceSummary._string(json['worker_name']);
    final employeeName =
        EmployeePerformanceSummary._string(json['employee_name']);
    return EmployeePerformanceRow(
      id: EmployeePerformanceSummary._int(json['id']) ?? 0,
      displayName: workerName ?? employeeName ?? 'Unknown',
      employeeId: EmployeePerformanceSummary._int(json['employee_id']),
      workerId: EmployeePerformanceSummary._int(json['worker_id']),
      billsToday: EmployeePerformanceSummary._int(json['bills_today']) ?? 0,
      billsMonth: EmployeePerformanceSummary._int(json['bills_month']) ?? 0,
      totalBills: EmployeePerformanceSummary._int(json['total_bills']) ?? 0,
      activeSessions:
          EmployeePerformanceSummary._int(json['active_sessions']) ?? 0,
      halfBillingMonth:
          EmployeePerformanceSummary._int(json['half_billing_month']) ?? 0,
      fullBillingMonth:
          EmployeePerformanceSummary._int(json['full_billing_month']) ?? 0,
      avgWorkMinutesToday:
          _double(json['avg_work_minutes_today']) ?? 0,
      avgWorkTimeToday:
          EmployeePerformanceSummary._string(json['avg_work_time_today']),
      workMinutesTotal: _double(json['work_minutes_total']) ?? 0,
    );
  }

  static double? _double(dynamic value) {
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }
}

class EmployeeBillsGroup {
  const EmployeeBillsGroup({
    required this.employeeName,
    required this.invoices,
    this.performance,
  });

  final String employeeName;
  final List<InvoiceSummaryModel> invoices;
  final EmployeePerformanceRow? performance;

  int get count => invoices.length;

  int get billsToday => performance?.billsToday ?? 0;
  int get activeSessions => performance?.activeSessions ?? 0;
  String get avgWorkTimeToday =>
      performance?.avgWorkTimeToday ?? '00:00';
}
