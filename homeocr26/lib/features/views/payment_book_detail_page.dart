import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/invoice_summary_model.dart';
import '../../models/payment_book_model.dart';
import '../../viewModels/login_viewmodel.dart';
import '../services/payment_book_service.dart';
import '../theme.dart';
import '../widgets/app_responsive.dart';
import '../widgets/system_safe.dart';
import 'live_refresh_mixin.dart';

/// Detail for a Payment Book row (website "Open: Invoices" fields).
class PaymentBookDetailPage extends StatefulWidget {
  const PaymentBookDetailPage({super.key, required this.invoice});

  final InvoiceSummaryModel invoice;

  @override
  State<PaymentBookDetailPage> createState() => _PaymentBookDetailPageState();
}

class _PaymentBookDetailPageState extends State<PaymentBookDetailPage>
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

  String? _apiDate(String? raw) {
    final parsed = DateTime.tryParse((raw ?? '').trim());
    if (parsed == null) return null;
    final y = parsed.year.toString().padLeft(4, '0');
    final m = parsed.month.toString().padLeft(2, '0');
    final d = parsed.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  Future<void> _reload({bool silent = false}) async {
    final login = Provider.of<LoginViewmodel>(context, listen: false);
    final sessionId = login.sessionId;
    if (sessionId == null || sessionId.isEmpty) return;
    final date = _apiDate(_invoice.invoiceDate);
    final book = await PaymentBookService.fetch(
      sessionId: sessionId,
      dateFrom: date,
      dateTo: date,
      forceRefresh: true,
    );
    final next = InvoiceSummaryModel.matchInList(book.invoices, _invoice);
    if (!mounted || next == null) return;
    setState(() => _invoice = next);
  }

  InvoiceSummaryModel get invoice => _invoice;

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
            fontSize: 17,
          ),
        ),
      ),
      body: ResponsiveBody(
        child: Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              color: const Color(0xFFE07A2F),
              onRefresh: () => _reload(),
              child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: SystemSafe.listPadding(context, top: 8),
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(14, 16, 14, 8),
                  decoration: sectionCardDecoration(radius: 14),
                  child: Column(
                    children: [
                      _PlainField(label: 'Payment Book', value: _paymentBookRef),
                      _PlainField(
                        label: 'Invoice',
                        value: _invoiceLinkLabel,
                      ),
                      _PlainField(
                        label: 'Invoice Number',
                        value: invoice.displayNumber,
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
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: sectionText,
                fontSize: 15,
                fontWeight: FontWeight.w500,
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
                fontSize: 14,
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
