import 'package:flutter/material.dart';
import 'package:health_flutter_shared/health_flutter_shared.dart'
    show MirrorMoodScope, MirrorWeeklyService;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../features/review/application/review_controller.dart';
import '../features/review/data/recall_api.dart';
import '../features/review/presentation/screens/decks_screen.dart';
import '../features/review/presentation/screens/stats_screen.dart';
import '../features/review/presentation/screens/study_screen.dart';
import '../features/settings/application/recall_prefs_controller.dart';
import '../features/settings/presentation/screens/settings_screen.dart';
import '../theme/ui_tokens.dart';

class AppShell extends StatefulWidget {
  final ReviewController controller;
  final RecallApi api;
  final RecallPrefsController prefs;

  const AppShell({
    super.key,
    required this.controller,
    required this.api,
    required this.prefs,
  });

  @override
  State<AppShell> createState() => _AppShellState();
}

SupabaseClient? _supabaseClientOrNull() {
  try {
    return Supabase.instance.client;
  } catch (_) {
    return null;
  }
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  late final MirrorWeeklyService _mirrorService = MirrorWeeklyService.forClient(
    _supabaseClientOrNull(),
  );
  final _decksKey = GlobalKey<DecksScreenState>();
  final _statsKey = GlobalKey<StatsScreenState>();
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

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          prefs: widget.prefs,
          controller: widget.controller,
        ),
      ),
    );
  }

  late final List<Widget> _pages = [
    StudyScreen(controller: widget.controller, onOpenSettings: _openSettings),
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
        body: MirrorMoodScope(
          service: _mirrorService,
          child: Container(
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
        ),
        bottomNavigationBar: NavigationBar(
          backgroundColor: UiColors.panel,
          indicatorColor: UiColors.primary.withValues(alpha: 0.15),
          selectedIndex: _index,
          onDestinationSelected: _selectIndex,
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
      ),
    );
  }
}
