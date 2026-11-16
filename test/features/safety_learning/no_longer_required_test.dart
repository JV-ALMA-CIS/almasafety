import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/features/safety_learning/domain/lesson_quiz.dart';
import 'package:jva_safety/features/safety_learning/domain/no_longer_required.dart';
import 'package:jva_safety/features/safety_learning/domain/todays_safety_readiness.dart';
import 'package:jva_safety/features/safety_learning/domain/worker_learning_record.dart';
import 'package:jva_safety/features/safety_learning/domain/worker_learning_status.dart';

WorkerLearningRecord record(String id, WorkerLearningStatus status) =>
    WorkerLearningRecord(
      id: 'w1_$id',
      workerUid: 'w1',
      organizationId: 'org-alpha',
      learningId: id,
      status: status,
    );

ReadinessItem item(String id, {bool canStart = true}) => ReadinessItem(
  learningId: id,
  title: id,
  status: ReadinessItemStatus.notStarted,
  canStart: canStart,
);

void main() {
  group('noLongerRequiredLearningIds', () {
    test('an unfinished record missing from every readiness list is no '
        'longer required', () {
      final ids = noLongerRequiredLearningIds(
        [
          record('today', WorkerLearningStatus.assigned),
          record('work', WorkerLearningStatus.inProgress),
          record('later', WorkerLearningStatus.assigned),
          record('tomorrow', WorkerLearningStatus.assigned),
          record('stale', WorkerLearningStatus.inProgress),
          record('stale2', WorkerLearningStatus.assigned),
        ],
        TodaysSafetyReadiness(
          gatingSource: ReadinessGatingSource.assignments,
          beforeMeeting: [item('today')],
          beforeWork: [item('work')],
          additional: [item('later')],
          neededTomorrow: [item('tomorrow')],
        ),
      );
      expect(ids, {'stale', 'stale2'});
    });

    test('a meeting lesson the learner cannot start is not counted as '
        'still required of them', () {
      final ids = noLongerRequiredLearningIds(
        [record('meeting-only', WorkerLearningStatus.assigned)],
        TodaysSafetyReadiness(
          gatingSource: ReadinessGatingSource.meeting,
          beforeMeeting: [item('meeting-only', canStart: false)],
        ),
      );
      expect(ids, {'meeting-only'});
    });

    test('completed records are history and are never relabelled', () {
      final ids = noLongerRequiredLearningIds(
        [record('done', WorkerLearningStatus.completed)],
        const TodaysSafetyReadiness(
          gatingSource: ReadinessGatingSource.assignments,
        ),
      );
      expect(ids, isEmpty);
    });
  });

  group('LessonQuiz.fromMap', () {
    test('reads the server\'s required flags', () {
      final quiz = LessonQuiz.fromMap({
        'required': false,
        'quizRequired': false,
        'questions': [
          {
            'id': 'q1',
            'prompt': 'P',
            'options': [
              {'id': 'a', 'text': 'A'},
              {'id': 'b', 'text': 'B'},
            ],
            'order': 0,
          },
        ],
      });
      expect(quiz.required, isFalse);
      expect(quiz.serverReportsRequirement, isTrue);
      expect(quiz.hasQuiz, isTrue);
    });

    test('an older server\'s answer (no flags) reads as required with a '
        'mandatory quiz — never as general learning', () {
      final quiz = LessonQuiz.fromMap({
        'questions': [
          {
            'id': 'q1',
            'prompt': 'P',
            'options': [
              {'id': 'a', 'text': 'A'},
              {'id': 'b', 'text': 'B'},
            ],
            'order': 0,
          },
        ],
      });
      expect(quiz.serverReportsRequirement, isFalse);
      expect(quiz.required, isTrue);
      expect(quiz.quizRequired, isTrue);
    });
  });
}
