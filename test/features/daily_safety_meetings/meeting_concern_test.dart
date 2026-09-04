import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/features/daily_safety_meetings/domain/meeting_concern.dart';
import 'package:jva_safety/features/daily_safety_meetings/domain/meeting_concern_category.dart';
import 'package:jva_safety/features/daily_safety_meetings/domain/meeting_concern_status.dart';

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<DocumentSnapshot<Map<String, dynamic>>> seed(
    Map<String, dynamic> data,
  ) async {
    final ref = firestore.doc(
      'organizations/org-alpha/daily_safety_meetings/m1/concerns/c1',
    );
    await ref.set(data);
    return ref.get();
  }

  test('fromFirestore parses every field', () async {
    final doc = await seed({
      'meetingId': 'm1',
      'organizationId': 'org-alpha',
      'siteId': 'site-1',
      'description': 'Loose scaffolding on level 3',
      'category': 'safety',
      'reportedBy': 'foreman-1',
      'status': 'open',
      'createdAt': Timestamp.now(),
    });

    final concern = MeetingConcern.fromFirestore(doc);

    expect(concern.id, 'c1');
    expect(concern.meetingId, 'm1');
    expect(concern.organizationId, 'org-alpha');
    expect(concern.siteId, 'site-1');
    expect(concern.description, 'Loose scaffolding on level 3');
    expect(concern.category, MeetingConcernCategory.safety);
    expect(concern.reportedBy, 'foreman-1');
    expect(concern.status, MeetingConcernStatus.open);
  });

  test('throws when organizationId is missing', () async {
    final doc = await seed({
      'meetingId': 'm1',
      'siteId': 'site-1',
      'description': 'x',
      'category': 'safety',
      'reportedBy': 'foreman-1',
      'status': 'open',
    });

    expect(
      () => MeetingConcern.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('throws when siteId is missing', () async {
    final doc = await seed({
      'meetingId': 'm1',
      'organizationId': 'org-alpha',
      'description': 'x',
      'category': 'safety',
      'reportedBy': 'foreman-1',
      'status': 'open',
    });

    expect(
      () => MeetingConcern.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('throws when meetingId is missing', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'siteId': 'site-1',
      'description': 'x',
      'category': 'safety',
      'reportedBy': 'foreman-1',
      'status': 'open',
    });

    expect(
      () => MeetingConcern.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('throws when description is missing', () async {
    final doc = await seed({
      'meetingId': 'm1',
      'organizationId': 'org-alpha',
      'siteId': 'site-1',
      'category': 'safety',
      'reportedBy': 'foreman-1',
      'status': 'open',
    });

    expect(
      () => MeetingConcern.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('throws when reportedBy is missing', () async {
    final doc = await seed({
      'meetingId': 'm1',
      'organizationId': 'org-alpha',
      'siteId': 'site-1',
      'description': 'x',
      'category': 'safety',
      'status': 'open',
    });

    expect(
      () => MeetingConcern.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('throws on an unrecognised status', () async {
    final doc = await seed({
      'meetingId': 'm1',
      'organizationId': 'org-alpha',
      'siteId': 'site-1',
      'description': 'x',
      'category': 'safety',
      'reportedBy': 'foreman-1',
      'status': 'archived',
    });

    expect(
      () => MeetingConcern.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('throws on an unrecognised category', () async {
    final doc = await seed({
      'meetingId': 'm1',
      'organizationId': 'org-alpha',
      'siteId': 'site-1',
      'description': 'x',
      'category': 'weather',
      'reportedBy': 'foreman-1',
      'status': 'open',
    });

    expect(
      () => MeetingConcern.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('every MeetingConcernStatus round-trips through its stored id', () {
    for (final status in MeetingConcernStatus.values) {
      expect(MeetingConcernStatus.tryFromId(status.id), status);
    }
    expect(MeetingConcernStatus.tryFromId('unknown'), isNull);
    expect(MeetingConcernStatus.tryFromId(null), isNull);
  });

  test('every MeetingConcernCategory round-trips through its stored id', () {
    for (final category in MeetingConcernCategory.values) {
      expect(MeetingConcernCategory.tryFromId(category.id), category);
    }
    expect(MeetingConcernCategory.tryFromId('unknown'), isNull);
    expect(MeetingConcernCategory.tryFromId(null), isNull);
  });

  test('the five expected categories exist', () {
    expect(
      MeetingConcernCategory.values.map((c) => c.id).toSet(),
      {'safety', 'equipment', 'environment', 'worker', 'other'},
    );
  });
}
