import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

// A generic native exception cannot prove whether its write committed.
bool isDefinitelyUncommittedWrite(
  Object error,
  SharedPreferencesStorePlatform backend,
) => false;
