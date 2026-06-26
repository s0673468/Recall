import 'package:flutter/material.dart';

import '../../../../theme/ui_tokens.dart';
import '../../application/review_controller.dart';

/// Email/password sign-in. Shown when there's no session (the production/Pages
/// build ships no bundled credentials — RLS gates all data behind this).
class AuthGate extends StatefulWidget {
  final ReviewController controller;
  const AuthGate({super.key, required this.controller});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  final _email = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || password.isEmpty) return;
    widget.controller.signIn(email: email, password: password);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: scaffoldGradient),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(UiSpacing.lg),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: ListenableBuilder(
                  listenable: widget.controller,
                  builder: (context, _) {
                    final s = widget.controller.state;
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          UiBrand.appName,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineLarge,
                        ),
                        const SizedBox(height: UiSpacing.xs),
                        const Text(
                          'Spaced repetition',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: UiColors.textMuted),
                        ),
                        const SizedBox(height: UiSpacing.xl),
                        Container(
                          padding: const EdgeInsets.all(UiSpacing.lg),
                          decoration: BoxDecoration(
                            color: UiColors.panel,
                            borderRadius: BorderRadius.circular(UiRadius.xl),
                            border: Border.all(color: UiColors.border),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              TextField(
                                controller: _email,
                                keyboardType: TextInputType.emailAddress,
                                autofillHints: const [AutofillHints.email],
                                decoration: const InputDecoration(
                                  labelText: 'Email',
                                ),
                              ),
                              const SizedBox(height: UiSpacing.md),
                              TextField(
                                controller: _password,
                                obscureText: true,
                                autofillHints: const [AutofillHints.password],
                                onSubmitted: (_) => _submit(),
                                decoration: const InputDecoration(
                                  labelText: 'Password',
                                ),
                              ),
                              if (s.error != null) ...[
                                const SizedBox(height: UiSpacing.md),
                                Text(
                                  s.error!,
                                  style: const TextStyle(
                                    color: UiColors.danger,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                              const SizedBox(height: UiSpacing.lg),
                              FilledButton(
                                onPressed: s.authSubmitting ? null : _submit,
                                style: FilledButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: UiSpacing.md,
                                  ),
                                ),
                                child: Text(
                                  s.authSubmitting ? 'Signing in…' : 'Sign in',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
