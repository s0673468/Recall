import 'package:flutter/material.dart';

import 'app/recall_app.dart';
import 'core/diagnostics/operational_diagnostics.dart';
import 'core/diagnostics/recall_error_handlers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final diagnostics = await OperationalDiagnostics.create();
  RecallDiagnostics.install(diagnostics);
  installRecallErrorHandlers(diagnostics);

  runApp(const RecallBootstrapApp());
}
