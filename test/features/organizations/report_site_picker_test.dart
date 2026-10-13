import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/features/organizations/data/site_repository.dart';
import 'package:jva_safety/features/organizations/presentation/report_site_picker.dart';

void main() {
  late FakeFirebaseFirestore firestore;
  late SiteRepository repository;

  setUp(() async {
    firestore = FakeFirebaseFirestore();
    repository = SiteRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org',
    );
    for (final (id, name, status) in [
      ('embassy', 'Italian Embassy', 'active'),
      ('new', 'New Project Site', 'active'),
      ('rosslyn', 'Rosslyn Ridge', 'inactive'),
    ]) {
      await firestore.doc('organizations/org/sites/$id').set({
        'organizationId': 'org',
        'projectId': 'p-$id',
        'name': name,
        'code': id.toUpperCase(),
        'status': status,
      });
    }
  });

  Widget picker(String? selected) => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: ReportSitePicker(
          organizationId: 'org',
          siteIds: null,
          selectedSiteId: selected,
          onChanged: (_) {},
          siteRepository: repository,
        ),
      ),
    ),
  );

  testWidgets('a finished (switched-off) site is not offered', (tester) async {
    await tester.pumpWidget(picker(null));
    await tester.pumpAndSettle();
    expect(find.text('Italian Embassy'), findsOneWidget);
    expect(find.text('New Project Site'), findsOneWidget);
    expect(find.text('Rosslyn Ridge'), findsNothing);
  });

  testWidgets('it still shows when it is the one already chosen', (
    tester,
  ) async {
    await tester.pumpWidget(picker('rosslyn'));
    await tester.pumpAndSettle();
    expect(find.text('Rosslyn Ridge'), findsOneWidget);
  });
}
