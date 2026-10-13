import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/features/hazards/domain/hazard.dart';
import 'package:jva_safety/features/hazards/domain/hazard_category.dart';
import 'package:jva_safety/features/hazards/domain/hazard_kind.dart';
import 'package:jva_safety/features/hazards/domain/hazard_status.dart';

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<DocumentSnapshot<Map<String, dynamic>>> seed(
    Map<String, dynamic> data,
  ) async {
    final ref = firestore.doc('organizations/org-alpha/hazards/hazard-1');
    await ref.set(data);
    return ref.get();
  }

  test('fromFirestore parses every field', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': 'site-1',
      'reportedByUid': 'worker-1',
      'category': 'electrical',
      'description': 'Exposed wiring near the water tank',
      'location': 'East wing, 3rd floor',
      'photoUrl': 'organizations/org-alpha/hazards/hazard-1/photo.jpg',
      'status': 'reported',
      'correctiveActionId': null,
      'acknowledgedBy': null,
      'acknowledgedAt': null,
      'closedBy': null,
      'closedAt': null,
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });

    final hazard = Hazard.fromFirestore(doc);

    expect(hazard.id, 'hazard-1');
    expect(hazard.organizationId, 'org-alpha');
    expect(hazard.projectId, 'project-1');
    expect(hazard.siteId, 'site-1');
    expect(hazard.reportedByUid, 'worker-1');
    expect(hazard.category, HazardCategory.electrical);
    expect(hazard.description, 'Exposed wiring near the water tank');
    expect(hazard.location, 'East wing, 3rd floor');
    expect(
      hazard.photoUrl,
      'organizations/org-alpha/hazards/hazard-1/photo.jpg',
    );
    expect(hazard.status, HazardStatus.reported);
    expect(hazard.correctiveActionId, isNull);
    expect(hazard.isClosed, isFalse);
    expect(hazard.canCloseDirectly, isTrue);
  });

  test('location and photoUrl are null when absent (both optional)', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': 'site-1',
      'reportedByUid': 'worker-1',
      'category': 'ppe',
      'description': 'Worker without hard hat',
      'status': 'reported',
    });

    final hazard = Hazard.fromFirestore(doc);

    expect(hazard.location, isNull);
    expect(hazard.photoUrl, isNull);
  });

  test('isClosed and canCloseDirectly reflect status correctly', () async {
    final cases = {
      'reported': (isClosed: false, canCloseDirectly: true),
      'acknowledged': (isClosed: false, canCloseDirectly: true),
      'correctiveActionCreated': (isClosed: false, canCloseDirectly: false),
      'closed': (isClosed: true, canCloseDirectly: false),
    };

    for (final entry in cases.entries) {
      final doc = await seed({
        'organizationId': 'org-alpha',
        'projectId': 'project-1',
        'siteId': 'site-1',
        'reportedByUid': 'worker-1',
        'category': 'other',
        'description': 'x',
        'status': entry.key,
      });
      final hazard = Hazard.fromFirestore(doc);
      expect(hazard.isClosed, entry.value.isClosed, reason: entry.key);
      expect(
        hazard.canCloseDirectly,
        entry.value.canCloseDirectly,
        reason: entry.key,
      );
    }
  });

  test('throws when organizationId is missing', () async {
    final doc = await seed({
      'projectId': 'project-1',
      'siteId': 'site-1',
      'reportedByUid': 'worker-1',
      'category': 'fire',
      'description': 'x',
      'status': 'reported',
    });

    expect(() => Hazard.fromFirestore(doc), throwsA(isA<DataException>()));
  });

  test('throws when siteId is missing', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'reportedByUid': 'worker-1',
      'category': 'fire',
      'description': 'x',
      'status': 'reported',
    });

    expect(() => Hazard.fromFirestore(doc), throwsA(isA<DataException>()));
  });

  test('throws when reportedByUid is missing', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': 'site-1',
      'category': 'fire',
      'description': 'x',
      'status': 'reported',
    });

    expect(() => Hazard.fromFirestore(doc), throwsA(isA<DataException>()));
  });

  test('throws when description is missing', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': 'site-1',
      'reportedByUid': 'worker-1',
      'category': 'fire',
      'status': 'reported',
    });

    expect(() => Hazard.fromFirestore(doc), throwsA(isA<DataException>()));
  });

  test('throws on an unrecognised category', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': 'site-1',
      'reportedByUid': 'worker-1',
      'category': 'notARealCategory',
      'description': 'x',
      'status': 'reported',
    });

    expect(() => Hazard.fromFirestore(doc), throwsA(isA<DataException>()));
  });

  test('throws on an unrecognised status', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': 'site-1',
      'reportedByUid': 'worker-1',
      'category': 'fire',
      'description': 'x',
      'status': 'archived',
    });

    expect(() => Hazard.fromFirestore(doc), throwsA(isA<DataException>()));
  });

  test('every HazardCategory round-trips through its stored id', () {
    for (final category in HazardCategory.values) {
      expect(HazardCategory.tryFromId(category.id), category);
    }
    expect(HazardCategory.tryFromId('unknown'), isNull);
    expect(HazardCategory.tryFromId(null), isNull);
  });

  test('every HazardStatus round-trips through its stored id', () {
    for (final status in HazardStatus.values) {
      expect(HazardStatus.tryFromId(status.id), status);
    }
    expect(HazardStatus.tryFromId('unknown'), isNull);
    expect(HazardStatus.tryFromId(null), isNull);
  });

  test('the nine expected categories exist', () {
    expect(HazardCategory.values.map((c) => c.id).toSet(), {
      'workingAtHeight',
      'electrical',
      'equipment',
      'ppe',
      'housekeeping',
      'environment',
      'chemical',
      'fire',
      'other',
    });
  });

  test('the four expected statuses exist', () {
    expect(HazardStatus.values.map((s) => s.id).toSet(), {
      'reported',
      'acknowledged',
      'correctiveActionCreated',
      'closed',
    });
  });

  Map<String, dynamic> minimal([Map<String, dynamic> extra = const {}]) => {
    'organizationId': 'org-alpha',
    'projectId': 'project-1',
    'siteId': 'site-1',
    'reportedByUid': 'worker-1',
    'category': 'workingAtHeight',
    'description': 'Hammer fell from scaffold',
    'status': 'reported',
    ...extra,
  };

  test('kind defaults to hazard when absent (reports filed before '
      'near-misses existed)', () async {
    final hazard = Hazard.fromFirestore(await seed(minimal()));
    expect(hazard.kind, HazardKind.hazard);
  });

  test('parses a near-miss', () async {
    final hazard = Hazard.fromFirestore(
      await seed(minimal({'kind': 'nearMiss'})),
    );
    expect(hazard.kind, HazardKind.nearMiss);
    expect(hazard.category, HazardCategory.workingAtHeight);
  });

  test('throws on an unrecognised kind', () async {
    final doc = await seed(minimal({'kind': 'incident'}));
    expect(() => Hazard.fromFirestore(doc), throwsA(isA<DataException>()));
  });
}
