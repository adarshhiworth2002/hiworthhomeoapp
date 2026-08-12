import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../viewModels/customer_med_viewModel.dart';
import '../../models/qr_model.dart';
import '../services/invoice_helper.dart';
import '../services/label_ocr_service.dart';
import 'label_camera_page.dart';
import 'label_text_select_page.dart';
import '../widgets/invoice_prefix_field.dart';
import '../widgets/show_dialog_custom.dart';
import '../widgets/system_safe.dart';

/// Returned when [AddToCustomerPage.showPopup] closes after a successful add.
class AddToCustomerResult {
  const AddToCustomerResult({
    required this.data,
    required this.qty,
    this.invoiceId,
  });

  final QrData data;
  final double qty;
  final int? invoiceId;
}

class AddToCustomerPage extends StatefulWidget {
  const AddToCustomerPage({
    super.key,
    this.lockedInvoiceNumber,
    this.asPopup = false,
    this.onAdded,
  });

  /// When set (e.g. from invoice detail), medicine is always added to this bill.
  final String? lockedInvoiceNumber;

  /// Compact chrome for dialog / bottom-sheet use.
  final bool asPopup;

  /// Called after a successful add_to_invoice so the parent bill can show the line.
  /// [invoiceId] is the Odoo `account.move` id (needed because draft `name` is `/`).
  final void Function(QrData data, double qty, int? invoiceId)? onAdded;

  /// Opens the Add-to-Customer scanner as a popup (does not replace other screens).
  static Future<AddToCustomerResult?> showPopup(
    BuildContext context, {
    String? lockedInvoiceNumber,
    void Function(QrData data, double qty, int? invoiceId)? onAdded,
  }) {
    return showDialog<AddToCustomerResult?>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        final size = MediaQuery.sizeOf(ctx);
        return Dialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
          backgroundColor: Colors.transparent,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              width: size.width,
              height: size.height * 0.88,
              child: AddToCustomerPage(
                lockedInvoiceNumber: lockedInvoiceNumber,
                asPopup: true,
                onAdded: onAdded,
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  State<AddToCustomerPage> createState() => _AddToCustomerPageState();
}

class _AddToCustomerPageState extends State<AddToCustomerPage> {
  MobileScannerController cameraController = MobileScannerController();

  bool hasPermission = false;
  String medicineName = "";
  int totalQty = 0;
  int requiredQty = 0;
  TextEditingController requiredQtyController = TextEditingController();
  TextEditingController invoicePrefixController = TextEditingController();
  bool _fetchInProgress = false;
  bool _labelOcrInProgress = false;

  bool get _invoiceLocked =>
      (widget.lockedInvoiceNumber ?? '').trim().isNotEmpty;

  @override
  void dispose() {
    requiredQtyController.dispose();
    invoicePrefixController.dispose();
    cameraController.dispose();
    super.dispose();
  }

  String get _fullInvoiceNumber {
    final locked = (widget.lockedInvoiceNumber ?? '').trim();
    if (locked.contains('/')) return locked;
    if (locked.isNotEmpty) {
      return InvoiceHelper.formatFull(InvoiceHelper.prefixFromFull(locked));
    }
    return InvoiceHelper.formatFull(invoicePrefixController.text);
  }

  Future<void> _finishSuccessfulAdd({
    required QrData data,
    required double qty,
    int? invoiceId,
  }) async {
    widget.onAdded?.call(data, qty, invoiceId);
    await StatusDialog.show(
      context: context,
      title: 'Success',
      message: 'Medicine quantity added',
      type: StatusType.success,
    );
    try {
      await cameraController.stop();
    } catch (_) {}
    if (!context.mounted) return;
    Navigator.of(context).maybePop(
      AddToCustomerResult(data: data, qty: qty, invoiceId: invoiceId),
    );
  }

  @override
  void initState() {
    super.initState();

    final locked = (widget.lockedInvoiceNumber ?? '').trim();
    if (locked.isNotEmpty) {
      invoicePrefixController.text = InvoiceHelper.prefixFromFull(locked);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      requestCamera();
      final model = Provider.of<CustomerMedViewmodel>(context, listen: false);
      model.resetAllScan();
    });
  }

  Future<void> refreshScanner({bool keepInvoice = false}) async {
    final model = Provider.of<CustomerMedViewmodel>(context, listen: false);
    model.resetAllScan();
    requiredQtyController.clear();
    _fetchInProgress = false;
    _labelOcrInProgress = false;
    if (!keepInvoice && !_invoiceLocked) {
      invoicePrefixController.clear();
    }
    try {
      await cameraController.stop();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;
      await cameraController.start();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('refreshScanner: $e');
      }
    }
    if (mounted) setState(() {});
  }

  void stopScanner() {
    cameraController.stop();
  }

  Future<void> requestCamera() async {
    final status = await Permission.camera.request();
    if (status.isGranted) {
      setState(() => hasPermission = true);
    } else {
      setState(() => hasPermission = false);
      if (status.isPermanentlyDenied) openAppSettings();
    }
  }

  bool _isQrScanSuccessful(CustomerMedViewmodel model) {
    return model.qrValue.isNotEmpty &&
        !model.qrFetchLoading &&
        model.qrFetchError.isEmpty &&
        model.qrResponse?.result?.data != null;
  }

  bool _isLabelScanSuccessful(CustomerMedViewmodel model) {
    return model.labelScanActive && !model.labelNotFound;
  }

  bool _isScanSuccessful(CustomerMedViewmodel model) {
    return _isQrScanSuccessful(model) || _isLabelScanSuccessful(model);
  }

  Future<void> _scanLabelFromCamera() async {
    if (_labelOcrInProgress) return;

    setState(() => _labelOcrInProgress = true);
    final model = Provider.of<CustomerMedViewmodel>(context, listen: false);
    model.resetQr();

    var restartScanner = false;
    try {
      restartScanner = cameraController.value.isRunning;
      if (restartScanner) {
        await cameraController.stop();
      }

      if (!mounted) return;

      final bytes = await LabelCameraPage.capture(context);
      if (!mounted || bytes == null) return;

      final selectedText = await LabelTextSelectPage.show(
        context,
        imageBytes: bytes,
        recognitionFuture: LabelOcrService.recognizeImageBytesDetailed(bytes),
      );

      if (!mounted || selectedText == null || selectedText.trim().isEmpty) {
        return;
      }

      await model.applyLabelOcrText(context, selectedText.trim());
      if (mounted && _isLabelScanSuccessful(model)) {
        restartScanner = false;
        await cameraController.stop();
      }
    } catch (e, s) {
      if (kDebugMode) debugPrint('label OCR: $e\n$s');
      if (mounted) {
        await StatusDialog.show(
          context: context,
          title: 'Scan failed',
          message: 'Could not read the label. Try again with better lighting.',
          type: StatusType.error,
        );
      }
    } finally {
      if (mounted && restartScanner && !_isScanSuccessful(model)) {
        try {
          await cameraController.start();
        } catch (e) {
          if (kDebugMode) debugPrint('label scan restart camera: $e');
        }
      }
      if (mounted) {
        setState(() => _labelOcrInProgress = false);
      }
    }
  }

  Future<void> fetchData(String code) async {
    if (_fetchInProgress) return;
    _fetchInProgress = true;

    final model = Provider.of<CustomerMedViewmodel>(context, listen: false);
    model.resetLabelScan();
    model.setQrValue(code);
    requiredQtyController.clear();

    try {
      await model.fetchQrDetails(context);
      if (mounted && _isScanSuccessful(model)) {
        cameraController.stop();
      }
    } finally {
      _fetchInProgress = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      appBar: AppBar(
        iconTheme: const IconThemeData(color: Colors.white),
        automaticallyImplyLeading: !widget.asPopup,
        leading: widget.asPopup
            ? IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.of(context).maybePop(),
              )
            : null,
        title: Text(
          _invoiceLocked ? 'Scan into bill' : 'Add to Customer',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w500,
            fontSize: 15,
          ),
        ),
        backgroundColor: const Color(0xFF1A1A1A),
        elevation: 0,
        actions: [
          GestureDetector(
            onTap: () => refreshScanner(keepInvoice: _invoiceLocked),
            child: Padding(
              padding: const EdgeInsets.only(right: 16.0),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2), // semi-transparent glass
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.white.withOpacity(0.3),
                        width: 1.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.2),
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child:
                    Padding(
                      padding: const EdgeInsets.all(3.0),
                      child: const Icon(Icons.refresh, color: const Color(0xFFE07A2F)),
                    ),


                  ),
                ),
              ),
            ),
          ),
          GestureDetector(onTap: stopScanner,
            child: Padding(
              padding: const EdgeInsets.only(right: 16.0),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2), // semi-transparent glass
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.white.withOpacity(0.3),
                        width: 1.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.2),
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child:
                    Padding(
                      padding: const EdgeInsets.all(3.0),
                      child: const Icon(Icons.stop_circle, color: const Color(0xFFE07A2F)),
                    ),


                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      body: !hasPermission
          ? const Center(
              child: Text(
                "Camera permission required",
                style: TextStyle(color: Colors.white, fontSize: 16),
              ),
            )
          : SafeArea(
              child: Consumer<CustomerMedViewmodel>(
                builder: (context, viewModel, _) {
                  final scanSuccess = _isScanSuccessful(viewModel);
                  final showScanner = !scanSuccess &&
                      !viewModel.labelOcrLoading &&
                      !_labelOcrInProgress;
                  return Column(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              SizedBox(height: height * .005),
                              if (showScanner)
                                _buildScannerSection(width, height, viewModel)
                              else if (scanSuccess)
                                scanSuccessBanner(viewModel)
                              else if (viewModel.labelOcrLoading ||
                                  _labelOcrInProgress)
                                SizedBox(
                                  height: min(height * 0.28, 220),
                                  child: const Center(
                                    child: CircularProgressIndicator(
                                      color: Color(0xFFE07A2F),
                                      strokeWidth: 4,
                                    ),
                                  ),
                                ),
                              SizedBox(height: scanSuccess ? 8 : height * .02),
                              medicineCard(viewModel),
                            ],
                          ),
                        ),
                      ),
                      actionButtonsGlass(),
                    ],
                  );
                },
              ),
            ),
    );
  }

  Widget _buildScannerSection(
    double width,
    double height,
    CustomerMedViewmodel viewModel,
  ) {
    final scannerHeight = min(height * 0.28, 220.0);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(25),
          child: SizedBox(
            width: width * .8,
            height: scannerHeight,
            child: Stack(
              alignment: Alignment.center,
              children: [
                MobileScanner(
                  controller: cameraController,
                  fit: BoxFit.cover,
                  onDetect: (capture) {
                    if (capture.barcodes.isEmpty) return;
                    final code = capture.barcodes.first.rawValue;
                    if (code == null) return;
                    if (code == viewModel.qrValue) return;
                    fetchData(code);
                  },
                ),
                scannerFocusBox(),
                Positioned(
                  bottom: 10,
                  child: GestureDetector(
                    onTap: _scanLabelFromCamera,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: BackdropFilter(
                        filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.45),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: const Color(0xFFE07A2F).withValues(alpha: 0.8),
                            ),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.document_scanner_outlined,
                                color: Color(0xFFE07A2F),
                                size: 18,
                              ),
                              SizedBox(width: 8),
                              Text(
                                'Photo label',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget scanSuccessBanner(CustomerMedViewmodel model) {
    final isLabel = _isLabelScanSuccessful(model);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.25),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.greenAccent.withValues(alpha: 0.6)),
            ),
            child: const Icon(
              Icons.check_circle,
              color: Colors.greenAccent,
              size: 32,
            ),
          ),
          const SizedBox(width: 14),
          Text(
            isLabel ? 'Medicine found in stock' : 'Successfully Scanned',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget scannerFocusBox() {
    return Stack(
      alignment: Alignment.center,
      children: [


        SizedBox(
          width: MediaQuery.of(context).size.width * .6,
          height: MediaQuery.of(context).size.height * .25,
        ),

        Positioned(
          top: 0,
          left: 0,
          child: _cornerIndicator(),
        ),
        Positioned(
          top: 0,
          right: 0,
          child: _cornerIndicator(rotation: pi / 2),
        ),
        Positioned(
          bottom: 0,
          left: 0,
          child: _cornerIndicator(rotation: -pi / 2),
        ),
        Positioned(
          bottom: 0,
          right: 0,
          child: _cornerIndicator(rotation: pi),
        ),
      ],
    );
  }

  Widget _cornerIndicator({double rotation = 0}) {
    return Transform.rotate(
      angle: rotation,
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: Colors.white, width: 3),
            left: BorderSide(color: Colors.white, width: 3),
          ),
        ),
      ),
    );
  }
  Widget medicineCard(CustomerMedViewmodel model) {
    if (model.qrFetchLoading || model.labelOcrLoading || _labelOcrInProgress) {
      return SizedBox(
        height: 200,
        child: const Padding(
          padding: EdgeInsets.all(30),
          child: Center(child: CircularProgressIndicator(color: const Color(0xFFE07A2F), strokeWidth: 4)),
        ),
      );
    }

    if (model.labelNotFound) {
      return SizedBox(
        height: 200,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.search_off, color: Colors.white70, size: 40),
              const SizedBox(height: 12),
              Text(
                model.labelOcrError.isNotEmpty
                    ? model.labelOcrError
                    : 'Product not found',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ],
          ),
        ),
      );
    }

    if (_isLabelScanSuccessful(model)) {
      return _buildLabelMedicineCard(model);
    }

    if (model.qrValue.isEmpty) {
      return const SizedBox.shrink();
    }
    if(model.qrFetchError!=""){
      return SizedBox(
        height: 200,
        child: Center(
          child: Text(
            model.qrFetchError,
            style: TextStyle(color: Colors.white, fontSize: 16),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(30),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 15, sigmaY: 15), // blur for glass effect
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15), // semi-transparent
              borderRadius: BorderRadius.circular(30),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.2),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black12.withValues(alpha: 0.15),
                  blurRadius: 20,
                  offset: const Offset(0, 7),
                ),
              ],
            ),
            padding: const EdgeInsets.symmetric(horizontal: 20,vertical: 10),
            child: Column(
              children: [
                _rowItem("Medicine Name", model.qrResponse?.result?.data?.productName??"", icon: Icons.medication),
                const Divider(color: Colors.white54),
                _rowItem("Potency", model.qrResponse?.result?.data?.potency??"", icon: Icons.percent),
                const Divider(color: Colors.white54),
                _rowItem("Company", model.qrResponse?.result?.data?.company??"", icon: Icons.location_city),
                const Divider(color: Colors.white54),
                _rowItem("Expiry", model.qrResponse?.result?.data?.expiry??"", icon: Icons.calendar_today),
                const Divider(color: Colors.white54),
                _rowItem(
                  "Stock Quantity",
                  _formatQty(
                    model.availableScanQuantity(
                      model.qrResponse?.result?.data,
                    ),
                  ),
                  icon: Icons.inventory_2,
                ),
                const Divider(color: Colors.white54),
                _rowTextField(
                  "Required Quantity",
                  requiredQtyController,
                  icon: Icons.shopping_cart,
                  keyboardType: TextInputType.number,
                ),
                const Divider(color: Colors.white54),
                _buildInvoiceField(model),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLabelMedicineCard(CustomerMedViewmodel model) {
    final medicineOptions = model.labelMedicineOptions;
    final potencyOptions = model.labelPotencyOptions;
    final packingOptions = model.labelPackingOptions;
    final stockQty = model.availableLabelStockQuantity();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(30),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 15, sigmaY: 15),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.2),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black12.withValues(alpha: 0.15),
                  blurRadius: 20,
                  offset: const Offset(0, 7),
                ),
              ],
            ),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: Column(
              children: [
                _LabelDropdown(
                  label: 'Medicine Name',
                  icon: Icons.medication,
                  value: model.labelMedicine,
                  items: medicineOptions,
                  onChanged: (value) =>
                      model.setLabelMedicine(context, value),
                ),
                const Divider(color: Colors.white54),
                _LabelDropdown(
                  label: 'Potency',
                  icon: Icons.percent,
                  value: model.labelPotency,
                  items: potencyOptions,
                  enabled: model.labelMedicine != null,
                  onChanged: model.setLabelPotency,
                ),
                const Divider(color: Colors.white54),
                _LabelDropdown(
                  label: 'Packing',
                  icon: Icons.inventory_2_outlined,
                  value: model.labelPacking,
                  items: packingOptions,
                  enabled: model.labelMedicine != null,
                  onChanged: model.setLabelPacking,
                ),
                const Divider(color: Colors.white54),
                _rowItem(
                  'Available Stock',
                  _formatQty(stockQty),
                  icon: Icons.inventory_2,
                ),
                const Divider(color: Colors.white54),
                _rowTextField(
                  'Required Quantity',
                  requiredQtyController,
                  icon: Icons.shopping_cart,
                  keyboardType: TextInputType.number,
                ),
                const Divider(color: Colors.white54),
                _buildInvoiceField(model),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInvoiceField(CustomerMedViewmodel model) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.receipt_long,
                size: 20,
                color: const Color(0xFFE07A2F).withValues(alpha: 0.85),
              ),
              const SizedBox(width: 8),
              const Text(
                'Invoice Number',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_invoiceLocked)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFE07A2F).withValues(alpha: 0.5)),
              ),
              child: Text(
                _fullInvoiceNumber,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            )
          else
            InvoicePrefixField(
              controller: invoicePrefixController,
              hintText: '0341',
              onSearch: (prefix) =>
                  model.searchInvoiceSuggestions(context, prefix),
            ),
        ],
      ),
    );
  }

  String _formatQty(double? value) {
    if (value == null) return '';
    if (value == value.roundToDouble()) {
      return value.toInt().toString();
    }
    return value.toString();
  }

  Widget _rowItem(String title, String value, {IconData? icon}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(

            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 20, color: const Color(0xFFE07A2F).withValues(alpha: .8)),
                const SizedBox(width: 11),
              ],
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ),

            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 8.0),
            child: Text(
              value,
              style: const TextStyle(fontSize: 11,color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
  Widget _rowTextField(
      String title,
      TextEditingController controller, {
        IconData? icon,
        TextInputType? keyboardType,
      }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(
              icon,
              size: 22,
              color: const Color(0xFFE07A2F).withValues(alpha: .8),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Expanded(
            child: TextField(
              keyboardType: keyboardType,
              controller: controller,
              style: const TextStyle(
                fontSize: 13,
                color: Colors.white54,
              ),
              decoration: const InputDecoration(
                isDense: true,
                border: UnderlineInputBorder(),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.white30),
                ),
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: const Color(0xFFE07A2F)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
  Widget actionButtonsGlass() {
    // final model=Provider.of<MedicineViewModel>(context,listen: false);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        SystemSafe.actionBarBottomPadding(context),
      ),
      child: Consumer<CustomerMedViewmodel>(
          builder: (context,model,_) {
            return Row(
              children: [
                model.addingLoading?Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox( height: 20,
                          width: 20,child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3)),

                    ],
                  ),
                ): Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(30),
                    child: BackdropFilter(
                      filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          double quantity =
                              double.tryParse(requiredQtyController.text.trim()) ?? 0.0;

                          final prefix = invoicePrefixController.text.trim();
                          final invoiceNumber = _fullInvoiceNumber;

                          if (prefix.isEmpty) {
                            StatusDialog.show(
                              context: context,
                              title: 'Invoice Error',
                              message: 'Invoice number is required',
                              type: StatusType.info,
                            );
                            return;
                          }

                          if (quantity == 0.0) {
                            StatusDialog.show(
                              context: context,
                              title: "Quantity Error",
                              message: "Quantity must be greater than 0",
                              type: StatusType.info,
                            );
                            return;
                          }

                          if (_isLabelScanSuccessful(model)) {
                            final scanQty = model.availableLabelStockQuantity();
                            if (model.selectedLabelStock == null) {
                              StatusDialog.show(
                                context: context,
                                title: 'Selection Error',
                                message:
                                    'Select medicine, potency, and packing from stock.',
                                type: StatusType.info,
                              );
                              return;
                            }
                            if (quantity > scanQty) {
                              StatusDialog.show(
                                context: context,
                                title: "Quantity Error",
                                message:
                                    'Required quantity is greater than stock quantity '
                                    '(${_formatQty(scanQty)})',
                                type: StatusType.info,
                              );
                              return;
                            }

                            final result = await model.addLabelStockToInvoice(
                              qty: quantity,
                              context: context,
                              invoiceNumber: invoiceNumber,
                            );

                            if (!context.mounted) return;

                            if (result == 'success') {
                              final addedStock = model.selectedLabelStock;
                              if (addedStock != null) {
                                await _finishSuccessfulAdd(
                                  data: model.qrDataFromLabelStock(addedStock),
                                  qty: quantity,
                                  invoiceId: model.lastAddedInvoiceId,
                                );
                              }
                            } else if (context.mounted) {
                              await StatusDialog.show(
                                context: context,
                                title: 'Failed',
                                message: result,
                                type: StatusType.error,
                              );
                            }
                            return;
                          }

                          final qrData = model.qrResponse?.result?.data;
                          final scanQty = model.availableScanQuantity(qrData);

                          if (model.qrResponse?.result?.data == null) {
                            StatusDialog.show(
                              context: context,
                              title: 'Scan Error',
                              message: 'Scan a product QR or label first',
                              type: StatusType.info,
                            );
                          } else if (quantity > scanQty) {
                            StatusDialog.show(
                              context: context,
                              title: "Quantity Error",
                              message:
                                  'Required quantity is greater than stock quantity '
                                  '(${_formatQty(scanQty)})',
                              type: StatusType.info,
                            );
                          } else {
                            final result = await model.addRequiredMedicineQty(
                              qty: quantity,
                              context: context,
                              invoiceNumber: invoiceNumber,
                            );

                            if (!context.mounted) return;

                            if (result == 'success') {
                              final addedData = model.qrResponse?.result?.data;
                              if (addedData != null) {
                                await _finishSuccessfulAdd(
                                  data: addedData,
                                  qty: quantity,
                                  invoiceId: model.lastAddedInvoiceId,
                                );
                              }
                            } else if (context.mounted) {
                              await StatusDialog.show(
                                context: context,
                                title: 'Failed',
                                message: result,
                                type: StatusType.error,
                              );
                            }
                          }
                        },
                        icon: const Icon(Icons.add, color: Colors.white),
                        label: const Text(
                          "Add",
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green.withValues(alpha: 0.7),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          elevation: 10,
                          shadowColor: Colors.black45,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(30),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),

                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(30),
                    child: BackdropFilter(
                      filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                      child: ElevatedButton.icon(
                        onPressed: refreshScanner,
                        icon: const Icon(Icons.clear, color: Colors.white),
                        label: const Text(
                          "Clear",
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red.withValues(alpha: 0.7),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          elevation: 10,
                          shadowColor: Colors.black45,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(30),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          }
      ),
    );
  }
}

class _LabelDropdown extends StatelessWidget {
  const _LabelDropdown({
    required this.label,
    required this.icon,
    required this.items,
    required this.onChanged,
    this.value,
    this.enabled = true,
  });

  final String label;
  final IconData icon;
  final String? value;
  final List<String> items;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final safeValue =
        value != null && items.any((e) => e == value) ? value : null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: const Color(0xFFE07A2F).withValues(alpha: 0.85),
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: safeValue,
                isExpanded: true,
                hint: Text(
                  items.isEmpty ? 'Not available' : 'Select',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 12,
                  ),
                ),
                dropdownColor: const Color(0xff2c505c),
                iconEnabledColor: Colors.white70,
                style: const TextStyle(color: Colors.white, fontSize: 12),
                items: items
                    .map(
                      (e) => DropdownMenuItem<String>(
                        value: e,
                        child: Text(e),
                      ),
                    )
                    .toList(),
                onChanged: enabled && items.isNotEmpty ? onChanged : null,
                onTap: () {
                  FocusManager.instance.primaryFocus?.unfocus();
                  SystemChannels.textInput.invokeMethod('TextInput.hide');
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
