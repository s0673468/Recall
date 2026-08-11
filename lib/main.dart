import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/recall_app.dart';
import 'core/diagnostics/operational_diagnostics.dart';
import 'core/diagnostics/operational_diagnostics_export.dart';
import 'core/diagnostics/recall_error_handlers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
      systemStatusBarContrastEnforced: false,
      systemNavigationBarContrastEnforced: false,
    ),
  );

  final diagnostics = await OperationalDiagnostics.create(
    exporter: const MethodChannelOperationalEventExporter(),
  );
  RecallDiagnostics.install(diagnostics);
  installRecallErrorHandlers(diagnostics);

  runApp(const RecallBootstrapApp());
}
