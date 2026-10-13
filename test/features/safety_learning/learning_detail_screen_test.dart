import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/features/safety_learning/data/worker_learning_service.dart';
import 'package:jva_safety/features/safety_learning/domain/complete_learning_result.dart';
import 'package:jva_safety/features/safety_learning/domain/knowledge_check_question.dart';
import 'package:jva_safety/features/safety_learning/domain/knowledge_check_result.dart';
import 'package:jva_safety/features/safety_learning/domain/safety_learning.dart';
import 'package:jva_safety/features/safety_learning/domain/safety_learning_type.dart';
import 'package:jva_safety/features/safety_learning/domain/submitted_answer.dart';
import 'package:jva_safety/features/safety_learning/domain/worker_learning_record.dart';
import 'package:jva_safety/features/safety_learning/domain/worker_learning_status.dart';
import 'package:jva_safety/features/safety_learning/presentation/learning_detail_screen.dart';
import 'package:jva_safety/features/organizations/domain/organization_record_status.dart';

class _FakeWorkerLearningService extends WorkerLearningService {
  _FakeWorkerLearningService({this.questions = const []});

  final List<String> startCalls = [];
  final List<String> completeCalls = [];
  final List<KnowledgeCheckQuestion> questions;
  AppException? completeError;
  AppException? questionsError;
  CompleteLearningResult? completeResult;

  @override
  Future<void> startLearning({
    required String organizationId,
    required String learningId,
  }) async {
    startCalls.add(learningId);
  }

  @override
  Future<List<KnowledgeCheckQuestion>> getKnowledgeCheckQuestions({
    required String organizationId,
    required String learningId,
  }) async {
    final error = questionsError;
    if (error != null) throw error;
    return questions;
  }

  @override
  Future<CompleteLearningResult> completeLearning({
    required String organizationId,
    required String learningId,
    List<SubmittedAnswer>? selectedAnswers,
  }) async {
    final error = completeError;
    if (error != null) throw error;
    completeCalls.add(learningId);
    return completeResult ??
        const CompleteLearningResult(status: WorkerLearningStatus.completed);
  }
}

void main() {
  SafetyLearning video({
    String id = 'l1',
    int? minimumWatchSeconds,
    String contentReference = 'https://example.com/video.mp4',
  }) {
    return SafetyLearning(
      id: id,
      organizationId: 'org-alpha',
      title: 'Working at Height',
      type: SafetyLearningType.video,
      contentReference: contentReference,
      status: OrganizationRecordStatus.active,
      minimumWatchSeconds: minimumWatchSeconds,
    );
  }

  SafetyLearning document({String id = 'l1'}) {
    return SafetyLearning(
      id: id,
      organizationId: 'org-alpha',
      title: 'PPE Handbook',
      type: SafetyLearningType.document,
      contentReference: 'https://example.com/handbook.pdf',
      status: OrganizationRecordStatus.active,
    );
  }

  WorkerLearningRecord record({
    String learningId = 'l1',
    required WorkerLearningStatus status,
    DateTime? startedAt,
  }) {
    return WorkerLearningRecord(
      id: 'worker-1_$learningId',
      workerUid: 'worker-1',
      organizationId: 'org-alpha',
      learningId: learningId,
      status: status,
      startedAt: startedAt,
    );
  }

  Widget wrap(Widget child) => MaterialApp(home: child);

  testWidgets('a video with no minimumWatchSeconds behaves exactly as before — '
      'Complete is enabled immediately once inProgress', (tester) async {
    final service = _FakeWorkerLearningService();

    await tester.pumpWidget(
      wrap(
        LearningDetailScreen(
          organizationId: 'org-alpha',
          learning: video(),
          record: record(
            status: WorkerLearningStatus.inProgress,
            startedAt: DateTime.now(),
          ),
          workerLearningService: service,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Keep this open'), findsNothing);
    final button = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Complete Learning'),
    );
    expect(button.onPressed, isNotNull);
  });

  testWidgets('a video with an unmet minimumWatchSeconds disables Complete and '
      'explains why', (tester) async {
    final service = _FakeWorkerLearningService();

    await tester.pumpWidget(
      wrap(
        LearningDetailScreen(
          organizationId: 'org-alpha',
          learning: video(minimumWatchSeconds: 120),
          record: record(
            status: WorkerLearningStatus.inProgress,
            startedAt: DateTime.now(),
          ),
          workerLearningService: service,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Keep this open'), findsOneWidget);
    final button = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Complete Learning'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets(
    'once the minimum watch time has elapsed (per the real startedAt), '
    'Complete becomes enabled',
    (tester) async {
      final service = _FakeWorkerLearningService();

      await tester.pumpWidget(
        wrap(
          LearningDetailScreen(
            organizationId: 'org-alpha',
            learning: video(minimumWatchSeconds: 30),
            record: record(
              status: WorkerLearningStatus.inProgress,
              startedAt: DateTime.now().subtract(const Duration(seconds: 60)),
            ),
            workerLearningService: service,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Keep this open'), findsNothing);
      final button = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Complete Learning'),
      );
      expect(button.onPressed, isNotNull);

      await tester.tap(
        find.widgetWithText(ElevatedButton, 'Complete Learning'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Submit'));
      await tester.pumpAndSettle();

      expect(service.completeCalls, ['l1']);
    },
  );

  testWidgets('a server refusal (e.g. the worker never actually started the '
      'video) is shown verbatim via the error banner', (tester) async {
    final service = _FakeWorkerLearningService()
      ..completeError = const DataException(
        'You must start this learning item before completing it.',
      );

    await tester.pumpWidget(
      wrap(
        LearningDetailScreen(
          organizationId: 'org-alpha',
          learning: video(minimumWatchSeconds: 5),
          record: record(
            status: WorkerLearningStatus.inProgress,
            startedAt: DateTime.now().subtract(const Duration(seconds: 30)),
          ),
          workerLearningService: service,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ElevatedButton, 'Complete Learning'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Submit'));
    await tester.pumpAndSettle();

    expect(
      find.text('You must start this learning item before completing it.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'a document with no minimumWatchSeconds set is not subject to any '
    'engagement-time gate — Complete is enabled immediately',
    (tester) async {
      final service = _FakeWorkerLearningService();

      await tester.pumpWidget(
        wrap(
          LearningDetailScreen(
            organizationId: 'org-alpha',
            learning: document(),
            record: record(
              status: WorkerLearningStatus.inProgress,
              startedAt: DateTime.now(),
            ),
            workerLearningService: service,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Keep this open'), findsNothing);
      final button = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Complete Learning'),
      );
      expect(button.onPressed, isNotNull);

      await tester.tap(
        find.widgetWithText(ElevatedButton, 'Complete Learning'),
      );
      await tester.pumpAndSettle();
      // The dialog's "Mark this learning item as completed?" confirmation
      // (non-knowledge-check) needs one more tap on Submit.
      await tester.tap(find.text('Submit'));
      await tester.pumpAndSettle();

      expect(service.completeCalls, ['l1']);
    },
  );

  testWidgets(
    'a document WITH a configured minimumWatchSeconds IS subject to the '
    'same engagement-time gate as video',
    (tester) async {
      final service = _FakeWorkerLearningService();

      await tester.pumpWidget(
        wrap(
          LearningDetailScreen(
            organizationId: 'org-alpha',
            learning: SafetyLearning(
              id: 'l1',
              organizationId: 'org-alpha',
              title: 'PPE Handbook',
              type: SafetyLearningType.document,
              contentReference: 'https://example.com/handbook.pdf',
              status: OrganizationRecordStatus.active,
              minimumWatchSeconds: 120,
            ),
            record: record(
              status: WorkerLearningStatus.inProgress,
              startedAt: DateTime.now(),
            ),
            workerLearningService: service,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Keep this open'), findsOneWidget);
      final button = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Complete Learning'),
      );
      expect(button.onPressed, isNull);
    },
  );

  testWidgets(
    'an already-completed record (predating this feature) still renders '
    'its existing completion date — nothing about past completions '
    'breaks',
    (tester) async {
      final completedAt = DateTime(2026, 1, 1, 9, 30);

      await tester.pumpWidget(
        wrap(
          LearningDetailScreen(
            organizationId: 'org-alpha',
            learning: video(minimumWatchSeconds: 120),
            record: WorkerLearningRecord(
              id: 'worker-1_l1',
              workerUid: 'worker-1',
              organizationId: 'org-alpha',
              learningId: 'l1',
              status: WorkerLearningStatus.completed,
              completedAt: completedAt,
            ),
            workerLearningService: _FakeWorkerLearningService(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Completed on'), findsOneWidget);
      expect(find.text('Complete Learning'), findsNothing);
    },
  );

  group('knowledge check', () {
    const question = KnowledgeCheckQuestion(
      id: 'q1',
      prompt: 'What must you always wear at height?',
      options: [
        KnowledgeCheckOption(id: 'a', text: 'A harness'),
        KnowledgeCheckOption(id: 'b', text: 'Sunglasses'),
      ],
      order: 0,
    );

    testWidgets(
      'presents the questions and submits the selected answer, showing '
      'a passed result',
      (tester) async {
        final service = _FakeWorkerLearningService(questions: const [question])
          ..completeResult = const CompleteLearningResult(
            status: WorkerLearningStatus.completed,
            knowledgeCheckResult: KnowledgeCheckResult(
              passed: true,
              score: 1,
              totalQuestions: 1,
            ),
          );

        await tester.pumpWidget(
          wrap(
            LearningDetailScreen(
              organizationId: 'org-alpha',
              learning: document(),
              record: record(status: WorkerLearningStatus.inProgress),
              workerLearningService: service,
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(
          find.widgetWithText(ElevatedButton, 'Complete Learning'),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('What must you always wear at height?'),
          findsOneWidget,
        );
        expect(find.text('A harness'), findsOneWidget);
        expect(find.text('Sunglasses'), findsOneWidget);

        // Submit is disabled until every question has a selection.
        final submitButton = tester.widget<ElevatedButton>(
          find.widgetWithText(ElevatedButton, 'Submit'),
        );
        expect(submitButton.onPressed, isNull);

        await tester.tap(find.text('A harness'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Submit'));
        await tester.pumpAndSettle();

        expect(service.completeCalls, ['l1']);
        expect(find.textContaining('Knowledge check passed'), findsOneWidget);
        expect(find.textContaining('1/1 correct'), findsOneWidget);
      },
    );

    testWidgets(
      'a failure loading the questions (e.g. the server refusing because '
      'this item is no longer required) is shown via the error banner, '
      'not silently swallowed',
      (tester) async {
        final service = _FakeWorkerLearningService()
          ..questionsError = const PermissionDeniedException(
            'That learning item is not currently required of you.',
          );

        await tester.pumpWidget(
          wrap(
            LearningDetailScreen(
              organizationId: 'org-alpha',
              learning: document(),
              record: record(status: WorkerLearningStatus.inProgress),
              workerLearningService: service,
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(
          find.widgetWithText(ElevatedButton, 'Complete Learning'),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('That learning item is not currently required of you.'),
          findsOneWidget,
        );
        // No quiz dialog and no silent completion — Complete Learning is
        // still available for the worker to retry.
        expect(find.byType(AlertDialog), findsNothing);
        expect(
          find.widgetWithText(ElevatedButton, 'Complete Learning'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'a failed attempt is shown as an expected outcome, not an error, '
      'and the record stays inProgress so the worker can retry',
      (tester) async {
        final service = _FakeWorkerLearningService(questions: const [question])
          ..completeResult = const CompleteLearningResult(
            status: WorkerLearningStatus.inProgress,
            knowledgeCheckResult: KnowledgeCheckResult(
              passed: false,
              score: 0,
              totalQuestions: 1,
            ),
          );

        await tester.pumpWidget(
          wrap(
            LearningDetailScreen(
              organizationId: 'org-alpha',
              learning: document(),
              record: record(status: WorkerLearningStatus.inProgress),
              workerLearningService: service,
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(
          find.widgetWithText(ElevatedButton, 'Complete Learning'),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Sunglasses'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Submit'));
        await tester.pumpAndSettle();

        expect(find.text('Completed on'), findsNothing);
        expect(
          find.textContaining('Knowledge check not yet passed'),
          findsOneWidget,
        );
        expect(find.textContaining('0/1 correct'), findsOneWidget);
        // The Complete Learning button remains, ready for a retry.
        expect(find.text('Complete Learning'), findsOneWidget);
      },
    );

    testWidgets('a video with BOTH minimumWatchSeconds and a knowledge check '
        'blocks Complete until the watch time elapses, independent of the '
        'quiz', (tester) async {
      final service = _FakeWorkerLearningService(questions: const [question]);

      await tester.pumpWidget(
        wrap(
          LearningDetailScreen(
            organizationId: 'org-alpha',
            learning: video(minimumWatchSeconds: 120),
            record: record(
              status: WorkerLearningStatus.inProgress,
              startedAt: DateTime.now(),
            ),
            workerLearningService: service,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The watch-time gate alone already disables Complete — the worker
      // never even reaches the quiz until it elapses.
      expect(find.textContaining('Keep this open'), findsOneWidget);
      final button = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Complete Learning'),
      );
      expect(button.onPressed, isNull);
    });
  });
}
