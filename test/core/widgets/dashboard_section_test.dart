import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/widgets/dashboard_section.dart';

void main() {
  testWidgets('renders title and child', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DashboardSection(title: 'Open Hazards', child: Text('content')),
        ),
      ),
    );

    expect(find.text('Open Hazards'), findsOneWidget);
    expect(find.text('content'), findsOneWidget);
  });

  testWidgets('renders trailing when given', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DashboardSection(
            title: 'Open Hazards',
            trailing: Text('See all'),
            child: Text('content'),
          ),
        ),
      ),
    );

    expect(find.text('See all'), findsOneWidget);
  });
}
