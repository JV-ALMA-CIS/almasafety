import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/features/safety_learning/domain/worker_learning_record.dart';
import 'package:jva_safety/features/safety_learning/domain/worker_learning_status.dart';

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<DocumentSnapshot<Map<String, dynamic>>> seed(
    Map<String, dynamic> data,
  ) async {
    final ref = firestore.doc(
      'organizations/org-alpha/worker_learning_records/worker-1_l1',
    );
    await ref.set(data);
    return ref.get();
  }

  test('fromFirestore parses an assigned record', () async {
    final doc = await seed({
      'workerUid': 'worker-1',
      'organizationId': 'org-alpha',
      'learningId': 'l1',
      'status': 'assigned',
      'assignedAt': Timestamp.now(),
    });

    final record = WorkerLearningRecord.fromFirestore(doc);

    expect(record.id, 'worker-1_l1');
    expect(record.workerUid, 'worker-1');
    expect(record.organizationId, 'org-alpha');
    expect(record.learningId, 'l1');
    expect(record.status, WorkerLearningStatus.assigned);
    expect(record.startedAt, isNull);
    expect(record.completedAt, isNull);
    expect(record.knowledgeCheckResult, isNull);
  });

  test('fromFirestore parses a completed record with a server-graded '
      'knowledge check result', () async {
    final doc = await seed({
      'workerUid': 'worker-1',
      'organizationId': 'org-alpha',
      'learningId': 'l1',
      'status': 'completed',
      'assignedAt': Timestamp.now(),
      'startedAt': Timestamp.now(),
      'completedAt': Timestamp.now(),
      'knowledgeCheckResult': {
        'passed': true,
        'score': 9,
        'totalQuestions': 10,
      },
    });

    final record = WorkerLearningRecord.fromFirestore(doc);

    expect(record.status, WorkerLearningStatus.completed);
    expect(record.completedAt, isNotNull);
    expect(record.knowledgeCheckResult, isNotNull);
    expect(record.knowledgeCheckResult!.passed, isTrue);
    expect(record.knowledgeCheckResult!.score, 9);
    expect(record.knowledgeCheckResult!.totalQuestions, 10);
  });

  test('fromFirestore still parses a record completed BEFORE this phase — '
      'the old self-attested {passed: true} shape with no score/'
      'totalQuestions at all', () async {
    final doc = await seed({
      'workerUid': 'worker-1',
      'organizationId': 'org-alpha',
      'learningId': 'l1',
      'status': 'completed',
      'assignedAt': Timestamp.now(),
      'startedAt': Timestamp.now(),
      'completedAt': Timestamp.now(),
      'knowledgeCheckResult': {'passed': true},
    });

    final record = WorkerLearningRecord.fromFirestore(doc);

    expect(record.status, WorkerLearningStatus.completed);
    expect(record.knowledgeCheckResult, isNotNull);
    expect(record.knowledgeCheckResult!.passed, isTrue);
    expect(record.knowledgeCheckResult!.score, isNull);
    expect(record.knowledgeCheckResult!.totalQuestions, isNull);
  });

  test('throws when workerUid is missing', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'learningId': 'l1',
      'status': 'assigned',
    });

    expect(
      () => WorkerLearningRecord.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('throws when organizationId is missing', () async {
    final doc = await seed({
      'workerUid': 'worker-1',
      'learningId': 'l1',
      'status': 'assigned',
    });

    expect(
      () => WorkerLearningRecord.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('throws when learningId is missing', () async {
    final doc = await seed({
      'workerUid': 'worker-1',
      'organizationId': 'org-alpha',
      'status': 'assigned',
    });

    expect(
      () => WorkerLearningRecord.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('throws on an unrecognised status', () async {
    final doc = await seed({
      'workerUid': 'worker-1',
      'organizationId': 'org-alpha',
      'learningId': 'l1',
      'status': 'done',
    });

    expect(
      () => WorkerLearningRecord.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('every WorkerLearningStatus round-trips through its stored id', () {
    for (final status in WorkerLearningStatus.values) {
      expect(WorkerLearningStatus.tryFromId(status.id), status);
    }
    expect(WorkerLearningStatus.tryFromId('unknown'), isNull);
    expect(WorkerLearningStatus.tryFromId(null), isNull);
  });
}
