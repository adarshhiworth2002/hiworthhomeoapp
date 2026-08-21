import 'package:flutter/material.dart';

import '../../models/payment_book_model.dart';
import '../theme.dart';

class InvoiceSearchFilterResult {
  const InvoiceSearchFilterResult.apply(this.filter) : clear = false;

  const InvoiceSearchFilterResult.clearAll()
      : filter = const PaymentBookFilter(),
        clear = true;

  final PaymentBookFilter filter;
  final bool clear;
}

/// Shared Payment Book-style search sheet, with an Invoice field.
class InvoiceSearchFilterSheet extends StatefulWidget {
  const InvoiceSearchFilterSheet({
    super.key,
    required this.initialFilter,
    required this.parentContext,
    this.datesRequired = false,
    this.clearLabel = 'Clear',
  });

  final PaymentBookFilter initialFilter;
  final BuildContext parentContext;
  final bool datesRequired;
  final String clearLabel;

  @override
  State<InvoiceSearchFilterSheet> createState() =>
      _InvoiceSearchFilterSheetState();
}

class _InvoiceSearchFilterSheetState extends State<InvoiceSearchFilterSheet> {
  late final TextEditingController _customerController;
  late final TextEditingController _invoiceController;
  DateTime? _from;
  DateTime? _to;
  late PaymentBookCustomerType _customerType;
  late PaymentBookPaymentMode _paymentMode;

  @override
  void initState() {
    super.initState();
    final today = PaymentBookFilter.todayDate();
    _customerController =
        TextEditingController(text: widget.initialFilter.customerQuery);
    _invoiceController =
        TextEditingController(text: widget.initialFilter.invoiceQuery);
    _from = widget.initialFilter.dateFrom ??
        (widget.datesRequired ? today : null);
    _to = widget.initialFilter.dateTo ??
        (widget.datesRequired ? today : null);
    _customerType = widget.initialFilter.customerType;
    _paymentMode = widget.initialFilter.paymentMode;
  }

  @override
  void dispose() {
    _customerController.dispose();
    _invoiceController.dispose();
    super.dispose();
  }

  InputDecoration _fieldDecoration({
    required String label,
    required IconData icon,
  }) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Colors.black54),
      prefixIcon: Icon(icon, color: Colors.black54),
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: sectionCardBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: sectionCardBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: sectionAccent),
      ),
    );
  }

  Future<void> _pickDate({required bool isFrom}) async {
    FocusScope.of(context).unfocus();
    final picked = await showDatePicker(
      context: widget.parentContext,
      initialDate: (isFrom ? _from : _to) ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (isFrom) {
        _from = picked;
        if (_to != null && _to!.isBefore(_from!)) _to = _from;
      } else {
        _to = picked;
        if (_from != null && _from!.isAfter(_to!)) _from = _to;
      }
    });
  }

  String _formatPickerDate(DateTime date) {
    final d = date.day.toString().padLeft(2, '0');
    final m = date.month.toString().padLeft(2, '0');
    return '$d/$m/${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          12,
          20,
          20 + MediaQuery.paddingOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: sectionCardBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Text(
              'Search & filter',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: sectionText,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: sectionText,
                      side: BorderSide(color: sectionCardBorder),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () => _pickDate(isFrom: true),
                    icon: const Icon(Icons.calendar_today, size: 18),
                    label: Text(
                      _from == null
                          ? 'From date'
                          : 'From ${_formatPickerDate(_from!)}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: sectionText,
                      side: BorderSide(color: sectionCardBorder),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () => _pickDate(isFrom: false),
                    icon: const Icon(Icons.calendar_today, size: 18),
                    label: Text(
                      _to == null
                          ? 'To date'
                          : 'To ${_formatPickerDate(_to!)}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
            if (!widget.datesRequired) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Leave dates empty to show all dates.',
                  style: TextStyle(
                    color: sectionTextMuted,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _customerController,
              style: const TextStyle(color: sectionText, fontSize: 16),
              cursorColor: sectionAccent,
              textInputAction: TextInputAction.next,
              decoration: _fieldDecoration(
                label: 'Customer',
                icon: Icons.person_outline,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _invoiceController,
              style: const TextStyle(color: sectionText, fontSize: 16),
              cursorColor: sectionAccent,
              textInputAction: TextInputAction.done,
              decoration: _fieldDecoration(
                label: 'Invoice',
                icon: Icons.receipt_long_outlined,
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<PaymentBookCustomerType>(
              initialValue: _customerType,
              dropdownColor: Colors.white,
              iconEnabledColor: Colors.black,
              style: const TextStyle(color: Colors.black, fontSize: 16),
              decoration: _fieldDecoration(
                label: 'Customer Type',
                icon: Icons.groups_outlined,
              ),
              items: const [
                DropdownMenuItem(
                  value: PaymentBookCustomerType.all,
                  child: Text('All Customers',
                      style: TextStyle(color: Colors.black)),
                ),
                DropdownMenuItem(
                  value: PaymentBookCustomerType.credit,
                  child: Text('Credit Customers',
                      style: TextStyle(color: Colors.black)),
                ),
                DropdownMenuItem(
                  value: PaymentBookCustomerType.normal,
                  child: Text('Normal Customers',
                      style: TextStyle(color: Colors.black)),
                ),
                DropdownMenuItem(
                  value: PaymentBookCustomerType.b2b,
                  child: Text('B2B', style: TextStyle(color: Colors.black)),
                ),
                DropdownMenuItem(
                  value: PaymentBookCustomerType.b2c,
                  child: Text('B2C', style: TextStyle(color: Colors.black)),
                ),
              ],
              onChanged: (value) {
                if (value == null) return;
                setState(() => _customerType = value);
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<PaymentBookPaymentMode>(
              initialValue: _paymentMode,
              dropdownColor: Colors.white,
              iconEnabledColor: Colors.black,
              style: const TextStyle(color: Colors.black, fontSize: 16),
              decoration: _fieldDecoration(
                label: 'Payment Mode',
                icon: Icons.payments_outlined,
              ),
              items: const [
                DropdownMenuItem(
                  value: PaymentBookPaymentMode.all,
                  child: Text('All', style: TextStyle(color: Colors.black)),
                ),
                DropdownMenuItem(
                  value: PaymentBookPaymentMode.cash,
                  child: Text('Cash', style: TextStyle(color: Colors.black)),
                ),
                DropdownMenuItem(
                  value: PaymentBookPaymentMode.credit,
                  child: Text('Credit', style: TextStyle(color: Colors.black)),
                ),
                DropdownMenuItem(
                  value: PaymentBookPaymentMode.cheque,
                  child: Text('Cheque', style: TextStyle(color: Colors.black)),
                ),
                DropdownMenuItem(
                  value: PaymentBookPaymentMode.card,
                  child: Text('Card', style: TextStyle(color: Colors.black)),
                ),
                DropdownMenuItem(
                  value: PaymentBookPaymentMode.upi,
                  child: Text('UPI', style: TextStyle(color: Colors.black)),
                ),
              ],
              onChanged: (value) {
                if (value == null) return;
                setState(() => _paymentMode = value);
              },
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: sectionText,
                      side: BorderSide(color: sectionCardBorder),
                    ),
                    onPressed: () {
                      FocusScope.of(context).unfocus();
                      Navigator.pop(
                        context,
                        const InvoiceSearchFilterResult.clearAll(),
                      );
                    },
                    child: Text(widget.clearLabel),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: sectionAccent,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () {
                      FocusScope.of(context).unfocus();
                      Navigator.pop(
                        context,
                        InvoiceSearchFilterResult.apply(
                          PaymentBookFilter(
                            dateFrom: _from,
                            dateTo: _to,
                            customerQuery: _customerController.text,
                            invoiceQuery: _invoiceController.text,
                            customerType: _customerType,
                            paymentMode: _paymentMode,
                          ),
                        ),
                      );
                    },
                    child: const Text('Search'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
