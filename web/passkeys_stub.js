// First-party no-op stub for the `passkeys_web` plugin.
//
// supabase_flutter pulls in `passkeys` -> `passkeys_web` transitively. Its web
// plugin auto-registers and calls window.PasskeyAuthenticator.init() at startup;
// without Corbado's external SDK bundle that global is undefined, the call throws
// during plugin registration, and the whole Flutter app white-screens.
//
// Recall authenticates with email/password only and never invokes any passkey
// flow, so we define a minimal stub matching passkeys_web/lib/interop.dart just
// enough for init() to succeed and the app to boot. No third-party code is
// loaded; the passkey methods are inert (register/login reject if ever called).
window.PasskeyAuthenticator = {
  init: function () {},
  register: function () {
    return Promise.reject(new Error('Passkeys are not enabled in this build.'));
  },
  login: function () {
    return Promise.reject(new Error('Passkeys are not enabled in this build.'));
  },
  cancelCurrentAuthenticatorOperation: function () {},
  isUserVerifyingPlatformAuthenticatorAvailable: function () {
    return Promise.resolve(false);
  },
  isConditionalMediationAvailable: function () {
    return Promise.resolve(false);
  },
  hasPasskeySupport: function () {
    return false;
  }
};
