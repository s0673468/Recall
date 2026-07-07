import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/features/auth/application/biometric_sign_in_service.dart';

class _FakeVault implements RecallCredentialVault {
  RecallSavedCredentials? saved;
  var clearCount = 0;

  @override
  Future<void> saveCredentials({
    required String email,
    required String password,
  }) async {
    saved = RecallSavedCredentials(email: email, password: password);
  }

  @override
  Future<RecallSavedCredentials?> readCredentials() async => saved;

  @override
  Future<void> clearCredentials() async {
    clearCount++;
    saved = null;
  }
}

class _FakePrompt implements RecallBiometricPrompt {
  _FakePrompt({this.available = true});

  bool available;
  var promptCount = 0;

  @override
  Future<bool> get canAuthenticate async => available;

  @override
  Future<bool> authenticate() async {
    promptCount++;
    return true;
  }
}

void main() {
  test('saves and returns credentials after biometric auth succeeds', () async {
    final vault = _FakeVault();
    final prompt = _FakePrompt();
    final service = BiometricSignInService(
      vault: vault,
      prompt: prompt,
      isSupportedPlatform: () => true,
    );

    await service.saveCredentials(email: ' user@example.com ', password: 'pw');
    final credentials = await service.authenticateAndRead();

    expect(credentials?.email, 'user@example.com');
    expect(credentials?.password, 'pw');
    expect(prompt.promptCount, 1);
  });

  test('does not prompt without saved credentials', () async {
    final vault = _FakeVault();
    final prompt = _FakePrompt();
    final service = BiometricSignInService(
      vault: vault,
      prompt: prompt,
      isSupportedPlatform: () => true,
    );

    expect(await service.authenticateAndRead(), isNull);
    expect(prompt.promptCount, 0);
  });

  test(
    'does not return credentials when biometric auth is unavailable',
    () async {
      final vault = _FakeVault()
        ..saved = const RecallSavedCredentials(
          email: 'a@b.com',
          password: 'pw',
        );
      final prompt = _FakePrompt(available: false);
      final service = BiometricSignInService(
        vault: vault,
        prompt: prompt,
        isSupportedPlatform: () => true,
      );

      expect(await service.authenticateAndRead(), isNull);
      expect(prompt.promptCount, 0);
    },
  );

  test('clears saved credentials', () async {
    final vault = _FakeVault()
      ..saved = const RecallSavedCredentials(email: 'a@b.com', password: 'pw');
    final service = BiometricSignInService(
      vault: vault,
      prompt: _FakePrompt(),
      isSupportedPlatform: () => true,
    );

    await service.clearCredentials();

    expect(vault.saved, isNull);
    expect(vault.clearCount, 1);
  });
}
