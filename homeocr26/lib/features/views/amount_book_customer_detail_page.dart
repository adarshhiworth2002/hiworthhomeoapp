import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/amount_book_model.dart';
import '../../viewModels/amount_book_viewmodel.dart';
import '../services/amount_book_pdf_service.dart';
import '../theme.dart';
import '../widgets/app_responsive.dart';
import '../widgets/system_safe.dart';

class AmountBookCustomerDetailPage extends StatelessWidget {
  const AmountBookCustomerDetailPage({
    super.key,
    required this.summary,
  });

  final AmountBookCustomerSummary summary;

  @override
  Widget build(BuildContext context) {
    final model = context.watch<AmountBookViewModel>();
    final entries = model.ledgerForCustomer(summary.customerName);

    return Scaffold(
      backgroundColor: sectionBg,
      appBar: AppBar(
        iconTheme: const IconThemeData(color: sectionText),
        title: Text(
          summary.customerName,
          style: const TextStyle(
            fontWeight: FontWeight.w500,
            fontSize: 15,
            color: sectionText,
          ),
        ),
        backgroundColor: sectionAppBar,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: 'Download PDF',
            onPressed: entries.isEmpty
                ? null
                : () => AmountBookPdfService.shareCustomerLedger(
                      customerName: summary.customerName,
                      entries: entries,
                      dateFrom: model.filter.dateFrom,
                      dateTo: model.filter.dateTo,
                    ),
            icon: const Icon(Icons.picture_as_pdf_outlined, color: sectionText),
          ),
        ],
      ),
      body: ResponsiveBody(
        child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  'YOU GAVE',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: sectionTextMuted,
                  ),
                ),
                const SizedBox(width: 28),
                Text(
                  'YOU GOT',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: sectionAccent.withValues(alpha: 0.95),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: entries.isEmpty
                ? const Center(
                    child: Text(
                      'No entries for this customer',
                      style: TextStyle(color: sectionTextMuted),
                    ),
                  )
                : ListView(
                    padding: SystemSafe.listPadding(context, top: 0),
                    children: _buildGroupedList(entries),
                  ),
          ),
        ],
      ),
      ),
    );
  }

  List<Widget> _buildGroupedList(List<AmountBookLedgerEntry> entries) {
    final widgets = <Widget>[];
    String? lastDayKey;

    for (final entry in entries) {
      final dayKey = _dayKey(entry.sortDate);
      if (dayKey != lastDayKey) {
        lastDayKey = dayKey;
        widgets.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
            child: Text(
              _formatDayHeader(entry.sortDate),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: sectionTextMuted,
              ),
            ),
          ),
        );
      }
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _LedgerEntryCard(entry: entry),
        ),
      );
    }
    return widgets;
  }

  static String _dayKey(DateTime? date) {
    if (date == null) return 'unknown';
    return '${date.year}-${date.month}-${date.day}';
  }

  static String _formatDayHeader(DateTime? date) {
    if (date == null) return '—';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(date.year, date.month, date.day);
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final d = date.day.toString().padLeft(2, '0');
    final m = months[date.month - 1];
    final y = (date.year % 100).toString().padLeft(2, '0');
    final label = '$d $m $y';
    if (day == today) return '$label • Today';
    return label;
  }
}

class _LedgerEntryCard extends StatelessWidget {
  const _LedgerEntryCard({required this.entry});

  final AmountBookLedgerEntry entry;

  @override
  Widget build(BuildContext context) {
    final gaveAmount = entry.youGaveAmount;
    final gotAmount = entry.youGotAmount;
    final timeLabel = _formatTime(entry.sortDate);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: sectionCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sectionCardBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (timeLabel.isNotEmpty)
                  Text(
                    timeLabel,
                    style: TextStyle(
                      fontSize: 11,
                      color: sectionTextMuted,
                    ),
                  ),
                const SizedBox(height: 2),
                Text(
                  entry.displayNumber,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: sectionText,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Bal. ${AmountBookViewModel.formatAmount(entry.balance)}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: sectionAccent,
                  ),
                ),
              ],
            ),
          ),
          if (gaveAmount != null && entry.isYouGave)
            _AmountPill(
              amount: gaveAmount,
              color: sectionText,
              background: Colors.white.withValues(alpha: 0.08),
            ),
          if (gotAmount != null && !entry.isYouGave) ...[
            const SizedBox(width: 8),
            _AmountPill(
              amount: gotAmount,
              color: sectionAccent,
              background: sectionAccent.withValues(alpha: 0.15),
            ),
          ],
        ],
      ),
    );
  }

  static String _formatTime(DateTime? date) {
    if (date == null) return '';
    if (date.hour == 0 && date.minute == 0) return '';
    final h = date.hour;
    final m = date.minute.toString().padLeft(2, '0');
    final period = h >= 12 ? 'PM' : 'AM';
    final hour12 = h % 12 == 0 ? 12 : h % 12;
    return '$hour12:$m $period';
  }
}

class _AmountPill extends StatelessWidget {
  const _AmountPill({
    required this.amount,
    required this.color,
    required this.background,
  });

  final double amount;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        AmountBookViewModel.formatAmount(amount),
        style: TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 13,
          color: color,
        ),
      ),
    );
  }
}
