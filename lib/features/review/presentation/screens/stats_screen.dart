import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:health_flutter_shared/health_flutter_shared.dart'
    show AppSwitcher, HealthWebApp;

import '../../../../theme/ui_tokens.dart';
import '../../application/review_controller.dart';
import '../../application/stats_service.dart';
import '../../data/recall_api.dart';
import '../../domain/stats_models.dart';
import '../widgets/due_forecast_chart.dart';
import '../widgets/retention_panel.dart';
import '../widgets/review_heatmap.dart';

/// Stats v2: headline tiles, a 26-week review heatmap, a 14-day due forecast,
/// and true-retention (30/90d). The three chart sections load independently —
/// a failed forecast can't blank the heatmap.
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
  int _retentionWindow = 30;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  void _fetch() {
    _reviewLog = _service.loadReviewLog();
    _dueDates = _service.loadDueDates();
  }

  Future<void> reload() async {
    setState(_fetch);
    await Future.wait([
      _reviewLog.catchError((_) => <ReviewLogEntry>[]),
      _dueDates.catchError((_) => <DateTime>[]),
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
          Text('Stats', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: UiSpacing.md),

          // Session tiles (live from the controller).
          ListenableBuilder(
            listenable: widget.controller,
            builder: (context, _) {
              final s = widget.controller.state;
              return _metricStrip(const Key('recall_stats_session_strip'), [
                ('This session', '${s.reviewedThisSession}'),
                ('Due now', '${s.dueRemaining}'),
                ('New left', '${s.newRemaining}'),
              ]);
            },
          ),
          const SizedBox(height: UiSpacing.sm),

          // Recall / streak / count tiles (from the review log).
          _asyncSection<List<ReviewLogEntry>>(
            future: _reviewLog,
            builder: (log) {
              final t = StatsService.tileStats(log, today: today);
              return _metricStrip(const Key('recall_stats_history_strip'), [
                ('Recall · 30d', t.recall),
                ('Streak', '${t.streak}${t.streak == 1 ? ' day' : ' days'}'),
                ('Reviews · 30d', '${t.reviews}'),
              ]);
            },
          ),
          const SizedBox(height: UiSpacing.lg),

          // Heatmap.
          _asyncSection<List<ReviewLogEntry>>(
            future: _reviewLog,
            label: 'heatmap',
            builder: (log) => ReviewHeatmap(
              days: StatsService.buildHeatmap(log, today: today),
            ),
          ),
          const SizedBox(height: UiSpacing.lg),

          // Due forecast (independent query).
          _asyncSection<List<DateTime>>(
            future: _dueDates,
            label: 'forecast',
            builder: (due) => DueForecastChart(
              days: StatsService.buildForecast(due, today: today),
            ),
          ),
          const SizedBox(height: UiSpacing.lg),

          // True retention (shares the review-log fetch, own window toggle).
          _asyncSection<List<ReviewLogEntry>>(
            future: _reviewLog,
            label: 'retention',
            builder: (log) => RetentionPanel(
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
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(UiSpacing.lg),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snap.hasError || !snap.hasData) {
          return Container(
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
        }
        return builder(snap.data as T);
      },
    );
  }

  Widget _metricStrip(Key key, List<(String, String)> metrics) => Container(
    key: key,
    decoration: const BoxDecoration(
      border: Border(
        top: BorderSide(color: UiColors.borderSubtle),
        bottom: BorderSide(color: UiColors.borderSubtle),
      ),
    ),
    child: IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < metrics.length; i++) ...[
            if (i > 0)
              const SizedBox(
                width: 1,
                child: ColoredBox(color: UiColors.borderSubtle),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: UiSpacing.md,
                  horizontal: UiSpacing.xs,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FittedBox(
                      child: Text(
                        metrics[i].$2,
                        style: const TextStyle(
                          color: UiColors.textPrimary,
                          fontFamily: 'monospace',
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      metrics[i].$1,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: UiColors.textMuted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}
