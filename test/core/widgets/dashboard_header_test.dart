import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/widgets/dashboard_header.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';

void main() {
  testWidgets('shows the title, role label and user name', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DashboardHeader(
            title: 'Dashboard',
            role: AppRole.foreman,
            userName: 'Amina Wanjiku',
          ),
        ),
      ),
    );

    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.text(AppRole.foreman.label), findsOneWidget);
    expect(find.text('Amina Wanjiku'), findsOneWidget);
  });

  testWidgets('omits the name row when no name is known', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DashboardHeader(title: 'Dashboard', role: AppRole.worker),
        ),
      ),
    );

    expect(find.text(AppRole.worker.label), findsOneWidget);
    expect(find.byIcon(Icons.account_circle), findsNothing);
  });

  test('every role has a distinct badge color', () {
    final colors = AppRole.values.map(DashboardHeader.roleColor).toSet();
    expect(colors.length, AppRole.values.length);
  });
}
