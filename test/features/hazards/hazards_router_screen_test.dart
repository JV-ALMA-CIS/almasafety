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
import 'package:jva_safety/features/corrective_actions/data/corrective_action_repository.dart';
import 'package:jva_safety/features/hazards/data/hazard_repository.dart';
import 'package:jva_safety/features/hazards/presentation/hazards_router_screen.dart';
import 'package:jva_safety/features/organizations/data/organization_repository.dart';
import 'package:jva_safety/features/organizations/data/site_repository.dart';

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
}

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Widget wrap({required AppRole? role, String? organizationId}) {
    final resolvedOrganizationId = organizationId ?? 'org-alpha';
    final firestoreService = FirestoreService(firestore: firestore);
    return ChangeNotifierProvider<SessionController>(
      create: (_) => _FakeSession(role: role, organizationId: organizationId),
      child: MaterialApp(
        home: Scaffold(
          body: HazardsRouterScreen(
            hazardRepository: HazardRepository(
              firestoreService: firestoreService,
              organizationId: resolvedOrganizationId,
            ),
            siteRepository: SiteRepository(
              firestoreService: firestoreService,
              organizationId: resolvedOrganizationId,
            ),
            correctiveActionRepository: CorrectiveActionRepository(
              firestoreService: firestoreService,
              organizationId: resolvedOrganizationId,
            ),
            organizationRepository: OrganizationRepository(
              firestoreService: firestoreService,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('a worker sees their own read-only hazard reports, not the '
      'reviewer management screen', (tester) async {
    await tester.pumpWidget(
      wrap(role: AppRole.worker, organizationId: 'org-alpha'),
    );
    await tester.pumpAndSettle();

    expect(find.text('My Hazard Reports'), findsOneWidget);
    expect(find.text('Hazard Management'), findsNothing);
  });

  testWidgets('a Site Manager is routed to the reviewer management screen, '
      'not the worker view', (tester) async {
    await tester.pumpWidget(
      wrap(role: AppRole.siteManager, organizationId: 'org-alpha'),
    );
    await tester.pumpAndSettle();

    expect(find.text('Hazard Management'), findsOneWidget);
    expect(find.text('My Hazard Reports'), findsNothing);
  });

  testWidgets('a foreman (reviewer authority) is also routed to the '
      'management screen', (tester) async {
    await tester.pumpWidget(
      wrap(role: AppRole.foreman, organizationId: 'org-alpha'),
    );
    await tester.pumpAndSettle();

    expect(find.text('Hazard Management'), findsOneWidget);
  });
}
