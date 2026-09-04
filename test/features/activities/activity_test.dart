import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/features/activities/domain/activity.dart';
import 'package:jva_safety/features/organizations/domain/organization_record_status.dart';

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<DocumentSnapshot<Map<String, dynamic>>> seedActivity(
    String id,
    Map<String, dynamic> data,
  ) async {
    final ref = firestore.doc('organizations/org-alpha/activities/$id');
    await ref.set(data);
    return ref.get();
  }

  Map<String, dynamic> validData({
    String status = 'active',
    String? organizationId = 'org-alpha',
    String? projectId = 'project-1',
    String? siteId = 'site-1',
  }) {
    return {
      'organizationId': ?organizationId,
      'projectId': ?projectId,
      'siteId': ?siteId,
      'name': 'Concrete Pour',
      'code': 'ACT-001',
      'status': status,
      'createdAt': Timestamp.fromDate(DateTime(2026, 1, 1)),
      'updatedAt': Timestamp.fromDate(DateTime(2026, 1, 2)),
      'createdBy': 'admin-uid',
      'updatedBy': 'admin-uid',
    };
  }

  group('Activity.fromFirestore', () {
    test('parses every field', () async {
      final doc = await seedActivity('activity-1', {
        ...validData(),
        'description': 'Pour the foundation slab.',
      });

      final activity = Activity.fromFirestore(doc);

      expect(activity.id, 'activity-1');
      expect(activity.organizationId, 'org-alpha');
      expect(activity.projectId, 'project-1');
      expect(activity.siteId, 'site-1');
      expect(activity.name, 'Concrete Pour');
      expect(activity.code, 'ACT-001');
      expect(activity.description, 'Pour the foundation slab.');
      expect(activity.status, OrganizationRecordStatus.active);
    });

    test('description is optional', () async {
      final doc = await seedActivity('activity-2', validData());

      final activity = Activity.fromFirestore(doc);

      expect(activity.description, isNull);
    });

    test('throws when organizationId is missing', () async {
      final doc = await seedActivity(
        'activity-bad-org',
        validData(organizationId: null),
      );

      expect(() => Activity.fromFirestore(doc), throwsA(isA<DataException>()));
    });

    test('throws when projectId is missing', () async {
      final doc = await seedActivity(
        'activity-bad-project',
        validData(projectId: null),
      );

      expect(() => Activity.fromFirestore(doc), throwsA(isA<DataException>()));
    });

    test('throws when siteId is missing', () async {
      final doc = await seedActivity(
        'activity-bad-site',
        validData(siteId: null),
      );

      expect(() => Activity.fromFirestore(doc), throwsA(isA<DataException>()));
    });

    test('throws on an unrecognised status', () async {
      final doc = await seedActivity(
        'activity-bad-status',
        validData(status: 'gone'),
      );

      expect(() => Activity.fromFirestore(doc), throwsA(isA<DataException>()));
    });
  });
}
