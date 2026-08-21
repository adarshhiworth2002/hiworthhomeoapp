import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/prefix_search.dart';
import '../services/settled_payment_store.dart';
import '../../models/invoice_summary_model.dart';
import '../../models/payment_book_model.dart';
import '../../viewModels/payment_history_viewmodel.dart';
import '../widgets/app_responsive.dart';
import '../widgets/system_safe.dart';
import 'invoice_list_widgets.dart';
import 'invoice_search_filter_sheet.dart';
import 'list_search_field.dart';
import 'live_refresh_mixin.dart';
import '../theme.dart';
import '../widgets/payment_book_style.dart';

class PaymentHistoryPage extends StatefulWidget {
  const PaymentHistoryPage({super.key});

  @override
  State<PaymentHistoryPage> createState() => _PaymentHistoryPageState();
}

class _PaymentHistoryPageState extends State<PaymentHistoryPage>
    with LiveRefreshMixin, SingleTickerProviderStateMixin {
  static const _snackDuration = Duration(milliseconds: 900);

  late final PaymentHistoryViewModel _viewModel;
  late final TextEditingController _searchController;
  late final TabController _tabController;
  String _searchQuery = '';
  String _statusFilter = 'all';
  Set<String> _settledKeys = {};
  List<InvoiceSummaryModel> _settledItems = const [];
  bool _settledReady = false;

  @override
  void initState() {
    super.initState();
    _viewModel = PaymentHistoryViewModel();
    _searchController = TextEditingController();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _reloadSettled();
      if (!mounted) return;
      await _viewModel.fetch(context);
      if (!mounted) return;
      await _reloadSettled(live: _viewModel.items);
    });
    startLiveRefresh(
      () async {
        await _viewModel.fetch(context, forceRefresh: true, silent: true);
        if (!mounted) return;
        await _reloadSettled(live: _viewModel.items);
      },
      interval: const Duration(seconds: 30),
      immediate: false,
    );
  }

  @override
  void dispose() {
    stopLiveRefresh();
    _searchController.dispose();
    _tabController.dispose();
    _viewModel.dispose();
    super.dispose();
  }

  Future<void> _openFilter() async {
    final result = await showModalBottomSheet<InvoiceSearchFilterResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: sectionBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => InvoiceSearchFilterSheet(
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

  Future<void> _reloadSettled({List<InvoiceSummaryModel>? live}) async {
    final keys = await SettledPaymentStore.settledKeys();
    final settled = await SettledPaymentStore.settledInvoices(
      live ?? _viewModel.items,
    );
    if (!mounted) return;
    setState(() {
      _settledKeys = keys;
      _settledItems = settled;
      _settledReady = true;
    });
  }

  List<InvoiceSummaryModel> _activeItems(List<InvoiceSummaryModel> all) {
    if (_settledKeys.isEmpty) return all;
    return all
        .where((e) => !_settledKeys.contains(SettledPaymentStore.keyFor(e)))
        .toList(growable: false);
  }

  List<InvoiceSummaryModel> _filter(List<InvoiceSummaryModel> items) {
    return _viewModel.visibleOf(items)
        .where(
          (item) => PrefixSearch.matchesCustomerOrInvoice(
            query: _searchQuery,
            customer: item.customer,
            displayCustomer: item.displayCustomer,
            displayNumber: item.displayNumber,
            invoiceNumber: item.invoiceNumber,
          ),
        )
        .toList(growable: false);
  }

  List<InvoiceSummaryModel> _currentTabItems(PaymentHistoryViewModel model) {
    final base = _tabController.index == 0
        ? _filter(_activeItems(model.items))
        : _filter(_settledItems);
    if (_statusFilter == 'all') return base;
    return base
        .where((inv) => inv.sectionKey == _statusFilter)
        .toList(growable: false);
  }

  double _sumTotals(List<InvoiceSummaryModel> items) {
    if (_statusFilter == 'all') {
      return InvoiceSummaryModel.sumTotals(items, includeCancel: false);
    }
    return InvoiceSummaryModel.sumTotals(items, includeCancel: true);
  }

  int _countBills(List<InvoiceSummaryModel> items) {
    if (_statusFilter == 'all') {
      return InvoiceSummaryModel.countBills(items, includeCancel: false);
    }
    return items.length;
  }

  void _briefSnack(String message, {VoidCallback? onUndo}) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: _snackDuration,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        action: onUndo == null
            ? null
            : SnackBarAction(
                label: 'Undo',
                onPressed: onUndo,
              ),
      ),
    );
  }

  Future<void> _settle(InvoiceSummaryModel item) async {
    await SettledPaymentStore.settle(item);
    await _reloadSettled(live: _viewModel.items);
    if (!mounted) return;
    _briefSnack(
      '${item.displayNumber} moved to Settled',
      onUndo: () => _restore(item),
    );
  }

  Future<void> _restore(InvoiceSummaryModel item) async {
    await SettledPaymentStore.restore(item);
    await _reloadSettled(live: _viewModel.items);
    if (!mounted) return;
    _briefSnack('${item.displayNumber} restored to History');
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
            'Payment History',
            style: TextStyle(
              color: sectionText,
              fontWeight: FontWeight.w500,
              fontSize: 17,
            ),
          ),
          backgroundColor: sectionBg,
          elevation: 0,
          actions: [
            IconButton(
              tooltip: 'Filter',
              onPressed: _openFilter,
              icon: const Icon(Icons.filter_list, color: sectionText),
            ),
          ],
        ),
        body: ResponsiveBody(
          child: Consumer<PaymentHistoryViewModel>(
          builder: (context, model, _) {
            if (model.loading && model.items.isEmpty && !_settledReady) {
              return const Center(
                child: CircularProgressIndicator(color: Color(0xFFE07A2F)),
              );
            }
            if (model.error.isNotEmpty &&
                model.items.isEmpty &&
                _settledItems.isEmpty) {
              return InvoiceListError(
                message: model.error,
                onRetry: () => model.fetch(context, forceRefresh: true),
              );
            }

            final tabItems = _currentTabItems(model);
            final tabTotal = _sumTotals(tabItems);
            final tabCount = _countBills(tabItems);

            return Column(
              children: [
                TabBar(
                  controller: _tabController,
                  indicatorColor: const Color(0xFFE07A2F),
                  labelColor: sectionAccent,
                  unselectedLabelColor: sectionTextMuted,
                  tabs: [
                    const Tab(
                      icon: Icon(Icons.history, size: 18),
                      text: 'History',
                    ),
                    Tab(
                      icon: const Icon(Icons.verified_outlined, size: 18),
                      text: _settledReady && _settledItems.isNotEmpty
                          ? 'Settled (${_settledItems.length})'
                          : 'Settled',
                    ),
                  ],
                ),
                Padding(
                  padding: SystemSafe.horizontalPadding(context, top: 8, bottom: 8),
                  child: ListSearchField(
                    controller: _searchController,
                    hintText: 'Search customer or invoice no…',
                    onChanged: (value) => setState(() => _searchQuery = value),
                  ),
                ),
                if (model.filter.isActive)
                  Padding(
                    padding: SystemSafe.horizontalPadding(context, bottom: 8),
                    child: _HistoryFilterChips(
                      filter: model.filter,
                      onClear: model.clearFilter,
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: InvoiceStatusFilterChips(
                    selected: _statusFilter,
                    onSelected: (v) => setState(() => _statusFilter = v),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: PaymentBookColorLegend(),
                ),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _buildHistoryList(model),
                      _buildSettledList(model),
                    ],
                  ),
                ),
                _buildTotalFooter(tabTotal, tabCount),
              ],
            );
          },
        ),
        ),
      ),
    );
  }

  Widget _buildHistoryList(PaymentHistoryViewModel model) {
    var active = _filter(_activeItems(model.items));
    if (_statusFilter != 'all') {
      active = active
          .where((inv) => inv.sectionKey == _statusFilter)
          .toList(growable: false);
    }

    return RefreshIndicator(
      color: const Color(0xFFE07A2F),
      displacement: 28,
      onRefresh: () async {
        await model.fetch(context, forceRefresh: true, silent: true);
        if (!mounted) return;
        await _reloadSettled(live: model.items);
      },
      child: active.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                SizedBox(
                  height: MediaQuery.sizeOf(context).height * 0.35,
                  child: Center(
                    child: Text(
                      model.items.isEmpty
                          ? 'No payment history found'
                          : (_searchQuery.trim().isEmpty
                              ? 'All bills are in Settled'
                              : 'No matches for "$_searchQuery"'),
                      style: const TextStyle(color: sectionTextMuted),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ],
            )
          : ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: SystemSafe.listPadding(context, top: 0, extraBottom: 72),
              itemCount: active.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final item = active[index];
                return Dismissible(
                  key: ValueKey('hist-${SettledPaymentStore.keyFor(item)}'),
                  direction: DismissDirection.endToStart,
                  confirmDismiss: (_) async {
                    await _settle(item);
                    return false; // we rebuild lists ourselves
                  },
                  background: _swipeBg(
                    alignEnd: true,
                    color: const Color(0xFF2E7D32),
                    icon: Icons.verified_outlined,
                    label: 'Settle',
                  ),
                  child: InvoiceListCard(
                    invoice: item,
                    onTap: () => openInvoiceDetail(context, item),
                  ),
                );
              },
            ),
    );
  }

  Widget _buildSettledList(PaymentHistoryViewModel model) {
    var settled = _filter(_settledItems);
    if (_statusFilter != 'all') {
      settled = settled
          .where((inv) => inv.sectionKey == _statusFilter)
          .toList(growable: false);
    }

    return RefreshIndicator(
      color: const Color(0xFFE07A2F),
      displacement: 28,
      onRefresh: () async {
        await model.fetch(context, forceRefresh: true, silent: true);
        if (!mounted) return;
        await _reloadSettled(live: model.items);
      },
      child: settled.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                SizedBox(
                  height: MediaQuery.sizeOf(context).height * 0.35,
                  child: Center(
                    child: Text(
                      _searchQuery.trim().isEmpty
                          ? 'Swipe a bill left in History to settle it'
                          : 'No settled matches for "$_searchQuery"',
                      style: const TextStyle(color: sectionTextMuted),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ],
            )
          : ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: SystemSafe.listPadding(context, top: 0, extraBottom: 72),
              itemCount: settled.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final item = settled[index];
                return Dismissible(
                  key: ValueKey('set-${SettledPaymentStore.keyFor(item)}'),
                  direction: DismissDirection.startToEnd,
                  confirmDismiss: (_) async {
                    await _restore(item);
                    return false;
                  },
                  background: _swipeBg(
                    alignEnd: false,
                    color: const Color(0xFFE07A2F),
                    icon: Icons.undo,
                    label: 'Restore',
                  ),
                  child: Stack(
                    children: [
                      InvoiceListCard(
                        invoice: item,
                        onTap: () => openInvoiceDetail(context, item),
                      ),
                      Positioned(
                        top: 6,
                        right: 8,
                        child: Icon(
                          Icons.verified,
                          size: 16,
                          color: const Color(0xFF81C784).withValues(alpha: 0.9),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }

  Widget _buildTotalFooter(double total, int count) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        16,
        12,
        16,
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
              count == 1 ? 'Total (1 bill)' : 'Total ($count bills)',
              style: TextStyle(
                color: sectionTextMuted,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Text(
            InvoiceSummaryModel.formatMoney(total),
            style: const TextStyle(
              color: Color(0xFFE07A2F),
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _swipeBg({
    required bool alignEnd,
    required Color color,
    required IconData icon,
    required String label,
  }) {
    return Container(
      alignment: alignEnd ? Alignment.centerRight : Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: alignEnd
            ? [
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 8),
                Icon(icon, color: Colors.white),
              ]
            : [
                Icon(icon, color: Colors.white),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
      ),
    );
  }
}

class _HistoryFilterChips extends StatelessWidget {
  const _HistoryFilterChips({
    required this.filter,
    required this.onClear,
  });

  final PaymentBookFilter filter;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final parts = filter.chipParts;
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
            color: Color(0xFFE07A2F),
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
