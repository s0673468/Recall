import 'package:integration_test/integration_test.dart';

import '../test/production_scale_acceptance_test.dart' as paths;

// The shared suite constructs invented cards and in-memory preferences only.
// The exact same production widget paths run in CI and on the disposable emulator.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  paths.main();
}
