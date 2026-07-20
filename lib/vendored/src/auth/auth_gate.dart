import 'package:flutter/material.dart';

import '../theme/shared_ui_tokens.dart';

/// Closure-based adapter the shared [AuthGate] renders against.
///
/// Each app builds one of these around its *own* controller — the controllers
/// themselves don't change (they keep their existing field names and types).
/// [source] is the [Listenable] the gate rebuilds on (normally the controller).
///
/// If [signUp] is omitted the gate renders a sign-in-only form (no mode toggle),
/// which is what Recall wants.
class AuthGateModel extends Listenable {
  AuthGateModel({
    required Listenable source,
    required bool Function() submitting,
    required String? Function() errorText,
    String? Function()? noticeText,
    required Future<void> Function({
      required String email,
      required String password,
    })
    signIn,
    Future<void> Function({required String email, required String password})?
    signUp,
  }) : _source = source,
       _submitting = submitting,
       _errorText = errorText,
       _noticeText = noticeText,
       _signIn = signIn,
       _signUp = signUp;

  final Listenable _source;
  final bool Function() _submitting;
  final String? Function() _errorText;
  final String? Function()? _noticeText;
  final Future<void> Function({required String email, required String password})
  _signIn;
  final Future<void> Function({
    required String email,
    required String password,
  })?
  _signUp;

  /// True while a sign-in / sign-up request is in flight (disables the form).
  bool get submitting => _submitting();

  /// Non-null when the last attempt failed — shown in the error colour.
  String? get errorText => _errorText();

  /// Non-null for a non-error notice (e.g. "check your email") — shown in the
  /// success colour. Optional.
  String? get noticeText => _noticeText?.call();

  /// Whether this app offers account creation (drives the mode toggle).
  bool get supportsSignUp => _signUp != null;

  Future<void> signIn({required String email, required String password}) =>
      _signIn(email: email, password: password);

  Future<void> signUp({required String email, required String password}) =>
      _signUp!(email: email, password: password);

  @override
  void addListener(VoidCallback listener) => _source.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _source.removeListener(listener);
}

/// The one login screen every app shares.
///
/// Brand text comes from [appName]/[subtitle]; the accent comes from the ambient
/// theme (`colorScheme.primary`), so it's emerald on the dashboard and indigo on
/// Recall/Lift automatically. Behaviour comes entirely from [model]. The navy
/// [scaffoldGradient] backdrop and the panel card are baked in so all three look
/// identical down to the pixel.
class AuthGate extends StatefulWidget {
  const AuthGate({
    super.key,
    required this.model,
    required this.appName,
    this.subtitle,
    this.maxWidth = 460,
  });

  final AuthGateModel model;
  final String appName;
  final String? subtitle;
  final double maxWidth;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _createMode = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  bool get _creating => _createMode && widget.model.supportsSignUp;

  Future<void> _submit() async {
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || password.isEmpty) return;
    if (_creating) {
      await widget.model.signUp(email: email, password: password);
    } else {
      await widget.model.signIn(email: email, password: password);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final initial = widget.appName.isEmpty
        ? '?'
        : widget.appName.substring(0, 1).toUpperCase();

    final form = ListenableBuilder(
      listenable: widget.model,
      builder: (context, _) {
        final m = widget.model;
        final error = m.errorText;
        final notice = m.noticeText;
        final busy = m.submitting;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: _BrandMark(accent: accent, letter: initial),
            ),
            const SizedBox(height: UiSpacing.md),
            Text(
              widget.appName,
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineLarge,
            ),
            if (widget.subtitle != null) ...[
              const SizedBox(height: UiSpacing.xs),
              Text(
                widget.subtitle!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: UiColors.textMuted,
                ),
              ),
            ],
            const SizedBox(height: UiSpacing.xl),
            Container(
              padding: const EdgeInsets.all(UiSpacing.lg),
              decoration: buildPanelDecoration(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (m.supportsSignUp) ...[
                    _ModeToggle(
                      createMode: _createMode,
                      onChanged: busy
                          ? null
                          : (v) => setState(() => _createMode = v),
                    ),
                    const SizedBox(height: UiSpacing.md),
                  ],
                  TextField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    enableSuggestions: false,
                    autofillHints: const [AutofillHints.email],
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(labelText: 'Email'),
                  ),
                  const SizedBox(height: UiSpacing.md),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    autofillHints: const [AutofillHints.password],
                    onSubmitted: (_) => _submit(),
                    decoration: const InputDecoration(labelText: 'Password'),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: UiSpacing.md),
                    _Message(
                      text: error,
                      color: UiColors.danger,
                      icon: Icons.error_outline,
                    ),
                  ] else if (notice != null) ...[
                    const SizedBox(height: UiSpacing.md),
                    _Message(
                      text: notice,
                      color: UiColors.scoreGood,
                      icon: Icons.check_circle_outline,
                    ),
                  ],
                  const SizedBox(height: UiSpacing.lg),
                  FilledButton(
                    onPressed: busy ? null : _submit,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        vertical: UiSpacing.md,
                      ),
                    ),
                    child: Text(
                      _creating
                          ? (busy ? 'Creating account…' : 'Create account')
                          : (busy ? 'Signing in…' : 'Sign in'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );

    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(gradient: scaffoldGradient),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(UiSpacing.lg),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: widget.maxWidth),
                child: form,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Accent rounded-square with the app initial — same dark-ink-on-accent look as
/// the home-screen icons, so the login reads as "this app".
class _BrandMark extends StatelessWidget {
  const _BrandMark({required this.accent, required this.letter});

  final Color accent;
  final String letter;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 60,
      height: 60,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(UiRadii.input),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [accent, Color.lerp(accent, UiColors.canvas, 0.32)!],
        ),
        boxShadow: const [
          BoxShadow(
            color: UiShadows.deep,
            blurRadius: 16,
            offset: Offset(0, 6),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        letter,
        style: const TextStyle(
          color: UiColors.canvas,
          fontSize: 30,
          fontWeight: FontWeight.w800,
          height: 1,
        ),
      ),
    );
  }
}

/// Sign-in / Create-account segmented toggle (only shown when sign-up is on).
class _ModeToggle extends StatelessWidget {
  const _ModeToggle({required this.createMode, required this.onChanged});

  final bool createMode;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    // Wrap (not Row) so the two chips reflow onto a second line on a narrow
    // card instead of overflowing.
    return Wrap(
      spacing: UiSpacing.sm,
      runSpacing: UiSpacing.xs,
      children: [
        ChoiceChip(
          label: const Text('Sign in'),
          selected: !createMode,
          onSelected: onChanged == null ? null : (_) => onChanged!(false),
        ),
        ChoiceChip(
          label: const Text('Create account'),
          selected: createMode,
          onSelected: onChanged == null ? null : (_) => onChanged!(true),
        ),
      ],
    );
  }
}

/// Inline status line (error or notice) with a leading glyph.
class _Message extends StatelessWidget {
  const _Message({required this.text, required this.color, required this.icon});

  final String text;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: UiSpacing.xs),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: color, fontSize: 13, height: 1.3),
          ),
        ),
      ],
    );
  }
}
