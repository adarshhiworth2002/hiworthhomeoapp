import 'dart:async';

import 'package:flutter/widgets.dart';

import '../services/live_data_sync.dart';

/// Mix into list screens so they silently re-fetch while open / on resume.
mixin LiveRefreshMixin<T extends StatefulWidget> on State<T> {
  Timer? _liveRefreshTimer;
  AppLifecycleListener? _liveRefreshLifecycle;
  bool _liveRefreshBusy = false;
  bool _liveRefreshStopped = false;

  /// Call from initState after the first load is scheduled.
  void startLiveRefresh(
    Future<void> Function() refresh, {
    Duration? interval,
    bool immediate = false,
  }) {
    _liveRefreshLifecycle = AppLifecycleListener(
      onResume: () => unawaited(_runLiveRefresh(refresh)),
    );
    _liveRefreshTimer?.cancel();
    _liveRefreshTimer = Timer.periodic(
      interval ?? LiveDataSync.pollInterval,
      (_) => unawaited(_runLiveRefresh(refresh)),
    );
    if (immediate) {
      unawaited(_runLiveRefresh(refresh));
    }
  }

  Future<void> _runLiveRefresh(Future<void> Function() refresh) async {
    if (_liveRefreshStopped || !mounted || _liveRefreshBusy) return;
    _liveRefreshBusy = true;
    try {
      await refresh();
    } catch (_) {
      // Fetch may finish after the page is popped.
    } finally {
      _liveRefreshBusy = false;
    }
  }

  /// Call from dispose before super.dispose().
  void stopLiveRefresh() {
    _liveRefreshStopped = true;
    _liveRefreshTimer?.cancel();
    _liveRefreshTimer = null;
    _liveRefreshLifecycle?.dispose();
    _liveRefreshLifecycle = null;
  }
}
