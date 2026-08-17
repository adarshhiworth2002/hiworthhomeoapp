import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/amount_book_model.dart';
import '../../viewModels/amount_book_viewmodel.dart';
import '../theme.dart';
import '../widgets/app_responsive.dart';
import '../widgets/system_safe.dart';
import 'amount_book_customer_detail_page.dart';
import 'live_refresh_mixin.dart';

class AmountBookPage extends StatefulWidget {
  const AmountBookPage({super.key, this.viewModel});

  final AmountBookViewModel? viewModel;

  @override
  State<AmountBookPage> createState() => _AmountBookPageState();
}

class _AmountBookPageState extends State<AmountBookPage>
    with LiveRefreshMixin, SingleTickerProviderStateMixin {
  late final AmountBookViewModel _viewModel;
  late final bool _ownsViewModel;
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _ownsViewModel = widget.viewModel == null;
    _viewModel = widget.viewModel ?? AmountBookViewModel();
    _tabController = TabController(length: 2, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _viewModel.fetch(context, silent: true);
      if (!mounted) return;
      await _viewModel.fetch(context, forceRefresh: true, silent: true);
    });
    startLiveRefresh(
      () => _viewModel.fetch(context, forceRefresh: true, silent: true),
    );
  }

  @override
  void dispose() {
    stopLiveRefresh();
    _tabController.dispose();
    if (_ownsViewModel) {
      _viewModel.dispose();
    }
    super.dispose();
  }

  Future<void> _openFilterSheet() async {
    final result = await showModalBottomSheet<_AmountBookFilterResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: sectionBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => _AmountBookFilterSheet(
        initialFilter: _viewModel.filter,
        parentContext: context,
      ),
    );

    if (!mounted || result == null) return;

    if (result.clear) {
      _viewModel.clearFilter();
      await _viewModel.fetch(context, forceRefresh: true);
      return;
    }

    _viewModel.applyFilter(result.filter);
    await _viewModel.fetch(
      context,
      forceRefresh: true,
      dateFrom: result.filter.dateFrom,
      dateTo: result.filter.dateTo,
    );
  }

  void _openCustomerDetail(AmountBookCustomerSummary summary) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChangeNotifierProvider.value(
          value: _viewModel,
          child: AmountBookCustomerDetailPage(summary: summary),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _viewModel,
      child: Scaffold(
        backgroundColor: sectionBg,
        appBar: AppBar(
          iconTheme: const IconThemeData(color: sectionText),
          title: const Text(
            'Amount Book',
            style: TextStyle(
              color: sectionText,
              fontWeight: FontWeight.w500,
              fontSize: 15,
            ),
          ),
          backgroundColor: sectionAppBar,
          elevation: 0,
          bottom: TabBar(
            controller: _tabController,
            indicatorColor: sectionAccent,
            labelColor: sectionText,
            unselectedLabelColor: sectionTextMuted,
            tabs: const [
              Tab(text: 'Customer'),
              Tab(text: 'Supplier'),
            ],
          ),
          actions: [
            IconButton(
              onPressed: () => _viewModel.fetch(context, forceRefresh: true),
              icon: const Icon(Icons.refresh, color: sectionText),
            ),
          ],
        ),
        body: ResponsiveBody(
          child: TabBarView(
          controller: _tabController,
          children: [
            _CustomerTab(
              onOpenFilter: _openFilterSheet,
              onOpenCustomer: _openCustomerDetail,
            ),
            const _SupplierPlaceholder(),
          ],
        ),
        ),
      ),
    );
  }
}

class _AmountBookFilterResult {
  const _AmountBookFilterResult.apply(this.filter) : clear = false;

  const _AmountBookFilterResult.clearAll()
      : filter = const AmountBookFilter(),
        clear = true;

  final AmountBookFilter filter;
  final bool clear;
}

class _AmountBookFilterSheet extends StatefulWidget {
  const _AmountBookFilterSheet({
    required this.initialFilter,
    required this.parentContext,
  });

  final AmountBookFilter initialFilter;
  final BuildContext parentContext;

  @override
  State<_AmountBookFilterSheet> createState() => _AmountBookFilterSheetState();
}

class _AmountBookFilterSheetState extends State<_AmountBookFilterSheet> {
  late final TextEditingController _nameController;
  DateTime? _from;
  DateTime? _to;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialFilter.nameQuery);
    _from = widget.initialFilter.dateFrom;
    _to = widget.initialFilter.dateTo;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  InputDecoration _fieldDecoration({
    required String label,
    required IconData icon,
  }) {
    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(color: sectionTextMuted),
      prefixIcon: Icon(icon, color: sectionTextMuted),
      filled: true,
      fillColor: sectionCard,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: sectionCardBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: sectionCardBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: sectionAccent),
      ),
    );
  }

  Future<void> _pickDate({required bool isFrom}) async {
    FocusScope.of(context).unfocus();
    final picked = await showDatePicker(
      context: widget.parentContext,
      initialDate: (isFrom ? _from : _to) ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (isFrom) {
        _from = picked;
      } else {
        _to = picked;
      }
    });
  }

  String _formatPickerDate(DateTime date) {
    final d = date.day.toString().padLeft(2, '0');
    final m = date.month.toString().padLeft(2, '0');
    return '$d/$m/${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          12,
          20,
          20 + MediaQuery.paddingOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: sectionCardBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Text(
              'Search & filter',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: sectionText,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nameController,
              style: const TextStyle(color: sectionText, fontSize: 14),
              cursorColor: sectionAccent,
              textInputAction: TextInputAction.done,
              decoration: _fieldDecoration(
                label: 'Customer name',
                icon: Icons.person_outline,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: sectionText,
                      side: BorderSide(
                        color: sectionCardBorder,
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () => _pickDate(isFrom: true),
                    icon: const Icon(Icons.calendar_today, size: 18),
                    label: Text(
                      _from == null ? 'From date' : _formatPickerDate(_from!),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: sectionText,
                      side: BorderSide(
                        color: sectionCardBorder,
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () => _pickDate(isFrom: false),
                    icon: const Icon(Icons.calendar_today, size: 18),
                    label: Text(
                      _to == null ? 'To date' : _formatPickerDate(_to!),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: sectionText,
                      side: BorderSide(
                        color: sectionCardBorder,
                      ),
                    ),
                    onPressed: () {
                      FocusScope.of(context).unfocus();
                      Navigator.pop(
                        context,
                        const _AmountBookFilterResult.clearAll(),
                      );
                    },
                    child: const Text('Clear'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: sectionAccent,
                      foregroundColor: sectionOnAccent,
                    ),
                    onPressed: () {
                      FocusScope.of(context).unfocus();
                      Navigator.pop(
                        context,
                        _AmountBookFilterResult.apply(
                          AmountBookFilter(
                            nameQuery: _nameController.text,
                            dateFrom: _from,
                            dateTo: _to,
                          ),
                        ),
                      );
                    },
                    child: const Text('Apply'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CustomerTab extends StatelessWidget {
  const _CustomerTab({
    required this.onOpenFilter,
    required this.onOpenCustomer,
  });

  final VoidCallback onOpenFilter;
  final void Function(AmountBookCustomerSummary summary) onOpenCustomer;

  @override
  Widget build(BuildContext context) {
    return Consumer<AmountBookViewModel>(
      builder: (context, model, _) {
        final summaries = model.customerSummaries;

        if (model.loading &&
            model.youGotAmount == null &&
            model.youGaveAmount == null) {
          return const Center(
            child: CircularProgressIndicator(color: sectionAccent),
          );
        }

        return RefreshIndicator(
          color: sectionAccent,
          onRefresh: () => model.fetch(context, forceRefresh: true),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: SystemSafe.listPadding(context),
            children: [
              const SizedBox(height: 8),
              _SummaryCard(
                youGot: model.youGotAmount,
                youGave: model.youGaveAmount,
                loading: model.loading,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      model.filter.isActive
                          ? 'Filtered results'
                          : 'All customers',
                      style: TextStyle(
                        color: sectionTextMuted,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Search & filter',
                    onPressed: onOpenFilter,
                    icon: const Icon(Icons.search, color: sectionText),
                  ),
                ],
              ),
              if (model.error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    model.error,
                    style: const TextStyle(color: sectionTextMuted, fontSize: 13),
                  ),
                ),
              if (summaries.isEmpty)
                SizedBox(
                  height: MediaQuery.sizeOf(context).height * 0.35,
                  child: Center(
                    child: Text(
                      model.filter.isActive
                          ? 'No customers match your filter'
                          : 'No customer entries found',
                      style: const TextStyle(color: sectionTextMuted),
                    ),
                  ),
                )
              else
                ...summaries.map(
                  (summary) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _CustomerCard(
                      summary: summary,
                      onTap: () => onOpenCustomer(summary),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.youGot,
    required this.youGave,
    required this.loading,
  });

  final double? youGot;
  final double? youGave;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      decoration: BoxDecoration(
        color: sectionCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: sectionCardBorder),
      ),
      child: Row(
        children: [
          Expanded(
            child: _SummaryColumn(
              label: 'YOU GOT',
              amount: youGot,
              color: sectionAccent,
              loading: loading,
            ),
          ),
          Container(
            width: 1,
            height: 48,
            color: Colors.white.withValues(alpha: 0.18),
          ),
          Expanded(
            child: _SummaryColumn(
              label: 'YOU GAVE',
              amount: youGave,
              color: sectionText,
              loading: loading,
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryColumn extends StatelessWidget {
  const _SummaryColumn({
    required this.label,
    required this.amount,
    required this.color,
    required this.loading,
  });

  final String label;
  final double? amount;
  final Color color;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: color.withValues(alpha: 0.9),
          ),
        ),
        const SizedBox(height: 6),
        if (loading && amount == null)
          SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: color,
            ),
          )
        else
          Text(
            AmountBookViewModel.formatAmount(amount),
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
      ],
    );
  }
}

class _CustomerCard extends StatelessWidget {
  const _CustomerCard({
    required this.summary,
    required this.onTap,
  });

  final AmountBookCustomerSummary summary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: sectionCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: sectionCardBorder),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    summary.customerName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: sectionText,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${summary.entryCount} entr${summary.entryCount == 1 ? 'y' : 'ies'}',
                    style: TextStyle(
                      fontSize: 11,
                      color: sectionTextMuted,
                    ),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  'Balance',
                  style: TextStyle(
                    fontSize: 9,
                    color: sectionTextMuted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  AmountBookViewModel.formatAmount(summary.lastBalance),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: sectionAccent,
                  ),
                ),
              ],
            ),
            Icon(
              Icons.chevron_right,
              color: sectionTextMuted,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

class _SupplierPlaceholder extends StatelessWidget {
  const _SupplierPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.store_outlined,
              size: 48,
              color: Colors.white.withValues(alpha: 0.35),
            ),
            const SizedBox(height: 12),
            const Text(
              'Supplier Amount Book',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: sectionTextMuted,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Coming soon',
              style: TextStyle(
                color: sectionTextMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
