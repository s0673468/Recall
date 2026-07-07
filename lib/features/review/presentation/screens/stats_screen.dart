import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:health_flutter_shared/health_flutter_shared.dart'
    show AppSwitcher, HealthWebApp, scopedPanelColor;

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
              return Row(
                children: [
                  _tile('This session', '${s.reviewedThisSession}'),
                  const SizedBox(width: UiSpacing.sm),
                  _tile('Due now', '${s.dueRemaining}'),
                  const SizedBox(width: UiSpacing.sm),
                  _tile('New left', '${s.newRemaining}'),
                ],
              );
            },
          ),
          const SizedBox(height: UiSpacing.sm),

          // Recall / streak / count tiles (from the review log).
          _asyncSection<List<ReviewLogEntry>>(
            future: _reviewLog,
            builder: (log) {
              final t = StatsService.tileStats(log, today: today);
              return Row(
                children: [
                  _tile('Recall · 30d', t.recall),
                  const SizedBox(width: UiSpacing.sm),
                  _tile('Streak', '${t.streak}${t.streak == 1 ? ' day' : ' days'}'),
                  const SizedBox(width: UiSpacing.sm),
                  _tile('Reviews · 30d', '${t.reviews}'),
                ],
              );
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
            decoration: BoxDecoration(
              color: scopedPanelColor(context),
              borderRadius: BorderRadius.circular(UiRadius.lg),
              border: Border.all(color: UiColors.border),
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

  Widget _tile(String label, String value) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(
        vertical: UiSpacing.md,
        horizontal: UiSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: scopedPanelColor(context),
        borderRadius: BorderRadius.circular(UiRadius.lg),
        border: Border.all(color: UiColors.border),
      ),
      child: Column(
        children: [
          FittedBox(
            child: Text(
              value,
              style: const TextStyle(
                color: UiColors.primary,
                fontSize: 24,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(color: UiColors.textMuted, fontSize: 12),
          ),
        ],
      ),
    ),
  );
}
