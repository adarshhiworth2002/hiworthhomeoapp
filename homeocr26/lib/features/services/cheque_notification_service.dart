import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

/// Shows an in-app + system notification with message sound after login.
class ChequeNotificationService {
  ChequeNotificationService._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static final AudioPlayer _player = AudioPlayer();
  static bool _initialized = false;
  static bool _shownThisSession = false;

  static Future<void> init() async {
    if (_initialized) return;
    try {
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      const ios = DarwinInitializationSettings();
      await _plugin.initialize(
        settings: const InitializationSettings(android: android, iOS: ios),
      );
      _initialized = true;
    } catch (e, s) {
      if (kDebugMode) debugPrint('Cheque notification init: $e\n$s');
    }
  }

  /// Call once when landing on the home screen after login.
  static Future<void> notifyIfNeeded({
    required BuildContext context,
    required int count,
    required VoidCallback onOpen,
  }) async {
    if (_shownThisSession || count <= 0 || !context.mounted) return;
    _shownThisSession = true;

    // Banner first (instant on home), then sound / system notification.
    _showInAppBanner(context, count: count, onOpen: onOpen);
    unawaited(() async {
      await init();
      await _requestPermission();
      await _playSound();
      await _showSystemNotification(count);
    }());
  }

  static void resetSession() {
    _shownThisSession = false;
  }

  static Future<void> _requestPermission() async {
    try {
      final status = await Permission.notification.status;
      if (!status.isGranted) {
        await Permission.notification.request();
      }
    } catch (e, s) {
      if (kDebugMode) debugPrint('Notification permission: $e\n$s');
    }
  }

  static Future<void> _playSound() async {
    try {
      await _player.stop();
      await _player.play(AssetSource('sounds/message.wav'));
    } catch (e, s) {
      if (kDebugMode) debugPrint('Message sound: $e\n$s');
    }
  }

  static Future<void> _showSystemNotification(int count) async {
    try {
      const android = AndroidNotificationDetails(
        'cheque_clearance',
        'Cheque Clearance',
        channelDescription: 'Today paid cheque clearance alerts',
        importance: Importance.high,
        priority: Priority.high,
        playSound: true,
      );
      const details = NotificationDetails(
        android: android,
        iOS: DarwinNotificationDetails(presentSound: true),
      );
      await _plugin.show(
        id: 260721,
        title: 'Today Cheque Clearance',
        body: count == 1
            ? '1 cheque cleared today'
            : '$count cheques cleared today',
        notificationDetails: details,
      );
    } catch (e, s) {
      if (kDebugMode) debugPrint('System notification: $e\n$s');
    }
  }

  static void _showInAppBanner(
    BuildContext context, {
    required int count,
    required VoidCallback onOpen,
  }) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentMaterialBanner();
    messenger.showMaterialBanner(
      MaterialBanner(
        backgroundColor: const Color(0xFF2A2A2A),
        content: Text(
          count == 1
              ? '1 cheque cleared today — tap to view'
              : '$count cheques cleared today — tap to view',
          style: const TextStyle(color: Colors.white, fontSize: 13),
        ),
        leading: const Icon(
          Icons.account_balance_outlined,
          color: Color(0xFFE07A2F),
        ),
        actions: [
          TextButton(
            onPressed: () {
              messenger.hideCurrentMaterialBanner();
              onOpen();
            },
            child: const Text(
              'Open',
              style: TextStyle(color: Color(0xFFE07A2F)),
            ),
          ),
          TextButton(
            onPressed: messenger.hideCurrentMaterialBanner,
            child: const Text('Dismiss', style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );

    Future<void>.delayed(const Duration(seconds: 8), () {
      messenger.hideCurrentMaterialBanner();
    });
  }
}
