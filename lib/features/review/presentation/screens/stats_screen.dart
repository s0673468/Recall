import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:health_anki_flutter/vendored/health_flutter_shared.dart'
    show AppSwitcher, HealthWebApp;

import '../../../../core/widgets/recall_motion.dart';
import '../../../../core/widgets/recall_page_header.dart';
import '../../../../core/widgets/recall_surfaces.dart';
import '../../../../theme/ui_tokens.dart';
import '../../application/review_controller.dart';
import '../../application/stats_service.dart';
import '../../data/recall_api.dart';
import '../../domain/stats_models.dart';
import '../widgets/concept_retention_panel.dart';
import '../widgets/due_forecast_chart.dart';
import '../widgets/retention_panel.dart';
import '../widgets/review_heatmap.dart';

/// The bundled inputs for the Concepts (METIS node-retention) section: the
/// review log, the note guid -> tags map, and the concept metadata.
typedef _ConceptInputs = ({
  List<ReviewLogEntry> log,
  Map<String, String> tags,
  List<ConceptNodeInfo> nodes,
  List<ConceptPage> pages,
});

/// Stats v2: headline tiles, a 26-week review heatmap, a 14-day due forecast,
/// true-retention (30/90d), and METIS concept retention. The chart sections load
/// independently — a failed forecast can't blank the heatmap.
class StatsScreen extends StatefulWidget {
  final RecallApi api;
  final ReviewController controller;

  const StatsScreen({super.key, required this.api, required this.controller});

  @override
  State<StatsScreen> createState() => StatsScreenState();
}

class StatsScreenState extends State<StatsScreen> {
  late final StatsService _service = StatsService(widget.api);
  late Future<List<ReviewLogEntry>> _reviewLog;
  late Future<List<DateTime>> _dueDates;
  late Future<_ConceptInputs> _conceptData;
  int _retentionWindow = 30;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  void _fetch() {
    _reviewLog = _service.loadReviewLog();
    _dueDates = _service.loadDueDates();
    // The Concepts section needs the review log plus the node<->card tag map and
    // concept metadata/primers. Start each one-time fetch together and bundle
    // them so the section resolves (and fails) as one unit.
    _conceptData = () async {
      final tagsFuture = _service.loadNoteTags();
      final nodesFuture = _service.loadConceptNodes();
      final pagesFuture = _service.loadConceptPages();
      final results = await Future.wait<Object>([
        _reviewLog,
        tagsFuture,
        nodesFuture,
        pagesFuture,
      ]);
      return (
        log: results[0] as List<ReviewLogEntry>,
        tags: results[1] as Map<String, String>,
        nodes: results[2] as List<ConceptNodeInfo>,
        pages: results[3] as List<ConceptPage>,
      );
    }();
  }

  Future<void> reload() async {
    setState(_fetch);
    await Future.wait([
      _reviewLog.catchError((_) => <ReviewLogEntry>[]),
      _dueDates.catchError((_) => <DateTime>[]),
      _conceptData.catchError(
        (_) => (
          log: <ReviewLogEntry>[],
          tags: <String, String>{},
          nodes: <ConceptNodeInfo>[],
          pages: <ConceptPage>[],
        ),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    return RefreshIndicator(
      onRefresh: reload,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          UiSpacing.md,
          UiSpacing.md,
          UiSpacing.md,
          UiSpacing.lg,
        ),
        children: [
          const RecallPageHeader(
            eyebrow: 'Progress',
            title: 'Stats',
            subtitle: 'What is sticking, what is due, and where to focus next.',
          ),
          const SizedBox(height: UiSpacing.lg),

          // Retention is the one screen hero: the most meaningful learning
          // outcome, ahead of workload and activity telemetry.
          _asyncSection<List<ReviewLogEntry>>(
            future: _reviewLog,
            label: 'retention',
            builder: (log) => RetentionPanel(
              key: const Key('recall_retention_hero'),
              hero: true,
              summary: StatsService.computeRetention(
                log,
                now: today,
                windowDays: _retentionWindow,
              ),
              windowDays: _retentionWindow,
              onWindowChanged: (w) => setState(() => _retentionWindow = w),
            ),
          ),
          const SizedBox(height: UiSpacing.xl),

          const RecallSectionLabel(
            title: 'Current session',
            subtitle: 'The work immediately in front of you.',
          ),
          const SizedBox(height: UiSpacing.sm),

          // Session tiles (live from the controller).
          ListenableBuilder(
            listenable: widget.controller,
            builder: (context, _) {
              final s = widget.controller.state;
              return RecallMetricStrip(
                key: const Key('recall_stats_session_strip'),
                metrics: [
                  RecallMetric('Reviewed', '${s.reviewedThisSession}'),
                  RecallMetric(
                    'Due now',
                    '${s.dueRemaining}',
                    color: s.dueRemaining > 0 ? UiColors.primary : null,
                  ),
                  RecallMetric(
                    'New left',
                    '${s.newRemaining}',
                    color: s.newRemaining > 0 ? UiColors.chartBlue : null,
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: UiSpacing.xl),

          const RecallSectionLabel(
            title: 'Last 30 days',
            subtitle: 'Recall quality and consistency over time.',
          ),
          const SizedBox(height: UiSpacing.sm),

          // Recall / streak / count tiles (from the review log).
          _asyncSection<List<ReviewLogEntry>>(
            future: _reviewLog,
            builder: (log) {
              final t = StatsService.tileStats(log, today: today);
              return RecallMetricStrip(
                key: const Key('recall_stats_history_strip'),
                metrics: [
                  RecallMetric('Recall', t.recall),
                  RecallMetric(
                    'Streak',
                    '${t.streak}${t.streak == 1 ? ' day' : ' days'}',
                  ),
                  RecallMetric('Reviews', '${t.reviews}'),
                ],
              );
            },
          ),
          const SizedBox(height: UiSpacing.xl),

          const RecallSectionLabel(
            title: 'Activity',
            subtitle: 'Your review rhythm across the last 26 weeks.',
          ),
          const SizedBox(height: UiSpacing.sm),

          // Heatmap.
          _asyncSection<List<ReviewLogEntry>>(
            future: _reviewLog,
            label: 'heatmap',
            builder: (log) => ReviewHeatmap(
              days: StatsService.buildHeatmap(log, today: today),
            ),
          ),
          const SizedBox(height: UiSpacing.xl),

          const RecallSectionLabel(
            title: 'Work ahead',
            subtitle: 'The review load scheduled over the next two weeks.',
          ),
          const SizedBox(height: UiSpacing.sm),

          // Due forecast (independent query).
          _asyncSection<List<DateTime>>(
            future: _dueDates,
            label: 'forecast',
            builder: (due) => DueForecastChart(
              days: StatsService.buildForecast(due, today: today),
            ),
          ),
          const SizedBox(height: UiSpacing.xl),

          const RecallSectionLabel(
            title: 'Concepts to reinforce',
            subtitle: 'Weak signals surfaced from your recent answers.',
          ),
          const SizedBox(height: UiSpacing.sm),

          // Concepts — METIS node retention (weakest-first Again-rate).
          _asyncSection<_ConceptInputs>(
            future: _conceptData,
            label: 'concepts',
            builder: (data) {
              final result = StatsService.computeNodeRetention(
                reviewLog: data.log,
                noteTags: data.tags,
                conceptNodes: data.nodes,
                now: today,
              );
              return ConceptRetentionPanel(
                ranked: result.ranked,
                notEnoughData: result.notEnoughData,
                coveredNodeCount: result.coveredNodeCount,
                totalConcepts: data.nodes.length,
                conceptPages: data.pages,
                conceptNodes: data.nodes,
              );
            },
          ),
          const SizedBox(height: UiSpacing.xl),

          if (kIsWeb)
            const AppSwitcher(
              current: HealthWebApp.recall,
              alignment: WrapAlignment.center,
            ),
        ],
      ),
    );
  }

  /// A section that resolves its own future with isolated loading + error
  /// states, so one failing query can't blank the others.
  Widget _asyncSection<T>({
    required Future<T> future,
    required Widget Function(T data) builder,
    String? label,
  }) {
    return FutureBuilder<T>(
      future: future,
      builder: (context, snap) {
        late final Widget content;
        if (snap.connectionState != ConnectionState.done) {
          content = const Padding(
            key: ValueKey('stats_section_loading'),
            padding: EdgeInsets.all(UiSpacing.lg),
            child: Center(child: CircularProgressIndicator()),
          );
        } else if (snap.hasError || !snap.hasData) {
          content = Container(
            key: ValueKey('stats_section_error_$label'),
            width: double.infinity,
            padding: const EdgeInsets.all(UiSpacing.md),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: UiColors.borderSubtle)),
            ),
            child: Text(
              'Could not load ${label ?? 'section'}.',
              style: const TextStyle(color: UiColors.textMuted),
            ),
          );
        } else {
          content = KeyedSubtree(
            key: ValueKey('stats_section_content_$label'),
            child: builder(snap.data as T),
          );
        }
        return RecallMotionSwap(child: content);
      },
    );
  }
}
