import 'package:flutter/material.dart';

import '../../models/invoice_summary_model.dart';
import 'customer_invoice_detail_page.dart';

/// Compact single-line list row: Number · [Status] · Balance · Subtotal · Total.
/// Tap opens the full invoice detail screen.
class InvoiceListCard extends StatelessWidget {
  const InvoiceListCard({
    super.key,
    required this.invoice,
    this.onTap,
    this.statusValue,
  });

  final InvoiceSummaryModel invoice;
  final VoidCallback? onTap;
  /// When set, shows a Status column (Payment History uses website status).
  final String? statusValue;

  @override
  Widget build(BuildContext context) {
    final card = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: statusValue != null ? 2 : 3,
            child: _LineCell(
              label: 'Number',
              value: invoice.displayNumber,
              emphasize: true,
            ),
          ),
          if (statusValue != null)
            Expanded(
              flex: 2,
              child: _LineCell(
                label: 'Status',
                value: statusValue!,
              ),
            ),
          Expanded(
            flex: 2,
            child: _LineCell(
              label: 'Balance',
              value: InvoiceSummaryModel.formatMoney(invoice.balance),
            ),
          ),
          Expanded(
            flex: 2,
            child: _LineCell(
              label: 'Subtotal',
              value: InvoiceSummaryModel.formatMoney(invoice.subtotal),
            ),
          ),
          Expanded(
            flex: 2,
            child: _LineCell(
              label: 'Total',
              value: InvoiceSummaryModel.formatMoney(invoice.total),
              alignEnd: onTap == null,
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 4),
            Icon(
              Icons.chevron_right,
              color: Colors.white.withValues(alpha: 0.55),
              size: 20,
            ),
          ],
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
    this.emphasize = false,
    this.alignEnd = false,
  });

  final String label;
  final String value;
  final bool emphasize;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final align = alignEnd ? TextAlign.right : TextAlign.left;
    return Column(
      crossAxisAlignment:
          alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: align,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.55),
            fontSize: 9,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: align,
          style: TextStyle(
            color: Colors.white,
            fontWeight: emphasize ? FontWeight.w700 : FontWeight.w600,
            fontSize: emphasize ? 12 : 11,
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
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 16),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
