import 'package:flutter/material.dart';

import '../../models/invoice_summary_model.dart';
import '../../models/qr_model.dart';
import '../services/invoice_calc_helper.dart';
import '../services/invoice_detail_service.dart';
import '../widgets/app_responsive.dart';
import '../widgets/system_safe.dart';
import 'add_to_customer.dart';
import 'customer_new_invoice_page.dart';
import '../theme.dart';

/// View-only customer invoice detail matching the Cash/Credit Tax Invoice screen.
/// When [supplierLayout] is true (You Gave), line items show Ordered / Received /
/// Free Qty instead of a single Qty — other invoice screens are unchanged.
class CustomerInvoiceDetailPage extends StatefulWidget {
  const CustomerInvoiceDetailPage({
    super.key,
    required this.invoice,
    this.title = 'Customer Invoice',
    this.partnerLabel = 'Customer',
    this.allowScan = true,
    this.supplierLayout = false,
  });

  final InvoiceSummaryModel invoice;
  final String title;
  /// Label for the partner row (Customer / Supplier).
  final String partnerLabel;
  final bool allowScan;
  /// You Gave only: show Ordered Qty, Received Qty, Free Qty on lines.
  final bool supplierLayout;

  @override
  State<CustomerInvoiceDetailPage> createState() =>
      _CustomerInvoiceDetailPageState();
}

class _CustomerInvoiceDetailPageState extends State<CustomerInvoiceDetailPage> {
  late InvoiceSummaryModel _invoice;
  bool _loadingLines = false;
  /// Optimistic lines shown until the server reload catches up.
  List<InvoiceLineModel>? _linesOverride;

  List<InvoiceLineModel> get _visibleLines =>
      _linesOverride ?? _invoice.lines;

  @override
  void initState() {
    super.initState();
    _invoice = widget.invoice;
    _loadingLines = true;
    _loadDetail();
  }

  Future<void> _loadDetail() async {
    final loaded = await InvoiceDetailService.fetchCustomerInvoice(
      context,
      seed: widget.invoice,
    );
    if (!mounted) return;
    setState(() {
      _invoice = loaded;
      _loadingLines = false;
      _linesOverride = null;
    });
  }

  void _applyScannedLine(QrData data, double qty, int? invoiceId) {
    final product = data.productName?.trim();
    final potency = data.potency?.trim();
    final batch = data.batch?.trim();

    final lines = List<InvoiceLineModel>.from(_visibleLines);
    final existingIndex = lines.indexWhere((line) {
      final sameProduct = (line.productName ?? '').trim().toLowerCase() ==
          (product ?? '').toLowerCase();
      final samePotency = (line.potency ?? '').trim().toLowerCase() ==
          (potency ?? '').toLowerCase();
      final sameBatch = (line.batch ?? '').trim().toLowerCase() ==
          (batch ?? '').toLowerCase();
      return sameProduct && samePotency && sameBatch && (product ?? '').isNotEmpty;
    });

    if (existingIndex >= 0) {
      final line = lines[existingIndex];
      final prevQty = line.qty ?? 0;
      lines[existingIndex] = InvoiceLineModel(
        id: line.id,
        productName: line.productName ?? product,
        potency: line.potency ?? potency,
        company: line.company ?? data.company,
        batch: line.batch ?? batch,
        manufacturer: line.manufacturer ?? data.mfd,
        mfd: line.mfd ?? data.mfd,
        expiry: line.expiry ?? data.expiry,
        packing: line.packing ?? data.packing,
        group: line.group ?? data.group,
        qty: prevQty + qty,
        orderedQty: line.orderedQty,
        freeQty: line.freeQty,
        mrp: line.mrp ?? data.mrp,
        discount: line.discount,
        dis2Percent: line.dis2Percent,
        unit: line.unit,
        unitPrice: line.unitPrice ?? data.unitPrice,
        uPrice: line.uPrice ?? data.unitPrice,
        tax: line.tax ?? data.tax,
        taxAmount: line.taxAmount,
        total: line.total,
        hsn: line.hsn ?? data.hsn,
        rack: line.rack ?? data.rack,
      );
    } else {
      lines.add(
        InvoiceLineModel(
          productName: product,
          potency: potency,
          company: data.company,
          batch: batch,
          manufacturer: data.mfd,
          mfd: data.mfd,
          expiry: data.expiry,
          packing: data.packing,
          group: data.group,
          qty: qty,
          mrp: data.mrp,
          unitPrice: data.unitPrice,
          uPrice: data.unitPrice,
          tax: data.tax,
          hsn: data.hsn,
          rack: data.rack,
        ),
      );
    }

    setState(() {
      if (invoiceId != null && _invoice.id == null) {
        _invoice = InvoiceSummaryModel(
          id: invoiceId,
          invoiceNumber: _invoice.invoiceNumber,
          customer: _invoice.customer,
          pharmacyCustomerId: _invoice.pharmacyCustomerId,
          address: _invoice.address,
          phone: _invoice.phone,
          responsiblePerson: _invoice.responsiblePerson,
          doctor: _invoice.doctor,
          invoiceDate: _invoice.invoiceDate,
          expiryMedicineBill: _invoice.expiryMedicineBill,
          verifyStatus: _invoice.verifyStatus,
          billedBy: _invoice.billedBy,
          taxAmount: _invoice.taxAmount,
          balance: _invoice.balance,
          subtotal: _invoice.subtotal,
          discountTotal: _invoice.discountTotal,
          total: _invoice.total,
          supplierInvoiceNo: _invoice.supplierInvoiceNo,
          poNumber: _invoice.poNumber,
          supplierInvoiceAmount: _invoice.supplierInvoiceAmount,
          previousInvoice: _invoice.previousInvoice,
          deliveryDate: _invoice.deliveryDate,
          status: _invoice.status,
          moveState: _invoice.moveState,
          paymentState: _invoice.paymentState,
          isPaid: _invoice.isPaid,
          paymentMode: _invoice.paymentMode,
          gstType: _invoice.gstType,
          discountCategory: _invoice.discountCategory,
          discountType: _invoice.discountType,
          discountRate: _invoice.discountRate,
          verifiedBy: _invoice.verifiedBy,
          expense: _invoice.expense,
          expenseAmt: _invoice.expenseAmt,
          remarks: _invoice.remarks,
          workMinutes: _invoice.workMinutes,
          workHours: _invoice.workHours,
          isCreditCustomer: _invoice.isCreditCustomer,
          lines: _invoice.lines,
        );
      }
      _linesOverride = lines;
    });
  }

  InvoiceCalcResult _visibleTotals() {
    if (_linesOverride == null) return _invoice.websiteTotals();
    return InvoiceSummaryModel(
      discountType: _invoice.discountType,
      discountRate: _invoice.discountRate,
      gstType: _invoice.gstType,
      expenseAmt: _invoice.expenseAmt,
      lines: _linesOverride!,
    ).websiteTotals();
  }

  Future<void> _reloadDetailAfterAdd() async {
    final expectedMin = _visibleLines.length;
    for (var attempt = 0; attempt < 4; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(Duration(milliseconds: 300 * attempt));
      }
      final loaded = await InvoiceDetailService.fetchCustomerInvoice(
        context,
        seed: _invoice,
      );
      if (!mounted) return;
      if (loaded.lines.length >= expectedMin) {
        setState(() {
          _invoice = loaded;
          _linesOverride = null;
          _loadingLines = false;
        });
        return;
      }
    }
  }

  Future<void> _openScanner() async {
    if (_invoice.sectionKey == 'paid') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This bill is paid. Scanning is not allowed.'),
        ),
      );
      return;
    }
    final number = _invoice.displayNumber;
    final result = await AddToCustomerPage.showPopup(
      context,
      lockedInvoiceNumber: number == 'Unknown' ? null : number,
    );
    if (result != null && mounted) {
      _applyScannedLine(result.data, result.qty, result.invoiceId);
      await _reloadDetailAfterAdd();
    }
  }

  Future<void> _openEdit() async {
    final key = _invoice.sectionKey;
    if (key != 'draft' && key != 'open') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only Draft or Open bills can be edited')),
      );
      return;
    }
    // Ensure lines are loaded before editing.
    if (_loadingLines) {
      await _loadDetail();
    }
    if (!mounted) return;
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => CustomerNewInvoicePage(
          editInvoice: _invoice,
        ),
      ),
    );
    if (!mounted) return;
    if (saved == true) {
      setState(() => _loadingLines = true);
      await _loadDetail();
    }
  }

  static String _formatGstType(String? value) {
    final raw = (value ?? '').trim();
    if (raw.isEmpty) return 'GST MINUS';
    final lower = raw.toLowerCase();
    if (lower == 'minus' || lower == 'gst minus' || lower == 'gst_minus') {
      return 'GST MINUS';
    }
    if (lower == 'plus' || lower == 'gst plus' || lower == 'gst_plus') {
      return 'GST PLUS';
    }
    return raw.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final status = _invoice.displayStatus;
    final canScan = widget.allowScan && _invoice.sectionKey != 'paid';
    final canEdit = !widget.supplierLayout &&
        (_invoice.sectionKey == 'draft' || _invoice.sectionKey == 'open');
    final totals = _visibleTotals();
    final showSupplierQty = widget.supplierLayout;

    return Scaffold(
      backgroundColor: sectionBg,
      appBar: AppBar(
        iconTheme: const IconThemeData(color: sectionText),
        title: Text(
          widget.title,
          style: const TextStyle(
            color: sectionText,
            fontWeight: FontWeight.w500,
            fontSize: 15,
          ),
        ),
        backgroundColor: sectionBg,
        elevation: 0,
        actions: [
          if (canEdit)
            IconButton(
              tooltip: 'Edit bill',
              onPressed: _loadingLines ? null : _openEdit,
              icon: const Icon(Icons.edit_outlined, color: sectionText),
            ),
          if (canScan)
            IconButton(
              tooltip: 'Scan QR into this bill',
              onPressed: _openScanner,
              icon: const Icon(Icons.qr_code_scanner, color: sectionText),
            ),
        ],
      ),
      body: ResponsiveBody(
        child: RefreshIndicator(
        color: const Color(0xFFE07A2F),
        onRefresh: () async {
          setState(() => _loadingLines = true);
          await _loadDetail();
        },
        child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: SystemSafe.listPadding(context),
        children: [
          Row(
            children: [
              _StatusChip(label: 'Draft', selected: status.toLowerCase() == 'draft'),
              const SizedBox(width: 8),
              _StatusChip(
                label: 'Open',
                selected: status.toLowerCase() == 'open',
              ),
              const SizedBox(width: 8),
              _StatusChip(
                label: 'Paid',
                selected: status.toLowerCase() == 'paid',
              ),
            ],
          ),
          const SizedBox(height: 14),
          Center(
            child: Text(
              showSupplierQty ? 'SUPPLIER INVOICE' : 'CASH/CREDIT TAX INVOICE',
              style: const TextStyle(
                color: Color(0xFFE53935),
                fontWeight: FontWeight.w800,
                fontSize: 15,
                letterSpacing: 0.3,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  _invoice.displayNumber,
                  style: const TextStyle(
                    color: Color(0xFFFFCDD2),
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
              ),
              Text(
                _formatDate(_invoice.invoiceDate),
                style: const TextStyle(color: sectionTextMuted, fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _SectionCard(
            child: Column(
              children: [
                _ReadField(widget.partnerLabel, _invoice.displayCustomer),
                _ReadField('Address', _invoice.address),
                _ReadField('Phone No', _invoice.phone),
                _ReadField('Responsible Person', _invoice.responsiblePerson),
                _ReadField('Doctor', _invoice.doctor),
                _ReadField('Payment Mode', _invoice.paymentMode ?? 'Cash'),
                _ReadField(
                  'GST type',
                  _formatGstType(_invoice.gstType),
                ),
                _ReadField(
                  'Expiry Medicine Bill',
                  _invoice.expiryMedicineBill ? 'Yes' : 'No',
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _SectionCard(
            title: 'Invoice Lines',
            child: _loadingLines
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFFE07A2F),
                        ),
                      ),
                    ),
                  )
                : _visibleLines.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          'No line items loaded for this bill.',
                          style: TextStyle(color: sectionTextMuted, fontSize: 12),
                        ),
                      )
                    : Column(
                        children: _visibleLines
                            .map(
                              (line) => _LineTile(
                                line: line,
                                showSupplierQty: showSupplierQty,
                              ),
                            )
                            .toList(),
                      ),
          ),
          const SizedBox(height: 12),
          _SectionCard(
            child: Column(
              children: [
                _ReadField('Discount Category', _invoice.discountCategory),
                _ReadField('Discount Type', _invoice.discountType ?? 'Percentage'),
                _ReadField(
                  'Discount Rate (%)',
                  InvoiceSummaryModel.formatMoney(_invoice.discountRate ?? 0),
                ),
                _ReadField('Billed By', _invoice.billedBy),
                _ReadField('Status', status),
                _ReadField('Verified By', _invoice.verifiedBy),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _SectionCard(
            child: Column(
              children: [
                _MoneyRow('Subtotal', totals.subtotal),
                _MoneyRow('Discount Total', totals.discountTotal),
                _MoneyRow('Tax', totals.tax),
                _MoneyRow('Tax Amount', totals.taxAmount),
                _MoneyRow('Expense Amt', totals.expenseAmt),
                _MoneyRow('Total', totals.total, emphasize: true),
                _MoneyRow('Balance', totals.balance, emphasize: true),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _SectionCard(
            child: _ReadField('Remarks', _invoice.remarks ?? ''),
          ),
          const SizedBox(height: 10),
          Text(
            canEdit
                ? 'Tap Edit to change customer and bill details.'
                : 'View mode only — editing actions are disabled.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: sectionTextMuted,
              fontSize: 11,
            ),
          ),
        ],
      ),
      ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.selected});

  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: selected
              ? sectionAccent
              : Colors.black.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selected) ...[
            const Icon(Icons.check, size: 14, color: sectionAccent),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: const TextStyle(
              color: Colors.black,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.child, this.title});

  final Widget child;
  final String? title;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: sectionCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: sectionCardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Text(
              title!,
              style: const TextStyle(
                color: sectionText,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 10),
          ],
          child,
        ],
      ),
    );
  }
}

class _ReadField extends StatelessWidget {
  const _ReadField(this.label, this.value);

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(
                color: sectionTextMuted,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Text(
              (value == null || value!.trim().isEmpty) ? '—' : value!,
              style: const TextStyle(color: sectionText, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _MoneyRow extends StatelessWidget {
  const _MoneyRow(this.label, this.value, {this.emphasize = false});

  final String label;
  final double? value;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: sectionTextMuted,
                fontSize: 12,
              ),
            ),
          ),
          Text(
            InvoiceSummaryModel.formatMoney(value),
            style: TextStyle(
              color: sectionText,
              fontSize: emphasize ? 15 : 12,
              fontWeight: emphasize ? FontWeight.w800 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _LineTile extends StatelessWidget {
  const _LineTile({
    required this.line,
    this.showSupplierQty = false,
  });

  final InvoiceLineModel line;
  /// You Gave only: Ordered / Received / Free Qty instead of single Qty.
  final bool showSupplierQty;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: appOrangeSoft,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            line.productName ?? 'Product',
            style: const TextStyle(
              color: sectionText,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 8),
          _LineRow(
            left: _Field('Potency', line.potency),
            right: _Field('Company', line.company),
          ),
          _LineRow(
            left: _Field('BATCH', line.batch),
            right: _Field('MFD', line.mfd ?? line.manufacturer),
          ),
          _LineRow(
            left: _Field('EXPIRY', line.expiry),
            right: _Field('Pack', line.packing),
          ),
          if (showSupplierQty) ...[
            _LineRow(
              left: _Field('Ordered Qty', _qty(line.orderedQty)),
              right: _Field('Received Qty', _qty(line.receivedQty)),
            ),
            _LineRow(
              left: _Field('Free Qty', _qty(line.freeQty)),
              right: _Field('Group', line.group),
            ),
          ] else
            _LineRow(
              left: _Field('Group', line.group),
              right: _Field('Qty', _num(line.qty)),
            ),
          _LineRow(
            left: _Field('Mrp', _money(line.mrp)),
            right: _Field('Dis', _num(line.discount)),
          ),
          _LineRow(
            left: _Field('Unit P', _money(line.unitPrice)),
            right: _Field('Tax', _num(line.tax)),
          ),
          _LineRow(
            left: _Field('Tax Amt', _money(line.taxAmount)),
            right: _Field('Total', _money(line.total), emphasize: true),
          ),
          _LineRow(
            left: _Field('Hsn', line.hsn),
            right: _Field('Rack', line.rack),
          ),
        ],
      ),
    );
  }

  static String _money(double? v) => InvoiceSummaryModel.formatMoney(v);
  static String _num(double? v) =>
      v == null ? '—' : v.toStringAsFixed(v == v.roundToDouble() ? 0 : 2);
  static String _qty(double? v) =>
      v == null ? '—' : v.toStringAsFixed(2);
}

class _LineRow extends StatelessWidget {
  const _LineRow({required this.left, required this.right});

  final _Field left;
  final _Field right;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(child: left),
          const SizedBox(width: 8),
          Expanded(child: right),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field(this.label, this.value, {this.emphasize = false});

  final String label;
  final String? value;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    final text = (value == null || value!.trim().isEmpty) ? '—' : value!;
    return RichText(
      text: TextSpan(
        style: TextStyle(
          color: sectionTextMuted,
          fontSize: 10,
        ),
        children: [
          TextSpan(text: '$label: '),
          TextSpan(
            text: text,
            style: TextStyle(
              color: sectionText,
              fontWeight: emphasize ? FontWeight.w700 : FontWeight.w500,
              fontSize: emphasize ? 12 : 11,
            ),
          ),
        ],
      ),
    );
  }
}

String _formatDate(String? value) {
  if (value == null || value.trim().isEmpty) return '—';
  final parsed = DateTime.tryParse(value.trim());
  if (parsed == null) return value.trim();
  final month = parsed.month.toString().padLeft(2, '0');
  final day = parsed.day.toString().padLeft(2, '0');
  return '$month/$day/${parsed.year}';
}
