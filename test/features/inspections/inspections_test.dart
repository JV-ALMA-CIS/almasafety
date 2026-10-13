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
import 'package:jva_safety/features/inspections/data/inspection_repository.dart';
import 'package:jva_safety/features/inspections/data/inspection_service.dart';
import 'package:jva_safety/features/inspections/domain/inspection.dart';
import 'package:jva_safety/features/inspections/presentation/inspection_run_screen.dart';
import 'package:jva_safety/features/inspections/presentation/inspections_screen.dart';
import 'package:jva_safety/features/organizations/data/site_repository.dart';

class _Session extends SessionController {
  _Session(this.role);

  final AppRole role;
  final String uid = 'manager-1';

  @override
  UserProfile? get profile => UserProfile(
    uid: uid,
    name: 'Test',
    email: 't@example.com',
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

/// Records calls and mirrors answers into the fake database, like the
/// real callables would.
class _FakeService extends InspectionService {
  _FakeService(this.firestore);

  final FakeFirebaseFirestore firestore;
  int installs = 0;
  int submits = 0;
  final signOffs = <String>[];

  @override
  Future<int> installDefaultTemplates(
    String organizationId, {
    List<String>? keys,
  }) async {
    installs++;
    return 2;
  }

  @override
  Future<void> recordItem({
    required String organizationId,
    required String inspectionId,
    required String itemId,
    required InspectionResult? result,
    String? note,
    String? photoUrl,
  }) async {
    final ref = firestore.doc('organizations/org/inspections/$inspectionId');
    final items = [
      for (final raw in ((await ref.get()).data()!['items'] as List))
        Map<String, dynamic>.from(raw as Map),
    ];
    for (final item in items) {
      if (item['id'] == itemId) {
        item['result'] = result?.id;
        item['note'] = note;
        item['photoUrl'] = photoUrl;
      }
    }
    await ref.update({'items': items});
  }

  @override
  Future<int> submit({
    required String organizationId,
    required String inspectionId,
  }) async {
    submits++;
    await firestore.doc('organizations/org/inspections/$inspectionId').update({
      'status': 'submitted',
    });
    return 1;
  }

  @override
  Future<void> signOff({
    required String organizationId,
    required String inspectionId,
    String? note,
  }) async => signOffs.add(inspectionId);
}

void main() {
  late FakeFirebaseFirestore firestore;
  late InspectionRepository repository;

  setUp(() {
    firestore = FakeFirebaseFirestore();
    repository = InspectionRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org',
    );
  });

  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<void> seedInspection({
    String status = 'inProgress',
    String inspector = 'manager-1',
  }) async {
    Map<String, Object?> item(String id, String text) => {
      'id': id,
      'section': 'Daily checks',
      'text': text,
      'result': status == 'inProgress' ? null : 'ok',
      'note': null,
      'photoUrl': null,
      'hazardId': null,
    };
    await firestore.doc('organizations/org/inspections/i1').set({
      'organizationId': 'org',
      'siteId': 'site-1',
      'siteName': 'Rosslyn Ridge',
      'templateId': 't1',
      'templateName': 'Daily site inspection',
      'kind': 'daily',
      'items': [
        item('d1', 'Everyone wears PPE'),
        item('d2', 'Fall protection'),
      ],
      'status': status,
      'inspectorUid': inspector,
      'inspectorName': 'Fred Foreman',
      'okCount': status == 'inProgress' ? 0 : 2,
      'notOkCount': 0,
      'naCount': 0,
      'startedAt': Timestamp.now(),
    });
  }

  Widget host(Widget child, {AppRole role = AppRole.siteManager}) =>
      ChangeNotifierProvider<SessionController>(
        create: (_) => _Session(role),
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute<bool>(builder: (_) => child)),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

  group('carrying out an inspection', () {
    testWidgets('submit stays locked until every item is answered and each '
        'Not OK has a note', (tester) async {
      tall(tester);
      await seedInspection();
      final service = _FakeService(firestore);
      await tester.pumpWidget(
        host(
          InspectionRunScreen(
            organizationId: 'org',
            inspectionId: 'i1',
            repository: repository,
            service: service,
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      FilledButton submit() => tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('Submit'),
          matching: find.byWidgetPredicate((w) => w is FilledButton),
        ),
      );

      expect(find.text('0 / 2 answered'), findsOneWidget);
      expect(submit().onPressed, isNull);

      await tester.tap(find.text('✅ OK').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('❌ Not OK').last);
      await tester.pumpAndSettle();

      expect(find.text('2 / 2 answered'), findsOneWidget);
      expect(find.text('1 Not OK need a note'), findsOneWidget);
      expect(submit().onPressed, isNull);

      await tester.enterText(
        find.widgetWithText(TextField, 'What is wrong? (required)'),
        'Two roofers not tied off',
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(submit().onPressed, isNotNull);

      await tester.tap(find.text('Submit'));
      await tester.pumpAndSettle();
      expect(find.textContaining('1 deficiency will be recorded'), findsOne);
      await tester.tap(find.widgetWithText(FilledButton, 'Submit').last);
      await tester.pumpAndSettle();
      expect(service.submits, 1);
    });
  });

  group('Inspections page', () {
    Widget page(AppRole role, _FakeService service) =>
        ChangeNotifierProvider<SessionController>(
          create: (_) => _Session(role),
          child: MaterialApp(
            home: Scaffold(
              body: InspectionsScreen(repository: repository, service: service),
            ),
          ),
        );

    testWidgets('a Site Manager with no checklists can install the '
        'standard ones', (tester) async {
      tall(tester);
      final service = _FakeService(firestore);
      await tester.pumpWidget(page(AppRole.siteManager, service));
      await tester.pumpAndSettle();

      expect(find.text('No checklists yet'), findsOneWidget);
      await tester.tap(find.text('Install standard checklists'));
      await tester.pumpAndSettle();
      expect(service.installs, 1);
    });

    testWidgets('a Foreman without checklists is told to ask their Site '
        'Manager', (tester) async {
      tall(tester);
      await tester.pumpWidget(page(AppRole.foreman, _FakeService(firestore)));
      await tester.pumpAndSettle();
      expect(find.textContaining('Ask your Site Manager'), findsOneWidget);
      expect(find.text('Install standard checklists'), findsNothing);
    });

    testWidgets('a Worker cannot use inspections', (tester) async {
      await tester.pumpWidget(page(AppRole.worker, _FakeService(firestore)));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('carried out by Foremen and Site Managers'),
        findsOneWidget,
      );
    });

    testWidgets('another manager can sign off a submitted inspection', (
      tester,
    ) async {
      tall(tester);
      await seedInspection(status: 'submitted', inspector: 'foreman-1');
      final service = _FakeService(firestore);
      await tester.pumpWidget(page(AppRole.siteManager, service));
      await tester.pumpAndSettle();

      expect(find.text('Awaiting sign-off'), findsWidgets);
      await tester.tap(find.text('Review & sign off'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sign off').first);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, 'Sign off'),
        ),
      );
      await tester.pumpAndSettle();
      expect(service.signOffs, ['i1']);
    });

    testWidgets('the inspector cannot sign off their own inspection', (
      tester,
    ) async {
      tall(tester);
      await seedInspection(status: 'submitted', inspector: 'manager-1');
      await tester.pumpWidget(
        page(AppRole.siteManager, _FakeService(firestore)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Review & sign off'), findsNothing);
    });
  });

  testWidgets('a checklist used only at other sites is not offered', (
    tester,
  ) async {
    tall(tester);
    await firestore.doc('organizations/org/sites/site-1').set({
      'organizationId': 'org',
      'projectId': 'project-1',
      'name': 'Italian Embassy',
      'code': 'EMB',
      'status': 'active',
    });
    Map<String, Object?> template(String name, List<String> siteIds) => {
      'organizationId': 'org',
      'name': name,
      'kind': 'daily',
      'status': 'active',
      'siteIds': siteIds,
      'sections': [
        {
          'title': 'A',
          'items': [
            {'id': 'a1', 'text': 'Check', 'hazardCategory': 'other'},
          ],
        },
      ],
    };
    await firestore
        .doc('organizations/org/inspection_templates/general')
        .set(template('Daily site inspection', const []));
    await firestore
        .doc('organizations/org/inspection_templates/roof')
        .set(template('Roof work inspection', const ['site-rosslyn']));

    await tester.pumpWidget(
      ChangeNotifierProvider<SessionController>(
        create: (_) => _Session(AppRole.foreman),
        child: MaterialApp(
          home: Scaffold(
            body: InspectionsScreen(
              repository: repository,
              service: _FakeService(firestore),
              siteRepository: SiteRepository(
                firestoreService: FirestoreService(firestore: firestore),
                organizationId: 'org',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start inspection'));
    await tester.pumpAndSettle();

    // The Foreman's one site is chosen for them.
    expect(find.text('Daily site inspection'), findsOneWidget);
    expect(find.text('Roof work inspection'), findsNothing);
  });
}
