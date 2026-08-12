import 'invoice_summary_model.dart';
import 'net_amount_model.dart';

/// One ledger line for a customer detail screen (Khatabook-style).
class AmountBookLedgerEntry {
  const AmountBookLedgerEntry({
    required this.row,
    required this.isYouGave,
    this.sortDate,
    this.youGotAmount,
    this.youGaveAmount,
    this.balance,
  });

  final NetAmountRow row;
  final bool isYouGave;
  final DateTime? sortDate;
  final double? youGotAmount;
  final double? youGaveAmount;
  final double? balance;

  String get displayNumber => row.displayNumber;
}

/// Merged customer row on the Amount Book list.
class AmountBookCustomerSummary {
  const AmountBookCustomerSummary({
    required this.customerName,
    required this.entries,
    this.lastBalance,
    this.youGotTotal,
    this.youGaveTotal,
  });

  final String customerName;
  final List<AmountBookLedgerEntry> entries;
  final double? lastBalance;
  final double? youGotTotal;
  final double? youGaveTotal;

  int get entryCount => entries.length;
}

/// Date-range + name filter for Amount Book.
class AmountBookFilter {
  const AmountBookFilter({
    this.nameQuery = '',
    this.dateFrom,
    this.dateTo,
  });

  final String nameQuery;
  final DateTime? dateFrom;
  final DateTime? dateTo;

  bool get hasDateRange => dateFrom != null || dateTo != null;
  bool get hasName => nameQuery.trim().isNotEmpty;
  bool get isActive => hasDateRange || hasName;

  AmountBookFilter copyWith({
    String? nameQuery,
    DateTime? dateFrom,
    DateTime? dateTo,
    bool clearDates = false,
  }) {
    return AmountBookFilter(
      nameQuery: nameQuery ?? this.nameQuery,
      dateFrom: clearDates ? null : dateFrom ?? this.dateFrom,
      dateTo: clearDates ? null : dateTo ?? this.dateTo,
    );
  }
}

/// Build ledger entries and customer summaries from net-amount rows.
class AmountBookLedgerBuilder {
  const AmountBookLedgerBuilder._();

  /// Website folder for invoices with no customer / walk-in (blank field).
  static const String noneCustomerLabel = 'None';

  static bool isNoneCustomerLabel(String customerName) {
    return customerName.trim().toLowerCase() == noneCustomerLabel.toLowerCase();
  }

  static bool isNamelessCustomerRow(NetAmountRow row) {
    final name = (row.customer ?? '').trim();
    if (name.isEmpty) return true;
    return InvoiceSummaryModel.isPlaceholderCustomerName(name);
  }

  static bool _youGotRowMatchesCustomer(NetAmountRow row, String target) {
    if (isNoneCustomerLabel(target)) return isNamelessCustomerRow(row);
    return (row.customer ?? '').trim().toLowerCase() == target;
  }

  static bool _youGaveRowMatchesCustomer(NetAmountRow row, String target) {
    if (isNoneCustomerLabel(target)) return false;
    final name = (row.customer ?? row.supplier ?? '').trim().toLowerCase();
    return name == target;
  }

  static DateTime? parseRowDate(NetAmountRow row) {
    final raw = row.invoiceDate?.trim();
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  static bool rowInDateRange(
    NetAmountRow row,
    DateTime? from,
    DateTime? to,
  ) {
    final d = parseRowDate(row);
    if (d == null) return from == null && to == null;
    final day = DateTime(d.year, d.month, d.day);
    if (from != null) {
      final start = DateTime(from.year, from.month, from.day);
      if (day.isBefore(start)) return false;
    }
    if (to != null) {
      final end = DateTime(to.year, to.month, to.day);
      if (day.isAfter(end)) return false;
    }
    return true;
  }

  static AmountBookLedgerEntry youGotEntry(NetAmountRow row) {
    return AmountBookLedgerEntry(
      row: row,
      isYouGave: false,
      sortDate: parseRowDate(row),
      youGotAmount: row.total,
      balance: row.balance,
    );
  }

  static AmountBookLedgerEntry youGaveEntry(NetAmountRow row) {
    return AmountBookLedgerEntry(
      row: row,
      isYouGave: true,
      sortDate: parseRowDate(row),
      youGaveAmount: row.total,
      balance: row.balance,
    );
  }

  static List<AmountBookLedgerEntry> entriesForCustomer({
    required String customerName,
    required List<NetAmountRow> youGotRows,
    required List<NetAmountRow> youGaveRows,
    AmountBookFilter? filter,
  }) {
    final target = customerName.trim().toLowerCase();
    final entries = <AmountBookLedgerEntry>[];

    for (final row in youGotRows) {
      if (!_youGotRowMatchesCustomer(row, target)) continue;
      if (filter != null &&
          !rowInDateRange(row, filter.dateFrom, filter.dateTo)) {
        continue;
      }
      entries.add(youGotEntry(row));
    }

    for (final row in youGaveRows) {
      if (!_youGaveRowMatchesCustomer(row, target)) continue;
      if (filter != null &&
          !rowInDateRange(row, filter.dateFrom, filter.dateTo)) {
        continue;
      }
      entries.add(youGaveEntry(row));
    }

    entries.sort((a, b) {
      final da = a.sortDate ?? DateTime(1970);
      final db = b.sortDate ?? DateTime(1970);
      final cmp = da.compareTo(db);
      if (cmp != 0) return cmp;
      return a.displayNumber.compareTo(b.displayNumber);
    });
    return entries;
  }

  static double? lastEntryBalance(List<AmountBookLedgerEntry> entries) {
    if (entries.isEmpty) return null;
    return entries.last.balance;
  }

  static List<AmountBookCustomerSummary> buildCustomerSummaries({
    required List<NetAmountRow> youGotRows,
    required List<NetAmountRow> youGaveRows,
    AmountBookFilter filter = const AmountBookFilter(),
  }) {
    final names = <String>{};
    for (final row in youGotRows) {
      final name = (row.customer ?? '').trim();
      if (name.isEmpty) continue;
      if (InvoiceSummaryModel.isPlaceholderCustomerName(name)) continue;
      names.add(name);
    }

    final summaries = <AmountBookCustomerSummary>[];
    for (final name in names) {
      final entries = entriesForCustomer(
        customerName: name,
        youGotRows: youGotRows,
        youGaveRows: youGaveRows,
        filter: filter,
      );
      if (entries.isEmpty) continue;

      final nameLower = name.toLowerCase();
      if (filter.hasName &&
          !nameLower.contains(filter.nameQuery.trim().toLowerCase())) {
        continue;
      }

      double youGotSum = 0;
      double youGaveSum = 0;
      for (final e in entries) {
        if (e.youGotAmount != null) youGotSum += e.youGotAmount!;
        if (e.youGaveAmount != null) youGaveSum += e.youGaveAmount!;
      }

      summaries.add(
        AmountBookCustomerSummary(
          customerName: name,
          entries: entries,
          lastBalance: lastEntryBalance(entries),
          youGotTotal: youGotSum > 0 ? youGotSum : null,
          youGaveTotal: youGaveSum > 0 ? youGaveSum : null,
        ),
      );
    }

    final noneEntries = entriesForCustomer(
      customerName: noneCustomerLabel,
      youGotRows: youGotRows,
      youGaveRows: youGaveRows,
      filter: filter,
    );
    if (noneEntries.isNotEmpty) {
      final noneLower = noneCustomerLabel.toLowerCase();
      if (!filter.hasName ||
          noneLower.contains(filter.nameQuery.trim().toLowerCase())) {
        double youGotSum = 0;
        double youGaveSum = 0;
        for (final e in noneEntries) {
          if (e.youGotAmount != null) youGotSum += e.youGotAmount!;
          if (e.youGaveAmount != null) youGaveSum += e.youGaveAmount!;
        }
        summaries.add(
          AmountBookCustomerSummary(
            customerName: noneCustomerLabel,
            entries: noneEntries,
            lastBalance: lastEntryBalance(noneEntries),
            youGotTotal: youGotSum > 0 ? youGotSum : null,
            youGaveTotal: youGaveSum > 0 ? youGaveSum : null,
          ),
        );
      }
    }

    summaries.sort(
      (a, b) => a.customerName.toLowerCase().compareTo(
            b.customerName.toLowerCase(),
          ),
    );
    return summaries;
  }
}
