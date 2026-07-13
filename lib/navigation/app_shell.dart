import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/platform/recall_platform.dart';
import '../features/review/application/review_controller.dart';
import '../features/reminders/application/study_reminder_controller.dart';
import '../features/review/data/recall_api.dart';
import '../features/review/presentation/screens/decks_screen.dart';
import '../features/review/presentation/screens/stats_screen.dart';
import '../features/review/presentation/screens/study_screen.dart';
import '../features/settings/application/recall_prefs_controller.dart';
import '../features/settings/presentation/screens/settings_screen.dart';
import '../theme/ui_tokens.dart';
import 'recall_deep_links.dart';

class AppShell extends StatefulWidget {
  final ReviewController controller;
  final RecallApi api;
  final RecallPrefsController prefs;
  final StudyReminderController? reminder;
  final RecallLinkSource? linkSource;
  final bool? nativeIos;

  const AppShell({
    super.key,
    required this.controller,
    required this.api,
    required this.prefs,
    this.reminder,
    this.linkSource,
    this.nativeIos,
  });

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  final _decksKey = GlobalKey<DecksScreenState>();
  final _statsKey = GlobalKey<StatsScreenState>();
  int _index = 0;
  late final bool _nativeIos = widget.nativeIos ?? recallRunsAsNativeIos();
  late final RecallDeepLinkController _deepLinks;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _deepLinks = RecallDeepLinkController(
      source: widget.linkSource,
      onDestination: (destination) {
        if (destination == RecallDestination.study) _selectIndex(0);
      },
    );
    unawaited(_deepLinks.start());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _deepLinks.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Drain durable writes and refresh stale aggregate state when no card is
      // active. An in-progress study card is never displaced on foreground.
      unawaited(() async {
        try {
          await Future.wait<void>([
            widget.controller.syncPending(),
            widget.controller.refreshIfIdle(),
          ]);
        } catch (error) {
          debugPrint('Recall: foreground sync deferred: $error');
        }
      }());
    }
  }

  void _openSettings() {
    Navigator.of(context).push(
      buildRecallPageRoute<void>(
        nativeIos: _nativeIos,
        builder: (_) => SettingsScreen(
          prefs: widget.prefs,
          controller: widget.controller,
          reminder: widget.reminder,
          nativeIos: _nativeIos,
        ),
      ),
    );
  }

  late final List<Widget> _pages = [
    StudyScreen(
      controller: widget.controller,
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
  ];

  void _selectIndex(int index) {
    if (index == _index) {
      return;
    }
    if (index == 1) {
      _reloadQuietly(_decksKey.currentState?.reload(), 'Reload decks');
    } else if (index == 2) {
      _reloadQuietly(_statsKey.currentState?.reload(), 'Reload stats');
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
      child: Scaffold(
        body: Container(
          decoration: const BoxDecoration(gradient: scaffoldGradient),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                UiSpacing.sm,
                UiSpacing.sm,
                UiSpacing.sm,
                0,
              ),
              child: IndexedStack(index: _index, children: _pages),
            ),
          ),
        ),
        extendBody: _nativeIos,
        bottomNavigationBar: RecallBottomNavigation(
          selectedIndex: _index,
          onDestinationSelected: _selectIndex,
          nativeIos: _nativeIos,
        ),
      ),
    );
  }
}

Route<T> buildRecallPageRoute<T>({
  required bool nativeIos,
  required WidgetBuilder builder,
}) => nativeIos
    ? CupertinoPageRoute<T>(builder: builder)
    : MaterialPageRoute<T>(builder: builder);

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
        backgroundColor: UiColors.panel.withValues(alpha: 0.78),
        border: const Border(
          top: BorderSide(color: UiColors.borderSubtle, width: 0.5),
        ),
        items: _items,
      );
    }
    return NavigationBar(
      backgroundColor: UiColors.panel,
      indicatorColor: accent.withValues(alpha: 0.15),
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
      ],
    );
  }
}
