import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/platform/recall_platform.dart';

class StudyReminderSettings {
  final bool enabled;
  final int hour;
  final int minute;

  const StudyReminderSettings({
    required this.enabled,
    required this.hour,
    required this.minute,
  });

  StudyReminderSettings copyWith({bool? enabled, int? hour, int? minute}) =>
      StudyReminderSettings(
        enabled: enabled ?? this.enabled,
        hour: hour ?? this.hour,
        minute: minute ?? this.minute,
      );

  String get formattedTime =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}

abstract class StudyReminderPlatform {
  Future<bool> requestPermission();
  Future<void> openNotificationSettings();
  Future<void> apply(
    StudyReminderSettings settings, {
    required int? dueCount,
    required bool studiedToday,
  });
  Future<void> cancel();
}

class MethodChannelStudyReminderPlatform implements StudyReminderPlatform {
  static const _channel = MethodChannel('com.german.ankiReview/studyReminder');

  const MethodChannelStudyReminderPlatform();

  bool get _isNativeMobile => recallRunsAsNativeMobile();

  @override
  Future<bool> requestPermission() async {
    if (!_isNativeMobile) return true;
    return await _channel.invokeMethod<bool>('requestPermission') ?? false;
  }

  @override
  Future<void> openNotificationSettings() async {
    if (!_isNativeMobile) return;
    await _channel.invokeMethod<void>('openSettings');
  }

  @override
  Future<void> apply(
    StudyReminderSettings settings, {
    required int? dueCount,
    required bool studiedToday,
  }) async {
    if (!_isNativeMobile) return;
    await _channel.invokeMethod<void>('apply', {
      'enabled': settings.enabled,
      'hour': settings.hour,
      'minute': settings.minute,
      'dueCount': dueCount,
      'studiedToday': studiedToday,
    });
  }

  @override
  Future<void> cancel() async {
    if (!_isNativeMobile) return;
    await _channel.invokeMethod<void>('cancel');
  }
}

class StudyReminderController extends ChangeNotifier {
  static const _enabledKey = 'recall_study_reminder_enabled';
  static const _hourKey = 'recall_study_reminder_hour';
  static const _minuteKey = 'recall_study_reminder_minute';
  static const defaultHour = 19;
  static const defaultMinute = 0;

  final StudyReminderPlatform platform;
  final Future<SharedPreferences> Function() _prefsLoader;
  final DateTime Function() clock;
  String? _ownerId;
  int? _dueCount;
  DateTime? _lastReviewedAt;
  bool _reviewActivityKnown = false;
  Timer? _dayBoundaryTimer;
  Future<void> _operationTail = Future<void>.value();
  String? _lastAppliedSignature;
  bool _disposed = false;

  StudyReminderSettings _value = const StudyReminderSettings(
    enabled: false,
    hour: defaultHour,
    minute: defaultMinute,
  );

  StudyReminderController({
    this.platform = const MethodChannelStudyReminderPlatform(),
    Future<SharedPreferences> Function()? prefsLoader,
    DateTime Function()? clock,
  }) : _prefsLoader = prefsLoader ?? SharedPreferences.getInstance,
       clock = clock ?? DateTime.now;

  StudyReminderSettings get value => _value;

  Future<void> openNotificationSettings() =>
      platform.openNotificationSettings();

  Future<void> initialize({String? ownerId, bool apply = true}) =>
      _enqueue(() => _initialize(ownerId: ownerId, apply: apply));

  Future<void> _initialize({String? ownerId, required bool apply}) async {
    if (_ownerId == ownerId) {
      // Auth emits token-refresh and repeated signed-in events for the same
      // account. Preserve the already reconciled local signals in that case;
      // resetting them would cancel a valid reminder until the next refresh.
      return;
    }
    _dayBoundaryTimer?.cancel();
    _dayBoundaryTimer = null;
    _ownerId = ownerId;
    _dueCount = null;
    _lastReviewedAt = null;
    _reviewActivityKnown = false;
    _lastAppliedSignature = null;
    // The native notification identifier is intentionally shared by the one
    // account currently active on this device. Clear it before loading the
    // next owner's preference so a slow preference read cannot leak the old
    // owner's reminder into the new session.
    if (apply) await platform.cancel();
    if (ownerId == null) {
      _value = const StudyReminderSettings(
        enabled: false,
        hour: defaultHour,
        minute: defaultMinute,
      );
      notifyListeners();
      return;
    }
    final prefs = await _prefsLoader();
    _value = StudyReminderSettings(
      enabled: prefs.getBool(_key(_enabledKey, ownerId)) ?? false,
      hour: (prefs.getInt(_key(_hourKey, ownerId)) ?? defaultHour).clamp(0, 23),
      minute: (prefs.getInt(_key(_minuteKey, ownerId)) ?? defaultMinute).clamp(
        0,
        59,
      ),
    );
    notifyListeners();
  }

  Future<void> activateOwner(String ownerId) => initialize(ownerId: ownerId);

  Future<void> releaseOwner() => _enqueue(_releaseOwner);

  Future<void> _releaseOwner() async {
    try {
      await platform.cancel();
    } finally {
      _dayBoundaryTimer?.cancel();
      _dayBoundaryTimer = null;
      _ownerId = null;
      _dueCount = null;
      _lastReviewedAt = null;
      _reviewActivityKnown = false;
      _lastAppliedSignature = null;
      _value = const StudyReminderSettings(
        enabled: false,
        hour: defaultHour,
        minute: defaultMinute,
      );
      notifyListeners();
    }
  }

  Future<bool> setEnabled(bool enabled) => _enqueue(() => _setEnabled(enabled));

  Future<bool> _setEnabled(bool enabled) async {
    final ownerId = _requireOwner();
    if (enabled && !await platform.requestPermission()) {
      _lastAppliedSignature = null;
      await platform.apply(
        _value.copyWith(enabled: false),
        dueCount: null,
        studiedToday: true,
      );
      return false;
    }
    await _commit(_value.copyWith(enabled: enabled), ownerId: ownerId);
    return true;
  }

  Future<void> setTime({required int hour, required int minute}) =>
      _enqueue(() => _setTime(hour: hour, minute: minute));

  Future<void> _setTime({required int hour, required int minute}) async {
    final ownerId = _requireOwner();
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
      throw RangeError('Reminder time must be a valid local time.');
    }
    await _commit(
      _value.copyWith(hour: hour, minute: minute),
      ownerId: ownerId,
    );
  }

  /// Stops account-scoped delivery without erasing the user's preference.
  /// A later sign-in re-applies the saved setting during initialization.
  Future<void> cancelPending() => _enqueue(() async {
    _lastAppliedSignature = null;
    await platform.cancel();
  });

  /// Reconciles the account's preference with the privacy-safe study signals.
  /// Unknown due count or review activity is treated as ineligible, so stale
  /// or partial data can suppress a notification but can never create a false
  /// nudge.
  Future<void> reconcile({
    required int? dueCount,
    required DateTime? lastReviewedAt,
    required bool reviewActivityKnown,
    bool force = false,
  }) => _enqueue(() async {
    if (_ownerId == null) return;
    _dueCount = dueCount;
    _lastReviewedAt = lastReviewedAt;
    _reviewActivityKnown = reviewActivityKnown;
    await _applyEligibility(force: force);
    _armDayBoundaryTimer();
  });

  String _requireOwner() {
    final ownerId = _ownerId;
    if (ownerId == null) throw StateError('A signed-in owner is required.');
    return ownerId;
  }

  String _key(String base, String ownerId) => '$base:$ownerId';

  Future<void> _commit(
    StudyReminderSettings next, {
    required String ownerId,
  }) async {
    // Apply first. If native delivery fails, don't persist a setting the app
    // could misleadingly show as active. Ineligible enabled preferences are
    // retained while the pending request is cancelled.
    await _applyEligibility(settings: next, force: true, persistDisabled: true);
    final prefs = await _prefsLoader();
    await Future.wait([
      prefs.setBool(_key(_enabledKey, ownerId), next.enabled),
      prefs.setInt(_key(_hourKey, ownerId), next.hour),
      prefs.setInt(_key(_minuteKey, ownerId), next.minute),
    ]);
    _value = next;
    _armDayBoundaryTimer();
    notifyListeners();
  }

  Future<void> _applyEligibility({
    StudyReminderSettings? settings,
    required bool force,
    bool persistDisabled = false,
  }) async {
    final next = settings ?? _value;
    final now = clock().toLocal();
    final studiedToday =
        _reviewActivityKnown &&
        _lastReviewedAt != null &&
        _sameLocalDay(_lastReviewedAt!, now);
    final signature = [
      next.enabled,
      next.hour,
      next.minute,
      _dueCount,
      _reviewActivityKnown,
      studiedToday,
      now.year,
      now.month,
      now.day,
      now.timeZoneOffset.inMinutes,
    ].join(':');
    if (!force && signature == _lastAppliedSignature) return;

    try {
      final dueCount = _dueCount;
      if (!next.enabled) {
        if (persistDisabled) {
          await platform.apply(next, dueCount: dueCount, studiedToday: true);
        } else {
          await platform.cancel();
        }
      } else if (dueCount == null ||
          dueCount <= 0 ||
          !_reviewActivityKnown ||
          studiedToday) {
        await platform.cancel();
      } else {
        await platform.apply(next, dueCount: dueCount, studiedToday: false);
      }
      _lastAppliedSignature = signature;
    } catch (_) {
      _lastAppliedSignature = null;
      rethrow;
    }
  }

  void _armDayBoundaryTimer() {
    _dayBoundaryTimer?.cancel();
    if (_ownerId == null) return;
    final now = clock().toLocal();
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    final delay = tomorrow.difference(now) + const Duration(milliseconds: 1);
    _dayBoundaryTimer = Timer(delay, () {
      _dayBoundaryTimer = null;
      unawaited(
        reconcile(
          dueCount: _dueCount,
          lastReviewedAt: _lastReviewedAt,
          reviewActivityKnown: _reviewActivityKnown,
        ),
      );
    });
  }

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final run = _operationTail.then((_) => operation());
    _operationTail = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  static bool _sameLocalDay(DateTime first, DateTime second) {
    final a = first.toLocal();
    final b = second.toLocal();
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _dayBoundaryTimer?.cancel();
    _dayBoundaryTimer = null;
    super.dispose();
  }
}
