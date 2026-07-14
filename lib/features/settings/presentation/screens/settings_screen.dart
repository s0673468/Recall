import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:health_flutter_shared/health_flutter_shared.dart'
    show SectionCard, SignOutButton, SignOutButtonVariant;

import '../../../../theme/ui_tokens.dart';
import '../../../review/application/review_controller.dart';
import '../../../reminders/application/study_reminder_controller.dart';
import '../../application/recall_prefs_controller.dart';
import '../../domain/recall_prefs.dart';

/// Recall's settings surface (pushed from the Study header gear): scheduling
/// (retention, new-cards/day, new-card order), per-deck new-card overrides, and
/// the account sign-out (relocated from the Stats tab).
class SettingsScreen extends StatefulWidget {
  final RecallPrefsController prefs;
  final ReviewController controller;
  final StudyReminderController? reminder;
  final bool nativeIos;

  const SettingsScreen({
    super.key,
    required this.prefs,
    required this.controller,
    this.reminder,
    this.nativeIos = false,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  /// Live value while the retention slider is being dragged (committed on
  /// change-end so we don't spam the cloud on every tick).
  double? _dragRetention;

  RecallPrefs get _prefs => widget.prefs.value;

  void _apply(RecallPrefs next) => widget.prefs.update(next);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: UiColors.canvas,
      appBar: AppBar(
        backgroundColor: UiColors.sidebar,
        foregroundColor: UiColors.textPrimary,
        elevation: 0,
        title: const Text('Settings'),
      ),
      body: ColoredBox(
        color: UiColors.canvas,
        child: SafeArea(
          child: ListenableBuilder(
            listenable: widget.prefs,
            builder: (context, _) => ListView(
              padding: const EdgeInsets.all(UiSpacing.sm),
              children: [
                _schedulingCard(context),
                if (widget.reminder != null) ...[
                  const SizedBox(height: UiSpacing.lg),
                  _reminderCard(context, widget.reminder!),
                ],
                const SizedBox(height: UiSpacing.lg),
                _perDeckCard(context),
                const SizedBox(height: UiSpacing.lg),
                _accountCard(context),
                const SizedBox(height: UiSpacing.xl),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Scheduling ──

  Widget _schedulingCard(BuildContext context) {
    final retention = _dragRetention ?? _prefs.desiredRetention;
    final mult = retentionWorkloadMultiplier(retention);
    return SectionCard(
      flat: true,
      title: 'Scheduling',
      subtitle: 'How Recall paces reviews and introduces new cards.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'Desired retention',
                style: TextStyle(
                  color: UiColors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                '${(retention * 100).round()}%',
                style: const TextStyle(
                  color: UiColors.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          Slider(
            value: retention.clamp(
              RecallPrefs.minRetention,
              RecallPrefs.maxRetention,
            ),
            min: RecallPrefs.minRetention,
            max: RecallPrefs.maxRetention,
            divisions:
                ((RecallPrefs.maxRetention - RecallPrefs.minRetention) / 0.01)
                    .round(),
            label: '${(retention * 100).round()}%',
            activeColor: UiColors.primary,
            onChanged: (v) => setState(() => _dragRetention = v),
            onChangeEnd: (v) {
              _apply(_prefs.copyWith(desiredRetention: v));
              setState(() => _dragRetention = null);
            },
          ),
          Text(
            '≈ workload ×${mult.toStringAsFixed(1)} vs the 90% baseline. '
            'Higher retention means more reviews.',
            style: const TextStyle(color: UiColors.textMuted, fontSize: 12),
          ),
          const Divider(color: UiColors.border, height: UiSpacing.xl),
          _stepperRow(
            label: 'New cards / day',
            value: _prefs.newLimitDefault,
            onChanged: (v) => _apply(_prefs.copyWith(newLimitDefault: v)),
          ),
          const SizedBox(height: UiSpacing.md),
          const Text(
            'New-card order',
            style: TextStyle(
              color: UiColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: UiSpacing.xs),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<NewOrder>(
              segments: [
                for (final o in NewOrder.values)
                  ButtonSegment(value: o, label: Text(o.label)),
              ],
              selected: {_prefs.newOrder},
              showSelectedIcon: false,
              onSelectionChanged: (s) =>
                  _apply(_prefs.copyWith(newOrder: s.first)),
            ),
          ),
        ],
      ),
    );
  }

  // ── Per-deck limits ──

  Widget _reminderCard(BuildContext context, StudyReminderController reminder) {
    return ListenableBuilder(
      listenable: reminder,
      builder: (context, _) {
        final settings = reminder.value;
        return SectionCard(
          flat: true,
          title: 'Study reminder',
          subtitle: 'One gentle daily nudge, delivered by your iPhone.',
          child: Column(
            children: [
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Daily reminder'),
                value: settings.enabled,
                onChanged: (enabled) async {
                  try {
                    final applied = await reminder.setEnabled(enabled);
                    if (!applied && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Notifications are off. Enable them in iPhone Settings to use reminders.',
                          ),
                        ),
                      );
                    }
                  } catch (error) {
                    if (context.mounted) _showError(context, '$error');
                  }
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                enabled: settings.enabled,
                title: const Text('Reminder time'),
                trailing: TextButton(
                  onPressed: settings.enabled
                      ? () => _chooseReminderTime(context, reminder)
                      : null,
                  child: Text(settings.formattedTime),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _chooseReminderTime(
    BuildContext context,
    StudyReminderController reminder,
  ) async {
    final current = reminder.value;
    TimeOfDay? selected;
    if (widget.nativeIos) {
      var draft = DateTime(2026, 1, 1, current.hour, current.minute);
      selected = await showCupertinoModalPopup<TimeOfDay>(
        context: context,
        builder: (sheetContext) => Container(
          height: 300,
          color: CupertinoColors.systemBackground.resolveFrom(sheetContext),
          child: SafeArea(
            top: false,
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: CupertinoButton(
                    onPressed: () => Navigator.of(
                      sheetContext,
                    ).pop(TimeOfDay(hour: draft.hour, minute: draft.minute)),
                    child: const Text('Done'),
                  ),
                ),
                Expanded(
                  child: CupertinoDatePicker(
                    mode: CupertinoDatePickerMode.time,
                    use24hFormat: true,
                    initialDateTime: draft,
                    onDateTimeChanged: (value) => draft = value,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } else {
      selected = await showTimePicker(
        context: context,
        initialTime: TimeOfDay(hour: current.hour, minute: current.minute),
      );
    }
    if (selected == null) return;
    try {
      await reminder.setTime(hour: selected.hour, minute: selected.minute);
    } catch (error) {
      if (context.mounted) _showError(context, '$error');
    }
  }

  void _showError(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  // ── Per-deck limits ──

  Widget _perDeckCard(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final decks = widget.controller.state.decks;
        return SectionCard(
          flat: true,
          title: 'Per-deck new-card limits',
          subtitle: decks.isEmpty
              ? 'Deck list loads after your first sync.'
              : 'Override the daily new-card limit for a specific deck.',
          child: Column(
            children: [
              for (final deck in decks)
                _deckOverrideRow(
                  name: deck.name.replaceAll('::', '  ›  '),
                  override: _prefs.perDeck[deck.deckId],
                  onSet: (v) => _apply(_prefs.withDeckOverride(deck.deckId, v)),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _deckOverrideRow({
    required String name,
    required int? override,
    required ValueChanged<int?> onSet,
  }) {
    final active = override != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              name,
              style: const TextStyle(color: UiColors.textPrimary, fontSize: 14),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (active) ...[
            _stepper(value: override, onChanged: (v) => onSet(v)),
            IconButton(
              tooltip: 'Use default',
              icon: const Icon(
                Icons.close,
                size: 18,
                color: UiColors.textMuted,
              ),
              onPressed: () => onSet(null),
            ),
          ] else
            TextButton(
              onPressed: () => onSet(_prefs.newLimitDefault),
              child: const Text('Set override'),
            ),
        ],
      ),
    );
  }

  // ── Account ──

  Widget _accountCard(BuildContext context) {
    return SectionCard(
      flat: true,
      title: 'Account',
      child: Align(
        alignment: Alignment.centerLeft,
        child: SignOutButton(
          onSignOut: () async {
            try {
              await widget.controller.signOut();
              if (context.mounted) Navigator.of(context).maybePop();
            } on PendingSyncException catch (error) {
              if (context.mounted) _showError(context, '$error');
            } catch (error) {
              if (context.mounted) {
                _showError(context, 'Could not sign out: $error');
              }
            }
          },
          email: widget.controller.currentUser?.email,
          variant: SignOutButtonVariant.text,
        ),
      ),
    );
  }

  // ── Shared stepper widgets ──

  Widget _stepperRow({
    required String label,
    required int value,
    required ValueChanged<int> onChanged,
  }) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              color: UiColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        _stepper(value: value, onChanged: onChanged),
      ],
    );
  }

  Widget _stepper({required int value, required ValueChanged<int> onChanged}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.remove_circle_outline),
          color: UiColors.textMuted,
          onPressed: value <= 0
              ? null
              : () => onChanged((value - 1).clamp(0, RecallPrefs.maxNewLimit)),
        ),
        SizedBox(
          width: 32,
          child: Text(
            '$value',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: UiColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.add_circle_outline),
          color: UiColors.primary,
          onPressed: value >= RecallPrefs.maxNewLimit
              ? null
              : () => onChanged((value + 1).clamp(0, RecallPrefs.maxNewLimit)),
        ),
      ],
    );
  }
}
