import 'package:flutter/material.dart';

import 'package:health_anki_flutter/vendored/health_flutter_shared.dart'
    show AppScrollBehavior, AuthGate, AuthGateModel;

import '../core/widgets/recall_widget_bridge.dart';
import '../core/widgets/recall_motion.dart';
import '../core/widgets/recall_surfaces.dart';
import '../navigation/app_shell.dart';
import '../theme/ui_tokens.dart';
import 'recall_dependencies.dart';

typedef RecallDependenciesLoader = Future<RecallDependencies> Function();

class RecallBootstrapApp extends StatefulWidget {
  final RecallDependenciesLoader loader;

  const RecallBootstrapApp({
    super.key,
    this.loader = RecallDependencies.create,
  });

  @override
  State<RecallBootstrapApp> createState() => _RecallBootstrapAppState();
}

class _RecallBootstrapAppState extends State<RecallBootstrapApp> {
  late final Future<RecallDependencies> _future;
  RecallDependencies? _deps;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _future = widget.loader().then((deps) {
      if (_disposed) {
        deps.dispose();
      } else {
        _deps = deps;
      }
      return deps;
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _deps?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<RecallDependencies>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          return RecallApp(dependencies: snapshot.data!);
        }
        return MaterialApp(
          title: UiBrand.appName,
          debugShowCheckedModeBanner: false,
          theme: buildRecallTheme(),
          scrollBehavior: const AppScrollBehavior(),
          home: snapshot.hasError ? const _StartupError() : const _Loading(),
        );
      },
    );
  }
}

class RecallApp extends StatelessWidget {
  final RecallDependencies dependencies;

  const RecallApp({super.key, required this.dependencies});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: UiBrand.appName,
      debugShowCheckedModeBanner: false,
      theme: buildRecallTheme(),
      scrollBehavior: const AppScrollBehavior(),
      home: _RecallRoot(dependencies: dependencies),
    );
  }
}

/// Shows the login gate until there's a signed-in user, then the app shell.
class _RecallRoot extends StatefulWidget {
  final RecallDependencies dependencies;
  const _RecallRoot({required this.dependencies});

  @override
  State<_RecallRoot> createState() => _RecallRootState();
}

class _RecallRootState extends State<_RecallRoot> {
  @override
  Widget build(BuildContext context) {
    final controller = widget.dependencies.reviewController;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        late final Widget content;
        if (controller.currentUser == null) {
          content = KeyedSubtree(
            key: const ValueKey('recall_auth'),
            child: AuthGate(
              model: AuthGateModel(
                source: controller,
                submitting: () => controller.state.authSubmitting,
                errorText: () => controller.state.error,
                signIn: controller.signIn,
              ),
              appName: UiBrand.appName,
              subtitle: UiBrand.subtitle,
            ),
          );
        } else {
          content = KeyedSubtree(
            key: const ValueKey('recall_shell'),
            child: AppShell(
              controller: controller,
              api: widget.dependencies.api,
              prefs: widget.dependencies.recallPrefs,
              reminder: widget.dependencies.studyReminder,
            ),
          );
        }
        return RecallWidgetBridge(
          controller: controller,
          child: RecallMotionSwap(child: content),
        );
      },
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Container(
      decoration: const BoxDecoration(gradient: scaffoldGradient),
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_stories_rounded, color: UiColors.primary, size: 38),
            SizedBox(height: UiSpacing.md),
            Text(
              'Recall',
              style: TextStyle(
                color: UiColors.textPrimary,
                fontSize: 24,
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: UiSpacing.lg),
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        ),
      ),
    ),
  );
}

class _StartupError extends StatelessWidget {
  const _StartupError();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: scaffoldGradient),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(UiSpacing.lg),
            child: Center(
              child: SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: const RecallStatePanel(
                    icon: Icons.error_outline,
                    title: 'Recall failed to start',
                    message:
                        'Check your connection and restart Recall. Your offline '
                        'study data has not been cleared.',
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
