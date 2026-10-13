import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/features/pre_start_checks/domain/pre_start_check.dart';
import 'package:jva_safety/features/pre_start_checks/presentation/pre_start_visuals.dart';

PreStartQuestion _q(String id, String prompt) =>
    PreStartQuestion(id: id, prompt: prompt, kind: 'standard');

void main() {
  test('the PPE question shows each piece of equipment', () {
    final labels = visualsFor(
      _q('std-ppe', 'I am wearing the right PPE.'),
    ).map((v) => v.label);
    expect(labels, [
      'Helmet',
      'Hi-vis vest',
      'Safety boots',
      'Gloves',
      'Eye protection',
    ]);
  });

  test('a requirement question gets pictures for the hazards it names', () {
    final labels = visualsFor(
      _q(
        'act-roofing',
        'Roofing: the controls for "Working at Height" and "Hot Work Fire '
            'Safety" are in place and I will follow them today.',
      ),
    ).map((v) => v.label);
    expect(labels, ['Working at height', 'Fire / hot work']);
  });

  test('a requirement with no recognised hazard words gets a general sign', () {
    expect(
      visualsFor(_q('act-x', 'Painting: the controls for "Site Rules".')),
      [(emoji: '⚠️', label: 'Controls in place')],
    );
  });

  testWidgets('the strip shows every picture with its label', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PreStartVisualStrip(
            visuals: visualsFor(_q('std-emergency', 'Emergency')),
          ),
        ),
      ),
    );

    expect(find.text('🚪'), findsOneWidget);
    expect(find.text('Assembly point'), findsOneWidget);
    expect(find.text('First aid'), findsOneWidget);
  });
}
