import 'package:flutter/material.dart';

import 'app_responsive.dart';

/// Labeled list fields that stay on one row on tablet, and wrap to extra
/// lines on phone so every column stays visible.
class CompactFieldRows extends StatelessWidget {
  const CompactFieldRows({
    super.key,
    required this.fields,
    this.trailing,
  });

  final List<Widget> fields;
  final Widget? trailing;

  static int columnsFor(int count, bool wide) {
    if (wide || count <= 3) return count;
    if (count == 4) return 2;
    return 3;
  }

  @override
  Widget build(BuildContext context) {
    if (fields.isEmpty) return const SizedBox.shrink();

    final wide = !AppResponsive.of(context).isCompact;
    final cols = columnsFor(fields.length, wide);
    final rows = <Widget>[];

    for (var i = 0; i < fields.length; i += cols) {
      final end = i + cols > fields.length ? fields.length : i + cols;
      final chunk = fields.sublist(i, end);
      if (rows.isNotEmpty) {
        rows.add(const SizedBox(height: 8));
      }
      rows.add(
        Row(
          children: [
            for (final field in chunk) Expanded(child: field),
          ],
        ),
      );
    }

    final grid = Column(
      mainAxisSize: MainAxisSize.min,
      children: rows,
    );

    if (trailing == null) return grid;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: grid),
        const SizedBox(width: 4),
        trailing!,
      ],
    );
  }
}
