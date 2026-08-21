import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Scan success feedback: motor buzz + beep (beep works even if vibration is off).
class ScanFeedback {
  ScanFeedback._();

  static const _channel = MethodChannel('com.example.homeocr26/haptics');
  static final AudioPlayer _player = AudioPlayer();

  /// Call after a successful QR / label scan.
  static Future<void> successBuzz() async {
    if (kDebugMode) debugPrint('ScanFeedback: successBuzz start');

    // Beep first — reliable on Samsung when vibration intensity is 0.
    unawaited(_playBeep());

    try {
      final ok = await _channel.invokeMethod<bool>(
        'vibrate',
        {'durationMs': 250},
      );
      if (kDebugMode) {
        debugPrint('ScanFeedback: native vibrate ok=$ok');
      }
      if (ok != true) {
        await HapticFeedback.vibrate();
      }
    } catch (e) {
      if (kDebugMode) debugPrint('ScanFeedback.vibrate failed: $e');
      try {
        await HapticFeedback.vibrate();
      } catch (_) {}
    }
  }

  static Future<void> _playBeep() async {
    try {
      await _player.stop();
      await _player.play(AssetSource('sounds/message.wav'));
    } catch (e) {
      if (kDebugMode) debugPrint('ScanFeedback.beep failed: $e');
    }
  }
}
