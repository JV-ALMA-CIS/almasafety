import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/core/widgets/choice_list.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/activities/data/activity_repository.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/organizations/data/project_repository.dart';
import 'package:jva_safety/features/organizations/data/site_repository.dart';
import 'package:jva_safety/features/organizations/domain/organization.dart';
import 'package:jva_safety/features/organizations/domain/organization_record_status.dart';
import 'package:jva_safety/features/safety_learning/data/safety_learning_repository.dart';
import 'package:jva_safety/features/safety_requirements/data/safety_requirement_admin_service.dart';
import 'package:jva_safety/features/safety_requirements/data/safety_requirement_repository.dart';
import 'package:jva_safety/features/safety_requirements/domain/safety_requirement_risk.dart';
import 'package:jva_safety/features/safety_requirements/domain/safety_requirement.dart';
import 'package:jva_safety/features/safety_requirements/presentation/safety_requirements_screen.dart';

/// A fake admin service, subclassing the real one rather than mocking — the
/// repo's established pattern (see safety_meeting_points_screen_test.dart's
/// `_FakeAdminService`).
class _FakeAdminService extends SafetyRequirementAdminService {
  final List<Map<String, Object?>> createCalls = [];

  @override
  Future<String> createSafetyRequirement({
    required String organizationId,
    required String name,
    required String category,
    required SafetyRequirementRisk risk,
    String? description,
    List<String> requiredLearningIds = const [],
    OrganizationRecordStatus status = OrganizationRecordStatus.active,
    bool gatesAttendance = true,
    bool requiredBeforeWork = false,
    Map<String, RequirementLearningSetting>? learningSettings,
    String? projectId,
    String? siteId,
    String? activityId,
  }) async {
    createCalls.add({
      'organizationId': organizationId,
      'name': name,
      'requiredLearningIds': requiredLearningIds,
      'learningSettings': _flatten(learningSettings),
      'projectId': projectId,
      'siteId': siteId,
      'activityId': activityId,
    });
    return 'new-requirement-id';
  }

  final List<Map<String, Object?>> updateCalls = [];

  @override
  Future<void> updateSafetyRequirement(
    String organizationId,
    String id, {
    String? name,
    String? category,
    SafetyRequirementRisk? risk,
    String? description,
    List<String>? requiredLearningIds,
    OrganizationRecordStatus? status,
    bool? gatesAttendance,
    bool? requiredBeforeWork,
    Map<String, RequirementLearningSetting>? learningSettings,
    String? projectId,
    String? siteId,
    String? activityId,
  }) async {
    updateCalls.add({
      'id': id,
      'name': name,
      'requiredLearningIds': requiredLearningIds,
      'gatesAttendance': gatesAttendance,
      'requiredBeforeWork': requiredBeforeWork,
      'learningSettings': _flatten(learningSettings),
    });
  }

  /// `{id: [gatesAttendance, requiredBeforeWork]}` — easy to compare.
  static Map<String, List<bool?>>? _flatten(
    Map<String, RequirementLearningSetting>? settings,
  ) => settings == null
      ? null
      : {
          for (final entry in settings.entries)
            entry.key: [
              entry.value.gatesAttendance,
              entry.value.requiredBeforeWork,
            ],
        };
}

class _FakeSession extends SessionController {
  _FakeSession()
    : _profile = UserProfile(
        uid: 'admin-uid',
        name: 'Admin',
        email: 'admin@example.com',
        accountStatus: AccountStatus.active,
        platformRole: AppRole.admin,
      );

  final UserProfile _profile;

  @override
  UserProfile? get profile => _profile;

  @override
  String? get activeOrganizationId => 'org-alpha';
}

void main() {
  late FakeFirebaseFirestore firestore;
  late _FakeAdminService adminService;

  setUp(() {
    firestore = FakeFirebaseFirestore();
    adminService = _FakeAdminService();
  });

  Future<void> seedProject(
    String id, {
    String name = 'Project Alpha',
    String status = 'active',
  }) async {
    await firestore.doc('organizations/org-alpha/projects/$id').set({
      'organizationId': 'org-alpha',
      'name': name,
      'code': 'CODE-$id',
      'status': status,
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  Future<void> seedSite(
    String id, {
    String name = 'North Yard',
    String projectId = 'project-1',
    String status = 'active',
  }) async {
    await firestore.doc('organizations/org-alpha/sites/$id').set({
      'organizationId': 'org-alpha',
      'projectId': projectId,
      'name': name,
      'code': 'CODE-$id',
      'status': status,
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  Widget wrap() {
    return ChangeNotifierProvider<SessionController>(
      create: (_) => _FakeSession(),
      child: MaterialApp(
        home: Scaffold(
          body: SafetyRequirementsScreen(
            organization: const Organization(
              id: 'org-alpha',
              name: 'JV Alma CIS',
              code: 'CODE-org-alpha',
              status: OrganizationRecordStatus.active,
            ),
            adminService: adminService,
            learningRepository: SafetyLearningRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: 'org-alpha',
            ),
            repository: SafetyRequirementRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: 'org-alpha',
            ),
            projectRepository: ProjectRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: 'org-alpha',
            ),
            siteRepository: SiteRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: 'org-alpha',
            ),
            activityRepository: ActivityRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: 'org-alpha',
            ),
          ),
        ),
      ),
    );
  }

  /// Taps [optionText] in the "Applies to" choice list — every option is
  /// listed on the form, so there is no menu to open first.
  Future<void> selectApplyTo(WidgetTester tester, String optionText) async {
    // Leave any text field first, so its focus can't scroll the form away.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(optionText).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(optionText).last);
    await tester.pumpAndSettle();
  }

  /// Taps [optionText] in the currently shown Project/Site/Activity list.
  Future<void> selectScopedValue(WidgetTester tester, String optionText) async {
    // Leave any text field first, so its focus can't scroll the form away.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(optionText).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(optionText).last);
    await tester.pumpAndSettle();
  }

  group('SafetyRequirementsScreen (scope picker)', () {
    testWidgets('offers a Project option alongside Whole organization, '
        'One site and One activity', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Add requirement'));
      await tester.pumpAndSettle();

      expect(find.text('Whole organization'), findsOneWidget);
      expect(find.text('One project'), findsOneWidget);
      expect(find.text('One site'), findsOneWidget);
      expect(find.text('One activity'), findsOneWidget);
    });

    testWidgets('the Site list excludes an inactive site', (tester) async {
      await seedSite('site-active', name: 'Active Site');
      await seedSite('site-inactive', name: 'Retired Site', status: 'inactive');

      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Add requirement'));
      await tester.pumpAndSettle();
      await selectApplyTo(tester, 'One site');

      expect(find.text('Active Site'), findsWidgets);
      expect(find.text('Retired Site'), findsNothing);
    });

    testWidgets('the Site list labels each site with its project, to '
        'disambiguate same-named sites across different projects', (
      tester,
    ) async {
      await seedProject('project-1', name: 'Project Alpha');
      await seedProject('project-2', name: 'Project Beta');
      await seedSite('site-1', name: 'Main Site', projectId: 'project-1');
      await seedSite('site-2', name: 'Main Site', projectId: 'project-2');

      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Add requirement'));
      await tester.pumpAndSettle();
      await selectApplyTo(tester, 'One site');

      // Both are "Main Site"; the line under each names its project.
      expect(find.text('Main Site'), findsNWidgets(2));
      expect(find.text('Project Alpha'), findsOneWidget);
      expect(find.text('Project Beta'), findsOneWidget);
    });

    testWidgets('creating a project-scoped requirement passes projectId, '
        'and nothing else, to the admin service', (tester) async {
      await seedProject('project-1', name: 'Project Alpha');

      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Add requirement'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'),
        'Site Induction',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Category'),
        'Induction',
      );
      await selectApplyTo(tester, 'One project');
      await selectScopedValue(tester, 'Project Alpha');
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(adminService.createCalls, hasLength(1));
      expect(adminService.createCalls.single['projectId'], 'project-1');
      expect(adminService.createCalls.single['siteId'], isNull);
      expect(adminService.createCalls.single['activityId'], isNull);
    });
  });

  group('SafetyRequirementsScreen (per-lesson settings)', () {
    Future<void> seedLesson(String id) async {
      await firestore.doc('organizations/org-alpha/safety_learning/$id').set({
        'organizationId': 'org-alpha',
        'title': 'Lesson $id',
        'type': 'document',
        'contentReference': 'ref-$id',
        'status': 'active',
        'createdAt': Timestamp.now(),
        'updatedAt': Timestamp.now(),
      });
    }

    Future<void> seedRequirement({
      required List<String> lessons,
      bool? gatesAttendance,
      bool? requiredBeforeWork,
      Map<String, Map<String, bool>>? learningSettings,
    }) async {
      await firestore
          .doc('organizations/org-alpha/safety_requirements/r1')
          .set({
            'organizationId': 'org-alpha',
            'name': 'Working at Height',
            'category': 'Height',
            'risk': 'high',
            'status': 'active',
            'requiredLearningIds': lessons,
            'gatesAttendance': ?gatesAttendance,
            'requiredBeforeWork': ?requiredBeforeWork,
            'learningSettings': ?learningSettings,
          });
    }

    /// A tall phone-sized window, so the dialog's lesson list fits without
    /// depending on scroll positions.
    void useTallWindow(WidgetTester tester) {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    Future<void> openCreate(WidgetTester tester) async {
      useTallWindow(tester);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Add requirement'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'),
        'Working at Height',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Category'),
        'Height',
      );
    }

    Future<void> openEdit(WidgetTester tester) async {
      useTallWindow(tester);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
    }

    Future<void> tapVisible(WidgetTester tester, Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    Future<void> tick(WidgetTester tester, String lessonId) =>
        tapVisible(tester, find.widgetWithText(ChoiceTile, 'Lesson $lessonId'));

    Future<void> toggleGate(WidgetTester tester, String lessonId) =>
        tapVisible(tester, find.byKey(Key('blocks-attendance-$lessonId')));

    Future<void> togglePreWork(WidgetTester tester, String lessonId) =>
        tapVisible(tester, find.byKey(Key('required-before-work-$lessonId')));

    bool switchValue(WidgetTester tester, String key) =>
        tester.widget<SwitchListTile>(find.byKey(Key(key))).value;

    testWidgets('explains the settings are per lesson, and has no '
        'requirement-wide urgency switches', (tester) async {
      await openCreate(tester);

      expect(
        find.textContaining('within this requirement only'),
        findsOneWidget,
      );
      expect(find.text('Blocks attendance until completed'), findsNothing);
      expect(find.textContaining('optional'), findsNothing);
    });

    testWidgets('switches appear only under ticked lessons, and a newly '
        'ticked lesson starts with both off', (tester) async {
      await seedLesson('l1');
      await seedLesson('l2');
      await openCreate(tester);

      expect(find.byKey(const Key('blocks-attendance-l1')), findsNothing);

      await tick(tester, 'l1');

      expect(switchValue(tester, 'blocks-attendance-l1'), isFalse);
      expect(switchValue(tester, 'required-before-work-l1'), isFalse);
      expect(find.byKey(const Key('blocks-attendance-l2')), findsNothing);

      await tapVisible(tester, find.text('Create'));

      expect(adminService.createCalls.single['learningSettings'], {
        'l1': [false, false],
      });
    });

    testWidgets('each lesson can take a different combination', (tester) async {
      for (final id in ['l1', 'l2', 'l3', 'l4']) {
        await seedLesson(id);
      }
      await openCreate(tester);
      for (final id in ['l1', 'l2', 'l3', 'l4']) {
        await tick(tester, id);
      }
      await toggleGate(tester, 'l1');
      await togglePreWork(tester, 'l1');
      await toggleGate(tester, 'l2');
      await togglePreWork(tester, 'l3');

      await tapVisible(tester, find.text('Create'));

      final call = adminService.createCalls.single;
      expect(call['requiredLearningIds'], ['l1', 'l2', 'l3', 'l4']);
      expect(call['learningSettings'], {
        'l1': [true, true],
        'l2': [true, false],
        'l3': [false, true],
        'l4': [false, false],
      });
    });

    testWidgets('an older requirement pre-fills each lesson from its '
        'requirement-level flags, so saving unchanged keeps its behavior', (
      tester,
    ) async {
      await seedLesson('l1');
      await seedLesson('l2');
      await seedRequirement(lessons: ['l1', 'l2'], gatesAttendance: true);
      await openEdit(tester);

      expect(switchValue(tester, 'blocks-attendance-l1'), isTrue);
      expect(switchValue(tester, 'required-before-work-l1'), isFalse);

      await tapVisible(tester, find.text('Save'));

      final call = adminService.updateCalls.single;
      expect(call['learningSettings'], {
        'l1': [true, false],
        'l2': [true, false],
      });
      // Requirement-level fallbacks are left untouched.
      expect(call['gatesAttendance'], isNull);
      expect(call['requiredBeforeWork'], isNull);
    });

    testWidgets('changing, removing and adding lessons on a per-lesson '
        'requirement', (tester) async {
      for (final id in ['l1', 'l2', 'l3']) {
        await seedLesson(id);
      }
      await seedRequirement(
        lessons: ['l1', 'l2'],
        learningSettings: {
          'l1': {'gatesAttendance': true, 'requiredBeforeWork': false},
          'l2': {'gatesAttendance': true, 'requiredBeforeWork': true},
        },
      );
      await openEdit(tester);

      await togglePreWork(tester, 'l1');
      await tick(tester, 'l2'); // untick
      await tick(tester, 'l3'); // new lesson, defaults off

      await tapVisible(tester, find.text('Save'));

      final call = adminService.updateCalls.single;
      expect(call['requiredLearningIds'], ['l1', 'l3']);
      expect(call['learningSettings'], {
        'l1': [true, true],
        'l3': [false, false],
      });
    });

    testWidgets('an unrelated edit preserves every lesson setting', (
      tester,
    ) async {
      await seedLesson('l1');
      await seedRequirement(
        lessons: ['l1'],
        learningSettings: {
          'l1': {'gatesAttendance': false, 'requiredBeforeWork': true},
        },
      );
      await openEdit(tester);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'),
        'Working at Height (updated)',
      );

      await tapVisible(tester, find.text('Save'));

      final call = adminService.updateCalls.single;
      expect(call['name'], 'Working at Height (updated)');
      expect(call['learningSettings'], {
        'l1': [false, true],
      });
    });

    testWidgets('the requirement card summarizes per-lesson urgency', (
      tester,
    ) async {
      for (final id in ['l1', 'l2', 'l3']) {
        await seedLesson(id);
      }
      await seedRequirement(
        lessons: ['l1', 'l2', 'l3'],
        gatesAttendance: true,
        learningSettings: {
          'l1': {'gatesAttendance': true, 'requiredBeforeWork': true},
          'l2': {'gatesAttendance': false, 'requiredBeforeWork': true},
          'l3': {'gatesAttendance': false, 'requiredBeforeWork': false},
        },
      );
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      expect(find.text('Blocks attendance: 1 of 3 lessons'), findsOneWidget);
      expect(find.text('Before work: 2 of 3 lessons'), findsOneWidget);
    });
  });
}
