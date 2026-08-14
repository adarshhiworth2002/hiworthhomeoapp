import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/employee_performance_model.dart';
import '../../models/employee_timer_log_model.dart';
import '../../models/invoice_summary_model.dart';
import '../../viewModels/employee_performance_viewmodel.dart';
import '../widgets/system_safe.dart';
import 'employee_performance_page.dart';
import '../theme.dart';

/// Website "Completed Today" — paid bills in date range.
class CompletedTodayPage extends StatefulWidget {
  const CompletedTodayPage({
    super.key,
    required this.invoices,
    this.reportDate,
    this.expectedCount,
  });

  /// Already paid invoices from the viewmodel.
  final List<InvoiceSummaryModel> invoices;
  final String? reportDate;
  final int? expectedCount;

  @override
  State<CompletedTodayPage> createState() => _CompletedTodayPageState();
}

class _CompletedTodayPageState extends State<CompletedTodayPage> {
  late DateTime _fromDate;
  late DateTime _toDate;
  late List<InvoiceSummaryModel> _source;
  late List<InvoiceSummaryModel> _results;

  @override
  void initState() {
    super.initState();
    final report = _parseDate(widget.reportDate) ?? _dateOnly(DateTime.now());
    _fromDate = report;
    _toDate = report;
    _source = widget.invoices;
    _results = _filter();
  }

  bool _isPaid(InvoiceSummaryModel inv) {
    if (inv.isPaid) return true;
    if (inv.sectionKey == 'paid') return true;
    return inv.displayPaymentHistoryStatus.toLowerCase().trim() == 'paid';
  }

  List<InvoiceSummaryModel> _filter() {
    return _source.where((inv) {
      if (!_isPaid(inv)) return false;
      final d = _parseDate(inv.invoiceDate);
      if (d == null) return false;
      if (d.isBefore(_fromDate) || d.isAfter(_toDate)) return false;
      return true;
    }).toList(growable: false);
  }

  Future<void> _onRefresh() async {
    final model = context.read<EmployeePerformanceViewModel>();
    await model.fetch(
      context,
      forceRefresh: true,
      waitForInvoices: false,
    );
    if (!mounted) return;
    setState(() {
      _source = model.paidInvoices;
      _results = _filter();
    });
  }

  Future<void> _pickFrom() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _fromDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      builder: _dateTheme,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _fromDate = _dateOnly(picked);
      if (_toDate.isBefore(_fromDate)) _toDate = _fromDate;
    });
  }

  Future<void> _pickTo() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _toDate,
      firstDate: _fromDate,
      lastDate: DateTime.now().add(const Duration(days: 365)),
      builder: _dateTheme,
    );
    if (picked == null || !mounted) return;
    setState(() => _toDate = _dateOnly(picked));
  }

  Widget _dateTheme(BuildContext context, Widget? child) {
    return Theme(
      data: Theme.of(context).copyWith(
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFE07A2F),
          onPrimary: Colors.white,
          surface: Color(0xFF2A2A2A),
          onSurface: Colors.white,
        ),
      ),
      child: child!,
    );
  }

  void _search() => setState(() => _results = _filter());

  void _openRow(InvoiceSummaryModel invoice) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EmployeeInvoiceOpenPage(invoice: invoice),
      ),
    );
  }

  void _openView(InvoiceSummaryModel invoice) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EmployeeBillDetailsPage(invoice: invoice),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: sectionBg,
      appBar: AppBar(
        iconTheme: const IconThemeData(color: sectionText),
        backgroundColor: sectionBg,
        elevation: 0,
        title: const Text(
          'Completed Today',
          style: TextStyle(
            color: Color(0xFFE53935),
            fontWeight: FontWeight.w800,
            fontSize: 18,
          ),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: SystemSafe.horizontalPadding(context, bottom: 8),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _DateField(
                        label: 'Date From',
                        value: _fmtDate(_fromDate),
                        onTap: _pickFrom,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _DateField(
                        label: 'Date To',
                        value: _fmtDate(_toDate),
                        onTap: _pickTo,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _search,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF2F80ED),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text(
                      'Search',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${_results.length} paid bill(s)'
                      '${widget.expectedCount != null ? ' · KPI: ${widget.expectedCount}' : ''}',
                      style: TextStyle(
                        color: sectionTextMuted,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              color: const Color(0xFFE07A2F),
              onRefresh: _onRefresh,
              child: _results.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        SizedBox(
                          height: MediaQuery.sizeOf(context).height * 0.35,
                          child: const Center(
                            child: Text(
                              'No paid bills in this date range',
                              style: TextStyle(color: sectionTextMuted),
                            ),
                          ),
                        ),
                      ],
                    )
                  : ListView.separated(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: SystemSafe.listPadding(context, top: 0),
                      itemCount: _results.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                      final inv = _results[index];
                      final walkIn = (inv.displayCustomer ?? '')
                          .toLowerCase()
                          .contains('walk-in');
                      final status = inv.displayPaymentHistoryStatus;
                      return Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => _openRow(inv),
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: sectionCard,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.18),
                              ),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              inv.displayNumber,
                                              style: TextStyle(
                                                color: walkIn
                                                    ? const Color(0xFFE53935)
                                                    : const Color(0xFF42A5F5),
                                                fontWeight: FontWeight.w800,
                                                fontSize: 14,
                                              ),
                                            ),
                                          ),
                                          _StatusPill(status),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      _Line(
                                        'Invoice Date',
                                        _fmtRawDate(inv.invoiceDate),
                                        color: walkIn
                                            ? const Color(0xFFE53935)
                                            : const Color(0xFF42A5F5),
                                      ),
                                      _Line(
                                        'Customer',
                                        inv.displayCustomer ?? '—',
                                        color: walkIn
                                            ? const Color(0xFFE53935)
                                            : const Color(0xFF42A5F5),
                                      ),
                                      _Line(
                                        'Work Hours',
                                        (inv.workHours ?? '').trim().isEmpty
                                            ? '—'
                                            : inv.workHours!,
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                FilledButton(
                                  onPressed: () => _openView(inv),
                                  style: FilledButton.styleFrom(
                                    backgroundColor: const Color(0xFF2F80ED),
                                    foregroundColor: Colors.white,
                                    minimumSize: const Size(0, 34),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                    ),
                                  ),
                                  child: const Text('View'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Website "Cash/Credit Timer Logs" filtered to In Progress / Running.
class ActiveSessionsTimerLogsPage extends StatefulWidget {
  const ActiveSessionsTimerLogsPage({super.key});

  @override
  State<ActiveSessionsTimerLogsPage> createState() =>
      _ActiveSessionsTimerLogsPageState();
}

class _ActiveSessionsTimerLogsPageState
    extends State<ActiveSessionsTimerLogsPage> {
  bool _loading = true;
  bool _refreshing = false;
  List<EmployeeTimerLog> _logs = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load({bool forceRefresh = false}) async {
    final model = context.read<EmployeePerformanceViewModel>();

    // Show local/cached rows immediately — no spinner wait when we already have data.
    final instant = model.quickActiveSessionLogs();
    if (instant.isNotEmpty && mounted) {
      setState(() {
        _logs = instant;
        _loading = false;
        _refreshing = true;
      });
    } else if (mounted) {
      setState(() {
        _loading = true;
        _refreshing = false;
      });
    }

    final logs = await model.fetchActiveTimerLogs(
      context,
      forceRefresh: forceRefresh,
    );
    if (!mounted) return;
    setState(() {
      _logs = logs;
      _loading = false;
      _refreshing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final kpiCount =
        context.watch<EmployeePerformanceViewModel>().summary.activeSessions;

    return Scaffold(
      backgroundColor: sectionBg,
      appBar: AppBar(
        iconTheme: const IconThemeData(color: sectionText),
        backgroundColor: sectionBg,
        elevation: 0,
        title: const Text(
          'Cash/Credit Timer Logs',
          style: TextStyle(
            color: sectionText,
            fontWeight: FontWeight.w500,
            fontSize: 15,
          ),
        ),
        actions: [
          if (_refreshing)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFFE07A2F),
                  ),
                ),
              ),
            ),
          IconButton(
            onPressed: _refreshing
                ? null
                : () => _load(forceRefresh: true),
            icon: const Icon(Icons.refresh, color: sectionText),
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFFE07A2F)),
            )
          : RefreshIndicator(
              color: const Color(0xFFE07A2F),
              onRefresh: () => _load(forceRefresh: true),
              child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _FilterChipLabel('All Status'),
                    _FilterChipLabel('In Progress', active: true),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '${_logs.length} record(s)'
                  '${kpiCount > 0 ? ' · KPI: $kpiCount' : ''}',
                  style: TextStyle(
                    color: sectionTextMuted,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 12),
                if (_logs.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 40),
                    child: Center(
                      child: Text(
                        'No running sessions',
                        style: TextStyle(color: sectionTextMuted),
                      ),
                    ),
                  )
                else
                  for (final log in _logs)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) =>
                                    ActiveSessionBillDetailPage(log: log),
                              ),
                            );
                          },
                          child: Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: sectionCard,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.18),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        log.invoiceNo ?? '—',
                                        style: const TextStyle(
                                          color: sectionText,
                                          fontWeight: FontWeight.w800,
                                          fontSize: 15,
                                        ),
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF26A69A),
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: Text(
                                        (log.status ?? 'Running')
                                                    .toUpperCase() ==
                                                'RUNNING'
                                            ? 'Running'
                                            : (log.status ?? 'Running'),
                                        style: const TextStyle(
                                          color: sectionText,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Icon(
                                      Icons.chevron_right,
                                      color:
                                          Colors.white.withValues(alpha: 0.5),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                _Line('Worked By', log.workedBy ?? '—'),
                                _Line(
                                  'Started By',
                                  log.startedBy ?? log.workedBy ?? '—',
                                  emphasize: true,
                                ),
                                _Line('Billing', log.billing ?? '—'),
                                _Line('Start', log.start ?? '—'),
                                _Line(
                                  'End',
                                  (log.end ?? '').trim().isEmpty
                                      ? '—'
                                      : log.end!,
                                ),
                                _Line('Break Time', log.breakTime ?? '00:00'),
                                _Line(
                                  'Work Duration',
                                  log.workDuration ?? '—',
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
              ],
            ),
            ),
    );
  }
}

/// Website form when opening an Active Session bill / timer log.
class ActiveSessionBillDetailPage extends StatefulWidget {
  const ActiveSessionBillDetailPage({super.key, required this.log});

  final EmployeeTimerLog log;

  @override
  State<ActiveSessionBillDetailPage> createState() =>
      _ActiveSessionBillDetailPageState();
}

class _ActiveSessionBillDetailPageState
    extends State<ActiveSessionBillDetailPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  late EmployeeTimerLog _log;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this, initialIndex: 1);
    _log = widget.log.enriched();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final log = _log;
    final startedBy = log.startedBy ?? log.workedBy ?? '—';
    final workedBy = log.workedBy ?? '—';
    final users = log.allUsersOnBill ?? workedBy;
    final completed = log.completedBy ?? workedBy;
    final duration = log.workDuration ?? '00:00:00';
    final breakTime = log.breakTime ?? '00:00';
    final status = log.status ?? 'Running';

    return Scaffold(
      backgroundColor: sectionBg,
      appBar: AppBar(
        iconTheme: const IconThemeData(color: sectionText),
        backgroundColor: sectionBg,
        elevation: 0,
        title: Text(
          log.invoiceNo ?? 'Active Session',
          style: const TextStyle(
            color: sectionText,
            fontWeight: FontWeight.w500,
            fontSize: 15,
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              color: const Color(0xFFE07A2F),
              onRefresh: () async {},
              child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
              children: [
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: sectionCard,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.18),
                    ),
                  ),
                  child: Column(
                    children: [
                      _DetailField('Invoice No', log.invoiceNo ?? '—'),
                      _DetailField('Invoice Ref', log.invoiceRef ?? '/'),
                      _DetailField(
                        'Invoice',
                        log.invoiceLabel ?? log.invoiceNo ?? '—',
                      ),
                      _DetailField('All Users on Bill', users, emphasize: true),
                      _DetailField(
                        'Worked By (This Session)',
                        workedBy,
                        emphasize: true,
                      ),
                      _DetailField('Started By', startedBy, emphasize: true),
                      _DetailField('Completed By', completed, emphasize: true),
                      _DetailField(
                        'Billing Stage',
                        log.billing ?? 'Full Billing',
                      ),
                      _DetailField(
                        'Start Time',
                        log.start ?? '—',
                        emphasize: true,
                      ),
                      _DetailField(
                        'End Time',
                        (log.end ?? '').trim().isEmpty ? '—' : log.end!,
                      ),
                      _DetailField('Breaks', '${log.breaksCount ?? 0}'),
                      _DetailField(
                        'Total Break Time',
                        breakTime,
                        emphasize: true,
                      ),
                      _DetailField(
                        'Session Work Duration',
                        duration,
                        emphasize: true,
                      ),
                      _DetailField('Status', status),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                TabBar(
                  controller: _tabs,
                  labelColor: sectionAccent,
                  unselectedLabelColor: sectionTextMuted,
                  indicatorColor: const Color(0xFFE07A2F),
                  tabs: const [
                    Tab(text: 'User Timings'),
                    Tab(text: 'All Bill Sessions'),
                    Tab(text: 'Breaks'),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 260,
                  child: TabBarView(
                    controller: _tabs,
                    children: [
                      // Website User Timings:
                      // Invoice No | User | Role | Start | End | Break Time | Work Duration
                      _UserTimingsTab(
                        invoiceNo: log.invoiceNo ?? '—',
                        user: startedBy,
                        role: 'Started',
                        start: log.start ?? '—',
                        end: (log.end ?? '').trim().isEmpty ? '' : log.end!,
                        breakTime: '',
                        workDuration: '',
                      ),
                      // Website All Bill Sessions:
                      // Invoice No | Worked By | Started By | Billing | Status | Start | End | Break Time | Work Duration
                      _AllBillSessionsTab(
                        invoiceNo: log.invoiceNo ?? '—',
                        workedBy: workedBy,
                        startedBy: startedBy,
                        billing: log.billing ?? 'Full Billing',
                        status: status,
                        start: log.start ?? '—',
                        end: (log.end ?? '').trim().isEmpty ? '' : log.end!,
                        breakTime: breakTime == '00:00' ? '00:00' : breakTime,
                        workDuration: duration,
                      ),
                      // Website Breaks: Hold | Restart | Restarted By | Break Duration
                      const _BreaksTab(),
                    ],
                  ),
                ),
              ],
            ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailField extends StatelessWidget {
  const _DetailField(this.label, this.value, {this.emphasize = false});

  final String label;
  final String value;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: TextStyle(
                color: sectionTextMuted,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: emphasize ? const Color(0xFFFF8A80) : Colors.white,
                fontSize: 13,
                fontWeight: emphasize ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Website "User Timings" tab — Invoice No, User, Role, Start, End, Break Time, Work Duration.
class _UserTimingsTab extends StatelessWidget {
  const _UserTimingsTab({
    required this.invoiceNo,
    required this.user,
    required this.role,
    required this.start,
    required this.end,
    required this.breakTime,
    required this.workDuration,
  });

  final String invoiceNo;
  final String user;
  final String role;
  final String start;
  final String end;
  final String breakTime;
  final String workDuration;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: sectionCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                invoiceNo,
                style: const TextStyle(
                  color: sectionText,
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 8),
              _Line('User', user, emphasize: true),
              _Line('Role', role),
              _Line('Start', start),
              _Line('End', end.isEmpty ? '—' : end),
              _Line('Break Time', breakTime.isEmpty ? '—' : breakTime),
              _Line(
                'Work Duration',
                workDuration.isEmpty ? '—' : workDuration,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Website "All Bill Sessions" tab.
class _AllBillSessionsTab extends StatelessWidget {
  const _AllBillSessionsTab({
    required this.invoiceNo,
    required this.workedBy,
    required this.startedBy,
    required this.billing,
    required this.status,
    required this.start,
    required this.end,
    required this.breakTime,
    required this.workDuration,
  });

  final String invoiceNo;
  final String workedBy;
  final String startedBy;
  final String billing;
  final String status;
  final String start;
  final String end;
  final String breakTime;
  final String workDuration;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: sectionCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      invoiceNo,
                      style: const TextStyle(
                        color: sectionText,
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF26A69A),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      status,
                      style: const TextStyle(
                        color: sectionText,
                        fontWeight: FontWeight.w700,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _Line('Worked By', workedBy),
              _Line('Started By', startedBy, emphasize: true),
              _Line('Billing', billing),
              _Line('Start', start),
              _Line('End', end.isEmpty ? '—' : end),
              _Line('Break Time', breakTime),
              _Line('Work Duration', workDuration),
            ],
          ),
        ),
      ],
    );
  }
}

/// Website "Breaks" tab (empty while Running).
class _BreaksTab extends StatelessWidget {
  const _BreaksTab();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'No breaks',
        style: TextStyle(color: sectionTextMuted, fontSize: 13),
      ),
    );
  }
}

/// Website Employee Performance Graph with measure selector.
class EmployeePerformanceGraphPage extends StatefulWidget {
  const EmployeePerformanceGraphPage({
    super.key,
    required this.employees,
    this.reportDate,
  });

  final List<EmployeeBillsGroup> employees;
  final String? reportDate;

  @override
  State<EmployeePerformanceGraphPage> createState() =>
      _EmployeePerformanceGraphPageState();
}

class _EmployeePerformanceGraphPageState
    extends State<EmployeePerformanceGraphPage> {
  EmployeeGraphMeasure _measure = EmployeeGraphMeasure.workMinutes;
  late List<EmployeeBillsGroup> _employees;

  @override
  void initState() {
    super.initState();
    _employees = widget.employees;
  }

  Future<void> _onRefresh() async {
    final model = context.read<EmployeePerformanceViewModel>();
    await model.fetch(
      context,
      forceRefresh: true,
      waitForInvoices: false,
    );
    if (!mounted) return;
    setState(() => _employees = model.employees);
  }

  double _valueFor(EmployeeBillsGroup e) {
    final p = e.performance;
    switch (_measure) {
      case EmployeeGraphMeasure.workMinutes:
        return p?.workMinutesTotal ?? 0;
      case EmployeeGraphMeasure.billsToday:
        return (p?.billsToday ?? e.billsToday).toDouble();
      case EmployeeGraphMeasure.billsMonth:
        return (p?.billsMonth ?? 0).toDouble();
      case EmployeeGraphMeasure.totalBills:
        return (p?.totalBills ?? e.count).toDouble();
      case EmployeeGraphMeasure.activeSessions:
        return (p?.activeSessions ?? e.activeSessions).toDouble();
      case EmployeeGraphMeasure.avgWorkMinutesToday:
        return p?.avgWorkMinutesToday ?? 0;
      case EmployeeGraphMeasure.halfBillingMonth:
        return (p?.halfBillingMonth ?? 0).toDouble();
      case EmployeeGraphMeasure.fullBillingMonth:
        return (p?.fullBillingMonth ?? 0).toDouble();
      case EmployeeGraphMeasure.count:
        return 1;
    }
  }

  void _openEmployee(EmployeeBillsGroup group) {
    switch (_measure) {
      case EmployeeGraphMeasure.activeSessions:
        if (group.activeSessions > 0) {
          final model = context.read<EmployeePerformanceViewModel>();
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ChangeNotifierProvider.value(
                value: model,
                child: const ActiveSessionsTimerLogsPage(),
              ),
            ),
          );
          return;
        }
        break;
      case EmployeeGraphMeasure.billsToday:
        final model = context.read<EmployeePerformanceViewModel>();
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ChangeNotifierProvider.value(
              value: model,
              child: CompletedTodayPage(
                invoices: model.paidInvoices
                    .where(
                      (inv) =>
                          (inv.billedBy ?? '').trim().toLowerCase() ==
                          group.employeeName.trim().toLowerCase(),
                    )
                    .toList(growable: false),
                reportDate: widget.reportDate,
                expectedCount: group.billsToday,
              ),
            ),
          ),
        );
        return;
      default:
        break;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChangeNotifierProvider.value(
          value: context.read<EmployeePerformanceViewModel>(),
          child: EmployeeBillsListPage(group: group),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final values = _employees.map(_valueFor).toList(growable: false);
    final maxVal = values.fold<double>(0, (m, v) => v > m ? v : m);
    final chartMax = maxVal <= 0 ? 1.0 : maxVal;

    return Scaffold(
      backgroundColor: sectionBg,
      appBar: AppBar(
        iconTheme: const IconThemeData(color: sectionText),
        backgroundColor: sectionBg,
        elevation: 0,
        title: const Text(
          'Employee Performance Graph',
          style: TextStyle(
            color: sectionText,
            fontWeight: FontWeight.w500,
            fontSize: 15,
          ),
        ),
      ),
      body: RefreshIndicator(
        color: const Color(0xFFE07A2F),
        onRefresh: _onRefresh,
        child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
        children: [
          if (widget.reportDate != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                'Report date: ${_fmtRawDate(widget.reportDate)}',
                style: TextStyle(
                  color: sectionTextMuted,
                  fontSize: 12,
                ),
              ),
            ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: sectionCard,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: sectionCardBorder),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<EmployeeGraphMeasure>(
                value: _measure,
                isExpanded: true,
                dropdownColor: const Color(0xFF2A2A2A),
                iconEnabledColor: Colors.white,
                style: const TextStyle(color: sectionText, fontSize: 14),
                items: [
                  for (final m in EmployeeGraphMeasure.values)
                    DropdownMenuItem(value: m, child: Text(m.label)),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _measure = v);
                },
              ),
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
            decoration: BoxDecoration(
              color: sectionCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: sectionCardBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      color: const Color(0xFF42A5F5),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _measure.label,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.8),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                SizedBox(
                  height: 220,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (var i = 0; i < _employees.length; i++) ...[
                        if (i > 0) const SizedBox(width: 10),
                        Expanded(
                          child: _BarColumn(
                            label: _employees[i].employeeName,
                            value: values[i],
                            maxValue: chartMax,
                            onTap: () => _openEmployee(_employees[i]),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    'Employee · tap a bar to open',
                    style: TextStyle(
                      color: sectionTextMuted,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          for (var i = 0; i < _employees.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => _openEmployee(_employees[i]),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: sectionCard,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _employees[i].employeeName,
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                        Text(
                          _fmtNum(values[i]),
                          style: const TextStyle(
                            color: Color(0xFF42A5F5),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.chevron_right,
                          color: sectionTextMuted,
                          size: 18,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      ),
    );
  }
}

class _BarColumn extends StatelessWidget {
  const _BarColumn({
    required this.label,
    required this.value,
    required this.maxValue,
    this.onTap,
  });

  final String label;
  final double value;
  final double maxValue;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final h = maxValue <= 0 ? 0.0 : (value / maxValue) * 160;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Text(
            _fmtNum(value),
            style: const TextStyle(color: sectionTextMuted, fontSize: 10),
          ),
          const SizedBox(height: 4),
          Container(
            height: h.clamp(2, 160),
            decoration: BoxDecoration(
              color: const Color(0xFF42A5F5),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(color: sectionTextMuted, fontSize: 10),
          ),
        ],
      ),
    );
  }
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(color: sectionTextMuted),
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.08),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
        child: Text(value, style: const TextStyle(color: Colors.white)),
      ),
    );
  }
}

class _FilterChipLabel extends StatelessWidget {
  const _FilterChipLabel(this.text, {this.active = false});

  final String text;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: active
            ? const Color(0xFF7B5EA7).withValues(alpha: 0.35)
            : Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: active
              ? const Color(0xFF7B5EA7)
              : Colors.white.withValues(alpha: 0.2),
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: Colors.white.withValues(alpha: active ? 1 : 0.75),
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill(this.status);

  final String status;

  @override
  Widget build(BuildContext context) {
    final paid = status.toLowerCase().contains('paid');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: paid ? const Color(0xFFE53935) : const Color(0xFF7B5EA7),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        status,
        style: const TextStyle(
          color: sectionText,
          fontWeight: FontWeight.w700,
          fontSize: 11,
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value, {this.color, this.emphasize = false});

  final String label;
  final String value;
  final Color? color;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: TextStyle(
                color: sectionTextMuted,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: color ??
                    (emphasize ? const Color(0xFFFF8A80) : Colors.white),
                fontSize: 12,
                fontWeight: emphasize ? FontWeight.w700 : FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

DateTime _dateOnly(DateTime v) => DateTime(v.year, v.month, v.day);

DateTime? _parseDate(String? value) {
  if (value == null) return null;
  final text = value.trim();
  if (text.isEmpty) return null;
  final iso = DateTime.tryParse(text);
  if (iso != null) return _dateOnly(iso);
  final slash = RegExp(r'^(\d{1,2})[/-](\d{1,2})[/-](\d{4})$').firstMatch(text);
  if (slash != null) {
    final a = int.parse(slash.group(1)!);
    final b = int.parse(slash.group(2)!);
    final y = int.parse(slash.group(3)!);
    if (a > 12) return DateTime(y, b, a);
    return DateTime(y, a, b);
  }
  return null;
}

String _fmtDate(DateTime v) {
  final m = v.month.toString().padLeft(2, '0');
  final d = v.day.toString().padLeft(2, '0');
  return '$m/$d/${v.year}';
}

String _fmtRawDate(String? value) {
  final p = _parseDate(value);
  if (p == null) return value?.trim().isNotEmpty == true ? value!.trim() : '—';
  return _fmtDate(p);
}

String _fmtNum(double v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v.toStringAsFixed(2);
}
