import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/features/organizations/domain/organization_record_status.dart';
import 'package:jva_safety/features/organizations/domain/site.dart';

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<DocumentSnapshot<Map<String, dynamic>>> seedSite(
    String id,
    Map<String, dynamic> data,
  ) async {
    final ref = firestore.doc('organizations/org-alpha/sites/$id');
    await ref.set(data);
    return ref.get();
  }

  Map<String, dynamic> validData({
    String status = 'active',
    String? organizationId = 'org-alpha',
    String? projectId = 'project-1',
  }) {
    return {
      'organizationId': ?organizationId,
      'projectId': ?projectId,
      'name': 'Rosslyn Site',
      'code': 'ROSS-SITE-01',
      'status': status,
      'createdAt': Timestamp.fromDate(DateTime(2026, 1, 1)),
      'updatedAt': Timestamp.fromDate(DateTime(2026, 1, 2)),
      'createdBy': 'sysadmin-uid',
      'updatedBy': 'sysadmin-uid',
    };
  }

  group('Site.fromFirestore', () {
    test('parses every field', () async {
      final doc = await seedSite('site-1', {
        ...validData(),
        'location': 'Rosslyn, Nairobi',
        'description': 'Main construction site.',
      });

      final site = Site.fromFirestore(doc);

      expect(site.id, 'site-1');
      expect(site.organizationId, 'org-alpha');
      expect(site.projectId, 'project-1');
      expect(site.name, 'Rosslyn Site');
      expect(site.code, 'ROSS-SITE-01');
      expect(site.location, 'Rosslyn, Nairobi');
      expect(site.description, 'Main construction site.');
      expect(site.status, OrganizationRecordStatus.active);
    });

    test('location/description are optional', () async {
      final doc = await seedSite('site-2', validData());

      final site = Site.fromFirestore(doc);

      expect(site.location, isNull);
      expect(site.description, isNull);
    });

    test('throws when organizationId is missing', () async {
      final doc = await seedSite(
        'site-bad-org',
        validData(organizationId: null),
      );

      expect(() => Site.fromFirestore(doc), throwsA(isA<DataException>()));
    });

    test('throws when projectId is missing', () async {
      final doc = await seedSite(
        'site-bad-project',
        validData(projectId: null),
      );

      expect(() => Site.fromFirestore(doc), throwsA(isA<DataException>()));
    });

    test('throws on an unrecognised status', () async {
      final doc = await seedSite('site-bad-status', validData(status: 'gone'));

      expect(() => Site.fromFirestore(doc), throwsA(isA<DataException>()));
    });
  });
}
