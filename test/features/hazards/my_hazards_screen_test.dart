import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/corrective_actions/data/corrective_action_repository.dart';
import 'package:jva_safety/features/hazards/data/hazard_repository.dart';
import 'package:jva_safety/features/hazards/presentation/my_hazards_screen.dart';

class _FakeSession extends SessionController {
  _FakeSession({String uid = 'worker-1'})
    : _profile = UserProfile(
        uid: uid,
        name: 'Test Worker',
        email: 'worker@example.com',
        accountStatus: AccountStatus.active,
      );

  final UserProfile _profile;

  @override
  UserProfile? get profile => _profile;

  @override
  String? get activeOrganizationId => 'org-alpha';
}

class _NoOrgSession extends SessionController {
  @override
  UserProfile? get profile => const UserProfile(
    uid: 'worker-1',
    name: 'Test Worker',
    email: 'worker@example.com',
    accountStatus: AccountStatus.active,
  );
}

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<void> seedHazard(
    String id, {
    required String reportedByUid,
    String category = 'electrical',
    String description = 'A hazard',
    String status = 'reported',
    String? photoUrl,
    String? correctiveActionId,
  }) async {
    await firestore.doc('organizations/org-alpha/hazards/$id').set({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': 'site-1',
      'reportedByUid': reportedByUid,
      'category': category,
      'description': description,
      'photoUrl': photoUrl,
      'status': status,
      'correctiveActionId': correctiveActionId,
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  Widget buildApp({
    required SessionController session,
    HazardRepository? repository,
  }) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SessionController>.value(value: session),
      ],
      child: MaterialApp(
        home: MyHazardsScreen(
          hazardRepository: repository,
          correctiveActionRepository: CorrectiveActionRepository(
            firestoreService: FirestoreService(firestore: firestore),
            organizationId: 'org-alpha',
          ),
        ),
      ),
    );
  }

  testWidgets('shows a message when the user has no organization', (
    tester,
  ) async {
    await tester.pumpWidget(buildApp(session: _NoOrgSession()));

    expect(
      find.textContaining('not yet assigned to an organization'),
      findsOneWidget,
    );
  });

  testWidgets('shows an empty state when there are no reports', (tester) async {
    final repository = HazardRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    await tester.pumpWidget(
      buildApp(session: _FakeSession(), repository: repository),
    );
    await tester.pumpAndSettle();

    expect(find.text("You haven't reported any hazards yet."), findsOneWidget);
  });

  testWidgets('shows only the signed-in worker\'s own reports', (tester) async {
    await seedHazard('h1', reportedByUid: 'worker-1', description: 'Mine');
    await seedHazard('h2', reportedByUid: 'worker-2', description: 'Not mine');
    final repository = HazardRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    await tester.pumpWidget(
      buildApp(session: _FakeSession(), repository: repository),
    );
    await tester.pumpAndSettle();

    expect(find.text('Mine'), findsOneWidget);
    expect(find.text('Not mine'), findsNothing);
  });

  testWidgets('shows the category, description and status for each report', (
    tester,
  ) async {
    await seedHazard(
      'h1',
      reportedByUid: 'worker-1',
      category: 'fire',
      description: 'Smoke near storage',
      status: 'acknowledged',
    );
    final repository = HazardRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    await tester.pumpWidget(
      buildApp(session: _FakeSession(), repository: repository),
    );
    await tester.pumpAndSettle();

    expect(find.text('Fire'), findsOneWidget);
    expect(find.text('Smoke near storage'), findsOneWidget);
    expect(find.text('Acknowledged'), findsOneWidget);
  });

  testWidgets('has a Report a Safety Issue action that opens the chooser', (
    tester,
  ) async {
    final repository = HazardRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    await tester.pumpWidget(
      buildApp(session: _FakeSession(), repository: repository),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Report a Safety Issue'));
    await tester.pumpAndSettle();

    expect(find.text('Something COULD happen'), findsOneWidget);
  });

  testWidgets('the reporter sees what was done once their hazard is fixed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await seedHazard(
      'h1',
      reportedByUid: 'worker-1',
      description: 'No guard rail on level 3',
      status: 'closed',
      correctiveActionId: 'ca-1',
    );
    await firestore.doc('organizations/org-alpha/corrective_actions/ca-1').set({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': 'site-1',
      'hazardId': 'h1',
      'title': 'Fit guard rail',
      'description': 'Level 3 edge',
      'assignedTo': 'foreman-1',
      'assignedBy': 'manager-1',
      'dueDate': Timestamp.now(),
      'status': 'completed',
      'evidenceRequired': true,
      'completionNote': 'New rail fitted and inspected',
    });
    final repository = HazardRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    await tester.pumpWidget(
      buildApp(session: _FakeSession(), repository: repository),
    );
    await tester.pumpAndSettle();

    expect(find.text('Fixed: Fit guard rail'), findsOneWidget);
    expect(
      find.textContaining('New rail fitted and inspected'),
      findsOneWidget,
    );
  });

  testWidgets('a new report says it is waiting for a supervisor', (
    tester,
  ) async {
    await seedHazard('h1', reportedByUid: 'worker-1');
    final repository = HazardRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    await tester.pumpWidget(
      buildApp(session: _FakeSession(), repository: repository),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Waiting for a supervisor to look at it.'),
      findsOneWidget,
    );
  });
}
