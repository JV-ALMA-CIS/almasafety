import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/features/safety_learning/domain/safety_learning.dart';
import 'package:jva_safety/features/safety_learning/domain/safety_learning_type.dart';

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<DocumentSnapshot<Map<String, dynamic>>> seed(
    Map<String, dynamic> data,
  ) async {
    final ref = firestore.doc('organizations/org-alpha/safety_learning/l1');
    await ref.set(data);
    return ref.get();
  }

  test('fromFirestore parses every field', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'title': 'Fall Protection Basics',
      'description': 'An introduction to fall protection.',
      'type': 'video',
      'contentReference': 'https://example.com/video.mp4',
      'status': 'active',
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
      'createdBy': 'admin-1',
      'updatedBy': 'admin-1',
    });

    final learning = SafetyLearning.fromFirestore(doc);

    expect(learning.id, 'l1');
    expect(learning.organizationId, 'org-alpha');
    expect(learning.title, 'Fall Protection Basics');
    expect(learning.description, 'An introduction to fall protection.');
    expect(learning.type, SafetyLearningType.video);
    expect(learning.contentReference, 'https://example.com/video.mp4');
    expect(learning.status.id, 'active');
    expect(learning.createdBy, 'admin-1');
    expect(learning.updatedBy, 'admin-1');
  });

  test('description is optional', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'title': 'PPE Course',
      'type': 'course',
      'contentReference': 'ref-1',
      'status': 'active',
    });

    final learning = SafetyLearning.fromFirestore(doc);

    expect(learning.description, isNull);
  });

  test('minimumWatchSeconds parses when present', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'title': 'Working at Height',
      'type': 'video',
      'contentReference': 'https://example.com/video.mp4',
      'status': 'active',
      'minimumWatchSeconds': 90,
    });

    final learning = SafetyLearning.fromFirestore(doc);

    expect(learning.minimumWatchSeconds, 90);
  });

  test(
    'minimumWatchSeconds is null when absent — a pre-existing video '
    'item (created before this field existed) still parses cleanly',
    () async {
      final doc = await seed({
        'organizationId': 'org-alpha',
        'title': 'Working at Height',
        'type': 'video',
        'contentReference': 'https://example.com/video.mp4',
        'status': 'active',
      });

      final learning = SafetyLearning.fromFirestore(doc);

      expect(learning.minimumWatchSeconds, isNull);
    },
  );

  test('passingScorePercent parses when present', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'title': 'Working at Height',
      'type': 'video',
      'contentReference': 'https://example.com/video.mp4',
      'status': 'active',
      'passingScorePercent': 80,
    });

    final learning = SafetyLearning.fromFirestore(doc);

    expect(learning.passingScorePercent, 80);
  });

  test('passingScorePercent is null when absent — a pre-existing item '
      '(created before this field existed) still parses cleanly', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'title': 'Working at Height',
      'type': 'knowledgeCheck',
      'contentReference': 'ref-1',
      'status': 'active',
    });

    final learning = SafetyLearning.fromFirestore(doc);

    expect(learning.passingScorePercent, isNull);
  });

  test('a video item can carry both minimumWatchSeconds and '
      'passingScorePercent at once', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'title': 'Working at Height',
      'type': 'video',
      'contentReference': 'https://example.com/video.mp4',
      'status': 'active',
      'minimumWatchSeconds': 60,
      'passingScorePercent': 80,
    });

    final learning = SafetyLearning.fromFirestore(doc);

    expect(learning.minimumWatchSeconds, 60);
    expect(learning.passingScorePercent, 80);
  });

  test('throws when organizationId is missing', () async {
    final doc = await seed({
      'title': 'PPE Course',
      'type': 'course',
      'contentReference': 'ref-1',
      'status': 'active',
    });

    expect(
      () => SafetyLearning.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('throws on an unrecognised status', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'title': 'PPE Course',
      'type': 'course',
      'contentReference': 'ref-1',
      'status': 'archived',
    });

    expect(
      () => SafetyLearning.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('throws on an unrecognised type', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'title': 'PPE Course',
      'type': 'podcast',
      'contentReference': 'ref-1',
      'status': 'active',
    });

    expect(
      () => SafetyLearning.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('every SafetyLearningType round-trips through its stored id', () {
    for (final type in SafetyLearningType.values) {
      expect(SafetyLearningType.tryFromId(type.id), type);
    }
    expect(SafetyLearningType.tryFromId('unknown'), isNull);
    expect(SafetyLearningType.tryFromId(null), isNull);
  });
}
