import 'package:flutter/material.dart';

import '../../models/invoice_summary_model.dart';
import '../../models/payment_book_model.dart';
import '../theme.dart';
import '../widgets/app_responsive.dart';
import '../widgets/system_safe.dart';
import 'invoice_list_widgets.dart';

/// Detail for a Payment Book row (website "Open: Invoices" fields).
class PaymentBookDetailPage extends StatelessWidget {
  const PaymentBookDetailPage({super.key, required this.invoice});

  final InvoiceSummaryModel invoice;

  String get _paymentBookRef {
    final id = invoice.id;
    if (id != null && id > 0) return 'customer.payment.book,$id';
    return 'customer.payment.book';
  }

  String get _invoiceLinkLabel {
    final number = invoice.displayNumber;
    final name = invoice.displayPaymentBookName;
    final rawDate = (invoice.invoiceDate ?? '').trim();
    String datePart = rawDate;
    final parsed = DateTime.tryParse(rawDate);
    if (parsed != null) {
      final y = parsed.year.toString().padLeft(4, '0');
      final m = parsed.month.toString().padLeft(2, '0');
      final d = parsed.day.toString().padLeft(2, '0');
      datePart = '$y-$m-$d';
    }
    if (datePart.isEmpty) datePart = '—';
    return '$number - $name - $datePart';
  }

  String get _paymentModeDisplay {
    final raw = (invoice.paymentMode ?? '').trim();
    if (raw.isEmpty) {
      return invoice.isCreditCustomer ? 'Credit' : '—';
    }
    return raw
        .split(RegExp(r'[\s_]+'))
        .where((p) => p.isNotEmpty)
        .map((p) => p[0].toUpperCase() + p.substring(1).toLowerCase())
        .join(' ');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: sectionBg,
      appBar: AppBar(
        backgroundColor: sectionAppBar,
        elevation: 0,
        iconTheme: const IconThemeData(color: sectionText),
        title: const Text(
          'Open: Invoices',
          style: TextStyle(
            color: sectionText,
            fontWeight: FontWeight.w500,
            fontSize: 15,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close, color: sectionText),
          ),
        ],
      ),
      body: ResponsiveBody(
        child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: SystemSafe.listPadding(context, top: 8),
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(14, 16, 14, 8),
                  decoration: sectionCardDecoration(radius: 14),
                  child: Column(
                    children: [
                      _LinkField(label: 'Payment Book', value: _paymentBookRef),
                      _LinkField(
                        label: 'Invoice',
                        value: _invoiceLinkLabel,
                        onTap: () => openInvoiceDetail(
                          context,
                          invoice,
                          title: 'Customer Invoice',
                        ),
                      ),
                      _LinkField(
                        label: 'Invoice Number',
                        value: invoice.displayNumber,
                        onTap: () => openInvoiceDetail(
                          context,
                          invoice,
                          title: 'Customer Invoice',
                        ),
                      ),
                      _PlainField(
                        label: 'Name',
                        value: invoice.displayPaymentBookName,
                      ),
                      _PlainField(
                        label: 'Invoice Date',
                        value: invoice.displayPaymentBookDate,
                      ),
                      _PlainField(
                        label: 'Balance',
                        value: InvoiceSummaryModel.formatMoney(invoice.balance),
                      ),
                      _PlainField(
                        label: 'Total',
                        value: InvoiceSummaryModel.formatMoney(invoice.total),
                      ),
                      _PlainField(
                        label: 'Payment Mode',
                        value: _paymentModeDisplay,
                      ),
                      _PlainField(
                        label: 'Status',
                        value: invoice.displayPaymentBookStatus,
                      ),
                      _CheckboxField(
                        label: 'Credit Customer',
                        checked: invoice.isCreditCustomer,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Container(
            width: double.infinity,
            padding: EdgeInsets.fromLTRB(
              16,
              12,
              16,
              SystemSafe.actionBarBottomPadding(context),
            ),
            decoration: BoxDecoration(
              color: sectionFooter,
              border: Border(
                top: BorderSide(color: sectionCardBorder),
              ),
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: sectionAccent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 22,
                    vertical: 12,
                  ),
                ),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text(
                  'Close',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }
}

void openPaymentBookDetail(BuildContext context, InvoiceSummaryModel invoice) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => PaymentBookDetailPage(invoice: invoice),
    ),
  );
}

class _PlainField extends StatelessWidget {
  const _PlainField({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(
                color: sectionTextMuted,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: sectionText,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LinkField extends StatelessWidget {
  const _LinkField({
    required this.label,
    required this.value,
    this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(
                color: sectionTextMuted,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: InkWell(
              onTap: onTap,
              child: Text(
                value,
                style: TextStyle(
                  color: onTap == null ? sectionAccent : const Color(0xFFCE93D8),
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  decoration:
                      onTap == null ? null : TextDecoration.underline,
                  decorationColor: const Color(0xFFCE93D8),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CheckboxField extends StatelessWidget {
  const _CheckboxField({required this.label, required this.checked});

  final String label;
  final bool checked;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(
                color: sectionTextMuted,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Icon(
            checked ? Icons.check_box : Icons.check_box_outline_blank,
            size: 22,
            color: checked ? sectionAccent : sectionTextMuted,
          ),
        ],
      ),
    );
  }
}
