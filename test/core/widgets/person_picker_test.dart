import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/widgets/person_picker.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/organization_user.dart';

OrganizationUser _user(
  String uid,
  String name, {
  AppRole? role,
  String? trade,
}) => OrganizationUser(
  uid: uid,
  name: name,
  email: '$uid@example.com',
  accountStatus: AccountStatus.active,
  role: role,
  trade: trade,
);

Widget _wrap(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  testWidgets('shows people by name, role and trade — never their account id', (
    tester,
  ) async {
    String? chosen;
    await tester.pumpWidget(
      _wrap(
        PersonPicker(
          uids: const ['uid-b', 'uid-a'],
          people: [
            _user(
              'uid-a',
              'Amina Otieno',
              role: AppRole.worker,
              trade: 'Mason',
            ),
            _user('uid-b', 'Brian Kip', role: AppRole.foreman),
          ],
          selected: null,
          onChanged: (uid) => chosen = uid,
        ),
      ),
    );

    expect(find.text('Amina Otieno'), findsOneWidget);
    expect(find.text('Brian Kip'), findsOneWidget);
    expect(find.text(AppRole.foreman.label), findsOneWidget);
    expect(find.text('Mason'), findsOneWidget);
    expect(find.text('uid-a'), findsNothing);

    await tester.tap(find.text('Brian Kip'));
    expect(chosen, 'uid-b');
  });

  testWidgets('an unknown uid is still offered, as "Unknown person"', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        PersonPicker(
          uids: const ['uid-x'],
          people: const [],
          selected: 'uid-x',
          onChanged: (_) {},
        ),
      ),
    );

    expect(find.text('Unknown person'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
  });

  testWidgets('a long list gets a search box that filters by name', (
    tester,
  ) async {
    final people = [
      for (var i = 0; i < 10; i++) _user('uid-$i', 'Worker $i'),
      _user('uid-z', 'Zawadi Mwangi'),
    ];
    await tester.pumpWidget(
      _wrap(
        PersonPicker(
          uids: [for (final p in people) p.uid],
          people: people,
          selected: null,
          onChanged: (_) {},
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'zawadi');
    await tester.pump();

    expect(find.text('Zawadi Mwangi'), findsOneWidget);
    expect(find.text('Worker 1'), findsNothing);
  });
}
