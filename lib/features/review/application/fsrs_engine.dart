import 'package:fsrs/fsrs.dart';

import '../data/models.dart';

/// Wraps the FSRS-6 scheduler. Reconstructs a card from its cloud state, applies
/// a rating, and returns the columns to persist. FSRS is UTC-only.
class FsrsEngine {
  late Scheduler _scheduler;
  late List<double> _parameters;
  late double _desiredRetention;

  FsrsEngine({List<double>? parameters, double desiredRetention = 0.9}) {
    _configure(
      parameters: parameters ?? defaultParameters,
      desiredRetention: desiredRetention,
    );
  }

  List<double> get parameters => List.unmodifiable(_parameters);
  double get desiredRetention => _desiredRetention;

  void configure(FsrsSettings settings) {
    _configure(
      parameters: settings.parameters,
      desiredRetention: settings.desiredRetention,
    );
  }

  void resetToDefaults() {
    _configure(parameters: defaultParameters, desiredRetention: 0.9);
  }

  /// Update only the desired retention, keeping the current parameters. Used
  /// when the user changes the retention slider in settings.
  void setDesiredRetention(double desiredRetention) {
    _configure(parameters: _parameters, desiredRetention: desiredRetention);
  }

  void _configure({
    required List<double> parameters,
    required double desiredRetention,
  }) {
    _parameters = List<double>.unmodifiable(parameters);
    _desiredRetention = desiredRetention;
    _scheduler = Scheduler(
      parameters: _parameters,
      desiredRetention: _desiredRetention,
    );
  }

  static State _stateFromInt(int s) => switch (s) {
    2 => State.review,
    3 => State.relearning,
    _ => State.learning,
  };

  static int _stateToInt(State s) => switch (s) {
    State.review => 2,
    State.relearning => 3,
    State.learning => 1,
  };

  /// Build the FSRS card. A new card (state 0, no real stability/difficulty)
  /// becomes a fresh learning card so the first review initialises it.
  Card _build(ReviewCard c) {
    if (c.isNew || (c.stability ?? 0) <= 0) {
      return Card(cardId: c.id);
    }
    return Card(
      cardId: c.id,
      state: _stateFromInt(c.state),
      // Recall's cloud row predates fsrs.dart's transient `step` field. The
      // package restores learning cards to step 0 itself, but relearning cards
      // otherwise keep a null step and crash as soon as rating previews build.
      // Recall uses the package's single 10-minute relearning step, so step 0
      // is the exact durable reconstruction for a persisted relearning card.
      step: c.state == 3 ? 0 : null,
      stability: c.stability,
      difficulty: c.difficulty,
      due: c.due ?? DateTime.now().toUtc(),
      lastReview: c.lastReview,
    );
  }

  ReviewOutcome review(ReviewCard c, Rating rating, {DateTime? now}) {
    final when = (now ?? DateTime.now()).toUtc();
    final result = _scheduler.reviewCard(
      _build(c),
      rating,
      reviewDateTime: when,
    );
    final card = result.card;
    final wasReviewish = c.state == 2 || c.state == 3;
    final lapsed = rating == Rating.again && wasReviewish;
    return ReviewOutcome(
      stability: card.stability ?? 0,
      difficulty: card.difficulty ?? 0,
      due: card.due.toUtc(),
      state: _stateToInt(card.state),
      reps: c.reps + 1,
      lapses: c.lapses + (lapsed ? 1 : 0),
      reviewedAt: when,
      rating: rating.value,
    );
  }

  /// Predicted next-due for each of the four ratings (powers the button labels).
  Map<Rating, DateTime> preview(ReviewCard c, {DateTime? now}) {
    final when = (now ?? DateTime.now()).toUtc();
    return {
      for (final r in Rating.values)
        r: _scheduler
            .reviewCard(_build(c), r, reviewDateTime: when)
            .card
            .due
            .toUtc(),
    };
  }
}
