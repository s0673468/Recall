import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../../theme/ui_tokens.dart';
import '../../domain/primer_layout.dart';
import '../../domain/stats_models.dart';
import '../widgets/card_face.dart';

/// Read-only concept primer rendered through the same HTML/LaTeX pipeline as a
/// study card.
class PrimerScreen extends StatelessWidget {
  final ConceptPage page;
  final List<ConceptNodeInfo> conceptNodes;

  const PrimerScreen({
    super.key,
    required this.page,
    required this.conceptNodes,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: UiColors.canvas,
    appBar: AppBar(
      backgroundColor: UiColors.canvas,
      foregroundColor: UiColors.textPrimary,
      elevation: 0,
      title: const Text('Read'),
    ),
    body: PrimerContent(page: page, conceptNodes: conceptNodes),
  );
}

/// The same independently scrolling primer used by routes and the Study pane.
class PrimerContent extends StatelessWidget {
  final ConceptPage page;
  final List<ConceptNodeInfo> conceptNodes;

  const PrimerContent({
    super.key,
    required this.page,
    required this.conceptNodes,
  });

  String? get _module {
    for (final node in conceptNodes) {
      if (node.nodeId == page.nodeId) return node.module;
    }
    return null;
  }

  // Parser caches validate the body text as well as this stable identity, so
  // an in-session refresh can never reuse an older primer revision.
  Widget _body(String html, String cacheKey, TextStyle style) => CardFace(
    html: html,
    hasLatex: true,
    revealCloze: true,
    selectable: false,
    textAlign: TextAlign.start,
    cacheKey: cacheKey,
    style: style,
  );

  /// The body split at the extra figures' paragraphs, each figure inline with
  /// the hero figure's box and spacing. Text runs get distinct cache keys.
  List<Widget> _bodyWithExtraFigures(TextStyle style) {
    var textIndex = 0;
    return [
      for (final block in layoutPrimerBody(page.bodyHtml, page.extraFigures))
        switch (block) {
          PrimerTextBlock(:final html) => _body(
            html,
            'primer:${page.nodeId}:${textIndex++}',
            style,
          ),
          PrimerFigureBlock(:final index, :final figure) => Padding(
            padding: const EdgeInsets.symmetric(vertical: UiSpacing.lg),
            child: _PrimerFigure(
              svg: figure.svg,
              figureKey: ValueKey(
                'recall_primer_extra_figure_${page.nodeId}_$index',
              ),
            ),
          ),
        },
    ];
  }

  @override
  Widget build(BuildContext context) {
    final module = _module;
    final bodyStyle = Theme.of(context).textTheme.bodyLarge!.copyWith(
      color: UiColors.textSecondary,
      fontSize: 18,
      height: 1.75,
      fontWeight: FontWeight.w400,
    );

    return ColoredBox(
      color: UiColors.canvas,
      child: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.all(UiSpacing.lg),
              children: [
                Text(
                  page.title,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    color: UiColors.textPrimary,
                    fontSize: 28,
                    height: 1.25,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (module != null && module.isNotEmpty) ...[
                  const SizedBox(height: UiSpacing.sm),
                  Text(
                    module,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: UiColors.textMuted),
                  ),
                ],
                const SizedBox(height: UiSpacing.xl),
                KeyedSubtree(
                  key: const Key('recall_primer_hero'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (page.figureSvg case final figureSvg?)
                        Padding(
                          padding: const EdgeInsets.only(bottom: UiSpacing.lg),
                          child: _PrimerFigure(
                            svg: figureSvg,
                            figureKey: ValueKey(
                              'recall_primer_figure_${page.nodeId}',
                            ),
                          ),
                        ),
                      if (page.extraFigures.isEmpty)
                        _body(page.bodyHtml, 'primer:${page.nodeId}', bodyStyle)
                      else
                        ..._bodyWithExtraFigures(bodyStyle),
                    ],
                  ),
                ),
                const SizedBox(height: UiSpacing.xl),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A primer figure. The scroll view gives no height bound, and an unbounded
/// SvgPicture asserts in layout — pin the figure to the spec's ~600x360 canvas
/// ratio and let BoxFit.contain letterbox any other aspect. Markup that fails
/// to parse renders nothing instead of breaking the page.
class _PrimerFigure extends StatelessWidget {
  final String svg;
  final Key figureKey;

  const _PrimerFigure({required this.svg, required this.figureKey});

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: 600 / 360,
    child: SvgPicture.string(
      svg,
      key: figureKey,
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    ),
  );
}
