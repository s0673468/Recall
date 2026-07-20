/// Vendored copy of Health's `health_flutter_shared/ui_tokens_canonical.dart`.
///
/// Dedicated entrypoint for the full canonical design-system token set — kept
/// OUT of the `health_flutter_shared.dart` barrel on purpose (the barrel only
/// re-exports `UiScore`), so the app-local `theme/ui_tokens.dart` can import
/// this with `hide UiColors` and re-export the non-colour primitives without a
/// name clash. See `lib/vendored/health_flutter_shared.dart` for provenance.
library;

export 'src/theme/shared_ui_tokens.dart';
