import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/features/hazards/data/hazard_repository.dart';

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<void> seedHazard(
    String orgId,
    String id, {
    required String reportedByUid,
    String siteId = 'site-1',
    String status = 'reported',
  }) async {
    await firestore.doc('organizations/$orgId/hazards/$id').set({
      'organizationId': orgId,
      'projectId': 'project-1',
      'siteId': siteId,
      'reportedByUid': reportedByUid,
      'category': 'electrical',
      'description': 'Hazard $id',
      'status': status,
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  test(
    'watchReportedBy returns only the given worker\'s own reports',
    () async {
      await seedHazard('org-alpha', 'h1', reportedByUid: 'worker-1');
      await seedHazard('org-alpha', 'h2', reportedByUid: 'worker-1');
      await seedHazard('org-alpha', 'h3', reportedByUid: 'worker-2');

      final repository = HazardRepository(
        firestoreService: FirestoreService(firestore: firestore),
        organizationId: 'org-alpha',
      );

      final hazards = await repository.watchReportedBy('worker-1').first;

      expect(hazards.map((h) => h.id).toSet(), {'h1', 'h2'});
    },
  );

  test('watchForSite returns only hazards for that site', () async {
    await seedHazard(
      'org-alpha',
      'h1',
      reportedByUid: 'worker-1',
      siteId: 'site-1',
    );
    await seedHazard(
      'org-alpha',
      'h2',
      reportedByUid: 'worker-2',
      siteId: 'site-2',
    );

    final repository = HazardRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final hazards = await repository.watchForSite('site-1').first;

    expect(hazards.map((h) => h.id).toList(), ['h1']);
  });

  test('watchForOrganization returns every hazard across sites', () async {
    await seedHazard(
      'org-alpha',
      'h1',
      reportedByUid: 'worker-1',
      siteId: 'site-1',
    );
    await seedHazard(
      'org-alpha',
      'h2',
      reportedByUid: 'worker-2',
      siteId: 'site-2',
    );

    final repository = HazardRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final hazards = await repository.watchForOrganization().first;

    expect(hazards.map((h) => h.id).toSet(), {'h1', 'h2'});
  });

  test(
    "watchForOrganization excludes another organization's hazards",
    () async {
      await seedHazard('org-alpha', 'h1', reportedByUid: 'worker-1');
      await seedHazard('org-beta', 'h1', reportedByUid: 'worker-1');

      final repository = HazardRepository(
        firestoreService: FirestoreService(firestore: firestore),
        organizationId: 'org-alpha',
      );

      final hazards = await repository.watchForOrganization().first;

      expect(hazards, hasLength(1));
      expect(hazards.single.organizationId, 'org-alpha');
    },
  );

  test('getById returns null for a missing document', () async {
    final repository = HazardRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    expect(await repository.getById('missing'), isNull);
  });

  test('organizationId exposes the scope this repository was built with', () {
    final repository = HazardRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    expect(repository.organizationId, 'org-alpha');
  });
}
