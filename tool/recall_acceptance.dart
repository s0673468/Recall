import 'package:flutter/material.dart';

import 'package:health_anki_flutter/app/recall_app.dart';

import 'acceptance/recall_acceptance_fixture.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  const rawScenario = String.fromEnvironment(
    'RECALL_ACCEPTANCE_SCENARIO',
    defaultValue: 'rich',
  );
  final scenario = AcceptanceScenario.parse(rawScenario);
  runApp(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Banner(
        message: 'TEST DATA',
        location: BannerLocation.topEnd,
        child: RecallBootstrapApp(
          loader: () => createSanitizedAcceptanceDependencies(scenario: scenario),
        ),
      ),
    ),
  );
}
