import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/prefix_search.dart';
import '../services/settled_payment_store.dart';
import '../../models/invoice_summary_model.dart';
import '../../viewModels/payment_history_viewmodel.dart';
import '../widgets/app_responsive.dart';
import '../widgets/system_safe.dart';
import 'invoice_list_widgets.dart';
import 'list_search_field.dart';
import 'live_refresh_mixin.dart';
import '../theme.dart';

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
      if (!mounted) return;
      await _viewModel.fetch(context, forceRefresh: true, silent: true);
      if (!mounted) return;
      await _reloadSettled(live: _viewModel.items);
    });
    startLiveRefresh(() async {
      await _viewModel.fetch(context, forceRefresh: true, silent: true);
      if (!mounted) return;
      await _reloadSettled(live: _viewModel.items);
    });
  }

  @override
  void dispose() {
    stopLiveRefresh();
    _searchController.dispose();
    _tabController.dispose();
    _viewModel.dispose();
    super.dispose();
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
    return items
        .where(
          (item) => PrefixSearch.matchesAny(
            [item.displayCustomer, item.displayNumber, item.invoiceNumber],
            _searchQuery,
          ),
        )
        .toList(growable: false);
  }

  List<InvoiceSummaryModel> _currentTabItems(PaymentHistoryViewModel model) {
    if (_tabController.index == 0) {
      return _filter(_activeItems(model.items));
    }
    return _filter(_settledItems);
  }

  double _sumTotals(List<InvoiceSummaryModel> items) {
    return items.fold<double>(0, (sum, item) => sum + (item.total ?? 0));
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
              fontSize: 15,
            ),
          ),
          backgroundColor: sectionBg,
          elevation: 0,
          actions: [
            IconButton(
              onPressed: () async {
                await _viewModel.fetch(context, forceRefresh: true);
                if (!mounted) return;
                await _reloadSettled(live: _viewModel.items);
              },
              icon: const Icon(Icons.refresh, color: sectionText),
            ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(48),
            child: TabBar(
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
          ),
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

            return Column(
              children: [
                Padding(
                  padding: SystemSafe.horizontalPadding(context, bottom: 8),
                  child: ListSearchField(
                    controller: _searchController,
                    hintText: 'Search customer or invoice no…',
                    onChanged: (value) => setState(() => _searchQuery = value),
                  ),
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
                _buildTotalFooter(tabTotal, tabItems.length),
              ],
            );
          },
        ),
        ),
      ),
    );
  }

  Widget _buildHistoryList(PaymentHistoryViewModel model) {
    final active = _filter(_activeItems(model.items));

    return RefreshIndicator(
      color: const Color(0xFFE07A2F),
      onRefresh: () async {
        await model.fetch(context, forceRefresh: true);
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
                    statusValue: item.displayPaymentHistoryStatus,
                    onTap: () => openInvoiceDetail(context, item),
                  ),
                );
              },
            ),
    );
  }

  Widget _buildSettledList(PaymentHistoryViewModel model) {
    final settled = _filter(_settledItems);

    return RefreshIndicator(
      color: const Color(0xFFE07A2F),
      onRefresh: () async {
        await model.fetch(context, forceRefresh: true);
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
                        statusValue: item.displayPaymentHistoryStatus,
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
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Text(
            InvoiceSummaryModel.formatMoney(total),
            style: const TextStyle(
              color: Color(0xFFE07A2F),
              fontSize: 16,
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
                    color: sectionText,
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
                    color: sectionText,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
      ),
    );
  }
}
