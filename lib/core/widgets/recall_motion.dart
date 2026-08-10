import 'package:flutter/material.dart';

/// Recall's restrained motion language.
///
/// Transitions are intentionally short and travel only a few pixels so motion
/// clarifies state changes without competing with the content. System reduced-
/// motion preferences collapse every transition to an immediate swap.
abstract final class RecallMotion {
  static const quick = Duration(milliseconds: 180);
  static const standard = Duration(milliseconds: 260);
  static const curve = Curves.easeOutCubic;
  static const reverseCurve = Curves.easeInCubic;

  static Duration duration(BuildContext context, [Duration value = standard]) =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false
      ? Duration.zero
      : value;
}

/// Fades and gently lifts between mutually exclusive pieces of UI.
class RecallMotionSwap extends StatelessWidget {
  final Widget child;
  final Duration duration;
  final Duration reverseDuration;
  final double travel;
  final AlignmentGeometry alignment;

  const RecallMotionSwap({
    super.key,
    required this.child,
    this.duration = RecallMotion.standard,
    this.reverseDuration = RecallMotion.quick,
    this.travel = 0.025,
    this.alignment = Alignment.center,
  });

  @override
  Widget build(BuildContext context) {
    final resolvedDuration = RecallMotion.duration(context, duration);
    final resolvedReverseDuration = RecallMotion.duration(
      context,
      reverseDuration,
    );
    return AnimatedSwitcher(
      duration: resolvedDuration,
      reverseDuration: resolvedReverseDuration,
      switchInCurve: RecallMotion.curve,
      switchOutCurve: RecallMotion.reverseCurve,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: alignment,
        children: [...previousChildren, ?currentChild],
      ),
      transitionBuilder: (child, animation) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: RecallMotion.curve,
          reverseCurve: RecallMotion.reverseCurve,
        );
        return AnimatedBuilder(
          animation: animation,
          child: FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: Offset(0, travel),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          ),
          builder: (context, animatedChild) {
            final exiting = animation.status == AnimationStatus.reverse;
            return IgnorePointer(
              ignoring: exiting,
              child: ExcludeSemantics(excluding: exiting, child: animatedChild),
            );
          },
        );
      },
      child: child,
    );
  }
}

/// An animated tab body that retains every tab's state.
///
/// Unlike an [AnimatedSwitcher], this keeps inactive children mounted. That is
/// important for Recall's independently loaded Decks, Stats, and Read tabs.
class RecallAnimatedIndexedStack extends StatelessWidget {
  final int index;
  final List<Widget> children;

  const RecallAnimatedIndexedStack({
    super.key,
    required this.index,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    assert(index >= 0 && index < children.length);
    final duration = RecallMotion.duration(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        for (var childIndex = 0; childIndex < children.length; childIndex++)
          IgnorePointer(
            ignoring: childIndex != index,
            child: ExcludeSemantics(
              excluding: childIndex != index,
              child: FocusScope(
                canRequestFocus: childIndex == index,
                child: AnimatedOpacity(
                  key: ValueKey('recall_tab_opacity_$childIndex'),
                  opacity: childIndex == index ? 1 : 0,
                  duration: duration,
                  curve: RecallMotion.curve,
                  child: AnimatedSlide(
                    offset: childIndex == index
                        ? Offset.zero
                        : Offset(childIndex < index ? -0.035 : 0.035, 0),
                    duration: duration,
                    curve: RecallMotion.curve,
                    child: TickerMode(
                      enabled: childIndex == index,
                      child: RepaintBoundary(child: children[childIndex]),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
