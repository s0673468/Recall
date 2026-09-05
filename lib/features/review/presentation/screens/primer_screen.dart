import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

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
    final bodyStyle = Theme.of(context).textTheme.bodyLarge!.copyWith(
      color: UiColors.textSecondary,
      fontSize: 18,
      height: 1.75,
      fontWeight: FontWeight.w400,
    );

    return Scaffold(
      backgroundColor: UiColors.canvas,
      appBar: AppBar(
        backgroundColor: UiColors.canvas,
        foregroundColor: UiColors.textPrimary,
        elevation: 0,
        title: const Text('Read'),
      ),
      body: ColoredBox(
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
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: UiColors.textMuted,
                      ),
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
