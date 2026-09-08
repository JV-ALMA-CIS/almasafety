import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/membership.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/organizations/data/organization_admin_service.dart';
import 'package:jva_safety/features/organizations/data/organization_repository.dart';
import 'package:jva_safety/features/organizations/domain/organization_record_status.dart';
import 'package:jva_safety/features/organizations/presentation/organizations_screen.dart';

/// A fake admin service, subclassing the real one rather than mocking — the
/// repo's established pattern (see organization_users_screen_test.dart).
class _FakeAdminService extends OrganizationAdminService {
  _FakeAdminService({this.createError, this.updateError});

  AppException? createError;
  AppException? updateError;

  final List<({String name, String code, OrganizationRecordStatus status})>
      createCalls = [];
  final List<({String id, String? name, String? code})> updateCalls = [];

  @override
  Future<String> createOrganization({
    required String name,
    required String code,
    OrganizationRecordStatus status = OrganizationRecordStatus.active,
  }) async {
    final error = createError;
    if (error != null) throw error;
    createCalls.add((name: name, code: code, status: status));
    return 'new-org-id';
  }

  @override
  Future<void> updateOrganization(
    String id, {
    String? name,
    String? code,
    OrganizationRecordStatus? status,
  }) async {
    final error = updateError;
    if (error != null) throw error;
    updateCalls.add((id: id, name: name, code: code));
  }
}

class _FakeSession extends SessionController {
  _FakeSession({
    required AppRole? role,
    String? organizationId,
    bool transientSiteManagerMarker = false,
    List<Membership>? memberships,
  }) : _profile = UserProfile(
         uid: 'sysadmin-uid',
         name: 'Sysadmin',
         email: 'sysadmin@example.com',
         accountStatus: AccountStatus.active,
         // A brand-new Site Manager approved with no organization yet (the
         // documented "create your own org afterward" path) has this
         // transient marker instead of a membership — see
         // `account_approval.ts`'s `approveAccount`.
         platformRole: role == AppRole.admin
             ? role
             : (transientSiteManagerMarker ? AppRole.siteManager : null),
       ),
       _membership = role == null || role == AppRole.admin || organizationId == null
           ? null
           : Membership(
               organizationId: organizationId,
               role: role,
               status: MembershipStatus.active,
             ),
       _memberships = memberships;

  final UserProfile _profile;
  final Membership? _membership;

  /// Overrides the single-membership derivation below when a test needs a
  /// Site Manager holding MULTIPLE memberships at once — see the
  /// "sees every organization they manage" regression test.
  final List<Membership>? _memberships;

  @override
  UserProfile? get profile => _profile;

  @override
  List<Membership> get memberships =>
      _memberships ?? (_membership == null ? const [] : [_membership]);

  @override
  String? get activeOrganizationId =>
      _membership?.organizationId ?? memberships.firstOrNull?.organizationId;

  @override
  Membership? get activeMembership {
    final id = activeOrganizationId;
    if (id == null) return null;
    for (final membership in memberships) {
      if (membership.organizationId == id) return membership;
    }
    return null;
  }
}

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<void> seedOrg(String id, {String status = 'active'}) async {
    await firestore.doc('organizations/$id').set({
      'name': 'Org $id',
      'code': 'CODE-$id',
      'status': status,
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  Widget wrap(
    _FakeAdminService adminService, {
    AppRole? reviewerRole = AppRole.admin,
    String? organizationId,
    bool transientSiteManagerMarker = false,
    List<Membership>? memberships,
  }) {
    return ChangeNotifierProvider<SessionController>(
      create: (_) => _FakeSession(
        role: reviewerRole,
        organizationId: organizationId,
        transientSiteManagerMarker: transientSiteManagerMarker,
        memberships: memberships,
      ),
      child: MaterialApp(
        home: Scaffold(
          body: OrganizationsScreen(
            repository: OrganizationRepository(
              firestoreService: FirestoreService(firestore: firestore),
            ),
            adminService: adminService,
          ),
        ),
      ),
    );
  }

  group('OrganizationsScreen (Admin)', () {
    testWidgets('lists every organization', (tester) async {
      await seedOrg('alpha');
      await seedOrg('beta');

      await tester.pumpWidget(wrap(_FakeAdminService()));
      await tester.pumpAndSettle();

      expect(find.text('Organizations'), findsOneWidget);
      expect(find.text('Org alpha'), findsOneWidget);
      expect(find.text('Org beta'), findsOneWidget);
    });

    testWidgets('shows an empty state when there are none', (tester) async {
      await tester.pumpWidget(wrap(_FakeAdminService()));
      await tester.pumpAndSettle();

      expect(find.text('No organizations yet.'), findsOneWidget);
    });

    testWidgets('creating calls the admin service with the form values', (
      tester,
    ) async {
      final service = _FakeAdminService();

      await tester.pumpWidget(wrap(service));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Add organization'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'),
        'JV Alma CIS',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Code'),
        'JV-ALMA-CIS',
      );
      await tester.tap(find.widgetWithText(ElevatedButton, 'Create'));
      await tester.pumpAndSettle();

      expect(service.createCalls, hasLength(1));
      expect(service.createCalls.single.name, 'JV Alma CIS');
      expect(service.createCalls.single.code, 'JV-ALMA-CIS');
      expect(service.createCalls.single.status, OrganizationRecordStatus.active);
    });

    testWidgets('cannot submit the create form without a name or code', (
      tester,
    ) async {
      final service = _FakeAdminService();

      await tester.pumpWidget(wrap(service));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Add organization'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Create'));
      await tester.pumpAndSettle();

      expect(service.createCalls, isEmpty);
      expect(find.text('A name is required.'), findsOneWidget);
      expect(find.text('A code is required.'), findsOneWidget);
    });

    testWidgets('editing pre-fills the form and calls updateOrganization', (
      tester,
    ) async {
      await seedOrg('alpha');
      final service = _FakeAdminService();

      await tester.pumpWidget(wrap(service));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, 'Edit'));
      await tester.pumpAndSettle();

      expect(find.text('Org alpha'), findsWidgets);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'),
        'Renamed Org',
      );
      await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
      await tester.pumpAndSettle();

      expect(service.updateCalls, hasLength(1));
      expect(service.updateCalls.single.id, 'alpha');
      expect(service.updateCalls.single.name, 'Renamed Org');
    });

    testWidgets('surfaces a refused create', (tester) async {
      final service = _FakeAdminService(
        createError: const PermissionDeniedException(
          'You do not have permission to do that.',
        ),
      );

      await tester.pumpWidget(wrap(service));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Add organization'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'),
        'JV Alma CIS',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Code'),
        'JV-ALMA-CIS',
      );
      await tester.tap(find.widgetWithText(ElevatedButton, 'Create'));
      await tester.pumpAndSettle();

      expect(
        find.text('You do not have permission to do that.'),
        findsOneWidget,
      );
    });

    testWidgets('surfaces a refused edit', (tester) async {
      await seedOrg('alpha');
      final service = _FakeAdminService(
        updateError: const PermissionDeniedException(
          'You do not have permission to do that.',
        ),
      );

      await tester.pumpWidget(wrap(service));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, 'Edit'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
      await tester.pumpAndSettle();

      expect(
        find.text('You do not have permission to do that.'),
        findsOneWidget,
      );
    });
  });

  group('OrganizationsScreen (Site Manager)', () {
    testWidgets('sees only their own organization, not others', (
      tester,
    ) async {
      await seedOrg('alpha');
      await seedOrg('beta');

      await tester.pumpWidget(
        wrap(
          _FakeAdminService(),
          reviewerRole: AppRole.siteManager,
          organizationId: 'alpha',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Organizations'), findsOneWidget);
      expect(find.text('Org alpha'), findsOneWidget);
      expect(find.text('Org beta'), findsNothing);
    });

    testWidgets(
      'a Site Manager holding memberships in TWO organizations sees BOTH '
      '— regression test: OrganizationsScreen used to call an unscoped '
      'collectionGroup list (organizations.watchAll()), which '
      'firestore.rules denies outright for any non-Admin (a collection '
      'LIST cannot be proven to satisfy belongsToOrganization for every '
      'possible document), producing "Couldn\'t load organizations" for '
      'every Site Manager regardless of how many orgs they belong to. '
      'Fixed by resolving the list from the caller\'s own memberships '
      '(self-scoped, always readable) instead',
      (tester) async {
        await seedOrg('alpha');
        await seedOrg('beta');
        await seedOrg('gamma');

        await tester.pumpWidget(
          wrap(
            _FakeAdminService(),
            reviewerRole: AppRole.siteManager,
            memberships: const [
              Membership(
                organizationId: 'alpha',
                role: AppRole.siteManager,
                status: MembershipStatus.active,
              ),
              Membership(
                organizationId: 'beta',
                role: AppRole.siteManager,
                status: MembershipStatus.active,
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Org alpha'), findsOneWidget);
        expect(find.text('Org beta'), findsOneWidget);
        // Not a member of gamma — must not leak in.
        expect(find.text('Org gamma'), findsNothing);
      },
    );

    testWidgets(
      'can see the Add organization action — PROJECT_CONTEXT.md §12: a '
      'Site Manager must be able to create an organization because they '
      'are the field operational manager, including a second/third one',
      (tester) async {
        await seedOrg('alpha');

        await tester.pumpWidget(
          wrap(
            _FakeAdminService(),
            reviewerRole: AppRole.siteManager,
            organizationId: 'alpha',
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byTooltip('Add organization'), findsOneWidget);
      },
    );

    testWidgets(
      'a brand-new Site Manager with no membership yet (approved by Admin '
      'with no organization) can still reach and see the Add organization '
      'action — the one path that gives them their first membership',
      (tester) async {
        await tester.pumpWidget(
          wrap(
            _FakeAdminService(),
            reviewerRole: null,
            transientSiteManagerMarker: true,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('You do not have permission to manage organizations.'),
            findsNothing);
        expect(find.byTooltip('Add organization'), findsOneWidget);
      },
    );

    testWidgets('cannot see the Edit action on their own organization', (
      tester,
    ) async {
      await seedOrg('alpha');

      await tester.pumpWidget(
        wrap(
          _FakeAdminService(),
          reviewerRole: AppRole.siteManager,
          organizationId: 'alpha',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.widgetWithText(OutlinedButton, 'Edit'), findsNothing);
    });

    testWidgets('can still navigate to Projects for their own organization', (
      tester,
    ) async {
      await seedOrg('alpha');

      await tester.pumpWidget(
        wrap(
          _FakeAdminService(),
          reviewerRole: AppRole.siteManager,
          organizationId: 'alpha',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.widgetWithText(ElevatedButton, 'Projects'), findsOneWidget);
    });

    testWidgets(
      'does NOT see the Safety Meeting Points action — regression test: '
      'this button used to be shown to a Site Manager, but '
      'createSafetyMeetingPoint/etc. are admin-ONLY server-side '
      '(requireAdmin in safety_meeting_point_callable.ts,  '
      'PROJECT_CONTEXT.md §4), so tapping it only bounced back to the '
      'dashboard via the router\'s own admin-only gate on that route',
      (tester) async {
        await seedOrg('alpha');

        await tester.pumpWidget(
          wrap(
            _FakeAdminService(),
            reviewerRole: AppRole.siteManager,
            organizationId: 'alpha',
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.widgetWithText(OutlinedButton, 'Safety Meeting Points'),
          findsNothing,
        );
      },
    );

    testWidgets('sees the Daily Safety Meetings action for their own '
        'organization', (tester) async {
      await seedOrg('alpha');

      await tester.pumpWidget(
        wrap(
          _FakeAdminService(),
          reviewerRole: AppRole.siteManager,
          organizationId: 'alpha',
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(OutlinedButton, 'Daily Safety Meetings'),
        findsOneWidget,
      );
    });
  });

  group('OrganizationsScreen (Admin sees the same admin '
      'actions)', () {
    testWidgets('the Safety Meeting Points and Daily Safety Meetings '
        'actions are present alongside Edit/Projects', (tester) async {
      await seedOrg('alpha');

      await tester.pumpWidget(wrap(_FakeAdminService()));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(OutlinedButton, 'Edit'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Projects'), findsOneWidget);
      expect(
        find.widgetWithText(OutlinedButton, 'Safety Meeting Points'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(OutlinedButton, 'Daily Safety Meetings'),
        findsOneWidget,
      );
    });
  });

  group('OrganizationsScreen (non-administrator)', () {
    testWidgets('renders no content for a user with no role', (tester) async {
      await tester.pumpWidget(wrap(_FakeAdminService(), reviewerRole: null));
      await tester.pumpAndSettle();

      expect(
        find.text('You do not have permission to manage organizations.'),
        findsOneWidget,
      );
    });
  });
}
