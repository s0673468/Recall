import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  Future<void> apply(StudyReminderSettings settings);
  Future<void> cancel();
}

class MethodChannelStudyReminderPlatform implements StudyReminderPlatform {
  static const _channel = MethodChannel('com.german.ankiReview/studyReminder');

  const MethodChannelStudyReminderPlatform();

  bool get _isNativeIos =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  @override
  Future<bool> requestPermission() async {
    if (!_isNativeIos) return true;
    return await _channel.invokeMethod<bool>('requestPermission') ?? false;
  }

  @override
  Future<void> apply(StudyReminderSettings settings) async {
    if (!_isNativeIos) return;
    await _channel.invokeMethod<void>('apply', {
      'enabled': settings.enabled,
      'hour': settings.hour,
      'minute': settings.minute,
    });
  }

  @override
  Future<void> cancel() async {
    if (!_isNativeIos) return;
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
  String? _ownerId;

  StudyReminderSettings _value = const StudyReminderSettings(
    enabled: false,
    hour: defaultHour,
    minute: defaultMinute,
  );

  StudyReminderController({
    this.platform = const MethodChannelStudyReminderPlatform(),
    Future<SharedPreferences> Function()? prefsLoader,
  }) : _prefsLoader = prefsLoader ?? SharedPreferences.getInstance;

  StudyReminderSettings get value => _value;

  Future<void> initialize({String? ownerId, bool apply = true}) async {
    _ownerId = ownerId;
    if (ownerId == null) {
      _value = const StudyReminderSettings(
        enabled: false,
        hour: defaultHour,
        minute: defaultMinute,
      );
      if (apply) await platform.cancel();
      notifyListeners();
      return;
    }
    final prefs = await _prefsLoader();
    _value = StudyReminderSettings(
      enabled: prefs.getBool(_key(_enabledKey)) ?? false,
      hour: (prefs.getInt(_key(_hourKey)) ?? defaultHour).clamp(0, 23),
      minute: (prefs.getInt(_key(_minuteKey)) ?? defaultMinute).clamp(0, 59),
    );
    if (apply) await platform.apply(_value);
    notifyListeners();
  }

  Future<void> activateOwner(String ownerId) => initialize(ownerId: ownerId);

  Future<void> releaseOwner() async {
    try {
      await platform.cancel();
    } finally {
      _ownerId = null;
      _value = const StudyReminderSettings(
        enabled: false,
        hour: defaultHour,
        minute: defaultMinute,
      );
      notifyListeners();
    }
  }

  Future<bool> setEnabled(bool enabled) async {
    _requireOwner();
    if (enabled && !await platform.requestPermission()) {
      await platform.apply(_value.copyWith(enabled: false));
      return false;
    }
    await _commit(_value.copyWith(enabled: enabled));
    return true;
  }

  Future<void> setTime({required int hour, required int minute}) async {
    _requireOwner();
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
      throw RangeError('Reminder time must be a valid local time.');
    }
    await _commit(_value.copyWith(hour: hour, minute: minute));
  }

  /// Stops account-scoped delivery without erasing the user's preference.
  /// A later sign-in re-applies the saved setting during initialization.
  Future<void> cancelPending() => platform.cancel();

  String _key(String base) {
    final ownerId = _ownerId;
    if (ownerId == null) throw StateError('A signed-in owner is required.');
    return '$base:$ownerId';
  }

  void _requireOwner() => _key(_enabledKey);

  Future<void> _commit(StudyReminderSettings next) async {
    // Schedule first. If native delivery fails, don't persist a setting the
    // app could misleadingly show as active.
    await platform.apply(next);
    final prefs = await _prefsLoader();
    await Future.wait([
      prefs.setBool(_key(_enabledKey), next.enabled),
      prefs.setInt(_key(_hourKey), next.hour),
      prefs.setInt(_key(_minuteKey), next.minute),
    ]);
    _value = next;
    notifyListeners();
  }
}
