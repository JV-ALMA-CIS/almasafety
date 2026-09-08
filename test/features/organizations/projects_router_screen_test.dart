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
import 'package:jva_safety/features/organizations/data/organization_repository.dart';
import 'package:jva_safety/features/organizations/data/project_repository.dart';
import 'package:jva_safety/features/organizations/presentation/projects_router_screen.dart';

class _FakeSession extends SessionController {
  _FakeSession({required AppRole? role, String? organizationId})
    : _profile = UserProfile(
        uid: 'user-1',
        name: 'Test User',
        email: 'user@example.com',
        accountStatus: AccountStatus.active,
        platformRole: role == AppRole.admin ||
                (role == AppRole.siteManager && organizationId == null)
            ? role
            : null,
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

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<void> seedOrganization(String id, {String name = 'JV Alma CIS'}) async {
    await firestore.doc('organizations/$id').set({
      'name': name,
      'code': 'CODE-$id',
      'status': 'active',
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  Widget wrap({required AppRole? role, String? organizationId}) {
    final firestoreService = FirestoreService(firestore: firestore);
    return ChangeNotifierProvider<SessionController>(
      create: (_) => _FakeSession(role: role, organizationId: organizationId),
      child: MaterialApp(
        home: Scaffold(
          body: ProjectsRouterScreen(
            organizationRepository: OrganizationRepository(
              firestoreService: firestoreService,
            ),
            firestoreService: firestoreService,
            projectRepository: organizationId == null
                ? null
                : ProjectRepository(
                    firestoreService: firestoreService,
                    organizationId: organizationId,
                  ),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'a Site Manager reaches ProjectsScreen for their own organization '
    'directly, without navigating through Organizations first',
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
    'a user with no active organization yet sees a not-yet-assigned '
    'message instead of an empty/loading screen',
    (tester) async {
      await tester.pumpWidget(
        wrap(role: AppRole.siteManager, organizationId: null),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Your account is not yet assigned to an organization.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'a Worker reaching this route sees ProjectsScreen\'s own '
    'permission message, not a crash',
    (tester) async {
      await seedOrganization('org-alpha');

      await tester.pumpWidget(
        wrap(role: AppRole.worker, organizationId: 'org-alpha'),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('You do not have permission to manage projects.'),
        findsOneWidget,
      );
    },
  );
}
