import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/activities/data/activity_repository.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/organizations/domain/organization_record_status.dart';
import 'package:jva_safety/features/safety_meeting_points/data/safety_meeting_point_admin_service.dart';
import 'package:jva_safety/features/safety_meeting_points/data/safety_meeting_point_repository.dart';
import 'package:jva_safety/features/safety_meeting_points/presentation/safety_meeting_points_screen.dart';

/// A fake admin service, subclassing the real one rather than mocking — the
/// repo's established pattern (see organizations_screen_test.dart's
/// `_FakeAdminService`).
class _FakeAdminService extends SafetyMeetingPointAdminService {
  final List<
      ({
        String organizationId,
        String title,
        String category,
        List<String> applicableActivities,
      })> createCalls = [];

  @override
  Future<String> createSafetyMeetingPoint({
    required String organizationId,
    required String title,
    required String category,
    String? description,
    List<String> applicableActivities = const [],
    List<String> applicableRisks = const [],
    OrganizationRecordStatus status = OrganizationRecordStatus.active,
  }) async {
    createCalls.add((
      organizationId: organizationId,
      title: title,
      category: category,
      applicableActivities: applicableActivities,
    ));
    return 'new-point-id';
  }
}

class _FakeSession extends SessionController {
  _FakeSession({required AppRole? role})
    : _profile = UserProfile(
        uid: 'admin-uid',
        name: 'Admin',
        email: 'admin@example.com',
        accountStatus: AccountStatus.active,
        platformRole: role,
        organizationId: 'org-alpha',
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

  Future<void> seedActivity(String id, {String name = 'Roofing'}) async {
    await firestore.doc('organizations/org-alpha/activities/$id').set({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': 'site-1',
      'name': name,
      'code': 'CODE-$id',
      'status': 'active',
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  Widget wrap(_FakeAdminService adminService) {
    return ChangeNotifierProvider<SessionController>(
      // The Safety Meeting Point library is admin-only (PROJECT_CONTEXT.md
      // §4, §12) — deliberately not delegated to Site Managers.
      create: (_) => _FakeSession(role: AppRole.admin),
      child: MaterialApp(
        home: Scaffold(
          body: SafetyMeetingPointsScreen(
            organizationId: 'org-alpha',
            repository: SafetyMeetingPointRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: 'org-alpha',
            ),
            activityRepository: ActivityRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: 'org-alpha',
            ),
            adminService: adminService,
          ),
        ),
      ),
    );
  }

  group('SafetyMeetingPointsScreen (create dialog)', () {
    testWidgets('opens without a rendering exception', (tester) async {
      await tester.pumpWidget(wrap(_FakeAdminService()));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Add meeting point'));
      await tester.pumpAndSettle();

      // A regression test for a bug where the dialog's content
      // (SingleChildScrollView with no bounding width) threw
      // "BoxConstraints forces an infinite width" and silently swallowed
      // the Create tap. No exception should be recorded by the test
      // framework, and the dialog's fields must actually be visible.
      expect(tester.takeException(), isNull);
      expect(find.widgetWithText(TextFormField, 'Title'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Category'), findsOneWidget);
    });

    testWidgets('creating with valid input calls the admin service and '
        'closes the dialog', (tester) async {
      final service = _FakeAdminService();

      await tester.pumpWidget(wrap(service));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Add meeting point'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Title'),
        'Working at Height',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Category'),
        'Safety',
      );
      await tester.tap(find.widgetWithText(ElevatedButton, 'Create'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(service.createCalls, hasLength(1));
      expect(service.createCalls.single.organizationId, 'org-alpha');
      expect(service.createCalls.single.title, 'Working at Height');
      expect(service.createCalls.single.category, 'Safety');
      // The dialog is gone after a successful create.
      expect(find.text('Add Meeting Point'), findsNothing);
    });

    testWidgets('cannot submit without a title or category', (tester) async {
      final service = _FakeAdminService();

      await tester.pumpWidget(wrap(service));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Add meeting point'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Create'));
      await tester.pumpAndSettle();

      expect(service.createCalls, isEmpty);
      expect(find.text('A title is required.'), findsOneWidget);
      expect(find.text('A category is required.'), findsOneWidget);
    });

    testWidgets(
      'the Applicable activities field is a picker of real activities, '
      'not free text — a regression test for recommendations silently '
      'never matching a typed activity name',
      (tester) async {
        await seedActivity('activity-1', name: 'Roofing');
        final service = _FakeAdminService();

        await tester.pumpWidget(wrap(service));
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('Add meeting point'));
        await tester.pumpAndSettle();

        // The activity is offered by name, not as a free-text field the
        // administrator could mistype or enter a name into instead of an
        // id.
        expect(find.text('Applicable activities'), findsOneWidget);
        expect(find.text('Roofing'), findsOneWidget);
        expect(
          find.widgetWithText(TextFormField, 'Applicable activities'),
          findsNothing,
        );

        await tester.enterText(
          find.widgetWithText(TextFormField, 'Title'),
          'Working at Height',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Category'),
          'Safety',
        );
        await tester.tap(find.byType(CheckboxListTile));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ElevatedButton, 'Create'));
        await tester.pumpAndSettle();

        expect(service.createCalls, hasLength(1));
        // The stored value is the activity's real Firestore document id
        // ("activity-1"), never the typed/displayed name ("Roofing") — this
        // is exactly what `DailySafetyMeetingScreen`'s recommendation
        // matching (`applicableActivities.any(activityIds.contains)`)
        // requires to ever recommend this point for a Roofing meeting.
        expect(service.createCalls.single.applicableActivities, [
          'activity-1',
        ]);
      },
    );
  });

  group('SafetyMeetingPointsScreen (list)', () {
    testWidgets(
      'the card shows a linked activity by name, not its raw document id',
      (tester) async {
        await seedActivity('activity-1', name: 'Roofing');
        await firestore
            .doc('organizations/org-alpha/safety_meeting_points/point-1')
            .set({
          'organizationId': 'org-alpha',
          'title': 'Working at Height',
          'category': 'Safety',
          'status': 'active',
          'applicableActivities': ['activity-1'],
          'applicableRisks': <String>[],
          'createdAt': Timestamp.now(),
          'updatedAt': Timestamp.now(),
        });

        await tester.pumpWidget(wrap(_FakeAdminService()));
        await tester.pumpAndSettle();

        expect(find.textContaining('Roofing'), findsOneWidget);
        expect(find.textContaining('activity-1'), findsNothing);
      },
    );

    testWidgets('shows an existing point', (tester) async {
      await firestore
          .doc('organizations/org-alpha/safety_meeting_points/point-1')
          .set({
        'organizationId': 'org-alpha',
        'title': 'Ladder Safety',
        'category': 'Safety',
        'status': 'active',
        'applicableActivities': <String>[],
        'applicableRisks': <String>[],
        'createdAt': Timestamp.now(),
        'updatedAt': Timestamp.now(),
      });

      await tester.pumpWidget(wrap(_FakeAdminService()));
      await tester.pumpAndSettle();

      expect(find.text('Ladder Safety'), findsOneWidget);
    });

    testWidgets('renders an existing point\'s Edit/Activate card without a '
        'layout exception', (tester) async {
      // A regression test for a bug where the card's Edit/Activate action
      // row used Row (which hands its children unbounded width) instead of
      // Wrap (used by every other card in this codebase — SitesScreen,
      // OrganizationsScreen, ProjectsScreen), causing
      // "BoxConstraints forces an infinite width" as soon as any point
      // existed to render a card for. This crashed the whole screen before
      // the Add button could even be tapped.
      await firestore
          .doc('organizations/org-alpha/safety_meeting_points/point-1')
          .set({
        'organizationId': 'org-alpha',
        'title': 'Ladder Safety',
        'category': 'Safety',
        'status': 'active',
        'applicableActivities': <String>[],
        'applicableRisks': <String>[],
        'createdAt': Timestamp.now(),
        'updatedAt': Timestamp.now(),
      });

      await tester.pumpWidget(wrap(_FakeAdminService()));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.widgetWithText(OutlinedButton, 'Edit'), findsOneWidget);
      expect(
        find.widgetWithText(OutlinedButton, 'Deactivate'),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('Add meeting point'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Add Meeting Point'), findsOneWidget);
    });
  });
}
