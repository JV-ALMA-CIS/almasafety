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
import 'package:jva_safety/features/authentication/domain/organization_user.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/authentication/data/account_approval_service.dart';
import 'package:jva_safety/features/daily_safety_meetings/data/daily_safety_meeting_repository.dart';
import 'package:jva_safety/features/daily_safety_meetings/presentation/daily_safety_meetings_router_screen.dart';
import 'package:jva_safety/features/organizations/data/organization_repository.dart';
import 'package:jva_safety/features/organizations/data/project_repository.dart';
import 'package:jva_safety/features/organizations/data/site_repository.dart';

class _FakeApprovalService extends AccountApprovalService {
  @override
  Future<List<OrganizationUser>> listUsers({
    AccountStatus status = AccountStatus.active,
    String? organizationId,
  }) async => const [];
}

class _FakeSession extends SessionController {
  _FakeSession({
    required AppRole? role,
    String? organizationId,
    List<String> siteIds = const [],
  }) : _profile = UserProfile(
         uid: 'user-1',
         name: 'Test User',
         email: 'user@example.com',
         accountStatus: AccountStatus.active,
         // platformRole is admin-only now; every other role lives on the
         // active Membership instead.
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
               siteIds: siteIds,
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

  Widget wrap({
    required AppRole? role,
    String? organizationId,
    List<String> siteIds = const [],
  }) {
    final firestoreService = FirestoreService(firestore: firestore);
    return ChangeNotifierProvider<SessionController>(
      create: (_) => _FakeSession(
        role: role,
        organizationId: organizationId,
        siteIds: siteIds,
      ),
      child: MaterialApp(
        home: Scaffold(
          body: DailySafetyMeetingsRouterScreen(
            organizationRepository: OrganizationRepository(
              firestoreService: firestoreService,
            ),
            firestoreService: firestoreService,
            meetingRepository: organizationId == null
                ? null
                : DailySafetyMeetingRepository(
                    firestoreService: firestoreService,
                    organizationId: organizationId,
                  ),
            projectRepository: organizationId == null
                ? null
                : ProjectRepository(
                    firestoreService: firestoreService,
                    organizationId: organizationId,
                  ),
            siteRepository: organizationId == null
                ? null
                : SiteRepository(
                    firestoreService: firestoreService,
                    organizationId: organizationId,
                  ),
            approvalService: _FakeApprovalService(),
          ),
        ),
      ),
    );
  }

  testWidgets('a foreman sees their own operational meeting workspace, '
      'not the review screen', (tester) async {
    await tester.pumpWidget(
      wrap(role: AppRole.foreman, organizationId: 'org-alpha'),
    );
    await tester.pumpAndSettle();

    // No site is seeded on this profile, so DailySafetyMeetingScreen's own
    // "no site assigned" message proves it (and not the admin review
    // screen) was rendered for a foreman.
    expect(
      find.text(
        'Daily Safety Meetings are available to a foreman assigned '
        'to a site.',
      ),
      findsOneWidget,
    );
    expect(find.text('Daily Safety Meetings'), findsNothing);
  });

  testWidgets('a Site Manager is routed to the read-only review screen for '
      'their own organization, not the foreman workspace', (tester) async {
    await seedOrganization('org-alpha', name: 'JV Alma CIS');

    await tester.pumpWidget(
      wrap(role: AppRole.siteManager, organizationId: 'org-alpha'),
    );
    await tester.pumpAndSettle();

    expect(find.text('Daily Safety Meetings'), findsOneWidget);
    expect(find.text('JV Alma CIS'), findsOneWidget);
    // Never the foreman-only messaging.
    expect(
      find.text(
        'Daily Safety Meetings are available to a foreman '
        'assigned to a site.',
      ),
      findsNothing,
    );
  });

  testWidgets('a worker sees the foreman-workspace messaging, not the '
      'review screen', (tester) async {
    await tester.pumpWidget(
      wrap(role: AppRole.worker, organizationId: 'org-alpha'),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Daily Safety Meetings are available to a foreman assigned '
        'to a site.',
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'a reviewer role before JV ALMA CIS is set up sees a clear message '
    'instead of crashing',
    (tester) async {
      await tester.pumpWidget(
        wrap(role: AppRole.siteManager, organizationId: null),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('JV ALMA CIS has not been set up yet'),
        findsOneWidget,
      );
    },
  );
}
