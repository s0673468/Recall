// Debug-only paint observation around the unchanged production study surface.
// All accepted identities belong to the generated 20-card benchmark fixture.
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/study_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/card_face.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

class SyntheticStudyFrameProbe {
  SyntheticStudyFrameProbe(this.controller);

  final ReviewController controller;
  final scopeKey = GlobalKey(debugLabel: 'synthetic-study-paint-scope');
  int? _paintedCardId;

  Widget screen() => SyntheticStudyFrame(
    probe: this,
    child: Theme(
      data: buildRecallTheme(),
      child: StudyScreen(controller: controller, nativeIos: false),
    ),
  );

  /// Framework paint completion only; this does not observe GPU presentation.
  Future<void> waitForPaintedCard(int cardId) async {
    while (!hasPaintedCard(cardId)) {
      requestPaint();
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  void requestPaint() =>
      scopeKey.currentContext?.findRenderObject()?.markNeedsPaint();

  bool hasPaintedCard(int cardId) =>
      _paintedCardId == cardId && _visibleProductionCard(cardId);

  void _afterPaint() {
    final cardId = controller.state.current?.id;
    _paintedCardId = cardId != null && _visibleProductionCard(cardId)
        ? cardId
        : null;
  }

  bool _visibleProductionCard(int cardId) {
    if (!kDebugMode ||
        cardId < 1 ||
        cardId > 20 ||
        controller.state.current?.id != cardId) {
      return false;
    }
    final scope = scopeKey.currentContext;
    if (scope is! Element) return false;
    final studies = <Element>[];
    void findStudy(Element element) {
      final widget = element.widget;
      if (widget is StudyScreen && identical(widget.controller, controller)) {
        studies.add(element);
      } else {
        element.visitChildElements(findStudy);
      }
    }

    scope.visitChildElements(findStudy);
    if (studies.length != 1) return false;
    final cards = <Element>[];
    void findCard(Element element) {
      if (element.widget.key == ValueKey('study_card_$cardId')) {
        cards.add(element);
      }
      element.visitChildElements(findCard);
    }

    studies.single.visitChildElements(findCard);
    if (cards.length != 1 || !_paintedOnScreen(cards.single)) return false;
    final fronts = <Element>[];
    void findFront(Element element) {
      final widget = element.widget;
      if (widget is CardFace &&
          widget.cacheKey == '$cardId:front' &&
          widget.html == 'Synthetic front $cardId') {
        fronts.add(element);
      }
      element.visitChildElements(findFront);
    }

    cards.single.visitChildElements(findFront);
    return fronts.length == 1 && _paintedOnScreen(fronts.single);
  }

  bool _paintedOnScreen(Element element) {
    final box = element.findRenderObject();
    if (box is! RenderBox ||
        !box.attached ||
        !box.hasSize ||
        box.debugNeedsLayout ||
        box.debugNeedsPaint ||
        box.size.isEmpty) {
      return false;
    }
    final view = View.of(element);
    final viewport = Offset.zero & (view.physicalSize / view.devicePixelRatio);
    final bounds = box.localToGlobal(Offset.zero) & box.size;
    if (!bounds.isFinite || !bounds.overlaps(viewport)) return false;
    RenderObject? ancestor = box;
    while (ancestor != null) {
      if (ancestor is RenderOffstage && ancestor.offstage) return false;
      if (ancestor is RenderOpacity &&
          ui.Color.getAlphaFromOpacity(ancestor.opacity) == 0) {
        return false;
      }
      if (ancestor is RenderAnimatedOpacity &&
          ui.Color.getAlphaFromOpacity(ancestor.opacity.value) == 0) {
        return false;
      }
      ancestor = ancestor.parent;
    }
    return true;
  }
}

/// A positive marker comes from painting the real subtree, never from mounting
/// its keys or from an unrelated parent's post-frame callback alone.
class SyntheticStudyFrame extends SingleChildRenderObjectWidget {
  SyntheticStudyFrame({required this.probe, required super.child})
    : super(key: probe.scopeKey);

  final SyntheticStudyFrameProbe probe;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _StudyFrameRenderBox(probe._afterPaint);

  @override
  void updateRenderObject(
    BuildContext context,
    _StudyFrameRenderBox renderObject,
  ) {
    renderObject.onPaint = probe._afterPaint;
  }
}

class _StudyFrameRenderBox extends RenderProxyBox {
  _StudyFrameRenderBox(this.onPaint);

  VoidCallback onPaint;

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    onPaint();
  }
}
