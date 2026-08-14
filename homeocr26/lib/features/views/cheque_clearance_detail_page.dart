import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models/cheque_clearance_model.dart';
import '../services/cheque_payment_enrichment.dart';
import '../widgets/system_safe.dart';
import 'customer_payment_from_cheque_page.dart';
import '../theme.dart';

/// Cheque Details / PDC Entry — screenshot 2.
class ChequeClearanceDetailPage extends StatefulWidget {
  const ChequeClearanceDetailPage({super.key, required this.cheque});

  final ChequeClearanceModel cheque;

  @override
  State<ChequeClearanceDetailPage> createState() =>
      _ChequeClearanceDetailPageState();
}

class _ChequeClearanceDetailPageState extends State<ChequeClearanceDetailPage> {
  static const _states = ['Draft', 'Posted', 'Bounced', 'Paid', 'Cancelled'];

  late ChequeClearanceModel _cheque;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _cheque = widget.cheque;
    WidgetsBinding.instance.addPostFrameCallback((_) => _enrich());
  }

  Future<void> _enrich() async {
    try {
      final enriched = await ChequePaymentEnrichment.enrich(context, _cheque);
      if (!mounted) return;
      setState(() {
        _cheque = enriched;
        _loading = false;
      });
    } catch (e, s) {
      if (kDebugMode) debugPrint('cheque detail enrich: $e\n$s');
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cheque = _cheque;
    final active = cheque.displayState;

    return Scaffold(
      backgroundColor: sectionBg,
      appBar: AppBar(
        iconTheme: const IconThemeData(color: sectionText),
        title: const Text(
          'Cheque Details',
          style: TextStyle(
            color: sectionText,
            fontWeight: FontWeight.w500,
            fontSize: 15,
          ),
        ),
        backgroundColor: sectionBg,
        elevation: 0,
      ),
      body: Stack(
        children: [
          ListView(
            padding: SystemSafe.listPadding(context),
            children: [
              _HeaderBanner(
                title: 'CHEQUE DETAILS / PDC ENTRY',
                subtitle: cheque.displaySerial,
              ),
              const SizedBox(height: 10),
              _StatusStepper(states: _states, active: active),
              const SizedBox(height: 14),
              _InfoCard(
                icon: Icons.description_outlined,
                title: 'Cheque Information',
                children: [
                  _Field('CHEQUE NO', cheque.displayChequeNo, highlight: true),
                  _Field(
                    'CHEQUE DATE',
                    ChequeClearanceModel.formatDate(cheque.chequeDate),
                  ),
                  _Field(
                    'ENTRY DATE',
                    ChequeClearanceModel.formatDate(cheque.date),
                  ),
                  _Field(
                    'CLEARANCE DATE',
                    ChequeClearanceModel.formatDate(cheque.clearanceDate),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _InfoCard(
                icon: Icons.person_outline,
                title: 'Party Details',
                children: [
                  _TappableField(
                    label: 'CUSTOMER PAYMENT',
                    value: cheque.displayCustomerPayment,
                    onTap: !cheque.hasCustomerPayment
                        ? null
                        : () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => CustomerPaymentFromChequePage(
                                  cheque: cheque,
                                ),
                              ),
                            );
                          },
                  ),
                  _Field('NAME', cheque.displayPartner),
                  _Field(
                    'TOTAL AMOUNT',
                    ChequeClearanceModel.formatMoney(cheque.displayBalance),
                  ),
                  _Field(
                    'CHEQUE AMOUNT',
                    ChequeClearanceModel.formatMoney(cheque.displayChequeAmount),
                    emphasize: true,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _InfoCard(
                icon: Icons.account_balance_outlined,
                title: 'Bank Details',
                children: [
                  _Field('BANK', cheque.displayBank),
                  _Field('BRANCH', cheque.displayBranch),
                  _Field('IFSC CODE', cheque.displayIfsc),
                ],
              ),
              const SizedBox(height: 10),
              _InfoCard(
                icon: Icons.list_alt_outlined,
                title: 'Linked Invoices',
                children: [
                  Text(
                    'Select Invoices',
                    style: TextStyle(
                      color: sectionTextMuted,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (cheque.invoices.isEmpty)
                    Text(
                      _loading ? 'Loading invoices…' : '—',
                      style: TextStyle(
                        color: sectionTextMuted,
                      ),
                    )
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: () {
                        final selected = cheque.invoices
                            .where((e) => e.selected || (e.payAmount ?? 0) > 0)
                            .toList();
                        final chips = selected.isNotEmpty
                            ? selected
                            : cheque.invoices;
                        return chips
                            .map(
                              (inv) => Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: sectionCard,
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                    color:
                                        Colors.white.withValues(alpha: 0.2),
                                  ),
                                ),
                                child: Text(
                                  inv.displayLabel,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            )
                            .toList();
                      }(),
                    ),
                ],
              ),
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
    );
  }
}

class _HeaderBanner extends StatelessWidget {
  const _HeaderBanner({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF2F5F8F),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.payments_outlined, color: Colors.white, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: sectionText,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusStepper extends StatelessWidget {
  const _StatusStepper({required this.states, required this.active});

  final List<String> states;
  final String active;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < states.length; i++) ...[
            if (i > 0)
              Icon(
                Icons.chevron_right,
                size: 16,
                color: Colors.white.withValues(alpha: 0.35),
              ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: states[i].toLowerCase() == active.toLowerCase()
                    ? const Color(0xFF6B5B95)
                    : Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                states[i],
                style: TextStyle(
                  color: Colors.white.withValues(
                    alpha: states[i].toLowerCase() == active.toLowerCase()
                        ? 1
                        : 0.55,
                  ),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.icon,
    required this.title,
    required this.children,
  });

  final IconData icon;
  final String title;
  final List<Widget> children;

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
              Icon(icon, color: const Color(0xFFE07A2F), size: 18),
              const SizedBox(width: 8),
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
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field(
    this.label,
    this.value, {
    this.emphasize = false,
    this.highlight = false,
  });

  final String label;
  final String value;
  final bool emphasize;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final valueWidget = Text(
      value,
      style: TextStyle(
        color: Colors.white,
        fontSize: emphasize ? 15 : 13,
        fontWeight: emphasize ? FontWeight.w800 : FontWeight.w500,
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: sectionTextMuted,
              fontSize: 10,
              letterSpacing: 0.4,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          if (highlight)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFF4CAF50)),
                borderRadius: BorderRadius.circular(4),
              ),
              child: valueWidget,
            )
          else
            valueWidget,
        ],
      ),
    );
  }
}

class _TappableField extends StatelessWidget {
  const _TappableField({
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
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: sectionTextMuted,
              fontSize: 10,
              letterSpacing: 0.4,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      value,
                      style: TextStyle(
                        color: onTap != null
                            ? const Color(0xFF64B5F6)
                            : Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        decoration:
                            onTap != null ? TextDecoration.underline : null,
                      ),
                    ),
                  ),
                  if (onTap != null) ...[
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.open_in_new,
                      size: 14,
                      color: Color(0xFF64B5F6),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
