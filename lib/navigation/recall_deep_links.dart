import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

enum RecallDestination { study }

/// Accepts exactly the route exposed by the widget. Unknown hosts, schemes,
/// paths, query parameters, and fragments are ignored rather than forwarded.
RecallDestination? recallDestinationFor(Uri uri) {
  if (uri.scheme != 'recall' ||
      uri.host != 'study' ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  return RecallDestination.study;
}

abstract interface class RecallLinkSource {
  Future<Uri?> getInitialLink();
  Stream<Uri> get links;
}

class AppLinksRecallLinkSource implements RecallLinkSource {
  final AppLinks _appLinks;

  AppLinksRecallLinkSource([AppLinks? appLinks])
    : _appLinks = appLinks ?? AppLinks();

  @override
  Future<Uri?> getInitialLink() => _appLinks.getInitialLink();

  @override
  Stream<Uri> get links => _appLinks.uriLinkStream;
}

/// Delivers cold-start and resumed links through the same strict parser.
class RecallDeepLinkController {
  final RecallLinkSource source;
  final ValueChanged<RecallDestination> onDestination;

  StreamSubscription<Uri>? _subscription;
  bool _disposed = false;

  RecallDeepLinkController({
    RecallLinkSource? source,
    required this.onDestination,
  }) : source = source ?? AppLinksRecallLinkSource();

  Future<void> start() async {
    if (_disposed || _subscription != null) return;
    _subscription = source.links.listen(
      _handle,
      onError: (Object error, StackTrace stackTrace) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'recall deep links',
            context: ErrorDescription('receiving a study deep link'),
          ),
        );
      },
    );
    try {
      final initial = await source.getInitialLink();
      if (!_disposed && initial != null) _handle(initial);
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'recall deep links',
          context: ErrorDescription('reading the initial study deep link'),
        ),
      );
    }
  }

  void _handle(Uri uri) {
    final destination = recallDestinationFor(uri);
    if (!_disposed && destination != null) onDestination(destination);
  }

  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    _subscription = null;
  }
}
