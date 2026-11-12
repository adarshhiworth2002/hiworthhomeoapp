import '../features/services/calendar_date.dart';
import '../features/services/invoice_series_classifier.dart';
import 'customer_payment_model.dart';
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
    this.paymentId,
    this.paymentName,
    this.entryPaymentMode,
  });

  final NetAmountRow row;
  final bool isYouGave;
  final DateTime? sortDate;
  final double? youGotAmount;
  final double? youGaveAmount;
  final double? balance;
  final List<AmountBookInvoiceLine> invoices;
  final int? paymentId;
  final String? paymentName;
  final String? entryPaymentMode;

  String get displayNumber =>
      (paymentName ?? '').trim().isNotEmpty
          ? paymentName!.trim()
          : row.displayNumber;

  String get displayDate =>
      AmountBookLedgerBuilder.formatDisplayDate(sortDate);

  String get displayTime => CalendarDate.formatTime(sortDate);

  String get displayPaymentMode =>
      AmountBookLedgerBuilder.formatPaymentMode(
        entryPaymentMode ?? row.paymentMode,
      );

  String get ledgerKey {
    if (paymentId != null) return 'pay:$paymentId';
    final stamp = sortDate?.millisecondsSinceEpoch ?? 0;
    final amount = isYouGave ? (youGaveAmount ?? 0) : (youGotAmount ?? 0);
    return '${isYouGave ? 'gave' : 'got'}:${row.id ?? displayNumber}:$stamp:$amount';
  }
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

/// A single recorded payment against an invoice: an amount and the
/// real-world moment it should be sorted/displayed under.
class PaymentLogEntry {
  const PaymentLogEntry({required this.amount, required this.time});

  final double amount;
  final DateTime time;
}

/// Resolves the list of individual payment entries that make up an
/// invoice's current total paid amount.
///
/// The backend only ever reports one cumulative "paid so far" number per
/// invoice — it never breaks that down into the separate payments that
/// were recorded against it. So when the caller detects the paid amount
/// has increased since it last looked, it should log *that increase* as
/// its own dated entry (e.g. "just now") rather than folding it into
/// whatever was already paid. This resolver returns the full list of
/// entries built up that way; entries should sum to [totalPaid].
/// [fallbackDate] (the invoice's own date) is used for any portion of the
/// paid amount that predates tracking (e.g. the first time an invoice is
/// seen with money already on it) or when no resolver is supplied at all.
typedef PaymentEventsResolver = List<PaymentLogEntry> Function(
    int? invoiceId,
    double totalPaid,
    DateTime fallbackDate,
    );

class _LedgerEvent {
  const _LedgerEvent({
    required this.row,
    required this.isSale,
    required this.amount,
    required this.billTotal,
    required this.invoiceBalance,
    this.date,
    this.sequence = 0,
    this.paymentId,
    this.paymentName,
    this.paymentMode,
    this.lines = const [],
  });

  final NetAmountRow row;
  final bool isSale;
  final double amount;
  final double billTotal;
  final double invoiceBalance;
  final DateTime? date;
  final int sequence;
  final int? paymentId;
  final String? paymentName;
  final String? paymentMode;
  final List<AmountBookInvoiceLine> lines;
}

/// Build ledger entries and customer summaries from customer invoice rows.
class AmountBookLedgerBuilder {
  const AmountBookLedgerBuilder._();

  /// Folder for nameless / walk-in customers (aligned with invoice lists).
  static const String noneCustomerLabel =
      InvoiceSummaryModel.walkinCustomerLabel;

  static bool isNoneCustomerLabel(String customerName) {
    return customerName.trim().toLowerCase() == noneCustomerLabel.toLowerCase();
  }

  static bool isWalkInOrNamelessName(String? name) {
    final raw = (name ?? '').trim();
    if (raw.isEmpty) return true;
    final lower = raw.toLowerCase();
    if (lower == noneCustomerLabel.toLowerCase() || lower == 'none') {
      return true;
    }
    return InvoiceSummaryModel.isWalkInCustomerName(raw);
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
      const aliases = 'walkin customer walk-in customer walk in customer none';
      return aliases.contains(q);
    }
    return false;
  }

  static DateTime? parseRowDate(NetAmountRow row) {
    return CalendarDate.parse(row.invoiceDate);
  }

  /// Bill date plus clock time from `create_date` when the API has it.
  static DateTime? parseRowDateTime(NetAmountRow row) {
    final created = CalendarDate.parseDateTime(row.createdAt);
    if (created != null && CalendarDate.hasClockTime(created)) {
      return created;
    }
    return CalendarDate.parseDateTime(row.invoiceDate) ?? parseRowDate(row);
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
      List<NetAmountRow> snapshots, [
        PaymentEventsResolver? paymentEventsFor,
        PaymentEventsResolver? saleEventsFor,
        bool includeSales = true,
        bool includePayments = true,
      ]) {
    final sorted = [...snapshots]..sort(_compareSnapshots);
    final events = <_LedgerEvent>[];
    var prevTotal = 0.0;
    var prevPaid = 0.0;
    var sequence = 0;

    for (final row in sorted) {
      final date = parseRowDateTime(row) ?? DateTime.now();
      final total = row.total ?? 0;
      final paid = paidAmount(row);

      final sameSnapshot = (total - prevTotal).abs() < 0.0001 &&
          (paid - prevPaid).abs() < 0.0001;
      if (sameSnapshot && events.isNotEmpty) continue;

      final saleDelta = total - prevTotal;
      if (includeSales && saleDelta > 0.0001) {
        final entries = saleEventsFor?.call(row.id, total, date) ??
            [PaymentLogEntry(amount: saleDelta, time: date)];
        var runningTotal = prevTotal;
        for (final entry in entries) {
          if (entry.amount <= 0.0001) continue;
          sequence += 1;
          runningTotal += entry.amount;
          events.add(
            _LedgerEvent(
              row: row,
              isSale: true,
              amount: entry.amount,
              billTotal: runningTotal,
              invoiceBalance: runningTotal - prevPaid,
              date: entry.time,
              sequence: sequence,
            ),
          );
        }
      }
      if (total > prevTotal) prevTotal = total;

      final payDelta = paid - prevPaid;
      if (includePayments && payDelta > 0.0001) {
        final entries = paymentEventsFor?.call(row.id, paid, date) ??
            [PaymentLogEntry(amount: payDelta, time: date)];
        var runningPaid = prevPaid;
        for (final entry in entries) {
          if (entry.amount <= 0.0001) continue;
          sequence += 1;
          runningPaid += entry.amount;
          events.add(
            _LedgerEvent(
              row: row,
              isSale: false,
              amount: entry.amount,
              billTotal: prevTotal,
              invoiceBalance: prevTotal - runningPaid,
              date: entry.time,
              sequence: sequence,
            ),
          );
        }
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
      paymentMode: event.paymentMode ?? event.row.paymentMode,
      advanceAmount: event.row.advanceAmount,
      oldBalance: event.row.oldBalance,
    );
  }

  static bool _paymentMatchesCustomer(
    CustomerPaymentRecord payment,
    String target,
  ) {
    if (isNoneCustomerLabel(target)) {
      return isWalkInOrNamelessName(payment.customerName);
    }
    if (isWalkInOrNamelessName(payment.customerName)) return false;
    return payment.customerName.trim().toLowerCase() ==
        target.trim().toLowerCase();
  }

  static bool _paymentInFilter(
    CustomerPaymentRecord payment,
    AmountBookFilter? filter,
  ) {
    if (filter == null) return true;
    final date = payment.dateTime;
    if (filter.dateFrom != null || filter.dateTo != null) {
      if (date == null) return false;
      final day = DateTime(date.year, date.month, date.day);
      if (filter.dateFrom != null) {
        final start = DateTime(
          filter.dateFrom!.year,
          filter.dateFrom!.month,
          filter.dateFrom!.day,
        );
        if (day.isBefore(start)) return false;
      }
      if (filter.dateTo != null) {
        final end = DateTime(
          filter.dateTo!.year,
          filter.dateTo!.month,
          filter.dateTo!.day,
        );
        if (day.isAfter(end)) return false;
      }
    }
    if (filter.paymentMode != PaymentBookPaymentMode.all) {
      final expected =
          PaymentBookFilter(paymentMode: filter.paymentMode).paymentModeApiValue;
      if (expected != null) {
        final raw = (payment.paymentMode ?? '').toLowerCase().trim();
        if (raw != expected && !raw.contains(expected)) return false;
      }
    }
    return true;
  }

  static String _allocationKey(CustomerPaymentInvoice invoice) {
    if (invoice.invoiceId != null) return 'id:${invoice.invoiceId}';
    return 'no:${invoice.number.trim().toLowerCase()}';
  }

  static NetAmountRow _rowForInvoice(
    CustomerPaymentInvoice invoice,
    List<NetAmountRow> matched,
    CustomerPaymentRecord payment,
  ) {
    if (invoice.invoiceId != null) {
      for (final row in matched) {
        if (row.id == invoice.invoiceId) return row;
      }
    }
    final want = invoice.number.trim().toLowerCase();
    if (want.isNotEmpty) {
      for (final row in matched) {
        if (row.displayNumber.trim().toLowerCase() == want) return row;
      }
    }
    return NetAmountRow(
      id: invoice.invoiceId,
      customer: payment.customerName,
      invoiceNumber: invoice.number,
      invoiceDate: invoice.invoiceDate,
      billedBy: invoice.responsiblePerson,
      total: invoice.total,
      balance: invoice.balance,
      paymentMode: invoice.paymentMode ?? payment.paymentMode,
      status: invoice.status,
    );
  }

  static List<AmountBookInvoiceLine> _linesForPayment(
    CustomerPaymentRecord payment,
    List<NetAmountRow> matched,
  ) {
    if (payment.invoices.isEmpty) return const [];
    final lines = <AmountBookInvoiceLine>[];
    for (final inv in payment.invoices) {
      final allocated = inv.allocatedAmount > 0
          ? inv.allocatedAmount
          : (payment.invoices.length == 1 ? payment.amount : 0.0);
      final row = _rowForInvoice(inv, matched, payment);
      final number = inv.number.trim().isNotEmpty
          ? inv.number.trim()
          : row.displayNumber;
      // Skip empty placeholder rows (no bill number and no pay).
      if ((number.isEmpty || number == '—') && allocated <= 0.0001) {
        continue;
      }
      final invoiceDate = CalendarDate.parseDateTime(inv.invoiceDate) ??
          parseRowDateTime(row) ??
          payment.dateTime;
      lines.add(
        AmountBookInvoiceLine(
          number: number,
          isYouGave: false,
          invoiceId: inv.invoiceId ?? row.id,
          sortDate: invoiceDate,
          total: inv.total ?? row.total,
          balance: inv.balance ?? row.balance,
          youGotAmount: allocated,
          status: inv.status.isNotEmpty
              ? inv.status
              : row.toInvoiceSummary().displayStatus,
          responsiblePerson: inv.responsiblePerson ?? row.billedBy,
          paymentMode:
              inv.paymentMode ?? payment.paymentMode ?? row.paymentMode,
          advanceAmount: row.advanceAmount,
          oldBalance: row.oldBalance,
        ),
      );
    }
    return lines;
  }

  static List<_LedgerEvent> _paymentEventsFromApi({
    required String customerName,
    required List<CustomerPaymentRecord> payments,
    required List<NetAmountRow> matched,
    AmountBookFilter? filter,
  }) {
    final events = <_LedgerEvent>[];
    var sequence = 0;
    for (final payment in payments) {
      if (!_paymentMatchesCustomer(payment, customerName)) continue;
      if (!_paymentInFilter(payment, filter)) continue;
      if (payment.amount <= 0.0001) continue;
      sequence += 1;
      final lines = _linesForPayment(payment, matched);
      final row = lines.isNotEmpty
          ? _rowForInvoice(
              payment.invoices.first,
              matched,
              payment,
            )
          : NetAmountRow(
              customer: payment.customerName,
              invoiceNumber: payment.name,
              paymentMode: payment.paymentMode,
              total: payment.amount,
            );
      events.add(
        _LedgerEvent(
          row: row,
          isSale: false,
          amount: payment.amount,
          billTotal: payment.amount,
          invoiceBalance: row.balance ?? 0.0,
          date: payment.dateTime,
          sequence: sequence,
          paymentId: payment.id,
          paymentName: payment.name,
          paymentMode: payment.paymentMode,
          lines: lines,
        ),
      );
    }
    return events;
  }

  static List<_LedgerEvent> _groupTimedPayEvents(List<_LedgerEvent> events) {
    if (events.length < 2) return events;
    final ungrouped = <_LedgerEvent>[];
    final live = <_LedgerEvent>[];
    final now = DateTime.now();
    for (final event in events) {
      final date = event.date;
      final isLive = date != null &&
          CalendarDate.hasClockTime(date) &&
          now.difference(date).abs() <= const Duration(minutes: 2);
      if (isLive) {
        live.add(event);
      } else {
        ungrouped.add(event);
      }
    }
    if (live.length < 2) return events;

    live.sort((a, b) {
      final cmp = (a.date ?? DateTime(1970)).compareTo(b.date ?? DateTime(1970));
      if (cmp != 0) return cmp;
      return a.sequence.compareTo(b.sequence);
    });

    final grouped = <_LedgerEvent>[];
    var cluster = <_LedgerEvent>[live.first];
    for (var i = 1; i < live.length; i++) {
      final prev = cluster.last.date!;
      final next = live[i].date!;
      if (next.difference(prev).abs() <= const Duration(seconds: 2)) {
        cluster.add(live[i]);
      } else {
        grouped.add(_mergePayCluster(cluster));
        cluster = [live[i]];
      }
    }
    grouped.add(_mergePayCluster(cluster));
    return [...ungrouped, ...grouped];
  }

  static _LedgerEvent _mergePayCluster(List<_LedgerEvent> cluster) {
    if (cluster.length == 1) return cluster.first;
    var amount = 0.0;
    final lines = <AmountBookInvoiceLine>[];
    DateTime? latest = cluster.first.date;
    for (final event in cluster) {
      amount += event.amount;
      lines.addAll(
        event.lines.isNotEmpty ? event.lines : [_lineForEvent(event)],
      );
      if (event.date != null &&
          (latest == null || event.date!.isAfter(latest))) {
        latest = event.date;
      }
    }
    return _LedgerEvent(
      row: cluster.first.row,
      isSale: false,
      amount: amount,
      billTotal: amount,
      invoiceBalance: cluster.last.invoiceBalance,
      date: latest,
      sequence: cluster.last.sequence,
      paymentMode: cluster.first.paymentMode,
      lines: lines,
    );
  }

  static bool _payEventCovered(
    _LedgerEvent event,
    Map<String, double> covered,
  ) {
    final key = _invoiceKey(event.row);
    final remaining = covered[key] ?? 0;
    if (remaining + 0.0001 >= event.amount) {
      covered[key] = remaining - event.amount;
      return true;
    }
    return false;
  }

  static List<AmountBookLedgerEntry> entriesForCustomer({
    required String customerName,
    required List<NetAmountRow> youGotRows,
    List<NetAmountRow> youGaveRows = const [],
    AmountBookFilter? filter,
    PaymentEventsResolver? paymentEventsFor,
    PaymentEventsResolver? saleEventsFor,
    List<CustomerPaymentRecord> payments = const [],
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
      events.addAll(
        _eventsFromInvoiceSnapshots(
          snapshots,
          paymentEventsFor,
          saleEventsFor,
          true,
          false,
        ),
      );
    }

    final apiPayEvents = _paymentEventsFromApi(
      customerName: customerName,
      payments: payments,
      matched: matched,
      filter: filter,
    );
    events.addAll(apiPayEvents);

    final covered = <String, double>{};
    var customerHasApiPayments = false;
    for (final payment in payments) {
      if (!_paymentMatchesCustomer(payment, customerName)) continue;
      if (!_paymentInFilter(payment, filter)) continue;
      customerHasApiPayments = true;
      for (final inv in payment.invoices) {
        final key = _allocationKey(inv);
        final amt = inv.allocatedAmount > 0
            ? inv.allocatedAmount
            : (payment.invoices.length == 1 ? payment.amount : 0.0);
        covered[key] = (covered[key] ?? 0) + amt;
      }
      // Also cover by payment total when lines are missing — suppress
      // fragmented invoice-paid leftovers for this customer.
      if (payment.invoices.isEmpty && payment.amount > 0) {
        covered['__unallocated__'] =
            (covered['__unallocated__'] ?? 0) + payment.amount;
      }
    }

    final leftoverPay = <_LedgerEvent>[];
    // When website payments are loaded for this customer, YOU GOT comes only
    // from partner.payment (one row per payment with nested bills). Do not
    // invent fragmented per-invoice "paid delta" rows that break the 500rs
    // grouping and throw the running balance off.
    if (!customerHasApiPayments) {
      for (final snapshots in byInvoice.values) {
        leftoverPay.addAll(
          _eventsFromInvoiceSnapshots(
            snapshots,
            paymentEventsFor,
            saleEventsFor,
            false,
            true,
          ),
        );
      }
      leftoverPay.removeWhere((event) => _payEventCovered(event, covered));
      events.addAll(_groupTimedPayEvents(leftoverPay));
    } else {
      // Still allow brand-new live payments not yet in partner.payment.
      for (final snapshots in byInvoice.values) {
        leftoverPay.addAll(
          _eventsFromInvoiceSnapshots(
            snapshots,
            paymentEventsFor,
            saleEventsFor,
            false,
            true,
          ),
        );
      }
      leftoverPay.removeWhere((event) => _payEventCovered(event, covered));
      leftoverPay.removeWhere((event) {
        final date = event.date;
        if (date == null || !CalendarDate.hasClockTime(date)) return true;
        return DateTime.now().difference(date).abs() >
            const Duration(minutes: 2);
      });
      var unallocatedApi = covered['__unallocated__'] ?? 0;
      leftoverPay.sort((a, b) {
        return (a.date ?? DateTime(1970)).compareTo(b.date ?? DateTime(1970));
      });
      leftoverPay.removeWhere((event) {
        if (unallocatedApi <= 0.0001) return false;
        if (event.amount <= unallocatedApi + 0.0001) {
          unallocatedApi -= event.amount;
          return true;
        }
        return false;
      });
      events.addAll(_groupTimedPayEvents(leftoverPay));
    }

    events.sort((a, b) {
      final da = a.date ?? DateTime(1970);
      final db = b.date ?? DateTime(1970);
      final cmp = da.compareTo(db);
      if (cmp != 0) return cmp;
      final payCmp = (a.paymentId ?? 0).compareTo(b.paymentId ?? 0);
      if (payCmp != 0) return payCmp;
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
          invoices: event.lines.isNotEmpty
              ? event.lines
              : [_lineForEvent(event)],
          paymentId: event.paymentId,
          paymentName: event.paymentName,
          entryPaymentMode: event.paymentMode,
        ),
      );
    }

    // Align running Bal. with website residual sum (You will get).
    // Cash-flow running can drift when invoice list residuals lag payments.
    if (chronological.isNotEmpty) {
      final target = outstandingFromInvoices(
        customerName: customerName,
        invoiceRows: youGotRows,
      );
      final delta = target - running;
      if (delta.abs() > 0.0001) {
        for (var i = 0; i < chronological.length; i++) {
          final e = chronological[i];
          chronological[i] = AmountBookLedgerEntry(
            row: e.row,
            isYouGave: e.isYouGave,
            sortDate: e.sortDate,
            youGaveAmount: e.youGaveAmount,
            youGotAmount: e.youGotAmount,
            balance: (e.balance ?? 0) + delta,
            invoices: e.invoices,
            paymentId: e.paymentId,
            paymentName: e.paymentName,
            entryPaymentMode: e.entryPaymentMode,
          );
        }
      }
    }

    return chronological.reversed.toList(growable: false);
  }

  /// Website "Balance Amount" / "You will get" = sum of open invoice residuals.
  static double outstandingFromInvoices({
    required String customerName,
    required List<NetAmountRow> invoiceRows,
  }) {
    final matched = _matchingInvoiceRows(
      customerName: customerName,
      invoiceRows: invoiceRows,
    );
    final seen = <String>{};
    var sum = 0.0;
    for (final row in matched) {
      final key = _invoiceKey(row);
      if (!seen.add(key)) continue;
      final bal = row.balance;
      if (bal != null) {
        if (bal > 0.0001) sum += bal;
        continue;
      }
      // No residual field — unpaid total counts as outstanding.
      if (!row.isPaid && !row.invoicePaidFlag) {
        final total = row.total ?? 0;
        if (total > 0.0001) sum += total;
      }
    }
    return sum;
  }

  static AmountBookCustomerFooter footerForCustomer({
    required String customerName,
    required List<NetAmountRow> invoiceRows,
    AmountBookFilter filter = const AmountBookFilter(),
    PaymentEventsResolver? paymentEventsFor,
    PaymentEventsResolver? saleEventsFor,
    List<CustomerPaymentRecord> payments = const [],
  }) {
    final allEntries = entriesForCustomer(
      customerName: customerName,
      youGotRows: invoiceRows,
      paymentEventsFor: paymentEventsFor,
      saleEventsFor: saleEventsFor,
      payments: payments,
    );

    final from = filter.dateFrom;

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
    if (!foundOld && from != null && allEntries.isNotEmpty) {
      final chronological = allEntries.reversed.toList(growable: false);
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

    // Match website balance (sum of invoice residuals), e.g. 239.20 for Ajith.
    final balance = outstandingFromInvoices(
      customerName: customerName,
      invoiceRows: invoiceRows,
    );

    return AmountBookCustomerFooter(
      advance: apiAdvance,
      oldBalance: apiOld,
      balance: balance,
    );
  }

  /// Current outstanding — prefer website residual sum when available.
  static double? lastEntryBalance(List<AmountBookLedgerEntry> entries) {
    if (entries.isEmpty) return null;
    return entries.first.balance;
  }

  static AmountBookCustomerSummary _summaryFor({
    required String customerName,
    required List<AmountBookLedgerEntry> entries,
    double? outstanding,
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
      lastBalance: outstanding ?? lastEntryBalance(entries),
      youGotTotal: youGotSum > 0 ? youGotSum : null,
      youGaveTotal: youGaveSum > 0 ? youGaveSum : null,
    );
  }

  static List<AmountBookCustomerSummary> buildCustomerSummaries({
    required List<NetAmountRow> youGotRows,
    List<NetAmountRow> youGaveRows = const [],
    AmountBookFilter filter = const AmountBookFilter(),
    PaymentEventsResolver? paymentEventsFor,
    PaymentEventsResolver? saleEventsFor,
    List<CustomerPaymentRecord> payments = const [],
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
        paymentEventsFor: paymentEventsFor,
        saleEventsFor: saleEventsFor,
        payments: payments,
      );
      if (entries.isEmpty) continue;
      if (filter.hasName &&
          !customerNameMatchesQuery(name, filter.nameQuery)) {
        continue;
      }
      summaries.add(
        _summaryFor(
          customerName: name,
          entries: entries,
          outstanding: outstandingFromInvoices(
            customerName: name,
            invoiceRows: youGotRows,
          ),
        ),
      );
    }

    final noneEntries = entriesForCustomer(
      customerName: noneCustomerLabel,
      youGotRows: youGotRows,
      youGaveRows: youGaveRows,
      filter: filter,
      paymentEventsFor: paymentEventsFor,
      saleEventsFor: saleEventsFor,
      payments: payments,
    );
    if (noneEntries.isNotEmpty) {
      if (!filter.hasName ||
          customerNameMatchesQuery(noneCustomerLabel, filter.nameQuery)) {
        summaries.add(
          _summaryFor(
            customerName: noneCustomerLabel,
            entries: noneEntries,
            outstanding: outstandingFromInvoices(
              customerName: noneCustomerLabel,
              invoiceRows: youGotRows,
            ),
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
