import 'package:flutter/material.dart';
import 'package:homeocr26/features/theme.dart';
import 'package:homeocr26/features/widgets/app_responsive.dart';

class StatusDialog {
  /// Shows the status popup. Completes when the user taps OK.
  static Future<void> show({
    required BuildContext context,
    required String title,
    required String message,
    required StatusType type,
  }) {
    IconData icon;
    Color color;

    switch (type) {
      case StatusType.success:
        icon = Icons.check_circle;
        color = Colors.green.shade500;
        break;
      case StatusType.error:
        icon = Icons.error;
        color = Colors.redAccent.shade200;
        break;
      case StatusType.info:
        icon = Icons.info;
        color = appOrange;
        break;
    }

    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        insetPadding: AppResponsive.of(context).dialogInsets,
        backgroundColor: bg2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(25),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 40),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.white60,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: Colors.white70),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: appOrange,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(dialogContext),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8.0),
                child: Text('OK'),
              ),
            )
          ],
        ),
      ),
    );
  }
}

enum StatusType { success, error, info }
