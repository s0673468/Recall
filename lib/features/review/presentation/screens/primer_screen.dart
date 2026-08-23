import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../../core/widgets/recall_surfaces.dart';
import '../../../../theme/ui_tokens.dart';
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

  String? get _module {
    for (final node in conceptNodes) {
      if (node.nodeId == page.nodeId) return node.module;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final module = _module;
    final bodyStyle = Theme.of(context).textTheme.titleLarge!.copyWith(
      color: UiColors.textPrimary,
      height: 1.4,
      fontWeight: FontWeight.w400,
    );

    return Scaffold(
      backgroundColor: UiColors.canvas,
      appBar: AppBar(
        backgroundColor: UiColors.canvas,
        foregroundColor: UiColors.textPrimary,
        elevation: 0,
        title: const Text('Primer'),
      ),
      body: ColoredBox(
        color: UiColors.canvas,
        child: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(
                padding: const EdgeInsets.all(UiSpacing.lg),
                children: [
                  if (module != null && module.isNotEmpty) ...[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _ModuleChip(module: module),
                    ),
                    const SizedBox(height: UiSpacing.sm),
                  ],
                  Text(
                    page.title,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      color: UiColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: UiSpacing.lg),
                  RecallHeroPanel(
                    key: const Key('recall_primer_hero'),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (page.figureSvg case final figureSvg?)
                          Padding(
                            padding: const EdgeInsets.only(
                              bottom: UiSpacing.lg,
                            ),
                            // The scroll view gives no height bound, and an
                            // unbounded SvgPicture asserts in layout — pin the
                            // figure to the spec's ~600x360 canvas ratio and let
                            // BoxFit.contain letterbox any other aspect.
                            child: AspectRatio(
                              aspectRatio: 600 / 360,
                              child: SvgPicture.string(
                                figureSvg,
                                key: ValueKey(
                                  'recall_primer_figure_${page.nodeId}',
                                ),
                                fit: BoxFit.contain,
                                errorBuilder: (_, _, _) =>
                                    const SizedBox.shrink(),
                              ),
                            ),
                          ),
                        CardFace(
                          html: page.bodyHtml,
                          hasLatex: true,
                          revealCloze: true,
                          selectable: false,
                          textAlign: TextAlign.start,
                          // Parser caches validate the body text as well as
                          // this stable identity, so an in-session refresh can
                          // never reuse an older primer revision.
                          cacheKey: 'primer:${page.nodeId}',
                          style: bodyStyle,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: UiSpacing.xl),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ModuleChip extends StatelessWidget {
  final String module;

  const _ModuleChip({required this.module});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(
      horizontal: UiSpacing.sm,
      vertical: UiSpacing.xs,
    ),
    decoration: BoxDecoration(
      color: UiColors.primaryMuted,
      borderRadius: BorderRadius.circular(UiRadii.pill),
    ),
    child: Text(
      module,
      style: const TextStyle(
        color: UiColors.primary,
        fontSize: 11,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}
