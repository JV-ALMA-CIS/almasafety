import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/widgets/kpi_card.dart';

void main() {
  testWidgets('renders value and label', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: KpiCard(
            value: '12',
            label: 'Open Hazards',
            icon: Icons.warning_amber_outlined,
          ),
        ),
      ),
    );

    expect(find.text('12'), findsOneWidget);
    expect(find.text('Open Hazards'), findsOneWidget);
  });

  testWidgets('calls onTap when tapped', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: KpiCard(
            value: '12',
            label: 'Open Hazards',
            icon: Icons.warning_amber_outlined,
            onTap: () => tapped = true,
          ),
        ),
      ),
    );

    await tester.tap(find.byType(KpiCard));
    expect(tapped, isTrue);
  });

  testWidgets('is not tappable when onTap is omitted', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: KpiCard(
            value: '12',
            label: 'Open Hazards',
            icon: Icons.warning_amber_outlined,
          ),
        ),
      ),
    );

    final inkWell = tester.widget<InkWell>(find.byType(InkWell));
    expect(inkWell.onTap, isNull);
  });
}
