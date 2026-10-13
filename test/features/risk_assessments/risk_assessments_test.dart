import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/features/activities/domain/activity.dart';
import 'package:jva_safety/features/organizations/domain/organization_record_status.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/membership.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/organizations/data/site_repository.dart';
import 'package:jva_safety/features/risk_assessments/data/risk_assessment_repository.dart';
import 'package:jva_safety/features/risk_assessments/data/risk_assessment_service.dart';
import 'package:jva_safety/features/risk_assessments/domain/aha_text.dart';
import 'package:jva_safety/features/risk_assessments/domain/risk_assessment.dart';
import 'package:jva_safety/features/risk_assessments/domain/standard_ahas.dart';
import 'package:jva_safety/features/risk_assessments/presentation/risk_assessment_editor_screen.dart';
import 'package:jva_safety/features/risk_assessments/presentation/risk_assessments_screen.dart';

class _Session extends SessionController {
  _Session(this.role);

  final AppRole role;

  @override
  UserProfile? get profile => const UserProfile(
    uid: 'me',
    name: 'Eston',
    email: 'e@example.com',
    accountStatus: AccountStatus.active,
  );

  @override
  String? get activeOrganizationId => 'org';

  @override
  Membership? get activeMembership => Membership(
    organizationId: 'org',
    role: role,
    siteIds: const ['site-1'],
    status: MembershipStatus.active,
  );
}

/// Records calls and writes what the real callables would into the fake
/// database.
class _FakeService extends RiskAssessmentService {
  _FakeService(this.firestore);

  final FakeFirebaseFirestore firestore;
  final saved = <AhaContent>[];
  final savedSiteIds = <String?>[];
  final savedActivityIds = <List<String>>[];
  final accepted = <String>[];
  final revised = <String>[];

  @override
  Future<String> save({
    required String organizationId,
    String? id,
    String? siteId,
    List<String> activityIds = const [],
    required AhaContent content,
  }) async {
    saved.add(content);
    savedActivityIds.add(activityIds);
    savedSiteIds.add(siteId);
    final newId = id ?? 'new-aha';
    await firestore.doc('organizations/org/risk_assessments/$newId').set({
      'organizationId': 'org',
      'siteId': siteId ?? 'site-1',
      'siteName': 'Rosslyn Ridge',
      'featureOfWork': content.featureOfWork,
      'steps': [for (final s in content.steps) s.toJson()],
      'equipment': content.equipment,
      'inspectionRequirements': content.inspectionRequirements,
      'trainingRequirements': content.trainingRequirements,
      'status': 'draft',
      'revision': 1,
      'preparedByUid': 'me',
      'preparedByName': 'Eston',
    });
    return newId;
  }

  @override
  Future<void> accept({
    required String organizationId,
    required String id,
    String? corName,
    String? note,
  }) async => accepted.add('$id|$corName');

  @override
  Future<String> revise({
    required String organizationId,
    required String id,
  }) async {
    revised.add(id);
    await firestore.doc('organizations/org/risk_assessments/rev-2').set({
      'organizationId': 'org',
      'siteId': 'site-1',
      'featureOfWork': 'Removals (revised)',
      'status': 'draft',
      'revision': 2,
      'previousId': id,
      'preparedByUid': 'me',
    });
    return 'rev-2';
  }
}

Activity _activity(String id, String name) => Activity(
  id: id,
  organizationId: 'org',
  projectId: 'project-1',
  siteId: 'site-1',
  name: name,
  code: name.substring(0, 3).toUpperCase(),
  status: OrganizationRecordStatus.active,
);

Future<List<Activity>> _loadActivities(String org, String site) async => [
  _activity('roofing', 'Roofing'),
  _activity('painting', 'Painting'),
];

void main() {
  late FakeFirebaseFirestore firestore;
  late RiskAssessmentRepository repository;
  late SiteRepository siteRepository;
  late _FakeService service;

  setUp(() async {
    firestore = FakeFirebaseFirestore();
    final firestoreService = FirestoreService(firestore: firestore);
    repository = RiskAssessmentRepository(
      firestoreService: firestoreService,
      organizationId: 'org',
    );
    siteRepository = SiteRepository(
      firestoreService: firestoreService,
      organizationId: 'org',
    );
    service = _FakeService(firestore);
    await firestore.doc('organizations/org/sites/site-1').set({
      'organizationId': 'org',
      'projectId': 'project-1',
      'name': 'Rosslyn Ridge',
      'code': 'RR',
      'status': 'active',
    });
  });

  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(900, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<void> seed(
    String id, {
    String status = 'accepted',
    String siteId = 'site-1',
    String preparedBy = 'giuseppe',
    String feature = 'Removals',
    List<String> training = const ['Fall protection'],
  }) {
    return firestore.doc('organizations/org/risk_assessments/$id').set({
      'organizationId': 'org',
      'siteId': siteId,
      'siteName': 'Rosslyn Ridge',
      'featureOfWork': feature,
      'steps': [
        {
          'id': 's1',
          'step': 'Remove roof sheets',
          'hazards': ['Falls from the roof edge'],
          'controls': ['Harness tied off'],
        },
      ],
      'equipment': ['Scaffold'],
      'inspectionRequirements': ['Scaffold inspected daily'],
      'trainingRequirements': training,
      'status': status,
      'revision': 1,
      'preparedByUid': preparedBy,
      'preparedByName': preparedBy == 'me' ? 'Eston' : 'Giuseppe',
    });
  }

  Widget page(AppRole role) => ChangeNotifierProvider<SessionController>(
    create: (_) => _Session(role),
    child: MaterialApp(
      home: Scaffold(
        body: RiskAssessmentsScreen(
          repository: repository,
          service: service,
          siteRepository: siteRepository,
          loadActivities: _loadActivities,
        ),
      ),
    ),
  );

  group('content', () {
    test('both standard drafts are complete enough to be accepted', () {
      expect(
        standardAhas.map((a) => a.content.featureOfWork),
        containsAll(['Removals', 'Roof construction', 'Scaffolding']),
      );
      for (final draft in standardAhas) {
        final aha = draft.content;
        expect(aha.missingForAcceptance, isEmpty, reason: aha.featureOfWork);
      }
    });

    test('lists are typed one per line; blank lines are ignored', () {
      expect(splitLines(' Scaffold \n\n  Harness\n'), ['Scaffold', 'Harness']);
    });
  });

  group('the list', () {
    testWidgets('a Worker sees only accepted AHAs for their own sites', (
      tester,
    ) async {
      tall(tester);
      await seed('a1');
      await seed('a2', status: 'draft', feature: 'Draft one');
      await seed('a3', siteId: 'site-2', feature: 'Other site');
      await tester.pumpWidget(page(AppRole.worker));
      await tester.pumpAndSettle();

      expect(find.text('Removals'), findsOneWidget);
      expect(find.text('Draft one'), findsNothing);
      expect(find.text('Other site'), findsNothing);
      expect(find.text('Prepare AHA'), findsNothing);
    });

    testWidgets('a Site Manager sees drafts too and can prepare one', (
      tester,
    ) async {
      tall(tester);
      await seed('a2', status: 'draft', feature: 'Draft one');
      await tester.pumpWidget(page(AppRole.siteManager));
      await tester.pumpAndSettle();
      expect(find.text('Drafts — waiting to be accepted'), findsOneWidget);
      expect(find.text('Draft one'), findsOneWidget);
      expect(find.text('Prepare AHA'), findsOneWidget);
    });

    testWidgets('preparing from the standard Removals draft', (tester) async {
      tall(tester);
      await tester.pumpWidget(page(AppRole.siteManager));
      await tester.pumpAndSettle();
      expect(find.text('No risk assessments yet'), findsOneWidget);

      await tester.tap(find.text('Prepare AHA'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Removals — roofing starting draft'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      // Prefilled; with one site, it is chosen automatically.
      expect(find.widgetWithText(TextField, 'Removals'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Save draft'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Save draft'));
      await tester.pumpAndSettle();

      expect(service.savedSiteIds, ['site-1']);
      // Nothing chosen = the whole site.
      expect(service.savedActivityIds, [<String>[]]);
      final saved = service.saved.single;
      expect(saved.featureOfWork, 'Removals');
      expect(
        saved.steps,
        hasLength(
          standardAhas
              .firstWhere((a) => a.content.featureOfWork == 'Removals')
              .content
              .steps
              .length,
        ),
      );
      expect(saved.missingForAcceptance, isEmpty);
      // Opens the new draft.
      expect(find.text('Draft — not yet accepted'), findsWidgets);
    });
  });

  group('the AHA', () {
    Future<void> open(WidgetTester tester, AppRole role) async {
      tall(tester);
      await tester.pumpWidget(page(role));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Removals'));
      await tester.pumpAndSettle();
    }

    FilledButton acceptButton(WidgetTester tester) =>
        tester.widget(find.widgetWithText(FilledButton, 'Accept'));

    testWidgets('shows each step with its hazards and controls', (
      tester,
    ) async {
      await seed('a1');
      await open(tester, AppRole.worker);
      expect(find.text('Remove roof sheets'), findsOneWidget);
      expect(find.text('Falls from the roof edge'), findsOneWidget);
      expect(find.text('Harness tied off'), findsOneWidget);
      expect(find.text('Start a revision'), findsNothing);
    });

    testWidgets('the preparer cannot accept their own draft', (tester) async {
      await seed('a1', status: 'draft', preparedBy: 'me');
      await open(tester, AppRole.siteManager);
      expect(acceptButton(tester).onPressed, isNull);
      expect(
        find.textContaining('another Site Manager or Admin must accept'),
        findsOneWidget,
      );
    });

    testWidgets('an incomplete draft says what is missing', (tester) async {
      await seed('a1', status: 'draft', training: const []);
      await open(tester, AppRole.siteManager);
      expect(acceptButton(tester).onPressed, isNull);
      expect(
        find.textContaining('add the training requirements'),
        findsOneWidget,
      );
    });

    testWidgets("another manager accepts it, noting the COR", (tester) async {
      await seed('a1', status: 'draft');
      await open(tester, AppRole.siteManager);
      await tester.tap(find.widgetWithText(FilledButton, 'Accept'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Reviewed by COR (optional)'),
        'J. Smith',
      );
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, 'Accept'),
        ),
      );
      await tester.pumpAndSettle();
      expect(service.accepted, ['a1|J. Smith']);
    });

    testWidgets('an accepted AHA is revised as a new draft', (tester) async {
      await seed('a1');
      await open(tester, AppRole.siteManager);
      await tester.tap(find.text('Start a revision'));
      await tester.pumpAndSettle();
      expect(service.revised, ['a1']);
      expect(find.text('Removals (revised)'), findsOneWidget);
      expect(find.text('Revision 2'), findsOneWidget);
    });
  });

  group('other sites and activities', () {
    testWidgets('an AHA can be limited to some of the site\'s activities', (
      tester,
    ) async {
      tall(tester);
      await tester.pumpWidget(page(AppRole.siteManager));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prepare AHA'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Blank form'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.text('Whole site'), findsOneWidget);
      await tester.tap(find.text('Painting'));
      await tester.enterText(
        find.widgetWithText(TextField, 'Phase / feature of work (required)'),
        'Interior painting',
      );
      await tester.scrollUntilVisible(
        find.text('Add a step'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Add a step'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'What is done'),
        'Paint walls',
      );
      await tester.scrollUntilVisible(
        find.text('Save draft'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Save draft'));
      await tester.pumpAndSettle();

      expect(service.savedActivityIds, [
        ['painting'],
      ]);
      expect(service.saved.single.featureOfWork, 'Interior painting');
    });

    testWidgets("another site's accepted AHA can be copied as a start", (
      tester,
    ) async {
      tall(tester);
      await seed('a1', siteId: 'site-2', feature: 'Scaffolding');
      await tester.pumpWidget(page(AppRole.siteManager));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prepare AHA'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy: Scaffolding (Rosslyn Ridge)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextField, 'Scaffolding'), findsOneWidget);
      expect(
        find.widgetWithText(TextField, 'Remove roof sheets'),
        findsOneWidget,
      );
    });

    test('per activity: only the activities worked today need an AHA', () {
      RiskAssessment aha(String id, List<String> activities) =>
          RiskAssessment.fromMap(id, {
            'siteId': 'site-1',
            'status': 'accepted',
            'featureOfWork': id,
            'activityIds': activities,
          });
      final roof = aha('roof', ['roofing']);
      final paint = aha('paint', ['painting']);
      final site = aha('site', []);

      expect(
        activitiesNeedingAha(
          siteAhas: [roof],
          activityIds: ['painting'],
          coveredIds: [],
        ),
        isEmpty,
      );
      expect(
        activitiesNeedingAha(
          siteAhas: [roof, paint],
          activityIds: ['roofing', 'painting'],
          coveredIds: ['roof'],
        ),
        ['painting'],
      );
      expect(
        activitiesNeedingAha(
          siteAhas: [roof, site],
          activityIds: ['roofing', 'painting'],
          coveredIds: ['site'],
        ),
        isEmpty,
      );
    });
  });

  group('pasting an AHA', () {
    test('steps, their hazards and controls, and the three lists', () {
      final parsed = parseAhaText(
        'Feature of work: Interior painting\n'
        'Activity: Painting the residence\n'
        '1. Erect scaffold\n'
        'Hazards:\n'
        '- Falls from height\n'
        '• Scaffold collapse\n'
        'Controls: Guardrails on open sides\n'
        '- Inspected before each shift\n'
        '\n'
        'Step 2: Paint walls\n'
        'and ceilings\n'
        'Potential hazards:\n'
        '- Paint fumes\n'
        'Recommended controls:\n'
        '- Ventilation\n'
        'Equipment to be used:\n'
        '- Scaffold\n'
        '- Rollers and brushes\n'
        'Inspection requirements:\n'
        '- Scaffold tagged daily\n'
        'Training requirements:\n'
        '- Working at height\n',
      );
      expect(parsed.featureOfWork, 'Interior painting');
      expect(parsed.activity, 'Painting the residence');
      expect(parsed.steps.map((s) => s.step), [
        'Erect scaffold',
        'Paint walls and ceilings',
      ]);
      expect(parsed.steps.first.hazards, [
        'Falls from height',
        'Scaffold collapse',
      ]);
      expect(parsed.steps.first.controls, [
        'Guardrails on open sides',
        'Inspected before each shift',
      ]);
      expect(parsed.steps.last.hazards, ['Paint fumes']);
      expect(parsed.steps.last.controls, ['Ventilation']);
      expect(parsed.equipment, ['Scaffold', 'Rollers and brushes']);
      expect(parsed.inspectionRequirements, ['Scaffold tagged daily']);
      expect(parsed.trainingRequirements, ['Working at height']);
    });

    test('a plain list with no headings becomes the steps', () {
      final parsed = parseAhaText('Set up\nDo the work\nClean up');
      expect(parsed.steps.map((s) => s.step), [
        'Set up',
        'Do the work',
        'Clean up',
      ]);
    });

    testWidgets('pasting into a blank form fills it in', (tester) async {
      tall(tester);
      await tester.pumpWidget(page(AppRole.siteManager));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prepare AHA'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Blank form'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Paste an AHA'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Paste an AHA'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'Feature of work: Interior painting\n'
        '1. Paint walls\nHazards:\n- Fumes\nControls:\n- Ventilation\n'
        'Equipment:\n- Rollers\n'
        'Inspection requirements:\n- Daily check\n'
        'Training requirements:\n- Briefing',
      );
      await tester.pump();
      expect(
        find.textContaining('1 step, 1 hazard, 1 control'),
        findsOneWidget,
      );
      await tester.tap(find.text('Add to AHA'));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Save draft'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Save draft'));
      await tester.pumpAndSettle();

      final saved = service.saved.single;
      expect(saved.featureOfWork, 'Interior painting');
      expect(saved.steps.single.step, 'Paint walls');
      expect(saved.steps.single.hazards, ['Fumes']);
      expect(saved.equipment, ['Rollers']);
      expect(saved.missingForAcceptance, isEmpty);
    });

    testWidgets('a draft can be copied too', (tester) async {
      tall(tester);
      await seed('d1', status: 'draft', feature: 'Plumbing');
      await tester.pumpWidget(page(AppRole.siteManager));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prepare AHA'));
      await tester.pumpAndSettle();
      expect(find.text('Copy: Plumbing (Rosslyn Ridge)'), findsOneWidget);
      // The library offers general drafts as well as the roofing ones.
      await tester.scrollUntilVisible(
        find.text('Scaffolding — starting draft'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Scaffolding — starting draft'), findsOneWidget);
    });
  });
}
