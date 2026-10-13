import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/features/organizations/domain/organization.dart';
import 'package:jva_safety/features/organizations/domain/organization_record_status.dart';

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<DocumentSnapshot<Map<String, dynamic>>> seedOrg(
    String id,
    Map<String, dynamic> data,
  ) async {
    final ref = firestore.doc('organizations/$id');
    await ref.set(data);
    return ref.get();
  }

  Map<String, dynamic> validData({String status = 'active'}) {
    return {
      'name': 'JV Alma CIS',
      'code': 'JV-ALMA-CIS',
      'status': status,
      'createdAt': Timestamp.fromDate(DateTime(2026, 1, 1)),
      'updatedAt': Timestamp.fromDate(DateTime(2026, 1, 2)),
      'createdBy': 'sysadmin-uid',
      'updatedBy': 'sysadmin-uid',
    };
  }

  group('Organization.fromFirestore', () {
    test('parses every field', () async {
      final doc = await seedOrg('org-alpha', validData());

      final org = Organization.fromFirestore(doc);

      expect(org.id, 'org-alpha');
      expect(org.name, 'JV Alma CIS');
      expect(org.code, 'JV-ALMA-CIS');
      expect(org.status, OrganizationRecordStatus.active);
      expect(org.createdAt, DateTime(2026, 1, 1));
      expect(org.updatedAt, DateTime(2026, 1, 2));
      expect(org.createdBy, 'sysadmin-uid');
      expect(org.updatedBy, 'sysadmin-uid');
    });

    test('round-trips every status', () async {
      for (final status in OrganizationRecordStatus.values) {
        final doc = await seedOrg(
          'org-${status.id}',
          validData(status: status.id),
        );
        expect(Organization.fromFirestore(doc).status, status);
      }
    });

    test('throws on a missing document', () async {
      final doc = await firestore.doc('organizations/does-not-exist').get();

      expect(
        () => Organization.fromFirestore(doc),
        throwsA(isA<DataException>()),
      );
    });

    test('throws on an unrecognised status rather than defaulting', () async {
      final doc = await seedOrg('org-bad', validData(status: 'deleted'));

      expect(
        () => Organization.fromFirestore(doc),
        throwsA(isA<DataException>()),
      );
    });
  });
}
