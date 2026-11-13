import 'package:flutter/material.dart';

import '../../models/payment_book_model.dart';

/// Website Payment Book row colours, shared across invoice list screens.
class PaymentBookStyleColors {
  const PaymentBookStyleColors._();

  static const Color billRed = Color(0xFF1565C0);

  static Color of(PaymentBookRowStyle style) {
    switch (style) {
      case PaymentBookRowStyle.walkIn:
      case PaymentBookRowStyle.normal:
        // Cash / walk-in share the same red.
        return billRed;
      case PaymentBookRowStyle.creditOpen:
        // Credit unpaid text — green (was black).
        return const Color(0xFFD32F2F);
      case PaymentBookRowStyle.creditPaid:
        return const Color(0xFF2E7D32);
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
  const PaymentBookColorLegend({
    super.key,
    this.hideStyles = const {},
    this.labelOverrides = const {},
  });

  /// Styles to omit from the legend (e.g. hide Cancel on Net Amount).
  final Set<PaymentBookRowStyle> hideStyles;
  /// Per-style label overrides (e.g. Draft → Pending on You Gave).
  final Map<PaymentBookRowStyle, String> labelOverrides;

  static const _items = <(PaymentBookRowStyle, String)>[
    (PaymentBookRowStyle.walkIn, 'Walk-in / Cash'),
    (PaymentBookRowStyle.creditOpen, 'Credit Unpaid'),
    (PaymentBookRowStyle.creditPaid, 'Credit Paid'),
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
          if (!hideStyles.contains(item.$1))
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
                  labelOverrides[item.$1] ?? item.$2,
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
  const InvoiceBillStatusBadge({super.key, required this.status, this.colorOverride});

  final String status;
  final Color? colorOverride;

  static Color colorFor(String status) {
    switch (status.toLowerCase().trim()) {
      case 'paid':
        return const Color(0xFF2E7D32);
      case 'draft':
      case 'pending':
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
        color: colorOverride ?? colorFor(label),
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
    this.selected,
    this.selectedKeys,
    required this.onSelected,
    this.hideKeys = const {},
    this.labelOverrides = const {},
  }) : assert(
          selected != null || selectedKeys != null,
          'Provide selected or selectedKeys',
        );

  /// Single-select mode (Payment Book, history, …).
  final String? selected;
  /// Multi-select mode (Net Amount You Got: draft+open).
  final Set<String>? selectedKeys;
  final ValueChanged<String> onSelected;
  /// Status keys to omit (e.g. hide `open` on You Gave).
  final Set<String> hideKeys;
  /// Per-screen chip label overrides (e.g. draft -> Pending).
  final Map<String, String> labelOverrides;

  bool _isSelected(String key) {
    final multi = selectedKeys;
    if (multi != null) {
      if (key == 'all') {
        return multi.isEmpty || multi.contains('all');
      }
      if (multi.isEmpty || multi.contains('all')) return false;
      return multi.contains(key);
    }
    return selected == key;
  }

  static const tabs = <(String, String)>[
    ('all', 'All'),
    ('draft', 'Draft'),
    ('open', 'Open'),
    ('paid', 'Paid'),
    ('cancel', 'Cancel'),
  ];

  static const _yellowHint = Color(0xFFF9A825);

  static String? _subtitleFor(String key) {
    switch (key) {
      case 'draft':
        return '(Incomplete)';
      case 'open':
        return '(Credit Pending)';
      default:
        return null;
    }
  }

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
                  label: _ChipLabel(
                    title: labelOverrides[tab.$1] ?? tab.$2,
                    subtitle: _subtitleFor(tab.$1),
                    selected: _isSelected(tab.$1),
                  ),
                  selected: _isSelected(tab.$1),
                  showCheckmark: true,
                  checkmarkColor: const Color(0xFFE07A2F),
                  onSelected: (_) => onSelected(tab.$1),
                  selectedColor: Colors.white,
                  backgroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  labelPadding: const EdgeInsets.symmetric(horizontal: 6),
                  side: BorderSide(
                    color: _isSelected(tab.$1)
                        ? const Color(0xFFE07A2F)
                        : Colors.black.withValues(alpha: 0.2),
                  ),
                  labelStyle: TextStyle(
                    color: _isSelected(tab.$1)
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

class _ChipLabel extends StatelessWidget {
  const _ChipLabel({
    required this.title,
    required this.selected,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final titleColor =
        selected ? const Color(0xFFE07A2F) : Colors.black;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: TextStyle(
            color: titleColor,
            fontWeight: FontWeight.w700,
            fontSize: 13,
            height: 1.1,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(
            subtitle!,
            style: const TextStyle(
              color: InvoiceStatusFilterChips._yellowHint,
              fontWeight: FontWeight.w700,
              fontSize: 10,
              height: 1.05,
            ),
          ),
        ],
      ],
    );
  }
}
