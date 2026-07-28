import 'dart:async';

import 'package:flutter/widgets.dart';

import '../services/live_data_sync.dart';

/// Mix into list screens so they silently re-fetch while open / on resume.
mixin LiveRefreshMixin<T extends StatefulWidget> on State<T> {
  Timer? _liveRefreshTimer;
  AppLifecycleListener? _liveRefreshLifecycle;
  bool _liveRefreshBusy = false;

  /// Call from initState after the first load is scheduled.
  void startLiveRefresh(Future<void> Function() refresh) {
    _liveRefreshLifecycle = AppLifecycleListener(
      onResume: () => unawaited(_runLiveRefresh(refresh)),
    );
    _liveRefreshTimer?.cancel();
    _liveRefreshTimer = Timer.periodic(
      LiveDataSync.pollInterval,
      (_) => unawaited(_runLiveRefresh(refresh)),
    );
  }

  Future<void> _runLiveRefresh(Future<void> Function() refresh) async {
    if (!mounted || _liveRefreshBusy) return;
    _liveRefreshBusy = true;
    try {
      await refresh();
    } finally {
      _liveRefreshBusy = false;
    }
  }

  /// Call from dispose before super.dispose().
  void stopLiveRefresh() {
    _liveRefreshTimer?.cancel();
    _liveRefreshTimer = null;
    _liveRefreshLifecycle?.dispose();
    _liveRefreshLifecycle = null;
  }
}
