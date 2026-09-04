import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/features/organizations/data/project_repository.dart';

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<void> seedProject(
    String orgId,
    String id, {
    String status = 'active',
  }) async {
    await firestore.doc('organizations/$orgId/projects/$id').set({
      'organizationId': orgId,
      'name': 'Project $id',
      'code': 'CODE-$id',
      'status': status,
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  test('watchAll streams only the projects under this organization', () async {
    await seedProject('org-alpha', 'p1');
    await seedProject('org-alpha', 'p2');
    await seedProject('org-beta', 'p3');

    final repository = ProjectRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final projects = await repository.watchAll().first;

    expect(projects.map((p) => p.id).toSet(), {'p1', 'p2'});
    expect(projects.every((p) => p.organizationId == 'org-alpha'), isTrue);
  });

  test('getById returns null for a project in another organization', () async {
    await seedProject('org-beta', 'p3');

    final repository = ProjectRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    // The repository is scoped to org-alpha's projects subcollection, so a
    // project living under org-beta is simply not addressable through it —
    // there is no id collision to worry about since the path differs.
    final project = await repository.getById('p3');

    expect(project, isNull);
  });
}
