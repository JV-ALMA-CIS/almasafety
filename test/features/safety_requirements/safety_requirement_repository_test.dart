import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/features/safety_requirements/data/safety_requirement_repository.dart';

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<void> seedRequirement(
    String orgId,
    String id, {
    required List<String> requiredLearningIds,
    String status = 'active',
    bool? gatesAttendance,
    bool? requiredBeforeWork,
    Map<String, Map<String, bool>>? learningSettings,
  }) async {
    await firestore.doc('organizations/$orgId/safety_requirements/$id').set({
      'organizationId': orgId,
      'name': 'Requirement $id',
      'category': 'General',
      'risk': 'medium',
      'requiredLearningIds': requiredLearningIds,
      'status': status,
      'gatesAttendance': ?gatesAttendance,
      'requiredBeforeWork': ?requiredBeforeWork,
      'learningSettings': ?learningSettings,
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  Future<void> seedLearning(
    String orgId,
    String id, {
    String status = 'active',
  }) async {
    await firestore.doc('organizations/$orgId/safety_learning/$id').set({
      'organizationId': orgId,
      'title': 'Learning $id',
      'type': 'document',
      'contentReference': 'ref-$id',
      'status': status,
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  Future<void> seedAssignment(
    String orgId,
    String activityId,
    String uid, {
    required String siteId,
    String? projectId,
  }) async {
    await firestore
        .doc('organizations/$orgId/activities/$activityId/assignments/$uid')
        .set({
          'uid': uid,
          'organizationId': orgId,
          'siteId': siteId,
          'activityId': activityId,
          'projectId': ?projectId,
          'assignedAt': Timestamp.now(),
        });
  }

  test(
    'watchAll streams only the requirements under this organization',
    () async {
      await seedRequirement('org-alpha', 'r1', requiredLearningIds: []);
      await seedRequirement('org-beta', 'r2', requiredLearningIds: []);

      final repository = SafetyRequirementRepository(
        firestoreService: FirestoreService(firestore: firestore),
        organizationId: 'org-alpha',
      );

      final requirements = await repository.watchAll().first;

      expect(requirements.map((r) => r.id).toSet(), {'r1'});
    },
  );

  test('watchResolvedRequiredLearning de-duplicates across overlapping '
      'requirements', () async {
    await seedLearning('org-alpha', 'l1');
    await seedLearning('org-alpha', 'l2');
    await seedRequirement('org-alpha', 'r1', requiredLearningIds: ['l1', 'l2']);
    await seedRequirement('org-alpha', 'r2', requiredLearningIds: ['l1']);

    final repository = SafetyRequirementRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final resolved = await repository
        .watchResolvedRequiredLearning('worker-1')
        .first;

    expect(resolved.map((l) => l.id).toSet(), {'l1', 'l2'});
  });

  test(
    'watchResolvedRequiredLearning excludes an inactive learning item',
    () async {
      await seedLearning('org-alpha', 'l1');
      await seedLearning('org-alpha', 'l2', status: 'inactive');
      await seedRequirement(
        'org-alpha',
        'r1',
        requiredLearningIds: ['l1', 'l2'],
      );

      final repository = SafetyRequirementRepository(
        firestoreService: FirestoreService(firestore: firestore),
        organizationId: 'org-alpha',
      );

      final resolved = await repository
          .watchResolvedRequiredLearning('worker-1')
          .first;

      expect(resolved.map((l) => l.id).toSet(), {'l1'});
    },
  );

  test("watchResolvedRequiredLearning excludes an inactive requirement's "
      'contribution', () async {
    await seedLearning('org-alpha', 'l1');
    await seedLearning('org-alpha', 'l2');
    await seedRequirement('org-alpha', 'r1', requiredLearningIds: ['l1']);
    await seedRequirement(
      'org-alpha',
      'r2',
      requiredLearningIds: ['l2'],
      status: 'inactive',
    );

    final repository = SafetyRequirementRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final resolved = await repository
        .watchResolvedRequiredLearning('worker-1')
        .first;

    expect(resolved.map((l) => l.id).toSet(), {'l1'});
  });

  test(
    'watchResolvedRequiredLearning is empty when nothing is required',
    () async {
      final repository = SafetyRequirementRepository(
        firestoreService: FirestoreService(firestore: firestore),
        organizationId: 'org-alpha',
      );

      final resolved = await repository
          .watchResolvedRequiredLearning('worker-1')
          .first;

      expect(resolved, isEmpty);
    },
  );

  test('watchResolvedRequiredLearning resolves a site-scoped requirement only '
      "for a worker assigned to that site", () async {
    await seedLearning('org-alpha', 'l1');
    await seedRequirement('org-alpha', 'r1', requiredLearningIds: ['l1']);
    await firestore
        .doc('organizations/org-alpha/safety_requirements/r1')
        .update({'siteId': 'site-a'});
    await seedAssignment('org-alpha', 'act-1', 'worker-1', siteId: 'site-a');

    final repository = SafetyRequirementRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final resolvedForAssignedWorker = await repository
        .watchResolvedRequiredLearning('worker-1')
        .first;
    final resolvedForUnrelatedWorker = await repository
        .watchResolvedRequiredLearning('worker-2')
        .first;

    expect(resolvedForAssignedWorker.map((l) => l.id).toSet(), {'l1'});
    expect(resolvedForUnrelatedWorker, isEmpty);
  });

  test('watchResolvedRequiredLearning resolves an activity-scoped requirement '
      'only for a worker assigned to that activity', () async {
    await seedLearning('org-alpha', 'l1');
    await seedRequirement('org-alpha', 'r1', requiredLearningIds: ['l1']);
    await firestore
        .doc('organizations/org-alpha/safety_requirements/r1')
        .update({'activityId': 'act-1'});
    await seedAssignment('org-alpha', 'act-1', 'worker-1', siteId: 'site-a');
    await seedAssignment('org-alpha', 'act-2', 'worker-2', siteId: 'site-a');

    final repository = SafetyRequirementRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final resolvedForAssignedWorker = await repository
        .watchResolvedRequiredLearning('worker-1')
        .first;
    // worker-2 shares the same site but a DIFFERENT activity — an
    // activity-scoped requirement must not leak to it.
    final resolvedForUnrelatedActivityWorker = await repository
        .watchResolvedRequiredLearning('worker-2')
        .first;

    expect(resolvedForAssignedWorker.map((l) => l.id).toSet(), {'l1'});
    expect(resolvedForUnrelatedActivityWorker, isEmpty);
  });

  test('watchResolvedRequiredLearning resolves a project-scoped requirement '
      'for a worker assigned anywhere under that project', () async {
    await seedLearning('org-alpha', 'l1');
    await seedRequirement('org-alpha', 'r1', requiredLearningIds: ['l1']);
    await firestore
        .doc('organizations/org-alpha/safety_requirements/r1')
        .update({'projectId': 'project-1'});
    await seedAssignment(
      'org-alpha',
      'act-1',
      'worker-1',
      siteId: 'site-a',
      projectId: 'project-1',
    );
    // Same organization, different project — must not see the requirement.
    await seedAssignment(
      'org-alpha',
      'act-2',
      'worker-2',
      siteId: 'site-b',
      projectId: 'project-2',
    );

    final repository = SafetyRequirementRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final resolvedForProjectWorker = await repository
        .watchResolvedRequiredLearning('worker-1')
        .first;
    final resolvedForOtherProjectWorker = await repository
        .watchResolvedRequiredLearning('worker-2')
        .first;

    expect(resolvedForProjectWorker.map((l) => l.id).toSet(), {'l1'});
    expect(resolvedForOtherProjectWorker, isEmpty);
  });

  test('watchResolvedRequiredLearning ignores an assignment with no '
      'denormalized projectId (legacy assignment predating the field), for '
      'a project-scoped requirement', () async {
    await seedLearning('org-alpha', 'l1');
    await seedRequirement('org-alpha', 'r1', requiredLearningIds: ['l1']);
    await firestore
        .doc('organizations/org-alpha/safety_requirements/r1')
        .update({'projectId': 'project-1'});
    // No projectId on the assignment — mirrors an assignment written before
    // this field existed.
    await seedAssignment('org-alpha', 'act-1', 'worker-1', siteId: 'site-a');

    final repository = SafetyRequirementRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final resolved = await repository
        .watchResolvedRequiredLearning('worker-1')
        .first;

    expect(resolved, isEmpty);
  });

  test('watchResolvedRequiredLearning unions requirements across a worker '
      'assigned to multiple activities, without duplicates', () async {
    await seedLearning('org-alpha', 'ppe');
    await seedLearning('org-alpha', 'height');
    await seedLearning('org-alpha', 'electrical');
    await seedRequirement(
      'org-alpha',
      'r-ppe-activity-a',
      requiredLearningIds: ['ppe'],
    );
    await firestore
        .doc('organizations/org-alpha/safety_requirements/r-ppe-activity-a')
        .update({'activityId': 'act-a'});
    await seedRequirement(
      'org-alpha',
      'r-height-activity-a',
      requiredLearningIds: ['height'],
    );
    await firestore
        .doc('organizations/org-alpha/safety_requirements/r-height-activity-a')
        .update({'activityId': 'act-a'});
    await seedRequirement(
      'org-alpha',
      'r-ppe-activity-b',
      requiredLearningIds: ['ppe'],
    );
    await firestore
        .doc('organizations/org-alpha/safety_requirements/r-ppe-activity-b')
        .update({'activityId': 'act-b'});
    await seedRequirement(
      'org-alpha',
      'r-electrical-activity-b',
      requiredLearningIds: ['electrical'],
    );
    await firestore
        .doc(
          'organizations/org-alpha/safety_requirements/'
          'r-electrical-activity-b',
        )
        .update({'activityId': 'act-b'});
    await seedAssignment('org-alpha', 'act-a', 'worker-1', siteId: 'site-a');
    await seedAssignment('org-alpha', 'act-b', 'worker-1', siteId: 'site-a');

    final repository = SafetyRequirementRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final resolved = await repository
        .watchResolvedRequiredLearning('worker-1')
        .first;

    expect(resolved.map((l) => l.id).toSet(), {'ppe', 'height', 'electrical'});
    expect(resolved.length, 3);
  });

  test('watchResolvedRequiredLearningForScope (the meeting-specific '
      "resolver) can differ from a worker's own broader "
      'watchResolvedRequiredLearning: a meeting scoped to only one of the '
      "worker's two assigned activities does not pull in the OTHER "
      "activity's requirement", () async {
    await seedLearning('org-alpha', 'height');
    await seedLearning('org-alpha', 'electrical');
    await seedRequirement(
      'org-alpha',
      'r-height',
      requiredLearningIds: ['height'],
    );
    await firestore
        .doc('organizations/org-alpha/safety_requirements/r-height')
        .update({'activityId': 'act-a'});
    await seedRequirement(
      'org-alpha',
      'r-electrical',
      requiredLearningIds: ['electrical'],
    );
    await firestore
        .doc('organizations/org-alpha/safety_requirements/r-electrical')
        .update({'activityId': 'act-b'});
    await seedAssignment('org-alpha', 'act-a', 'worker-1', siteId: 'site-a');
    await seedAssignment('org-alpha', 'act-b', 'worker-1', siteId: 'site-a');

    final repository = SafetyRequirementRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    // Overall compliance: union across BOTH assigned activities.
    final overallCompliance = await repository
        .watchResolvedRequiredLearning('worker-1')
        .first;
    // Meeting-specific: only activity A is on today's meeting.
    final meetingScoped = await repository
        .watchResolvedRequiredLearningForScope(
          siteId: 'site-a',
          activityIds: const ['act-a'],
        )
        .first;

    expect(overallCompliance.map((l) => l.id).toSet(), {
      'height',
      'electrical',
    });
    expect(meetingScoped.map((l) => l.id).toSet(), {'height'});
  });

  test('watchAttendanceGatingLearningForScope excludes a non-gating '
      "requirement's learning, while watchResolvedRequiredLearningForScope "
      'still includes it', () async {
    await seedLearning('org-alpha', 'l1');
    await seedRequirement(
      'org-alpha',
      'r1',
      requiredLearningIds: ['l1'],
      gatesAttendance: false,
    );
    await firestore
        .doc('organizations/org-alpha/safety_requirements/r1')
        .update({'siteId': 'site-a'});

    final repository = SafetyRequirementRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final required = await repository
        .watchResolvedRequiredLearningForScope(
          siteId: 'site-a',
          activityIds: const [],
        )
        .first;
    final gating = await repository
        .watchAttendanceGatingLearningForScope(
          siteId: 'site-a',
          activityIds: const [],
        )
        .first;

    expect(required.map((l) => l.id).toSet(), {'l1'});
    expect(gating, isEmpty);
  });

  test(
    'watchAttendanceGatingLearningForScope includes a gating '
    "requirement's learning (missing gatesAttendance defaults to true)",
    () async {
      await seedLearning('org-alpha', 'l1');
      // gatesAttendance omitted entirely — legacy requirement.
      await seedRequirement('org-alpha', 'r1', requiredLearningIds: ['l1']);
      await firestore
          .doc('organizations/org-alpha/safety_requirements/r1')
          .update({'siteId': 'site-a'});

      final repository = SafetyRequirementRepository(
        firestoreService: FirestoreService(firestore: firestore),
        organizationId: 'org-alpha',
      );

      final gating = await repository
          .watchAttendanceGatingLearningForScope(
            siteId: 'site-a',
            activityIds: const [],
          )
          .first;

      expect(gating.map((l) => l.id).toSet(), {'l1'});
    },
  );

  test(
    'watchAttendanceGatingLearningForScope: a mix of gating and '
    "non-gating requirements only surfaces the gating one's learning",
    () async {
      await seedLearning('org-alpha', 'gating-learning');
      await seedLearning('org-alpha', 'non-gating-learning');
      await seedRequirement(
        'org-alpha',
        'r-gating',
        requiredLearningIds: ['gating-learning'],
        gatesAttendance: true,
      );
      await firestore
          .doc('organizations/org-alpha/safety_requirements/r-gating')
          .update({'siteId': 'site-a'});
      await seedRequirement(
        'org-alpha',
        'r-non-gating',
        requiredLearningIds: ['non-gating-learning'],
        gatesAttendance: false,
      );
      await firestore
          .doc('organizations/org-alpha/safety_requirements/r-non-gating')
          .update({'siteId': 'site-a'});

      final repository = SafetyRequirementRepository(
        firestoreService: FirestoreService(firestore: firestore),
        organizationId: 'org-alpha',
      );

      final gating = await repository
          .watchAttendanceGatingLearningForScope(
            siteId: 'site-a',
            activityIds: const [],
          )
          .first;

      expect(gating.map((l) => l.id).toSet(), {'gating-learning'});
    },
  );

  test('LEARNING-ID OVERLAP: watchAttendanceGatingLearningForScope still '
      'includes a learning id required by both a gating and a non-gating '
      'requirement', () async {
    await seedLearning('org-alpha', 'L1');
    await seedLearning('org-alpha', 'L2');
    await seedLearning('org-alpha', 'L3');
    await seedRequirement(
      'org-alpha',
      'requirement-a',
      requiredLearningIds: ['L1', 'L2'],
      gatesAttendance: true,
    );
    await firestore
        .doc('organizations/org-alpha/safety_requirements/requirement-a')
        .update({'siteId': 'site-a'});
    await seedRequirement(
      'org-alpha',
      'requirement-b',
      requiredLearningIds: ['L2', 'L3'],
      gatesAttendance: false,
    );
    await firestore
        .doc('organizations/org-alpha/safety_requirements/requirement-b')
        .update({'siteId': 'site-a'});

    final repository = SafetyRequirementRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final gating = await repository
        .watchAttendanceGatingLearningForScope(
          siteId: 'site-a',
          activityIds: const [],
        )
        .first;

    // L2 is gating (contributed by requirement-a), L3 is not (only
    // requirement-b, which is non-gating, contributes it).
    expect(gating.map((l) => l.id).toSet(), {'L1', 'L2'});
  });

  test('requiredBeforeWork does not change required or attendance-gating '
      'resolution, in any combination', () async {
    for (final id in ['ff', 'tf', 'ft', 'tt']) {
      await seedLearning('org-alpha', id);
    }
    // Naming: <requiredBeforeWork><gatesAttendance>.
    await seedRequirement(
      'org-alpha',
      'r-ff',
      requiredLearningIds: ['ff'],
      requiredBeforeWork: false,
      gatesAttendance: false,
    );
    await seedRequirement(
      'org-alpha',
      'r-tf',
      requiredLearningIds: ['tf'],
      requiredBeforeWork: true,
      gatesAttendance: false,
    );
    await seedRequirement(
      'org-alpha',
      'r-ft',
      requiredLearningIds: ['ft'],
      requiredBeforeWork: false,
      gatesAttendance: true,
    );
    await seedRequirement(
      'org-alpha',
      'r-tt',
      requiredLearningIds: ['tt'],
      requiredBeforeWork: true,
      gatesAttendance: true,
    );

    final repository = SafetyRequirementRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final required = await repository
        .watchResolvedRequiredLearning('worker-1')
        .first;
    final gating = await repository
        .watchAttendanceGatingLearningForScope(
          siteId: 'site-1',
          activityIds: const [],
        )
        .first;

    expect(required.map((l) => l.id).toSet(), {'ff', 'tf', 'ft', 'tt'});
    expect(gating.map((l) => l.id).toSet(), {'ft', 'tt'});
  });

  test('per-lesson settings: attendance gating is decided per lesson, and a '
      'lesson gating under ANY applicable requirement stays gating', () async {
    for (final id in ['l1', 'l2', 'l3']) {
      await seedLearning('org-alpha', id);
    }
    await seedRequirement(
      'org-alpha',
      'rA',
      requiredLearningIds: ['l1', 'l2', 'l3'],
      gatesAttendance: true,
      learningSettings: {
        'l1': {'gatesAttendance': true, 'requiredBeforeWork': false},
        'l2': {'gatesAttendance': false, 'requiredBeforeWork': true},
        'l3': {'gatesAttendance': false, 'requiredBeforeWork': false},
      },
    );
    await seedRequirement(
      'org-alpha',
      'rB',
      requiredLearningIds: ['l3'],
      learningSettings: {
        'l3': {'gatesAttendance': true, 'requiredBeforeWork': false},
      },
    );

    final repository = SafetyRequirementRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final gating = await repository
        .watchAttendanceGatingLearningForScope(
          siteId: 'site-1',
          activityIds: const [],
        )
        .first;
    final required = await repository
        .watchResolvedRequiredLearning('worker-1')
        .first;

    expect(gating.map((l) => l.id).toSet(), {'l1', 'l3'});
    expect(required.map((l) => l.id).toSet(), {'l1', 'l2', 'l3'});
  });
}
