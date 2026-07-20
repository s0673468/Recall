/// Vendored subset of Health's `health_flutter_shared` package.
///
/// Recall was moved out of the Health monorepo (Health slim phase 2, moved from
/// Health @ 39caf0d2 — full history preserved in this repo's `main` via
/// `git subtree split`, and in Health under tag `pre-slim2-2026-07`). It used to
/// depend on the sibling `health_flutter_shared` path package for ~8–10 generic
/// UI/auth symbols. Those source files are copied verbatim under
/// `lib/vendored/src/` and re-exported here so the app builds with ZERO
/// dependency on any Health repo package.
///
/// Only the symbols Recall actually imported are surfaced. If you need to pull a
/// fix from upstream Health, re-copy the matching file under `src/` — the
/// relative structure mirrors the original package.
library;

export 'src/auth/auth_gate.dart';
export 'src/auth/migrating_secure_local_storage.dart';
export 'src/auth/sign_out_button.dart';
export 'src/dashboard/widgets/section_card.dart';
// Provides `scopedPanelColor` (used by study_screen) and `MoodAtmosphere`
// (used by section_card).
export 'src/dashboard/widgets/mood_atmosphere.dart';
export 'src/navigation/app_switcher.dart';
export 'src/theme/app_scroll_behavior.dart';
// The 0-100 score-health ladder. Exported on its own (as upstream did) so
// consumers can colour scores without pulling in the shared colour/spacing
// tokens, which would clash with the app-local `theme/ui_tokens.dart`.
export 'src/theme/shared_ui_tokens.dart' show UiScore;
