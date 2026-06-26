import 'dart:ui';

import 'package:flutter/material.dart';

import 'app/recall_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Surface framework and uncaught async errors in the console.
  FlutterError.onError = (details) {
    debugPrint('=== FLUTTER ERROR ===');
    debugPrint('${details.exception}');
    debugPrint('${details.stack}');
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('=== UNCAUGHT ERROR ===');
    debugPrint('$error');
    debugPrint('$stack');
    return false;
  };

  runApp(const RecallBootstrapApp());
}
