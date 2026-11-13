import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../models/invoice_summary_model.dart';
import '../../models/payment_book_model.dart';
import '../services/WebApi/web_api_impl.dart';
import 'api_request_helper.dart';
import 'calendar_date.dart';
import 'endPoints.dart';
import 'invoice_series_classifier.dart';
import 'payment_history_service.dart';

class PaymentBookService {
  const PaymentBookService._();

  static PaymentBookModel? _cache;
  static DateTime? _cachedAt;
  static String? _cacheKey;
  static Future<PaymentBookModel>? _inFlight;
  static const _cacheTtl = Duration(seconds: 8);

  /// `get_payment_book` crashes on string `date_from`/`date_to`
  /// (`'str' object has no attribute 'strftime'`).
  /// Custom date ranges use `get_payment_history` as a fallback.
  static const bool paymentBookAcceptsDateStrings = false;

  static bool get hasFreshCache =>
      _cache != null &&
      _cachedAt != null &&
      DateTime.now().difference(_cachedAt!) < _cacheTtl;

  static PaymentBookModel? get cachedBook => _cache;

  static String _key({
    String? dateFrom,
    String? dateTo,
    String? customer,
    String? customerType,
    String? paymentMode,
  }) =>
      '${dateFrom ?? ''}|${dateTo ?? ''}|${customer ?? ''}|'
      '${customerType ?? ''}|${paymentMode ?? ''}';

  static bool _isTodayOnly(String? dateFrom, String? dateTo) {
    final today = _formatApiDate(PaymentBookFilter.todayDate());
    // No dates = show all (history fallback). Do not treat as "today".
    if (dateFrom == null && dateTo == null) return false;
    return dateFrom == today && (dateTo == null || dateTo == today);
  }

  static Future<PaymentBookModel> fetch({
    required String sessionId,
    String? dateFrom,
    String? dateTo,
    String? customer,
    String? customerType,
    String? paymentMode,
    bool forceRefresh = false,
  }) async {
    final key = _key(
      dateFrom: dateFrom,
      dateTo: dateTo,
      customer: customer,
      customerType: customerType,
      paymentMode: paymentMode,
    );
    if (!forceRefresh && hasFreshCache && _cacheKey == key) {
      return _cache!;
    }

    final pending = _inFlight;
    if (!forceRefresh && pending != null && _cacheKey == key) {
      return pending;
    }

    final future = _fetchFromApi(
      sessionId: sessionId,
      dateFrom: dateFrom,
      dateTo: dateTo,
      customer: customer,
      customerType: customerType,
      paymentMode: paymentMode,
    );
    _inFlight = future;
    _cacheKey = key;
    try {
      return await future;
    } finally {
      if (identical(_inFlight, future)) {
        _inFlight = null;
      }
    }
  }

  static Future<PaymentBookModel> _fetchFromApi({
    required String sessionId,
    String? dateFrom,
    String? dateTo,
    String? customer,
    String? customerType,
    String? paymentMode,
  }) async {
    final useHistoryFallback = !paymentBookAcceptsDateStrings &&
        !_isTodayOnly(dateFrom, dateTo);

    final PaymentBookModel book;
    if (useHistoryFallback) {
      book = await _fetchViaPaymentHistory(
        sessionId: sessionId,
        dateFrom: dateFrom,
        dateTo: dateTo,
      );
    } else {
      book = await _fetchPaymentBookEndpoint(
        sessionId: sessionId,
        customer: customer,
        customerType: customerType,
        paymentMode: paymentMode,
      );
    }

    // Client-side filters (API may ignore customer name; history fallback
    // also needs type/mode filtering). Always re-apply trusted Dis% totals
    // after filters so parallel home refreshes cannot flash MRP amounts.
    final filtered = _applyTrustedTotals(
      _applyLocalFilters(
        book,
        customer: customer,
        customerType: customerType,
        paymentMode: paymentMode,
      ),
    );

    if (kDebugMode) {
      debugPrint(
        'get_payment_book ready ${filtered.invoices.length} invoices '
        'amount=${filtered.totalAmount} viaHistory=$useHistoryFallback '
        'from=${filtered.dateFrom} to=${filtered.dateTo}',
      );
    }

    // After saving a bill, Laravel may return only today's new row while
    // home_count still reflects the full set — never wipe a fuller cache.
    final prior = _cache;
    final priorN = prior?.invoices.length ?? 0;
    final nextN = filtered.invoices.length;
    final homeHint = filtered.homeCount;
    if (prior != null &&
        priorN > 0 &&
        nextN < priorN &&
        (nextN == 0 || (homeHint > 0 && nextN < homeHint))) {
      final merged = _mergeInvoiceLists(prior.invoices, filtered.invoices);
      var bal = 0.0;
      var tot = 0.0;
      for (final inv in merged) {
        bal += inv.balance ?? 0;
        tot += inv.total ?? 0;
      }
      final kept = PaymentBookModel(
        cardName: (filtered.cardName ?? '').isNotEmpty
            ? filtered.cardName
            : prior.cardName,
        dateFrom: filtered.dateFrom ?? prior.dateFrom,
        dateTo: filtered.dateTo ?? prior.dateTo,
        homeCount: homeHint > prior.homeCount ? homeHint : prior.homeCount,
        totalCount: merged.length,
        totalBalance: bal,
        totalAmount: tot,
        invoices: merged,
      );
      _cache = kept;
      _cachedAt = DateTime.now();
      return kept;
    }

    _cache = filtered;
    _cachedAt = DateTime.now();
    return filtered;
  }

  static List<InvoiceSummaryModel> _mergeInvoiceLists(
    List<InvoiceSummaryModel> base,
    List<InvoiceSummaryModel> incoming,
  ) {
    final byId = <int, InvoiceSummaryModel>{};
    for (final inv in incoming) {
      final id = inv.id;
      if (id != null) byId[id] = inv;
    }
    final out = <InvoiceSummaryModel>[];
    final seen = <int>{};
    for (final inv in incoming) {
      final id = inv.id;
      if (id == null) {
        out.add(inv);
        continue;
      }
      if (seen.contains(id)) continue;
      seen.add(id);
      out.add(inv);
    }
    for (final inv in base) {
      final id = inv.id;
      if (id == null) {
        out.add(inv);
        continue;
      }
      if (seen.contains(id)) continue;
      seen.add(id);
      final patch = byId[id];
      out.add(patch == null ? inv : inv.mergedWith(patch));
    }
    return out;
  }

  static Future<PaymentBookModel> _fetchPaymentBookEndpoint({
    required String sessionId,
    String? customer,
    String? customerType,
    String? paymentMode,
  }) async {
    final params = <String, dynamic>{};
    if (customer != null && customer.trim().isNotEmpty) {
      params['customer'] = customer.trim();
      params['customer_name'] = customer.trim();
    }
    if (customerType != null && customerType.isNotEmpty) {
      params['customer_type'] = customerType;
    }
    if (paymentMode != null && paymentMode.isNotEmpty) {
      params['payment_mode'] = paymentMode;
    }

    final webApi = WebApiImpl();
    final response = await webApi.fetchInvoiceList(
      endpointPath: EndPoint.paymentBook.path,
      userDetails: ApiRequestHelper.jsonRpcCall(params),
      sessionId: sessionId,
      logResponseBody: kDebugMode,
    );

    if (response.statusCode != 200) {
      return _cache ?? const PaymentBookModel();
    }

    final body = json.decode(response.body);
    if (body is! Map) return _cache ?? const PaymentBookModel();

    final map = Map<String, dynamic>.from(body);
    final result = map['result'];
    if (result is Map && result['status'] == 'error') {
      if (kDebugMode) {
        debugPrint('get_payment_book error: ${result['message']}');
      }
      return _cache ?? const PaymentBookModel();
    }

    final parsed = _applyTrustedTotals(PaymentBookModel.fromResponse(map));
    // Today-only endpoint often returns invoices:[] while home_count is large.
    // Prefer existing cache / shared history catalog over an empty wipe.
    if (parsed.invoices.isEmpty &&
        parsed.homeCount > 0 &&
        (_cache?.invoices.isNotEmpty == true ||
            PaymentHistoryService.hasAnyCache)) {
      final seed = _cache?.invoices.isNotEmpty == true
          ? _cache!.invoices
          : (PaymentHistoryService.cachedInvoices ?? const []);
      if (seed.isNotEmpty) {
        final today = CalendarDate.today();
        final ranged = seed.where((inv) {
          final day = CalendarDate.parse(inv.invoiceDate);
          if (day == null) return true;
          return !day.isBefore(today) && !day.isAfter(today);
        }).toList(growable: false);
        if (ranged.isEmpty) return parsed;
        var bal = 0.0;
        var tot = 0.0;
        for (final inv in ranged) {
          bal += inv.balance ?? 0;
          tot += inv.total ?? 0;
        }
        return PaymentBookModel(
          cardName: parsed.cardName,
          dateFrom: parsed.dateFrom,
          dateTo: parsed.dateTo,
          homeCount: parsed.homeCount,
          totalCount: ranged.length,
          totalBalance: bal,
          totalAmount: tot,
          invoices: ranged,
        );
      }
    }
    return parsed;
  }

  /// Fallback when payment-book date params are broken on the server.
  /// Uses [PaymentHistoryService] so sparse `get_payment_history` still
  /// expands via `get_customer_invoice_list` instead of wiping the catalog.
  static Future<PaymentBookModel> _fetchViaPaymentHistory({
    required String sessionId,
    String? dateFrom,
    String? dateTo,
  }) async {
    final invoices = await PaymentHistoryService.fetchInvoices(
      sessionId: sessionId,
      forceRefresh: true,
    );
    // Keep only rows inside the requested date window (API may return extra).
    // Hide cancelled/canceled and emptied drafts (total+balance 0) — discard
    // may leave an empty draft when hard-delete routes are missing.
    final ranged = invoices.where((inv) {
      final state =
          (inv.moveState ?? inv.paymentState ?? inv.status ?? '')
              .toLowerCase();
      if (state.contains('cancel')) return false;
      final total = inv.total ?? 0;
      final balance = inv.balance ?? 0;
      final name = (inv.customer ?? '').trim();
      if (total.abs() < 0.0001 &&
          balance.abs() < 0.0001 &&
          name.isEmpty) {
        return false;
      }
      final day = CalendarDate.parse(inv.invoiceDate);
      if (day == null) return true;
      if (dateFrom != null) {
        final from = CalendarDate.parse(dateFrom);
        if (from != null && day.isBefore(from)) {
          return false;
        }
      }
      if (dateTo != null) {
        final to = CalendarDate.parse(dateTo);
        if (to != null && day.isAfter(to)) {
          return false;
        }
      }
      return true;
    }).toList(growable: false);

    double bal = 0;
    double tot = 0;
    for (final inv in ranged) {
      bal += inv.balance ?? 0;
      tot += inv.total ?? 0;
    }

    return PaymentBookModel(
      cardName: 'Payment Book',
      dateFrom: dateFrom,
      dateTo: dateTo,
      homeCount: ranged.length,
      totalCount: ranged.length,
      totalBalance: bal,
      totalAmount: tot,
      invoices: ranged,
    );
  }

  static PaymentBookModel _applyTrustedTotals(PaymentBookModel book) {
    final list = book.invoices
        .map(PaymentHistoryService.withTrustedTotals)
        .toList(growable: false);
    if (identical(list, book.invoices)) return book;
    var changed = false;
    for (var i = 0; i < list.length; i++) {
      if (!identical(list[i], book.invoices[i])) {
        changed = true;
        break;
      }
    }
    if (!changed) return book;
    var bal = 0.0;
    var tot = 0.0;
    for (final inv in list) {
      bal += inv.balance ?? 0;
      tot += inv.total ?? 0;
    }
    return PaymentBookModel(
      cardName: book.cardName,
      dateFrom: book.dateFrom,
      dateTo: book.dateTo,
      homeCount: book.homeCount,
      totalCount: list.length,
      totalBalance: bal,
      totalAmount: tot,
      invoices: list,
    );
  }

  static PaymentBookModel _applyLocalFilters(
    PaymentBookModel book, {
    String? customer,
    String? customerType,
    String? paymentMode,
  }) {
    var list = List<InvoiceSummaryModel>.from(book.invoices);

    if (customer != null && customer.trim().isNotEmpty) {
      final q = customer.trim().toLowerCase();
      list = list.where((item) {
        final name = item.listCustomerLabel.toLowerCase();
        final raw = (item.customer ?? '').toLowerCase();
        final number = (item.invoiceNumber ?? '').toLowerCase();
        return name.contains(q) ||
            raw.contains(q) ||
            number.contains(q) ||
            (q.contains('walk') && item.isWalkInOrNamelessCustomer);
      }).toList(growable: false);
    }

    if (customerType != null && customerType.isNotEmpty) {
      list = list.where((item) {
        switch (customerType) {
          case 'credit':
            return item.isCreditCustomer;
          case 'normal':
            return !item.isCreditCustomer;
          case 'b2b':
            return InvoiceSeriesClassifier.isB2bInvoice(item);
          case 'b2c':
            return InvoiceSeriesClassifier.isB2cInvoice(item);
          default:
            return true;
        }
      }).toList(growable: false);
    }

    if (paymentMode != null && paymentMode.isNotEmpty) {
      final mode = paymentMode.toLowerCase();
      list = list.where((item) {
        final raw = (item.paymentMode ?? '').toLowerCase().trim();
        // Drafts often omit mode; treat blank as cash (same as PaymentBookFilter).
        if (raw.isEmpty) return mode == 'cash';
        return raw == mode || raw.contains(mode);
      }).toList(growable: false);
    }

    if (identical(list, book.invoices) || list.length == book.invoices.length) {
      // Still recompute when we filtered in place with same length unlikely;
      // only skip rebuild when nothing changed.
      final unchanged = list.length == book.invoices.length &&
          (list.isEmpty || identical(list.first, book.invoices.first));
      if (unchanged) return book;
    }

    double bal = 0;
    double tot = 0;
    for (final inv in list) {
      bal += inv.balance ?? 0;
      tot += inv.total ?? 0;
    }

    return PaymentBookModel(
      cardName: book.cardName,
      dateFrom: book.dateFrom,
      dateTo: book.dateTo,
      homeCount: list.length,
      totalCount: list.length,
      totalBalance: bal,
      totalAmount: tot,
      invoices: list,
    );
  }

  static Future<void> prefetch(
    String sessionId, {
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && hasFreshCache) return;
    try {
      await fetch(sessionId: sessionId, forceRefresh: forceRefresh);
    } catch (e, s) {
      if (kDebugMode) debugPrint('Payment book prefetch: $e\n$s');
    }
  }

  static String _formatApiDate(DateTime date) {
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  static void clearCache() {
    _cache = null;
    _cachedAt = null;
    _cacheKey = null;
    _inFlight = null;
  }

  /// Optimistically drop a discarded draft from the home/payment-book cache.
  static void removeInvoice(int invoiceId) {
    if (invoiceId <= 0) return;
    final book = _cache;
    if (book == null) return;
    final kept = book.invoices.where((i) => i.id != invoiceId).toList();
    if (kept.length == book.invoices.length) return;
    var balance = 0.0;
    var amount = 0.0;
    for (final inv in kept) {
      balance += inv.balance ?? 0;
      amount += inv.total ?? 0;
    }
    _cache = PaymentBookModel(
      cardName: book.cardName,
      dateFrom: book.dateFrom,
      dateTo: book.dateTo,
      homeCount: (book.homeCount - 1).clamp(0, 1 << 30).toInt(),
      totalCount: kept.length,
      totalBalance: balance,
      totalAmount: amount,
      invoices: kept,
    );
    _cachedAt = DateTime.now();
  }

  /// Patch / insert one invoice so the home Payment Book card updates instantly.
  static void upsertInvoice(InvoiceSummaryModel invoice) {
    final id = invoice.id;
    if (id == null || id <= 0) return;
    final patched = PaymentHistoryService.withTrustedTotals(invoice);
    final book = _cache;
    final list = List<InvoiceSummaryModel>.from(book?.invoices ?? const []);
    final idx = list.indexWhere((i) => i.id == id);
    if (idx >= 0) {
      list[idx] = PaymentHistoryService.withTrustedTotals(
        list[idx].mergedWith(patched),
      );
    } else {
      list.insert(0, patched);
    }
    var balance = 0.0;
    var amount = 0.0;
    for (final inv in list) {
      balance += inv.balance ?? 0;
      amount += inv.total ?? 0;
    }
    _cache = PaymentBookModel(
      cardName: book?.cardName ?? 'Payment Book',
      dateFrom: book?.dateFrom,
      dateTo: book?.dateTo,
      homeCount: list.length,
      totalCount: list.length,
      totalBalance: balance,
      totalAmount: amount,
      invoices: list,
    );
    _cachedAt = DateTime.now();
  }
}
