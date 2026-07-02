import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:health_flutter_shared/health_flutter_shared.dart'
    show AppSwitcher, HealthWebApp, SignOutButton, SignOutButtonVariant;
import 'package:intl/intl.dart';

import '../../../../theme/ui_tokens.dart';
import '../../application/review_controller.dart';
import '../../data/recall_api.dart';

/// Stats: headline tiles (session/due/new + recall%/streak/30-day total) and a
/// 14-day review histogram.
class StatsScreen extends StatefulWidget {
  final RecallApi api;
  final ReviewController controller;

  const StatsScreen({super.key, required this.api, required this.controller});

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  late Future<List<({DateTime at, int rating})>> _reviews;

  @override
  void initState() {
    super.initState();
    _reviews = widget.api.fetchRecentReviews(days: 30);
  }

  void _reload() =>
      setState(() => _reviews = widget.api.fetchRecentReviews(days: 30));

  static DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  static int _streak(Set<DateTime> days) {
    if (days.isEmpty) return 0;
    final today = _dayOnly(DateTime.now());
    var cursor = days.contains(today)
        ? today
        : today.subtract(const Duration(days: 1));
    if (!days.contains(cursor)) return 0;
    var n = 0;
    while (days.contains(cursor)) {
      n++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return n;
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async => _reload(),
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
          FutureBuilder<List<({DateTime at, int rating})>>(
            future: _reviews,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.all(UiSpacing.xl),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (snap.hasError) {
                return Padding(
                  padding: const EdgeInsets.all(UiSpacing.md),
                  child: Text(
                    'Could not load history: ${snap.error}',
                    style: const TextStyle(color: UiColors.textMuted),
                  ),
                );
              }
              final reviews = snap.data ?? const [];
              final retained = reviews.where((r) => r.rating >= 2).length;
              final recall = reviews.isEmpty
                  ? '—'
                  : '${(retained / reviews.length * 100).round()}%';
              final days = {for (final r in reviews) _dayOnly(r.at)};
              final streak = _streak(days);
              return Column(
                children: [
                  Row(
                    children: [
                      _tile('Recall · 30d', recall),
                      const SizedBox(width: UiSpacing.sm),
                      _tile('Streak', '$streak${streak == 1 ? ' day' : ' days'}'),
                      const SizedBox(width: UiSpacing.sm),
                      _tile('Reviews · 30d', '${reviews.length}'),
                    ],
                  ),
                  const SizedBox(height: UiSpacing.lg),
                  _Histogram(reviews: [for (final r in reviews) r.at]),
                ],
              );
            },
          ),
          const SizedBox(height: UiSpacing.xl),
          // Web-only cross-app switcher. Recall has no settings surface, so
          // Stats (which already hosts sign-out) is its meta tab.
          if (kIsWeb) ...[
            const AppSwitcher(
              current: HealthWebApp.recall,
              alignment: WrapAlignment.center,
            ),
            const SizedBox(height: UiSpacing.md),
          ],
          Center(
            child: SignOutButton(
              onSignOut: widget.controller.signOut,
              email: widget.controller.currentUser?.email,
              variant: SignOutButtonVariant.text,
            ),
          ),
        ],
      ),
    );
  }

  Widget _tile(String label, String value) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(
        vertical: UiSpacing.md,
        horizontal: UiSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: UiColors.panel,
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

class _Histogram extends StatelessWidget {
  final List<DateTime> reviews;
  const _Histogram({required this.reviews});

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final days = [
      for (var i = 13; i >= 0; i--)
        DateTime(today.year, today.month, today.day).subtract(Duration(days: i)),
    ];
    final counts = {for (final d in days) d: 0};
    for (final r in reviews) {
      final key = DateTime(r.year, r.month, r.day);
      if (counts.containsKey(key)) counts[key] = counts[key]! + 1;
    }
    final maxCount = counts.values.fold(1, (a, b) => a > b ? a : b);

    return Container(
      padding: const EdgeInsets.all(UiSpacing.md),
      decoration: BoxDecoration(
        color: UiColors.panel,
        borderRadius: BorderRadius.circular(UiRadius.lg),
        border: Border.all(color: UiColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Reviews · last 14 days  (${reviews.length})',
            style: const TextStyle(
              color: UiColors.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: UiSpacing.md),
          SizedBox(
            height: 120,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final d in days)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text(
                            counts[d]! > 0 ? '${counts[d]}' : '',
                            style: const TextStyle(
                              color: UiColors.textMuted,
                              fontSize: 9,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Container(
                            height: (counts[d]! / maxCount) * 88 + 2,
                            decoration: BoxDecoration(
                              color: counts[d]! > 0
                                  ? UiColors.primary
                                  : UiColors.border,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            DateFormat('E').format(d).substring(0, 1),
                            style: const TextStyle(
                              color: UiColors.textMuted,
                              fontSize: 9,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
