import 'dart:io';

import 'package:flutter/material.dart';
import 'package:health_anki_flutter/app/recall_app.dart';
import 'package:health_anki_flutter/app/recall_dependencies.dart';

import '../test/support/android_acceptance_fixture.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isAndroid ||
      !const bool.fromEnvironment('RECALL_ANDROID_ACCEPTANCE')) {
    throw StateError(
      'This entrypoint requires the isolated Android acceptance build',
    );
  }
  runApp(const _AcceptanceApp());
}

class _AcceptanceApp extends StatefulWidget {
  const _AcceptanceApp();

  @override
  State<_AcceptanceApp> createState() => _AcceptanceAppState();
}

class _AcceptanceAppState extends State<_AcceptanceApp> {
  RecallDependencies? dependencies;

  Future<RecallDependencies> load() async {
    final result = await createAndroidAcceptanceDependencies();
    if (mounted) setState(() => dependencies = result);
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final deps = dependencies;
    final api = deps?.api as AndroidAcceptanceApi?;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Column(
        children: [
          SafeArea(
            bottom: false,
            child: Material(
              color: Colors.amber.shade100,
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('TEST DATA · invented backend'),
                  if (api != null)
                    TextButton(
                      onPressed: () async {
                        await api.setOnline(!api.online);
                        if (api.online) {
                          await deps!.reviewController.syncPending();
                        }
                        if (mounted) setState(() {});
                      },
                      child: Text(api.online ? 'Go offline' : 'Reconnect'),
                    ),
                ],
              ),
            ),
          ),
          Expanded(child: RecallBootstrapApp(loader: load)),
        ],
      ),
    );
  }
}
