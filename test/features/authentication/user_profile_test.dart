import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/authentication/domain/worker_type.dart';

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  /// Seeds a profile at the top-level path the app actually reads:
  /// users/{uid}
  Future<DocumentSnapshot<Map<String, dynamic>>> seedUser(
    String uid,
    Map<String, dynamic> data,
  ) async {
    final ref = firestore.doc('users/$uid');
    await ref.set(data);
    return ref.get();
  }

  Map<String, dynamic> validData({
    String accountStatus = 'active',
    String? organizationId = 'org-alpha',
  }) {
    return {
      'uid': 'seeded',
      // Null-aware element: a null organizationId omits the key entirely,
      // which is the shape a freshly registered (pending) profile has.
      'organizationId': ?organizationId,
      'name': 'Test User',
      'email': 'test@example.com',
      'accountStatus': accountStatus,
      'createdAt': Timestamp.fromDate(DateTime(2026, 1, 1)),
      'updatedAt': Timestamp.fromDate(DateTime(2026, 1, 2)),
    };
  }

  group('UserProfile.fromFirestore (valid profile)', () {
    test('parses status, org and audit timestamps', () async {
      final doc = await seedUser('uid-a', {
        ...validData(),
        'phone': '+254700000000',
        'approvedAt': Timestamp.fromDate(DateTime(2026, 1, 3)),
        'approvedBy': 'approver-uid',
      });

      final profile = UserProfile.fromFirestore(doc);

      expect(profile.uid, 'uid-a');
      expect(profile.organizationId, 'org-alpha');
      expect(profile.accountStatus, AccountStatus.active);
      expect(profile.phone, '+254700000000');
      expect(profile.createdAt, DateTime(2026, 1, 1));
      expect(profile.updatedAt, DateTime(2026, 1, 2));
      expect(profile.approvedAt, DateTime(2026, 1, 3));
      expect(profile.approvedBy, 'approver-uid');
    });

    test('round-trips every account status without loss', () async {
      for (final status in AccountStatus.values) {
        final doc = await seedUser(
          'uid-${status.id}',
          validData(accountStatus: status.id),
        );
        expect(UserProfile.fromFirestore(doc).accountStatus, status);
      }
    });

    test('accountStatus alone still gates hasOperationalAccess', () {
      // platformRole is orthogonal to accountStatus: a role never
      // substitutes for approval, only accountStatus does.
      final profile = UserProfile(
        uid: 'uid-a',
        name: 'Test',
        email: 'test@example.com',
        accountStatus: AccountStatus.active,
      );

      expect(profile.hasOperationalAccess, isTrue);
      expect(profile.platformRole, isNull);
    });

    test('parses a valid platformRole', () async {
      final doc = await seedUser('uid-role', {
        ...validData(),
        'platformRole': 'siteManager',
      });

      expect(
        UserProfile.fromFirestore(doc).platformRole,
        AppRole.siteManager,
      );
    });

    test('parses a valid workerType', () async {
      final doc = await seedUser('uid-wt-valid', {
        ...validData(),
        'workerType': 'contractor',
      });

      expect(
        UserProfile.fromFirestore(doc).workerType,
        WorkerType.contractor,
      );
    });
  });

  group('UserProfile.fromFirestore (pending users have no organization)', () {
    test('a pending profile with no organizationId parses cleanly', () async {
      final doc = await seedUser(
        'uid-pending',
        validData(accountStatus: 'pending', organizationId: null),
      );

      final profile = UserProfile.fromFirestore(doc);

      expect(profile.accountStatus, AccountStatus.pending);
      expect(profile.organizationId, isNull);
      expect(profile.hasOperationalAccess, isFalse);
    });

    test('an empty organizationId is read as unassigned, not as ""', () async {
      final doc = await seedUser(
        'uid-empty-org',
        validData(accountStatus: 'pending', organizationId: ''),
      );

      expect(UserProfile.fromFirestore(doc).organizationId, isNull);
    });

    test('approval fields are null before approval', () async {
      final doc = await seedUser(
        'uid-pending-2',
        validData(accountStatus: 'pending', organizationId: null),
      );

      final profile = UserProfile.fromFirestore(doc);

      expect(profile.approvedAt, isNull);
      expect(profile.approvedBy, isNull);
    });
  });

  group(
      'UserProfile.platformRole (assigned by a reviewer, never '
      'self-granted)', () {
    test('defaults to null when the field is absent', () async {
      // Every profile written before this field existed, and every pending
      // profile awaiting review, must parse with no role rather than
      // throwing — and the safe default for an authorization field is "no
      // authority".
      final doc = await seedUser('uid-legacy', validData());

      expect(UserProfile.fromFirestore(doc).platformRole, isNull);
      expect(UserProfile.fromFirestore(doc).canReviewPendingAccounts, isFalse);
    });

    test('round-trips every role', () async {
      for (final role in AppRole.values) {
        final doc = await seedUser('uid-role-${role.id}', {
          ...validData(),
          'platformRole': role.id,
        });
        expect(UserProfile.fromFirestore(doc).platformRole, role);
      }
    });

    test('an unrecognised role reads as no role, not a thrown error',
        () async {
      // Fails closed like isOrgApprover did: a malformed authorization value
      // must deny the capability, not deny the whole profile the way a
      // malformed accountStatus does.
      final doc = await seedUser('uid-bad-role', {
        ...validData(),
        'platformRole': 'platformOwner',
      });

      final profile = UserProfile.fromFirestore(doc);

      expect(profile.platformRole, isNull);
      expect(profile.accountStatus, AccountStatus.active);
    });

    test('is not in registrationPayload — registration cannot grant it', () {
      final payload = UserProfile.registrationPayload(
        uid: 'uid-a',
        name: 'New User',
        email: 'new@example.com',
        phone: '+254700000000',
      );

      expect(payload.containsKey('platformRole'), isFalse);
    });

    test('is not in selfEditablePayload — nobody can self-escalate', () {
      final payload = UserProfile.selfEditablePayload(name: 'New Name');

      expect(payload.containsKey('platformRole'), isFalse);
    });

    test('survives copyWith, which cannot change it', () {
      const profile = UserProfile(
        uid: 'uid-a',
        name: 'Reviewer',
        email: 'reviewer@example.com',
        accountStatus: AccountStatus.active,
        platformRole: AppRole.siteManager,
      );

      // copyWith takes only name and phone; there is no parameter by which
      // the role could be changed either way.
      expect(
        profile.copyWith(name: 'Renamed').platformRole,
        AppRole.siteManager,
      );
    });

    test('admin, siteManager and foreman can review pending accounts; '
        'worker cannot', () {
      final expected = {
        AppRole.admin: true,
        AppRole.siteManager: true,
        AppRole.foreman: true,
        AppRole.worker: false,
      };

      for (final entry in expected.entries) {
        expect(
          entry.key.canReviewPendingAccounts,
          entry.value,
          reason: '${entry.key} canReviewPendingAccounts should be '
              '${entry.value}',
        );
      }
    });

    test(
        'UserProfile.isPlatformAdministrator mirrors '
        'platformRole.isPlatformLevel', () {
      const admin = UserProfile(
        uid: 'uid-admin',
        name: 'Admin',
        email: 'admin@example.com',
        accountStatus: AccountStatus.active,
        platformRole: AppRole.admin,
      );
      const siteManager = UserProfile(
        uid: 'uid-site-manager',
        name: 'Site Manager',
        email: 'site-manager@example.com',
        accountStatus: AccountStatus.active,
        organizationId: 'org-alpha',
        platformRole: AppRole.siteManager,
      );
      const noRole = UserProfile(
        uid: 'uid-none',
        name: 'Nobody',
        email: 'nobody@example.com',
        accountStatus: AccountStatus.pending,
      );

      expect(admin.isPlatformAdministrator, isTrue);
      expect(siteManager.isPlatformAdministrator, isFalse);
      expect(noRole.isPlatformAdministrator, isFalse);
    });
  });

  group('UserProfile.siteIds', () {
    test('defaults to empty when the field is absent', () async {
      final doc = await seedUser('uid-no-sites', validData());

      expect(UserProfile.fromFirestore(doc).siteIds, isEmpty);
    });

    test('parses a list of site ids', () async {
      final doc = await seedUser('uid-sites', {
        ...validData(),
        'siteIds': ['site-a', 'site-b'],
      });

      expect(
        UserProfile.fromFirestore(doc).siteIds,
        ['site-a', 'site-b'],
      );
    });

    test('a non-list value is read as no sites, not a thrown error',
        () async {
      final doc = await seedUser('uid-bad-sites', {
        ...validData(),
        'siteIds': 'not-a-list',
      });

      expect(UserProfile.fromFirestore(doc).siteIds, isEmpty);
    });

    test('is not in registrationPayload — registration cannot grant it', () {
      final payload = UserProfile.registrationPayload(
        uid: 'uid-a',
        name: 'New User',
        email: 'new@example.com',
        phone: '+254700000000',
      );

      expect(payload.containsKey('siteIds'), isFalse);
    });

    test('is not in selfEditablePayload — nobody can self-grant site access',
        () {
      final payload = UserProfile.selfEditablePayload(name: 'New Name');

      expect(payload.containsKey('siteIds'), isFalse);
    });

    test('survives copyWith, which cannot change it', () {
      const profile = UserProfile(
        uid: 'uid-a',
        name: 'Worker',
        email: 'worker@example.com',
        accountStatus: AccountStatus.active,
        siteIds: ['site-a'],
      );

      expect(profile.copyWith(name: 'Renamed').siteIds, ['site-a']);
    });
  });

  group('UserProfile.workerType', () {
    test('is not in registrationPayload — registration cannot set it', () {
      final payload = UserProfile.registrationPayload(
        uid: 'uid-a',
        name: 'New User',
        email: 'new@example.com',
        phone: '+254700000000',
      );

      expect(payload.containsKey('workerType'), isFalse);
    });

    test('is not in selfEditablePayload — a user cannot set their own', () {
      final payload = UserProfile.selfEditablePayload(name: 'New Name');

      expect(payload.containsKey('workerType'), isFalse);
    });
  });

  group('UserProfile.hasOperationalAccess', () {
    test('only active grants access', () async {
      for (final status in AccountStatus.values) {
        final doc = await seedUser(
          'uid-access-${status.id}',
          validData(accountStatus: status.id),
        );
        expect(
          UserProfile.fromFirestore(doc).hasOperationalAccess,
          status == AccountStatus.active,
          reason: '$status access should be ${status == AccountStatus.active}',
        );
      }
    });
  });

  group('UserProfile.fromFirestore (malformed profiles fail safe)', () {
    test('unknown accountStatus throws rather than defaulting', () async {
      final doc = await seedUser(
        'uid-c',
        validData(accountStatus: 'not-a-real-status'),
      );

      expect(
        () => UserProfile.fromFirestore(doc),
        throwsA(isA<DataException>()),
      );
    });

    test('an "active"-looking status value does not become active', () async {
      for (final bogus in ['Active', 'ACTIVE', 'approved', 'true']) {
        final doc = await seedUser(
          'uid-$bogus',
          validData(accountStatus: bogus),
        );
        expect(
          () => UserProfile.fromFirestore(doc),
          throwsA(isA<DataException>()),
          reason: '"$bogus" must not resolve to a status',
        );
      }
    });

    test('missing accountStatus throws rather than assuming active', () async {
      final data = validData()..remove('accountStatus');
      final doc = await seedUser('uid-e', data);

      expect(
        () => UserProfile.fromFirestore(doc),
        throwsA(isA<DataException>()),
      );
    });

    test('an unrecognised workerType reads as null, not a thrown error',
        () async {
      final doc = await seedUser('uid-bad-wt', {
        ...validData(),
        'workerType': 'astronaut',
      });

      final profile = UserProfile.fromFirestore(doc);

      expect(profile.workerType, isNull);
      expect(profile.accountStatus, AccountStatus.active);
    });
  });

  group('UserProfile.registrationPayload (grants nothing)', () {
    test('always sets accountStatus to pending', () {
      final payload = UserProfile.registrationPayload(
        uid: 'uid-a',
        name: 'New User',
        email: 'new@example.com',
        phone: '+254700000000',
      );

      expect(payload['accountStatus'], AccountStatus.pending.id);
    });

    test(
        'never carries organizationId, approval fields, platformRole or '
        'active', () {
      final payload = UserProfile.registrationPayload(
        uid: 'uid-a',
        name: 'New User',
        email: 'new@example.com',
        phone: '+254700000000',
      );

      for (final forbidden in [
        'organizationId',
        'approvedAt',
        'approvedBy',
        'platformRole',
        'workerType',
        'trade',
        'active',
        'siteIds',
        'activityIds',
        'supervisorUid',
      ]) {
        expect(
          payload.containsKey(forbidden),
          isFalse,
          reason: 'registration must never include $forbidden',
        );
      }
    });

    test('contains exactly the fields firestore.rules allows at create', () {
      final payload = UserProfile.registrationPayload(
        uid: 'uid-a',
        name: 'New User',
        email: 'new@example.com',
        phone: '+254700000000',
      );

      expect(
        payload.keys.toSet(),
        {
          'uid',
          'name',
          'email',
          'phone',
          'accountStatus',
          'createdAt',
          'updatedAt',
        },
      );
    });

    test('timestamps are server-side, not client clock values', () {
      final payload = UserProfile.registrationPayload(
        uid: 'uid-a',
        name: 'New User',
        email: 'new@example.com',
        phone: '+254700000000',
      );

      expect(payload['createdAt'], isA<FieldValue>());
      expect(payload['updatedAt'], isA<FieldValue>());
      expect(payload['createdAt'], isNot(isA<Timestamp>()));
    });
  });

  group('UserProfile.selfEditablePayload (client cannot self-escalate)', () {
    test('contains only name, phone and a server updatedAt', () {
      final payload = UserProfile.selfEditablePayload(
        name: 'New Name',
        phone: '+254711111111',
      );

      expect(payload.keys.toSet(), {'name', 'phone', 'updatedAt'});
    });

    test('never carries accountStatus, organizationId or approval fields', () {
      final payload = UserProfile.selfEditablePayload(name: 'New Name');

      for (final forbidden in [
        'accountStatus',
        'organizationId',
        'approvedAt',
        'approvedBy',
        'uid',
        'email',
        'createdAt',
        'platformRole',
        'workerType',
        'trade',
        'siteIds',
        'supervisorUid',
        'active',
      ]) {
        expect(
          payload.containsKey(forbidden),
          isFalse,
          reason: 'a self-service write must never include $forbidden',
        );
      }
    });

    test('updatedAt is a server timestamp, not a client clock value', () {
      final payload = UserProfile.selfEditablePayload(name: 'New Name');

      expect(payload['updatedAt'], isA<FieldValue>());
      expect(payload['updatedAt'], isNot(isA<DateTime>()));
      expect(payload['updatedAt'], isNot(isA<Timestamp>()));
    });
  });

  group('AccountStatus parsing', () {
    test('AccountStatus.tryFromId returns null for unknown values', () {
      expect(AccountStatus.tryFromId('nonsense'), isNull);
      expect(AccountStatus.tryFromId(null), isNull);
      expect(AccountStatus.tryFromId('active'), AccountStatus.active);
    });

    test('only AccountStatus.active reports grantsAccess', () {
      for (final status in AccountStatus.values) {
        expect(status.grantsAccess, status == AccountStatus.active);
      }
    });
  });
}
