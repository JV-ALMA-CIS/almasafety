import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/widgets/status_badge.dart';

void main() {
  testWidgets('renders the given label', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: StatusBadge(label: 'Open', color: Colors.blue),
        ),
      ),
    );

    expect(find.text('Open'), findsOneWidget);
  });
}
