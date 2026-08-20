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
    final bodyStyle = Theme.of(context).textTheme.titleLarge!.copyWith(
      color: UiColors.textPrimary,
      height: 1.4,
      fontWeight: FontWeight.w400,
    );

    return Scaffold(
      backgroundColor: UiColors.canvas,
      appBar: AppBar(
        backgroundColor: UiColors.sidebar,
        foregroundColor: UiColors.textPrimary,
        elevation: 0,
        title: const Text('Primer'),
      ),
      body: ColoredBox(
        color: UiColors.canvas,
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(UiSpacing.lg),
            children: [
              Text(
                page.title,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: UiColors.textPrimary,
                ),
              ),
              if (module != null && module.isNotEmpty) ...[
                const SizedBox(height: UiSpacing.sm),
                Align(
                  alignment: Alignment.centerLeft,
                  child: _ModuleChip(module: module),
                ),
              ],
              const SizedBox(height: UiSpacing.lg),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(UiSpacing.lg),
                decoration: BoxDecoration(
                  color: UiColors.panel,
                  borderRadius: BorderRadius.circular(UiRadii.group),
                  border: Border.all(color: UiColors.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (page.figureSvg case final figureSvg?)
                      Padding(
                        padding: const EdgeInsets.only(bottom: UiSpacing.lg),
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
                            errorBuilder: (_, _, _) => const SizedBox.shrink(),
                          ),
                        ),
                      ),
                    CardFace(
                      html: page.bodyHtml,
                      hasLatex: true,
                      revealCloze: true,
                      selectable: false,
                      textAlign: TextAlign.start,
                      // Unlike card faces, a primer body can change server-side
                      // within a session (rows are updated in place), so the
                      // memo key must vary with content, not just identity.
                      cacheKey:
                          'primer:${page.nodeId}:${page.bodyHtml.hashCode}',
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
      color: UiColors.secondary,
      borderRadius: BorderRadius.circular(UiRadii.pill),
    ),
    child: Text(
      module,
      style: const TextStyle(color: UiColors.textMuted, fontSize: 12),
    ),
  );
}
