import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models/cheque_clearance_model.dart';
import '../services/cheque_payment_enrichment.dart';
import '../widgets/app_responsive.dart';
import '../widgets/system_safe.dart';
import 'customer_payment_create_page.dart';
import '../theme.dart';

/// Customer Payment detail opened from cheque party details (PAY/0236).
class CustomerPaymentFromChequePage extends StatefulWidget {
  const CustomerPaymentFromChequePage({super.key, required this.cheque});

  final ChequeClearanceModel cheque;

  @override
  State<CustomerPaymentFromChequePage> createState() =>
      _CustomerPaymentFromChequePageState();
}

class _CustomerPaymentFromChequePageState
    extends State<CustomerPaymentFromChequePage> {
  late ChequeClearanceModel _cheque;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _cheque = widget.cheque;
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadPaymentDetail());
  }

  Future<void> _loadPaymentDetail() async {
    try {
      final enriched = await ChequePaymentEnrichment.enrich(context, _cheque);
      if (!mounted) return;
      setState(() {
        _cheque = enriched;
        _loading = false;
      });
    } catch (e, s) {
      if (kDebugMode) debugPrint('Customer payment detail: $e\n$s');
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cheque = _cheque;
    final invoices = cheque.invoices;
    final totalSum = invoices.fold<double>(
      0,
      (sum, inv) => sum + (inv.total ?? 0),
    );
    final balanceSum = invoices.fold<double>(
      0,
      (sum, inv) => sum + (inv.balance ?? 0),
    );
    final paySum = invoices.fold<double>(
      0,
      (sum, inv) => sum + (inv.payAmount ?? 0),
    );
    // Website outstanding = cheque balance (selected allocation remaining).
    final outstanding = cheque.displayBalance ?? balanceSum;

    return Scaffold(
      backgroundColor: sectionBg,
      appBar: AppBar(
        iconTheme: const IconThemeData(color: sectionText),
        title: Text(
          cheque.displayCustomerPayment,
          style: const TextStyle(
            color: sectionText,
            fontWeight: FontWeight.w500,
            fontSize: 15,
          ),
        ),
        backgroundColor: sectionBg,
        elevation: 0,
      ),
      body: ResponsiveBody(
        child: Stack(
        children: [
          ListView(
            padding: SystemSafe.listPadding(context),
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _NewPaymentGradientButton(
                  onPressed: () async {
                    final created = await Navigator.of(context).push<bool>(
                      MaterialPageRoute(
                        builder: (_) => CustomerPaymentCreatePage(
                          prefill: cheque,
                        ),
                      ),
                    );
                    if (!mounted) return;
                    if (created == true) {
                      await _loadPaymentDetail();
                    }
                  },
                ),
              ),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E4D5C),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.credit_card_outlined,
                      color: Colors.white,
                      size: 26,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'CUSTOMER PAYMENT',
                            style: TextStyle(
                              color: sectionText,
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                              letterSpacing: 0.3,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            cheque.displayCustomerPayment,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.9),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          'OUTSTANDING BALANCE',
                          style: TextStyle(
                            color: sectionTextMuted,
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '₹ ${ChequeClearanceModel.formatMoney(outstanding)}',
                          style: const TextStyle(
                            color: sectionText,
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _SectionCard(
                title: 'Customer & Payment Info',
                icon: Icons.person_outline,
                children: [
                  _Meta('Customer', cheque.displayPartner),
                  _Meta('Resp. Person', cheque.responsiblePerson ?? '—'),
                  _Meta(
                    'Date',
                    ChequeClearanceModel.formatDate(cheque.date),
                  ),
                  _Meta(
                    'Clearance Date',
                    ChequeClearanceModel.formatDate(cheque.clearanceDate),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _SectionCard(
                title: 'Financial Details',
                icon: Icons.currency_rupee,
                children: [
                  _Meta(
                    'Payment Amount',
                    '₹ ${ChequeClearanceModel.formatMoney(cheque.displayPaymentAmount)}',
                    highlight: true,
                    highlightColor: const Color(0xFF4CAF50),
                  ),
                  _Meta(
                    'Advance Amt',
                    ChequeClearanceModel.formatMoney(cheque.advanceAmount ?? 0),
                  ),
                  _Meta(
                    'Old Balance',
                    ChequeClearanceModel.formatMoney(cheque.oldBalance ?? 0),
                  ),
                  _Meta(
                    'Payment Mode',
                    cheque.paymentMode?.trim().isNotEmpty == true
                        ? cheque.paymentMode!
                        : 'Cheque',
                    highlight: true,
                    highlightColor: const Color(0xFF26C6DA),
                  ),
                  _Meta('Validated By', cheque.validatedBy ?? '—'),
                ],
              ),
              const SizedBox(height: 10),
              _SectionCard(
                title: 'Cheque Details',
                icon: Icons.description_outlined,
                children: [
                  _Meta('Cheque No', cheque.displayChequeNo),
                  _Meta(
                    'Bank',
                    (cheque.paymentBank?.trim().isNotEmpty == true)
                        ? cheque.paymentBank!
                        : cheque.displayBank,
                  ),
                  _Meta('Branch', cheque.displayBranch),
                  _Meta('IFSC', cheque.displayIfsc),
                  _Meta(
                    'Credited To',
                    cheque.creditedTo?.trim().isNotEmpty == true
                        ? cheque.creditedTo!
                        : cheque.displayBank,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                'INVOICES',
                style: TextStyle(
                  color: sectionTextMuted,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 8),
              if (invoices.isEmpty)
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: sectionCard,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _loading
                        ? 'Loading invoices…'
                        : 'No linked invoices',
                    style: const TextStyle(color: sectionTextMuted),
                  ),
                )
              else
                ...invoices.map((inv) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _InvoiceCard(invoice: inv),
                    )),
              if (invoices.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: sectionCard,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    children: [
                      _FooterRow(
                        'Total Amount',
                        '₹ ${ChequeClearanceModel.formatMoney(totalSum)}',
                      ),
                      _FooterRow(
                        'Balance Amount',
                        '₹ ${ChequeClearanceModel.formatMoney(balanceSum)}',
                      ),
                      _FooterRow(
                        'Pay Amount',
                        '₹ ${ChequeClearanceModel.formatMoney(paySum)}',
                      ),
                      _FooterRow(
                        'Validated By',
                        cheque.validatedBy ?? '—',
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          if (_loading)
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(
                color: Color(0xFFE07A2F),
                backgroundColor: Colors.transparent,
                minHeight: 2,
              ),
            ),
        ],
      ),
      ),
    );
  }
}

/// Same style as Customer Invoices "New Bill" gradient button.
class _NewPaymentGradientButton extends StatelessWidget {
  const _NewPaymentGradientButton({required this.onPressed});

  final VoidCallback? onPressed;

  static const _gradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [
      Color(0xFFE07A2F),
      Color(0xFFE8A04A),
      Color(0xFFC43B2E),
    ],
  );

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 18),
          decoration: BoxDecoration(
            gradient: onPressed == null
                ? LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      const Color(0xFFE07A2F).withValues(alpha: 0.45),
                      const Color(0xFFE8A04A).withValues(alpha: 0.45),
                      const Color(0xFFC43B2E).withValues(alpha: 0.45),
                    ],
                  )
                : _gradient,
            borderRadius: BorderRadius.circular(14),
            boxShadow: onPressed == null
                ? null
                : [
                    BoxShadow(
                      color: const Color(0xFFE07A2F).withValues(alpha: 0.35),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
          ),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add_circle_outline, color: Colors.white, size: 22),
              SizedBox(width: 10),
              Text(
                'New Payment',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.children,
    this.icon,
  });

  final String title;
  final List<Widget> children;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
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
              if (icon != null) ...[
                Icon(icon, color: const Color(0xFFE07A2F), size: 18),
                const SizedBox(width: 8),
              ],
              Text(
                title,
                style: const TextStyle(
                  color: sectionText,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta(
    this.label,
    this.value, {
    this.highlight = false,
    this.highlightColor = const Color(0xFF4CAF50),
  });

  final String label;
  final String value;
  final bool highlight;
  final Color highlightColor;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      value,
      style: const TextStyle(color: sectionText, fontSize: 12),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(
                color: sectionTextMuted,
                fontSize: 11,
              ),
            ),
          ),
          Expanded(
            child: highlight
                ? Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: highlightColor.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: highlightColor),
                    ),
                    child: text,
                  )
                : text,
          ),
        ],
      ),
    );
  }
}

class _InvoiceCard extends StatelessWidget {
  const _InvoiceCard({required this.invoice});

  final ChequeLinkedInvoice invoice;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: sectionCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sectionCardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                invoice.selected
                    ? Icons.check_box
                    : Icons.check_box_outline_blank,
                color: invoice.selected
                    ? const Color(0xFF7E57C2)
                    : Colors.white54,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  invoice.number ?? '—',
                  style: const TextStyle(
                    color: sectionText,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _InvCell(
                  'Invoice Date',
                  ChequeClearanceModel.formatDate(invoice.invoiceDate),
                ),
              ),
              Expanded(
                child: _InvCell(
                  'Total',
                  '₹ ${ChequeClearanceModel.formatMoney(invoice.total)}',
                ),
              ),
              Expanded(
                child: _InvCell(
                  'Balance',
                  '₹ ${ChequeClearanceModel.formatMoney(invoice.balance)}',
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _InvCell(
                  'Pay Amount',
                  '₹ ${ChequeClearanceModel.formatMoney(invoice.payAmount ?? 0)}',
                ),
              ),
              Expanded(
                child: _InvCell(
                  'Status',
                  _prettyStatus(invoice.status),
                ),
              ),
              Expanded(
                child: _InvCell(
                  'Resp. Person',
                  invoice.responsiblePerson ?? '—',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _prettyStatus(String? status) {
    if (status == null || status.trim().isEmpty) return '—';
    final s = status.trim().replaceAll('_', ' ');
    final lower = s.toLowerCase();
    if (lower == 'in payment') return 'In Payment';
    if (lower == 'not paid') return 'Not Paid';
    if (lower == 'partial' || lower == 'partially paid') {
      return 'Partially Paid';
    }
    return s[0].toUpperCase() + s.substring(1);
  }
}

class _InvCell extends StatelessWidget {
  const _InvCell(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: sectionTextMuted,
            fontSize: 9,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: sectionText, fontSize: 12),
        ),
      ],
    );
  }
}

class _FooterRow extends StatelessWidget {
  const _FooterRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: sectionTextMuted,
                fontSize: 12,
              ),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: sectionText,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
