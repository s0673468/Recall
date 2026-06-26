import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:health_flutter_shared/health_flutter_shared.dart'
    show GlassTabBar, GlassTabItem;

import '../features/review/application/review_controller.dart';
import '../features/review/data/recall_api.dart';
import '../features/review/presentation/screens/decks_screen.dart';
import '../features/review/presentation/screens/stats_screen.dart';
import '../features/review/presentation/screens/study_screen.dart';
import '../theme/ui_tokens.dart';

class AppShell extends StatefulWidget {
  final ReviewController controller;
  final RecallApi api;

  const AppShell({super.key, required this.controller, required this.api});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Sync any reviews queued while offline, without disturbing the session.
      widget.controller.syncPending();
    }
  }

  // dart:io is unavailable on web, so never call Platform here — the iPhone PWA
  // runs the web build and uses the Material chrome; only a native iOS build
  // gets the frosted GlassTabBar.
  bool get _useIosChrome =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  static const _iosTabs = [
    GlassTabItem(
      icon: Icons.style_outlined,
      activeIcon: Icons.style,
      label: 'Study',
    ),
    GlassTabItem(
      icon: Icons.folder_outlined,
      activeIcon: Icons.folder,
      label: 'Decks',
    ),
    GlassTabItem(
      icon: Icons.bar_chart_outlined,
      activeIcon: Icons.bar_chart,
      label: 'Stats',
    ),
  ];

  late final List<Widget> _pages = [
    StudyScreen(controller: widget.controller),
    DecksScreen(
      controller: widget.controller,
      api: widget.api,
      onStudyDeck: (deckId) {
        widget.controller.selectDeck(deckId);
        setState(() => _index = 0);
      },
    ),
    StatsScreen(api: widget.api, controller: widget.controller),
  ];

  @override
  Widget build(BuildContext context) {
    final ios = _useIosChrome;
    return Scaffold(
      extendBody: ios,
      body: Container(
        decoration: const BoxDecoration(gradient: scaffoldGradient),
        child: SafeArea(
          bottom: !ios,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              UiSpacing.sm,
              UiSpacing.sm,
              UiSpacing.sm,
              ios
                  ? UiIos.tabBarHeight + MediaQuery.viewPaddingOf(context).bottom
                  : 0,
            ),
            child: IndexedStack(index: _index, children: _pages),
          ),
        ),
      ),
      bottomNavigationBar: ios
          ? GlassTabBar(
              items: _iosTabs,
              currentIndex: _index,
              onTap: (i) => setState(() => _index = i),
            )
          : NavigationBar(
              backgroundColor: UiColors.panel,
              indicatorColor: UiColors.primary.withValues(alpha: 0.15),
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
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
            ),
    );
  }
}
