import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../viewModels/supplier_med_viewmodel.dart';
import '../services/invoice_helper.dart';
import '../services/invoice_search_service.dart';
import '../widgets/invoice_prefix_field.dart';
import '../widgets/show_dialog_custom.dart';
import '../widgets/app_responsive.dart';
import '../widgets/system_safe.dart';
import '../theme.dart';

class AddToSupplPage extends StatefulWidget {
  const AddToSupplPage({super.key});

  @override
  State<AddToSupplPage> createState() => _AddToSupplPageState();
}

class _AddToSupplPageState extends State<AddToSupplPage> {
  MobileScannerController cameraController = MobileScannerController();

  bool hasPermission = false;
  String medicineName = "";
  int totalQty = 0;
  int requiredQty = 0;
  TextEditingController invoicePrefixController = TextEditingController();
  bool _fetchInProgress = false;

  String get _fullInvoiceNumber =>
      InvoiceHelper.formatFull(invoicePrefixController.text);

  @override
  void dispose() {
    invoicePrefixController.dispose();
    cameraController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      InvoiceSearchService.clearCache();
      requestCamera();
      final model = Provider.of<SupplierMedViewModel>(context, listen: false);
      model.resetQr();
    });
  }

  Future<void> refreshScanner({bool keepInvoice = false}) async {
    final model = Provider.of<SupplierMedViewModel>(context, listen: false);
    model.resetQr();
    if (!keepInvoice) {
      invoicePrefixController.clear();
    }
    try {
      await cameraController.stop();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;
      await cameraController.start();
    } catch (e) {
      debugPrint('refreshScanner: $e');
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

  bool _isScanSuccessful(SupplierMedViewModel model) {
    return model.qrValue.isNotEmpty &&
        !model.qrFetchLoading &&
        model.qrFetchError.isEmpty &&
        model.medicine.isNotEmpty;
  }

  Future<void> fetchData(String code) async {
    if (_fetchInProgress) return;
    _fetchInProgress = true;

    final model = Provider.of<SupplierMedViewModel>(context, listen: false);
    model.setQrValue(code);
    model.parseMedicines(code);

    try {
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
      backgroundColor: sectionBg,
      appBar: AppBar(
        iconTheme: const IconThemeData(color: sectionText),

        title: const Text(
          "Add to Supplier",
          style: TextStyle(
            color: sectionText,
            fontWeight: FontWeight.w500,
            fontSize: 15,
          ),
        ),
        backgroundColor: sectionBg,
        elevation: 0,

        actions: [
          GestureDetector(
            onTap: refreshScanner,
            child: Padding(
              padding: const EdgeInsets.only(right: 16.0),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      // semi-transparent glass
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
                    child: Padding(
                      padding: const EdgeInsets.all(3.0),
                      child: const Icon(
                        Icons.refresh,
                        color: const Color(0xFFE07A2F),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          GestureDetector(
            onTap: stopScanner,
            child: Padding(
              padding: const EdgeInsets.only(right: 16.0),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      // semi-transparent glass
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
                    child: Padding(
                      padding: const EdgeInsets.all(3.0),
                      child: const Icon(
                        Icons.stop_circle,
                        color: const Color(0xFFE07A2F),
                      ),
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
              child: Consumer<SupplierMedViewModel>(
                builder: (context, viewModel, _) {
                  final scanSuccess = _isScanSuccessful(viewModel);
                  return Column(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              SizedBox(height: height * .005),
                              if (!scanSuccess)
                                _buildScannerSection(width, height, viewModel)
                              else
                                scanSuccessBanner(),
                              SizedBox(height: scanSuccess ? 8 : height * .01),
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
    SupplierMedViewModel viewModel,
  ) {
    final scannerHeight = min(height * 0.28, 220.0);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(25),
          child: SizedBox(
            width: width * .9,
            height: scannerHeight,
            child: Stack(
              alignment: Alignment.center,
              children: [
                MobileScanner(
                  controller: cameraController,
                  fit: BoxFit.cover,
                  onDetect: (capture) {
                    final code = capture.barcodes.first.rawValue;
                    if (code == null) return;
                    if (code == viewModel.qrValue) return;
                    fetchData(code);
                  },
                ),
                scannerFocusBox(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget scanSuccessBanner() {
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
          const Text(
            'Successfully Scanned',
            style: TextStyle(
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
          width: AppResponsive.of(context).scannerFrame(widthFactor: 0.6).width,
          height: AppResponsive.of(context).scannerFrame(heightFactor: 0.25).height,
        ),

        Positioned(top: 0, left: 0, child: _cornerIndicator()),
        Positioned(top: 0, right: 0, child: _cornerIndicator(rotation: pi / 2)),
        Positioned(
          bottom: 0,
          left: 0,
          child: _cornerIndicator(rotation: -pi / 2),
        ),
        Positioned(bottom: 0, right: 0, child: _cornerIndicator(rotation: pi)),
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

  Widget medicineCard(SupplierMedViewModel model) {
    if (model.qrFetchLoading) {
      return SizedBox(
        height: 200,
        child: const Padding(
          padding: EdgeInsets.all(30),
          child: Center(
            child: CircularProgressIndicator(
              color: const Color(0xFFE07A2F),
              strokeWidth: 4,
            ),
          ),
        ),
      );
    }

    if (model.qrValue.isEmpty) {
      return const SizedBox.shrink();
    }
    if (model.qrFetchError.isNotEmpty) {
      return SizedBox(
        height: 200,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              model.qrFetchError,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(30),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
          // blur for glass effect
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
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
            child: SingleChildScrollView(
              child: Column(
                children: [
                  Text(
                    "Medicines",
                    style: TextStyle(color: Colors.white, fontSize: 15),
                  ),
                  SizedBox(height: 12),
                  ListView.builder(
                    physics: const NeverScrollableScrollPhysics(),
                    shrinkWrap: true,
                    itemCount: model.medicine.length,
                    itemBuilder: (context, index) {
                      return Column(
                        children: [
                          _rowItemCustomer(
                            model.medicine[index].name,
                            model.medicine[index].quantity,
                            model.medicine[index].mrp,
                            model.medicine[index].rate,
                            icon: Icons.medication,
                          ),
                          const Divider(color: sectionTextMuted),
                        ],
                      );
                    },
                  ),
                  const Divider(color: sectionTextMuted),
                  _buildInvoiceField(model),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInvoiceField(SupplierMedViewModel model) {
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
          InvoicePrefixField(
            controller: invoicePrefixController,
            hintText: '1011',
            warnOnNonDraftSelection: true,
            onSearchSuggestions: (prefix) =>
                model.searchInvoiceSuggestionsDetailed(context, prefix),
          ),
        ],
      ),
    );
  }

  Widget _rowItemCustomer(
    String title,
    String quantity,
    String mrp,
    String rate, {
    IconData? icon,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 18,
                  color: const Color(0xFFE07A2F).withValues(alpha: .8),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: sectionTextMuted,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 8.0),
            child: Row(
              children: [
                Text(
                  "Quantity: ",
                  style: const TextStyle(fontSize: 12, color: Colors.white60),
                ),
                Text(
                  quantity,
                  style: const TextStyle(fontSize: 12, color: Colors.white60),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 8.0),
            child: Row(
              children: [
                Text(
                  "Mrp: ",
                  style: const TextStyle(fontSize: 12, color: Colors.white60),
                ),
                Text(
                  mrp,
                  style: const TextStyle(fontSize: 12, color: Colors.white60),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 8.0),
            child: Row(
              children: [
                Text(
                  "Rate: ",
                  style: const TextStyle(fontSize: 12, color: Colors.white60),
                ),
                Text(
                  rate,
                  style: const TextStyle(fontSize: 12, color: Colors.white60),
                ),
              ],
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
      padding: const EdgeInsets.symmetric(vertical: 5),
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
                color: sectionTextMuted,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Expanded(
            child: TextField(
              keyboardType: keyboardType,
              controller: controller,
              style: const TextStyle(fontSize: 14, color: sectionTextMuted),
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
      child: Consumer<SupplierMedViewModel>(
        builder: (context, model, _) {
          return Row(
            children: [
              model.addingLoading
                  ? Expanded(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 3,
                            ),
                          ),
                        ],
                      ),
                    )
                  : Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(30),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                          child: ElevatedButton.icon(
                            onPressed: () async {
                              final prefix = invoicePrefixController.text.trim();
                              final invoiceNumber = _fullInvoiceNumber;

                              if (prefix.isEmpty) {
                                StatusDialog.show(
                                  context: context,
                                  title: 'Invoice Error',
                                  message: 'Invoice number is required',
                                  type: StatusType.info,
                                );
                              } else if (model.medicine.isEmpty) {
                                StatusDialog.show(
                                  context: context,
                                  title: 'Qr Error',
                                  message:
                                      'Scan a supplier invoice QR with ITEM: lines',
                                  type: StatusType.info,
                                );
                              } else {
                                final success =
                                    await model.addRequiredMedicineQtySupplier(
                                  context: context,
                                  invoiceNumber: invoiceNumber,
                                );
                                if (!context.mounted) return;
                                if (success) {
                                  try {
                                    await cameraController.stop();
                                  } catch (_) {}
                                  if (!context.mounted) return;
                                  Navigator.of(context).maybePop(true);
                                }
                              }
                            },
                            icon: const Icon(Icons.add, color: Colors.white),
                            label: const Text(
                              "Add",
                              style: TextStyle(
                                color: sectionText,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green.withValues(
                                alpha: 0.7,
                              ),
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
                    filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: ElevatedButton.icon(
                      onPressed: refreshScanner,
                      icon: const Icon(Icons.clear, color: Colors.white),
                      label: const Text(
                        "Clear",
                        style: TextStyle(
                          color: sectionText,
                          fontWeight: FontWeight.bold,
                        ),
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
        },
      ),
    );
  }
}
