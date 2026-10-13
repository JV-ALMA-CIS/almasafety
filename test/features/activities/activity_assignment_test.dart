import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/features/activities/domain/activity_assignment.dart';

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<DocumentSnapshot<Map<String, dynamic>>> seedAssignment(
    String uid,
    Map<String, dynamic> data,
  ) async {
    final ref = firestore.doc(
      'organizations/org-alpha/activities/activity-1/assignments/$uid',
    );
    await ref.set(data);
    return ref.get();
  }

  Map<String, dynamic> validData({
    String? organizationId = 'org-alpha',
    String? siteId = 'site-1',
    String? activityId = 'activity-1',
  }) {
    return {
      'uid': 'worker-1',
      'organizationId': ?organizationId,
      'siteId': ?siteId,
      'activityId': ?activityId,
      'assignedAt': Timestamp.fromDate(DateTime(2026, 1, 1)),
      'assignedBy': 'admin-uid',
    };
  }

  group('ActivityAssignment.fromFirestore', () {
    test('parses every field', () async {
      final doc = await seedAssignment('worker-1', validData());

      final assignment = ActivityAssignment.fromFirestore(doc);

      expect(assignment.uid, 'worker-1');
      expect(assignment.organizationId, 'org-alpha');
      expect(assignment.siteId, 'site-1');
      expect(assignment.activityId, 'activity-1');
      expect(assignment.assignedAt, DateTime(2026, 1, 1));
      expect(assignment.assignedBy, 'admin-uid');
    });

    test('throws when organizationId is missing', () async {
      final doc = await seedAssignment(
        'worker-1',
        validData(organizationId: null),
      );

      expect(
        () => ActivityAssignment.fromFirestore(doc),
        throwsA(isA<DataException>()),
      );
    });

    test('throws when siteId is missing', () async {
      final doc = await seedAssignment('worker-1', validData(siteId: null));

      expect(
        () => ActivityAssignment.fromFirestore(doc),
        throwsA(isA<DataException>()),
      );
    });

    test('throws when activityId is missing', () async {
      final doc = await seedAssignment('worker-1', validData(activityId: null));

      expect(
        () => ActivityAssignment.fromFirestore(doc),
        throwsA(isA<DataException>()),
      );
    });
  });
}
