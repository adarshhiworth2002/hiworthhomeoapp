import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/prefix_search.dart';
import '../../models/employee_performance_model.dart';
import '../../models/invoice_summary_model.dart';
import '../../viewModels/employee_performance_viewmodel.dart';
import '../widgets/app_responsive.dart';
import '../widgets/system_safe.dart';
import 'employee_kpi_pages.dart';
import 'list_search_field.dart';
import 'live_refresh_mixin.dart';
import '../theme.dart';

class EmployeePerformancePage extends StatefulWidget {
  const EmployeePerformancePage({
    super.key,
    this.showKpiEntry = true,
    this.viewModel,
  });

  /// When false (opened from KPI Dashboard), hide the KPI entry button so
  /// only the employee list is shown. Back then returns to the KPI screen.
  final bool showKpiEntry;

  /// Shared VM when opened from [EmployeeKpiDashboardPage]; otherwise owned here.
  final EmployeePerformanceViewModel? viewModel;

  @override
  State<EmployeePerformancePage> createState() => _EmployeePerformancePageState();
}

class _EmployeePerformancePageState extends State<EmployeePerformancePage>
    with LiveRefreshMixin {
  late final EmployeePerformanceViewModel _viewModel;
  late final bool _ownsViewModel;
  late final TextEditingController _searchController;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _ownsViewModel = widget.viewModel == null;
    _viewModel = widget.viewModel ?? EmployeePerformanceViewModel();
    _searchController = TextEditingController();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (_ownsViewModel || _viewModel.employees.isEmpty) {
        await _viewModel.fetch(context);
      }
    });
    if (_ownsViewModel) {
      startLiveRefresh(
        () => _viewModel.fetch(
          context,
          forceRefresh: true,
          silent: true,
          waitForInvoices: false,
        ),
      );
    }
  }

  @override
  void dispose() {
    if (_ownsViewModel) {
      stopLiveRefresh();
    }
    _searchController.dispose();
    if (_ownsViewModel) {
      _viewModel.dispose();
    }
    super.dispose();
  }

  void _openKpiDashboard(EmployeePerformanceViewModel model) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChangeNotifierProvider.value(
          value: model,
          child: const EmployeeKpiDashboardPage(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final listOnly = !widget.showKpiEntry;
    return ChangeNotifierProvider.value(
      value: _viewModel,
      child: Scaffold(
        backgroundColor: sectionBg,
        appBar: AppBar(
          iconTheme: const IconThemeData(color: sectionText),
          backgroundColor: sectionBg,
          elevation: 0,
          title: Text(
            listOnly ? 'Employee List' : 'Employee Performance',
            style: const TextStyle(
              color: sectionText,
              fontWeight: FontWeight.w500,
              fontSize: 15,
            ),
          ),
          actions: [
            IconButton(
              onPressed: () => _viewModel.fetch(context, forceRefresh: true),
              icon: const Icon(Icons.refresh, color: sectionText),
            ),
          ],
        ),
        body: ResponsiveBody(
          child: Consumer<EmployeePerformanceViewModel>(
          builder: (context, model, _) {
            final hasEmployees = model.employees.isNotEmpty;
            final hasKpis = model.summary.effectiveKpiCards.isNotEmpty;

            if (model.loading && !hasEmployees && !hasKpis) {
              return const Center(
                child: CircularProgressIndicator(color: Color(0xFFE07A2F)),
              );
            }

            if (!hasEmployees && !hasKpis) {
              return RefreshIndicator(
                color: const Color(0xFFE07A2F),
                onRefresh: () => model.fetch(
                  context,
                  forceRefresh: true,
                  waitForInvoices: false,
                ),
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    SizedBox(
                      height: MediaQuery.sizeOf(context).height * 0.45,
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                model.error.isNotEmpty
                                    ? model.error
                                    : 'No employee performance data found',
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: sectionTextMuted),
                              ),
                              const SizedBox(height: 16),
                              FilledButton(
                                onPressed: () =>
                                    model.fetch(context, forceRefresh: true),
                                child: const Text('Retry'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }

            final employees = model.employees
                .where(
                  (e) => PrefixSearch.matches(e.employeeName, _searchQuery),
                )
                .toList(growable: false);

            return RefreshIndicator(
              onRefresh: () => model.fetch(
                context,
                forceRefresh: true,
                waitForInvoices: false,
              ),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: SystemSafe.listPadding(context, top: 10, extraBottom: 24),
                children: [
                  if (model.summary.reportDate != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(
                        'Report date: ${_formatDate(model.summary.reportDate)}',
                        style: TextStyle(
                          color: sectionTextMuted,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  if (widget.showKpiEntry) ...[
                    _KpiDashboardEntryButton(
                      billsToday: model.summary.billsCompletedToday,
                      activeSessions: model.summary.activeSessions,
                      employeeCount: model.summary.employeeCount > 0
                          ? model.summary.employeeCount
                          : model.employees.length,
                      onTap: () => _openKpiDashboard(model),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'Employee List',
                      style: TextStyle(
                        color: sectionTextMuted,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  ListSearchField(
                    controller: _searchController,
                    hintText: 'Search employee name…',
                    onChanged: (value) => setState(() => _searchQuery = value),
                  ),
                  const SizedBox(height: 10),
                  if (employees.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 40),
                      child: Center(
                        child: Text(
                          _searchQuery.trim().isEmpty
                              ? 'No employees found'
                              : 'No matches for "$_searchQuery"',
                          style: const TextStyle(color: sectionTextMuted),
                        ),
                      ),
                    )
                  else
                    ...employees.map(
                      (group) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _EmployeeCard(
                          group: group,
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => ChangeNotifierProvider.value(
                                  value: model,
                                  child: EmployeeBillsListPage(group: group),
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
          },
        ),
        ),
      ),
    );
  }
}

class _KpiDashboardEntryButton extends StatelessWidget {
  const _KpiDashboardEntryButton({
    required this.billsToday,
    required this.activeSessions,
    required this.employeeCount,
    required this.onTap,
  });

  final int billsToday;
  final int activeSessions;
  final int employeeCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                const Color(0xFF2F80ED).withValues(alpha: 0.35),
                const Color(0xFF7B5EA7).withValues(alpha: 0.28),
              ],
            ),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: sectionCardBorder),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.dashboard_customize_outlined,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'KPI Dashboard',
                      style: TextStyle(
                        color: sectionText,
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Bills $billsToday · Sessions $activeSessions · Employees $employeeCount',
                      style: TextStyle(
                        color: sectionTextMuted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_ios, color: Colors.white, size: 16),
            ],
          ),
        ),
      ),
    );
  }
}

/// Separate screen for website-style KPI cards.
class EmployeeKpiDashboardPage extends StatelessWidget {
  const EmployeeKpiDashboardPage({super.key});

  void _openKpiDetails(BuildContext context, EmployeeKpiCard card) {
    final model = context.read<EmployeePerformanceViewModel>();
    switch (card.kind) {
      case EmployeeKpiKind.employeeList:
        // Push list-only screen so Back returns to this KPI Dashboard.
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ChangeNotifierProvider.value(
              value: model,
              child: EmployeePerformancePage(
                showKpiEntry: false,
                viewModel: model,
              ),
            ),
          ),
        );
        return;
      case EmployeeKpiKind.performanceGraph:
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ChangeNotifierProvider.value(
              value: model,
              child: EmployeePerformanceGraphPage(
                employees: model.employees,
                reportDate: model.summary.reportDate,
              ),
            ),
          ),
        );
        return;
      case EmployeeKpiKind.billsCompletedToday:
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ChangeNotifierProvider.value(
              value: model,
              child: CompletedTodayPage(
                invoices: model.paidInvoices,
                reportDate: model.summary.reportDate,
                expectedCount: model.summary.billsCompletedToday,
              ),
            ),
          ),
        );
        return;
      case EmployeeKpiKind.activeSessions:
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ChangeNotifierProvider.value(
              value: model,
              child: const ActiveSessionsTimerLogsPage(),
            ),
          ),
        );
        return;
      case EmployeeKpiKind.avgWorkTime:
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => _EmployeeKpiDetailPage(
              title: card.name,
              subtitle:
                  'Overall avg: ${model.summary.avgWorkTimeToday ?? '00:00'}',
              rows: model.employees
                  .map(
                    (e) => _KpiDetailRow(
                      title: e.employeeName,
                      value: e.avgWorkTimeToday,
                      subtitle: 'Avg work time today',
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
        );
        return;
    }
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
          'KPI Dashboard',
          style: TextStyle(
            color: sectionText,
            fontWeight: FontWeight.w500,
            fontSize: 15,
          ),
        ),
      ),
      body: ResponsiveBody(
        child: Consumer<EmployeePerformanceViewModel>(
        builder: (context, model, _) {
          return RefreshIndicator(
            color: const Color(0xFFE07A2F),
            onRefresh: () => model.fetch(
              context,
              forceRefresh: true,
              waitForInvoices: false,
            ),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: SystemSafe.listPadding(context, top: 10, extraBottom: 24),
              children: [
                if (model.summary.reportDate != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      'Report date: ${_formatDate(model.summary.reportDate)}',
                      style: TextStyle(
                        color: sectionTextMuted,
                        fontSize: 12,
                      ),
                    ),
                  ),
                _KpiDashboard(
                  cards: model.summary.effectiveKpiCards,
                  onViewDetails: (card) => _openKpiDetails(context, card),
                ),
              ],
            ),
          );
        },
      ),
      ),
    );
  }
}


class EmployeeBillsListPage extends StatefulWidget {
  const EmployeeBillsListPage({super.key, required this.group});

  final EmployeeBillsGroup group;

  @override
  State<EmployeeBillsListPage> createState() => _EmployeeBillsListPageState();
}

class _EmployeeBillsListPageState extends State<EmployeeBillsListPage> {
  late final TextEditingController _searchController;
  late EmployeeBillsGroup _group;
  String _searchQuery = '';
  DateTime? _fromDate;
  DateTime? _toDate;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _group = widget.group;
    // Match website: default to today so the list opens on the current range.
    final today = _dateOnly(DateTime.now());
    _fromDate = today;
    _toDate = today;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _onRefresh() async {
    final model = context.read<EmployeePerformanceViewModel>();
    await model.fetch(
      context,
      forceRefresh: true,
      waitForInvoices: false,
    );
    if (!mounted) return;
    final name = widget.group.employeeName.trim().toLowerCase();
    EmployeeBillsGroup? match;
    for (final e in model.employees) {
      if (e.employeeName.trim().toLowerCase() == name) {
        match = e;
        break;
      }
    }
    setState(() {
      if (match != null) _group = match;
    });
  }

  Future<void> _pickFrom() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _fromDate ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.light(
            primary: Color(0xFFE07A2F),
            onPrimary: Colors.white,
            surface: Colors.white,
            onSurface: Colors.black,
          ),
        ),
        child: child!,
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _fromDate = _dateOnly(picked);
      if (_toDate != null && _toDate!.isBefore(_fromDate!)) {
        _toDate = _fromDate;
      }
    });
  }

  Future<void> _pickTo() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _toDate ?? _fromDate ?? DateTime.now(),
      firstDate: _fromDate ?? DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.light(
            primary: Color(0xFFE07A2F),
            onPrimary: Colors.white,
            surface: Colors.white,
            onSurface: Colors.black,
          ),
        ),
        child: child!,
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _toDate = _dateOnly(picked));
  }

  void _clearDates() {
    setState(() {
      _fromDate = null;
      _toDate = null;
    });
  }

  List<InvoiceSummaryModel> get _filteredInvoices {
    return _group.invoices.where((invoice) {
      if (!_invoiceInDateRange(invoice.invoiceDate, _fromDate, _toDate)) {
        return false;
      }
      return PrefixSearch.matchesAny(
        [invoice.displayCustomer, invoice.displayNumber, invoice.invoiceNumber],
        _searchQuery,
      );
    }).toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final invoices = _filteredInvoices;
    final hasDateFilter = _fromDate != null || _toDate != null;

    return Scaffold(
      backgroundColor: sectionBg,
      appBar: AppBar(
        iconTheme: const IconThemeData(color: sectionText),
        backgroundColor: sectionBg,
        elevation: 0,
        title: Text(
          _group.employeeName,
          style: const TextStyle(
            color: sectionText,
            fontWeight: FontWeight.w500,
            fontSize: 15,
          ),
        ),
      ),
      body: ResponsiveBody(
        child: Column(
        children: [
          Padding(
            padding: SystemSafe.horizontalPadding(context, bottom: 0),
            child: _DateRangeFilterBar(
              fromDate: _fromDate,
              toDate: _toDate,
              onPickFrom: _pickFrom,
              onPickTo: _pickTo,
              onClear: hasDateFilter ? _clearDates : null,
            ),
          ),
          Padding(
            padding: SystemSafe.horizontalPadding(context, bottom: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${invoices.length} bill(s)'
                '${hasDateFilter ? ' in selected range' : ''}',
                style: TextStyle(
                  color: sectionTextMuted,
                  fontSize: 12,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: ListSearchField(
              controller: _searchController,
              hintText: 'Search customer or invoice no…',
              onChanged: (value) => setState(() => _searchQuery = value),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              color: const Color(0xFFE07A2F),
              onRefresh: _onRefresh,
              child: invoices.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        SizedBox(
                          height: MediaQuery.sizeOf(context).height * 0.35,
                          child: Center(
                            child: Text(
                              _emptyBillsMessage(
                                searchQuery: _searchQuery,
                                hasDateFilter: hasDateFilter,
                              ),
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: sectionTextMuted),
                            ),
                          ),
                        ),
                      ],
                    )
                  : ListView.separated(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: SystemSafe.listPadding(context, top: 0),
                      itemCount: invoices.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final invoice = invoices[index];
                        return _InvoiceListCard(
                          invoice: invoice,
                          onRowTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) =>
                                    EmployeeInvoiceOpenPage(invoice: invoice),
                              ),
                            );
                          },
                          onViewTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) =>
                                    EmployeeBillDetailsPage(invoice: invoice),
                              ),
                            );
                          },
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
      ),
    );
  }
}

class _DateRangeFilterBar extends StatelessWidget {
  const _DateRangeFilterBar({
    required this.fromDate,
    required this.toDate,
    required this.onPickFrom,
    required this.onPickTo,
    this.onClear,
  });

  final DateTime? fromDate;
  final DateTime? toDate;
  final VoidCallback onPickFrom;
  final VoidCallback onPickTo;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: sectionCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sectionCardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Date filter',
                style: TextStyle(
                  color: sectionTextMuted,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
              const Spacer(),
              if (onClear != null)
                TextButton(
                  onPressed: onClear,
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFE07A2F),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('Clear', style: TextStyle(fontSize: 12)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _DateChip(
                  label: 'From',
                  value: fromDate == null ? 'Any' : _formatDateOnly(fromDate!),
                  onTap: onPickFrom,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _DateChip(
                  label: 'To',
                  value: toDate == null ? 'Any' : _formatDateOnly(toDate!),
                  onTap: onPickTo,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DateChip extends StatelessWidget {
  const _DateChip({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            color: sectionCard,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: sectionCardBorder),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: sectionTextMuted,
                        fontSize: 10,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: sectionText,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.calendar_today_outlined,
                size: 16,
                color: sectionTextMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _emptyBillsMessage({
  required String searchQuery,
  required bool hasDateFilter,
}) {
  if (searchQuery.trim().isNotEmpty) {
    return 'No matches for "$searchQuery"';
  }
  if (hasDateFilter) {
    return 'No bills in this date range';
  }
  return 'No bills found';
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

String _formatDateOnly(DateTime value) {
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  return '$month/$day/${value.year}';
}

DateTime? _parseInvoiceDate(String? value) {
  if (value == null) return null;
  final text = value.trim();
  if (text.isEmpty) return null;

  final iso = DateTime.tryParse(text);
  if (iso != null) return _dateOnly(iso);

  // MM/DD/YYYY or DD/MM/YYYY — prefer year-last with month first (app format).
  final slash = RegExp(r'^(\d{1,2})[/-](\d{1,2})[/-](\d{4})$').firstMatch(text);
  if (slash != null) {
    final a = int.parse(slash.group(1)!);
    final b = int.parse(slash.group(2)!);
    final y = int.parse(slash.group(3)!);
    if (a > 12) return DateTime(y, b, a); // DD/MM/YYYY
    return DateTime(y, a, b); // MM/DD/YYYY
  }

  return null;
}

bool _invoiceInDateRange(
  String? invoiceDate,
  DateTime? fromDate,
  DateTime? toDate,
) {
  if (fromDate == null && toDate == null) return true;
  final parsed = _parseInvoiceDate(invoiceDate);
  if (parsed == null) return false;
  if (fromDate != null && parsed.isBefore(fromDate)) return false;
  if (toDate != null && parsed.isAfter(toDate)) return false;
  return true;
}

/// Screenshot 3 — Open: Invoices (tap anywhere on bill row).
class EmployeeInvoiceOpenPage extends StatelessWidget {
  const EmployeeInvoiceOpenPage({super.key, required this.invoice});

  final InvoiceSummaryModel invoice;

  @override
  Widget build(BuildContext context) {
    final status = invoice.displayPaymentHistoryStatus;
    final invoiceLabel =
        '${invoice.displayNumber} - ${invoice.displayCustomer ?? ''} - ${invoice.invoiceDate ?? ''}';

    return Scaffold(
      backgroundColor: sectionBg,
      appBar: AppBar(
        iconTheme: const IconThemeData(color: sectionText),
        backgroundColor: sectionBg,
        elevation: 0,
        title: const Text(
          'Open: Invoices',
          style: TextStyle(
            color: sectionText,
            fontWeight: FontWeight.w500,
            fontSize: 15,
          ),
        ),
      ),
      body: ResponsiveBody(
        child: RefreshIndicator(
        color: const Color(0xFFE07A2F),
        onRefresh: () async {},
        child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: SystemSafe.listPadding(context, top: 10, extraBottom: 24),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: sectionCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: sectionCardBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Meta('Invoice', invoiceLabel),
                _Meta('Invoice Date', _formatDate(invoice.invoiceDate)),
                _Meta(
                  'Invoice Number',
                  invoice.displayNumber,
                  emphasize: true,
                ),
                _Meta(
                  'Customer Name',
                  invoice.displayCustomer ?? '—',
                  emphasize: true,
                ),
                _Meta(
                  'Total Amount',
                  InvoiceSummaryModel.formatMoney(invoice.total),
                ),
                _Meta('Work Minutes', invoice.workMinutes ?? '0.00'),
                _Meta('Work Hours', invoice.workHours ?? '—'),
                _Meta('Invoice Paid?', invoice.isPaid ? 'Yes' : 'No'),
                _Meta(
                  'Credit Customer',
                  invoice.isCreditCustomer ? 'Yes' : 'No',
                ),
                _Meta(
                  'Expiry Medicine Bill',
                  invoice.expiryMedicineBill ? 'Yes' : 'No',
                ),
                _Meta('Verify Status', invoice.displayVerifyStatus),
                _Meta('Customer Status', status),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _AmountChip('Tax', invoice.taxAmount),
                    const SizedBox(width: 8),
                    _AmountChip('Balance Due', invoice.balance),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _AmountChip('Subtotal', invoice.subtotal),
                    const SizedBox(width: 8),
                    _AmountChip('Total', invoice.total),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
      ),
      ),
    );
  }
}

/// Screenshot 4 — Bill Details (tap View on bill row).
class EmployeeBillDetailsPage extends StatelessWidget {
  const EmployeeBillDetailsPage({super.key, required this.invoice});

  final InvoiceSummaryModel invoice;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: sectionBg,
      appBar: AppBar(
        iconTheme: const IconThemeData(color: sectionText),
        backgroundColor: sectionBg,
        elevation: 0,
        title: const Text(
          'Bill Details',
          style: TextStyle(
            color: sectionText,
            fontWeight: FontWeight.w500,
            fontSize: 15,
          ),
        ),
      ),
      body: ResponsiveBody(
        child: RefreshIndicator(
        color: const Color(0xFFE07A2F),
        onRefresh: () async {},
        child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: SystemSafe.listPadding(context, top: 10, extraBottom: 24),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: sectionCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: sectionCardBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  invoice.displayNumber,
                  style: const TextStyle(
                    color: sectionText,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                _DetailRow(
                  'Date',
                  _formatDate(invoice.invoiceDate),
                ),
                _DetailRow('Invoice Number', invoice.displayNumber),
                _DetailRow('Customer Name', invoice.displayCustomer ?? '—'),
                _DetailRow(
                  'Total Amount',
                  InvoiceSummaryModel.formatMoney(invoice.total),
                ),
                _DetailRow(
                  'Time Taken',
                  invoice.workHours ?? invoice.workMinutes ?? '—',
                ),
              ],
            ),
          ),
        ],
      ),
      ),
      ),
    );
  }
}

class _KpiDashboard extends StatelessWidget {
  const _KpiDashboard({
    required this.cards,
    required this.onViewDetails,
  });

  final List<EmployeeKpiCard> cards;
  final ValueChanged<EmployeeKpiCard> onViewDetails;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final crossAxisCount = width >= 700 ? 4 : width >= 500 ? 3 : 2;
        final spacing = 10.0;
        final itemWidth =
            (width - spacing * (crossAxisCount - 1)) / crossAxisCount;

        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final card in cards)
              SizedBox(
                width: itemWidth,
                child: _WebsiteKpiCard(
                  card: card,
                  onViewDetails: () => onViewDetails(card),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _WebsiteKpiCard extends StatelessWidget {
  const _WebsiteKpiCard({
    required this.card,
    required this.onViewDetails,
  });

  final EmployeeKpiCard card;
  final VoidCallback onViewDetails;

  @override
  Widget build(BuildContext context) {
    final accent = _kpiAccentColor(card.accent, card.kind);
    return Material(
      color: Colors.white,
      elevation: 2,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onViewDetails,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border(
              top: BorderSide(color: accent, width: 3),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  _kpiIcon(card.icon, card.kind),
                  color: accent,
                  size: 22,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                card.name.toUpperCase(),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.blueGrey.shade700,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                  height: 1.15,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                card.count,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.black87,
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  height: 1.1,
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: onViewDetails,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF2F80ED),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    minimumSize: const Size(0, 34),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'VIEW DETAILS',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.2,
                        ),
                      ),
                      SizedBox(width: 4),
                      Icon(Icons.arrow_forward, size: 14),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Color _kpiAccentColor(String? accent, EmployeeKpiKind kind) {
  switch ((accent ?? '').toLowerCase()) {
    case 'accent-sales':
      return const Color(0xFF2E9E5B);
    case 'accent-expiry':
      return const Color(0xFFC9A227);
    case 'accent-stock':
      return const Color(0xFF1FA6A0);
    case 'accent-payment':
      return const Color(0xFF7B5EA7);
  }
  switch (kind) {
    case EmployeeKpiKind.billsCompletedToday:
      return const Color(0xFF2E9E5B);
    case EmployeeKpiKind.activeSessions:
      return const Color(0xFFC9A227);
    case EmployeeKpiKind.avgWorkTime:
      return const Color(0xFF1FA6A0);
    case EmployeeKpiKind.performanceGraph:
      return const Color(0xFF7B5EA7);
    case EmployeeKpiKind.employeeList:
      return const Color(0xFF2E9E5B);
  }
}

IconData _kpiIcon(String? icon, EmployeeKpiKind kind) {
  final key = (icon ?? '').toLowerCase();
  if (key.contains('check')) return Icons.check_circle_outline;
  if (key.contains('clock')) return Icons.access_time;
  if (key.contains('hourglass')) return Icons.hourglass_bottom;
  if (key.contains('line-chart') || key.contains('chart')) {
    return Icons.show_chart;
  }
  if (key.contains('users')) return Icons.groups_outlined;
  switch (kind) {
    case EmployeeKpiKind.billsCompletedToday:
      return Icons.check_circle_outline;
    case EmployeeKpiKind.activeSessions:
      return Icons.access_time;
    case EmployeeKpiKind.avgWorkTime:
      return Icons.hourglass_bottom;
    case EmployeeKpiKind.performanceGraph:
      return Icons.show_chart;
    case EmployeeKpiKind.employeeList:
      return Icons.groups_outlined;
  }
}

class _KpiDetailRow {
  const _KpiDetailRow({
    required this.title,
    required this.value,
    required this.subtitle,
    this.onTap,
  });

  final String title;
  final String value;
  final String subtitle;
  final VoidCallback? onTap;
}

class _EmployeeKpiDetailPage extends StatelessWidget {
  const _EmployeeKpiDetailPage({
    required this.title,
    required this.rows,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final List<_KpiDetailRow> rows;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: sectionBg,
      appBar: AppBar(
        iconTheme: const IconThemeData(color: sectionText),
        backgroundColor: sectionBg,
        elevation: 0,
        title: Text(
          title,
          style: const TextStyle(
            color: sectionText,
            fontWeight: FontWeight.w500,
            fontSize: 15,
          ),
        ),
      ),
      body: ResponsiveBody(
        child: RefreshIndicator(
        color: const Color(0xFFE07A2F),
        onRefresh: () async {},
        child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: SystemSafe.listPadding(context, top: 10, extraBottom: 24),
        children: [
          if (subtitle != null && subtitle!.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                subtitle!,
                style: TextStyle(
                  color: sectionTextMuted,
                  fontSize: 12,
                ),
              ),
            ),
          if (rows.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text(
                  'No details available',
                  style: TextStyle(color: sectionTextMuted),
                ),
              ),
            )
          else
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: row.onTap,
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: sectionCard,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: sectionCardBorder,
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  row.title,
                                  style: const TextStyle(
                                    color: sectionText,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 14,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  row.subtitle,
                                  style: TextStyle(
                                    color: sectionTextMuted,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            row.value,
                            style: const TextStyle(
                              color: Color(0xFFE07A2F),
                              fontWeight: FontWeight.w800,
                              fontSize: 18,
                            ),
                          ),
                          if (row.onTap != null) ...[
                            const SizedBox(width: 6),
                            Icon(
                              Icons.chevron_right,
                              color: sectionTextMuted,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
        ],
      ),
      ),
      ),
    );
  }
}

class _EmployeeCard extends StatelessWidget {
  const _EmployeeCard({required this.group, required this.onTap});

  final EmployeeBillsGroup group;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final perf = group.performance;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: sectionCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: sectionCardBorder),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  group.employeeName,
                  style: const TextStyle(
                    color: sectionText,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    _EmpStatChip(
                      'Today',
                      '${perf?.billsToday ?? group.count}',
                    ),
                    if (perf != null) ...[
                      _EmpStatChip('Month', '${perf.billsMonth}'),
                      _EmpStatChip('Sessions', '${perf.activeSessions}'),
                      _EmpStatChip(
                        'Avg',
                        perf.avgWorkTimeToday ?? '00:00',
                      ),
                    ] else
                      _EmpStatChip('Bills', '${group.count}'),
                  ],
                ),
              ],
            ),
          ),
          OutlinedButton.icon(
            onPressed: onTap,
            style: OutlinedButton.styleFrom(
              foregroundColor: sectionText,
              side: const BorderSide(color: sectionCardBorder),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            icon: const Icon(Icons.receipt_long_outlined, size: 18),
            label: const Text('View Bills'),
          ),
        ],
      ),
    );
  }
}

class _EmpStatChip extends StatelessWidget {
  const _EmpStatChip(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: sectionCard,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '$label $value',
        style: TextStyle(
          color: sectionText,
          fontSize: 11,
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(
              label,
              style: TextStyle(
                color: sectionTextMuted,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              value,
              style: const TextStyle(
                color: sectionText,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InvoiceListCard extends StatelessWidget {
  const _InvoiceListCard({
    required this.invoice,
    required this.onRowTap,
    required this.onViewTap,
  });

  final InvoiceSummaryModel invoice;
  final VoidCallback onRowTap;
  final VoidCallback onViewTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onRowTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          decoration: BoxDecoration(
            color: sectionCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: sectionCardBorder),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: _MiniField(
                            label: 'Invoice Date',
                            value: _formatDate(invoice.invoiceDate),
                          ),
                        ),
                        Expanded(
                          child: _MiniField(
                            label: 'Invoice Number',
                            value: invoice.displayNumber,
                            emphasize: true,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: _MiniField(
                            label: 'Customer',
                            value: invoice.displayCustomer ?? '—',
                          ),
                        ),
                        Expanded(
                          child: _MiniField(
                            label: 'Work Hours',
                            value: invoice.workHours ?? '—',
                          ),
                        ),
                        Expanded(
                          child: _MiniField(
                            label: 'Status',
                            value: invoice.displayPaymentHistoryStatus,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: onViewTap,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFE07A2F),
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: const Text('View', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniField extends StatelessWidget {
  const _MiniField({
    required this.label,
    required this.value,
    this.emphasize = false,
  });

  final String label;
  final String value;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: sectionTextMuted,
              fontSize: 10,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: sectionText,
              fontSize: emphasize ? 13 : 12,
              fontWeight: emphasize ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta(this.label, this.value, {this.emphasize = false});

  final String label;
  final String value;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 135,
            child: Text(
              label,
              style: TextStyle(
                color: sectionTextMuted,
                fontSize: 11,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: emphasize ? const Color(0xFFE53935) : sectionText,
                fontSize: 12,
                fontWeight: emphasize ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AmountChip extends StatelessWidget {
  const _AmountChip(this.label, this.value);

  final String label;
  final double? value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: appOrangeSoft,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                color: sectionTextMuted,
                fontSize: 10,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              InvoiceSummaryModel.formatMoney(value),
              style: const TextStyle(
                color: sectionText,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatDate(String? value) {
  if (value == null || value.trim().isEmpty) return '—';
  final parsed = DateTime.tryParse(value.trim());
  if (parsed == null) return value.trim();
  final month = parsed.month.toString().padLeft(2, '0');
  final day = parsed.day.toString().padLeft(2, '0');
  return '$month/$day/${parsed.year}';
}
