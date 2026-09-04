import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/features/organizations/data/site_repository.dart';

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<void> seedSite(
    String orgId,
    String id, {
    required String projectId,
  }) async {
    await firestore.doc('organizations/$orgId/sites/$id').set({
      'organizationId': orgId,
      'projectId': projectId,
      'name': 'Site $id',
      'code': 'CODE-$id',
      'status': 'active',
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  test('watchAll streams only the sites under this organization', () async {
    await seedSite('org-alpha', 's1', projectId: 'p1');
    await seedSite('org-alpha', 's2', projectId: 'p2');
    await seedSite('org-beta', 's3', projectId: 'p1');

    final repository = SiteRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final sites = await repository.watchAll().first;

    expect(sites.map((s) => s.id).toSet(), {'s1', 's2'});
  });

  test('watchByProject narrows to one project within the organization',
      () async {
    await seedSite('org-alpha', 's1', projectId: 'p1');
    await seedSite('org-alpha', 's2', projectId: 'p2');
    await seedSite('org-alpha', 's3', projectId: 'p1');

    final repository = SiteRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final sites = await repository.watchByProject('p1').first;

    expect(sites.map((s) => s.id).toSet(), {'s1', 's3'});
    expect(sites.every((s) => s.projectId == 'p1'), isTrue);
  });

  test('organizationId exposes the scope this repository was built with',
      () {
    final repository = SiteRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    expect(repository.organizationId, 'org-alpha');
  });
}
