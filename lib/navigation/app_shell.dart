import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;

import '../core/diagnostics/operational_diagnostics.dart';
import '../core/platform/recall_platform.dart';
import '../core/widgets/recall_motion.dart';
import '../features/review/application/review_controller.dart';
import '../features/reminders/application/study_reminder_controller.dart';
import '../features/review/data/recall_api.dart';
import '../features/review/presentation/screens/decks_screen.dart';
import '../features/review/presentation/screens/read_screen.dart';
import '../features/review/presentation/screens/stats_screen.dart';
import '../features/review/presentation/screens/study_screen.dart';
import '../features/settings/application/recall_prefs_controller.dart';
import '../features/settings/presentation/screens/settings_screen.dart';
import '../theme/ui_tokens.dart';
import 'recall_deep_links.dart';
import 'recall_page_route.dart';

export 'recall_page_route.dart' show buildRecallPageRoute;

class AppShell extends StatefulWidget {
  final ReviewController controller;
  final RecallApi api;
  final RecallPrefsController prefs;
  final StudyReminderController? reminder;
  final RecallLinkSource? linkSource;
  final bool? nativeIos;
  final bool? nativeAndroid;
  final OperationalEventRecorder diagnostics;

  AppShell({
    super.key,
    required this.controller,
    required this.api,
    required this.prefs,
    this.reminder,
    this.linkSource,
    this.nativeIos,
    this.nativeAndroid,
    OperationalEventRecorder? diagnostics,
  }) : diagnostics = diagnostics ?? RecallDiagnostics.instance;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  final _decksKey = GlobalKey<DecksScreenState>();
  final _statsKey = GlobalKey<StatsScreenState>();
  final _readKey = GlobalKey<ReadScreenState>();
  int _index = 0;
  late final bool _nativeIos = widget.nativeIos ?? recallRunsAsNativeIos();
  late final bool _nativeAndroid =
      widget.nativeAndroid ?? recallRunsAsNativeAndroid();
  late final RecallDeepLinkController _deepLinks;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_reconcileStudyReminder);
    _deepLinks = RecallDeepLinkController(
      source: widget.linkSource,
      onDestination: (destination) {
        if (destination == RecallDestination.study) _selectIndex(0);
      },
    );
    unawaited(_deepLinks.start());
    _reconcileStudyReminder();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_reconcileStudyReminder);
    WidgetsBinding.instance.removeObserver(this);
    _deepLinks.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Drain durable writes and refresh stale aggregate state when no card is
      // active. An in-progress study card is never displaced on foreground.
      unawaited(_resumeAndReconcileStudyReminder());
    }
  }

  Future<void> _resumeAndReconcileStudyReminder() async {
    await runRecallForegroundSync(
      diagnostics: widget.diagnostics,
      syncPending: widget.controller.syncPending,
      refreshIfIdle: widget.controller.refreshIfIdle,
    );
    _reconcileStudyReminder(force: true);
  }

  void _reconcileStudyReminder({bool force = false}) {
    final reminder = widget.reminder;
    if (reminder == null || widget.controller.currentUser == null) return;
    unawaited(
      reminder.reconcile(
        dueCount: widget.controller.state.globalDueCount,
        lastReviewedAt: widget.controller.state.lastReviewedAt,
        reviewActivityKnown: widget.controller.state.reviewActivityKnown,
        force: force,
      ),
    );
  }

  void _openSettings() {
    Navigator.of(context).push(
      buildRecallPageRoute<void>(
        nativeIos: _nativeIos,
        builder: (_) => SettingsScreen(
          prefs: widget.prefs,
          controller: widget.controller,
          reminder: _nativeIos || _nativeAndroid ? widget.reminder : null,
          nativeIos: _nativeIos,
        ),
      ),
    );
  }

  late final List<Widget> _pages = [
    StudyScreen(
      controller: widget.controller,
      api: widget.api,
      store: widget.controller.store,
      onOpenSettings: _openSettings,
      nativeIos: _nativeIos,
    ),
    DecksScreen(
      key: _decksKey,
      controller: widget.controller,
      api: widget.api,
      onStudyDeck: (deckId) {
        widget.controller.selectDeck(deckId);
        _selectIndex(0);
      },
    ),
    StatsScreen(key: _statsKey, api: widget.api, controller: widget.controller),
    ReadScreen(key: _readKey, api: widget.api, store: widget.controller.store),
  ];

  void _selectIndex(int index) {
    if (index == _index) {
      return;
    }
    if (index == 1) {
      _reloadQuietly(_decksKey.currentState?.reload(), 'Reload decks');
    } else if (index == 2) {
      _reloadQuietly(_statsKey.currentState?.reload(), 'Reload stats');
    } else if (index == 3) {
      _reloadQuietly(_readKey.currentState?.reload(), 'Reload reading');
    }
    setState(() => _index = index);
  }

  void _reloadQuietly(Future<void>? reloadFuture, String context) {
    reloadFuture?.catchError((Object error, StackTrace stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'recall navigation',
          context: ErrorDescription(context),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _index == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _selectIndex(0);
        }
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        key: const Key('recall_system_bars'),
        value: SystemUiOverlayStyle.light.copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarContrastEnforced: false,
          systemNavigationBarIconBrightness: Brightness.light,
        ),
        child: ListenableBuilder(
          listenable: widget.controller,
          builder: (context, _) => LayoutBuilder(
            builder: (context, constraints) {
              final useRail = _nativeAndroid && constraints.maxWidth >= 600;
              final state = widget.controller.state;
              final busy = state.loading || state.authSubmitting;
              final content = Column(
                children: [
                  SizedBox(
                    height: 2,
                    child: AnimatedSwitcher(
                      duration: RecallMotion.duration(
                        context,
                        RecallMotion.quick,
                      ),
                      child: busy
                          ? const LinearProgressIndicator(
                              key: ValueKey('recall_shell_busy'),
                              minHeight: 2,
                            )
                          : const SizedBox.shrink(
                              key: ValueKey('recall_shell_idle'),
                            ),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        UiSpacing.sm,
                        UiSpacing.sm,
                        UiSpacing.sm,
                        _nativeIos || useRail ? UiSpacing.sm : 0,
                      ),
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 820),
                          child: SizedBox.expand(
                            child: RecallAnimatedIndexedStack(
                              index: _index,
                              children: _pages,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
              return Scaffold(
                backgroundColor: UiColors.canvas,
                body: Material(
                  key: const Key('recall_flat_canvas'),
                  color: UiColors.canvas,
                  child: SafeArea(
                    child: useRail
                        ? Row(
                            children: [
                              RecallNavigationRail(
                                selectedIndex: _index,
                                onDestinationSelected: _selectIndex,
                              ),
                              const VerticalDivider(
                                width: 1,
                                color: UiColors.borderSubtle,
                              ),
                              Expanded(child: content),
                            ],
                          )
                        : content,
                  ),
                ),
                extendBody: _nativeIos,
                bottomNavigationBar: useRail
                    ? null
                    : RecallBottomNavigation(
                        selectedIndex: _index,
                        onDestinationSelected: _selectIndex,
                        nativeIos: _nativeIos,
                      ),
              );
            },
          ),
        ),
      ),
    );
  }
}

@visibleForTesting
Future<void> runRecallForegroundSync({
  required OperationalEventRecorder diagnostics,
  required Future<void> Function() syncPending,
  required Future<void> Function() refreshIfIdle,
}) async {
  try {
    await Future.wait<void>([syncPending(), refreshIfIdle()]);
  } catch (_) {
    await diagnostics.record(
      level: OperationalLevel.error,
      component: OperationalComponent.foregroundSync,
      operation: OperationalOperation.syncPending,
      outcome: OperationalOutcome.failed,
      causeCode: OperationalCauseCode.foregroundSyncFailed,
      retryable: true,
    );
  }
}

/// One navigation contract rendered in the host platform's native idiom.
///
/// The iOS bar's translucent background activates CupertinoTabBar's built-in
/// backdrop blur. Web keeps Recall's existing Material NavigationBar.
class RecallBottomNavigation extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final bool nativeIos;

  const RecallBottomNavigation({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.nativeIos,
  });

  static const _items = [
    BottomNavigationBarItem(
      icon: Icon(Icons.style_outlined),
      activeIcon: Icon(Icons.style),
      label: 'Study',
    ),
    BottomNavigationBarItem(
      icon: Icon(Icons.folder_outlined),
      activeIcon: Icon(Icons.folder),
      label: 'Decks',
    ),
    BottomNavigationBarItem(
      icon: Icon(Icons.bar_chart_outlined),
      activeIcon: Icon(Icons.bar_chart),
      label: 'Stats',
    ),
    BottomNavigationBarItem(
      icon: Icon(Icons.menu_book_outlined),
      activeIcon: Icon(Icons.menu_book),
      label: 'Read',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    if (nativeIos) {
      return CupertinoTabBar(
        currentIndex: selectedIndex,
        onTap: onDestinationSelected,
        activeColor: accent,
        inactiveColor: UiColors.textSecondary,
        backgroundColor: UiColors.canvas.withValues(alpha: 0.94),
        border: const Border(
          top: BorderSide(color: UiColors.borderSubtle, width: 0.5),
        ),
        items: _items,
      );
    }
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: UiColors.canvas,
        border: Border(top: BorderSide(color: UiColors.borderSubtle)),
      ),
      child: NavigationBarTheme(
        data: NavigationBarThemeData(
          backgroundColor: Colors.transparent,
          indicatorColor: Colors.transparent,
          iconTheme: WidgetStateProperty.resolveWith((states) {
            return IconThemeData(
              color: states.contains(WidgetState.selected)
                  ? accent
                  : UiColors.textMuted,
            );
          }),
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            return Theme.of(context).textTheme.bodySmall?.copyWith(
              color: states.contains(WidgetState.selected)
                  ? accent
                  : UiColors.textMuted,
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w600
                  : FontWeight.w500,
            );
          }),
        ),
        child: NavigationBar(
          height: 68,
          animationDuration: RecallMotion.duration(context),
          selectedIndex: selectedIndex,
          onDestinationSelected: onDestinationSelected,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.style_outlined),
              selectedIcon: Icon(Icons.style),
              label: 'Study',
            ),
            NavigationDestination(
              icon: Icon(Icons.folder_outlined),
              selectedIcon: Icon(Icons.folder),
              label: 'Decks',
            ),
            NavigationDestination(
              icon: Icon(Icons.bar_chart_outlined),
              selectedIcon: Icon(Icons.bar_chart),
              label: 'Stats',
            ),
            NavigationDestination(
              icon: Icon(Icons.menu_book_outlined),
              selectedIcon: Icon(Icons.menu_book),
              label: 'Read',
            ),
          ],
        ),
      ),
    );
  }
}

/// Material adaptive navigation for Android tablets and wide rotations.
class RecallNavigationRail extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  const RecallNavigationRail({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return NavigationRail(
      selectedIndex: selectedIndex,
      onDestinationSelected: onDestinationSelected,
      labelType: NavigationRailLabelType.all,
      backgroundColor: UiColors.sidebar,
      indicatorColor: Colors.transparent,
      selectedIconTheme: IconThemeData(color: accent),
      unselectedIconTheme: const IconThemeData(color: UiColors.textMuted),
      selectedLabelTextStyle: TextStyle(
        color: accent,
        fontWeight: FontWeight.w700,
      ),
      unselectedLabelTextStyle: const TextStyle(color: UiColors.textMuted),
      destinations: const [
        NavigationRailDestination(
          icon: Icon(Icons.style_outlined),
          selectedIcon: Icon(Icons.style),
          label: Text('Study'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.folder_outlined),
          selectedIcon: Icon(Icons.folder),
          label: Text('Decks'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.bar_chart_outlined),
          selectedIcon: Icon(Icons.bar_chart),
          label: Text('Stats'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.menu_book_outlined),
          selectedIcon: Icon(Icons.menu_book),
          label: Text('Read'),
        ),
      ],
    );
  }
}
