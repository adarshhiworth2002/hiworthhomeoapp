import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/cheque_clearance_model.dart';
import '../../viewModels/cheque_clearance_viewmodel.dart';
import '../services/prefix_search.dart';
import '../widgets/app_responsive.dart';
import '../widgets/system_safe.dart';
// Detail navigation temporarily disabled — list-only for now.
// import 'cheque_clearance_detail_page.dart';
import 'invoice_list_widgets.dart';
import 'list_search_field.dart';
import 'live_refresh_mixin.dart';
import '../theme.dart';

class ChequeClearancePage extends StatefulWidget {
  const ChequeClearancePage({super.key});

  @override
  State<ChequeClearancePage> createState() => _ChequeClearancePageState();
}

class _ChequeClearancePageState extends State<ChequeClearancePage>
    with LiveRefreshMixin {
  late final ChequeClearanceViewModel _viewModel;
  late final TextEditingController _searchController;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _viewModel = ChequeClearanceViewModel();
    _searchController = TextEditingController();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _viewModel.fetch(context);
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
    _searchController.dispose();
    _viewModel.dispose();
    super.dispose();
  }

  List<ChequeClearanceModel> _filter(List<ChequeClearanceModel> items) {
    return items
        .where(
          (item) => PrefixSearch.matchesAny(
            [
              item.serialNumber,
              item.chequeNumber,
              item.partnerName,
              item.bank,
              item.customerPayment,
            ],
            _searchQuery,
          ),
        )
        .toList(growable: false);
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
            'Today Cheque Clearance',
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
              onPressed: () => _viewModel.fetch(context, forceRefresh: true),
              icon: const Icon(Icons.refresh, color: sectionText),
            ),
          ],
        ),
        body: ResponsiveBody(
          child: Consumer<ChequeClearanceViewModel>(
          builder: (context, model, _) {
            if (model.loading && model.items.isEmpty) {
              return const Center(
                child: CircularProgressIndicator(color: Color(0xFFE07A2F)),
              );
            }
            if (model.error.isNotEmpty && model.items.isEmpty) {
              return InvoiceListError(
                message: model.error,
                onRetry: () => model.fetch(context, forceRefresh: true),
              );
            }
            if (model.items.isEmpty) {
              return RefreshIndicator(
                color: const Color(0xFFE07A2F),
                onRefresh: () => model.fetch(context, forceRefresh: true),
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    SizedBox(
                      height: MediaQuery.sizeOf(context).height * 0.4,
                      child: const Center(
                        child: Text(
                          'No cheque clearance found for today',
                          style: TextStyle(color: sectionTextMuted),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }

            final filtered = _filter(model.items);
            return Column(
              children: [
                Padding(
                  padding: SystemSafe.horizontalPadding(context, bottom: 8),
                  child: ListSearchField(
                    controller: _searchController,
                    hintText: 'Search cheque, bank or customer…',
                    onChanged: (value) => setState(() => _searchQuery = value),
                  ),
                ),
                Expanded(
                  child: RefreshIndicator(
                    color: const Color(0xFFE07A2F),
                    onRefresh: () => model.fetch(context, forceRefresh: true),
                    child: filtered.isEmpty
                        ? ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            children: [
                              SizedBox(
                                height:
                                    MediaQuery.sizeOf(context).height * 0.35,
                                child: Center(
                                  child: Text(
                                    'No matches for "$_searchQuery"',
                                    style: const TextStyle(
                                      color: sectionTextMuted,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          )
                        : ListView.separated(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: SystemSafe.listPadding(context, top: 0),
                            itemCount: filtered.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final item = filtered[index];
                              return _ChequeClearanceCard(
                                item: item,
                                // Stay on this list page — detail navigation paused.
                                onTap: null,
                                // onTap: () {
                                //   Navigator.of(context).push(
                                //     MaterialPageRoute(
                                //       builder: (_) =>
                                //           ChequeClearanceDetailPage(
                                //         cheque: item,
                                //       ),
                                //     ),
                                //   );
                                // },
                              );
                            },
                          ),
                  ),
                ),
              ],
            );
          },
        ),
        ),
      ),
    );
  }
}

class _ChequeClearanceCard extends StatelessWidget {
  const _ChequeClearanceCard({required this.item, this.onTap});

  final ChequeClearanceModel item;
  final VoidCallback? onTap;

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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    item.displaySerial,
                    style: const TextStyle(
                      color: sectionText,
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                ),
                // Status pill (Paid, etc.) hidden on main cheque list.
                // Chevron / open-detail affordance paused (list-only).
                // const SizedBox(width: 4),
                // Icon(
                //   Icons.chevron_right,
                //   color: sectionTextMuted,
                //   size: 20,
                // ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _Cell(
                    'Cheque No',
                    item.displayChequeNo,
                  ),
                ),
                Expanded(
                  child: _Cell(
                    'Cheque Date',
                    ChequeClearanceModel.formatDate(item.chequeDate),
                  ),
                ),
                Expanded(
                  child: _Cell(
                    'Clearance',
                    ChequeClearanceModel.formatDate(item.clearanceDate),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _Cell(
                    'Total',
                    ChequeClearanceModel.formatMoney(item.totalAmount),
                    emphasize: true,
                  ),
                ),
                Expanded(
                  child: _Cell(
                    'Balance',
                    ChequeClearanceModel.formatMoney(item.balance),
                  ),
                ),
                Expanded(
                  child: _Cell('Bank', item.displayBank),
                ),
              ],
            ),
            if (item.branch != null && item.branch!.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'Branch: ${item.displayBranch}',
                style: TextStyle(
                  color: sectionTextMuted,
                  fontSize: 11,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell(this.label, this.value, {this.emphasize = false});

  final String label;
  final String value;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: sectionTextMuted,
            fontSize: 9,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: emphasize ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
