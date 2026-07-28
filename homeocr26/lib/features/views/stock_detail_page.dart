import 'package:flutter/material.dart';

import '../../models/stock_item_model.dart';
import '../widgets/system_safe.dart';

/// Full stock record detail (same fields as the previous list card).
class StockDetailPage extends StatelessWidget {
  const StockDetailPage({super.key, required this.item});

  final StockItemModel item;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      appBar: AppBar(
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text(
          'Stock Details',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w500,
            fontSize: 15,
          ),
        ),
        backgroundColor: const Color(0xFF1A1A1A),
        elevation: 0,
      ),
      body: RefreshIndicator(
        color: const Color(0xFFE07A2F),
        onRefresh: () async {},
        child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: SystemSafe.listPadding(context),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.medicineLabel,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 8),
                _Meta('Stock Date', item.stockDate ?? '—'),
                _Meta('Potency', item.potency ?? '—'),
                _Meta('Packing', item.packing ?? '—'),
                _Meta('Company', item.company ?? '—'),
                _Meta('Group', item.group ?? '—'),
                _Meta('Batch', item.batch ?? '—'),
                _Meta('Mfd', item.mfd ?? '—'),
                _Meta('Exp', item.exp ?? '—'),
                _Meta('Rack', item.rack ?? '—'),
                _Meta('HSN', item.hsn ?? '—'),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _AmountChip('Item Qty', item.itemQty),
                    const SizedBox(width: 8),
                    _AmountChip('Stock', item.stock),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    _AmountChip('Mrp', item.mrp),
                    const SizedBox(width: 8),
                    _AmountChip('Hold Qty', item.holdQty ?? 0),
                  ],
                ),
                if (item.gst != null) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      _AmountChip('GST(%)', item.gst),
                      const SizedBox(width: 8),
                      const Expanded(child: SizedBox()),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }
}

void openStockDetail(BuildContext context, StockItemModel item) {
  Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => StockDetailPage(item: item)),
  );
}

class _Meta extends StatelessWidget {
  const _Meta(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: [
          SizedBox(
            width: 96,
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

class _AmountChip extends StatelessWidget {
  const _AmountChip(this.label, this.value);

  final String label;
  final double? value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 10,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              StockItemModel.money(value),
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
