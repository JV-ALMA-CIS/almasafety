import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/features/organizations/domain/organization_record_status.dart';
import 'package:jva_safety/features/organizations/domain/project.dart';

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<DocumentSnapshot<Map<String, dynamic>>> seedProject(
    String id,
    Map<String, dynamic> data,
  ) async {
    final ref = firestore.doc('organizations/org-alpha/projects/$id');
    await ref.set(data);
    return ref.get();
  }

  Map<String, dynamic> validData({
    String status = 'active',
    String? organizationId = 'org-alpha',
  }) {
    return {
      'organizationId': ?organizationId,
      'name': 'Rosslyn Tower',
      'code': 'ROSS-01',
      'status': status,
      'createdAt': Timestamp.fromDate(DateTime(2026, 1, 1)),
      'updatedAt': Timestamp.fromDate(DateTime(2026, 1, 2)),
      'createdBy': 'sysadmin-uid',
      'updatedBy': 'sysadmin-uid',
    };
  }

  group('Project.fromFirestore', () {
    test('parses every field', () async {
      final doc = await seedProject('project-1', {
        ...validData(),
        'description': 'A commercial tower.',
        'startDate': Timestamp.fromDate(DateTime(2026, 2, 1)),
        'endDate': Timestamp.fromDate(DateTime(2027, 2, 1)),
      });

      final project = Project.fromFirestore(doc);

      expect(project.id, 'project-1');
      expect(project.organizationId, 'org-alpha');
      expect(project.name, 'Rosslyn Tower');
      expect(project.code, 'ROSS-01');
      expect(project.description, 'A commercial tower.');
      expect(project.status, OrganizationRecordStatus.active);
      expect(project.startDate, DateTime(2026, 2, 1));
      expect(project.endDate, DateTime(2027, 2, 1));
      expect(project.createdBy, 'sysadmin-uid');
    });

    test('description/dates are optional', () async {
      final doc = await seedProject('project-2', validData());

      final project = Project.fromFirestore(doc);

      expect(project.description, isNull);
      expect(project.startDate, isNull);
      expect(project.endDate, isNull);
    });

    test('throws when organizationId is missing', () async {
      final doc = await seedProject(
        'project-bad',
        validData(organizationId: null),
      );

      expect(
        () => Project.fromFirestore(doc),
        throwsA(isA<DataException>()),
      );
    });

    test('throws on an unrecognised status', () async {
      final doc = await seedProject('project-bad-status',
          validData(status: 'archived'));

      expect(
        () => Project.fromFirestore(doc),
        throwsA(isA<DataException>()),
      );
    });
  });
}
