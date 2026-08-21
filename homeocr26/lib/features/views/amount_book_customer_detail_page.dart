import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/amount_book_model.dart';
import '../../viewModels/amount_book_viewmodel.dart';
import '../services/amount_book_pdf_service.dart';
import '../theme.dart';
import '../widgets/app_responsive.dart';
import '../widgets/system_safe.dart';
import 'amount_book_invoice_table_page.dart';
import 'live_refresh_mixin.dart';

class AmountBookCustomerDetailPage extends StatefulWidget {
  const AmountBookCustomerDetailPage({
    super.key,
    required this.summary,
  });

  final AmountBookCustomerSummary summary;

  @override
  State<AmountBookCustomerDetailPage> createState() =>
      _AmountBookCustomerDetailPageState();
}

class _AmountBookCustomerDetailPageState
    extends State<AmountBookCustomerDetailPage> with LiveRefreshMixin {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        context.read<AmountBookViewModel>().ensureBalancesForCustomer(
              context,
              widget.summary.customerName,
              force: true,
            ),
      );
    });
    startLiveRefresh(
      () async {
        if (!mounted) return;
        final model = context.read<AmountBookViewModel>();
        await model.fetch(
          context,
          silent: true,
          headOnly: true,
        );
        if (!mounted) return;
        // Re-read advance/old from Odoo so website edits show live.
        await model.ensureBalancesForCustomer(
          context,
          widget.summary.customerName,
          force: true,
        );
      },
      interval: const Duration(seconds: 12),
      immediate: false,
    );
  }

  @override
  void dispose() {
    stopLiveRefresh();
    super.dispose();
  }

  Future<void> _refresh({bool silent = false}) async {
    final model = context.read<AmountBookViewModel>();
    await model.fetch(
      context,
      forceRefresh: true,
      silent: silent,
    );
    if (!mounted) return;
    await model.ensureBalancesForCustomer(
      context,
      widget.summary.customerName,
      force: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final summary = widget.summary;
    final model = context.watch<AmountBookViewModel>();
    final entries = model.ledgerForCustomer(summary.customerName);

    return Scaffold(
      backgroundColor: sectionBg,
      appBar: AppBar(
        iconTheme: const IconThemeData(color: sectionText),
        title: Text(
          summary.customerName,
          style: const TextStyle(
            fontWeight: FontWeight.w500,
            fontSize: 17,
            color: sectionText,
          ),
        ),
        backgroundColor: sectionAppBar,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: 'Download PDF',
            onPressed: entries.isEmpty
                ? null
                : () => AmountBookPdfService.shareCustomerLedger(
                      customerName: summary.customerName,
                      entries: entries,
                      dateFrom: model.filter.dateFrom,
                      dateTo: model.filter.dateTo,
                    ),
            icon: const Icon(Icons.picture_as_pdf_outlined, color: sectionText),
          ),
        ],
      ),
      body: ResponsiveBody(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: _YouWillGetBox(
                amount: entries.isEmpty
                    ? summary.lastBalance
                    : entries.first.balance,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  const Expanded(child: SizedBox.shrink()),
                  SizedBox(
                    width: 100,
                    child: Text(
                      'YOU GOT',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: cashYouGot,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 100,
                    child: Text(
                      'YOU GAVE',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: cashYouGave,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                color: sectionAccent,
                onRefresh: () => _refresh(),
                child: entries.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          SizedBox(
                            height: MediaQuery.sizeOf(context).height * 0.35,
                            child: const Center(
                              child: Text(
                                'No entries for this customer',
                                style: TextStyle(color: sectionTextMuted),
                              ),
                            ),
                          ),
                        ],
                      )
                    : ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: SystemSafe.listPadding(context, top: 0),
                        children: _buildGroupedList(context, entries),
                      ),
              ),
            ),
            _CustomerFooter(
              footer: model.footerForCustomer(summary.customerName),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildGroupedList(
    BuildContext context,
    List<AmountBookLedgerEntry> entries,
  ) {
    final widgets = <Widget>[];
    String? lastDayKey;

    for (final entry in entries) {
      final dayKey = AmountBookLedgerBuilder.dayKey(entry.sortDate);
      if (dayKey != lastDayKey) {
        lastDayKey = dayKey;
        widgets.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
            child: Text(
              _formatDayHeader(entry.sortDate),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: sectionTextMuted,
              ),
            ),
          ),
        );
      }
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _LedgerEntryCard(
            entry: entry,
            onTap: () => _openInvoiceTable(context, entry),
          ),
        ),
      );
    }
    return widgets;
  }

  void _openInvoiceTable(BuildContext context, AmountBookLedgerEntry entry) {
    final model = context.read<AmountBookViewModel>();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChangeNotifierProvider.value(
          value: model,
          child: AmountBookInvoiceTablePage(
            customerName: widget.summary.customerName,
            date: entry.sortDate,
            isYouGave: entry.isYouGave,
            invoices: entry.invoices,
          ),
        ),
      ),
    );
  }

  static String _formatDayHeader(DateTime? date) {
    if (date == null) return '—';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(date.year, date.month, date.day);
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final d = date.day.toString().padLeft(2, '0');
    final m = months[date.month - 1];
    final y = (date.year % 100).toString().padLeft(2, '0');
    final label = '$d $m $y';
    if (day == today) return '$label • Today';
    return label;
  }
}

class _LedgerEntryCard extends StatelessWidget {
  const _LedgerEntryCard({
    required this.entry,
    required this.onTap,
  });

  final AmountBookLedgerEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final gaveAmount = entry.youGaveAmount;
    final gotAmount = entry.youGotAmount;
    final timeLabel = _formatTime(entry.sortDate);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: sectionCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: sectionCardBorder),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (timeLabel.isNotEmpty)
                      Text(
                        timeLabel,
                        style: TextStyle(
                          fontSize: 13,
                          color: sectionTextMuted,
                        ),
                      ),
                    if (timeLabel.isNotEmpty) const SizedBox(height: 2),
                    Text(
                      entry.displayDate,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: sectionText,
                      ),
                    ),
                    if (entry.displayPaymentMode != '—') ...[
                      const SizedBox(height: 2),
                      Text(
                        entry.displayPaymentMode,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: sectionTextMuted,
                        ),
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      'Bal. ${AmountBookViewModel.formatAmount(entry.balance)}',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: cashYouGave,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 100,
                child: gotAmount != null && !entry.isYouGave
                    ? Align(
                        alignment: Alignment.centerRight,
                        child: _AmountPill(
                          amount: gotAmount,
                          color: cashYouGot,
                          background: cashYouGotSoft,
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              SizedBox(
                width: 100,
                child: gaveAmount != null && entry.isYouGave
                    ? Align(
                        alignment: Alignment.centerRight,
                        child: _AmountPill(
                          amount: gaveAmount,
                          color: cashYouGave,
                          background: cashYouGaveSoft,
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _formatTime(DateTime? date) {
    if (date == null) return '';
    if (date.hour == 0 && date.minute == 0) return '';
    final h = date.hour;
    final m = date.minute.toString().padLeft(2, '0');
    final period = h >= 12 ? 'PM' : 'AM';
    final hour12 = h % 12 == 0 ? 12 : h % 12;
    return '$hour12:$m $period';
  }
}

class _AmountPill extends StatelessWidget {
  const _AmountPill({
    required this.amount,
    required this.color,
    required this.background,
  });

  final double amount;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 88),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        AmountBookViewModel.formatAmount(amount),
        textAlign: TextAlign.right,
        style: TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 15,
          color: color,
        ),
      ),
    );
  }
}

class _YouWillGetBox extends StatelessWidget {
  const _YouWillGetBox({required this.amount});

  final double? amount;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: sectionCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sectionCardBorder),
      ),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'You will get',
              style: TextStyle(
                color: sectionText,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Text(
            AmountBookViewModel.formatAmount(amount),
            style: const TextStyle(
              color: cashYouGave,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _CustomerFooter extends StatelessWidget {
  const _CustomerFooter({required this.footer});

  final AmountBookCustomerFooter footer;

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
            child: _FooterStat(
              label: 'ADVANCE',
              value: AmountBookViewModel.formatAmount(footer.advance),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _FooterStat(
              label: 'OLD BALANCE',
              value: AmountBookViewModel.formatAmount(footer.oldBalance),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _FooterStat(
              label: 'BALANCE',
              value: AmountBookViewModel.formatAmount(footer.balance),
              color: cashYouGave,
            ),
          ),
        ],
      ),
    );
  }
}

class _FooterStat extends StatelessWidget {
  const _FooterStat({
    required this.label,
    required this.value,
    this.color,
  });

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
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
              color: sectionTextMuted,
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
              color: color ?? sectionText,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}
