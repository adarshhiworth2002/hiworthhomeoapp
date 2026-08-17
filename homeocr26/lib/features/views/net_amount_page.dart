import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/prefix_search.dart';
import '../../models/net_amount_model.dart';
import '../../viewModels/net_amount_viewmodel.dart';
import '../widgets/app_responsive.dart';
import '../widgets/system_safe.dart';
import 'list_search_field.dart';
import 'live_refresh_mixin.dart';
import 'net_amount_detail_page.dart';
import '../theme.dart';

class NetAmountPage extends StatefulWidget {
  const NetAmountPage({super.key, this.viewModel});

  final NetAmountViewModel? viewModel;

  @override
  State<NetAmountPage> createState() => _NetAmountPageState();
}

class _NetAmountPageState extends State<NetAmountPage> with LiveRefreshMixin {
  late final NetAmountViewModel _viewModel;
  late final bool _ownsViewModel;

  @override
  void initState() {
    super.initState();
    _ownsViewModel = widget.viewModel == null;
    _viewModel = widget.viewModel ?? NetAmountViewModel();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _viewModel.fetchBoth(context, silent: true);
      if (!mounted) return;
      await _viewModel.fetchBoth(context, forceRefresh: true, silent: true);
    });
    startLiveRefresh(
      () => _viewModel.fetchBoth(context, forceRefresh: true, silent: true),
    );
  }

  @override
  void dispose() {
    stopLiveRefresh();
    if (_ownsViewModel) {
      _viewModel.dispose();
    }
    super.dispose();
  }

  void _openSection(NetAmountSection section) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChangeNotifierProvider.value(
          value: _viewModel,
          child: NetAmountSectionPage(section: section),
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
            'Net Amount (Yesterday)',
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
              onPressed: () => _viewModel.fetchBoth(
                context,
                forceRefresh: true,
              ),
              icon: const Icon(Icons.refresh, color: sectionText),
            ),
          ],
        ),
        body: ResponsiveBody(
          child: Consumer<NetAmountViewModel>(
          builder: (context, model, _) {
            if (model.detailLoading &&
                model.youGotAmount == null &&
                model.youGaveAmount == null) {
              return const Center(
                child: CircularProgressIndicator(color: Color(0xFFE07A2F)),
              );
            }

            return RefreshIndicator(
              color: const Color(0xFFE07A2F),
              onRefresh: () =>
                  _viewModel.fetchBoth(context, forceRefresh: true),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(20),
                children: [
                  if (model.reportDate != null &&
                      model.reportDate!.trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        'Report date: ${model.reportDate}',
                        style: TextStyle(
                          color: sectionTextMuted,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  if (model.error.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(
                        model.error,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: sectionTextMuted),
                      ),
                    ),
                  _AmountButton(
                    title: 'You Got (Paid)',
                    amountLabel: NetAmountViewModel.formatAmount(
                      model.youGotAmount,
                    ),
                    subtitle: '${model.youGotInvoices.length} invoice(s)',
                    color: const Color(0xFFE07A2F),
                    loading: model.detailLoading,
                    onTap: () => _openSection(NetAmountSection.youGot),
                  ),
                  const SizedBox(height: 16),
                  _AmountButton(
                    title: 'You Gave (Paid)',
                    amountLabel: NetAmountViewModel.formatAmount(
                      model.youGaveAmount,
                    ),
                    subtitle: '${model.youGaveBills.length} bill(s)',
                    color: Colors.white,
                    loading: model.detailLoading,
                    onTap: () => _openSection(NetAmountSection.youGave),
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

class _AmountButton extends StatelessWidget {
  const _AmountButton({
    required this.title,
    required this.amountLabel,
    required this.subtitle,
    required this.color,
    required this.loading,
    required this.onTap,
  });

  final String title;
  final String amountLabel;
  final String subtitle;
  final Color color;
  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final onColor =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
            ? Colors.white
            : Colors.black;
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: loading ? null : onTap,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: onColor == Colors.black
                  ? const Color(0x40000000)
                  : Colors.transparent,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: onColor,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: onColor.withValues(alpha: 0.75),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (loading)
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: onColor,
                  ),
                )
              else ...[
                Text(
                  amountLabel,
                  style: TextStyle(
                    color: onColor,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.chevron_right, color: onColor),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class NetAmountSectionPage extends StatefulWidget {
  const NetAmountSectionPage({super.key, required this.section});

  final NetAmountSection section;

  @override
  State<NetAmountSectionPage> createState() => _NetAmountSectionPageState();
}

class _NetAmountSectionPageState extends State<NetAmountSectionPage> {
  late final TextEditingController _searchController;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final section = widget.section;
    final isGave = section == NetAmountSection.youGave;

    return Scaffold(
      backgroundColor: sectionBg,
      appBar: AppBar(
        iconTheme: const IconThemeData(color: sectionText),
        title: Text(
          NetAmountViewModel.sectionTitle(section),
          style: const TextStyle(
            color: sectionText,
            fontWeight: FontWeight.w500,
            fontSize: 15,
          ),
        ),
        backgroundColor: sectionBg,
        elevation: 0,
      ),
      body: ResponsiveBody(
        child: Consumer<NetAmountViewModel>(
        builder: (context, model, _) {
          final amount = model.amountFor(section);
          final rows = model.rowsFor(section).where((row) {
            return PrefixSearch.matchesAny(
              [
                row.customer,
                row.supplier,
                row.displayNumber,
              ],
              _searchQuery,
            );
          }).toList(growable: false);

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        model.reportDate == null
                            ? 'Yesterday'
                            : 'Date: ${model.reportDate}',
                        style: TextStyle(
                          color: sectionTextMuted,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    Text(
                      NetAmountViewModel.formatAmount(amount),
                      style: const TextStyle(
                        color: sectionText,
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: SystemSafe.horizontalPadding(context, top: 0, bottom: 8),
                child: ListSearchField(
                  controller: _searchController,
                  hintText: isGave
                      ? 'Search supplier or invoice no…'
                      : 'Search customer or invoice no…',
                  onChanged: (value) => setState(() => _searchQuery = value),
                ),
              ),
              Expanded(
                child: RefreshIndicator(
                  color: const Color(0xFFE07A2F),
                  onRefresh: () => context
                      .read<NetAmountViewModel>()
                      .fetchBoth(context, forceRefresh: true),
                  child: rows.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: [
                            SizedBox(
                              height: MediaQuery.sizeOf(context).height * 0.35,
                              child: Center(
                                child: Text(
                                  _searchQuery.trim().isEmpty
                                      ? 'No records for yesterday'
                                      : 'No matches for "$_searchQuery"',
                                  style: const TextStyle(color: sectionTextMuted),
                                ),
                              ),
                            ),
                          ],
                        )
                      : ListView.separated(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: SystemSafe.listPadding(context, top: 0),
                          itemCount: rows.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final row = rows[index];
                            return _NetAmountListCard(
                              row: row,
                              isGave: isGave,
                              onTap: () => openNetAmountRowDetail(
                                context,
                                row: row,
                                section: section,
                              ),
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
    );
  }
}

/// Single-line row: Number · Date · Tax · Total · Status (You Got).
/// You Gave: Supplier · Date · Total · Status.
class _NetAmountListCard extends StatelessWidget {
  const _NetAmountListCard({
    required this.row,
    required this.isGave,
    required this.onTap,
  });

  final NetAmountRow row;
  final bool isGave;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final status = row.displayPaymentHistoryStatus;

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: sectionCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: sectionCardBorder),
        ),
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: _Cell(
                label: isGave ? 'Supplier' : 'Number',
                value: isGave
                    ? NetAmountRow.text(row.supplier)
                    : row.displayNumber,
                emphasize: true,
              ),
            ),
            Expanded(
              flex: 2,
              child: Padding(
                padding: EdgeInsets.only(right: isGave ? 0 : 6),
                child: _Cell(
                  label: 'Date',
                  value: NetAmountRow.formatDate(row.invoiceDate),
                ),
              ),
            ),
            if (!isGave) ...[
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: _Cell(
                    label: 'Tax',
                    value: NetAmountRow.money(row.displayTaxAmount),
                  ),
                ),
              ),
            ],
            Expanded(
              flex: 2,
              child: _Cell(
                label: 'Total',
                value: NetAmountRow.money(row.total),
              ),
            ),
            Expanded(
              flex: 2,
              child: _Cell(
                label: 'Status',
                value: status,
              ),
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

class _Cell extends StatelessWidget {
  const _Cell({
    required this.label,
    required this.value,
    this.emphasize = false,
  });

  final String label;
  final String value;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: sectionTextMuted,
            fontSize: 9,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: sectionText,
            fontWeight: emphasize ? FontWeight.w700 : FontWeight.w600,
            fontSize: emphasize ? 12 : 11,
          ),
        ),
      ],
    );
  }
}
