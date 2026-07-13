import 'package:flutter/foundation.dart';

/// True only for Recall's compiled native iOS app, never for its web/PWA build.
///
/// The optional values keep platform branching deterministic in widget tests.
bool recallRunsAsNativeIos({bool? isWeb, TargetPlatform? targetPlatform}) =>
    !(isWeb ?? kIsWeb) &&
    (targetPlatform ?? defaultTargetPlatform) == TargetPlatform.iOS;
