import 'package:url_launcher/url_launcher.dart';

/// Native Track opens the deployed siblings in the browser. The root remains
/// configurable for forks/staging builds while the personal deployment works
/// without another dart-define.
String? documentBaseUri() => const String.fromEnvironment(
  'HEALTH_SUITE_ROOT',
  defaultValue: 'https://s0673468.github.io/Health/',
);

Future<void> assignLocation(String url) async {
  await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
}
