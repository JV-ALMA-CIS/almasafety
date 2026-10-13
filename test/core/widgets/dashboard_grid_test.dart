import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/widgets/dashboard_grid.dart';

void main() {
  testWidgets('renders every child', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DashboardGrid(
            children: [Text('One'), Text('Two'), Text('Three')],
          ),
        ),
      ),
    );

    expect(find.text('One'), findsOneWidget);
    expect(find.text('Two'), findsOneWidget);
    expect(find.text('Three'), findsOneWidget);
  });

  testWidgets('renders nothing for an empty list', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: DashboardGrid(children: [])),
      ),
    );

    expect(find.byType(SizedBox), findsWidgets);
  });
}
