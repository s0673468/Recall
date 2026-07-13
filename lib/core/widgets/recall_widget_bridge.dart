import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../features/review/application/review_controller.dart';
import '../../features/review/application/review_state.dart';

/// The complete, deliberately narrow contract shared with WidgetKit.
///
/// No account identifier, deck name, card content, or review row crosses the
/// App Group boundary. The extension receives only a count and the instant at
/// which Recall last calculated it.
@immutable
class RecallWidgetSnapshot {
  final int dueCount;
  final DateTime updatedAt;

  const RecallWidgetSnapshot({required this.dueCount, required this.updatedAt});

  @override
  bool operator ==(Object other) =>
      other is RecallWidgetSnapshot &&
      other.dueCount == dueCount &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(dueCount, updatedAt);
}

abstract interface class RecallWidgetStore {
  Future<void> update(RecallWidgetSnapshot snapshot);
  Future<void> clear();
}

/// Sends the aggregate snapshot to the native App Group writer.
class MethodChannelRecallWidgetStore implements RecallWidgetStore {
  static const channel = MethodChannel('com.german.ankiReview/widget');

  const MethodChannelRecallWidgetStore();

  bool get _supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  @override
  Future<void> update(RecallWidgetSnapshot snapshot) async {
    if (!_supported) return;
    await channel.invokeMethod<void>('update', {
      'dueCount': snapshot.dueCount,
      'updatedAtEpochMs': snapshot.updatedAt.millisecondsSinceEpoch,
    });
  }

  @override
  Future<void> clear() async {
    if (!_supported) return;
    await channel.invokeMethod<void>('clear');
  }
}

/// Converts review state into the privacy-safe widget aggregate.
///
/// Writes are deduplicated by count and verified cloud timestamp. A signed-in
/// cold-start or offline-only state does not publish a misleading queue-local
/// count; WidgetKit keeps the previous snapshot and marks it stale instead.
class RecallWidgetPublisher {
  final RecallWidgetStore store;

  int? _lastDueCount;
  DateTime? _lastUpdatedAt;
  bool _cleared = false;
  bool _clearQueued = false;
  bool _signedIn = false;
  Future<void> _pending = Future<void>.value();

  RecallWidgetPublisher({required this.store});

  Future<void> publish({required bool signedIn, required ReviewState state}) {
    _signedIn = signedIn;
    if (!signedIn) {
      if (_cleared || _clearQueued) return _pending;
      _lastDueCount = null;
      _lastUpdatedAt = null;
      return _clearOnSignOut();
    }

    _cleared = false;
    final dueCount = state.globalDueCount;
    final updatedAt = state.globalDueUpdatedAt;
    if (dueCount == null || updatedAt == null) return _pending;
    if (_lastDueCount == dueCount && _lastUpdatedAt == updatedAt) {
      return _pending;
    }
    _lastDueCount = dueCount;
    _lastUpdatedAt = updatedAt;
    final snapshot = RecallWidgetSnapshot(
      dueCount: dueCount,
      updatedAt: updatedAt.toUtc(),
    );
    return _enqueue(() => store.update(snapshot));
  }

  Future<void> _clearOnSignOut() async {
    _clearQueued = true;
    try {
      await _enqueue(store.clear);
      if (!_signedIn) _cleared = true;
    } finally {
      // A failed clear must be retryable on the next signed-out publication.
      _clearQueued = false;
    }
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final next = _pending.then((_) => operation());
    // Report this operation's error to its caller, but heal the internal tail
    // so a transient channel/App Group failure cannot suppress later updates.
    _pending = next.then<void>((_) {}, onError: (_, _) {});
    return next;
  }
}

/// Keeps WidgetKit current for both network and offline/cached queue changes.
class RecallWidgetBridge extends StatefulWidget {
  final ReviewController controller;
  final Widget child;
  final RecallWidgetStore store;

  const RecallWidgetBridge({
    super.key,
    required this.controller,
    required this.child,
    this.store = const MethodChannelRecallWidgetStore(),
  });

  @override
  State<RecallWidgetBridge> createState() => _RecallWidgetBridgeState();
}

class _RecallWidgetBridgeState extends State<RecallWidgetBridge> {
  late RecallWidgetPublisher _publisher;

  @override
  void initState() {
    super.initState();
    _publisher = RecallWidgetPublisher(store: widget.store);
    widget.controller.addListener(_publish);
    _publish();
  }

  @override
  void didUpdateWidget(covariant RecallWidgetBridge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.store != widget.store) {
      oldWidget.controller.removeListener(_publish);
      _publisher = RecallWidgetPublisher(store: widget.store);
      widget.controller.addListener(_publish);
      _publish();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_publish);
    super.dispose();
  }

  void _publish() {
    unawaited(
      _publisher
          .publish(
            signedIn: widget.controller.currentUser != null,
            state: widget.controller.state,
          )
          .catchError((Object error, StackTrace stackTrace) {
            FlutterError.reportError(
              FlutterErrorDetails(
                exception: error,
                stack: stackTrace,
                library: 'recall widget bridge',
                context: ErrorDescription('publishing the due-count snapshot'),
              ),
            );
          }),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
