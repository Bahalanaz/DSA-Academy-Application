import 'dart:async';

import 'package:flutter/widgets.dart';

/// Keeps what's on screen current when the same data is changed somewhere
/// else: another admin, or the same account signed in on a second phone.
///
/// Screens used to load their data once, when opened. A payment recorded on
/// one phone didn't show on the other until someone left the screen and
/// came back, and acting on those old figures was refused with an error
/// ("that payment is already paid").
///
/// Now the screen in front reloads quietly every [interval] while the app
/// is open, straight away when the app comes back to the foreground, and
/// straight away after the server refuses an action because the data had
/// changed (see [ApiClient]).
class LiveRefresh {
  LiveRefresh._();

  static const interval = Duration(seconds: 20);

  /// Bumped on every refresh; screens listen to it (see [LiveRefreshing]).
  static final ticks = ValueNotifier<int>(0);

  static Timer? _timer;
  static _LifecycleWatcher? _watcher;

  /// Called once from main().
  static void start() {
    if (_watcher != null) return;
    _watcher = _LifecycleWatcher();
    WidgetsBinding.instance.addObserver(_watcher!);
    _startTimer();
  }

  /// Asks the screen in front to reload now.
  static void now() => ticks.value++;

  static void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => now());
  }

  static void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }
}

/// No polling while the app is in the background; one refresh on return.
class _LifecycleWatcher with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        LiveRefresh.now();
        LiveRefresh._startTimer();
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        LiveRefresh._stopTimer();
      case AppLifecycleState.inactive:
        break;
    }
  }
}

/// For a screen that shows data from the server. [reloadQuietly] fetches it
/// again with no spinner and no error message (a failed background reload
/// just leaves what's there; the next one tries again), then the screen
/// rebuilds.
///
/// Only the screen actually in front reloads: never one covered by a
/// dialog or sheet (the figures would change under a decision being made),
/// nor a tab that isn't showing. A screen with unsaved edits says so
/// through [canReloadNow].
mixin LiveRefreshing<T extends StatefulWidget> on State<T> {
  bool _reloading = false;

  Future<void> reloadQuietly();

  /// False while the user has unsaved changes a reload would disturb.
  bool get canReloadNow => true;

  @override
  void initState() {
    super.initState();
    LiveRefresh.ticks.addListener(_onTick);
  }

  @override
  void dispose() {
    LiveRefresh.ticks.removeListener(_onTick);
    super.dispose();
  }

  Future<void> _onTick() async {
    if (_reloading || !mounted || !canReloadNow) return;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    if (!TickerMode.valuesOf(context).enabled) return;
    _reloading = true;
    try {
      await reloadQuietly();
    } catch (_) {
      // Offline or refused: keep showing what's there.
    } finally {
      _reloading = false;
    }
    if (mounted) setState(() {});
  }
}
