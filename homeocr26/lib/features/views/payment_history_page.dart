import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/prefix_search.dart';
import '../services/settled_payment_store.dart';
import '../../models/invoice_summary_model.dart';
import '../../viewModels/payment_history_viewmodel.dart';
import '../widgets/system_safe.dart';
import 'invoice_list_widgets.dart';
import 'list_search_field.dart';
import 'live_refresh_mixin.dart';

class PaymentHistoryPage extends StatefulWidget {
  const PaymentHistoryPage({super.key});

  @override
  State<PaymentHistoryPage> createState() => _PaymentHistoryPageState();
}

class _PaymentHistoryPageState extends State<PaymentHistoryPage>
    with LiveRefreshMixin, SingleTickerProviderStateMixin {
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

  Future<void> _settle(InvoiceSummaryModel item) async {
    await SettledPaymentStore.settle(item);
    await _reloadSettled(live: _viewModel.items);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${item.displayNumber} moved to Settled'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => _restore(item),
        ),
      ),
    );
  }

  Future<void> _restore(InvoiceSummaryModel item) async {
    await SettledPaymentStore.restore(item);
    await _reloadSettled(live: _viewModel.items);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${item.displayNumber} restored to History')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _viewModel,
      child: Scaffold(
        backgroundColor: const Color(0xFF1A1A1A),
        appBar: AppBar(
          iconTheme: const IconThemeData(color: Colors.white),
          title: const Text(
            'Payment History',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w500,
              fontSize: 15,
            ),
          ),
          backgroundColor: const Color(0xFF1A1A1A),
          elevation: 0,
          actions: [
            IconButton(
              onPressed: () async {
                await _viewModel.fetch(context, forceRefresh: true);
                if (!mounted) return;
                await _reloadSettled(live: _viewModel.items);
              },
              icon: const Icon(Icons.refresh, color: Colors.white),
            ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(48),
            child: TabBar(
              controller: _tabController,
              indicatorColor: const Color(0xFFE07A2F),
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white54,
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
        body: Consumer<PaymentHistoryViewModel>(
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
              ],
            );
          },
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
                      style: const TextStyle(color: Colors.white70),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ],
            )
          : ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: SystemSafe.listPadding(context, top: 0),
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
                      style: const TextStyle(color: Colors.white70),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ],
            )
          : ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: SystemSafe.listPadding(context, top: 0),
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
