import 'package:flutter/material.dart';

import '../../models/invoice_summary_model.dart';
import '../widgets/system_safe.dart';
import '../theme.dart';

/// Payment History session detail — same columns as the website list view.
class PaymentHistoryDetailPage extends StatelessWidget {
  const PaymentHistoryDetailPage({super.key, required this.invoice});

  final InvoiceSummaryModel invoice;

  @override
  Widget build(BuildContext context) {
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
            fontSize: 15,
          ),
        ),
        backgroundColor: sectionBg,
        elevation: 0,
      ),
      body: RefreshIndicator(
        color: const Color(0xFFE07A2F),
        onRefresh: () async {},
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
                          fontSize: 15,
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
                fontSize: 11,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: sectionText, fontSize: 12),
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
                fontSize: 10,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              InvoiceSummaryModel.formatMoney(value),
              style: const TextStyle(
                color: sectionText,
                fontWeight: FontWeight.w700,
                fontSize: 13,
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
      bg = Colors.white.withValues(alpha: 0.22);
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
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
