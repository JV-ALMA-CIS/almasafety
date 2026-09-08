import 'dart:async' show StreamSubscription, unawaited;
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../features/authentication/data/membership_repository.dart';
import '../../features/authentication/data/user_profile_repository.dart';
import '../../features/authentication/domain/account_status.dart';
import '../../features/authentication/domain/membership.dart';
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
/// SECURITY WARNING: [status], [accountStatus], [memberships],
/// [activeOrganizationId], [activeMembership] and [UserProfile.platformRole]
/// (read from [profile]) drive UI behavior only (what screens/actions are
/// shown). They are never a substitute for Firestore security rules or the
/// Cloud Functions callables' own server-side checks — a compromised or
/// modified client must not be able to gain access by manipulating this
/// class. In particular, [setActiveOrganization] only changes which of the
/// caller's OWN memberships the UI currently displays; every privileged
/// callable independently re-verifies the caller's membership in whichever
/// organization it is asked to act within, and never trusts this class's
/// notion of "active" organization.
class SessionController extends ChangeNotifier {
  SessionController({
    AuthService? authService,
    UserProfileRepository? userProfileRepository,
    MembershipRepository? membershipRepository,
    Future<SharedPreferences>? sharedPreferences,
  }) : _authService = authService ?? AuthService(),
       _userProfileRepository =
           userProfileRepository ??
           UserProfileRepository(firestoreService: FirestoreService()),
       _membershipRepository =
           membershipRepository ??
           MembershipRepository(firestoreService: FirestoreService()),
       _sharedPreferences =
           sharedPreferences ?? SharedPreferences.getInstance() {
    _authSubscription = _authService.authStateChanges().listen(
      _onAuthStateChanged,
      onError: (Object error) =>
          _fail(_asAppException(error, 'Authentication failed.')),
    );
  }

  final AuthService _authService;
  final UserProfileRepository _userProfileRepository;
  final MembershipRepository _membershipRepository;

  /// Backing store for [_selectedOrganizationId] persistence. Injectable in
  /// tests (pair with `SharedPreferences.setMockInitialValues`); production
  /// callers pass nothing and this resolves the real platform-channel-backed
  /// instance.
  final Future<SharedPreferences> _sharedPreferences;
  late final StreamSubscription<User?> _authSubscription;
  StreamSubscription<UserProfile?>? _profileSubscription;
  StreamSubscription<List<Membership>>? _membershipSubscription;
  bool _disposed = false;

  User? _firebaseUser;
  UserProfile? _profile;
  AuthStatus _status = AuthStatus.loading;
  AppException? _lastError;
  List<Membership> _memberships = const [];

  /// The organization explicitly selected via [setActiveOrganization] for
  /// the current uid, when the user holds more than one membership.
  ///
  /// Persisted to [SharedPreferences] under `'activeOrganizationId:$uid'` so
  /// the choice survives an app restart. [SharedPreferences.getInstance] is
  /// async, so this field is a synchronous in-memory cache, loaded once
  /// per-uid by [_loadPersistedSelection] (fired alongside the membership
  /// subscription, once memberships are known to exist for this uid) and
  /// kept current thereafter by [setActiveOrganization]'s write-through.
  String? _selectedOrganizationId;
  String? _selectedForUid;

  /// The uid [_loadPersistedSelection] has already read (or is reading) a
  /// persisted selection for, so a rebuilt membership subscription (e.g. a
  /// duplicate snapshot) does not re-trigger a redundant read.
  String? _loadedSelectionForUid;

  User? get firebaseUser => _firebaseUser;
  UserProfile? get profile => _profile;
  AuthStatus get status => _status;
  AppException? get lastError => _lastError;

  /// The authoritative account state, or null when no profile is loaded.
  AccountStatus? get accountStatus => _profile?.accountStatus;

  /// Every organization the signed-in user belongs to. Empty before the
  /// profile/memberships have loaded, and empty for an [AppRole.admin], who
  /// holds no memberships (platform-level, org-less by construction).
  List<Membership> get memberships => _memberships;

  /// The organization the signed-in user is currently acting within, or null.
  ///
  /// Resolution order:
  ///  1. Exactly one membership: that one, always — there is nothing to
  ///     choose.
  ///  2. More than one membership: the last one explicitly selected via
  ///     [setActiveOrganization] for this uid — persisted locally (see
  ///     [_selectedOrganizationId]'s doc comment), so this survives an app
  ///     restart — falling back to the first membership by organization id
  ///     when nothing has been selected yet (or the persisted value has not
  ///     finished loading).
  ///  3. Zero memberships: null.
  String? get activeOrganizationId {
    if (_memberships.isEmpty) return null;
    if (_memberships.length == 1) return _memberships.single.organizationId;

    final uid = _firebaseUser?.uid;
    if (uid != null &&
        _selectedForUid == uid &&
        _selectedOrganizationId != null &&
        _memberships.any((m) => m.organizationId == _selectedOrganizationId)) {
      return _selectedOrganizationId;
    }

    final sorted = [..._memberships]
      ..sort((a, b) => a.organizationId.compareTo(b.organizationId));
    return sorted.first.organizationId;
  }

  /// The [Membership] matching [activeOrganizationId], or null.
  Membership? get activeMembership {
    final organizationId = activeOrganizationId;
    if (organizationId == null) return null;
    for (final membership in _memberships) {
      if (membership.organizationId == organizationId) return membership;
    }
    return null;
  }

  /// The caller's own [Membership] for [organizationId] specifically, or
  /// null if they hold none there.
  ///
  /// Distinct from [activeMembership]: that getter is a UI convenience for
  /// scoping day-to-day operational screens (Hazards, Meetings, ...), not
  /// "every organization this caller may act in". A management screen
  /// reached by navigating directly to a specific organization (e.g.
  /// tapping a project card, independent of which organization happens to
  /// be "active") must check membership in THAT organization, not the
  /// active one. Under the single-company model (PHASE 1) every caller
  /// holds at most one membership, so `activeOrganizationId` and this
  /// method resolve identically in practice — this distinction remains
  /// correct groundwork if a second organization is ever introduced.
  Membership? membershipFor(String organizationId) {
    for (final membership in _memberships) {
      if (membership.organizationId == organizationId) return membership;
    }
    return null;
  }

  /// Selects which of the caller's own memberships the UI should treat as
  /// "active" going forward. Validated defensively against the caller's own
  /// [memberships] — this is a UI convenience only (see this class's
  /// SECURITY WARNING); it grants no authority a server call would not
  /// independently re-verify.
  ///
  /// Written through to [SharedPreferences] (fire-and-forget — this is a UI
  /// convenience, not a security boundary, so the write need not be awaited)
  /// so the selection survives an app restart.
  void setActiveOrganization(String organizationId) {
    if (!_memberships.any((m) => m.organizationId == organizationId)) return;
    _selectedOrganizationId = organizationId;
    _selectedForUid = _firebaseUser?.uid;
    _safeNotify();

    final uid = _firebaseUser?.uid;
    if (uid != null) {
      unawaited(
        _sharedPreferences.then(
          (prefs) => prefs.setString(_selectionKey(uid), organizationId),
        ),
      );
    }
  }

  static String _selectionKey(String uid) => 'activeOrganizationId:$uid';

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
  Future<void> signIn({required String email, required String password}) async {
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
    await _cancelMembershipSubscription();
    _profile = null;
    _memberships = const [];
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
    _updateMembershipSubscription(profile);
    _safeNotify();
  }

  /// Starts (or stops) streaming the signed-in user's memberships once the
  /// profile is loaded and active. Mirrors [_loadProfileFor]/
  /// [_onProfileChanged]'s subscription lifecycle. Memberships are read
  /// self-or-Admin-only (see [MembershipRepository]'s doc comment), so this
  /// is only meaningful once a profile has resolved to a real, signed-in uid.
  void _updateMembershipSubscription(UserProfile? profile) {
    final uid = _firebaseUser?.uid;
    if (profile == null || uid == null || !profile.hasOperationalAccess) {
      unawaited(_cancelMembershipSubscription());
      if (_memberships.isNotEmpty) {
        _memberships = const [];
      }
      return;
    }

    _loadPersistedSelection(uid);

    // Already streaming for this uid — nothing to restart.
    if (_membershipSubscription != null && _membershipUid == uid) return;

    unawaited(_cancelMembershipSubscription());
    _membershipUid = uid;
    _membershipSubscription = _membershipRepository
        .watchAll(uid)
        .listen(_onMembershipsChanged, onError: _onMembershipsError);
  }

  /// Loads this uid's persisted [_selectedOrganizationId] once memberships
  /// are known to be loading for it, so [activeOrganizationId] can honor a
  /// prior selection as soon as it resolves rather than only after the next
  /// [setActiveOrganization] call. Runs at most once per uid per session
  /// (tracked by [_loadedSelectionForUid]) — cheap, but there is no reason to
  /// repeat it on every membership snapshot.
  void _loadPersistedSelection(String uid) {
    if (_loadedSelectionForUid == uid) return;
    _loadedSelectionForUid = uid;
    unawaited(
      _sharedPreferences.then((prefs) {
        if (_disposed || _firebaseUser?.uid != uid) return;
        final stored = prefs.getString(_selectionKey(uid));
        if (stored == null) return;
        _selectedOrganizationId = stored;
        _selectedForUid = uid;
        _safeNotify();
      }),
    );
  }

  String? _membershipUid;

  void _onMembershipsChanged(List<Membership> memberships) {
    if (_disposed) return;
    _memberships = memberships;
    _safeNotify();
  }

  void _onMembershipsError(Object error) {
    if (_disposed) return;
    // A membership-load failure should not deny access to an already-active
    // account (the profile stream is the access gate) — it just means
    // activeOrganizationId/activeMembership fall back to empty until the
    // stream recovers, which the UI can treat like "no organizations yet".
    _memberships = const [];
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

  Future<void> _cancelMembershipSubscription() async {
    final subscription = _membershipSubscription;
    _membershipSubscription = null;
    _membershipUid = null;
    await subscription?.cancel();
  }

  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _authSubscription.cancel();
    _profileSubscription?.cancel();
    _profileSubscription = null;
    _membershipSubscription?.cancel();
    _membershipSubscription = null;
    super.dispose();
  }
}
