import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/authentication/data/account_approval_service.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/membership.dart';
import 'package:jva_safety/features/authentication/domain/organization_user.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/authentication/domain/worker_type.dart';
import 'package:jva_safety/features/organizations/data/site_assignment_service.dart';
import 'package:jva_safety/features/organizations/domain/organization.dart';
import 'package:jva_safety/features/organizations/domain/organization_record_status.dart';
import 'package:jva_safety/features/organizations/domain/project.dart';
import 'package:jva_safety/features/organizations/domain/site.dart';
import 'package:jva_safety/features/organizations/presentation/site_workers_screen.dart';

/// A fake user-listing service, subclassing the real one rather than mocking
/// — the repo's established pattern (see activity_workers_screen tests and
/// organizations_screen_test.dart's `_FakeAdminService`).
class _FakeApprovalService extends AccountApprovalService {
  _FakeApprovalService({this.users = const [], this.listError});

  List<OrganizationUser> users;
  AppException? listError;

  @override
  Future<List<OrganizationUser>> listUsers({
    AccountStatus status = AccountStatus.active,
    String? organizationId,
  }) async {
    final error = listError;
    if (error != null) throw error;
    return users;
  }
}

class _FakeAssignmentService extends SiteAssignmentService {
  _FakeAssignmentService({this.assignError, this.removeError});

  AppException? assignError;
  AppException? removeError;

  final List<({String uid, String organizationId, String siteId})>
      assignCalls = [];
  final List<({String uid, String organizationId, String siteId})>
      removeCalls = [];

  @override
  Future<void> assignWorkerToSite({
    required String uid,
    required String organizationId,
    required String siteId,
  }) async {
    final error = assignError;
    if (error != null) throw error;
    assignCalls.add((uid: uid, organizationId: organizationId, siteId: siteId));
  }

  @override
  Future<void> removeWorkerFromSite({
    required String uid,
    required String organizationId,
    required String siteId,
  }) async {
    final error = removeError;
    if (error != null) throw error;
    removeCalls.add((uid: uid, organizationId: organizationId, siteId: siteId));
  }
}

class _FakeSession extends SessionController {
  _FakeSession({required AppRole? role, String? organizationId})
    : _profile = UserProfile(
        uid: 'admin-uid',
        name: 'Admin',
        email: 'admin@example.com',
        accountStatus: AccountStatus.active,
        // platformRole is admin-only now; every other role lives on the
        // active Membership instead.
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
}

void main() {
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
  const site = Site(
    id: 'site-1',
    organizationId: 'org-alpha',
    projectId: 'project-1',
    name: 'Rosslyn',
    code: 'ROSS-SITE-01',
    status: OrganizationRecordStatus.active,
  );

  const foreman = OrganizationUser(
    uid: 'foreman-uid',
    name: 'John Kamau',
    email: 'john@example.com',
    accountStatus: AccountStatus.active,
    role: AppRole.foreman,
    workerType: WorkerType.contractor,
    organizationId: 'org-alpha',
    siteIds: ['site-1'],
  );
  const unassignedWorker = OrganizationUser(
    uid: 'worker-uid',
    name: 'Mary Wanjiku',
    email: 'mary@example.com',
    accountStatus: AccountStatus.active,
    role: AppRole.worker,
    organizationId: 'org-alpha',
    siteIds: [],
  );
  const otherOrgWorker = OrganizationUser(
    uid: 'other-org-uid',
    name: 'Someone Else',
    email: 'someone@example.com',
    accountStatus: AccountStatus.active,
    role: AppRole.worker,
    organizationId: 'org-beta',
    siteIds: [],
  );

  Widget wrap({
    required AppRole? role,
    String? organizationId,
    List<OrganizationUser> users = const [],
    Organization org = organization,
    _FakeAssignmentService? assignmentService,
  }) {
    return ChangeNotifierProvider<SessionController>(
      create: (_) => _FakeSession(role: role, organizationId: organizationId),
      child: MaterialApp(
        home: Scaffold(
          body: SiteWorkersScreen(
            organization: org,
            project: project,
            site: site,
            approvalService: _FakeApprovalService(users: users),
            assignmentService: assignmentService ?? _FakeAssignmentService(),
          ),
        ),
      ),
    );
  }

  group('SiteWorkersScreen (authorization)', () {
    testWidgets('a Admin sees the management action', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(role: AppRole.admin, users: [foreman]),
      );
      await tester.pumpAndSettle();

      expect(find.text('You do not have permission to manage site workers.'), findsNothing);
      expect(find.text('John Kamau'), findsOneWidget);
    });

    testWidgets(
      'an Site Manager of the matching organization sees it',
      (tester) async {
        await tester.pumpWidget(
          wrap(
            role: AppRole.siteManager,
            organizationId: 'org-alpha',
            users: [foreman],
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('John Kamau'), findsOneWidget);
      },
    );

    testWidgets(
      'an Site Manager of a different organization is refused',
      (tester) async {
        await tester.pumpWidget(
          wrap(
            role: AppRole.siteManager,
            organizationId: 'org-beta',
            users: [foreman],
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('You do not have permission to manage site workers.'),
          findsOneWidget,
        );
      },
    );

    testWidgets('a foreman does not receive the management action', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          role: AppRole.foreman,
          organizationId: 'org-alpha',
          users: [foreman],
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('You do not have permission to manage site workers.'),
        findsOneWidget,
      );
    });

    testWidgets('a worker does not receive the management action', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          role: AppRole.worker,
          organizationId: 'org-alpha',
          users: [foreman],
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('You do not have permission to manage site workers.'),
        findsOneWidget,
      );
    });
  });

  group('SiteWorkersScreen (assigned list)', () {
    testWidgets('shows the assigned worker with name, role and status', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(role: AppRole.admin, users: [foreman]),
      );
      await tester.pumpAndSettle();

      expect(find.text('John Kamau'), findsOneWidget);
      expect(find.textContaining('Foreman'), findsOneWidget);
      expect(find.textContaining('Active'), findsOneWidget);
    });

    testWidgets('does not show a user not assigned to this site', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          role: AppRole.admin,
          users: [foreman, unassignedWorker],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('John Kamau'), findsOneWidget);
      expect(find.text('Mary Wanjiku'), findsNothing);
    });

    testWidgets('shows an empty state when nobody is assigned', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(role: AppRole.admin, users: [unassignedWorker]),
      );
      await tester.pumpAndSettle();

      expect(find.text('No workers assigned yet.'), findsOneWidget);
    });
  });

  group('SiteWorkersScreen (assign)', () {
    testWidgets('assigning a candidate calls SiteAssignmentService', (
      tester,
    ) async {
      final service = _FakeAssignmentService();

      await tester.pumpWidget(
        wrap(
          role: AppRole.admin,
          users: [unassignedWorker],
          assignmentService: service,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Assign worker'));
      await tester.pumpAndSettle();

      expect(find.text('Mary Wanjiku'), findsOneWidget);
      await tester.tap(find.text('Mary Wanjiku'));
      await tester.pumpAndSettle();

      expect(service.assignCalls, hasLength(1));
      expect(service.assignCalls.single.uid, 'worker-uid');
      expect(service.assignCalls.single.organizationId, 'org-alpha');
      expect(service.assignCalls.single.siteId, 'site-1');
    });

    testWidgets('an already-assigned worker is not offered as a candidate', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(role: AppRole.admin, users: [foreman]),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Assign worker'));
      await tester.pumpAndSettle();

      expect(
        find.text('No eligible active users in this organization to assign.'),
        findsOneWidget,
      );
    });

    testWidgets(
      'a user from another organization is never offered as a candidate',
      (tester) async {
        await tester.pumpWidget(
          wrap(
            role: AppRole.admin,
            org: organization,
            users: [unassignedWorker, otherOrgWorker],
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('Assign worker'));
        await tester.pumpAndSettle();

        expect(find.text('Mary Wanjiku'), findsOneWidget);
        expect(find.text('Someone Else'), findsNothing);
      },
    );

    testWidgets('surfaces a refused assignment', (tester) async {
      final service = _FakeAssignmentService(
        assignError: const PermissionDeniedException(
          'You do not have permission to do that.',
        ),
      );

      await tester.pumpWidget(
        wrap(
          role: AppRole.admin,
          users: [unassignedWorker],
          assignmentService: service,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Assign worker'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mary Wanjiku'));
      await tester.pumpAndSettle();

      expect(
        find.text('You do not have permission to do that.'),
        findsOneWidget,
      );
    });
  });

  group('SiteWorkersScreen (remove)', () {
    testWidgets('removing an assigned worker calls SiteAssignmentService', (
      tester,
    ) async {
      final service = _FakeAssignmentService();

      await tester.pumpWidget(
        wrap(
          role: AppRole.admin,
          users: [foreman],
          assignmentService: service,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Remove'));
      await tester.pumpAndSettle();

      expect(service.removeCalls, hasLength(1));
      expect(service.removeCalls.single.uid, 'foreman-uid');
      expect(service.removeCalls.single.organizationId, 'org-alpha');
      expect(service.removeCalls.single.siteId, 'site-1');
    });

    testWidgets('surfaces a refused removal', (tester) async {
      final service = _FakeAssignmentService(
        removeError: const PermissionDeniedException(
          'You do not have permission to do that.',
        ),
      );

      await tester.pumpWidget(
        wrap(
          role: AppRole.admin,
          users: [foreman],
          assignmentService: service,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Remove'));
      await tester.pumpAndSettle();

      expect(
        find.text('You do not have permission to do that.'),
        findsOneWidget,
      );
    });
  });

  group('SiteWorkersScreen (loading/error states)', () {
    testWidgets('surfaces a list-loading failure', (tester) async {
      await tester.pumpWidget(
        ChangeNotifierProvider<SessionController>(
          create: (_) => _FakeSession(
            role: AppRole.admin,
          ),
          child: MaterialApp(
            home: Scaffold(
              body: SiteWorkersScreen(
                organization: organization,
                project: project,
                site: site,
                approvalService: _FakeApprovalService(
                  listError: const DataException('Could not load users.'),
                ),
                assignmentService: _FakeAssignmentService(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Could not load users.'), findsOneWidget);
    });
  });
}
