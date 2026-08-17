import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/invoice_summary_model.dart';
import '../../models/payment_book_model.dart';
import '../../viewModels/payment_book_viewmodel.dart';
import '../theme.dart';
import '../widgets/app_responsive.dart';
import '../widgets/system_safe.dart';
import 'invoice_list_widgets.dart';
import 'live_refresh_mixin.dart';
import 'payment_book_detail_page.dart';

class PaymentBookPage extends StatefulWidget {
  const PaymentBookPage({super.key});

  @override
  State<PaymentBookPage> createState() => _PaymentBookPageState();
}

class _PaymentBookPageState extends State<PaymentBookPage>
    with LiveRefreshMixin {
  late final PaymentBookViewModel _viewModel;

  @override
  void initState() {
    super.initState();
    _viewModel = PaymentBookViewModel();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _viewModel.fetch(
        context,
        applyFilter: PaymentBookFilter.today(),
      );
      if (!mounted) return;
      await _viewModel.fetch(context, forceRefresh: true, silent: true);
    });
    startLiveRefresh(
      () => _viewModel.fetch(context, forceRefresh: true, silent: true),
    );
  }

  @override
  void dispose() {
    stopLiveRefresh();
    _viewModel.dispose();
    super.dispose();
  }

  Future<void> _openFilter() async {
    final result = await showModalBottomSheet<_PaymentBookFilterResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: sectionBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => _PaymentBookFilterSheet(
        initialFilter: _viewModel.filter,
        parentContext: context,
      ),
    );
    if (!mounted || result == null) return;

    if (result.clear) {
      await _viewModel.resetToToday(context);
      return;
    }

    await _viewModel.fetch(
      context,
      forceRefresh: true,
      applyFilter: result.filter,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _viewModel,
      child: Scaffold(
        backgroundColor: sectionBg,
        appBar: AppBar(
          iconTheme: const IconThemeData(color: sectionText),
          title: const Text(
            'Payment Book',
            style: TextStyle(
              color: sectionText,
              fontWeight: FontWeight.w500,
              fontSize: 15,
            ),
          ),
          backgroundColor: sectionBg,
          elevation: 0,
          actions: [
            IconButton(
              tooltip: 'Filter',
              onPressed: _openFilter,
              icon: const Icon(Icons.filter_list, color: sectionText),
            ),
            IconButton(
              onPressed: () => _viewModel.fetch(context, forceRefresh: true),
              icon: const Icon(Icons.refresh, color: sectionText),
            ),
          ],
        ),
        body: ResponsiveBody(
          child: Consumer<PaymentBookViewModel>(
          builder: (context, model, _) {
            if (model.loading && model.invoices.isEmpty) {
              return const Center(
                child: CircularProgressIndicator(color: Color(0xFFE07A2F)),
              );
            }
            if (model.error.isNotEmpty && model.invoices.isEmpty) {
              return InvoiceListError(
                message: model.error,
                onRetry: () => model.fetch(context, forceRefresh: true),
              );
            }

            final filtered = model.visibleInvoices;
            final visibleTotal = filtered.fold<double>(
              0,
              (sum, item) => sum + (item.total ?? 0),
            );
            final visibleBalance = filtered.fold<double>(
              0,
              (sum, item) => sum + (item.balance ?? 0),
            );
            final footerTotal = visibleTotal;
            final footerBalance = visibleBalance;

            return Column(
              children: [
                _SummaryBar(model: model),
                Expanded(
                  child: RefreshIndicator(
                    color: const Color(0xFFE07A2F),
                    onRefresh: () =>
                        model.fetch(context, forceRefresh: true),
                    child: filtered.isEmpty
                        ? ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            children: [
                              SizedBox(
                                height:
                                    MediaQuery.sizeOf(context).height * 0.35,
                                child: const Center(
                                  child: Text(
                                    'No payment book entries found',
                                    style: TextStyle(color: sectionTextMuted),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ),
                            ],
                          )
                        : ListView.separated(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: SystemSafe.listPadding(
                              context,
                              top: 0,
                              extraBottom: 88,
                            ),
                            itemCount: filtered.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final item = filtered[index];
                              return _PaymentBookCard(
                                invoice: item,
                                onTap: () => openPaymentBookDetail(
                                  context,
                                  item,
                                ),
                                onOpenBill: () => openInvoiceDetail(
                                  context,
                                  item,
                                  title: 'Customer Invoice',
                                ),
                              );
                            },
                          ),
                  ),
                ),
                _TotalFooter(
                  count: filtered.length,
                  total: footerTotal,
                  balance: footerBalance,
                ),
              ],
            );
          },
        ),
        ),
      ),
    );
  }
}

class _SummaryBar extends StatelessWidget {
  const _SummaryBar({required this.model});

  final PaymentBookViewModel model;

  @override
  Widget build(BuildContext context) {
    final from = PaymentBookViewModel.formatDisplayDate(model.filter.dateFrom);
    final to = PaymentBookViewModel.formatDisplayDate(model.filter.dateTo);
    final range = from == to ? from : '$from  →  $to';
    final parts = <String>[range];
    if (model.filter.hasCustomer) {
      parts.add(model.filter.customerQuery.trim());
    }
    if (model.filter.hasCustomerType) {
      parts.add(model.filter.customerTypeLabel);
    }
    if (model.filter.hasPaymentMode) {
      parts.add(model.filter.paymentModeLabel);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: sectionCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: sectionCardBorder),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.filter_alt_outlined,
              size: 14,
              color: Color(0xFFE07A2F),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                parts.join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: sectionText,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Two-line dark card — same feel as other home sections.
class _PaymentBookCard extends StatelessWidget {
  const _PaymentBookCard({
    required this.invoice,
    required this.onTap,
    required this.onOpenBill,
  });

  final InvoiceSummaryModel invoice;
  final VoidCallback onTap;
  final VoidCallback onOpenBill;

  static Color _rowColor(PaymentBookRowStyle style) {
    switch (style) {
      case PaymentBookRowStyle.walkIn:
        return const Color(0xFFD32F2F);
      case PaymentBookRowStyle.creditOpen:
        return const Color(0xFF111111);
      case PaymentBookRowStyle.creditPaid:
        return const Color(0xFF1565C0);
      case PaymentBookRowStyle.draft:
        return const Color(0xFF9E9E9E);
      case PaymentBookRowStyle.normal:
        return sectionText;
    }
  }

  static FontWeight _rowWeight(PaymentBookRowStyle style) {
    switch (style) {
      case PaymentBookRowStyle.creditOpen:
        return FontWeight.w800;
      case PaymentBookRowStyle.draft:
        return FontWeight.w400;
      default:
        return FontWeight.w600;
    }
  }

  @override
  Widget build(BuildContext context) {
    final style = invoice.paymentBookRowStyle;
    final color = _rowColor(style);
    final weight = _rowWeight(style);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
          decoration: BoxDecoration(
            color: sectionCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: sectionCardBorder),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: Text(
                            invoice.displayNumber,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: color,
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 4,
                          child: Text(
                            invoice.displayPaymentBookName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: color,
                              fontSize: 12,
                              fontWeight: weight,
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(
                            invoice.displayPaymentBookStatus,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              color: color,
                              fontSize: 11,
                              fontWeight: weight,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: _Meta(
                            'Balance',
                            InvoiceSummaryModel.formatMoney(invoice.balance),
                            color: color,
                            weight: weight,
                          ),
                        ),
                        Expanded(
                          child: _Meta(
                            'Total',
                            InvoiceSummaryModel.formatMoney(invoice.total),
                            color: color,
                            weight: FontWeight.w800,
                          ),
                        ),
                        Expanded(
                          child: _Meta(
                            'Date',
                            invoice.displayPaymentBookDate,
                            color: color,
                            weight: weight,
                            alignEnd: true,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Open invoice',
                onPressed: onOpenBill,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                icon: const Icon(
                  Icons.receipt_long_outlined,
                  color: Color(0xFFE07A2F),
                  size: 22,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta(
    this.label,
    this.value, {
    required this.color,
    required this.weight,
    this.alignEnd = false,
  });

  final String label;
  final String value;
  final Color color;
  final FontWeight weight;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment:
          alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: sectionTextMuted,
            fontSize: 9,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: weight,
          ),
        ),
      ],
    );
  }
}

class _TotalFooter extends StatelessWidget {
  const _TotalFooter({
    required this.count,
    required this.total,
    required this.balance,
  });

  final int count;
  final double total;
  final double balance;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        AppResponsive.of(context).pagePadding,
        12,
        AppResponsive.of(context).pagePadding,
        SystemSafe.actionBarBottomPadding(context),
      ),
      decoration: BoxDecoration(
        color: sectionFooter,
        border: Border(
          top: BorderSide(color: sectionCardBorder),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              count == 1 ? 'Total (1 bill)' : 'Total ($count bills)',
              style: TextStyle(
                color: sectionTextMuted,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                'Balance  ${InvoiceSummaryModel.formatMoney(balance)}',
                style: TextStyle(
                  color: sectionTextMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                InvoiceSummaryModel.formatMoney(total),
                style: const TextStyle(
                  color: Color(0xFFE07A2F),
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PaymentBookFilterResult {
  const _PaymentBookFilterResult.apply(this.filter) : clear = false;

  const _PaymentBookFilterResult.clearAll()
      : filter = const PaymentBookFilter(),
        clear = true;

  final PaymentBookFilter filter;
  final bool clear;
}

class _PaymentBookFilterSheet extends StatefulWidget {
  const _PaymentBookFilterSheet({
    required this.initialFilter,
    required this.parentContext,
  });

  final PaymentBookFilter initialFilter;
  final BuildContext parentContext;

  @override
  State<_PaymentBookFilterSheet> createState() =>
      _PaymentBookFilterSheetState();
}

class _PaymentBookFilterSheetState extends State<_PaymentBookFilterSheet> {
  late final TextEditingController _customerController;
  late DateTime _from;
  late DateTime _to;
  late PaymentBookCustomerType _customerType;
  late PaymentBookPaymentMode _paymentMode;

  @override
  void initState() {
    super.initState();
    final today = PaymentBookFilter.todayDate();
    _customerController =
        TextEditingController(text: widget.initialFilter.customerQuery);
    _from = widget.initialFilter.dateFrom ?? today;
    _to = widget.initialFilter.dateTo ?? today;
    _customerType = widget.initialFilter.customerType;
    _paymentMode = widget.initialFilter.paymentMode;
  }

  @override
  void dispose() {
    _customerController.dispose();
    super.dispose();
  }

  InputDecoration _fieldDecoration({
    required String label,
    required IconData icon,
    Color fillColor = Colors.white,
  }) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Colors.black54),
      prefixIcon: Icon(icon, color: Colors.black54),
      filled: true,
      fillColor: fillColor,
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
      initialDate: isFrom ? _from : _to,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (isFrom) {
        _from = picked;
        if (_to.isBefore(_from)) _to = _from;
      } else {
        _to = picked;
        if (_from.isAfter(_to)) _from = _to;
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
                fontSize: 16,
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
                      side: BorderSide(
                        color: sectionCardBorder,
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () => _pickDate(isFrom: true),
                    icon: const Icon(Icons.calendar_today, size: 18),
                    label: Text(
                      'From ${_formatPickerDate(_from)}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: sectionText,
                      side: BorderSide(
                        color: sectionCardBorder,
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () => _pickDate(isFrom: false),
                    icon: const Icon(Icons.calendar_today, size: 18),
                    label: Text(
                      'To ${_formatPickerDate(_to)}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _customerController,
              style: const TextStyle(color: sectionText, fontSize: 14),
              cursorColor: sectionAccent,
              textInputAction: TextInputAction.done,
              decoration: _fieldDecoration(
                label: 'Customer',
                icon: Icons.person_outline,
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<PaymentBookCustomerType>(
              initialValue: _customerType,
              dropdownColor: Colors.white,
              iconEnabledColor: Colors.black,
              style: const TextStyle(color: Colors.black, fontSize: 14),
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
              style: const TextStyle(color: Colors.black, fontSize: 14),
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
                      side: BorderSide(
                        color: sectionCardBorder,
                      ),
                    ),
                    onPressed: () {
                      FocusScope.of(context).unfocus();
                      Navigator.pop(
                        context,
                        const _PaymentBookFilterResult.clearAll(),
                      );
                    },
                    child: const Text('Reset today'),
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
                        _PaymentBookFilterResult.apply(
                          PaymentBookFilter(
                            dateFrom: _from,
                            dateTo: _to,
                            customerQuery: _customerController.text,
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
