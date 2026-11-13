import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/amount_book_model.dart';
import '../../models/invoice_summary_model.dart';
import '../../viewModels/amount_book_viewmodel.dart';
import '../services/customer_invoice_pdf_service.dart';
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
    this.paymentId,
    this.paymentName,
  });

  final String customerName;
  final List<AmountBookInvoiceLine> invoices;
  final DateTime? date;
  final bool isYouGave;
  final int? paymentId;
  final String? paymentName;

  @override
  State<AmountBookInvoiceTablePage> createState() =>
      _AmountBookInvoiceTablePageState();
}

class _AmountBookInvoiceTablePageState extends State<AmountBookInvoiceTablePage>
    with LiveRefreshMixin {
  List<AmountBookInvoiceLine>? _paymentLines;
  bool _loadingPaymentLines = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_ensurePaymentLines());
    });
    startLiveRefresh(
      () async {
        if (!mounted) return;
        // Soft refresh payment lines only — skip full Cash Book fetch.
        await _ensurePaymentLines(force: true, silent: true);
      },
      interval: const Duration(seconds: 5),
    );
  }

  @override
  void dispose() {
    stopLiveRefresh();
    super.dispose();
  }

  Future<void> _ensurePaymentLines({
    bool force = false,
    bool silent = false,
  }) async {
    final paymentId = widget.paymentId;
    if (paymentId == null) return;
    if (!force &&
        _paymentLines != null &&
        _paymentLines!.isNotEmpty &&
        !_paymentLines!.every(_isPaymentNumberRow)) {
      return;
    }
    if (_loadingPaymentLines) return;
    final showSpinner = !silent &&
        (_paymentLines == null ||
            _paymentLines!.isEmpty ||
            _paymentLines!.every(_isPaymentNumberRow));
    if (showSpinner) setState(() => _loadingPaymentLines = true);
    try {
      final model = context.read<AmountBookViewModel>();
      final loaded = await model.loadPaymentInvoiceLines(context, paymentId);
      if (!mounted) return;
      if (loaded.isNotEmpty) {
        setState(() => _paymentLines = loaded);
      }
    } finally {
      if (mounted && showSpinner) {
        setState(() => _loadingPaymentLines = false);
      } else if (mounted && _loadingPaymentLines) {
        setState(() => _loadingPaymentLines = false);
      }
    }
  }

  static bool _isPaymentNumberRow(AmountBookInvoiceLine line) {
    final n = line.number.trim().toUpperCase();
    return n.startsWith('PAY/') || n.startsWith('PMT/');
  }

  Future<void> _refresh({bool silent = false}) async {
    await context.read<AmountBookViewModel>().fetch(
          context,
          forceRefresh: true,
          silent: silent,
        );
    if (!mounted) return;
    await _ensurePaymentLines(force: true);
  }

  List<AmountBookInvoiceLine> _resolveRows(AmountBookViewModel model) {
    if (_paymentLines != null && _paymentLines!.isNotEmpty) {
      return _filterYouGotPayRows(_paymentLines!);
    }
    // Show nest lines from the ledger immediately while detail API loads.
    final seed = _filterYouGotPayRows(widget.invoices);
    if (seed.isNotEmpty && !seed.every(_isPaymentNumberRow)) {
      return seed;
    }
    final live = model.invoicesForLedgerTap(
      customerName: widget.customerName,
      isYouGave: widget.isYouGave,
      date: widget.date,
      numbers: widget.invoices.map((e) => e.number).toList(),
      paymentId: widget.paymentId,
    );
    final source = live.isNotEmpty ? live : widget.invoices;
    // Never show PAY/xxxx as the only "invoice" when this is a payment drill-in.
    if (widget.paymentId != null &&
        source.isNotEmpty &&
        source.every(_isPaymentNumberRow)) {
      return const [];
    }
    return _filterYouGotPayRows(source);
  }

  /// YOU GOT / payment nest: only bills that actually received pay amount.
  List<AmountBookInvoiceLine> _filterYouGotPayRows(
    List<AmountBookInvoiceLine> source,
  ) {
    final isYouGotNest = widget.paymentId != null || !widget.isYouGave;
    if (!isYouGotNest) return source;
    return source
        .where((row) => (row.youGotAmount ?? 0) > 0.0001)
        .toList(growable: false);
  }

  void _openCustomerInvoice(
    BuildContext context,
    AmountBookInvoiceLine line,
  ) {
    final model = context.read<AmountBookViewModel>();
    // Prefer this payment's residual (balance_after) over list/API pre-pay balance.
    final invoice = model.invoiceSummaryForLine(line).mergedWith(
          InvoiceSummaryModel(
            customer: widget.customerName,
            balance: line.balance,
            total: line.total,
          ),
        );
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CustomerInvoiceDetailPage(
          invoice: invoice,
          title: 'Customer Invoice',
          partnerLabel: 'Customer',
          allowScan: true,
          supplierLayout: false,
          balanceOverride: line.balance,
        ),
      ),
    );
  }

  Future<void> _shareCustomerInvoice(
    BuildContext context,
    AmountBookInvoiceLine line,
  ) async {
    final model = context.read<AmountBookViewModel>();
    final invoice = model.invoiceSummaryForLine(line).mergedWith(
          InvoiceSummaryModel(customer: widget.customerName),
        );
    await CustomerInvoicePdfService.shareInvoice(
      context,
      invoice: invoice,
      payAmount: line.youGotAmount ?? line.youGaveAmount,
      paymentName: widget.paymentName,
    );
  }

  @override
  Widget build(BuildContext context) {
    final model = context.watch<AmountBookViewModel>();
    final titleDate = AmountBookLedgerBuilder.formatDisplayDate(widget.date);
    final rows = _resolveRows(model);
    final isPayment = widget.paymentId != null || !widget.isYouGave;
    final paymentTitle = (widget.paymentName ?? '').trim();

    double totalSum = 0;
    double balanceSum = 0;
    double paySum = 0;
    double previouslyPaidSum = 0;
    for (final row in rows) {
      final total = row.total ?? 0;
      final balance = row.balance ?? 0;
      final pay = row.youGotAmount ?? row.youGaveAmount ?? 0;
      totalSum += total;
      balanceSum += balance;
      paySum += pay;
      // Amount settled before this voucher: Total − this Pay − Balance after.
      final prior = total - pay - balance;
      if (prior > 0.0001) previouslyPaidSum += prior;
    }

    return Scaffold(
      backgroundColor: sectionBg,
      appBar: AppBar(
        iconTheme: const IconThemeData(color: sectionText),
        title: Text(
          paymentTitle.isNotEmpty ? paymentTitle : widget.customerName,
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
            if (widget.date != null || paymentTitle.isNotEmpty)
              Padding(
                padding: SystemSafe.horizontalPadding(
                  context,
                  top: 8,
                  bottom: 4,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    paymentTitle.isNotEmpty && widget.date != null
                        ? '$paymentTitle  •  $titleDate'
                        : (paymentTitle.isNotEmpty ? paymentTitle : titleDate),
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
                child: _loadingPaymentLines && rows.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          SizedBox(
                            height: MediaQuery.sizeOf(context).height * 0.35,
                            child: const Center(
                              child: CircularProgressIndicator(
                                color: sectionAccent,
                              ),
                            ),
                          ),
                        ],
                      )
                    : rows.isEmpty
                        ? ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            children: [
                              SizedBox(
                                height:
                                    MediaQuery.sizeOf(context).height * 0.35,
                                child: const Center(
                                  child: Text(
                                    'No invoices for this payment',
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
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, index) => _InvoiceCard(
                              invoice: rows[index],
                              paymentStyle: isPayment,
                              onOpenBill: () =>
                                  _openCustomerInvoice(context, rows[index]),
                              onShare: () =>
                                  _shareCustomerInvoice(context, rows[index]),
                            ),
                          ),
              ),
            ),
            _InvoiceTotals(
              count: rows.length,
              isPayment: isPayment,
              total: totalSum,
              balance: balanceSum,
              payAmount: paySum,
              previouslyPaid: isPayment ? previouslyPaidSum : 0,
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
    required this.onShare,
    this.paymentStyle = false,
  });

  final AmountBookInvoiceLine invoice;
  final VoidCallback onOpenBill;
  final VoidCallback onShare;
  final bool paymentStyle;

  @override
  Widget build(BuildContext context) {
    final fields = paymentStyle
        ? <Widget>[
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
              label: 'Total',
              value: AmountBookViewModel.formatAmount(invoice.total),
            ),
            _LineCell(
              label: 'Balance',
              value: AmountBookViewModel.formatAmount(invoice.balance),
            ),
            _LineCell(
              label: 'Pay Amount',
              value: AmountBookViewModel.formatAmount(invoice.youGotAmount),
              emphasize: true,
              color: cashYouGot,
            ),
            _LineCell(
              label: 'Status',
              value: invoice.status.trim().isEmpty ? '—' : invoice.status,
            ),
            if ((invoice.responsiblePerson ?? '').trim().isNotEmpty)
              _LineCell(
                label: 'Responsible Person',
                value: invoice.responsiblePerson!.trim(),
              ),
          ]
        : <Widget>[
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
              value: AmountBookLedgerBuilder.formatPaymentMode(
                invoice.paymentMode,
              ),
            ),
            _LineCell(
              label: invoice.isYouGave ? 'Bill Total' : 'Amount',
              value: AmountBookViewModel.formatAmount(
                invoice.isYouGave
                    ? invoice.total
                    : (invoice.youGotAmount ?? invoice.total),
              ),
            ),
            _LineCell(
              label: invoice.isYouGave ? 'You Gave' : 'You Got',
              value: AmountBookViewModel.formatAmount(
                invoice.isYouGave
                    ? invoice.youGaveAmount
                    : invoice.youGotAmount,
              ),
              emphasize: true,
              color: invoice.isYouGave ? cashYouGave : cashYouGot,
            ),
            _LineCell(
              label: 'Balance',
              value: AmountBookViewModel.formatAmount(invoice.balance),
            ),
          ];

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onOpenBill,
        borderRadius: BorderRadius.circular(12),
        child: Container(
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
                  _StatusPill(
                    paymentStyle
                        ? (invoice.status.trim().isEmpty
                            ? 'YOU GOT'
                            : invoice.status.trim())
                        : (invoice.isYouGave ? 'YOU GAVE' : 'YOU GOT'),
                    isGot: !invoice.isYouGave,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              CompactFieldRows(
                fields: fields,
                trailing: IconButton(
                  tooltip: 'Share invoice PDF',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                  onPressed: () {
                    // Absorb tap so parent InkWell does not open the bill.
                    onShare();
                  },
                  icon: Icon(
                    Icons.share_outlined,
                    size: 22,
                    color: sectionAccent,
                  ),
                ),
              ),
            ],
          ),
        ),
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
  const _StatusPill(this.label, {this.isGot = true});

  final String label;
  final bool isGot;

  @override
  Widget build(BuildContext context) {
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
    required this.isPayment,
    required this.total,
    required this.balance,
    required this.payAmount,
    this.previouslyPaid = 0,
  });

  final int count;
  final bool isPayment;
  final double total;
  final double balance;
  final double payAmount;
  /// Sum of amounts paid on these bills before this payment voucher.
  final double previouslyPaid;

  @override
  Widget build(BuildContext context) {
    final showPrior = isPayment && previouslyPaid > 0.0001;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        AppResponsive.of(context).pagePadding,
        10,
        AppResponsive.of(context).pagePadding,
        SystemSafe.actionBarBottomPadding(context),
      ),
      decoration: BoxDecoration(
        color: sectionFooter,
        border: Border(top: BorderSide(color: sectionCardBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$count bill${count == 1 ? '' : 's'}',
            style: TextStyle(
              color: sectionTextMuted,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
          if (showPrior) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: sectionCard,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: sectionCardBorder),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'PREVIOUSLY PAID',
                      style: TextStyle(
                        color: sectionTextMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    AmountBookViewModel.formatAmount(previouslyPaid),
                    style: const TextStyle(
                      color: sectionText,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _TotalBox(
                  label: 'TOTAL',
                  value: AmountBookViewModel.formatAmount(total),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _TotalBox(
                  label: isPayment ? 'PAY AMOUNT' : 'YOU GOT',
                  value: AmountBookViewModel.formatAmount(payAmount),
                  color: cashYouGot,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _TotalBox(
                  label: 'BALANCE',
                  value: AmountBookViewModel.formatAmount(balance),
                  color: cashYouGave,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TotalBox extends StatelessWidget {
  const _TotalBox({
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
