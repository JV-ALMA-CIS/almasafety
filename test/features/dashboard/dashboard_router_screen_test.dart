import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/features/incidents/data/incident_repository.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/analytics/data/analytics_repository.dart';
import 'package:jva_safety/features/authentication/data/account_approval_service.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/membership.dart';
import 'package:jva_safety/features/authentication/domain/organization_user.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/corrective_actions/data/corrective_action_repository.dart';
import 'package:jva_safety/features/daily_safety_meetings/data/daily_safety_meeting_repository.dart';
import 'package:jva_safety/features/daily_safety_meetings/data/meeting_attendance_repository.dart';
import 'package:jva_safety/features/dashboard/presentation/dashboard_router_screen.dart';
import 'package:jva_safety/features/hazards/data/hazard_repository.dart';
import 'package:jva_safety/features/organizations/data/organization_repository.dart';
import 'package:jva_safety/features/organizations/data/project_repository.dart';
import 'package:jva_safety/features/organizations/data/site_repository.dart';
import 'package:jva_safety/features/safety_learning_compliance/data/safety_compliance_repository.dart';
import 'package:jva_safety/features/safety_learning_compliance/domain/activity_compliance_summary.dart';
import 'package:jva_safety/features/safety_requirements/data/safety_requirement_repository.dart';

class _FakeSession extends SessionController {
  _FakeSession({required AppRole? role, String? organizationId})
    : _profile = UserProfile(
        uid: 'uid-1',
        name: 'Test User',
        email: 'user@example.com',
        accountStatus: AccountStatus.active,
        platformRole: role == AppRole.admin ? role : null,
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
  final Membership? _membership;

  @override
  UserProfile? get profile => _profile;

  @override
  String? get activeOrganizationId => _membership?.organizationId;

  @override
  Membership? get activeMembership => _membership;

  @override
  bool get membershipsLoaded => true;
}

class _FakeApprovalService extends AccountApprovalService {
  @override
  Future<List<OrganizationUser>> listUsers({
    AccountStatus status = AccountStatus.active,
    String? organizationId,
  }) async => const [];
}

class _FakeComplianceRepository extends SafetyComplianceRepository {
  _FakeComplianceRepository({
    required super.firestoreService,
    required super.organizationId,
  });

  @override
  Future<List<ActivityComplianceSummary>> buildSiteCompliance(
    String siteId,
  ) async => const [];
}

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<void> seedOrg(String id) async {
    await firestore.doc('organizations/$id').set({
      'name': 'Org $id',
      'code': 'CODE-$id',
      'status': 'active',
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  Widget wrap({required AppRole? role, String? organizationId}) {
    final resolvedOrganizationId = organizationId ?? 'org-alpha';
    final firestoreService = FirestoreService(firestore: firestore);
    return ChangeNotifierProvider<SessionController>(
      create: (_) => _FakeSession(role: role, organizationId: organizationId),
      child: MaterialApp(
        home: Scaffold(
          body: DashboardRouterScreen(
            safetyRequirementRepository: SafetyRequirementRepository(
              firestoreService: firestoreService,
              organizationId: resolvedOrganizationId,
            ),
            dailySafetyMeetingRepository: DailySafetyMeetingRepository(
              firestoreService: firestoreService,
              organizationId: resolvedOrganizationId,
            ),
            hazardRepository: HazardRepository(
              firestoreService: firestoreService,
              organizationId: resolvedOrganizationId,
            ),
            incidentRepository: IncidentRepository(
              firestoreService: firestoreService,
              organizationId: resolvedOrganizationId,
            ),
            correctiveActionRepository: CorrectiveActionRepository(
              firestoreService: firestoreService,
              organizationId: resolvedOrganizationId,
            ),
            meetingAttendanceRepositoryFor: (meetingId) =>
                MeetingAttendanceRepository(
                  firestoreService: firestoreService,
                  organizationId: resolvedOrganizationId,
                  meetingId: meetingId,
                ),
            analyticsRepository: AnalyticsRepository(
              firestoreService: firestoreService,
              organizationId: resolvedOrganizationId,
              accountApprovalService: _FakeApprovalService(),
            ),
            siteRepository: SiteRepository(
              firestoreService: firestoreService,
              organizationId: resolvedOrganizationId,
            ),
            projectRepository: ProjectRepository(
              firestoreService: firestoreService,
              organizationId: resolvedOrganizationId,
            ),
            organizationRepository: OrganizationRepository(
              firestoreService: firestoreService,
            ),
            safetyComplianceRepository: _FakeComplianceRepository(
              firestoreService: firestoreService,
              organizationId: resolvedOrganizationId,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('a worker sees the worker dashboard', (tester) async {
    await tester.pumpWidget(
      wrap(role: AppRole.worker, organizationId: 'org-alpha'),
    );
    await tester.pumpAndSettle();

    // WorkerDashboardScreen's own section titles — see
    // worker_dashboard_screen_test.dart for its full content coverage.
    expect(find.text('Ready for Today'), findsOneWidget);
    expect(find.text("Today's Meeting"), findsOneWidget);
  });

  testWidgets('a foreman sees the foreman dashboard', (tester) async {
    await tester.pumpWidget(
      wrap(role: AppRole.foreman, organizationId: 'org-alpha'),
    );
    await tester.pumpAndSettle();

    // ForemanDashboardScreen's own "no site assigned" message — this
    // fake session carries no siteIds, which is enough to prove the
    // foreman-specific body (not worker/site manager/admin) rendered. See
    // foreman_dashboard_screen_test.dart for its full content coverage.
    expect(
      find.text('You have not been assigned to a site yet.'),
      findsOneWidget,
    );
  });

  testWidgets('a site manager sees the site manager dashboard', (tester) async {
    await tester.pumpWidget(
      wrap(role: AppRole.siteManager, organizationId: 'org-alpha'),
    );
    await tester.pumpAndSettle();

    // SiteManagerDashboardScreen's own section titles — see
    // site_manager_dashboard_screen_test.dart for its full content
    // coverage.
    expect(find.text('Site KPIs'), findsOneWidget);
  });

  testWidgets('an admin sees the admin dashboard, regardless of membership', (
    tester,
  ) async {
    await seedOrg('org-alpha');

    await tester.pumpWidget(wrap(role: AppRole.admin, organizationId: null));
    await tester.pumpAndSettle();

    // AdminDashboardScreen's own section title — see
    // admin_dashboard_screen_test.dart for its full content coverage.
    expect(find.text('Organization KPIs'), findsOneWidget);
  });

  testWidgets(
    'a signed-in user with no membership yet sees an explanatory message, '
    'not a crash',
    (tester) async {
      await tester.pumpWidget(wrap(role: null, organizationId: null));
      await tester.pumpAndSettle();

      expect(find.textContaining('Your dashboard will appear'), findsOneWidget);
    },
  );
}
