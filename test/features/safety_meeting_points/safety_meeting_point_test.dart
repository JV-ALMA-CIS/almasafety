import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/features/safety_meeting_points/domain/safety_meeting_point.dart';

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<DocumentSnapshot<Map<String, dynamic>>> seed(
    Map<String, dynamic> data,
  ) async {
    final ref =
        firestore.doc('organizations/org-alpha/safety_meeting_points/mp1');
    await ref.set(data);
    return ref.get();
  }

  test('fromFirestore parses every field', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'title': 'Fall Protection Muster Point',
      'description': 'Gather here before high-risk work.',
      'category': 'Fall Protection',
      'applicableActivities': ['activity-1', 'activity-2'],
      'applicableRisks': ['high'],
      'status': 'active',
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
      'createdBy': 'admin-1',
      'updatedBy': 'admin-1',
    });

    final point = SafetyMeetingPoint.fromFirestore(doc);

    expect(point.id, 'mp1');
    expect(point.organizationId, 'org-alpha');
    expect(point.title, 'Fall Protection Muster Point');
    expect(point.description, 'Gather here before high-risk work.');
    expect(point.category, 'Fall Protection');
    expect(point.applicableActivities, ['activity-1', 'activity-2']);
    expect(point.applicableRisks, ['high']);
    expect(point.status.id, 'active');
    expect(point.isActive, isTrue);
    expect(point.createdBy, 'admin-1');
    expect(point.updatedBy, 'admin-1');
  });

  test('description and applicable lists are optional', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'title': 'General Muster Point',
      'category': 'General',
      'status': 'inactive',
    });

    final point = SafetyMeetingPoint.fromFirestore(doc);

    expect(point.description, isNull);
    expect(point.applicableActivities, isEmpty);
    expect(point.applicableRisks, isEmpty);
    expect(point.isActive, isFalse);
  });

  test('throws when organizationId is missing', () async {
    final doc = await seed({
      'title': 'General Muster Point',
      'category': 'General',
      'status': 'active',
    });

    expect(
      () => SafetyMeetingPoint.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('throws on an unrecognised status', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'title': 'General Muster Point',
      'category': 'General',
      'status': 'archived',
    });

    expect(
      () => SafetyMeetingPoint.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('throws on a missing document', () async {
    final ref =
        firestore.doc('organizations/org-alpha/safety_meeting_points/gone');
    final doc = await ref.get();

    expect(
      () => SafetyMeetingPoint.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });
}
