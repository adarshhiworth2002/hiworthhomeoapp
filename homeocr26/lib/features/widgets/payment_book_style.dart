import 'package:flutter/material.dart';

import '../../models/payment_book_model.dart';

/// Website Payment Book row colours, shared across invoice list screens.
class PaymentBookStyleColors {
  const PaymentBookStyleColors._();

  static const Color billRed = Color(0xFFD32F2F);

  static Color of(PaymentBookRowStyle style) {
    switch (style) {
      case PaymentBookRowStyle.walkIn:
      case PaymentBookRowStyle.normal:
        // Cash / walk-in share the same red.
        return billRed;
      case PaymentBookRowStyle.creditOpen:
        // Credit unpaid text — green (was black).
        return const Color(0xFF2E7D32);
      case PaymentBookRowStyle.creditPaid:
        return const Color(0xFF1565C0);
      case PaymentBookRowStyle.draft:
        return const Color(0xFF6B7280);
      case PaymentBookRowStyle.cancel:
        // Cancel text — cyan (was purple).
        return const Color(0xFF00ACC1);
    }
  }

  static FontWeight weightOf(PaymentBookRowStyle style) {
    switch (style) {
      case PaymentBookRowStyle.creditOpen:
        return FontWeight.w800;
      case PaymentBookRowStyle.draft:
      case PaymentBookRowStyle.cancel:
        return FontWeight.w600;
      default:
        return FontWeight.w600;
    }
  }
}

class PaymentBookColorLegend extends StatelessWidget {
  const PaymentBookColorLegend({super.key});

  static const _items = <(PaymentBookRowStyle, String)>[
    (PaymentBookRowStyle.walkIn, 'Walk-in / Cash'),
    (PaymentBookRowStyle.creditOpen, 'Credit unpaid'),
    (PaymentBookRowStyle.creditPaid, 'Credit paid'),
    (PaymentBookRowStyle.draft, 'Draft'),
    (PaymentBookRowStyle.cancel, 'Cancel'),
  ];

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 6,
      children: [
        for (final item in _items)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: PaymentBookStyleColors.of(item.$1),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                item.$2,
                style: TextStyle(
                  color: PaymentBookStyleColors.of(item.$1),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
      ],
    );
  }
}

/// Draft / Open / Paid / Cancel pill (top-right of list cards).
class InvoiceBillStatusBadge extends StatelessWidget {
  const InvoiceBillStatusBadge({super.key, required this.status});

  final String status;

  static Color colorFor(String status) {
    switch (status.toLowerCase().trim()) {
      case 'paid':
        return const Color(0xFF2E7D32);
      case 'draft':
        return const Color(0xFF6B7280);
      case 'open':
        return const Color(0xFF1565C0);
      case 'cancel':
      case 'cancelled':
      case 'canceled':
        return const Color(0xFF8E24AA);
      default:
        return PaymentBookStyleColors.billRed;
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = status.trim().isEmpty ? '—' : status.trim();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: colorFor(label),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// Shared All / Draft / Open / Paid / Cancel chips.
class InvoiceStatusFilterChips extends StatelessWidget {
  const InvoiceStatusFilterChips({
    super.key,
    required this.selected,
    required this.onSelected,
    this.hideKeys = const {},
  });

  final String selected;
  final ValueChanged<String> onSelected;
  /// Status keys to omit (e.g. hide `open` on You Gave).
  final Set<String> hideKeys;

  static const tabs = <(String, String)>[
    ('all', 'All'),
    ('draft', 'Draft'),
    ('open', 'Open'),
    ('paid', 'Paid'),
    ('cancel', 'Cancel'),
  ];

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final tab in tabs)
            if (!hideKeys.contains(tab.$1))
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilterChip(
                  label: Text(tab.$2),
                  selected: selected == tab.$1,
                  showCheckmark: true,
                  checkmarkColor: const Color(0xFFE07A2F),
                  onSelected: (_) => onSelected(tab.$1),
                  selectedColor: Colors.white,
                  backgroundColor: Colors.white,
                  side: BorderSide(
                    color: selected == tab.$1
                        ? const Color(0xFFE07A2F)
                        : Colors.black.withValues(alpha: 0.2),
                  ),
                  labelStyle: TextStyle(
                    color: selected == tab.$1
                        ? const Color(0xFFE07A2F)
                        : Colors.black,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
