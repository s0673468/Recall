import 'dart:async';

import 'package:flutter/services.dart';

import '../../../core/platform/recall_platform.dart';

typedef HapticCallback = void Function();

void _noHaptic() {}

/// Presentation feedback for the four tactile moments in a review.
///
/// The controller owns *when* feedback is valid; this injectable adapter owns
/// *how* it feels. Browser and non-iOS builds receive a no-op adapter so the
/// shared review flow never gains platform conditionals.
class ReviewHaptics {
  final HapticCallback _onReveal;
  final HapticCallback _onRating;
  final HapticCallback _onUndo;
  final HapticCallback _onCompletion;

  const ReviewHaptics({
    HapticCallback onReveal = _noHaptic,
    HapticCallback onRating = _noHaptic,
    HapticCallback onUndo = _noHaptic,
    HapticCallback onCompletion = _noHaptic,
  }) : _onReveal = onReveal,
       _onRating = onRating,
       _onUndo = onUndo,
       _onCompletion = onCompletion;

  factory ReviewHaptics.forPlatform({
    bool? isWeb,
    TargetPlatform? targetPlatform,
  }) {
    if (!recallRunsAsNativeIos(isWeb: isWeb, targetPlatform: targetPlatform)) {
      return const ReviewHaptics();
    }
    return ReviewHaptics(
      onReveal: () => unawaited(HapticFeedback.lightImpact()),
      onRating: () => unawaited(HapticFeedback.selectionClick()),
      onUndo: () => unawaited(HapticFeedback.mediumImpact()),
      onCompletion: () => unawaited(HapticFeedback.heavyImpact()),
    );
  }

  void reveal() => _onReveal();
  void rating() => _onRating();
  void undo() => _onUndo();
  void completion() => _onCompletion();
}
