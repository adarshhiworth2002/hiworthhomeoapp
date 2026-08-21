import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/amount_book_model.dart';
import '../../models/payment_book_model.dart';
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Cache paints instantly; head-only sync keeps it fresh without full reload.
      unawaited(
        _viewModel.fetch(
          context,
          silent: true,
          headOnly: _viewModel.hasData,
        ),
      );
      // Start balance prefetch immediately so customer taps feel instant.
      unawaited(_viewModel.prefetchBalances(context));
    });
    startLiveRefresh(
      () async {
        await _viewModel.fetch(
          context,
          silent: true,
          headOnly: true,
        );
        if (!mounted) return;
        await _viewModel.prefetchBalances(context, refreshStale: true);
      },
      // Head + stale balance refresh so website advance/old edits appear.
      interval: const Duration(seconds: 12),
      immediate: false,
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
      return;
    }

    _viewModel.applyFilter(result.filter);
  }

  void _openCustomerDetail(AmountBookCustomerSummary summary) {
    // Force re-read during transition so website edits are not stuck in cache.
    unawaited(
      _viewModel.ensureBalancesForCustomer(
        context,
        summary.customerName,
        force: true,
      ),
    );
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
            'Cash Book',
            style: TextStyle(
              color: sectionText,
              fontWeight: FontWeight.w500,
              fontSize: 17,
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
              tooltip: 'Filter',
              onPressed: _openFilterSheet,
              icon: const Icon(Icons.filter_list, color: sectionText),
            ),
          ],
        ),
        body: ResponsiveBody(
          child: TabBarView(
          controller: _tabController,
          children: [
            _CustomerTab(
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
  late PaymentBookCustomerType _customerType;
  late PaymentBookPaymentMode _paymentMode;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialFilter.nameQuery);
    _from = widget.initialFilter.dateFrom;
    _to = widget.initialFilter.dateTo;
    _customerType = widget.initialFilter.customerType;
    _paymentMode = widget.initialFilter.paymentMode;
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
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: sectionText,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nameController,
              style: const TextStyle(color: sectionText, fontSize: 16),
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
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Leave dates empty to show all dates.',
                style: TextStyle(
                  color: sectionTextMuted,
                  fontSize: 14,
                ),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<PaymentBookCustomerType>(
              initialValue: _customerType,
              dropdownColor: Colors.white,
              iconEnabledColor: Colors.black,
              style: const TextStyle(color: Colors.black, fontSize: 16),
              decoration: _fieldDecoration(
                label: 'Customer Type',
                icon: Icons.groups_outlined,
              ),
              items: const [
                DropdownMenuItem(
                  value: PaymentBookCustomerType.all,
                  child: Text('All Customers',
                      style: TextStyle(color: Colors.black)),
                ),
                DropdownMenuItem(
                  value: PaymentBookCustomerType.credit,
                  child: Text('Credit Customers',
                      style: TextStyle(color: Colors.black)),
                ),
                DropdownMenuItem(
                  value: PaymentBookCustomerType.normal,
                  child: Text('Normal Customers',
                      style: TextStyle(color: Colors.black)),
                ),
                DropdownMenuItem(
                  value: PaymentBookCustomerType.b2b,
                  child: Text('B2B', style: TextStyle(color: Colors.black)),
                ),
                DropdownMenuItem(
                  value: PaymentBookCustomerType.b2c,
                  child: Text('B2C', style: TextStyle(color: Colors.black)),
                ),
              ],
              onChanged: (value) {
                if (value == null) return;
                setState(() => _customerType = value);
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<PaymentBookPaymentMode>(
              initialValue: _paymentMode,
              dropdownColor: Colors.white,
              iconEnabledColor: Colors.black,
              style: const TextStyle(color: Colors.black, fontSize: 16),
              decoration: _fieldDecoration(
                label: 'Payment Mode',
                icon: Icons.payments_outlined,
              ),
              items: const [
                DropdownMenuItem(
                  value: PaymentBookPaymentMode.all,
                  child: Text('All', style: TextStyle(color: Colors.black)),
                ),
                DropdownMenuItem(
                  value: PaymentBookPaymentMode.cash,
                  child: Text('Cash', style: TextStyle(color: Colors.black)),
                ),
                DropdownMenuItem(
                  value: PaymentBookPaymentMode.credit,
                  child: Text('Credit', style: TextStyle(color: Colors.black)),
                ),
                DropdownMenuItem(
                  value: PaymentBookPaymentMode.cheque,
                  child: Text('Cheque', style: TextStyle(color: Colors.black)),
                ),
                DropdownMenuItem(
                  value: PaymentBookPaymentMode.card,
                  child: Text('Card', style: TextStyle(color: Colors.black)),
                ),
                DropdownMenuItem(
                  value: PaymentBookPaymentMode.upi,
                  child: Text('UPI', style: TextStyle(color: Colors.black)),
                ),
              ],
              onChanged: (value) {
                if (value == null) return;
                setState(() => _paymentMode = value);
              },
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
                            customerType: _customerType,
                            paymentMode: _paymentMode,
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
    required this.onOpenCustomer,
  });

  final void Function(AmountBookCustomerSummary summary) onOpenCustomer;

  @override
  Widget build(BuildContext context) {
    return Consumer<AmountBookViewModel>(
      builder: (context, model, _) {
        final summaries = model.customerSummaries;

        if (model.loading && model.youGotInvoices.isEmpty) {
          return const Center(
            child: CircularProgressIndicator(color: sectionAccent),
          );
        }

        return Column(
          children: [
            Expanded(
              child: RefreshIndicator(
                color: sectionAccent,
                onRefresh: () => model.fetch(context, forceRefresh: true),
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: SystemSafe.listPadding(context, extraBottom: 12),
                  children: [
                    const SizedBox(height: 8),
                    _SummaryCard(
                      youGot: model.allYouGot,
                      youGave: model.allYouGave,
                      loading: model.loading,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      model.filter.isActive
                          ? 'Filtered customers'
                          : 'All customers',
                      style: TextStyle(
                        color: sectionTextMuted,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (model.filter.isActive)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _FilterChipBar(
                          filter: model.filter,
                          onClear: model.clearFilter,
                        ),
                      ),
                    if (model.error.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          model.error,
                          style: const TextStyle(
                            color: sectionTextMuted,
                            fontSize: 15,
                          ),
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
              ),
            ),
            _FilteredTotalsFooter(
              youGot: model.filteredYouGot,
              youGave: model.filteredYouGave,
              balance: model.filteredBalance,
              filtered: model.filter.isActive,
            ),
          ],
        );
      },
    );
  }
}

class _FilterChipBar extends StatelessWidget {
  const _FilterChipBar({
    required this.filter,
    required this.onClear,
  });

  final AmountBookFilter filter;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final parts = <String>[];
    if (filter.hasName) parts.add(filter.nameQuery.trim());
    if (filter.dateFrom != null || filter.dateTo != null) {
      final from = filter.dateFrom == null
          ? '…'
          : AmountBookLedgerBuilder.formatDisplayDate(filter.dateFrom);
      final to = filter.dateTo == null
          ? '…'
          : AmountBookLedgerBuilder.formatDisplayDate(filter.dateTo);
      parts.add(from == to ? from : '$from → $to');
    }
    if (filter.hasCustomerType) parts.add(filter.customerTypeLabel);
    if (filter.hasPaymentMode) parts.add(filter.paymentModeLabel);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      decoration: BoxDecoration(
        color: sectionCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sectionCardBorder),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.filter_alt_outlined,
            size: 14,
            color: sectionAccent,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              parts.isEmpty ? 'Filtered' : parts.join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: sectionText,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Clear filters',
            onPressed: onClear,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 32, height: 32),
            icon: const Icon(Icons.close, size: 18, color: sectionText),
          ),
        ],
      ),
    );
  }
}

class _FilteredTotalsFooter extends StatelessWidget {
  const _FilteredTotalsFooter({
    required this.youGot,
    required this.youGave,
    required this.balance,
    required this.filtered,
  });

  final double youGot;
  final double youGave;
  final double balance;
  final bool filtered;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        AppResponsive.of(context).pagePadding,
        12,
        AppResponsive.of(context).pagePadding,
        SystemSafe.actionBarBottomPadding(context),
      ),
      decoration: BoxDecoration(
        color: sectionFooter,
        border: Border(
          top: BorderSide(color: sectionCardBorder),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              filtered ? 'Filtered totals' : 'All dates',
              style: TextStyle(
                color: sectionTextMuted,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                'YOU GOT  ${AmountBookViewModel.formatAmount(youGot)}',
                style: const TextStyle(
                  color: cashYouGot,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'YOU GAVE  ${AmountBookViewModel.formatAmount(youGave)}',
                style: const TextStyle(
                  color: cashYouGave,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'BALANCE  ${AmountBookViewModel.formatAmount(balance)}',
                style: const TextStyle(
                  color: sectionText,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ],
      ),
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
              color: cashYouGot,
              loading: loading,
            ),
          ),
          Container(
            width: 1,
            height: 48,
            color: sectionCardBorder,
          ),
          Expanded(
            child: _SummaryColumn(
              label: 'YOU GAVE',
              amount: youGave,
              color: cashYouGave,
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
            fontSize: 13,
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
              fontSize: 20,
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
                      fontSize: 16,
                      color: sectionText,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${summary.entryCount} entr${summary.entryCount == 1 ? 'y' : 'ies'}',
                    style: TextStyle(
                      fontSize: 13,
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
                    fontSize: 11,
                    color: sectionTextMuted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: cashYouGaveSoft,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    AmountBookViewModel.formatAmount(summary.lastBalance),
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: cashYouGave,
                    ),
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
    final model = context.watch<AmountBookViewModel>();
    return RefreshIndicator(
      color: sectionAccent,
      onRefresh: () => model.fetch(context, forceRefresh: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.55,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.store_outlined,
                      size: 48,
                      color: sectionTextMuted,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Supplier Cash Book',
                      style: TextStyle(
                        fontSize: 18,
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
            ),
          ),
        ],
      ),
    );
  }
}
