import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../features/authentication/data/user_profile_repository.dart';
import '../../features/authentication/domain/account_status.dart';
import '../../features/authentication/domain/user_profile.dart';
import '../errors/app_exception.dart';
import 'auth_service.dart';
import 'firestore_service.dart';

/// The session's high-level state, driving router redirects and top-level
/// loading/error UI.
enum AuthStatus {
  /// Firebase auth state has not resolved yet (app just launched; session
  /// restoration in progress).
  loading,

  /// No signed-in Firebase user.
  unauthenticated,

  /// A sign-in or registration attempt is in flight.
  authenticating,

  /// Signed in, but the user's Firestore profile hasn't loaded yet (or is
  /// being reloaded).
  loadingProfile,

  /// Signed in with a loaded, active profile — full app access.
  authenticated,

  /// Registered and awaiting approval by an authorized organizational user.
  pending,

  /// Approved once, but access has since been withdrawn.
  suspended,

  /// Reviewed and refused.
  rejected,

  /// Signed in, but no profile document exists. Normally unreachable — it
  /// means the Auth account was created and the profile write did not land.
  profileMissing,

  /// Sign-in, registration or profile loading failed. See [lastError].
  error,
}

/// Statuses that grant no access to operational routes. Kept next to the
/// enum so any future status must be explicitly classified.
const Set<AuthStatus> _deniedStatuses = {
  AuthStatus.pending,
  AuthStatus.suspended,
  AuthStatus.rejected,
  AuthStatus.profileMissing,
  AuthStatus.error,
};

/// Represents the authenticated user's session context: identity, account
/// status and (once approved) organization scope.
///
/// SECURITY WARNING: [status], [accountStatus], [organizationId] and
/// [UserProfile.platformRole] (read from [profile]) drive UI behavior only (what
/// screens/actions are shown). They are never a substitute for Firestore
/// security rules or the Cloud Functions callables' own server-side checks —
/// a compromised or modified client must not be able to gain access by
/// manipulating this class.
class SessionController extends ChangeNotifier {
  SessionController({
    AuthService? authService,
    UserProfileRepository? userProfileRepository,
  }) : _authService = authService ?? AuthService(),
       _userProfileRepository =
           userProfileRepository ??
           UserProfileRepository(firestoreService: FirestoreService()) {
    _authSubscription = _authService.authStateChanges().listen(
      _onAuthStateChanged,
      onError: (Object error) =>
          _fail(_asAppException(error, 'Authentication failed.')),
    );
  }

  final AuthService _authService;
  final UserProfileRepository _userProfileRepository;
  late final StreamSubscription<User?> _authSubscription;
  StreamSubscription<UserProfile?>? _profileSubscription;
  bool _disposed = false;

  User? _firebaseUser;
  UserProfile? _profile;
  AuthStatus _status = AuthStatus.loading;
  AppException? _lastError;

  User? get firebaseUser => _firebaseUser;
  UserProfile? get profile => _profile;
  AuthStatus get status => _status;
  AppException? get lastError => _lastError;

  /// The authoritative account state, or null when no profile is loaded.
  AccountStatus? get accountStatus => _profile?.accountStatus;

  /// The organization this session is scoped to, or null when the user has
  /// not been approved into one yet. Never inferred from the email address
  /// and never hardcoded in the app.
  String? get organizationId => _profile?.organizationId;

  /// True only when there is a signed-in Firebase user AND a loaded profile
  /// with [AccountStatus.active]. Router guards and feature code should use
  /// this (or [status]) rather than checking [firebaseUser] alone, so a
  /// pending or suspended account is never treated as having app access.
  bool get isAuthenticated => _status == AuthStatus.authenticated;

  /// True while the session is still resolving and no decision can be made.
  bool get isResolving =>
      _status == AuthStatus.loading ||
      _status == AuthStatus.authenticating ||
      _status == AuthStatus.loadingProfile;

  /// True when signed in to Firebase but denied operational access.
  bool get isDenied => _deniedStatuses.contains(_status);

  /// Signs in with email/password. State transitions to
  /// [AuthStatus.authenticating] and then follows the auth-state listener
  /// into profile loading; on failure it lands on [AuthStatus.error] with
  /// [lastError] set, and rethrows so the sign-in screen can show the
  /// message inline.
  Future<void> signIn({
    required String email,
    required String password,
  }) async {
    _status = AuthStatus.authenticating;
    _lastError = null;
    _safeNotify();
    try {
      await _authService.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      // The auth-state listener drives the remaining transitions.
    } on AppException catch (e) {
      _fail(e);
      rethrow;
    }
  }

  /// Self-registration: creates the Firebase Auth account, then its `pending`
  /// profile document.
  ///
  /// The caller supplies only name, email, phone and password. There is no
  /// parameter for role, trade, organization, site, activity or account
  /// status —
  /// registration cannot grant a privilege because there is no argument by
  /// which one could be requested.
  ///
  /// If the profile write fails after the account was created, the account is
  /// rolled back so the user is not stranded able-to-sign-in but
  /// profile-less, and can simply retry with the same email.
  Future<void> register({
    required String name,
    required String email,
    required String phone,
    required String password,
  }) async {
    _status = AuthStatus.authenticating;
    _lastError = null;
    _safeNotify();

    final String uid;
    try {
      final credential = await _authService.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      final user = credential.user;
      if (user == null) {
        throw const AuthException(
          'Registration did not complete. Please try again.',
        );
      }
      uid = user.uid;
    } on AppException catch (e) {
      _fail(e);
      rethrow;
    }

    try {
      await _userProfileRepository.createPendingProfile(
        uid: uid,
        name: name,
        email: email,
        phone: phone,
      );
    } on AppException catch (e) {
      // Best-effort rollback. A failure to delete is not surfaced: the
      // original profile-write error is the one worth reporting.
      try {
        await _authService.deleteCurrentUser();
      } on Object catch (_) {
        // Ignored deliberately; see above.
      }
      await _authService.signOut();
      _fail(e);
      rethrow;
    }
    // The auth-state listener picks up the new user and loads the profile,
    // landing the session on AuthStatus.pending.
  }

  Future<void> signOut() async {
    try {
      await _authService.signOut();
    } on Object catch (e) {
      _fail(_asAppException(e, 'Sign-out failed. Please try again.'));
    }
  }

  /// Reloads the profile. The profile is already streamed, so this is only
  /// needed as a manual recovery action after an error state.
  Future<void> refresh() async {
    final user = _firebaseUser;
    if (user == null) return;
    await _loadProfileFor(user);
  }

  Future<void> _onAuthStateChanged(User? user) async {
    _firebaseUser = user;
    await _cancelProfileSubscription();
    _profile = null;
    _lastError = null;

    if (user == null) {
      _status = AuthStatus.unauthenticated;
      _safeNotify();
      return;
    }

    await _loadProfileFor(user);
  }

  Future<void> _loadProfileFor(User user) async {
    await _cancelProfileSubscription();

    _status = AuthStatus.loadingProfile;
    _safeNotify();

    if (_disposed || _firebaseUser?.uid != user.uid) return;

    _profileSubscription = _userProfileRepository
        .watchByUid(user.uid)
        .listen(_onProfileChanged, onError: _onProfileError);
  }

  void _onProfileChanged(UserProfile? profile) {
    if (_disposed) return;
    _profile = profile;
    _lastError = null;
    _status = deriveStatus(profile);
    _safeNotify();
  }

  /// Pure decision of session status from a loaded profile (or null),
  /// isolated from Firebase so it can be unit tested directly.
  ///
  /// A Firebase-authenticated user reaches [AuthStatus.authenticated] only if
  /// their profile exists AND its [AccountStatus] is `active`. Every other
  /// status maps to its own denied state so the UI can explain *why*, and a
  /// missing document is [AuthStatus.profileMissing]. None of them grant
  /// access.
  static AuthStatus deriveStatus(UserProfile? profile) {
    if (profile == null) return AuthStatus.profileMissing;
    return switch (profile.accountStatus) {
      AccountStatus.active => AuthStatus.authenticated,
      AccountStatus.pending => AuthStatus.pending,
      AccountStatus.suspended => AuthStatus.suspended,
      AccountStatus.rejected => AuthStatus.rejected,
    };
  }

  void _onProfileError(Object error) {
    if (_disposed) return;
    _profile = null;
    _fail(_asAppException(error, 'Failed to load your profile.'));
  }

  void _fail(AppException error) {
    if (_disposed) return;
    _lastError = error;
    _status = AuthStatus.error;
    _safeNotify();
  }

  static AppException _asAppException(Object error, String fallbackMessage) {
    if (error is AppException) return error;
    return DataException(fallbackMessage, cause: error);
  }

  Future<void> _cancelProfileSubscription() async {
    final subscription = _profileSubscription;
    _profileSubscription = null;
    await subscription?.cancel();
  }

  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _authSubscription.cancel();
    _profileSubscription?.cancel();
    _profileSubscription = null;
    super.dispose();
  }
}
