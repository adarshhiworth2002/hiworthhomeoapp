import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/amount_book_model.dart';
import '../../models/invoice_summary_model.dart';
import '../../viewModels/amount_book_viewmodel.dart';
import '../theme.dart';
import '../widgets/app_responsive.dart';
import '../widgets/compact_field_rows.dart';
import '../widgets/system_safe.dart';
import 'customer_invoice_detail_page.dart';
import 'live_refresh_mixin.dart';

class AmountBookInvoiceTablePage extends StatefulWidget {
  const AmountBookInvoiceTablePage({
    super.key,
    required this.customerName,
    required this.invoices,
    this.date,
    this.isYouGave = true,
  });

  final String customerName;
  final List<AmountBookInvoiceLine> invoices;
  final DateTime? date;
  final bool isYouGave;

  @override
  State<AmountBookInvoiceTablePage> createState() =>
      _AmountBookInvoiceTablePageState();
}

class _AmountBookInvoiceTablePageState extends State<AmountBookInvoiceTablePage>
    with LiveRefreshMixin {
  @override
  void initState() {
    super.initState();
    startLiveRefresh(
      () {
        if (!mounted) return Future.value();
        return context.read<AmountBookViewModel>().fetch(
              context,
              silent: true,
              headOnly: true,
            );
      },
      interval: const Duration(seconds: 6),
    );
  }

  @override
  void dispose() {
    stopLiveRefresh();
    super.dispose();
  }

  Future<void> _refresh({bool silent = false}) {
    return context.read<AmountBookViewModel>().fetch(
          context,
          forceRefresh: true,
          silent: silent,
        );
  }

  List<AmountBookInvoiceLine> _resolveRows(AmountBookViewModel model) {
    final live = model.invoicesForLedgerTap(
      customerName: widget.customerName,
      isYouGave: widget.isYouGave,
      date: widget.date,
      numbers: widget.invoices.map((e) => e.number).toList(),
    );
    if (live.isNotEmpty) return live;
    return widget.invoices;
  }

  void _openCustomerInvoice(
    BuildContext context,
    AmountBookInvoiceLine line,
  ) {
    final model = context.read<AmountBookViewModel>();
    final invoice = model.invoiceSummaryForLine(line).mergedWith(
          InvoiceSummaryModel(customer: widget.customerName),
        );
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CustomerInvoiceDetailPage(
          invoice: invoice,
          title: 'Customer Invoice',
          partnerLabel: 'Customer',
          allowScan: true,
          supplierLayout: false,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final model = context.watch<AmountBookViewModel>();
    final titleDate = AmountBookLedgerBuilder.formatDisplayDate(widget.date);
    final rows = _resolveRows(model);
    final gave = rows.any((e) => e.isYouGave) || widget.isYouGave;

    double totalSum = 0;
    double balanceSum = 0;
    double youGaveSum = 0;
    double youGotSum = 0;
    for (final row in rows) {
      totalSum += row.total ?? 0;
      balanceSum += row.balance ?? 0;
      youGaveSum += row.youGaveAmount ?? 0;
      youGotSum += row.youGotAmount ?? 0;
    }

    return Scaffold(
      backgroundColor: sectionBg,
      appBar: AppBar(
        iconTheme: const IconThemeData(color: sectionText),
        title: Text(
          widget.customerName,
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
        child: Column(
          children: [
            if (widget.date != null)
              Padding(
                padding: SystemSafe.horizontalPadding(
                  context,
                  top: 8,
                  bottom: 4,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    titleDate,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: sectionTextMuted,
                    ),
                  ),
                ),
              ),
            Expanded(
              child: RefreshIndicator(
                color: sectionAccent,
                onRefresh: () => _refresh(),
                child: rows.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          SizedBox(
                            height: MediaQuery.sizeOf(context).height * 0.35,
                            child: const Center(
                              child: Text(
                                'No invoices for this date',
                                style: TextStyle(color: sectionTextMuted),
                              ),
                            ),
                          ),
                        ],
                      )
                    : ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: SystemSafe.listPadding(
                          context,
                          top: widget.date == null ? 12 : 8,
                          extraBottom: 12,
                        ),
                        itemCount: rows.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) => _InvoiceCard(
                          invoice: rows[index],
                          onOpenBill: () =>
                              _openCustomerInvoice(context, rows[index]),
                        ),
                      ),
              ),
            ),
            _InvoiceTotals(
              count: rows.length,
              isYouGave: gave,
              total: totalSum,
              balance: balanceSum,
              youGave: youGaveSum,
              youGot: youGotSum,
            ),
          ],
        ),
      ),
    );
  }
}

class _InvoiceCard extends StatelessWidget {
  const _InvoiceCard({
    required this.invoice,
    required this.onOpenBill,
  });

  final AmountBookInvoiceLine invoice;
  final VoidCallback onOpenBill;

  @override
  Widget build(BuildContext context) {
    final fields = <Widget>[
      _LineCell(
        label: 'Number',
        value: invoice.number,
        emphasize: true,
      ),
      _LineCell(
        label: 'Invoice Date',
        value: AmountBookLedgerBuilder.formatDisplayDate(invoice.sortDate),
      ),
      _LineCell(
        label: 'Payment Mode',
        value: AmountBookLedgerBuilder.formatPaymentMode(invoice.paymentMode),
      ),
      _LineCell(
        label: 'Total',
        value: AmountBookViewModel.formatAmount(invoice.total),
      ),
      if (invoice.isYouGave)
        _LineCell(
          label: 'You Gave',
          value: AmountBookViewModel.formatAmount(invoice.youGaveAmount),
          emphasize: true,
          color: cashYouGave,
        )
      else
        _LineCell(
          label: 'You Got',
          value: AmountBookViewModel.formatAmount(invoice.youGotAmount),
          emphasize: true,
          color: cashYouGot,
        ),
      _LineCell(
        label: 'Balance',
        value: AmountBookViewModel.formatAmount(invoice.balance),
      ),
    ];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: sectionCardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  invoice.number,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: sectionText,
                    fontWeight: FontWeight.w700,
                    fontSize: 17,
                  ),
                ),
              ),
              _StatusPill(invoice.isYouGave ? 'YOU GAVE' : 'YOU GOT'),
            ],
          ),
          const SizedBox(height: 10),
          CompactFieldRows(
            fields: fields,
            trailing: IconButton(
              tooltip: 'Open customer invoice',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(
                minWidth: 36,
                minHeight: 36,
              ),
              onPressed: onOpenBill,
              icon: Icon(
                Icons.receipt_long_outlined,
                size: 22,
                color: sectionAccent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LineCell extends StatelessWidget {
  const _LineCell({
    required this.label,
    required this.value,
    this.emphasize = false,
    this.color,
  });

  final String label;
  final String value;
  final bool emphasize;
  final Color? color;

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
            color: color ?? sectionTextMuted,
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
            color: color ?? (emphasize ? sectionAccent : sectionText),
            fontWeight: emphasize ? FontWeight.w700 : FontWeight.w600,
            fontSize: emphasize ? 14 : 13,
          ),
        ),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final isGot = label.contains('GOT');
    final color = isGot ? cashYouGot : cashYouGave;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _InvoiceTotals extends StatelessWidget {
  const _InvoiceTotals({
    required this.count,
    required this.isYouGave,
    required this.total,
    required this.balance,
    required this.youGave,
    required this.youGot,
  });

  final int count;
  final bool isYouGave;
  final double total;
  final double balance;
  final double youGave;
  final double youGot;

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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            count == 1 ? '1 bill' : '$count bills',
            style: TextStyle(
              color: sectionTextMuted,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _FooterChip(
                  label: 'TOTAL',
                  value: AmountBookViewModel.formatAmount(total),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _FooterChip(
                  label: isYouGave ? 'YOU GAVE' : 'YOU GOT',
                  value: AmountBookViewModel.formatAmount(
                    isYouGave ? youGave : youGot,
                  ),
                  color: isYouGave ? cashYouGave : cashYouGot,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _FooterChip(
                  label: 'BALANCE',
                  value: AmountBookViewModel.formatAmount(balance),
                  accent: true,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FooterChip extends StatelessWidget {
  const _FooterChip({
    required this.label,
    required this.value,
    this.color,
    this.accent = false,
  });

  final String label;
  final String value;
  final Color? color;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final valueColor = color ?? (accent ? sectionAccent : sectionText);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: sectionCard,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: sectionCardBorder),
      ),
      child: Column(
        children: [
          Text(
            label,
            style: TextStyle(
              color: color ?? sectionTextMuted,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: valueColor,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}
