import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
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
        home: MyHazardsScreen(hazardRepository: repository),
      ),
    );
  }

  testWidgets('shows a message when the user has no organization',
    (tester) async {
      await tester.pumpWidget(buildApp(session: _NoOrgSession()));

      expect(
        find.textContaining('not yet assigned to an organization'),
        findsOneWidget,
      );
    });

  testWidgets('shows an empty state when there are no reports', (
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

    expect(
      find.text("You haven't reported any hazards yet."),
      findsOneWidget,
    );
  });

  testWidgets('shows only the signed-in worker\'s own reports', (
    tester,
  ) async {
    await seedHazard('h1', reportedByUid: 'worker-1', description: 'Mine');
    await seedHazard(
      'h2',
      reportedByUid: 'worker-2',
      description: 'Not mine',
    );
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

  testWidgets('shows the category, description and status for each report',
    (tester) async {
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

  testWidgets('has a Report Hazard action that opens the report screen',
    (tester) async {
      final repository = HazardRepository(
        firestoreService: FirestoreService(firestore: firestore),
        organizationId: 'org-alpha',
      );

      await tester.pumpWidget(
        buildApp(session: _FakeSession(), repository: repository),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Report Hazard'));
      await tester.pumpAndSettle();

      expect(find.text('Report a Hazard'), findsAtLeastNWidgets(1));
    });
}
