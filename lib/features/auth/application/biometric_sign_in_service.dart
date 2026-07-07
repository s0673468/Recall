import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

class RecallSavedCredentials {
  final String email;
  final String password;

  const RecallSavedCredentials({required this.email, required this.password});
}

abstract class RecallCredentialVault {
  Future<void> saveCredentials({
    required String email,
    required String password,
  });

  Future<RecallSavedCredentials?> readCredentials();

  Future<void> clearCredentials();
}

abstract class RecallBiometricPrompt {
  Future<bool> get canAuthenticate;

  Future<bool> authenticate();
}

class SecureRecallCredentialVault implements RecallCredentialVault {
  static const _emailKey = 'recall.auth.email';
  static const _passwordKey = 'recall.auth.password';
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(storageNamespace: 'recall_auth'),
  );

  const SecureRecallCredentialVault();

  @override
  Future<void> saveCredentials({
    required String email,
    required String password,
  }) async {
    await _storage.write(key: _emailKey, value: email);
    await _storage.write(key: _passwordKey, value: password);
  }

  @override
  Future<RecallSavedCredentials?> readCredentials() async {
    final email = await _storage.read(key: _emailKey);
    final password = await _storage.read(key: _passwordKey);
    if (email == null ||
        email.trim().isEmpty ||
        password == null ||
        password.isEmpty) {
      return null;
    }
    return RecallSavedCredentials(email: email, password: password);
  }

  @override
  Future<void> clearCredentials() async {
    await _storage.delete(key: _emailKey);
    await _storage.delete(key: _passwordKey);
  }
}

class LocalAuthRecallBiometricPrompt implements RecallBiometricPrompt {
  final LocalAuthentication _auth;

  LocalAuthRecallBiometricPrompt({LocalAuthentication? auth})
    : _auth = auth ?? LocalAuthentication();

  @override
  Future<bool> get canAuthenticate async {
    try {
      return await _auth.canCheckBiometrics &&
          await _auth.isDeviceSupported() &&
          (await _auth.getAvailableBiometrics()).isNotEmpty;
    } catch (e) {
      debugPrint('Recall: biometric capability check failed: $e');
      return false;
    }
  }

  @override
  Future<bool> authenticate() async {
    try {
      return _auth.authenticate(
        localizedReason: 'Unlock Recall with your fingerprint',
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );
    } catch (e) {
      debugPrint('Recall: biometric authentication failed: $e');
      return false;
    }
  }
}

class BiometricSignInService {
  final RecallCredentialVault _vault;
  final RecallBiometricPrompt _prompt;
  final bool Function() _isSupportedPlatform;

  BiometricSignInService({
    RecallCredentialVault vault = const SecureRecallCredentialVault(),
    RecallBiometricPrompt? prompt,
    bool Function()? isSupportedPlatform,
  }) : _vault = vault,
       _prompt = prompt ?? LocalAuthRecallBiometricPrompt(),
       _isSupportedPlatform = isSupportedPlatform ?? _isAndroidApp;

  static bool _isAndroidApp() =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> saveCredentials({
    required String email,
    required String password,
  }) async {
    if (!_isSupportedPlatform()) return;
    await _vault.saveCredentials(email: email.trim(), password: password);
  }

  Future<RecallSavedCredentials?> authenticateAndRead() async {
    if (!_isSupportedPlatform()) return null;
    final saved = await _vault.readCredentials();
    if (saved == null || !await _prompt.canAuthenticate) return null;
    if (!await _prompt.authenticate()) return null;
    return saved;
  }

  Future<void> clearCredentials() => _vault.clearCredentials();
}
