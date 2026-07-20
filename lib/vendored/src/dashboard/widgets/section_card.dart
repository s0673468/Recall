import 'package:flutter/material.dart';

import '../../theme/shared_ui_tokens.dart';
import 'mood_atmosphere.dart';

class SectionCard extends StatelessWidget {
  final String? title;
  final String? subtitle;
  final Widget child;
  final Widget? trailing;
  final Color? tint;
  final EdgeInsetsGeometry? padding;

  /// Renders an unfilled plot/list region with a single structural divider.
  /// Use for repeated peer content; reserve bounded surfaces for real
  /// interaction boundaries and the single screen hero.
  final bool flat;

  /// Renders this card as a HERO surface — a faint neutral wash so the one
  /// day-carrying card (Readiness) reads as louder than the rest. Preferred
  /// over [mood] for the mood-free hero tier.
  final bool hero;

  /// Legacy weather-mood hero/ambient tinting. Retained as inert shared
  /// infrastructure — no caller feeds a live mood today. When set, the panel is
  /// washed with the mood's deep sky and carries the atmosphere texture; cards
  /// without an explicit mood pick up the faint AMBIENT tier from an enclosing
  /// [MoodScope], of which no provider currently exists.
  final UiMood? mood;

  const SectionCard({
    super.key,
    this.title,
    this.subtitle,
    required this.child,
    this.trailing,
    this.tint,
    this.padding,
    this.flat = false,
    this.hero = false,
    this.mood,
  });

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding:
          padding ??
          (flat
              ? const EdgeInsets.symmetric(vertical: UiSpacing.md)
              : const EdgeInsets.all(UiSpacing.lg)),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null || trailing != null) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (title != null)
                          Text(
                            title!,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        if (subtitle != null) ...[
                          const SizedBox(height: UiSpacing.xs),
                          Text(
                            subtitle!,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: UiColors.textMuted),
                          ),
                        ],
                      ],
                    ),
                  ),
                  ...?(trailing == null ? null : [trailing!]),
                ],
              ),
              const SizedBox(height: UiSpacing.md),
            ],
            child,
          ],
        ),
      ),
    );
    if (flat) {
      return Container(
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: UiColors.borderSubtle)),
        ),
        child: content,
      );
    }

    final ambient = mood == null ? MoodScope.of(context) : null;
    final BoxDecoration decoration;
    Widget? atmosphere;
    if (mood != null) {
      decoration = buildHeroPanelDecoration(mood!);
      atmosphere = MoodAtmosphere(mood: mood!);
    } else if (hero) {
      decoration = buildHeroPanelDecoration();
    } else if (ambient != null && tint == null) {
      decoration = buildAmbientPanelDecoration(ambient);
      atmosphere = MoodAtmosphere(mood: ambient, ambient: true);
    } else {
      decoration = buildPanelDecoration(tint: tint);
    }
    return Container(
      decoration: decoration,
      child: atmosphere == null
          ? content
          : Stack(
              children: [
                Positioned.fill(child: atmosphere),
                content,
              ],
            ),
    );
  }
}
