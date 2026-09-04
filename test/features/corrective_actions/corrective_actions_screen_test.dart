import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/corrective_actions/data/corrective_action_repository.dart';
import 'package:jva_safety/features/corrective_actions/data/corrective_action_service.dart';
import 'package:jva_safety/features/corrective_actions/presentation/corrective_actions_screen.dart';
import 'package:jva_safety/features/organizations/data/organization_repository.dart';
import 'package:jva_safety/features/organizations/data/site_repository.dart';

class _FakeSession extends SessionController {
  _FakeSession({required AppRole? role, String? organizationId})
    : _profile = UserProfile(
        uid: 'uid-1',
        name: 'Test User',
        email: 'user@example.com',
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

  Future<void> seedAction(String orgId, String id) async {
    await firestore.doc('organizations/$orgId/corrective_actions/$id').set({
      'organizationId': orgId,
      'projectId': 'project-1',
      'siteId': 'site-1',
      'meetingId': 'meeting-1',
      'concernId': null,
      'title': 'Action $id',
      'description': 'Description $id',
      'assignedTo': 'worker-1',
      'assignedBy': 'foreman-1',
      'dueDate': Timestamp.fromDate(DateTime(2026, 9, 1)),
      'status': 'open',
      'evidenceRequired': false,
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  Widget wrap({required AppRole? role, String? organizationId}) {
    return ChangeNotifierProvider<SessionController>(
      create: (_) => _FakeSession(role: role, organizationId: organizationId),
      child: MaterialApp(
        home: Scaffold(
          body: CorrectiveActionsScreen(
            repository: organizationId != null
                ? CorrectiveActionRepository(
                    firestoreService: FirestoreService(firestore: firestore),
                    organizationId: organizationId,
                  )
                : null,
            service: CorrectiveActionService(),
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

  group('CorrectiveActionsScreen (Admin)', () {
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
          'Corrective Actions are available to Organization '
          'Administrators, Safety Managers and Site Superintendents.',
        ),
        findsNothing,
      );
      expect(find.text('Organization'), findsOneWidget);
      expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
    });

    testWidgets('a reviewer with an organization sees content directly', (
      tester,
    ) async {
      await seedOrg('alpha');
      await seedAction('alpha', 'action-1');

      await tester.pumpWidget(
        wrap(role: AppRole.siteManager, organizationId: 'alpha'),
      );
      await tester.pumpAndSettle();

      expect(find.text('Corrective Actions'), findsOneWidget);
      expect(find.text('Action action-1'), findsOneWidget);
      expect(find.text('Organization'), findsNothing);
    });

    testWidgets('a foreman with an organization also sees content directly '
        '(reviewer authority includes Foreman)', (tester) async {
      await seedOrg('alpha');
      await seedAction('alpha', 'action-1');

      await tester.pumpWidget(
        wrap(role: AppRole.foreman, organizationId: 'alpha'),
      );
      await tester.pumpAndSettle();

      expect(find.text('Corrective Actions'), findsOneWidget);
      expect(find.text('Action action-1'), findsOneWidget);
    });
  });

  group('CorrectiveActionsScreen (non-reviewer)', () {
    testWidgets('a worker is refused regardless of organization', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(role: AppRole.worker, organizationId: 'alpha'),
      );
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Corrective Actions are available to Organization '
          'Administrators, Safety Managers and Site Superintendents.',
        ),
        findsOneWidget,
      );
    });
  });
}
