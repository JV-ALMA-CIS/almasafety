import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../errors/app_exception.dart';

/// Thin wrapper around FirebaseAuth.
///
/// Feature code should depend on this service rather than calling
/// FirebaseAuth.instance directly, so auth can be mocked in tests and so
/// cross-cutting behavior (e.g. logging, token refresh hooks) has one place
/// to live.
///
/// Resolves [FirebaseAuth.instance] lazily rather than at construction time,
/// so this class (and anything that builds it, like SessionController) can
/// still be constructed before Firebase.initializeApp() has run — e.g. in
/// widget tests, or when Firebase configuration is unavailable at runtime.
///
/// Note there is no custom-claims accessor here. Under the self-registration
/// model the profile document at `users/{uid}` is the single source of truth
/// for account state, and the client addresses it by uid alone — it does not
/// need a claim to know where its own profile lives. Claims will return when
/// role/site RBAC arrives, as a rules-performance optimisation, not as the
/// client's notion of identity.
class AuthService {
  AuthService({FirebaseAuth? firebaseAuth}) : _injectedAuth = firebaseAuth;

  final FirebaseAuth? _injectedAuth;

  FirebaseAuth? get _firebaseAuth {
    if (_injectedAuth != null) return _injectedAuth;
    if (Firebase.apps.isEmpty) return null;
    return FirebaseAuth.instance;
  }

  /// Emits on sign-in, sign-out and on session restoration at app start.
  /// Firebase persists the session itself, so this is what makes a signed-in
  /// user still signed in after a cold start.
  Stream<User?> authStateChanges() =>
      _firebaseAuth?.authStateChanges() ?? const Stream.empty();

  User? get currentUser => _firebaseAuth?.currentUser;

  Future<UserCredential> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    final auth = _requireAuth('Sign-in');
    try {
      return await auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
    } on FirebaseAuthException catch (e) {
      throw mapAuthError(e);
    } on TimeoutException catch (e) {
      throw NetworkException(
        'The request timed out. Check your connection and try again.',
        cause: e,
      );
    }
  }

  /// Creates a Firebase Auth account.
  ///
  /// This grants nothing on its own: the account has no profile, no
  /// organization and no privileges until [UserProfileRepository] writes a
  /// `pending` profile for it and an approver acts on that profile.
  Future<UserCredential> createUserWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    final auth = _requireAuth('Registration');
    try {
      return await auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
    } on FirebaseAuthException catch (e) {
      throw mapAuthError(e);
    } on TimeoutException catch (e) {
      throw NetworkException(
        'The request timed out. Check your connection and try again.',
        cause: e,
      );
    }
  }

  /// Deletes the currently signed-in account.
  ///
  /// Used only to roll back a half-finished registration: if the Auth account
  /// was created but the profile write failed, leaving the account behind
  /// would strand the user in a state where they can sign in but have no
  /// profile and cannot re-register with the same email. Failures here are
  /// swallowed by the caller — a stranded account is recoverable by an
  /// administrator, whereas throwing would mask the original error.
  Future<void> deleteCurrentUser() async {
    final user = _firebaseAuth?.currentUser;
    if (user == null) return;
    await user.delete();
  }

  Future<void> signOut() => _firebaseAuth?.signOut() ?? Future.value();

  /// Emails [email] a Firebase link for choosing a new password — the
  /// signed-in person's own address (Settings → Change password). Firebase
  /// sends the email; nothing about the account changes until the link is
  /// used.
  Future<void> sendPasswordResetEmail(String email) async {
    final auth = _requireAuth('Changing the password');
    try {
      await auth.sendPasswordResetEmail(email: email);
    } on FirebaseAuthException catch (e) {
      throw mapAuthError(e);
    } on TimeoutException catch (e) {
      throw NetworkException(
        'The request timed out. Check your connection and try again.',
        cause: e,
      );
    }
  }

  FirebaseAuth _requireAuth(String operation) {
    final auth = _firebaseAuth;
    if (auth == null) {
      throw AuthException(
        '$operation is unavailable right now. Please try again later.',
      );
    }
    return auth;
  }

  /// Maps a Firebase auth failure to the app's exception hierarchy with a
  /// user-safe message. Raw Firebase codes/messages are retained only in
  /// [AppException.cause] for diagnostics — they are never shown to users.
  static AppException mapAuthError(FirebaseAuthException e) {
    if (e.code == 'network-request-failed') {
      return NetworkException(
        'Network error. Check your connection and try again.',
        cause: e,
      );
    }
    return AuthException(_messageForCode(e.code), cause: e);
  }

  static String _messageForCode(String code) {
    switch (code) {
      case 'invalid-email':
        return 'Enter a valid email address.';
      case 'user-disabled':
        return 'This account has been disabled. Contact your administrator.';
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        // Deliberately identical for all three: distinguishing them would
        // let an attacker enumerate valid accounts.
        return 'Incorrect email or password.';
      case 'too-many-requests':
        return 'Too many attempts. Please wait and try again.';
      case 'operation-not-allowed':
        return 'Sign-in is unavailable right now. Contact your administrator.';
      case 'email-already-in-use':
        return 'An account already exists for that email address. '
            'Sign in instead.';
      case 'weak-password':
        return 'Choose a stronger password of at least 8 characters.';
      default:
        return 'Something went wrong. Please try again.';
    }
  }
}
