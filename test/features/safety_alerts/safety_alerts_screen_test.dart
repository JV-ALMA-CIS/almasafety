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
import 'package:jva_safety/features/organizations/data/site_repository.dart';
import 'package:jva_safety/features/safety_alerts/data/safety_alert_repository.dart';
import 'package:jva_safety/features/safety_alerts/data/safety_alert_service.dart';
import 'package:jva_safety/features/safety_alerts/presentation/safety_alerts_screen.dart';

class _FakeSession extends SessionController {
  _FakeSession({required AppRole? role, String? organizationId})
    : _profile = UserProfile(
        uid: 'uid-1',
        name: 'Test User',
        email: 'user@example.com',
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

  Future<void> seedAlert(String orgId, String id) async {
    await firestore.doc('organizations/$orgId/safety_alerts/$id').set({
      'organizationId': orgId,
      'projectId': 'project-1',
      'siteId': 'site-1',
      'title': 'Alert $id',
      'description': 'Description $id',
      'severity': 'high',
      'category': 'safety',
      'status': 'active',
      'createdBy': 'uid-1',
      'createdAt': Timestamp.now(),
      'acknowledgedAt': null,
      'acknowledgedBy': null,
      'resolvedAt': null,
      'resolvedBy': null,
    });
  }

  Widget wrap({required AppRole? role, String? organizationId}) {
    return ChangeNotifierProvider<SessionController>(
      create: (_) => _FakeSession(role: role, organizationId: organizationId),
      child: MaterialApp(
        home: Scaffold(
          body: SafetyAlertsScreen(
            repository: organizationId != null
                ? SafetyAlertRepository(
                    firestoreService: FirestoreService(firestore: firestore),
                    organizationId: organizationId,
                  )
                : null,
            service: SafetyAlertService(),
            siteRepository: organizationId != null
                ? SiteRepository(
                    firestoreService: FirestoreService(firestore: firestore),
                    organizationId: organizationId,
                  )
                : null,
            organizationRepository: OrganizationRepository(
              firestoreService: FirestoreService(firestore: firestore),
            ),
          ),
        ),
      ),
    );
  }

  group('SafetyAlertsScreen (Admin)', () {
    testWidgets('shows an organization picker instead of being blocked', (
      tester,
    ) async {
      await seedOrg('alpha');

      await tester.pumpWidget(
        wrap(role: AppRole.admin, organizationId: null),
      );
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Safety Alerts are available once your account has an '
          'organization.',
        ),
        findsNothing,
      );
      expect(find.text('Organization'), findsOneWidget);
    });

    testWidgets('a reviewer with an organization sees content directly', (
      tester,
    ) async {
      await seedOrg('alpha');
      await seedAlert('alpha', 'alert-1');

      await tester.pumpWidget(
        wrap(role: AppRole.siteManager, organizationId: 'alpha'),
      );
      await tester.pumpAndSettle();

      expect(find.text('Safety Alerts'), findsOneWidget);
      expect(find.text('Alert alert-1'), findsOneWidget);
    });
  });
}
