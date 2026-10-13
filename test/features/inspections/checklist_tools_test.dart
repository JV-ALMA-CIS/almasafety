import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/features/inspections/data/inspection_repository.dart';
import 'package:jva_safety/features/inspections/data/inspection_service.dart';
import 'package:jva_safety/features/inspections/domain/checklist_text.dart';
import 'package:jva_safety/features/inspections/domain/inspection.dart';
import 'package:jva_safety/features/inspections/presentation/inspection_templates_screen.dart';
import 'package:jva_safety/features/organizations/data/site_repository.dart';

class _FakeService extends InspectionService {
  final saved = <({String? id, String name, List<TemplateSection> sections})>[];
  final installedKeys = <List<String>?>[];
  final library = {'daily-site-inspection': true, 'scaffolds-ladders': false};

  @override
  Future<String> saveTemplate({
    required String organizationId,
    String? templateId,
    required String name,
    required InspectionKind kind,
    String? description,
    required List<TemplateSection> sections,
    bool active = true,
    List<String> siteIds = const [],
  }) async {
    saved.add((id: templateId, name: name, sections: sections));
    return templateId ?? 'new';
  }

  @override
  Future<List<StandardChecklist>> listStandardTemplates(
    String organizationId,
  ) async => [
    for (final entry in library.entries)
      StandardChecklist(
        key: entry.key,
        name: entry.key == 'scaffolds-ladders'
            ? 'Scaffolds & ladders'
            : 'Daily site inspection',
        kind: InspectionKind.daily,
        description: 'Checks',
        core: entry.key == 'daily-site-inspection',
        itemCount: 10,
        installed: entry.value,
      ),
  ];

  @override
  Future<int> installDefaultTemplates(
    String organizationId, {
    List<String>? keys,
  }) async {
    installedKeys.add(keys);
    for (final key in keys ?? const <String>[]) {
      library[key] = true;
    }
    return keys?.length ?? 0;
  }
}

void main() {
  group('pasting a checklist', () {
    test('headings start sections; bullets and numbers are removed', () {
      final sections = parseChecklistText(
        '- PPE worn by everyone\n'
        '\n'
        'Scaffolds:\n'
        '1. Scaffold tagged by a competent person\n'
        '2) ☐ Guardrails on open sides\n'
        '# Electrical\n'
        '• GFCI on temporary power\n'
        '[ ] Cords not stapled or hung from nails\n',
      );
      expect(sections.map((s) => s.title), [
        'Checks',
        'Scaffolds',
        'Electrical',
      ]);
      expect(sections[1].items.map((i) => i.text), [
        'Scaffold tagged by a competent person',
        'Guardrails on open sides',
      ]);
      expect(sections[2].items.map((i) => i.text), [
        'GFCI on temporary power',
        'Cords not stapled or hung from nails',
      ]);
    });

    test('hazard categories are guessed from the wording', () {
      expect(guessHazardCategory('Scaffold tagged'), 'workingAtHeight');
      expect(guessHazardCategory('GFCI on temporary power'), 'electrical');
      expect(guessHazardCategory('Hard hats worn'), 'ppe');
      expect(guessHazardCategory('Fire extinguisher charged'), 'fire');
      expect(guessHazardCategory('Walkways clear'), 'housekeeping');
      expect(guessHazardCategory('Visitors signed in'), 'other');
      // Whole words only: "record" is not a cord, "clear" is not an ear.
      expect(guessHazardCategory('Training records up to date'), 'other');
    });
  });

  group('the checklists screen', () {
    late FakeFirebaseFirestore firestore;
    late InspectionRepository repository;
    late _FakeService service;

    setUp(() async {
      firestore = FakeFirebaseFirestore();
      repository = InspectionRepository(
        firestoreService: FirestoreService(firestore: firestore),
        organizationId: 'org',
      );
      service = _FakeService();
      await firestore.doc('organizations/org/inspection_templates/t1').set({
        'organizationId': 'org',
        'name': 'Daily site inspection',
        'kind': 'daily',
        'status': 'active',
        'siteIds': <String>[],
        'sections': [
          {
            'title': 'Daily checks',
            'items': [
              {'id': 'd1', 'text': 'PPE worn', 'hazardCategory': 'ppe'},
            ],
          },
        ],
      });
    });

    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: InspectionTemplatesScreen(
            organizationId: 'org',
            repository: repository,
            service: service,
            siteRepository: SiteRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: 'org',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('Duplicate starts a new checklist from an existing one', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(find.text('Duplicate'));
      await tester.pumpAndSettle();
      expect(find.text('Duplicate checklist'), findsOneWidget);
      expect(
        find.widgetWithText(TextField, 'Copy of Daily site inspection'),
        findsOneWidget,
      );

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final saved = service.saved.single;
      expect(saved.id, isNull);
      expect(saved.sections.single.items.single.text, 'PPE worn');
      // A copy gets fresh item ids.
      expect(saved.sections.single.items.single.id, '');
    });

    testWidgets('Paste a list fills a new checklist', (tester) async {
      await open(tester);
      await tester.tap(find.text('New checklist'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Name'),
        'Embassy daily check',
      );
      await tester.tap(find.text('Paste a list'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'Access:\n- Gate locked after hours\n- Visitors signed in',
      );
      await tester.pump();
      expect(find.text('2 items in 1 section'), findsOneWidget);
      await tester.tap(find.text('Add to checklist'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final saved = service.saved.single;
      expect(saved.name, 'Embassy daily check');
      expect(saved.sections.single.title, 'Access');
      expect(saved.sections.single.items.map((i) => i.text), [
        'Gate locked after hours',
        'Visitors signed in',
      ]);
    });

    testWidgets('the library adds one checklist at a time', (tester) async {
      await open(tester);
      await tester.tap(find.text('Checklist library'));
      await tester.pumpAndSettle();

      expect(find.text('Scaffolds & ladders'), findsOneWidget);
      expect(find.text('Added'), findsOneWidget);
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(service.installedKeys, [
        ['scaffolds-ladders'],
      ]);
      expect(find.text('Added'), findsNWidgets(2));
    });
  });
}
