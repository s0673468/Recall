import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/platform/recall_platform.dart';
import '../../../../navigation/recall_page_route.dart';
import '../../../../theme/ui_tokens.dart';
import '../../application/remediation_service.dart';
import '../../data/local_review_store.dart';
import '../../data/recall_api.dart';
import '../../domain/stats_models.dart';
import '../screens/primer_screen.dart';

/// The shared presentation for local lapse-remediation rows.
class RemediationRows extends StatelessWidget {
  final List<ConceptPage> pages;
  final ValueChanged<ConceptPage> onTap;

  const RemediationRows({super.key, required this.pages, required this.onTap});

  @override
  Widget build(BuildContext context) {
    if (pages.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Reread'),
        const SizedBox(height: UiSpacing.xs),
        for (final page in pages)
          RereadRow(page: page, onTap: () => onTap(page)),
      ],
    );
  }
}

class RereadRow extends StatelessWidget {
  final ConceptPage page;
  final VoidCallback onTap;

  const RereadRow({super.key, required this.page, required this.onTap});

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      child: Container(
        key: ValueKey('recall_reread_row_${page.nodeId}'),
        constraints: const BoxConstraints(minHeight: 52),
        padding: const EdgeInsets.symmetric(horizontal: UiSpacing.sm),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: UiColors.borderSubtle)),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.refresh_outlined,
              color: UiColors.primary,
              size: 18,
            ),
            const SizedBox(width: UiSpacing.md),
            Expanded(
              child: Text(
                'Reread: ${page.title}',
                style: const TextStyle(
                  color: UiColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const Icon(
              Icons.chevron_right,
              color: UiColors.textMuted,
              size: 20,
            ),
          ],
        ),
      ),
    ),
  );
}

/// Loads and owns completion for the done-screen version of the rows. ReadScreen
/// already has the same data in hand and uses [RemediationRows] directly.
class RemediationSection extends StatefulWidget {
  final RecallApi api;
  final LocalReviewStore store;
  final int revision;

  const RemediationSection({
    super.key,
    required this.api,
    required this.store,
    this.revision = 0,
  });

  @override
  State<RemediationSection> createState() => _RemediationSectionState();
}

class _RemediationSectionState extends State<RemediationSection> {
  late Future<RemediationData> _data;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(covariant RemediationSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api ||
        oldWidget.store != widget.store ||
        oldWidget.revision != widget.revision) {
      _reload();
    }
  }

  void _reload() {
    _data = RemediationService(api: widget.api, store: widget.store).load();
  }

  Future<void> _openPrimer(
    BuildContext context,
    RemediationData data,
    ConceptPage page,
  ) async {
    await Navigator.of(context).push(
      buildRecallPageRoute<void>(
        nativeIos: recallRunsAsNativeIos(),
        builder: (_) =>
            PrimerScreen(page: page, conceptNodes: data.conceptNodes),
      ),
    );
    try {
      await widget.store.completeRemediation(page.nodeId);
    } catch (error) {
      debugPrint('Recall: remediation completion skipped (non-fatal): $error');
    }
    if (mounted) setState(_reload);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<RemediationData>(
    future: _data,
    builder: (context, snapshot) {
      if (!snapshot.hasData) return const SizedBox.shrink();
      final data = snapshot.data!;
      final pages = data.visiblePages;
      if (pages.isEmpty) return const SizedBox.shrink();
      return RemediationRows(
        pages: pages,
        onTap: (page) => unawaited(_openPrimer(context, data, page)),
      );
    },
  );
}
