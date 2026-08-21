/// Today Paid Cheque Clearance row + nested payment / invoice detail.
import '../features/services/calendar_date.dart';

class ChequeClearanceModel {
  const ChequeClearanceModel({
    this.id,
    this.serialNumber,
    this.date,
    this.chequeNumber,
    this.chequeDate,
    this.clearanceDate,
    this.totalAmount,
    this.balance,
    this.bank,
    this.branch,
    this.ifsc,
    this.state,
    this.customerPayment,
    this.partnerPaymentId,
    this.partnerId,
    this.partnerName,
    this.chequeAmount,
    this.responsiblePerson,
    this.paymentAmount,
    this.advanceAmount,
    this.oldBalance,
    this.paymentMode,
    this.validatedBy,
    this.creditedTo,
    this.paymentBank,
    this.invoices = const [],
  });

  final int? id;
  final String? serialNumber;
  final String? date;
  final String? chequeNumber;
  final String? chequeDate;
  final String? clearanceDate;
  final double? totalAmount;
  final double? balance;
  final String? bank;
  final String? branch;
  final String? ifsc;
  final String? state;
  final String? customerPayment;
  /// Odoo `partner_payment_id` (e.g. 236 → PAY/0236).
  final int? partnerPaymentId;
  final int? partnerId;
  final String? partnerName;
  final double? chequeAmount;
  final String? responsiblePerson;
  final double? paymentAmount;
  final double? advanceAmount;
  final double? oldBalance;
  final String? paymentMode;
  final String? validatedBy;
  final String? creditedTo;
  /// Free-text bank on partner.payment (website Customer Payment card).
  final String? paymentBank;
  final List<ChequeLinkedInvoice> invoices;

  String get displaySerial => _text(serialNumber);
  String get displayChequeNo => _text(chequeNumber);
  String get displayState {
    final raw = state?.trim();
    if (raw == null || raw.isEmpty) return 'Paid';
    return raw[0].toUpperCase() + raw.substring(1);
  }

  String get displayCustomerPayment {
    final named = customerPayment?.trim();
    if (named != null &&
        named.isNotEmpty &&
        !named.toUpperCase().contains('PCSH')) {
      return named;
    }
    return formatPartnerPaymentName(partnerPaymentId) ?? '—';
  }

  String get displayPartner => _text(partnerName);
  String get displayBank => _text(bank);
  String get displayBranch => _text(branch);
  String get displayIfsc => _text(ifsc);

  double? get displayChequeAmount => chequeAmount ?? totalAmount ?? paymentAmount;
  double? get displayBalance => balance ?? oldBalance;
  double? get displayPaymentAmount => paymentAmount ?? chequeAmount ?? totalAmount;

  bool get hasCustomerPayment {
    if (partnerPaymentId != null && partnerPaymentId! > 0) return true;
    final v = customerPayment?.trim();
    return v != null && v.isNotEmpty && v != '—';
  }

  /// Website sequence style: partner_payment_id 236 → PAY/0236.
  static String? formatPartnerPaymentName(int? id) {
    if (id == null || id <= 0) return null;
    return 'PAY/${id.toString().padLeft(4, '0')}';
  }

  ChequeClearanceModel copyWith({
    int? id,
    String? serialNumber,
    String? date,
    String? chequeNumber,
    String? chequeDate,
    String? clearanceDate,
    double? totalAmount,
    double? balance,
    String? bank,
    String? branch,
    String? ifsc,
    String? state,
    String? customerPayment,
    int? partnerPaymentId,
    int? partnerId,
    String? partnerName,
    double? chequeAmount,
    String? responsiblePerson,
    double? paymentAmount,
    double? advanceAmount,
    double? oldBalance,
    String? paymentMode,
    String? validatedBy,
    String? creditedTo,
    String? paymentBank,
    List<ChequeLinkedInvoice>? invoices,
  }) {
    return ChequeClearanceModel(
      id: id ?? this.id,
      serialNumber: serialNumber ?? this.serialNumber,
      date: date ?? this.date,
      chequeNumber: chequeNumber ?? this.chequeNumber,
      chequeDate: chequeDate ?? this.chequeDate,
      clearanceDate: clearanceDate ?? this.clearanceDate,
      totalAmount: totalAmount ?? this.totalAmount,
      balance: balance ?? this.balance,
      bank: bank ?? this.bank,
      branch: branch ?? this.branch,
      ifsc: ifsc ?? this.ifsc,
      state: state ?? this.state,
      customerPayment: customerPayment ?? this.customerPayment,
      partnerPaymentId: partnerPaymentId ?? this.partnerPaymentId,
      partnerId: partnerId ?? this.partnerId,
      partnerName: partnerName ?? this.partnerName,
      chequeAmount: chequeAmount ?? this.chequeAmount,
      responsiblePerson: responsiblePerson ?? this.responsiblePerson,
      paymentAmount: paymentAmount ?? this.paymentAmount,
      advanceAmount: advanceAmount ?? this.advanceAmount,
      oldBalance: oldBalance ?? this.oldBalance,
      paymentMode: paymentMode ?? this.paymentMode,
      validatedBy: validatedBy ?? this.validatedBy,
      creditedTo: creditedTo ?? this.creditedTo,
      paymentBank: paymentBank ?? this.paymentBank,
      invoices: invoices ?? this.invoices,
    );
  }

  /// Merge Odoo / nested payment detail over list-row values.
  ChequeClearanceModel mergedWith(ChequeClearanceModel other) {
    return copyWith(
      id: other.id ?? id,
      serialNumber: _prefer(other.serialNumber, serialNumber),
      date: _prefer(other.date, date),
      chequeNumber: _prefer(other.chequeNumber, chequeNumber),
      chequeDate: _prefer(other.chequeDate, chequeDate),
      clearanceDate: _prefer(other.clearanceDate, clearanceDate),
      totalAmount: other.totalAmount ?? totalAmount,
      balance: other.balance ?? balance,
      bank: _prefer(other.bank, bank),
      branch: _prefer(other.branch, branch),
      ifsc: _prefer(other.ifsc, ifsc),
      state: _prefer(other.state, state),
      customerPayment: _prefer(other.customerPayment, customerPayment),
      partnerPaymentId: other.partnerPaymentId ?? partnerPaymentId,
      partnerId: other.partnerId ?? partnerId,
      partnerName: _prefer(other.partnerName, partnerName),
      chequeAmount: other.chequeAmount ?? chequeAmount,
      responsiblePerson:
          _prefer(other.responsiblePerson, responsiblePerson),
      paymentAmount: other.paymentAmount ?? paymentAmount,
      advanceAmount: other.advanceAmount ?? advanceAmount,
      oldBalance: other.oldBalance ?? oldBalance,
      paymentMode: _prefer(other.paymentMode, paymentMode),
      validatedBy: _prefer(other.validatedBy, validatedBy),
      creditedTo: _prefer(other.creditedTo, creditedTo),
      paymentBank: _prefer(other.paymentBank, paymentBank),
      invoices: other.invoices.isNotEmpty ? other.invoices : invoices,
    );
  }

  static String? _prefer(String? primary, String? fallback) {
    final p = primary?.trim();
    if (p != null && p.isNotEmpty && p != '—') return p;
    final f = fallback?.trim();
    if (f != null && f.isNotEmpty && f != '—') return f;
    return primary ?? fallback;
  }

  factory ChequeClearanceModel.fromJson(Map<String, dynamic> json) {
    final payment = _asMap(json['customer_payment']) ??
        _asMap(json['payment']) ??
        _asMap(json['payment_id']) ??
        _asMap(json['account_payment']);

    final merged = <String, dynamic>{...json};
    if (payment != null) {
      for (final entry in payment.entries) {
        merged.putIfAbsent(entry.key, () => entry.value);
      }
    }

    final invoices = ChequeLinkedInvoice.parseList(merged);

    final partnerPaymentId = _asInt(
      merged['partner_payment_id'] ??
          merged['payment_id'] ??
          merged['customer_payment_id'],
    );

    final paymentLabelRaw = _str(merged, const [
          'customer_payment',
          'customer_payment_name',
          'payment_name',
          'payment_ref',
          'payment_number',
          'payment_id_name',
        ]) ??
        _many2oneName(merged['payment_id']) ??
        formatPartnerPaymentName(partnerPaymentId);
    final paymentLabel = (paymentLabelRaw != null &&
            paymentLabelRaw.toUpperCase().contains('PCSH'))
        ? formatPartnerPaymentName(partnerPaymentId)
        : paymentLabelRaw;

    return ChequeClearanceModel(
      id: _asInt(merged['id'] ?? merged['cheque_id']),
      serialNumber: _chequeSerial(merged),
      date: _date(merged, const [
        'date',
        'entry_date',
        'create_date',
        'cheque_entry_date',
      ]),
      chequeNumber: _str(merged, const [
        'cheque_no',
        'cheque_number',
        'check_number',
        'check_no',
        'cheque_num',
      ]),
      chequeDate: _date(merged, const [
        'cheque_date',
        'check_date',
        'cheque_dt',
      ]),
      clearanceDate: _date(merged, const [
        'clearance_date',
        'deposit_date',
        'cleared_date',
        'clear_date',
        'date_clearance',
      ]),
      totalAmount: _num(merged, const [
        'list_cheque_amount',
        'cheque_amount',
        'total_amount',
        'amount_total',
        'amount',
        'payment_amount',
      ]),
      balance: _num(merged, const [
        'list_balance_amount',
        'balance_amount',
        'balance',
        'amount_residual',
        'residual',
        'outstanding_balance',
        'total_amount_party',
      ]),
      bank: _str(merged, const [
        'bank_id_name',
        'bank_name',
        'bank',
      ]),
      branch: _str(merged, const [
        'branch',
        'bank_branch',
        'branch_name',
      ]),
      ifsc: _str(merged, const [
        'ifsc',
        'ifsc_code',
        'ifsc_code_id',
      ]),
      state: _str(merged, const [
        'state',
        'status',
        'cheque_state',
        'payment_state',
      ]),
      customerPayment: paymentLabel,
      partnerPaymentId: partnerPaymentId,
      partnerId: _asInt(merged['partner_id'] ?? merged['partner']),
      partnerName: _str(merged, const [
        'partner_name',
        'customer',
        'name_partner',
      ]) ??
          _many2oneName(merged['partner_id']),
      chequeAmount: _num(merged, const [
        'list_cheque_amount',
        'cheque_amount',
        'amount',
        'payment_amount',
        'total_amount',
      ]),
      responsiblePerson: _str(merged, const [
        'responsible_person',
        'resp_person',
        'responsible_person_id_name',
        'responsible_id_name',
        'salesperson',
        'billed_by',
        'billed_by_name',
        'invoice_user_id_name',
      ]),
      paymentAmount: _num(merged, const [
        'list_cheque_amount',
        'cheque_amount',
        'payment_amount',
        'amount',
        'paid_amount',
      ]),
      advanceAmount: _num(merged, const [
        'advance_amount',
        'advance_amt',
        'advance',
      ]),
      oldBalance: _num(merged, const [
        'old_balance',
        'previous_balance',
      ]),
      paymentMode: _paymentMode(merged),
      validatedBy: _str(merged, const [
        'validated_by',
        'validated_by_name',
        'create_uid_name',
        'create_uid',
        'write_uid',
      ]) ??
          _many2oneName(merged['create_uid']),
      creditedTo: _str(merged, const [
        'credited_to',
        'credit_to',
        'bank_id_name',
        'journal_id_name',
      ]) ??
          _many2oneName(merged['journal_id']) ??
          _many2oneName(merged['bank_id']),
      paymentBank: _str(merged, const [
        'payment_bank',
        'cheque_bank',
        'bank_name',
        'bank',
      ]),
      invoices: invoices,
    );
  }

  /// Prefer CHQ/… — never treat PAY/… or PCSH… as cheque serial.
  static String? _chequeSerial(Map json) {
    for (final key in const [
      'serial_number',
      'cheque_name',
      'name',
      'display_name',
      'reference',
    ]) {
      final text = _str(json, [key]);
      if (text == null) continue;
      final upper = text.toUpperCase();
      if (upper.startsWith('PAY/') ||
          upper.startsWith('PCSH') ||
          upper.contains('PCSH')) {
        continue;
      }
      return text;
    }
    return null;
  }

  /// Website Customer Payment mode is Cheque — not Odoo inbound/outbound.
  static String? _paymentMode(Map json) {
    final mode = _str(json, const ['payment_mode', 'journal_type']);
    if (mode != null) {
      final lower = mode.toLowerCase();
      if (lower == 'inbound' || lower == 'outbound') return 'Cheque';
      return mode;
    }
    final type = _str(json, const ['payment_type']);
    if (type == null) return null;
    final lower = type.toLowerCase();
    if (lower == 'inbound' || lower == 'outbound' || lower == 'transfer') {
      return 'Cheque';
    }
    return type;
  }

  static List<ChequeClearanceModel> parseList(Map<String, dynamic> response) {
    final result = response['result'];
    if (result is! Map) return const [];

    final root = Map<String, dynamic>.from(result);

    // Actual API: result.data.cheques
    final data = root['data'];
    if (data is Map) {
      final cheques = data['cheques'];
      if (cheques is List) {
        return cheques
            .whereType<Map>()
            .map((e) => ChequeClearanceModel.fromJson(
                  Map<String, dynamic>.from(e),
                ))
            .toList();
      }
    }

    final candidates = <dynamic>[
      root['cheques'],
      root['cheque_clearance'],
      root['cheque_clearances'],
      root['today_cheque_clearance'],
      root['today_paid_cheque_clearance'],
      root['records'],
      root['items'],
      root['data'],
      root['results'],
      root['payments'],
    ];

    for (final candidate in candidates) {
      if (candidate is List) {
        return candidate
            .whereType<Map>()
            .map((e) => ChequeClearanceModel.fromJson(
                  Map<String, dynamic>.from(e),
                ))
            .toList();
      }
      if (candidate is Map) {
        final nested = candidate['cheques'] ??
            candidate['cheque_clearance'] ??
            candidate['records'] ??
            candidate['items'] ??
            candidate['data'];
        if (nested is List) {
          return nested
              .whereType<Map>()
              .map((e) => ChequeClearanceModel.fromJson(
                    Map<String, dynamic>.from(e),
                  ))
              .toList();
        }
      }
    }
    return const [];
  }

  static String formatMoney(double? value) {
    if (value == null) return '0.00';
    return value.toStringAsFixed(2);
  }

  static String formatDate(String? value) {
    final parsed = CalendarDate.parse(value);
    if (parsed != null) return CalendarDate.dmy(parsed);
    final raw = (value ?? '').trim();
    return raw.isEmpty ? '—' : raw;
  }

  static String _text(String? value) {
    if (value == null || value.trim().isEmpty) return '—';
    return value.trim();
  }

  static Map<String, dynamic>? _asMap(dynamic value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  static String? _many2oneName(dynamic value) {
    if (value is List && value.length >= 2) {
      final name = value[1]?.toString().trim();
      if (name == null || name.isEmpty || name == 'false') return null;
      return name;
    }
    return null;
  }

  static String? _str(Map json, List<String> keys) {
    for (final key in keys) {
      if (!json.containsKey(key)) continue;
      final value = json[key];
      if (value == null || value == false) continue;
      if (value is List && value.length >= 2) {
        final name = value[1]?.toString().trim();
        if (name != null && name.isNotEmpty && name != 'false') return name;
        continue;
      }
      final text = value.toString().trim();
      if (text.isEmpty || text == 'false') continue;
      return text;
    }
    return null;
  }

  static String? _date(Map json, List<String> keys) {
    final raw = _str(json, keys);
    if (raw == null) return null;
    return formatDate(raw);
  }

  static double? _num(Map json, List<String> keys) {
    for (final key in keys) {
      if (!json.containsKey(key)) continue;
      final value = json[key];
      if (value == null || value == false) continue;
      if (value is num) return value.toDouble();
      final parsed = double.tryParse(
        value.toString().replaceAll(',', '').trim(),
      );
      if (parsed != null) return parsed;
    }
    return null;
  }

  static int? _asInt(dynamic value) {
    if (value == null || value == false || value == true) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is List && value.isNotEmpty) return _asInt(value.first);
    return int.tryParse(value.toString());
  }
}

class ChequeLinkedInvoice {
  const ChequeLinkedInvoice({
    this.number,
    this.invoiceDate,
    this.total,
    this.balance,
    this.payAmount,
    this.status,
    this.responsiblePerson,
    this.narration,
    this.partnerName,
    this.selected = false,
    this.moveId,
  });

  final String? number;
  final String? invoiceDate;
  final double? total;
  final double? balance;
  final double? payAmount;
  final String? status;
  final String? responsiblePerson;
  final String? narration;
  final String? partnerName;
  /// Website Customer Payment checkbox (pay amount > 0 / selected).
  final bool selected;
  final int? moveId;

  String get displayLabel {
    final no = number?.trim();
    final name = partnerName?.trim();
    if (no != null && no.isNotEmpty && name != null && name.isNotEmpty) {
      return '$no - $name';
    }
    if (no != null && no.isNotEmpty) return no;
    if (name != null && name.isNotEmpty) return name;
    return '—';
  }

  ChequeLinkedInvoice copyWith({
    String? number,
    String? invoiceDate,
    double? total,
    double? balance,
    double? payAmount,
    String? status,
    String? responsiblePerson,
    String? narration,
    String? partnerName,
    bool? selected,
    int? moveId,
  }) {
    return ChequeLinkedInvoice(
      number: number ?? this.number,
      invoiceDate: invoiceDate ?? this.invoiceDate,
      total: total ?? this.total,
      balance: balance ?? this.balance,
      payAmount: payAmount ?? this.payAmount,
      status: status ?? this.status,
      responsiblePerson: responsiblePerson ?? this.responsiblePerson,
      narration: narration ?? this.narration,
      partnerName: partnerName ?? this.partnerName,
      selected: selected ?? this.selected,
      moveId: moveId ?? this.moveId,
    );
  }

  factory ChequeLinkedInvoice.fromJson(Map<String, dynamic> json) {
    final pay = ChequeClearanceModel._num(json, const [
      'pay_amount',
      'amount',
      'allocated_amount',
      'payment_amount',
    ]);
    final selectedRaw = json['selected'] ?? json['is_selected'] ?? json['select'];
    final selected = selectedRaw == true ||
        selectedRaw == 1 ||
        selectedRaw == 'true' ||
        (pay != null && pay > 0);
    return ChequeLinkedInvoice(
      number: ChequeClearanceModel._str(json, const [
        'number',
        'name',
        'invoice_number',
        'invoice_name',
        'move_name',
        'display_name',
      ]),
      invoiceDate: ChequeClearanceModel._date(json, const [
        'invoice_date',
        'date',
        'invoice_date_due',
      ]),
      total: ChequeClearanceModel._num(json, const [
        'total',
        'amount_total',
        'total_amount',
      ]),
      balance: ChequeClearanceModel._num(json, const [
        'balance',
        'amount_residual',
        'residual',
      ]),
      payAmount: pay,
      status: ChequeClearanceModel._str(json, const [
        'status',
        'state',
        'payment_state',
      ]),
      responsiblePerson: ChequeClearanceModel._str(json, const [
        'responsible_person',
        'resp_person',
        'responsible_person_id_name',
        'billed_by',
        'billed_by_name',
        'invoice_user_id_name',
        'salesperson',
      ]),
      narration: ChequeClearanceModel._str(json, const [
        'narration',
        'remarks',
        'note',
      ]),
      partnerName: ChequeClearanceModel._str(json, const [
        'partner_name',
        'customer',
        'partner_id',
      ]),
      selected: selected,
      moveId: ChequeClearanceModel._asInt(json['move_id'] ?? json['id']),
    );
  }

  static List<ChequeLinkedInvoice> parseList(Map<String, dynamic> json) {
    final candidates = <dynamic>[
      json['invoices'],
      json['invoice_ids'],
      json['linked_invoices'],
      json['invoice_lines'],
      json['reconciled_invoice_ids'],
      json['invoice_list'],
    ];
    for (final candidate in candidates) {
      if (candidate is! List) continue;
      return candidate
          .whereType<Map>()
          .map((e) => ChequeLinkedInvoice.fromJson(
                Map<String, dynamic>.from(e),
              ))
          .toList();
    }
    // Single invoice fields on the parent row.
    final singleNo = ChequeClearanceModel._str(json, const [
      'invoice_number',
      'invoice_name',
      'move_name',
    ]);
    if (singleNo != null) {
      return [
        ChequeLinkedInvoice(
          number: singleNo,
          partnerName: ChequeClearanceModel._str(json, const [
            'partner_name',
            'customer',
            'partner_id',
          ]),
          invoiceDate: ChequeClearanceModel._date(json, const [
            'invoice_date',
          ]),
          total: ChequeClearanceModel._num(json, const [
            'invoice_total',
            'amount_total',
          ]),
          balance: ChequeClearanceModel._num(json, const [
            'balance',
            'amount_residual',
          ]),
          payAmount: ChequeClearanceModel._num(json, const [
            'pay_amount',
            'payment_amount',
            'cheque_amount',
          ]),
          status: ChequeClearanceModel._str(json, const [
            'invoice_status',
            'payment_state',
          ]),
          responsiblePerson: ChequeClearanceModel._str(json, const [
            'responsible_person',
            'resp_person',
          ]),
        ),
      ];
    }
    return const [];
  }
}
