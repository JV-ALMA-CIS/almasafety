import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/features/safety_alerts/data/safety_alert_repository.dart';

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<void> seedAlert(
    String orgId,
    String id, {
    String siteId = 'site-1',
    String status = 'active',
  }) async {
    await firestore.doc('organizations/$orgId/safety_alerts/$id').set({
      'organizationId': orgId,
      'projectId': 'project-1',
      'siteId': siteId,
      'title': 'Alert $id',
      'description': 'Description $id',
      'severity': 'medium',
      'category': 'safety',
      'status': status,
      'createdBy': 'manager-1',
      'createdAt': Timestamp.now(),
    });
  }

  test('watchForOrganization returns every alert across sites', () async {
    await seedAlert('org-alpha', 'a1', siteId: 'site-1');
    await seedAlert('org-alpha', 'a2', siteId: 'site-2');

    final repository = SafetyAlertRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final alerts = await repository.watchForOrganization().first;

    expect(alerts.map((a) => a.id).toSet(), {'a1', 'a2'});
  });

  test("watchForOrganization excludes another organization's alerts",
      () async {
    await seedAlert('org-alpha', 'a1');
    await seedAlert('org-beta', 'a1');

    final repository = SafetyAlertRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final alerts = await repository.watchForOrganization().first;

    expect(alerts, hasLength(1));
    expect(alerts.single.organizationId, 'org-alpha');
  });

  test('watchForSite returns only alerts for that site', () async {
    await seedAlert('org-alpha', 'a1', siteId: 'site-1');
    await seedAlert('org-alpha', 'a2', siteId: 'site-2');
    await seedAlert('org-alpha', 'a3', siteId: 'site-1');

    final repository = SafetyAlertRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final alerts = await repository.watchForSite('site-1').first;

    expect(alerts.map((a) => a.id).toSet(), {'a1', 'a3'});
  });

  test('watchForSite excludes alerts from another site in the same '
      'organization', () async {
    await seedAlert('org-alpha', 'a1', siteId: 'site-1');
    await seedAlert('org-alpha', 'a2', siteId: 'site-2');

    final repository = SafetyAlertRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final alerts = await repository.watchForSite('site-2').first;

    expect(alerts.map((a) => a.id).toList(), ['a2']);
  });

  test('getById returns null for a missing document', () async {
    final repository = SafetyAlertRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    expect(await repository.getById('missing'), isNull);
  });

  test('organizationId exposes the scope this repository was built with',
      () {
    final repository = SafetyAlertRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    expect(repository.organizationId, 'org-alpha');
  });
}
