import 'package:flutter/material.dart';

import '../theme/shared_ui_tokens.dart';

/// The one "are you sure?" dialog every app shows before signing out. Returns
/// true only if the user confirmed.
Future<bool> confirmSignOut(BuildContext context) async {
  final out = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: UiColors.panel,
      title: const Text('Sign out?'),
      content: const Text('You can sign back in any time.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Sign out'),
        ),
      ],
    ),
  );
  return out ?? false;
}

enum SignOutButtonVariant { outlined, text }

/// Shared sign-out control: a logout glyph + "Sign out[ · email]". Confirms via
/// [confirmSignOut] before calling [onSignOut] (unless [confirm] is false).
///
/// Use [SignOutButtonVariant.text] for an unobtrusive footer placement (muted),
/// [outlined] for a settings-style action. App-bar icon placements (e.g. Lift's
/// shell) can call [confirmSignOut] directly instead.
class SignOutButton extends StatelessWidget {
  const SignOutButton({
    super.key,
    required this.onSignOut,
    this.email,
    this.variant = SignOutButtonVariant.outlined,
    this.confirm = true,
  });

  final Future<void> Function() onSignOut;
  final String? email;
  final SignOutButtonVariant variant;
  final bool confirm;

  Future<void> _handle(BuildContext context) async {
    if (confirm && !await confirmSignOut(context)) return;
    await onSignOut();
  }

  @override
  Widget build(BuildContext context) {
    final label = (email == null || email!.isEmpty)
        ? 'Sign out'
        : 'Sign out · $email';
    final icon = const Icon(Icons.logout_rounded, size: 18);
    switch (variant) {
      case SignOutButtonVariant.text:
        return TextButton.icon(
          onPressed: () => _handle(context),
          style: TextButton.styleFrom(foregroundColor: UiColors.textMuted),
          icon: icon,
          label: Text(label),
        );
      case SignOutButtonVariant.outlined:
        return OutlinedButton.icon(
          onPressed: () => _handle(context),
          icon: icon,
          label: Text(label),
        );
    }
  }
}
