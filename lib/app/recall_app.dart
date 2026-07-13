import 'package:flutter/material.dart';

import 'package:health_flutter_shared/health_flutter_shared.dart'
    show AppScrollBehavior, AuthGate, AuthGateModel;

import '../core/widgets/recall_widget_bridge.dart';
import '../features/review/application/review_controller.dart';
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
          home: snapshot.hasError
              ? _StartupError(
                  error: snapshot.error!,
                  stack: snapshot.stackTrace,
                )
              : const _Loading(),
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
  bool _biometricAttempted = false;
  bool _biometricInFlight = false;

  @override
  Widget build(BuildContext context) {
    final controller = widget.dependencies.reviewController;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        late final Widget content;
        if (controller.currentUser == null) {
          _scheduleBiometricSignIn(controller);
          content = AuthGate(
            model: AuthGateModel(
              source: controller,
              submitting: () => controller.state.authSubmitting,
              errorText: () => controller.state.error,
              signIn: controller.signIn,
            ),
            appName: UiBrand.appName,
            subtitle: UiBrand.subtitle,
          );
        } else {
          content = AppShell(
            controller: controller,
            api: widget.dependencies.api,
            prefs: widget.dependencies.recallPrefs,
            reminder: widget.dependencies.studyReminder,
          );
        }
        return RecallWidgetBridge(controller: controller, child: content);
      },
    );
  }

  void _scheduleBiometricSignIn(ReviewController controller) {
    if (_biometricAttempted ||
        _biometricInFlight ||
        controller.state.authSubmitting) {
      return;
    }
    _biometricAttempted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _tryBiometricSignIn(controller);
    });
  }

  Future<void> _tryBiometricSignIn(ReviewController controller) async {
    setState(() => _biometricInFlight = true);
    final credentials = await widget.dependencies.biometricSignIn
        .authenticateAndRead();
    if (credentials != null && mounted && controller.currentUser == null) {
      await controller.signIn(
        email: credentials.email,
        password: credentials.password,
      );
      if (controller.currentUser == null && controller.state.error != null) {
        await widget.dependencies.biometricSignIn.clearCredentials();
      }
    }
    if (mounted) setState(() => _biometricInFlight = false);
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Container(
      decoration: const BoxDecoration(gradient: scaffoldGradient),
      child: const Center(child: CircularProgressIndicator()),
    ),
  );
}

class _StartupError extends StatelessWidget {
  final Object error;
  final StackTrace? stack;
  const _StartupError({required this.error, this.stack});

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
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      color: UiColors.danger,
                      size: 48,
                    ),
                    const SizedBox(height: UiSpacing.md),
                    Text(
                      'Recall failed to start',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: UiSpacing.sm),
                    SelectableText(
                      '$error',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: UiColors.textMuted),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
