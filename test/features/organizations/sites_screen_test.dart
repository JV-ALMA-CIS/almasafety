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
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/organizations/data/organization_admin_service.dart';
import 'package:jva_safety/features/organizations/data/site_repository.dart';
import 'package:jva_safety/features/organizations/domain/organization.dart';
import 'package:jva_safety/features/organizations/domain/organization_record_status.dart';
import 'package:jva_safety/features/organizations/domain/project.dart';
import 'package:jva_safety/features/organizations/presentation/sites_screen.dart';

class _FakeAdminService extends OrganizationAdminService {
  _FakeAdminService({this.createError});

  AppException? createError;

  final List<({String organizationId, String projectId, String name})>
      createCalls = [];

  @override
  Future<String> createSite({
    required String organizationId,
    required String projectId,
    required String name,
    required String code,
    String? location,
    String? description,
    OrganizationRecordStatus status = OrganizationRecordStatus.active,
  }) async {
    final error = createError;
    if (error != null) throw error;
    createCalls.add(
      (organizationId: organizationId, projectId: projectId, name: name),
    );
    return 'new-site-id';
  }
}

class _FakeSession extends SessionController {
  _FakeSession({required AppRole? role, String? organizationId})
    : _profile = UserProfile(
        uid: 'sysadmin-uid',
        name: 'Sysadmin',
        email: 'sysadmin@example.com',
        accountStatus: AccountStatus.active,
        platformRole: role,
        organizationId: organizationId,
      );

  final UserProfile _profile;

  @override
  UserProfile? get profile => _profile;
}

void main() {
  late FakeFirebaseFirestore firestore;

  const organization = Organization(
    id: 'org-alpha',
    name: 'JV Alma CIS',
    code: 'JV-ALMA-CIS',
    status: OrganizationRecordStatus.active,
  );
  const project = Project(
    id: 'project-1',
    organizationId: 'org-alpha',
    name: 'Rosslyn Tower',
    code: 'ROSS-01',
    status: OrganizationRecordStatus.active,
  );

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<void> seedSite(
    String orgId,
    String id, {
    required String projectId,
  }) async {
    await firestore.doc('organizations/$orgId/sites/$id').set({
      'organizationId': orgId,
      'projectId': projectId,
      'name': 'Site $id',
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
          body: SitesScreen(
            organization: organization,
            project: project,
            repository: SiteRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: organization.id,
            ),
            adminService: adminService,
          ),
        ),
      ),
    );
  }

  group('SitesScreen (Admin)', () {
    testWidgets('lists only this project\'s sites', (tester) async {
      await seedSite('org-alpha', 's1', projectId: 'project-1');
      await seedSite('org-alpha', 's2', projectId: 'project-2');

      await tester.pumpWidget(wrap(_FakeAdminService()));
      await tester.pumpAndSettle();

      expect(find.text('Sites'), findsOneWidget);
      expect(find.textContaining('JV Alma CIS'), findsOneWidget);
      expect(find.text('Site s1'), findsOneWidget);
      expect(find.text('Site s2'), findsNothing);
    });

    testWidgets('creating supplies this organization and project id', (
      tester,
    ) async {
      final service = _FakeAdminService();

      await tester.pumpWidget(wrap(service));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Add site'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'),
        'Rosslyn Site',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Code'),
        'ROSS-SITE-01',
      );
      await tester.tap(find.widgetWithText(ElevatedButton, 'Create'));
      await tester.pumpAndSettle();

      expect(service.createCalls, hasLength(1));
      expect(service.createCalls.single.organizationId, 'org-alpha');
      expect(service.createCalls.single.projectId, 'project-1');
    });

    testWidgets(
      'surfaces the server refusal when project/organization mismatch',
      (tester) async {
        final service = _FakeAdminService(
          createError: const DataException(
            'That project does not belong to the given organization.',
          ),
        );

        await tester.pumpWidget(wrap(service));
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('Add site'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Name'),
          'Rosslyn Site',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Code'),
          'ROSS-SITE-01',
        );
        await tester.tap(find.widgetWithText(ElevatedButton, 'Create'));
        await tester.pumpAndSettle();

        expect(
          find.text('That project does not belong to the given organization.'),
          findsOneWidget,
        );
      },
    );

    testWidgets('shows an empty state when there are none', (tester) async {
      await tester.pumpWidget(wrap(_FakeAdminService()));
      await tester.pumpAndSettle();

      expect(find.text('No sites yet.'), findsOneWidget);
    });
  });

  group('SitesScreen (Site Manager)', () {
    testWidgets('sees the same sites for their own organization', (
      tester,
    ) async {
      await seedSite('org-alpha', 's1', projectId: 'project-1');

      await tester.pumpWidget(
        wrap(
          _FakeAdminService(),
          reviewerRole: AppRole.siteManager,
          organizationId: 'org-alpha',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Site s1'), findsOneWidget);
    });

    testWidgets('cannot manage another organization\'s sites', (
      tester,
    ) async {
      await seedSite('org-alpha', 's1', projectId: 'project-1');

      await tester.pumpWidget(
        wrap(
          _FakeAdminService(),
          reviewerRole: AppRole.siteManager,
          organizationId: 'org-beta',
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('You do not have permission to manage sites.'),
        findsOneWidget,
      );
      expect(find.text('Site s1'), findsNothing);
    });

    testWidgets('cannot see the Add site action', (tester) async {
      await tester.pumpWidget(
        wrap(
          _FakeAdminService(),
          reviewerRole: AppRole.siteManager,
          organizationId: 'org-alpha',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('Add site'), findsNothing);
    });

    testWidgets('cannot see the Edit action, but sees Workers', (
      tester,
    ) async {
      await seedSite('org-alpha', 's1', projectId: 'project-1');

      await tester.pumpWidget(
        wrap(
          _FakeAdminService(),
          reviewerRole: AppRole.siteManager,
          organizationId: 'org-alpha',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.widgetWithText(OutlinedButton, 'Edit'), findsNothing);
      expect(find.widgetWithText(ElevatedButton, 'Workers'), findsOneWidget);
    });
  });

  group('SitesScreen (Admin sees Workers action too)', () {
    testWidgets('the Workers action is present alongside Edit/Activities', (
      tester,
    ) async {
      await seedSite('org-alpha', 's1', projectId: 'project-1');

      await tester.pumpWidget(wrap(_FakeAdminService()));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(OutlinedButton, 'Edit'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Activities'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Workers'), findsOneWidget);
    });
  });

  group('SitesScreen (non-administrator)', () {
    testWidgets('renders no content', (tester) async {
      await tester.pumpWidget(wrap(_FakeAdminService(), reviewerRole: null));
      await tester.pumpAndSettle();

      expect(
        find.text('You do not have permission to manage sites.'),
        findsOneWidget,
      );
    });
  });
}
