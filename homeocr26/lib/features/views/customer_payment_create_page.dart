import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/cheque_clearance_model.dart';
import '../../viewModels/login_viewmodel.dart';
import '../services/odoo_rpc_helper.dart';
import '../widgets/system_safe.dart';

/// Website "New Customer Payment" form (partner.payment draft).
class CustomerPaymentCreatePage extends StatefulWidget {
  const CustomerPaymentCreatePage({super.key, this.prefill});

  /// Optional values from an existing cheque payment screen.
  final ChequeClearanceModel? prefill;

  @override
  State<CustomerPaymentCreatePage> createState() =>
      _CustomerPaymentCreatePageState();
}

class _CustomerPaymentCreatePageState extends State<CustomerPaymentCreatePage> {
  final _amountCtrl = TextEditingController(text: '0.00');
  final _invoiceSearchCtrl = TextEditingController();

  int? _paymentId;
  String _paymentName = 'New';
  bool _bootstrapping = true;
  bool _busy = false;
  String? _error;
  /// True after Confirm/Pay Bill/Cancel succeeds — skip draft cleanup.
  bool _terminalActionDone = false;
  String? _sidCache;

  _NamedOpt? _customer;
  _NamedOpt? _responsible;
  String _paymentMode = 'Cash';
  DateTime _date = DateTime.now();
  DateTime _clearanceDate = DateTime.now();
  bool _useAdvance = false;
  bool _payOldBalance = false;
  double _advanceAmt = 0;
  double _oldBalance = 0;
  String _validatedBy = 'Administrator';

  List<_NamedOpt> _customers = [];
  List<_NamedOpt> _responsiblePeople = [];
  List<String> _paymentModes = const ['Cash', 'Cheque', 'Bank', 'UPI'];
  List<ChequeLinkedInvoice> _invoices = [];

  Timer? _syncDebounce;

  @override
  void initState() {
    super.initState();
    final pre = widget.prefill;
    if (pre != null) {
      if ((pre.partnerName ?? '').trim().isNotEmpty) {
        _customer = _NamedOpt(name: pre.partnerName!.trim(), id: pre.partnerId);
      }
      if ((pre.responsiblePerson ?? '').trim().isNotEmpty) {
        _responsible = _NamedOpt(name: pre.responsiblePerson!.trim());
      }
      if ((pre.paymentMode ?? '').trim().isNotEmpty) {
        _paymentMode = _prettyMode(pre.paymentMode!);
      }
      if (pre.displayPaymentAmount != null) {
        _amountCtrl.text =
            ChequeClearanceModel.formatMoney(pre.displayPaymentAmount);
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    _syncDebounce?.cancel();
    final draftId = _paymentId;
    final sid = _sidCache;
    final cleanup = draftId != null && !_terminalActionDone;
    _amountCtrl.dispose();
    _invoiceSearchCtrl.dispose();
    super.dispose();
    if (cleanup && sid != null && sid.isNotEmpty) {
      // Discard unused draft so opening the form does not leave orphan PAY/….
      unawaited(OdooRpcHelper.cancelPartnerPayment(sid, draftId));
    }
  }

  Future<String> _sessionId() async {
    final login = context.read<LoginViewmodel>();
    var sid = login.sessionId ?? '';
    final email = (login.loginEmail ?? '').trim();
    final pass = login.loginPassword ?? '';
    if (email.isNotEmpty && pass.isNotEmpty) {
      final web = await OdooRpcHelper.cachedWebSessionId(
        db: LoginViewmodel.dbName,
        login: email,
        password: pass,
      );
      if (web != null && web.isNotEmpty) sid = web;
    }
    _sidCache = sid;
    return sid;
  }

  Future<void> _bootstrap() async {
    setState(() {
      _bootstrapping = true;
      _error = null;
    });
    try {
      final sid = await _sessionId();
      if (sid.isEmpty) throw Exception('Not logged in');

      final modes = await OdooRpcHelper.partnerPaymentModes(sid);
      final customers = await OdooRpcHelper.searchPharmacyCustomers(sid);
      final responsible = await OdooRpcHelper.searchResponsiblePersons(sid);

      if (!mounted) return;
      setState(() {
        _paymentId = null;
        _paymentName = 'New';
        _paymentModes = modes;
        if (!_paymentModes.contains(_paymentMode) && _paymentModes.isNotEmpty) {
          _paymentMode = _paymentModes.first;
        }
        _customers = customers
            .map((row) {
              final name = (row['name'] ?? '').toString().trim();
              if (name.isEmpty) return null;
              // partner.payment.partner_id uses pharmacy.customer id (e.g. 904).
              final id = row['id'] is num
                  ? (row['id'] as num).toInt()
                  : int.tryParse('${row['id']}');
              return _NamedOpt(name: name, id: id);
            })
            .whereType<_NamedOpt>()
            .toList()
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        _responsiblePeople = responsible
            .map((row) {
              final name =
                  (row['name'] ?? row['display_name'] ?? '').toString().trim();
              if (name.isEmpty) return null;
              final id = row['id'];
              return _NamedOpt(
                name: name,
                id: id is num ? id.toInt() : int.tryParse('$id'),
              );
            })
            .whereType<_NamedOpt>()
            .toList()
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

        if (_customer != null) {
          _NamedOpt? match;
          for (final c in _customers) {
            if (c.name.toLowerCase() == _customer!.name.toLowerCase() ||
                (c.id != null && c.id == _customer!.id)) {
              match = c;
              break;
            }
          }
          if (match != null) {
            _customer = match;
          } else if (!_customers.any((c) => c.name == _customer!.name)) {
            _customers = [..._customers, _customer!];
          }
        }
        if (_responsible != null &&
            !_responsiblePeople.any((r) => r.name == _responsible!.name)) {
          _responsiblePeople = [..._responsiblePeople, _responsible!];
        }
        _bootstrapping = false;
      });

      // Only create a website draft once a customer is known (prefill / pick).
      if (_customer != null) {
        await _ensureDraft();
        await _loadInvoicesForCustomer();
      }
    } catch (e, s) {
      if (kDebugMode) debugPrint('payment create bootstrap: $e\n$s');
      if (!mounted) return;
      setState(() {
        _bootstrapping = false;
        _error = e.toString();
      });
    }
  }

  /// Create partner.payment draft once (not on every screen open).
  Future<bool> _ensureDraft() async {
    if (_paymentId != null) return true;
    try {
      final sid = await _sessionId();
      if (sid.isEmpty) throw Exception('Not logged in');
      final amount =
          double.tryParse(_amountCtrl.text.replaceAll(',', '')) ?? 0;
      final modeVal = OdooRpcHelper.partnerPaymentModeValue(_paymentMode);
      final vals = <String, dynamic>{
        if (_customer?.id != null) 'partner_id': _customer!.id,
        'payment_mode': modeVal,
        'date': _fmtYmd(_date),
        'clearance_date': _fmtYmd(_clearanceDate),
        'payment_amount': amount,
      };
      if (modeVal == 'cheque') {
        vals['cheque_amount'] = amount;
      }
      final draftId = await OdooRpcHelper.createPartnerPaymentDraft(
        sid,
        values: vals,
      );
      if (draftId == null) throw Exception('Could not create payment draft');
      final header =
          await OdooRpcHelper.readPartnerPaymentHeader(sid, draftId);
      if (!mounted) return false;
      setState(() {
        _paymentId = draftId;
        if (header != null) {
          _paymentName = (header['name'] ?? 'New').toString();
          _advanceAmt = _toDouble(header['advance_amount']) ?? _advanceAmt;
          _oldBalance = _toDouble(header['old_balance']) ?? _oldBalance;
          _validatedBy =
              (header['create_uid_name'] ?? _validatedBy).toString();
        }
      });
      return true;
    } catch (e, s) {
      if (kDebugMode) debugPrint('ensureDraft: $e\n$s');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not create payment: $e')),
        );
      }
      return false;
    }
  }

  void _scheduleSync() {
    _syncDebounce?.cancel();
    _syncDebounce = Timer(const Duration(milliseconds: 450), () {
      _syncToOdoo();
    });
  }

  Future<void> _syncToOdoo() async {
    if (_paymentId == null) {
      if (_customer == null) return;
      final ok = await _ensureDraft();
      if (!ok) return;
    }
    final id = _paymentId;
    if (id == null) return;
    try {
      final sid = await _sessionId();
      if (sid.isEmpty) return;
      final amount =
          double.tryParse(_amountCtrl.text.replaceAll(',', '')) ?? 0;
      final modeVal = OdooRpcHelper.partnerPaymentModeValue(_paymentMode);
      final vals = <String, dynamic>{
        'date': _fmtYmd(_date),
        'clearance_date': _fmtYmd(_clearanceDate),
        'payment_amount': amount,
        'payment_mode': modeVal,
        'use_advance': _useAdvance,
        'pay_old_balance': _payOldBalance,
      };
      // Odoo ValidationError: "Enter the cheque amount before processing payment."
      if (modeVal == 'cheque') {
        vals['cheque_amount'] = amount;
      }
      if (_customer?.id != null) {
        vals['partner_id'] = _customer!.id;
      }
      if (_responsible?.id != null) {
        vals['responsible_person_id'] = _responsible!.id;
        vals['responsible_id'] = _responsible!.id;
      } else if ((_responsible?.name ?? '').trim().isNotEmpty) {
        vals['responsible_person'] = _responsible!.name.trim();
      }
      await OdooRpcHelper.updatePartnerPayment(sid, id, vals);
      final header = await OdooRpcHelper.readPartnerPaymentHeader(sid, id);
      if (!mounted || header == null) return;
      setState(() {
        _paymentName = (header['name'] ?? _paymentName).toString();
        _advanceAmt = _toDouble(header['advance_amount']) ?? _advanceAmt;
        _oldBalance = _toDouble(header['old_balance']) ?? _oldBalance;
        _validatedBy =
            (header['create_uid_name'] ?? _validatedBy).toString();
      });
    } catch (e) {
      if (kDebugMode) debugPrint('sync partner.payment: $e');
    }
  }

  Future<void> _loadInvoicesForCustomer() async {
    if (_customer == null) {
      if (mounted) setState(() => _invoices = []);
      return;
    }
    final sid = await _sessionId();
    if (sid.isEmpty) return;

    // Ensure draft exists so Odoo builds partner.payment.line rows.
    await _ensureDraft();
    await _syncToOdoo();

    final id = _paymentId;
    List<ChequeLinkedInvoice> rows = const [];
    if (id != null) {
      rows = await OdooRpcHelper.invoicesFromPartnerPayment(
        sid,
        id,
        defaultPayAmount:
            double.tryParse(_amountCtrl.text.replaceAll(',', '')) ?? 0,
      );
    }
    // Fallback if lines are empty (wrong partner id / not yet computed).
    if (rows.isEmpty) {
      rows = await OdooRpcHelper.openInvoicesForPartner(
        sid,
        partnerId: null,
        partnerName: _customer?.name,
      );
    }
    if (!mounted) return;
    setState(() => _invoices = rows);
  }

  Future<void> _pickDate({required bool clearance}) async {
    final initial = clearance ? _clearanceDate : _date;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: Color(0xFFE07A2F),
              surface: Color(0xFF1E4D5C),
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked == null) return;
    setState(() {
      if (clearance) {
        _clearanceDate = picked;
      } else {
        _date = picked;
      }
    });
    _scheduleSync();
  }

  Future<_NamedOpt?> _pickOption({
    required String title,
    required List<_NamedOpt> options,
    _NamedOpt? selected,
  }) async {
    final q = TextEditingController();
    var filtered = List<_NamedOpt>.from(options);
    return showModalBottomSheet<_NamedOpt>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModal) {
            return SafeArea(
              child: SizedBox(
                height: MediaQuery.of(ctx).size.height * 0.85,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.pop(ctx),
                            icon: const Icon(Icons.close, color: Colors.white70),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: TextField(
                        controller: q,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: 'Search…',
                          hintStyle: TextStyle(
                            color: Colors.white.withValues(alpha: 0.45),
                          ),
                          prefixIcon: const Icon(
                            Icons.search,
                            color: Colors.white54,
                          ),
                          filled: true,
                          fillColor: Colors.white.withValues(alpha: 0.08),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        onChanged: (v) {
                          final needle = v.trim().toLowerCase();
                          setModal(() {
                            filtered = options
                                .where((e) =>
                                    e.name.toLowerCase().contains(needle))
                                .toList();
                          });
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '${filtered.length} of ${options.length}',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.5),
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Expanded(
                      child: ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (_, i) {
                          final opt = filtered[i];
                          final isSelected = selected?.name == opt.name ||
                              (selected?.id != null && selected!.id == opt.id);
                          return ListTile(
                            title: Text(
                              opt.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: isSelected
                                    ? const Color(0xFFE07A2F)
                                    : Colors.white,
                                fontWeight: isSelected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                            ),
                            trailing: isSelected
                                ? const Icon(
                                    Icons.check,
                                    color: Color(0xFFE07A2F),
                                  )
                                : null,
                            onTap: () => Navigator.pop(ctx, opt),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _onPayBill() async {
    await _runAction(
      label: 'Pay Bill',
      run: (sid, id) => OdooRpcHelper.payBillPartnerPayment(sid, id),
    );
  }

  Future<void> _onConfirm() async {
    await _runAction(
      label: 'Confirm',
      run: (sid, id) => OdooRpcHelper.confirmPartnerPayment(sid, id),
      popOnSuccess: true,
    );
  }

  Future<void> _onCancel() async {
    final id = _paymentId;
    if (id == null) {
      if (mounted) Navigator.pop(context, false);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Cancel payment?', style: TextStyle(color: Colors.white)),
        content: const Text(
          'This will cancel/delete the draft on the website.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cancel payment'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _runAction(
      label: 'Cancel',
      run: (sid, pid) => OdooRpcHelper.cancelPartnerPayment(sid, pid),
      popOnSuccess: true,
      successValue: false,
    );
  }

  Future<void> _runAction({
    required String label,
    required Future<bool> Function(String sid, int id) run,
    bool popOnSuccess = false,
    bool successValue = true,
  }) async {
    if (_customer == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a customer first')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final okDraft = await _ensureDraft();
      if (!okDraft) return;
      await _syncToOdoo();
      final id = _paymentId;
      if (id == null) return;
      final sid = await _sessionId();
      await run(sid, id);
      _terminalActionDone = true;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$label successful')),
      );
      if (popOnSuccess) Navigator.pop(context, successValue);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$label failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  double get _outstanding {
    if (_invoices.isEmpty) return 0;
    return _invoices.fold<double>(0, (s, e) => s + (e.balance ?? 0));
  }

  double get _invoiceTotalSum =>
      _invoices.fold<double>(0, (s, e) => s + (e.total ?? 0));

  List<ChequeLinkedInvoice> get _filteredInvoices {
    final q = _invoiceSearchCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return _invoices;
    return _invoices
        .where((e) => (e.number ?? '').toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      appBar: AppBar(
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text(
          'New Customer Payment',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w500,
            fontSize: 15,
          ),
        ),
        backgroundColor: const Color(0xFF1A1A1A),
        elevation: 0,
      ),
      body: _bootstrapping
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFFE07A2F)),
            )
          : _error != null && !_bootstrapping
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _error!,
                          style: const TextStyle(color: Colors.white70),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        TextButton(
                          onPressed: _bootstrap,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                )
              : Stack(
                  children: [
                    ListView(
                      padding: SystemSafe.listPadding(context),
                      children: [
                        _HeaderBanner(
                          title: 'CUSTOMER PAYMENT',
                          subtitle: _paymentName,
                          outstanding: _outstanding,
                        ),
                        const SizedBox(height: 12),
                        _SectionCard(
                          title: 'Customer & Payment Info',
                          icon: Icons.person_outline,
                          children: [
                            _DropdownField(
                              label: 'Customer',
                              value: _customer?.name,
                              onTap: () async {
                                final picked = await _pickOption(
                                  title: 'Select Customer',
                                  options: _customers,
                                  selected: _customer,
                                );
                                if (picked == null) return;
                                setState(() => _customer = picked);
                                await _loadInvoicesForCustomer();
                              },
                            ),
                            _DropdownField(
                              label: 'Resp. Person',
                              value: _responsible?.name,
                              onTap: () async {
                                final picked = await _pickOption(
                                  title: 'Responsible Person',
                                  options: _responsiblePeople,
                                  selected: _responsible,
                                );
                                if (picked == null) return;
                                setState(() => _responsible = picked);
                                _scheduleSync();
                              },
                            ),
                            _DateField(
                              label: 'Date',
                              value: _fmtDisplay(_date),
                              onTap: () => _pickDate(clearance: false),
                            ),
                            _DateField(
                              label: 'Clearance Date',
                              value: _fmtDisplay(_clearanceDate),
                              onTap: () => _pickDate(clearance: true),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        _SectionCard(
                          title: 'Financial Details',
                          icon: Icons.currency_rupee,
                          children: [
                            _AmountField(
                              label: 'Payment Amount',
                              controller: _amountCtrl,
                              onChanged: (_) => _scheduleSync(),
                            ),
                            _ReadRow(
                              'Advance Amt',
                              ChequeClearanceModel.formatMoney(_advanceAmt),
                            ),
                            _CheckRow(
                              label: 'Use Advance',
                              value: _useAdvance,
                              onChanged: (v) {
                                setState(() => _useAdvance = v);
                                _scheduleSync();
                              },
                            ),
                            _ReadRow(
                              'Old Balance',
                              ChequeClearanceModel.formatMoney(_oldBalance),
                            ),
                            _CheckRow(
                              label: 'Pay Old Balance',
                              value: _payOldBalance,
                              onChanged: (v) {
                                setState(() => _payOldBalance = v);
                                _scheduleSync();
                              },
                            ),
                            _DropdownField(
                              label: 'Payment Mode',
                              value: _paymentMode,
                              onTap: () async {
                                final opts = _paymentModes
                                    .map((e) => _NamedOpt(name: e))
                                    .toList();
                                final picked = await _pickOption(
                                  title: 'Payment Mode',
                                  options: opts,
                                  selected: _NamedOpt(name: _paymentMode),
                                );
                                if (picked == null) return;
                                setState(() => _paymentMode = picked.name);
                                _scheduleSync();
                              },
                            ),
                            _ReadRow('Validated By', _validatedBy),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Text(
                          'INVOICES',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.85),
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                            letterSpacing: 0.5,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _invoiceSearchCtrl,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            hintText: 'Scan or Type Invoice',
                            hintStyle: TextStyle(
                              color: Colors.white.withValues(alpha: 0.45),
                            ),
                            prefixIcon: const Icon(
                              Icons.search,
                              color: Colors.white54,
                            ),
                            filled: true,
                            fillColor: Colors.white.withValues(alpha: 0.08),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: BorderSide.none,
                            ),
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                        const SizedBox(height: 8),
                        if (_filteredInvoices.isEmpty)
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              _customer == null
                                  ? 'Select a customer to load invoices'
                                  : 'No open invoices',
                              style: const TextStyle(color: Colors.white70),
                            ),
                          )
                        else
                          ..._filteredInvoices.map(
                            (inv) => Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: _InvoiceMiniCard(invoice: inv),
                            ),
                          ),
                        if (_invoices.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Align(
                            alignment: Alignment.centerRight,
                            child: Text(
                              'Total Amount: ₹ ${ChequeClearanceModel.formatMoney(_invoiceTotalSum)}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 18),
                        _ActionButton(
                          label: 'Pay Bill',
                          color: const Color(0xFF2E7D32),
                          onPressed: _busy ? null : _onPayBill,
                        ),
                        const SizedBox(height: 10),
                        _ActionButton(
                          label: 'Confirm',
                          color: const Color(0xFFE07A2F),
                          onPressed: _busy ? null : _onConfirm,
                        ),
                        const SizedBox(height: 10),
                        _ActionButton(
                          label: 'Cancel',
                          color: const Color(0xFF546E7A),
                          onPressed: _busy ? null : _onCancel,
                        ),
                        const SizedBox(height: 24),
                      ],
                    ),
                    if (_busy)
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

  static String _fmtYmd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static String _fmtDisplay(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/'
      '${d.year}';

  static String _prettyMode(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return 'Cash';
    return t[0].toUpperCase() + t.substring(1).toLowerCase();
  }

  static double? _toDouble(dynamic v) {
    if (v == null || v == false) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString().replaceAll(',', ''));
  }
}

class _NamedOpt {
  const _NamedOpt({required this.name, this.id});
  final String name;
  final int? id;
}

class _HeaderBanner extends StatelessWidget {
  const _HeaderBanner({
    required this.title,
    required this.subtitle,
    required this.outstanding,
  });

  final String title;
  final String subtitle;
  final double outstanding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1E4D5C),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.credit_card_outlined, color: Colors.white, size: 26),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
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
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                'OUTSTANDING BALANCE',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '₹ ${ChequeClearanceModel.formatMoney(outstanding)}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                ),
              ),
            ],
          ),
        ],
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
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
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
                  color: Colors.white,
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

class _DropdownField extends StatelessWidget {
  const _DropdownField({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String? value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            labelStyle: TextStyle(color: Colors.white.withValues(alpha: 0.65)),
            filled: true,
            fillColor: Colors.white.withValues(alpha: 0.06),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
            ),
            suffixIcon: const Icon(Icons.arrow_drop_down, color: Colors.white70),
          ),
          child: Text(
            (value == null || value!.trim().isEmpty) ? 'Select…' : value!,
            style: TextStyle(
              color: (value == null || value!.trim().isEmpty)
                  ? Colors.white54
                  : Colors.white,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            labelStyle: TextStyle(color: Colors.white.withValues(alpha: 0.65)),
            filled: true,
            fillColor: Colors.white.withValues(alpha: 0.06),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
            ),
            suffixIcon:
                const Icon(Icons.calendar_today, color: Colors.white70, size: 18),
          ),
          child: Text(
            value,
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
        ),
      ),
    );
  }
}

class _AmountField extends StatelessWidget {
  const _AmountField({
    required this.label,
    required this.controller,
    required this.onChanged,
  });

  final String label;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
        ],
        style: const TextStyle(color: Colors.white),
        onChanged: onChanged,
        decoration: InputDecoration(
          labelText: label,
          prefixText: '₹ ',
          prefixStyle: const TextStyle(color: Colors.white),
          labelStyle: TextStyle(color: Colors.white.withValues(alpha: 0.65)),
          filled: true,
          fillColor: const Color(0xFF1B5E20).withValues(alpha: 0.25),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF4CAF50)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF4CAF50)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF66BB6A), width: 1.4),
          ),
        ),
      ),
    );
  }
}

class _ReadRow extends StatelessWidget {
  const _ReadRow(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 11,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: () => onChanged(!value),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              SizedBox(
                width: 28,
                height: 28,
                child: Checkbox(
                  value: value,
                  onChanged: (v) => onChanged(v ?? false),
                  activeColor: const Color(0xFFE07A2F),
                  side: BorderSide(
                    color: Colors.white.withValues(alpha: 0.55),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InvoiceMiniCard extends StatelessWidget {
  const _InvoiceMiniCard({required this.invoice});
  final ChequeLinkedInvoice invoice;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            invoice.number ?? '—',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Total ₹ ${ChequeClearanceModel.formatMoney(invoice.total)}'
            '  ·  Balance ₹ ${ChequeClearanceModel.formatMoney(invoice.balance)}'
            '  ·  ${invoice.status ?? '—'}',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.75),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.color,
    required this.onPressed,
  });

  final String label;
  final Color color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
        ),
      ),
    );
  }
}
