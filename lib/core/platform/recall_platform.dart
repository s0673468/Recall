import 'package:flutter/foundation.dart';

/// True only for Recall's compiled native iOS app, never for its web/PWA build.
///
/// The optional values keep platform branching deterministic in widget tests.
bool recallRunsAsNativeIos({bool? isWeb, TargetPlatform? targetPlatform}) =>
    !(isWeb ?? kIsWeb) &&
    (targetPlatform ?? defaultTargetPlatform) == TargetPlatform.iOS;

/// True only for Recall's compiled native Android app.
bool recallRunsAsNativeAndroid({bool? isWeb, TargetPlatform? targetPlatform}) =>
    !(isWeb ?? kIsWeb) &&
    (targetPlatform ?? defaultTargetPlatform) == TargetPlatform.android;

/// Whether a platform can use Recall's app-container native integrations.
bool recallRunsAsNativeMobile({bool? isWeb, TargetPlatform? targetPlatform}) =>
    recallRunsAsNativeIos(isWeb: isWeb, targetPlatform: targetPlatform) ||
    recallRunsAsNativeAndroid(isWeb: isWeb, targetPlatform: targetPlatform);
