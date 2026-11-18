import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/amount_book_model.dart';
import '../../models/invoice_summary_model.dart';
import '../../viewModels/amount_book_viewmodel.dart';
import '../../viewModels/login_viewmodel.dart';
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
      // Warm session + prefetch receipt / bill PDFs for faster Share.
      if (!silent) {
        unawaited(_prefetchSharePdfs(loaded.isNotEmpty ? loaded : null));
      }
    } finally {
      if (mounted && showSpinner) {
        setState(() => _loadingPaymentLines = false);
      } else if (mounted && _loadingPaymentLines) {
        setState(() => _loadingPaymentLines = false);
      }
    }
  }

  Future<void> _prefetchSharePdfs(List<AmountBookInvoiceLine>? lines) async {
    final paymentId = widget.paymentId;
    if (paymentId == null || paymentId <= 0 || !mounted) return;
    final login = context.read<LoginViewmodel>();
    await CustomerInvoicePdfService.warmPrintSession(login);
    if (!mounted) return;

    double? amount;
    for (final p in context.read<AmountBookViewModel>().payments) {
      if (p.id == paymentId) {
        amount = p.amount;
        break;
      }
    }
    unawaited(
      CustomerInvoicePdfService.prefetchPayment(
        login,
        paymentId: paymentId,
        paymentName: widget.paymentName,
        customerName: widget.customerName,
        amount: amount,
      ),
    );

    final rows = lines ?? _resolveRows(context.read<AmountBookViewModel>());
    // Prefetch first few bills (partner_payment) — enough for typical nest.
    for (final line in rows.take(3)) {
      final invoice = _invoiceForLine(line);
      if (invoice.id == null || invoice.id! <= 0) continue;
      unawaited(
        CustomerInvoicePdfService.prefetchInvoice(
          login,
          invoice: invoice,
          payAmount: line.youGotAmount ?? line.youGaveAmount,
          paymentName: widget.paymentName,
          partnerPaymentId: paymentId,
        ),
      );
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

  int? _partnerPaymentIdForLine(
    AmountBookViewModel model,
    AmountBookInvoiceLine line, {
    int? preferred,
  }) {
    if (preferred != null && preferred > 0) return preferred;
    final nestPay = widget.paymentId;
    if (nestPay != null && nestPay > 0) return nestPay;
    return model.paymentIdForInvoice(line.invoiceId);
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
    final partnerPayId = _partnerPaymentIdForLine(model, line);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CustomerInvoiceDetailPage(
          invoice: invoice,
          title: 'Customer Invoice',
          partnerLabel: 'Customer',
          allowScan: true,
          supplierLayout: false,
          balanceOverride: line.balance,
          // Tax invoice share must keep ?partner_payment= from this nest.
          partnerPaymentId: partnerPayId,
        ),
      ),
    );
  }

  InvoiceSummaryModel _invoiceForLine(AmountBookInvoiceLine line) {
    return context.read<AmountBookViewModel>().invoiceSummaryForLine(line).mergedWith(
          InvoiceSummaryModel(customer: widget.customerName),
        );
  }

  bool get _isYouGotOrPaymentNest =>
      widget.paymentId != null || !widget.isYouGave;

  Future<void> _shareCustomerInvoice(
    BuildContext context,
    AmountBookInvoiceLine line, {
    int? partnerPaymentId,
  }) async {
    final model = context.read<AmountBookViewModel>();
    final payId = _partnerPaymentIdForLine(
      model,
      line,
      preferred: partnerPaymentId,
    );
    // YOU GOT / PAY nest bill Share → always ?partner_payment= (never plain).
    if (_isYouGotOrPaymentNest && (payId == null || payId <= 0)) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No payment linked to this bill for sharing.'),
        ),
      );
      return;
    }
    await CustomerInvoicePdfService.shareInvoice(
      context,
      invoice: _invoiceForLine(line),
      payAmount: line.youGotAmount ?? line.youGaveAmount,
      paymentName: widget.paymentName,
      partnerPaymentId: payId,
    );
  }

  /// Row WhatsApp → that bill's tax invoice with `partner_payment=`.
  Future<void> _shareCustomerInvoiceToWhatsApp(
    BuildContext context,
    AmountBookInvoiceLine line, {
    int? partnerPaymentId,
  }) async {
    final model = context.read<AmountBookViewModel>();
    final payId = _partnerPaymentIdForLine(
      model,
      line,
      preferred: partnerPaymentId,
    );
    if (payId == null || payId <= 0) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No payment linked to this bill for WhatsApp.'),
        ),
      );
      return;
    }
    await CustomerInvoicePdfService.shareInvoiceToWhatsApp(
      context,
      invoice: _invoiceForLine(line),
      payAmount: line.youGotAmount ?? line.youGaveAmount,
      paymentName: widget.paymentName,
      partnerPaymentId: payId,
    );
  }

  /// App-bar Share → payment receipt `/partner-payments/{id}/print`.
  Future<void> _sharePaymentReceipt(BuildContext context) async {
    final paymentId = widget.paymentId;
    if (paymentId == null || paymentId <= 0) return;
    double? amount;
    for (final p in context.read<AmountBookViewModel>().payments) {
      if (p.id == paymentId) {
        amount = p.amount;
        break;
      }
    }
    await CustomerInvoicePdfService.sharePayment(
      context,
      paymentId: paymentId,
      paymentName: widget.paymentName,
      customerName: widget.customerName,
      amount: amount,
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
        actions: [
          if (widget.paymentId != null && widget.paymentId! > 0)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Center(
                child: _ShareGradientChip(
                  label: 'Share',
                  onTap: () => _sharePaymentReceipt(context),
                ),
              ),
            ),
        ],
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
                            itemBuilder: (context, index) {
                              final line = rows[index];
                              final partnerPayId = _partnerPaymentIdForLine(
                                model,
                                line,
                              );
                              return _InvoiceCard(
                                invoice: line,
                                paymentStyle: isPayment,
                                showWhatsApp: partnerPayId != null,
                                onOpenBill: () =>
                                    _openCustomerInvoice(context, line),
                                // Bill Share → tax invoice ?partner_payment=
                                onShare: () => _shareCustomerInvoice(
                                  context,
                                  line,
                                  partnerPaymentId: partnerPayId,
                                ),
                                onWhatsApp: partnerPayId == null
                                    ? null
                                    : () => _shareCustomerInvoiceToWhatsApp(
                                          context,
                                          line,
                                          partnerPaymentId: partnerPayId,
                                        ),
                              );
                            },
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
    this.onWhatsApp,
    this.paymentStyle = false,
    this.showWhatsApp = false,
  });

  final AmountBookInvoiceLine invoice;
  final VoidCallback onOpenBill;
  final VoidCallback onShare;
  final VoidCallback? onWhatsApp;
  final bool paymentStyle;
  final bool showWhatsApp;

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

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: sectionCardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
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
                    IconButton(
                      tooltip: 'Open invoice',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 36,
                        minHeight: 36,
                      ),
                      onPressed: onOpenBill,
                      icon: Icon(
                        Icons.open_in_new,
                        size: 20,
                        color: sectionAccent,
                      ),
                    ),
                  ],
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
            trailing: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: paymentStyle
                      ? 'Share bill PDF'
                      : 'Share invoice PDF',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                  onPressed: onShare,
                  icon: Icon(
                    Icons.share_outlined,
                    size: 22,
                    color: sectionAccent,
                  ),
                ),
                if (showWhatsApp && onWhatsApp != null) ...[
                  const SizedBox(height: 2),
                  _WhatsAppIconButton(onTap: onWhatsApp!),
                ],
              ],
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

/// WhatsApp logo under bill Share — tax invoice with partner_payment=.
class _WhatsAppIconButton extends StatelessWidget {
  const _WhatsAppIconButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'WhatsApp bill PDF',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 22,
            height: 22,
            child: ClipOval(
              child: Image.asset(
                'assets/images/whatsapp_logo.png',
                width: 22,
                height: 22,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
                errorBuilder: (_, _, _) => const Icon(
                  Icons.chat,
                  size: 18,
                  color: Color(0xFF25D366),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact Share control — brand blue→green gradient with icon + label.
class _ShareGradientChip extends StatelessWidget {
  const _ShareGradientChip({
    required this.label,
    required this.onTap,
  });

  final String label;
  final VoidCallback onTap;

  static const _gradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [
      Color(0xFF00BCF8),
      Color(0xFF0096C7),
      Color(0xFF40B448),
    ],
  );

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            gradient: _gradient,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: appBlue.withValues(alpha: 0.28),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.share_outlined,
                size: 16,
                color: Colors.white,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
