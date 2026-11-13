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

  Widget _figure(PrimerFigureBlock block) => Padding(
    padding: const EdgeInsets.symmetric(vertical: UiSpacing.lg),
    child: _PrimerFigure(
      svg: block.figure.svg,
      figureKey: ValueKey(
        'recall_primer_extra_figure_${page.nodeId}_${block.index}',
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final module = _module;
    final blocks = layoutPrimerBody(
      page.bodyHtml,
      page.extraFigures,
      sections: true,
    );
    final sections = [
      for (final block in blocks)
        if (block is PrimerTextBlock && block.heading != null) block,
    ];
    final targets = {
      for (final section in sections) section.paragraphNumber!: GlobalKey(),
    };
    var textIndex = 0;
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
              key: PageStorageKey('recall_primer_scroll_${page.nodeId}'),
              padding: EdgeInsets.all(
                MediaQuery.sizeOf(context).width < 600
                    ? UiSpacing.md
                    : UiSpacing.lg,
              ),
              // Keep section targets mounted so even a distant contents link
              // can scroll directly to its heading.
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      page.title,
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(
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
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: UiColors.textMuted,
                        ),
                      ),
                    ],
                    if (sections.isNotEmpty) ...[
                      const SizedBox(height: UiSpacing.md),
                      Wrap(
                        key: const Key('recall_primer_contents'),
                        spacing: UiSpacing.xs,
                        children: [
                          for (final section in sections)
                            TextButton(
                              onPressed: () {
                                final target = targets[section.paragraphNumber]!
                                    .currentContext;
                                if (target != null) {
                                  Scrollable.ensureVisible(
                                    target,
                                    duration:
                                        MediaQuery.disableAnimationsOf(context)
                                        ? Duration.zero
                                        : const Duration(milliseconds: 200),
                                  );
                                }
                              },
                              child: Text(section.heading!),
                            ),
                        ],
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
                              padding: const EdgeInsets.only(
                                bottom: UiSpacing.lg,
                              ),
                              child: _PrimerFigure(
                                svg: figureSvg,
                                figureKey: ValueKey(
                                  'recall_primer_figure_${page.nodeId}',
                                ),
                              ),
                            ),
                          for (final block in blocks)
                            if (block is PrimerFigureBlock)
                              _figure(block)
                            else if (block is PrimerTextBlock) ...[
                              if (block.heading != null)
                                Padding(
                                  key: targets[block.paragraphNumber],
                                  padding: const EdgeInsets.only(
                                    top: UiSpacing.lg,
                                    bottom: UiSpacing.sm,
                                  ),
                                  child: Semantics(
                                    header: true,
                                    child: Text(
                                      block.heading!,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleLarge,
                                    ),
                                  ),
                                ),
                              _body(
                                block.html,
                                page.extraFigures.isEmpty && sections.isEmpty
                                    ? 'primer:${page.nodeId}'
                                    : 'primer:${page.nodeId}:${textIndex++}',
                                bodyStyle,
                              ),
                            ],
                        ],
                      ),
                    ),
                    const SizedBox(height: UiSpacing.xl),
                  ],
                ),
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
