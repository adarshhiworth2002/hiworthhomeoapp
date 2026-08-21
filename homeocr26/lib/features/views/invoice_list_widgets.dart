import 'package:flutter/material.dart';

import '../../models/invoice_summary_model.dart';
import '../../models/payment_book_model.dart';
import '../theme.dart';
import '../widgets/compact_field_rows.dart';
import '../widgets/payment_book_style.dart';
import 'customer_invoice_detail_page.dart';

/// Compact list row with status badge top-right.
/// Row colour matches Payment Book (walk-in/cash red, credit, draft, cancel).
class InvoiceListCard extends StatelessWidget {
  const InvoiceListCard({
    super.key,
    required this.invoice,
    this.onTap,
    this.statusValue,
  });

  final InvoiceSummaryModel invoice;
  final VoidCallback? onTap;
  /// When set, overrides [InvoiceSummaryModel.displayStatus] on the badge.
  final String? statusValue;

  @override
  Widget build(BuildContext context) {
    final style = invoice.paymentBookRowStyle;
    final color = PaymentBookStyleColors.of(style);
    final weight = PaymentBookStyleColors.weightOf(style);
    final status = (statusValue ?? invoice.displayStatus).trim();

    final fields = <Widget>[
      _LineCell(
        label: 'Number',
        value: invoice.displayNumber,
        color: color,
        weight: FontWeight.w800,
      ),
      _LineCell(
        label: 'Balance',
        value: InvoiceSummaryModel.formatMoney(invoice.balance),
        color: color,
        weight: weight,
      ),
      _LineCell(
        label: 'Subtotal',
        value: InvoiceSummaryModel.formatMoney(invoice.subtotal),
        color: color,
        weight: weight,
      ),
      _LineCell(
        label: 'Total',
        value: InvoiceSummaryModel.formatMoney(invoice.total),
        color: color,
        weight: FontWeight.w800,
      ),
    ];

    final card = Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: sectionCardDecoration(),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: CompactFieldRows(fields: fields)),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              InvoiceBillStatusBadge(status: status),
              if (onTap != null) ...[
                const SizedBox(height: 8),
                Icon(Icons.chevron_right, color: color, size: 20),
              ],
            ],
          ),
        ],
      ),
    );

    if (onTap == null) return card;

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: card,
    );
  }
}

class _LineCell extends StatelessWidget {
  const _LineCell({
    required this.label,
    required this.value,
    required this.color,
    required this.weight,
  });

  final String label;
  final String value;
  final Color color;
  final FontWeight weight;

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
            color: color.withValues(alpha: 0.65),
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
            fontWeight: weight,
            fontSize: 13,
          ),
        ),
      ],
    );
  }
}

void openInvoiceDetail(
  BuildContext context,
  InvoiceSummaryModel invoice, {
  String title = 'Customer Invoice',
}) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => CustomerInvoiceDetailPage(
        invoice: invoice,
        title: title,
      ),
    ),
  );
}

class InvoiceListError extends StatelessWidget {
  const InvoiceListError({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface.withValues(
                      alpha: 0.7,
                    ),
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 16),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
