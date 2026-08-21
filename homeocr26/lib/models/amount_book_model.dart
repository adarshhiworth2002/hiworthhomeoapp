import '../features/services/calendar_date.dart';
import '../features/services/invoice_series_classifier.dart';
import 'invoice_summary_model.dart';
import 'net_amount_model.dart';
import 'payment_book_model.dart';

/// One invoice row on the Cash Book tap-through table.
class AmountBookInvoiceLine {
  const AmountBookInvoiceLine({
    required this.number,
    required this.isYouGave,
    this.invoiceId,
    this.sortDate,
    this.total,
    this.balance,
    this.youGotAmount,
    this.youGaveAmount,
    this.status = '',
    this.responsiblePerson,
    this.paymentMode,
    this.advanceAmount,
    this.oldBalance,
  });

  final String number;
  final bool isYouGave;
  final int? invoiceId;
  final DateTime? sortDate;
  final double? total;
  final double? balance;
  final double? youGotAmount;
  final double? youGaveAmount;
  final String status;
  final String? responsiblePerson;
  final String? paymentMode;
  final double? advanceAmount;
  final double? oldBalance;
}

/// One ledger line for a customer detail screen (Khatabook-style).
class AmountBookLedgerEntry {
  const AmountBookLedgerEntry({
    required this.row,
    required this.isYouGave,
    this.sortDate,
    this.youGotAmount,
    this.youGaveAmount,
    this.balance,
    this.invoices = const [],
  });

  final NetAmountRow row;
  final bool isYouGave;
  final DateTime? sortDate;
  final double? youGotAmount;
  final double? youGaveAmount;
  final double? balance;
  final List<AmountBookInvoiceLine> invoices;

  String get displayNumber => row.displayNumber;

  String get displayDate =>
      AmountBookLedgerBuilder.formatDisplayDate(sortDate);

  String get displayPaymentMode =>
      AmountBookLedgerBuilder.formatPaymentMode(row.paymentMode);
}

/// Merged customer row on the Cash Book list.
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

class AmountBookCustomerFooter {
  const AmountBookCustomerFooter({
    this.advance = 0,
    this.oldBalance = 0,
    this.balance = 0,
  });

  final double advance;
  final double oldBalance;
  final double balance;
}

/// Date-range + name filter for Cash Book.
class AmountBookFilter {
  const AmountBookFilter({
    this.nameQuery = '',
    this.dateFrom,
    this.dateTo,
    this.customerType = PaymentBookCustomerType.all,
    this.paymentMode = PaymentBookPaymentMode.all,
  });

  final String nameQuery;
  final DateTime? dateFrom;
  final DateTime? dateTo;
  final PaymentBookCustomerType customerType;
  final PaymentBookPaymentMode paymentMode;

  bool get hasDateRange => dateFrom != null || dateTo != null;
  bool get hasName => nameQuery.trim().isNotEmpty;
  bool get hasCustomerType => customerType != PaymentBookCustomerType.all;
  bool get hasPaymentMode => paymentMode != PaymentBookPaymentMode.all;
  bool get isActive =>
      hasDateRange || hasName || hasCustomerType || hasPaymentMode;

  String get customerTypeLabel =>
      PaymentBookFilter(customerType: customerType).customerTypeLabel;

  String get paymentModeLabel =>
      PaymentBookFilter(paymentMode: paymentMode).paymentModeLabel;

  String? get paymentModeApiValue =>
      PaymentBookFilter(paymentMode: paymentMode).paymentModeApiValue;

  AmountBookFilter copyWith({
    String? nameQuery,
    DateTime? dateFrom,
    DateTime? dateTo,
    PaymentBookCustomerType? customerType,
    PaymentBookPaymentMode? paymentMode,
    bool clearDates = false,
  }) {
    return AmountBookFilter(
      nameQuery: nameQuery ?? this.nameQuery,
      dateFrom: clearDates ? null : dateFrom ?? this.dateFrom,
      dateTo: clearDates ? null : dateTo ?? this.dateTo,
      customerType: customerType ?? this.customerType,
      paymentMode: paymentMode ?? this.paymentMode,
    );
  }
}

class _LedgerEvent {
  const _LedgerEvent({
    required this.row,
    required this.isSale,
    required this.amount,
    required this.billTotal,
    required this.invoiceBalance,
    this.date,
    this.sequence = 0,
  });

  final NetAmountRow row;
  final bool isSale;
  final double amount;
  final double billTotal;
  final double invoiceBalance;
  final DateTime? date;
  final int sequence;
}

/// Build ledger entries and customer summaries from customer invoice rows.
class AmountBookLedgerBuilder {
  const AmountBookLedgerBuilder._();

  /// Folder for nameless / walk-in customers.
  static const String noneCustomerLabel = 'None';

  static bool isNoneCustomerLabel(String customerName) {
    return customerName.trim().toLowerCase() == noneCustomerLabel.toLowerCase();
  }

  static bool isWalkInOrNamelessName(String? name) {
    final raw = (name ?? '').trim();
    if (raw.isEmpty) return true;
    if (InvoiceSummaryModel.isPlaceholderCustomerName(raw)) return true;
    final lower = raw.toLowerCase();
    return lower == 'none' ||
        lower == 'walk-in' ||
        lower == 'walk in' ||
        lower == 'walk-in customer' ||
        lower == 'walk in customer' ||
        lower.startsWith('walk-in') ||
        lower.startsWith('walk in');
  }

  static bool isNamelessCustomerRow(NetAmountRow row) {
    return isWalkInOrNamelessName(row.customer);
  }

  static bool _rowMatchesCustomer(NetAmountRow row, String target) {
    if (isNoneCustomerLabel(target)) return isNamelessCustomerRow(row);
    if (isNamelessCustomerRow(row)) return false;
    return (row.customer ?? '').trim().toLowerCase() == target;
  }

  static bool customerNameMatchesQuery(String customerName, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    if (customerName.toLowerCase().contains(q)) return true;
    if (isNoneCustomerLabel(customerName)) {
      const aliases = 'walk-in customer walk in customer none';
      return aliases.contains(q);
    }
    return false;
  }

  static DateTime? parseRowDate(NetAmountRow row) {
    return CalendarDate.parse(row.invoiceDate);
  }

  static String formatDisplayDate(DateTime? date) {
    if (date == null) return '—';
    return CalendarDate.dmy(date);
  }

  static String formatPaymentMode(String? raw) {
    final t = (raw ?? '').trim();
    if (t.isEmpty) return '—';
    return t
        .split(RegExp(r'[\s_]+'))
        .where((p) => p.isNotEmpty)
        .map((p) => p[0].toUpperCase() + p.substring(1).toLowerCase())
        .join(' ');
  }

  static String dayKey(DateTime? date) {
    if (date == null) return 'unknown';
    return '${date.year}-${date.month}-${date.day}';
  }

  static bool rowMatchesPaymentMode(
    NetAmountRow row,
    PaymentBookPaymentMode mode,
  ) {
    if (mode == PaymentBookPaymentMode.all) return true;
    final expected = PaymentBookFilter(paymentMode: mode).paymentModeApiValue;
    if (expected == null) return true;
    final raw = (row.paymentMode ?? '').toLowerCase().trim();
    return raw == expected || raw.contains(expected);
  }

  static bool rowMatchesCustomerType(
    NetAmountRow row,
    PaymentBookCustomerType type,
  ) {
    switch (type) {
      case PaymentBookCustomerType.all:
        return true;
      case PaymentBookCustomerType.credit:
        return row.isCreditCustomer;
      case PaymentBookCustomerType.normal:
        return !row.isCreditCustomer;
      case PaymentBookCustomerType.b2b:
        return InvoiceSeriesClassifier.isB2bRow(row);
      case PaymentBookCustomerType.b2c:
        return InvoiceSeriesClassifier.isB2cRow(row);
    }
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

  /// Amount received against an invoice (YOU GOT).
  static double paidAmount(NetAmountRow row) {
    final total = row.total ?? 0;
    final balance = row.balance;
    if (row.isPaid || row.invoicePaidFlag) {
      final remaining = balance ?? 0;
      if (remaining <= 0.0001) return total;
      final paid = total - remaining;
      return paid > 0 ? paid : 0;
    }
    if (balance != null) {
      final paid = total - balance;
      return paid > 0.0001 ? paid : 0;
    }
    return 0;
  }

  static List<NetAmountRow> _matchingInvoiceRows({
    required String customerName,
    required List<NetAmountRow> invoiceRows,
    AmountBookFilter? filter,
  }) {
    final target = customerName.trim().toLowerCase();
    final matched = <NetAmountRow>[];

    for (final row in invoiceRows) {
      if (!_rowMatchesCustomer(row, target)) continue;
      if (filter != null) {
        if (!rowInDateRange(row, filter.dateFrom, filter.dateTo)) continue;
        if (!rowMatchesPaymentMode(row, filter.paymentMode)) continue;
        if (!rowMatchesCustomerType(row, filter.customerType)) continue;
      }
      matched.add(row);
    }
    return matched;
  }

  static String _invoiceKey(NetAmountRow row) {
    if (row.id != null) return 'id:${row.id}';
    return 'no:${row.displayNumber}';
  }

  static int _compareSnapshots(NetAmountRow a, NetAmountRow b) {
    final da = parseRowDate(a) ?? DateTime(1970);
    final db = parseRowDate(b) ?? DateTime(1970);
    final cmp = da.compareTo(db);
    if (cmp != 0) return cmp;
    // Same calendar day: later invoice id = later activity (website order).
    final idCmp = (a.id ?? 0).compareTo(b.id ?? 0);
    if (idCmp != 0) return idCmp;
    return (a.total ?? 0).compareTo(b.total ?? 0);
  }

  static List<_LedgerEvent> _eventsFromInvoiceSnapshots(
    List<NetAmountRow> snapshots,
  ) {
    final sorted = [...snapshots]..sort(_compareSnapshots);
    final events = <_LedgerEvent>[];
    var prevTotal = 0.0;
    var prevPaid = 0.0;
    var sequence = 0;

    for (final row in sorted) {
      final date = parseRowDate(row);
      final total = row.total ?? 0;
      final paid = paidAmount(row);

      final sameSnapshot = (total - prevTotal).abs() < 0.0001 &&
          (paid - prevPaid).abs() < 0.0001;
      if (sameSnapshot && events.isNotEmpty) continue;

      final saleDelta = total - prevTotal;
      if (saleDelta > 0.0001) {
        sequence += 1;
        events.add(
          _LedgerEvent(
            row: row,
            isSale: true,
            amount: saleDelta,
            billTotal: total,
            invoiceBalance: total - prevPaid,
            date: date,
            sequence: sequence,
          ),
        );
      }
      if (total > prevTotal) prevTotal = total;

      final payDelta = paid - prevPaid;
      if (payDelta > 0.0001) {
        sequence += 1;
        events.add(
          _LedgerEvent(
            row: row,
            isSale: false,
            amount: payDelta,
            billTotal: prevTotal,
            invoiceBalance: prevTotal - paid,
            date: date,
            sequence: sequence,
          ),
        );
      }
      if (paid > prevPaid) prevPaid = paid;
    }
    return events;
  }

  static AmountBookInvoiceLine _lineForEvent(_LedgerEvent event) {
    return AmountBookInvoiceLine(
      number: event.row.displayNumber,
      isYouGave: event.isSale,
      invoiceId: event.row.id,
      sortDate: event.date,
      total: event.billTotal,
      balance: event.invoiceBalance,
      youGaveAmount: event.isSale ? event.amount : null,
      youGotAmount: event.isSale ? null : event.amount,
      status: event.row.toInvoiceSummary().displayStatus,
      responsiblePerson: event.row.billedBy,
      paymentMode: event.row.paymentMode,
      advanceAmount: event.row.advanceAmount,
      oldBalance: event.row.oldBalance,
    );
  }

  static List<AmountBookLedgerEntry> entriesForCustomer({
    required String customerName,
    required List<NetAmountRow> youGotRows,
    List<NetAmountRow> youGaveRows = const [],
    AmountBookFilter? filter,
  }) {
    // Customer Cash Book uses customer invoices only (youGotRows / section all).
    // youGaveRows are supplier bills and are ignored here.
    final matched = _matchingInvoiceRows(
      customerName: customerName,
      invoiceRows: youGotRows,
      filter: filter,
    );

    final byInvoice = <String, List<NetAmountRow>>{};
    for (final row in matched) {
      byInvoice.putIfAbsent(_invoiceKey(row), () => []).add(row);
    }

    final events = <_LedgerEvent>[];
    for (final snapshots in byInvoice.values) {
      events.addAll(_eventsFromInvoiceSnapshots(snapshots));
    }

    events.sort((a, b) {
      final da = a.date ?? DateTime(1970);
      final db = b.date ?? DateTime(1970);
      final cmp = da.compareTo(db);
      if (cmp != 0) return cmp;
      // Time order by invoice id (not YOU GAVE / YOU GOT grouping).
      final idCmp = (a.row.id ?? 0).compareTo(b.row.id ?? 0);
      if (idCmp != 0) return idCmp;
      return a.sequence.compareTo(b.sequence);
    });

    var running = 0.0;
    final chronological = <AmountBookLedgerEntry>[];
    for (final event in events) {
      if (event.isSale) {
        running += event.amount;
      } else {
        running -= event.amount;
      }
      chronological.add(
        AmountBookLedgerEntry(
          row: event.row,
          isYouGave: event.isSale,
          sortDate: event.date,
          youGaveAmount: event.isSale ? event.amount : null,
          youGotAmount: event.isSale ? null : event.amount,
          balance: running,
          invoices: [
            _lineForEvent(event),
          ],
        ),
      );
    }

    return chronological.reversed.toList(growable: false);
  }

  static AmountBookCustomerFooter footerForCustomer({
    required String customerName,
    required List<NetAmountRow> invoiceRows,
    AmountBookFilter filter = const AmountBookFilter(),
  }) {
    final allEntries = entriesForCustomer(
      customerName: customerName,
      youGotRows: invoiceRows,
    );
    if (allEntries.isEmpty) {
      return const AmountBookCustomerFooter();
    }

    final chronological = allEntries.reversed.toList(growable: false);
    var running = 0.0;
    final from = filter.dateFrom;

    for (final entry in chronological) {
      running = entry.balance ?? running;
      final day = entry.sortDate;
      if (filter.dateTo != null && day != null) {
        final end = DateTime(
          filter.dateTo!.year,
          filter.dateTo!.month,
          filter.dateTo!.day,
        );
        final d = DateTime(day.year, day.month, day.day);
        if (d.isAfter(end)) break;
      }
    }

    // Advance / old balance come from customer invoice API fields (newest
    // invoice for this customer), not from local ledger math.
    final customerRows = _matchingInvoiceRows(
      customerName: customerName,
      invoiceRows: invoiceRows,
    )..sort((a, b) => -_compareSnapshots(a, b));

    double apiAdvance = 0;
    double apiOld = 0;
    var foundAdvance = false;
    var foundOld = false;
    // Prefer non-zero customer_advance_amount / customer_old_balance from the
    // newest matching rows; bare 0 often means "unset" on list payloads.
    for (final row in customerRows) {
      final adv = row.advanceAmount;
      if (adv != null && (!foundAdvance || (apiAdvance == 0 && adv != 0))) {
        apiAdvance = adv;
        foundAdvance = true;
      }
      final old = row.oldBalance;
      if (old != null && (!foundOld || (apiOld == 0 && old != 0))) {
        apiOld = old;
        foundOld = true;
      }
      if (foundAdvance &&
          foundOld &&
          (apiAdvance != 0 || apiOld != 0)) {
        break;
      }
    }

    // When a date filter is active and API has no old_balance, fall back to
    // opening balance before the range.
    if (!foundOld && from != null) {
      var opening = 0.0;
      for (final entry in chronological) {
        final day = entry.sortDate;
        if (day == null) continue;
        final d = DateTime(day.year, day.month, day.day);
        final start = DateTime(from.year, from.month, from.day);
        if (d.isBefore(start)) {
          opening = entry.balance ?? opening;
        }
      }
      apiOld = opening;
    }

    final current = chronological.last.balance ?? running;
    final balance = current > 0 ? current : 0.0;

    return AmountBookCustomerFooter(
      advance: apiAdvance,
      oldBalance: apiOld,
      balance: balance,
    );
  }

  /// Current outstanding — newest ledger line after reverse sort.
  static double? lastEntryBalance(List<AmountBookLedgerEntry> entries) {
    if (entries.isEmpty) return null;
    return entries.first.balance;
  }

  static AmountBookCustomerSummary _summaryFor({
    required String customerName,
    required List<AmountBookLedgerEntry> entries,
  }) {
    double youGotSum = 0;
    double youGaveSum = 0;
    for (final e in entries) {
      if (e.youGotAmount != null) youGotSum += e.youGotAmount!;
      if (e.youGaveAmount != null) youGaveSum += e.youGaveAmount!;
    }
    return AmountBookCustomerSummary(
      customerName: customerName,
      entries: entries,
      lastBalance: lastEntryBalance(entries),
      youGotTotal: youGotSum > 0 ? youGotSum : null,
      youGaveTotal: youGaveSum > 0 ? youGaveSum : null,
    );
  }

  static List<AmountBookCustomerSummary> buildCustomerSummaries({
    required List<NetAmountRow> youGotRows,
    List<NetAmountRow> youGaveRows = const [],
    AmountBookFilter filter = const AmountBookFilter(),
  }) {
    final names = <String>{};
    for (final row in youGotRows) {
      final name = (row.customer ?? '').trim();
      if (name.isEmpty) continue;
      if (isWalkInOrNamelessName(name)) continue;
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
      if (filter.hasName &&
          !customerNameMatchesQuery(name, filter.nameQuery)) {
        continue;
      }
      summaries.add(
        _summaryFor(customerName: name, entries: entries),
      );
    }

    final noneEntries = entriesForCustomer(
      customerName: noneCustomerLabel,
      youGotRows: youGotRows,
      youGaveRows: youGaveRows,
      filter: filter,
    );
    if (noneEntries.isNotEmpty) {
      if (!filter.hasName ||
          customerNameMatchesQuery(noneCustomerLabel, filter.nameQuery)) {
        summaries.add(
          _summaryFor(
            customerName: noneCustomerLabel,
            entries: noneEntries,
          ),
        );
      }
    }

    summaries.sort((a, b) {
      final da = a.entries.isEmpty
          ? DateTime(1970)
          : (a.entries.first.sortDate ?? DateTime(1970));
      final db = b.entries.isEmpty
          ? DateTime(1970)
          : (b.entries.first.sortDate ?? DateTime(1970));
      final byDate = db.compareTo(da);
      if (byDate != 0) return byDate;
      final aId = a.entries.isEmpty ? 0 : (a.entries.first.row.id ?? 0);
      final bId = b.entries.isEmpty ? 0 : (b.entries.first.row.id ?? 0);
      final byId = bId.compareTo(aId);
      if (byId != 0) return byId;
      return a.customerName.toLowerCase().compareTo(b.customerName.toLowerCase());
    });
    return summaries;
  }
}
