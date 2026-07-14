import 'dart:async';

import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';

import '../../../../theme/ui_tokens.dart';

abstract class RecallBiometricPrompt {
  Future<bool> get canAuthenticate;
  Future<bool> authenticate();
  Future<void> cancel();
}

class LocalAuthRecallBiometricPrompt implements RecallBiometricPrompt {
  final LocalAuthentication _auth;

  LocalAuthRecallBiometricPrompt({LocalAuthentication? auth})
    : _auth = auth ?? LocalAuthentication();

  @override
  Future<bool> get canAuthenticate async {
    try {
      return await _auth.isDeviceSupported();
    } catch (error) {
      debugPrint(
        'Recall: local authentication capability check failed: $error',
      );
      return false;
    }
  }

  @override
  Future<bool> authenticate() async {
    try {
      return await _auth.authenticate(
        localizedReason: 'Unlock Recall to continue studying',
        biometricOnly: false,
        persistAcrossBackgrounding: true,
      );
    } catch (error) {
      debugPrint('Recall: local authentication failed: $error');
      return false;
    }
  }

  @override
  Future<void> cancel() async {
    try {
      await _auth.stopAuthentication();
    } catch (error) {
      debugPrint('Recall: could not cancel local authentication: $error');
    }
  }
}

class BiometricUnlockGate extends StatefulWidget {
  final Widget child;
  final RecallBiometricPrompt prompt;
  final Future<void> Function()? onSignOut;

  BiometricUnlockGate({
    super.key,
    required this.child,
    RecallBiometricPrompt? prompt,
    this.onSignOut,
  }) : prompt = prompt ?? LocalAuthRecallBiometricPrompt();

  @override
  State<BiometricUnlockGate> createState() => _BiometricUnlockGateState();
}

class _BiometricUnlockGateState extends State<BiometricUnlockGate>
    with WidgetsBindingObserver {
  bool _locked = true;
  bool _authenticating = false;
  bool _signingOut = false;
  bool _authenticationAvailable = true;
  bool _promptCancelled = false;
  String? _signOutError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(widget.prompt.cancel());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_authenticating) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      if (!_locked && mounted) {
        FocusManager.instance.primaryFocus?.unfocus();
        setState(() => _locked = true);
      }
      return;
    }
    if (state == AppLifecycleState.resumed && _locked) {
      unawaited(_unlock());
    }
  }

  Future<void> _unlock() async {
    if (!mounted || !_locked || _authenticating || _signingOut) return;
    setState(() {
      _authenticating = true;
      _promptCancelled = false;
      _signOutError = null;
    });
    final available = await widget.prompt.canAuthenticate;
    if (!mounted) return;
    if (!available) {
      setState(() {
        _authenticating = false;
        _authenticationAvailable = false;
      });
      return;
    }
    final unlocked = await widget.prompt.authenticate();
    if (!mounted) return;
    setState(() {
      _authenticating = false;
      _authenticationAvailable = true;
      _locked = !unlocked;
      _promptCancelled = !unlocked;
    });
  }

  Future<void> _signOut() async {
    final signOut = widget.onSignOut;
    if (signOut == null || _signingOut) return;
    setState(() {
      _signingOut = true;
      _signOutError = null;
    });
    try {
      await signOut();
    } catch (error) {
      if (mounted) setState(() => _signOutError = '$error');
    } finally {
      if (mounted) setState(() => _signingOut = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ExcludeFocus(
          excluding: _locked,
          child: Offstage(offstage: _locked, child: widget.child),
        ),
        if (_locked)
          Scaffold(
            body: Container(
              decoration: const BoxDecoration(gradient: scaffoldGradient),
              child: SafeArea(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: Container(
                      margin: const EdgeInsets.all(UiSpacing.lg),
                      padding: const EdgeInsets.all(UiSpacing.lg),
                      decoration: buildPanelDecoration(),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Icon(
                            Icons.lock_outline,
                            size: 42,
                            color: UiColors.primary,
                          ),
                          const SizedBox(height: UiSpacing.md),
                          Text(
                            _authenticationAvailable
                                ? 'Recall is locked'
                                : 'Device authentication is not available',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(height: UiSpacing.sm),
                          Text(
                            _authenticationAvailable
                                ? 'Use Face ID, fingerprint, or your device passcode to continue studying.'
                                : 'Enable biometrics or a device passcode in Settings, then try again.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: UiColors.textMuted),
                          ),
                          if (_promptCancelled) ...[
                            const SizedBox(height: UiSpacing.md),
                            Text(
                              'Recall stayed locked because authentication was cancelled.',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: UiColors.textMuted),
                            ),
                          ],
                          if (_signOutError != null) ...[
                            const SizedBox(height: UiSpacing.md),
                            Text(
                              _signOutError!,
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: UiColors.danger),
                            ),
                          ],
                          const SizedBox(height: UiSpacing.lg),
                          FilledButton.icon(
                            onPressed: _authenticating ? null : _unlock,
                            icon: _authenticating
                                ? const SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.fingerprint),
                            label: Text(
                              _authenticating
                                  ? 'Checking device security...'
                                  : 'Unlock Recall',
                            ),
                          ),
                          if (widget.onSignOut != null) ...[
                            const SizedBox(height: UiSpacing.sm),
                            TextButton(
                              onPressed: _authenticating || _signingOut
                                  ? null
                                  : _signOut,
                              child: Text(
                                _signingOut ? 'Signing out...' : 'Sign out',
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

bool supportsRecallBiometricUnlock({
  required bool isWeb,
  required TargetPlatform targetPlatform,
}) =>
    !isWeb &&
    (targetPlatform == TargetPlatform.iOS ||
        targetPlatform == TargetPlatform.android);
