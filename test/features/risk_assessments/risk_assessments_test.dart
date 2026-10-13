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
import 'package:jva_safety/features/organizations/data/site_repository.dart';
import 'package:jva_safety/features/risk_assessments/data/risk_assessment_repository.dart';
import 'package:jva_safety/features/risk_assessments/data/risk_assessment_service.dart';
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
  final accepted = <String>[];
  final revised = <String>[];

  @override
  Future<String> save({
    required String organizationId,
    String? id,
    String? siteId,
    required AhaContent content,
  }) async {
    saved.add(content);
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
        ),
      ),
    ),
  );

  group('content', () {
    test('both standard drafts are complete enough to be accepted', () {
      expect(standardAhas.map((a) => a.featureOfWork), [
        'Removals',
        'Roof construction',
      ]);
      for (final aha in standardAhas) {
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
      await tester.tap(find.text('Removals — standard draft'));
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
      final saved = service.saved.single;
      expect(saved.featureOfWork, 'Removals');
      expect(saved.steps, hasLength(standardAhas.first.steps.length));
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
}
