import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/features/corrective_actions/domain/corrective_action.dart';
import 'package:jva_safety/features/corrective_actions/domain/corrective_action_status.dart';

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<DocumentSnapshot<Map<String, dynamic>>> seed(
    Map<String, dynamic> data,
  ) async {
    final ref = firestore.doc('organizations/org-alpha/corrective_actions/ca1');
    await ref.set(data);
    return ref.get();
  }

  test('fromFirestore parses every field', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': 'site-1',
      'meetingId': 'm1',
      'concernId': 'c1',
      'title': 'Fix loose scaffolding',
      'description': 'Level 3 scaffolding needs tightening',
      'assignedTo': 'worker-1',
      'assignedBy': 'foreman-1',
      'dueDate': Timestamp.fromDate(DateTime(2026, 9, 1)),
      'status': 'open',
      'evidenceRequired': true,
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
      'completedAt': null,
    });

    final action = CorrectiveAction.fromFirestore(doc);

    expect(action.id, 'ca1');
    expect(action.organizationId, 'org-alpha');
    expect(action.projectId, 'project-1');
    expect(action.siteId, 'site-1');
    expect(action.meetingId, 'm1');
    expect(action.concernId, 'c1');
    expect(action.title, 'Fix loose scaffolding');
    expect(action.description, 'Level 3 scaffolding needs tightening');
    expect(action.assignedTo, 'worker-1');
    expect(action.assignedBy, 'foreman-1');
    expect(action.dueDate, DateTime(2026, 9, 1));
    expect(action.status, CorrectiveActionStatus.open);
    expect(action.evidenceRequired, isTrue);
    expect(action.isCompleted, isFalse);
  });

  test('concernId is null when raised directly from the meeting', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': 'site-1',
      'meetingId': 'm1',
      'title': 'Fix loose scaffolding',
      'description': 'Level 3 scaffolding needs tightening',
      'assignedTo': 'worker-1',
      'assignedBy': 'foreman-1',
      'dueDate': Timestamp.fromDate(DateTime(2026, 9, 1)),
      'status': 'open',
    });

    final action = CorrectiveAction.fromFirestore(doc);

    expect(action.concernId, isNull);
  });

  test('evidenceRequired defaults to false when absent', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': 'site-1',
      'meetingId': 'm1',
      'title': 'Fix loose scaffolding',
      'description': 'Level 3 scaffolding needs tightening',
      'assignedTo': 'worker-1',
      'assignedBy': 'foreman-1',
      'dueDate': Timestamp.fromDate(DateTime(2026, 9, 1)),
      'status': 'open',
    });

    final action = CorrectiveAction.fromFirestore(doc);

    expect(action.evidenceRequired, isFalse);
  });

  test('isCompleted is true only for the completed status', () async {
    for (final status in CorrectiveActionStatus.values) {
      final doc = await seed({
        'organizationId': 'org-alpha',
        'projectId': 'project-1',
        'siteId': 'site-1',
        'meetingId': 'm1',
        'title': 'x',
        'description': 'x',
        'assignedTo': 'worker-1',
        'assignedBy': 'foreman-1',
        'dueDate': Timestamp.fromDate(DateTime(2026, 9, 1)),
        'status': status.id,
      });
      final action = CorrectiveAction.fromFirestore(doc);
      expect(
        action.isCompleted,
        status == CorrectiveActionStatus.completed,
        reason: 'status ${status.id}',
      );
    }
  });

  test('throws when organizationId is missing', () async {
    final doc = await seed({
      'projectId': 'project-1',
      'siteId': 'site-1',
      'meetingId': 'm1',
      'title': 'x',
      'description': 'x',
      'assignedTo': 'worker-1',
      'assignedBy': 'foreman-1',
      'dueDate': Timestamp.fromDate(DateTime(2026, 9, 1)),
      'status': 'open',
    });

    expect(
      () => CorrectiveAction.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('throws when projectId is missing', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'siteId': 'site-1',
      'meetingId': 'm1',
      'title': 'x',
      'description': 'x',
      'assignedTo': 'worker-1',
      'assignedBy': 'foreman-1',
      'dueDate': Timestamp.fromDate(DateTime(2026, 9, 1)),
      'status': 'open',
    });

    expect(
      () => CorrectiveAction.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('throws when siteId is missing', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'meetingId': 'm1',
      'title': 'x',
      'description': 'x',
      'assignedTo': 'worker-1',
      'assignedBy': 'foreman-1',
      'dueDate': Timestamp.fromDate(DateTime(2026, 9, 1)),
      'status': 'open',
    });

    expect(
      () => CorrectiveAction.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('throws when neither meetingId nor hazardId is present', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': 'site-1',
      'title': 'x',
      'description': 'x',
      'assignedTo': 'worker-1',
      'assignedBy': 'foreman-1',
      'dueDate': Timestamp.fromDate(DateTime(2026, 9, 1)),
      'status': 'open',
    });

    expect(
      () => CorrectiveAction.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('throws when both meetingId and hazardId are present', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': 'site-1',
      'meetingId': 'm1',
      'hazardId': 'hazard-1',
      'title': 'x',
      'description': 'x',
      'assignedTo': 'worker-1',
      'assignedBy': 'foreman-1',
      'dueDate': Timestamp.fromDate(DateTime(2026, 9, 1)),
      'status': 'open',
    });

    expect(
      () => CorrectiveAction.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test(
    'parses a hazard-originated action (meetingId null, hazardId set)',
    () async {
      final doc = await seed({
        'organizationId': 'org-alpha',
        'projectId': 'project-1',
        'siteId': 'site-1',
        'hazardId': 'hazard-1',
        'title': 'Isolate exposed wiring',
        'description': 'De-energize before re-use',
        'assignedTo': 'worker-1',
        'assignedBy': 'reviewer-1',
        'dueDate': Timestamp.fromDate(DateTime(2026, 9, 1)),
        'status': 'open',
      });

      final action = CorrectiveAction.fromFirestore(doc);

      expect(action.hazardId, 'hazard-1');
      expect(action.meetingId, isNull);
      expect(action.concernId, isNull);
    },
  );

  test('throws when title is missing', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': 'site-1',
      'meetingId': 'm1',
      'description': 'x',
      'assignedTo': 'worker-1',
      'assignedBy': 'foreman-1',
      'dueDate': Timestamp.fromDate(DateTime(2026, 9, 1)),
      'status': 'open',
    });

    expect(
      () => CorrectiveAction.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('throws when description is missing', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': 'site-1',
      'meetingId': 'm1',
      'title': 'x',
      'assignedTo': 'worker-1',
      'assignedBy': 'foreman-1',
      'dueDate': Timestamp.fromDate(DateTime(2026, 9, 1)),
      'status': 'open',
    });

    expect(
      () => CorrectiveAction.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('throws when assignedTo is missing', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': 'site-1',
      'meetingId': 'm1',
      'title': 'x',
      'description': 'x',
      'assignedBy': 'foreman-1',
      'dueDate': Timestamp.fromDate(DateTime(2026, 9, 1)),
      'status': 'open',
    });

    expect(
      () => CorrectiveAction.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('throws when assignedBy is missing', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': 'site-1',
      'meetingId': 'm1',
      'title': 'x',
      'description': 'x',
      'assignedTo': 'worker-1',
      'dueDate': Timestamp.fromDate(DateTime(2026, 9, 1)),
      'status': 'open',
    });

    expect(
      () => CorrectiveAction.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('throws when dueDate is missing', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': 'site-1',
      'meetingId': 'm1',
      'title': 'x',
      'description': 'x',
      'assignedTo': 'worker-1',
      'assignedBy': 'foreman-1',
      'status': 'open',
    });

    expect(
      () => CorrectiveAction.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('throws on an unrecognised status', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': 'site-1',
      'meetingId': 'm1',
      'title': 'x',
      'description': 'x',
      'assignedTo': 'worker-1',
      'assignedBy': 'foreman-1',
      'dueDate': Timestamp.fromDate(DateTime(2026, 9, 1)),
      'status': 'archived',
    });

    expect(
      () => CorrectiveAction.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('every CorrectiveActionStatus round-trips through its stored id', () {
    for (final status in CorrectiveActionStatus.values) {
      expect(CorrectiveActionStatus.tryFromId(status.id), status);
    }
    expect(CorrectiveActionStatus.tryFromId('unknown'), isNull);
    expect(CorrectiveActionStatus.tryFromId(null), isNull);
  });

  test('the five expected statuses exist', () {
    expect(CorrectiveActionStatus.values.map((s) => s.id).toSet(), {
      'open',
      'inProgress',
      'submittedForReview',
      'completed',
      'overdue',
    });
  });
}
