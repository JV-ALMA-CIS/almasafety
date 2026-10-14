import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/features/organizations/data/organization_admin_service.dart';
import 'package:jva_safety/features/organizations/data/site_repository.dart';
import 'package:jva_safety/features/organizations/domain/organization_record_status.dart';
import 'package:jva_safety/features/organizations/domain/site.dart';
import 'package:jva_safety/features/organizations/domain/site_emergency_info.dart';
import 'package:jva_safety/features/organizations/presentation/site_emergency_contacts.dart';

class _FakeAdminService extends OrganizationAdminService {
  final saved = <SiteEmergencyInfo>[];

  @override
  Future<void> updateSiteEmergencyInfo(
    String organizationId,
    String siteId,
    SiteEmergencyInfo emergency,
  ) async => saved.add(emergency);
}

const _info = SiteEmergencyInfo(
  clinicName: 'Nairobi Hospital',
  clinicAddress: 'Argwings Kodhek Rd',
  clinicPhones: ['+254 700 000000'],
  ambulancePhone: '999',
  otherNumbers: [EmergencyNumber(label: 'Fire', number: '998')],
  assemblyPoint: 'Main gate',
  firstAidKitLocation: 'Site office',
  firstAiders: ['Eston K Gikonyo', 'Fred'],
);

void main() {
  test('the call list puts the ambulance first', () {
    expect(_info.callList.map((n) => '${n.label}: ${n.number}'), [
      'Ambulance: 999',
      'Nairobi Hospital: +254 700 000000',
      'Fire: 998',
    ]);
    expect(SiteEmergencyInfo.fromMap(const <String, Object?>{}), isNull);
  });

  testWidgets('the card shows tap-to-call numbers and the site details', (
    tester,
  ) async {
    final called = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: EmergencyContactsCard(
              siteName: 'Italian Embassy',
              info: _info,
              call: (number) async => called.add(number),
            ),
          ),
        ),
      ),
    );
    expect(find.text('In an emergency — Italian Embassy'), findsOneWidget);
    expect(find.text('Assembly point: Main gate'), findsOneWidget);
    expect(find.text('First-aiders: Eston K Gikonyo, Fred'), findsOneWidget);
    await tester.tap(find.text('Ambulance: 999'));
    expect(called, ['999']);
  });

  testWidgets('with nothing set, a worker is told to ask', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: EmergencyContactsCard(siteName: 'New Site', info: null),
        ),
      ),
    );
    expect(find.textContaining('ask your Site Manager'), findsOneWidget);
    expect(find.text('Add'), findsNothing);
  });

  testWidgets('a site is loaded live by id', (tester) async {
    final firestore = FakeFirebaseFirestore();
    await firestore.doc('organizations/org/sites/s1').set({
      'organizationId': 'org',
      'projectId': 'p',
      'name': 'Rosslyn Ridge',
      'code': 'RR',
      'status': 'active',
      'emergency': _info.toJson(),
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SiteEmergencyContacts(
              organizationId: 'org',
              siteId: 's1',
              siteRepository: SiteRepository(
                firestoreService: FirestoreService(firestore: firestore),
                organizationId: 'org',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('In an emergency — Rosslyn Ridge'), findsOneWidget);
    expect(find.text('Ambulance: 999'), findsOneWidget);
  });

  testWidgets('the editor saves what was typed', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final service = _FakeAdminService();
    await tester.pumpWidget(
      MaterialApp(
        home: SiteEmergencyEditorScreen(
          organizationId: 'org',
          site: const Site(
            id: 's1',
            organizationId: 'org',
            projectId: 'p',
            name: 'Italian Embassy',
            code: 'EMB',
            status: OrganizationRecordStatus.active,
          ),
          service: service,
        ),
      ),
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Ambulance number'),
      '999',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Other emergency numbers'),
      'Fire brigade: 998\n0711 222333',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Trained first-aiders'),
      'Eston\n\nFred',
    );
    await tester.tap(find.text('Save emergency contacts'));
    await tester.pumpAndSettle();

    final saved = service.saved.single;
    expect(saved.ambulancePhone, '999');
    expect(saved.otherNumbers.map((n) => '${n.label}|${n.number}'), [
      'Fire brigade|998',
      'Emergency|0711 222333',
    ]);
    expect(saved.firstAiders, ['Eston', 'Fred']);
    expect(saved.clinicName, isNull);
  });
}
