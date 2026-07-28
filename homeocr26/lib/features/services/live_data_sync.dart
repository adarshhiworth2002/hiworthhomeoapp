import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Keeps list data close to the website by polling while the app is visible
/// and syncing immediately when the app returns to the foreground.
class LiveDataSync {
  LiveDataSync._();

  /// How often to pull fresh data while the app is in the foreground.
  static const Duration pollInterval = Duration(seconds: 45);

  static Timer? _timer;
  static AppLifecycleListener? _lifecycle;
  static bool _running = false;
  static bool _syncing = false;
  static Future<void> Function()? _onSync;

  static bool get isRunning => _running;

  /// Start foreground polling + resume sync. Safe to call multiple times.
  static void start({required Future<void> Function() onSync}) {
    _onSync = onSync;
    if (_running) return;
    _running = true;

    _lifecycle = AppLifecycleListener(
      onResume: () {
        unawaited(syncNow());
      },
      onPause: () {
        // Keep timer; syncNow no-ops while paused via lifecycle checks if needed.
      },
    );

    _timer?.cancel();
    _timer = Timer.periodic(pollInterval, (_) {
      unawaited(syncNow());
    });

    // First sync shortly after start so website edits show up quickly.
    unawaited(Future<void>.delayed(const Duration(seconds: 2), syncNow));
  }

  static void stop() {
    _running = false;
    _onSync = null;
    _timer?.cancel();
    _timer = null;
    _lifecycle?.dispose();
    _lifecycle = null;
  }

  static Future<void> syncNow() async {
    final sync = _onSync;
    if (sync == null || _syncing) return;
    _syncing = true;
    try {
      await sync();
    } catch (e, s) {
      if (kDebugMode) debugPrint('LiveDataSync: $e\n$s');
    } finally {
      _syncing = false;
    }
  }
}
