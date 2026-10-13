import 'dart:async';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/core/services/auth_service.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/authentication/data/membership_repository.dart';
import 'package:jva_safety/features/authentication/data/user_profile_repository.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A scriptable stand-in for [AuthService].
///
/// Subclassing the real service (rather than mocking FirebaseAuth) keeps the
/// test focused on SessionController's own logic: which transitions it makes,
/// in what order, and what it does when a step fails. It never touches
/// Firebase, so no emulator or initialized app is required.
class FakeAuthService implements AuthService {
  FakeAuthService();

  final _controller = StreamController<User?>.broadcast();

  /// The uid handed back by [createUserWithEmailAndPassword]; also the uid
  /// the auth-state stream reports as signed in.
  String? signedInUid;

  /// When set, registration fails at the Firebase Auth step.
  AppException? createUserError;

  bool deleteCalled = false;
  bool signOutCalled = false;
  bool signInCalled = false;

  @override
  Stream<User?> authStateChanges() => _controller.stream;

  /// Drives the auth-state stream the way Firebase would.
  void emitSignedIn(String uid) {
    signedInUid = uid;
    _controller.add(_FakeUser(uid));
  }

  void emitSignedOut() {
    signedInUid = null;
    _controller.add(null);
  }

  @override
  User? get currentUser => signedInUid == null ? null : _FakeUser(signedInUid!);

  @override
  Future<UserCredential> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    signInCalled = true;
    throw UnimplementedError('Not exercised by these tests.');
  }

  @override
  Future<UserCredential> createUserWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    final error = createUserError;
    if (error != null) throw error;
    // SessionController only reads credential.user.uid, so a minimal fake
    // credential is enough and avoids depending on Firebase internals.
    return _FakeUserCredential(_FakeUser(signedInUid ?? 'new-uid'));
  }

  @override
  Future<void> deleteCurrentUser() async {
    deleteCalled = true;
  }

  @override
  Future<void> signOut() async {
    signOutCalled = true;
    emitSignedOut();
  }

  Future<void> dispose() => _controller.close();
}

class _FakeUser implements User {
  _FakeUser(this.uid);

  @override
  final String uid;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeUserCredential implements UserCredential {
  _FakeUserCredential(this.user);

  @override
  final User? user;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Waits for the session to settle on a status, so tests do not depend on
/// the exact number of microtask turns a Firestore snapshot takes.
Future<void> waitForStatus(
  SessionController session,
  AuthStatus expected,
) async {
  for (var i = 0; i < 50; i++) {
    if (session.status == expected) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Session settled on ${session.status}, expected $expected');
}

/// Waits for the memberships stream (separate from the profile stream) to
/// settle on [expected], so a test does not depend on how many microtask
/// turns the memberships snapshot takes to arrive after the profile's own.
Future<void> _waitForActiveOrganization(
  SessionController session,
  String? expected,
) async {
  for (var i = 0; i < 50; i++) {
    if (session.activeOrganizationId == expected) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail(
    'activeOrganizationId settled on ${session.activeOrganizationId}, '
    'expected $expected',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeFirebaseFirestore firestore;
  late FakeAuthService auth;
  late UserProfileRepository repository;
  late MembershipRepository membershipRepository;
  late SessionController session;

  setUp(() {
    // Every SessionController now resolves SharedPreferences.getInstance()
    // internally (for activeOrganizationId persistence); the mock channel
    // handler must be installed before any construction, even for tests
    // that don't otherwise care about persistence.
    SharedPreferences.setMockInitialValues({});
    firestore = FakeFirebaseFirestore();
    auth = FakeAuthService();
    repository = UserProfileRepository(
      firestoreService: FirestoreService(firestore: firestore),
    );
    membershipRepository = MembershipRepository(
      firestoreService: FirestoreService(firestore: firestore),
    );
    session = SessionController(
      authService: auth,
      userProfileRepository: repository,
      membershipRepository: membershipRepository,
    );
  });

  tearDown(() async {
    session.dispose();
    await auth.dispose();
  });

  Future<void> seedProfile(String uid, AccountStatus status) async {
    await firestore.doc('users/$uid').set({
      'uid': uid,
      'name': 'Test User',
      'email': 'test@example.com',
      'phone': '+254700000000',
      'accountStatus': status.id,
    });
    // A pending account has no membership yet; every other status does —
    // under the multi-org membership model this lives on the memberships
    // subcollection, not a scalar organizationId field.
    if (status != AccountStatus.pending) {
      await firestore.doc('users/$uid/memberships/org-alpha').set({
        'organizationId': 'org-alpha',
        'role': 'siteManager',
        'status': 'active',
      });
    }
  }

  group('initial state', () {
    test('starts in loading until auth state resolves', () {
      expect(session.status, AuthStatus.loading);
      expect(session.isAuthenticated, isFalse);
      expect(session.isResolving, isTrue);
    });
  });

  group('registration', () {
    test(
      'creates a pending profile and lands the session on pending',
      () async {
        auth.signedInUid = 'new-uid';

        final future = session.register(
          name: 'New User',
          email: 'new@example.com',
          phone: '+254700000000',
          password: 'password123',
        );
        // Firebase would emit the new user; the fake does so explicitly.
        await future;
        auth.emitSignedIn('new-uid');
        await waitForStatus(session, AuthStatus.pending);

        final doc = await firestore.doc('users/new-uid').get();
        expect(doc.exists, isTrue);
        expect(doc.data()!['accountStatus'], 'pending');
        expect(doc.data()!.containsKey('workerType'), isFalse);
        expect(session.isAuthenticated, isFalse);
      },
    );

    test('never writes an organizationId or approval fields', () async {
      auth.signedInUid = 'new-uid';

      await session.register(
        name: 'New User',
        email: 'new@example.com',
        phone: '+254700000000',
        password: 'password123',
      );

      final data = (await firestore.doc('users/new-uid').get()).data()!;
      expect(data.containsKey('organizationId'), isFalse);
      expect(data.containsKey('approvedAt'), isFalse);
      expect(data.containsKey('approvedBy'), isFalse);
      expect(data.containsKey('role'), isFalse);
      expect(data.containsKey('active'), isFalse);
    });

    test(
      'a registered user is not authenticated for operational access',
      () async {
        auth.signedInUid = 'new-uid';

        await session.register(
          name: 'New User',
          email: 'new@example.com',
          phone: '+254700000000',
          password: 'password123',
        );
        auth.emitSignedIn('new-uid');
        await waitForStatus(session, AuthStatus.pending);

        expect(session.isAuthenticated, isFalse);
        expect(session.isDenied, isTrue);
        expect(session.activeOrganizationId, isNull);
        expect(session.accountStatus, AccountStatus.pending);
      },
    );

    test('surfaces an auth failure as an error state and rethrows', () async {
      auth.createUserError = const AuthException('That email is in use.');

      await expectLater(
        session.register(
          name: 'New User',
          email: 'taken@example.com',
          phone: '+254700000000',
          password: 'password123',
        ),
        throwsA(isA<AuthException>()),
      );

      expect(session.status, AuthStatus.error);
      expect(session.lastError?.message, 'That email is in use.');
      // No Auth account was created, so there is nothing to roll back.
      expect(auth.deleteCalled, isFalse);
    });
  });

  group('session reacts to account status changes', () {
    test(
      'approval moves a pending user into the app without re-login',
      () async {
        await seedProfile('uid-1', AccountStatus.pending);
        auth.emitSignedIn('uid-1');
        await waitForStatus(session, AuthStatus.pending);

        // An approver activates the account and creates its first membership.
        await firestore.doc('users/uid-1').update({
          'accountStatus': 'active',
          'approvedBy': 'approver-uid',
        });
        await firestore.doc('users/uid-1/memberships/org-alpha').set({
          'organizationId': 'org-alpha',
          'role': 'siteManager',
          'status': 'active',
        });
        await waitForStatus(session, AuthStatus.authenticated);
        await _waitForActiveOrganization(session, 'org-alpha');

        expect(session.isAuthenticated, isTrue);
        expect(session.activeOrganizationId, 'org-alpha');
      },
    );

    test('suspension revokes access on the next snapshot', () async {
      await seedProfile('uid-1', AccountStatus.active);
      auth.emitSignedIn('uid-1');
      await waitForStatus(session, AuthStatus.authenticated);

      await firestore.doc('users/uid-1').update({'accountStatus': 'suspended'});
      await waitForStatus(session, AuthStatus.suspended);

      expect(session.isAuthenticated, isFalse);
      expect(session.isDenied, isTrue);
    });

    test('rejection denies access', () async {
      await seedProfile('uid-1', AccountStatus.pending);
      auth.emitSignedIn('uid-1');
      await waitForStatus(session, AuthStatus.pending);

      await firestore.doc('users/uid-1').update({'accountStatus': 'rejected'});
      await waitForStatus(session, AuthStatus.rejected);

      expect(session.isAuthenticated, isFalse);
    });

    test(
      'a signed-in user with no profile document is profileMissing',
      () async {
        auth.emitSignedIn('ghost-uid');
        await waitForStatus(session, AuthStatus.profileMissing);

        expect(session.isAuthenticated, isFalse);
        expect(session.profile, isNull);
      },
    );

    test('a malformed profile denies access instead of degrading', () async {
      await firestore.doc('users/uid-bad').set({
        'uid': 'uid-bad',
        'name': 'Test',
        'email': 'test@example.com',
        'accountStatus': 'super-admin',
      });
      auth.emitSignedIn('uid-bad');
      await waitForStatus(session, AuthStatus.error);

      expect(session.isAuthenticated, isFalse);
      expect(session.isDenied, isTrue);
    });
  });

  group('bootstrap Admin', () {
    test('an active admin profile signs in immediately, no approval '
        'workflow involved', () async {
      // Simulates the operator script's bootstrap-admin outcome: role and
      // accountStatus are already active on first sign-in, unlike every
      // other account which starts pending.
      await firestore.doc('users/admin-uid').set({
        'uid': 'admin-uid',
        'name': 'Bootstrap Admin',
        'email': 'admin@example.com',
        'phone': '+254700000000',
        'accountStatus': 'active',
        'platformRole': 'admin',
        // Deliberately no organizationId: Admin is platform-level, not
        // scoped to one organization.
      });
      auth.emitSignedIn('admin-uid');
      await waitForStatus(session, AuthStatus.authenticated);

      expect(session.isAuthenticated, isTrue);
      expect(session.activeOrganizationId, isNull);
      expect(session.profile?.platformRole, isNotNull);
      expect(session.profile?.canReviewPendingAccounts, isTrue);
      expect(session.profile?.isPlatformAdministrator, isTrue);
    });

    test(
      'a bootstrap admin reaches operational access with no organization',
      () async {
        await firestore.doc('users/admin-uid').set({
          'uid': 'admin-uid',
          'name': 'Bootstrap Admin',
          'email': 'admin@example.com',
          'accountStatus': 'active',
          'platformRole': 'admin',
        });
        auth.emitSignedIn('admin-uid');
        await waitForStatus(session, AuthStatus.authenticated);

        expect(session.isDenied, isFalse);
        expect(session.isResolving, isFalse);
      },
    );
  });

  group('logout', () {
    test('clears the profile and returns to unauthenticated', () async {
      await seedProfile('uid-1', AccountStatus.active);
      auth.emitSignedIn('uid-1');
      await waitForStatus(session, AuthStatus.authenticated);

      await session.signOut();
      await waitForStatus(session, AuthStatus.unauthenticated);

      expect(auth.signOutCalled, isTrue);
      expect(session.profile, isNull);
      expect(session.activeOrganizationId, isNull);
      expect(session.isAuthenticated, isFalse);
    });

    test('signing out from a pending session also clears it', () async {
      await seedProfile('uid-1', AccountStatus.pending);
      auth.emitSignedIn('uid-1');
      await waitForStatus(session, AuthStatus.pending);

      await session.signOut();
      await waitForStatus(session, AuthStatus.unauthenticated);

      expect(session.accountStatus, isNull);
    });
  });

  group('auth state persistence', () {
    test(
      'a restored Firebase session loads the profile without a sign-in',
      () async {
        // Firebase restores the session at cold start by emitting on
        // authStateChanges without any signIn() call.
        await seedProfile('uid-1', AccountStatus.active);
        auth.emitSignedIn('uid-1');
        await waitForStatus(session, AuthStatus.authenticated);

        expect(auth.signInCalled, isFalse);
        expect(session.isAuthenticated, isTrue);
      },
    );
  });

  group('activeOrganizationId persistence', () {
    Future<void> seedTwoMemberships(String uid) async {
      await firestore.doc('users/$uid').set({
        'uid': uid,
        'name': 'Test User',
        'email': 'test@example.com',
        'phone': '+254700000000',
        'accountStatus': 'active',
      });
      await firestore.doc('users/$uid/memberships/org-alpha').set({
        'organizationId': 'org-alpha',
        'role': 'siteManager',
        'status': 'active',
      });
      await firestore.doc('users/$uid/memberships/org-beta').set({
        'organizationId': 'org-beta',
        'role': 'siteManager',
        'status': 'active',
      });
    }

    test(
      'a selection survives a simulated app restart (fresh SessionController '
      'reading the same SharedPreferences-backed store)',
      () async {
        SharedPreferences.setMockInitialValues({});
        await seedTwoMemberships('uid-multi');

        auth.emitSignedIn('uid-multi');
        await waitForStatus(session, AuthStatus.authenticated);
        // Two memberships and nothing selected yet: falls back to the first
        // by organization id.
        await _waitForActiveOrganization(session, 'org-alpha');

        session.setActiveOrganization('org-beta');
        await _waitForActiveOrganization(session, 'org-beta');

        // "Restart": dispose this session and build a brand-new one reading
        // the SAME (mocked) SharedPreferences-backed store, exactly like a
        // fresh app launch would.
        session.dispose();
        await auth.dispose();

        final restartedAuth = FakeAuthService();
        final restartedSession = SessionController(
          authService: restartedAuth,
          userProfileRepository: repository,
          membershipRepository: membershipRepository,
        );
        addTearDown(restartedSession.dispose);
        addTearDown(restartedAuth.dispose);

        restartedAuth.emitSignedIn('uid-multi');
        await waitForStatus(restartedSession, AuthStatus.authenticated);
        await _waitForActiveOrganization(restartedSession, 'org-beta');

        expect(restartedSession.activeOrganizationId, 'org-beta');
      },
    );

    test(
      'a selection for one uid does not leak into another uid\'s session',
      () async {
        SharedPreferences.setMockInitialValues({});
        await seedTwoMemberships('uid-a');
        await seedTwoMemberships('uid-b');

        auth.emitSignedIn('uid-a');
        await waitForStatus(session, AuthStatus.authenticated);
        await _waitForActiveOrganization(session, 'org-alpha');
        session.setActiveOrganization('org-beta');
        await _waitForActiveOrganization(session, 'org-beta');

        session.dispose();
        await auth.dispose();

        final auth2 = FakeAuthService();
        final session2 = SessionController(
          authService: auth2,
          userProfileRepository: repository,
          membershipRepository: membershipRepository,
        );
        addTearDown(session2.dispose);
        addTearDown(auth2.dispose);

        auth2.emitSignedIn('uid-b');
        await waitForStatus(session2, AuthStatus.authenticated);
        // uid-b never called setActiveOrganization, so it falls back to the
        // default (first by organization id), not uid-a's persisted choice.
        await _waitForActiveOrganization(session2, 'org-alpha');

        expect(session2.activeOrganizationId, 'org-alpha');
      },
    );
  });
}
