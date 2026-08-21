import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/prefix_search.dart';
import '../../models/net_amount_model.dart';
import '../../models/payment_book_model.dart';
import '../../viewModels/net_amount_viewmodel.dart';
import '../widgets/app_responsive.dart';
import '../widgets/compact_field_rows.dart';
import '../widgets/system_safe.dart';
import 'list_search_field.dart';
import 'live_refresh_mixin.dart';
import 'net_amount_detail_page.dart';
import '../widgets/payment_book_style.dart';
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
              fontSize: 17,
            ),
          ),
          backgroundColor: sectionBg,
          elevation: 0,
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
                          fontSize: 14,
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
                    title: 'You Got (Customer)',
                    amountLabel: NetAmountViewModel.formatAmount(
                      model.amountFor(NetAmountSection.youGot),
                    ),
                    subtitle: 'Paid',
                    color: const Color(0xFFE07A2F),
                    loading: model.detailLoading,
                    onTap: () => _openSection(NetAmountSection.youGot),
                  ),
                  const SizedBox(height: 16),
                  _AmountButton(
                    title: 'You Gave (Supplier)',
                    amountLabel: NetAmountViewModel.formatAmount(
                      model.amountFor(NetAmountSection.youGave),
                    ),
                    subtitle: 'Not paid',
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
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: onColor.withValues(alpha: 0.75),
                        fontSize: 14,
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
                    fontSize: 20,
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

class _NetAmountSectionPageState extends State<NetAmountSectionPage>
    with LiveRefreshMixin {
  late final TextEditingController _searchController;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final model = context.read<NetAmountViewModel>();
      // You Gave has no Open chip — reset if left on Open from You Got.
      if (widget.section == NetAmountSection.youGave &&
          model.statusFilter == 'open') {
        model.setStatusFilter('all');
      }
    });
    startLiveRefresh(() {
      if (!mounted) return Future.value();
      return context.read<NetAmountViewModel>().fetchBoth(
            context,
            forceRefresh: true,
            silent: true,
          );
    });
  }

  @override
  void dispose() {
    stopLiveRefresh();
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
            fontSize: 17,
          ),
        ),
        backgroundColor: sectionBg,
        elevation: 0,
      ),
      body: ResponsiveBody(
        child: Consumer<NetAmountViewModel>(
        builder: (context, model, _) {
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
          final visibleTotal = model.statusFilter == 'all'
              ? rows.fold<double>(0, (sum, row) {
                  if (row.sectionKey == 'cancel') return sum;
                  return sum + (row.total ?? 0);
                })
              : rows.fold<double>(0, (sum, row) => sum + (row.total ?? 0));
          final visibleBalance = model.statusFilter == 'all'
              ? rows.fold<double>(0, (sum, row) {
                  if (row.sectionKey == 'cancel') return sum;
                  return sum + (row.balance ?? 0);
                })
              : rows.fold<double>(0, (sum, row) => sum + (row.balance ?? 0));
          final visiblePaid = model.statusFilter == 'all'
              ? rows.fold<double>(0, (sum, row) {
                  if (row.sectionKey == 'cancel') return sum;
                  return sum + row.paidAmount;
                })
              : rows.fold<double>(0, (sum, row) => sum + row.paidAmount);
          final visibleCount = model.statusFilter == 'all'
              ? rows.where((r) => r.sectionKey != 'cancel').length
              : rows.length;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: const PaymentBookColorLegend(),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: InvoiceStatusFilterChips(
                  selected: model.statusFilter,
                  onSelected: model.setStatusFilter,
                  hideKeys: isGave ? const {'open'} : const {},
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  model.reportDate == null
                      ? 'Yesterday'
                      : 'Date: ${model.reportDate}',
                  style: TextStyle(
                    color: sectionTextMuted,
                    fontSize: 14,
                  ),
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
                          padding: SystemSafe.listPadding(
                            context,
                            top: 0,
                            extraBottom: 12,
                          ),
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
              _NetAmountTotalsFooter(
                count: visibleCount,
                paid: visiblePaid,
                total: visibleTotal,
                balance: visibleBalance,
              ),
            ],
          );
        },
      ),
      ),
    );
  }
}

/// Single-line row: Number · Date · Tax · Total/Paid/Balance.
/// Status badge sits at the top-right. Text colour follows Payment Book.
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
    final invoice = row.toInvoiceSummary(asSupplier: isGave);
    final style = invoice.paymentBookRowStyle;
    final color = PaymentBookStyleColors.of(style);
    final weight = PaymentBookStyleColors.weightOf(style);
    final status = row.displayBillStatus;
    final fields = <Widget>[
      _Cell(
        label: isGave ? 'Supplier' : 'Number',
        value: isGave ? NetAmountRow.text(row.supplier) : row.displayNumber,
        emphasize: true,
        color: color,
        weight: FontWeight.w800,
      ),
      _Cell(
        label: 'Date',
        value: NetAmountRow.formatDate(row.invoiceDate),
        color: color,
        weight: weight,
      ),
      if (!isGave)
        _Cell(
          label: 'Tax',
          value: NetAmountRow.money(row.displayTaxAmount),
          color: color,
          weight: weight,
        ),
      _Cell(
        label: 'Paid',
        value: NetAmountRow.money(row.paidAmount),
        color: const Color(0xFF2E7D32),
        weight: FontWeight.w700,
      ),
      _Cell(
        label: 'Balance',
        value: NetAmountRow.money(row.balance),
        color: const Color(0xFFD32F2F),
        weight: FontWeight.w700,
      ),
      _Cell(
        label: 'Total',
        value: NetAmountRow.money(row.total),
        color: color,
        weight: weight,
      ),
    ];

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        decoration: BoxDecoration(
          color: sectionCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: sectionCardBorder),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: CompactFieldRows(fields: fields),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                InvoiceBillStatusBadge(status: status),
                const SizedBox(height: 8),
                const Icon(
                  Icons.chevron_right,
                  color: sectionTextMuted,
                  size: 20,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _NetAmountTotalsFooter extends StatelessWidget {
  const _NetAmountTotalsFooter({
    required this.count,
    required this.paid,
    required this.total,
    required this.balance,
  });

  final int count;
  final double paid;
  final double total;
  final double balance;

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
              count == 1 ? 'Total (1 bill)' : 'Total ($count bills)',
              style: TextStyle(
                color: sectionTextMuted,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                'Paid  ${NetAmountRow.money(paid)}',
                style: const TextStyle(
                  color: Color(0xFF2E7D32),
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Balance  ${NetAmountRow.money(balance)}',
                style: const TextStyle(
                  color: Color(0xFFD32F2F),
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Total  ${NetAmountRow.money(total)}',
                style: const TextStyle(
                  color: sectionText,
                  fontSize: 17,
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

class _Cell extends StatelessWidget {
  const _Cell({
    required this.label,
    required this.value,
    this.emphasize = false,
    this.color = sectionText,
    this.weight,
  });

  final String label;
  final String value;
  final bool emphasize;
  final Color color;
  final FontWeight? weight;

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
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: color,
            fontWeight: weight ??
                (emphasize ? FontWeight.w700 : FontWeight.w600),
            fontSize: emphasize ? 14 : 13,
          ),
        ),
      ],
    );
  }
}
