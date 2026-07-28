import 'package:flutter/material.dart';

import '../../models/net_amount_model.dart';
import '../../viewModels/net_amount_viewmodel.dart';
import 'customer_invoice_detail_page.dart';

void openNetAmountRowDetail(
  BuildContext context, {
  required NetAmountRow row,
  required NetAmountSection section,
}) {
  final isGave = section == NetAmountSection.youGave;
  final seed = row.toInvoiceSummary(asSupplier: isGave);

  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => CustomerInvoiceDetailPage(
        invoice: seed,
        title: NetAmountViewModel.sectionTitle(section),
        partnerLabel: isGave ? 'Supplier' : 'Customer',
        allowScan: !isGave,
        supplierLayout: isGave,
      ),
    ),
  );
}
