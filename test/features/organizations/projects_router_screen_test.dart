import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/membership.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/organizations/data/organization_admin_service.dart';
import 'package:jva_safety/features/organizations/data/organization_repository.dart';
import 'package:jva_safety/features/organizations/data/project_repository.dart';
import 'package:jva_safety/features/organizations/domain/organization_record_status.dart';
import 'package:jva_safety/features/organizations/presentation/projects_router_screen.dart';

/// A fake org-admin service, subclassing the real one rather than mocking —
/// the repo's established pattern.
class _FakeAdminService extends OrganizationAdminService {
  final List<({String name, String code})> createCalls = [];

  @override
  Future<String> createOrganization({
    required String name,
    required String code,
    OrganizationRecordStatus status = OrganizationRecordStatus.active,
  }) async {
    createCalls.add((name: name, code: code));
    return 'jv-alma-cis';
  }
}

class _FakeSession extends SessionController {
  _FakeSession({required AppRole? role, String? organizationId})
    : _profile = UserProfile(
        uid: 'user-1',
        name: 'Test User',
        email: 'user@example.com',
        accountStatus: AccountStatus.active,
        platformRole:
            role == AppRole.admin ||
                (role == AppRole.siteManager && organizationId == null)
            ? role
            : null,
      ),
      _membership =
          role == null || role == AppRole.admin || organizationId == null
          ? null
          : Membership(
              organizationId: organizationId,
              role: role,
              status: MembershipStatus.active,
            );

  final UserProfile _profile;
  Membership? _membership;

  /// Simulates SessionController's real membership subscription picking up
  /// a newly-created membership and notifying listeners, so a test can
  /// exercise the bootstrap flow end-to-end (create -> rebuild -> resolved
  /// org) without a real Firestore stream.
  void simulateMembershipCreated(String organizationId, AppRole role) {
    _membership = Membership(
      organizationId: organizationId,
      role: role,
      status: MembershipStatus.active,
    );
    notifyListeners();
  }

  @override
  UserProfile? get profile => _profile;

  @override
  String? get activeOrganizationId => _membership?.organizationId;

  @override
  Membership? get activeMembership => _membership;

  @override
  Membership? membershipFor(String organizationId) =>
      _membership?.organizationId == organizationId ? _membership : null;
}

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<void> seedOrganization(
    String id, {
    String name = 'JV Alma CIS',
  }) async {
    await firestore.doc('organizations/$id').set({
      'name': name,
      'code': 'CODE-$id',
      'status': 'active',
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  /// Set by [wrap] so a test can reach into the fake session it created —
  /// e.g. to call [_FakeSession.simulateMembershipCreated].
  _FakeSession? lastSession;

  Widget wrap({
    required AppRole? role,
    String? organizationId,
    OrganizationAdminService? adminService,
  }) {
    final firestoreService = FirestoreService(firestore: firestore);
    return ChangeNotifierProvider<SessionController>(
      create: (_) {
        final session = _FakeSession(
          role: role,
          organizationId: organizationId,
        );
        lastSession = session;
        return session;
      },
      child: MaterialApp(
        home: Scaffold(
          body: ProjectsRouterScreen(
            organizationRepository: OrganizationRepository(
              firestoreService: firestoreService,
            ),
            firestoreService: firestoreService,
            // Scoped to 'jv-alma-cis' unconditionally: once the bootstrap
            // flow resolves a membership (see
            // _FakeSession.simulateMembershipCreated), ProjectsScreen is
            // built with whatever organization id that membership names —
            // every bootstrap test in this file uses 'jv-alma-cis'. A
            // caller that already has an organizationId at wrap() time
            // still gets the same repository, since it's organization-id
            // scoped identically either way.
            projectRepository: ProjectRepository(
              firestoreService: firestoreService,
              organizationId: organizationId ?? 'jv-alma-cis',
            ),
            adminService: adminService,
          ),
        ),
      ),
    );
  }

  testWidgets(
    'a Site Manager reaches ProjectsScreen for JV ALMA CIS directly — '
    'there is no Organizations list to navigate through first',
    (tester) async {
      await seedOrganization('org-alpha', name: 'JV Alma CIS');

      await tester.pumpWidget(
        wrap(role: AppRole.siteManager, organizationId: 'org-alpha'),
      );
      await tester.pumpAndSettle();

      expect(find.text('Projects'), findsOneWidget);
      // The org name resolved from the caller's active organization.
      expect(find.textContaining('JV Alma CIS'), findsWidgets);
    },
  );

  testWidgets(
    'a Site Manager with no organization yet sees the one-time "Set up '
    'JV ALMA CIS" bootstrap prompt instead of a dead end',
    (tester) async {
      await tester.pumpWidget(
        wrap(role: AppRole.siteManager, organizationId: null),
      );
      await tester.pumpAndSettle();

      expect(find.text('JV ALMA CIS has not been set up yet.'), findsOneWidget);
      expect(
        find.widgetWithText(ElevatedButton, 'Set up JV ALMA CIS'),
        findsOneWidget,
      );
    },
  );

  testWidgets('tapping "Set up JV ALMA CIS" calls createOrganization with the '
      'fixed company name/code — no form, nothing for the Site Manager to '
      'type, since there is only ever one company', (tester) async {
    final adminService = _FakeAdminService();

    await tester.pumpWidget(
      wrap(
        role: AppRole.siteManager,
        organizationId: null,
        adminService: adminService,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ElevatedButton, 'Set up JV ALMA CIS'));
    await tester.pumpAndSettle();

    expect(adminService.createCalls, [
      (name: 'JV ALMA CIS', code: 'JV-ALMA-CIS'),
    ]);
  });

  testWidgets('once the membership subscription picks up the new organization, '
      'this screen resolves straight into ProjectsScreen without further '
      'user action', (tester) async {
    await seedOrganization('jv-alma-cis', name: 'JV ALMA CIS');
    final adminService = _FakeAdminService();

    await tester.pumpWidget(
      wrap(
        role: AppRole.siteManager,
        organizationId: null,
        adminService: adminService,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('JV ALMA CIS has not been set up yet.'), findsOneWidget);

    lastSession!.simulateMembershipCreated('jv-alma-cis', AppRole.siteManager);
    await tester.pumpAndSettle();

    expect(find.text('JV ALMA CIS has not been set up yet.'), findsNothing);
    expect(find.text('Projects'), findsOneWidget);
  });

  testWidgets('a Worker reaching this route sees ProjectsScreen\'s own '
      'permission message, not a crash', (tester) async {
    await seedOrganization('org-alpha');

    await tester.pumpWidget(
      wrap(role: AppRole.worker, organizationId: 'org-alpha'),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('You do not have permission to manage projects.'),
      findsOneWidget,
    );
  });
}
