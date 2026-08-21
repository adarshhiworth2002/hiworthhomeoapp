import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/invoice_summary_model.dart';
import '../../viewModels/login_viewmodel.dart';
import '../services/payment_history_service.dart';
import '../widgets/app_responsive.dart';
import '../widgets/system_safe.dart';
import 'live_refresh_mixin.dart';
import '../theme.dart';

/// Payment History session detail — same columns as the website list view.
class PaymentHistoryDetailPage extends StatefulWidget {
  const PaymentHistoryDetailPage({super.key, required this.invoice});

  final InvoiceSummaryModel invoice;

  @override
  State<PaymentHistoryDetailPage> createState() =>
      _PaymentHistoryDetailPageState();
}

class _PaymentHistoryDetailPageState extends State<PaymentHistoryDetailPage>
    with LiveRefreshMixin {
  late InvoiceSummaryModel _invoice;

  @override
  void initState() {
    super.initState();
    _invoice = widget.invoice;
    startLiveRefresh(() => _reload(silent: true));
  }

  @override
  void dispose() {
    stopLiveRefresh();
    super.dispose();
  }

  Future<void> _reload({bool silent = false}) async {
    final login = Provider.of<LoginViewmodel>(context, listen: false);
    final sessionId = login.sessionId;
    if (sessionId == null || sessionId.isEmpty) return;
    final items = await PaymentHistoryService.fetchInvoices(
      sessionId: sessionId,
      limit: 200,
      forceRefresh: true,
    );
    final next = InvoiceSummaryModel.matchInList(items, _invoice);
    if (!mounted || next == null) return;
    setState(() => _invoice = next);
  }

  @override
  Widget build(BuildContext context) {
    final invoice = _invoice;
    final verify = invoice.displayVerifyStatus;
    final status = invoice.displayPaymentHistoryStatus;

    return Scaffold(
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
      ),
      body: ResponsiveBody(
        child: RefreshIndicator(
        color: const Color(0xFFE07A2F),
        onRefresh: () => _reload(),
        child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: SystemSafe.listPadding(context),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: sectionCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: sectionCardBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        invoice.displayNumber,
                        style: const TextStyle(
                          color: sectionText,
                          fontWeight: FontWeight.w700,
                          fontSize: 17,
                        ),
                      ),
                    ),
                    _StatusPill(status),
                  ],
                ),
                const SizedBox(height: 10),
                _Meta('Invoice Number', invoice.displayNumber),
                _Meta('Customer', invoice.displayCustomer ?? '—'),
                _Meta('Invoice Date', invoice.invoiceDate ?? '—'),
                _Meta(
                  'Expiry Medicine Bill',
                  invoice.expiryMedicineBill ? 'Yes' : 'No',
                ),
                _Meta('Verify Status', verify),
                _Meta('Billed By', invoice.billedBy ?? '—'),
                _Meta('Status', status),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _AmountChip('Tax Amount', invoice.taxAmount),
                    const SizedBox(width: 8),
                    _AmountChip('Balance', invoice.balance),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    _AmountChip('Subtotal', invoice.subtotal),
                    const SizedBox(width: 8),
                    _AmountChip('Total', invoice.total),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
      ),
      ),
    );
  }
}

void openPaymentHistoryDetail(
  BuildContext context,
  InvoiceSummaryModel invoice,
) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => PaymentHistoryDetailPage(invoice: invoice),
    ),
  );
}

class _Meta extends StatelessWidget {
  const _Meta(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: TextStyle(
                color: sectionTextMuted,
                fontSize: 13,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: sectionText, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}

class _AmountChip extends StatelessWidget {
  const _AmountChip(this.label, this.value);

  final String label;
  final double? value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                color: sectionTextMuted,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              InvoiceSummaryModel.formatMoney(value),
              style: const TextStyle(
                color: sectionText,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final lower = label.toLowerCase();
    Color bg;
    if (lower.contains('paid')) {
      bg = const Color(0xFF2E7D32);
    } else if (lower.contains('hold')) {
      bg = const Color(0xFF1565C0);
    } else {
      bg = sectionAccent;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
