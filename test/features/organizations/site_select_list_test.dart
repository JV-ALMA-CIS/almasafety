import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/features/organizations/domain/organization_record_status.dart';
import 'package:jva_safety/features/organizations/domain/site.dart';
import 'package:jva_safety/features/organizations/presentation/site_select_list.dart';

Site _site(String id, String name, {String? code, String? location}) => Site(
  id: id,
  organizationId: 'org-alpha',
  projectId: 'project-1',
  name: name,
  code: code ?? id.toUpperCase(),
  location: location,
  status: OrganizationRecordStatus.active,
);

void main() {
  /// Hosts the list with its own selection state, like a real form.
  Future<List<String?>> pumpList(
    WidgetTester tester,
    List<Site> sites, {
    String? initial,
  }) async {
    final changes = <String?>[];
    var selected = initial;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SingleChildScrollView(
              child: SiteSelectList(
                sites: sites,
                selectedSiteId: selected,
                onChanged: (id) => setState(() {
                  changes.add(id);
                  selected = id;
                }),
              ),
            ),
          ),
        ),
      ),
    );
    return changes;
  }

  testWidgets('shows each site with its code and location', (tester) async {
    await pumpList(tester, [
      _site('s1', 'Embassy Block A', code: 'EMB-A', location: 'Gigiri'),
      _site('s2', 'Embassy Block B', code: 'EMB-B', location: 'Gigiri'),
    ]);

    expect(find.text('Embassy Block A'), findsOneWidget);
    expect(find.text('EMB-A · Gigiri'), findsOneWidget);
    expect(find.text('EMB-B'), findsOneWidget); // the colour badge
  });

  testWidgets('tapping the chosen site again unselects it', (tester) async {
    final changes = await pumpList(tester, [
      _site('s1', 'Embassy'),
      _site('s2', 'Depot'),
    ]);

    await tester.tap(find.text('Depot'));
    await tester.pump();
    await tester.tap(find.text('Depot'));
    await tester.pump();
    await tester.tap(find.text('Embassy'));
    await tester.pump();

    expect(changes, ['s2', null, 's1']);
  });

  testWidgets('a single site is shown as "Your site" with nothing to pick', (
    tester,
  ) async {
    final changes = await pumpList(tester, [
      _site('s1', 'Embassy'),
    ], initial: 's1');

    expect(find.text('Your site'), findsOneWidget);
    await tester.tap(find.text('Embassy'));
    await tester.pump();
    expect(changes, isEmpty);
  });

  testWidgets('many sites get a search box that filters by name, code or '
      'location', (tester) async {
    await pumpList(tester, [
      for (var i = 1; i <= 8; i++)
        _site(
          's$i',
          'Site $i',
          code: 'C$i',
          location: i == 5 ? 'Karen' : 'CBD',
        ),
    ]);

    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'karen');
    await tester.pump();

    expect(find.text('Site 5'), findsOneWidget);
    expect(find.text('Site 1'), findsNothing);
  });

  testWidgets('a few sites get no search box', (tester) async {
    await pumpList(tester, [_site('s1', 'Embassy'), _site('s2', 'Depot')]);
    expect(find.byType(TextField), findsNothing);
  });
}
