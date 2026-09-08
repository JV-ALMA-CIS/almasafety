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
import 'package:jva_safety/features/organizations/data/project_repository.dart';
import 'package:jva_safety/features/organizations/domain/organization.dart';
import 'package:jva_safety/features/organizations/domain/organization_record_status.dart';
import 'package:jva_safety/features/organizations/presentation/projects_screen.dart';

class _FakeAdminService extends OrganizationAdminService {
  _FakeAdminService({this.createError});

  AppException? createError;

  final List<({String organizationId, String name, String code})>
      createCalls = [];

  @override
  Future<String> createProject({
    required String organizationId,
    required String name,
    required String code,
    String? description,
    OrganizationRecordStatus status = OrganizationRecordStatus.active,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final error = createError;
    if (error != null) throw error;
    createCalls.add(
      (organizationId: organizationId, name: name, code: code),
    );
    return 'new-project-id';
  }
}

class _FakeSession extends SessionController {
  _FakeSession({required AppRole? role, String? organizationId})
    : _profile = UserProfile(
        uid: 'sysadmin-uid',
        name: 'Sysadmin',
        email: 'sysadmin@example.com',
        accountStatus: AccountStatus.active,
        platformRole: role == AppRole.admin ? role : null,
      ),
      _membership = role == null || role == AppRole.admin || organizationId == null
          ? null
          : Membership(
              organizationId: organizationId,
              role: role,
              status: MembershipStatus.active,
            );

  final UserProfile _profile;
  final Membership? _membership;

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

  const organization = Organization(
    id: 'org-alpha',
    name: 'JV Alma CIS',
    code: 'JV-ALMA-CIS',
    status: OrganizationRecordStatus.active,
  );

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<void> seedProject(String orgId, String id) async {
    await firestore.doc('organizations/$orgId/projects/$id').set({
      'organizationId': orgId,
      'name': 'Project $id',
      'code': 'CODE-$id',
      'status': 'active',
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  Widget wrap(
    _FakeAdminService adminService, {
    AppRole? reviewerRole = AppRole.admin,
    String? organizationId,
  }) {
    return ChangeNotifierProvider<SessionController>(
      create: (_) =>
          _FakeSession(role: reviewerRole, organizationId: organizationId),
      child: MaterialApp(
        home: Scaffold(
          body: ProjectsScreen(
            organization: organization,
            repository: ProjectRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: organization.id,
            ),
            adminService: adminService,
          ),
        ),
      ),
    );
  }

  group('ProjectsScreen (Admin)', () {
    testWidgets('lists only this organization\'s projects', (tester) async {
      await seedProject('org-alpha', 'p1');
      await seedProject('org-beta', 'p2');

      await tester.pumpWidget(wrap(_FakeAdminService()));
      await tester.pumpAndSettle();

      expect(find.text('Projects'), findsOneWidget);
      expect(find.text('JV Alma CIS'), findsOneWidget);
      expect(find.text('Project p1'), findsOneWidget);
      expect(find.text('Project p2'), findsNothing);
    });

    testWidgets('creating supplies this organization\'s id', (tester) async {
      final service = _FakeAdminService();

      await tester.pumpWidget(wrap(service));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Add project'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'),
        'Rosslyn Tower',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Code'),
        'ROSS-01',
      );
      await tester.tap(find.widgetWithText(ElevatedButton, 'Create'));
      await tester.pumpAndSettle();

      expect(service.createCalls, hasLength(1));
      expect(service.createCalls.single.organizationId, 'org-alpha');
      expect(service.createCalls.single.name, 'Rosslyn Tower');
    });

    testWidgets('shows an empty state when there are none', (tester) async {
      await tester.pumpWidget(wrap(_FakeAdminService()));
      await tester.pumpAndSettle();

      expect(find.text('No projects yet.'), findsOneWidget);
    });

    testWidgets('surfaces a refused create, e.g. a deleted organization', (
      tester,
    ) async {
      final service = _FakeAdminService(
        createError: const DataException('That organization does not exist.'),
      );

      await tester.pumpWidget(wrap(service));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Add project'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'),
        'Rosslyn Tower',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Code'),
        'ROSS-01',
      );
      await tester.tap(find.widgetWithText(ElevatedButton, 'Create'));
      await tester.pumpAndSettle();

      expect(
        find.text('That organization does not exist.'),
        findsOneWidget,
      );
    });
  });

  group('ProjectsScreen (Site Manager)', () {
    testWidgets('sees the same projects for their own organization', (
      tester,
    ) async {
      await seedProject('org-alpha', 'p1');

      await tester.pumpWidget(
        wrap(
          _FakeAdminService(),
          reviewerRole: AppRole.siteManager,
          organizationId: 'org-alpha',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Project p1'), findsOneWidget);
    });

    testWidgets('cannot manage another organization\'s projects', (
      tester,
    ) async {
      await seedProject('org-alpha', 'p1');

      await tester.pumpWidget(
        wrap(
          _FakeAdminService(),
          reviewerRole: AppRole.siteManager,
          organizationId: 'org-beta',
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('You do not have permission to manage projects.'),
        findsOneWidget,
      );
      expect(find.text('Project p1'), findsNothing);
    });

    testWidgets('cannot see the Add project action', (tester) async {
      await tester.pumpWidget(
        wrap(
          _FakeAdminService(),
          reviewerRole: AppRole.siteManager,
          organizationId: 'org-alpha',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('Add project'), findsNothing);
    });

    testWidgets('cannot see the Edit action, but can navigate to Sites', (
      tester,
    ) async {
      await seedProject('org-alpha', 'p1');

      await tester.pumpWidget(
        wrap(
          _FakeAdminService(),
          reviewerRole: AppRole.siteManager,
          organizationId: 'org-alpha',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.widgetWithText(OutlinedButton, 'Edit'), findsNothing);
      expect(find.widgetWithText(ElevatedButton, 'Sites'), findsOneWidget);
    });
  });

  group('ProjectsScreen (non-administrator)', () {
    testWidgets('renders no content', (tester) async {
      await tester.pumpWidget(wrap(_FakeAdminService(), reviewerRole: null));
      await tester.pumpAndSettle();

      expect(
        find.text('You do not have permission to manage projects.'),
        findsOneWidget,
      );
    });
  });
}
