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
import 'package:jva_safety/features/corrective_actions/presentation/my_corrective_actions_screen.dart';

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

  Future<void> seedAction(
    String id, {
    required String assignedTo,
    String status = 'open',
    String description = 'A corrective action',
    String? reviewFeedback,
    String? hazardId,
  }) async {
    await firestore.doc('organizations/org-alpha/corrective_actions/$id').set({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': 'site-1',
      'meetingId': hazardId == null ? 'meeting-1' : null,
      'concernId': null,
      'hazardId': hazardId,
      'reviewFeedback': reviewFeedback,
      'assignedByName': 'Grace Achieng',
      'title': 'Action $id',
      'description': description,
      'assignedTo': assignedTo,
      'assignedBy': 'foreman-1',
      'dueDate': Timestamp.fromDate(DateTime(2026, 9, 1)),
      'status': status,
      'evidenceRequired': false,
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  Widget buildApp({
    required SessionController session,
    CorrectiveActionRepository? repository,
  }) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SessionController>.value(value: session),
      ],
      child: MaterialApp(
        home: MyCorrectiveActionsScreen(repository: repository),
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

  testWidgets('shows an empty state when nothing is assigned', (tester) async {
    final repository = CorrectiveActionRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    await tester.pumpWidget(
      buildApp(session: _FakeSession(), repository: repository),
    );
    await tester.pumpAndSettle();

    expect(find.text('Nothing assigned to you'), findsOneWidget);
  });

  testWidgets('shows only the signed-in worker\'s own assigned actions', (
    tester,
  ) async {
    await seedAction('ca1', assignedTo: 'worker-1', description: 'Mine');
    await seedAction('ca2', assignedTo: 'worker-2', description: 'Not mine');
    final repository = CorrectiveActionRepository(
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

  testWidgets(
    'an open action offers Complete & Submit; a submittedForReview one '
    'does not',
    (tester) async {
      await seedAction('ca1', assignedTo: 'worker-1', status: 'open');
      await seedAction(
        'ca2',
        assignedTo: 'worker-1',
        status: 'submittedForReview',
      );
      final repository = CorrectiveActionRepository(
        firestoreService: FirestoreService(firestore: firestore),
        organizationId: 'org-alpha',
      );

      await tester.pumpWidget(
        buildApp(session: _FakeSession(), repository: repository),
      );
      await tester.pumpAndSettle();

      expect(find.text('Complete & Submit'), findsOneWidget);
      expect(find.textContaining('waiting for a supervisor'), findsOneWidget);
    },
  );

  testWidgets('a completed action offers no actions', (tester) async {
    await seedAction('ca1', assignedTo: 'worker-1', status: 'completed');
    final repository = CorrectiveActionRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    await tester.pumpWidget(
      buildApp(session: _FakeSession(), repository: repository),
    );
    await tester.pumpAndSettle();

    expect(find.text('Complete & Submit'), findsNothing);
  });

  testWidgets('a worker sees their jobs as To do / Waiting for review / Done, '
      'with who asked and where it came from', (tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await seedAction(
      'todo',
      assignedTo: 'worker-1',
      hazardId: 'hazard-1',
      reviewFeedback: 'Photo is blurry',
      status: 'inProgress',
    );
    await seedAction(
      'review',
      assignedTo: 'worker-1',
      status: 'submittedForReview',
    );
    await seedAction('done', assignedTo: 'worker-1', status: 'completed');
    final repository = CorrectiveActionRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    await tester.pumpWidget(
      buildApp(session: _FakeSession(), repository: repository),
    );
    await tester.pumpAndSettle();

    expect(find.text('To do'), findsOneWidget);
    expect(find.text('Waiting for review'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
    expect(find.text('From a reported hazard'), findsOneWidget);
    expect(find.text('Asked by Grace Achieng'), findsWidgets);
    expect(find.text('Sent back'), findsOneWidget);
    expect(find.text('Reviewer: Photo is blurry'), findsOneWidget);
    expect(find.text('Complete & Submit'), findsOneWidget);
  });
}
