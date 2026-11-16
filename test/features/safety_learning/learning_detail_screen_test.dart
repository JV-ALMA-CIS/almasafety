import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/features/organizations/domain/organization_record_status.dart';
import 'package:jva_safety/features/safety_learning/data/worker_learning_service.dart';
import 'package:jva_safety/features/safety_learning/domain/complete_learning_result.dart';
import 'package:jva_safety/features/safety_learning/domain/knowledge_check_question.dart';
import 'package:jva_safety/features/safety_learning/domain/knowledge_check_result.dart';
import 'package:jva_safety/features/safety_learning/domain/lesson_quiz.dart';
import 'package:jva_safety/features/safety_learning/domain/safety_learning.dart';
import 'package:jva_safety/features/safety_learning/domain/safety_learning_type.dart';
import 'package:jva_safety/features/safety_learning/domain/submitted_answer.dart';
import 'package:jva_safety/features/safety_learning/domain/worker_learning_record.dart';
import 'package:jva_safety/features/safety_learning/domain/worker_learning_status.dart';
import 'package:jva_safety/features/safety_learning/presentation/learning_detail_screen.dart';

const _question = KnowledgeCheckQuestion(
  id: 'q1',
  prompt: 'What must you always wear at height?',
  options: [
    KnowledgeCheckOption(id: 'a', text: 'A harness'),
    KnowledgeCheckOption(id: 'b', text: 'Sunglasses'),
  ],
  order: 0,
);

const _passed = KnowledgeCheckResult(passed: true, score: 1, totalQuestions: 1);
const _failed = KnowledgeCheckResult(
  passed: false,
  score: 0,
  totalQuestions: 1,
);

/// Behaves like the server's `completeLearning`: without answers, a
/// mandatory quiz leaves the lesson open with the video recorded; with
/// answers, [quizResult] decides. Every call is recorded.
class _FakeService extends WorkerLearningService {
  _FakeService({
    this.questions = const [],
    this.quizRequired = true,
    this.quizResult = _passed,
    this.lessonRequired = true,
    this.reportsRequirement = true,
  });

  final List<KnowledgeCheckQuestion> questions;
  final bool quizRequired;
  KnowledgeCheckResult quizResult;

  /// Whether the server says the lesson is still required of the learner.
  final bool lessonRequired;

  /// False for an older server, which never says (see [LessonQuiz]).
  final bool reportsRequirement;

  /// When set, `getLessonQuiz` waits for it.
  Completer<void>? quizPending;

  final List<String> startCalls = [];

  /// The answers sent with each `completeLearning` call (null = none).
  final List<List<SubmittedAnswer>?> completeCalls = [];
  final List<List<SubmittedAnswer>> practiceCalls = [];
  int quizLoads = 0;

  AppException? completeError;
  AppException? quizError;

  /// When set, `completeLearning` waits for it.
  Completer<void>? pending;

  @override
  Future<void> startLearning({
    required String organizationId,
    required String learningId,
  }) async {
    startCalls.add(learningId);
  }

  @override
  Future<LessonQuiz> getLessonQuiz({
    required String organizationId,
    required String learningId,
  }) async {
    quizLoads++;
    final wait = quizPending;
    if (wait != null) await wait.future;
    final error = quizError;
    if (error != null) throw error;
    if (!reportsRequirement) {
      return LessonQuiz(
        questions: questions,
        required: true,
        quizRequired: questions.isNotEmpty,
        serverReportsRequirement: false,
      );
    }
    return LessonQuiz(
      questions: questions,
      required: lessonRequired,
      quizRequired: lessonRequired && quizRequired && questions.isNotEmpty,
    );
  }

  @override
  Future<CompleteLearningResult> completeLearning({
    required String organizationId,
    required String learningId,
    List<SubmittedAnswer>? selectedAnswers,
  }) async {
    completeCalls.add(selectedAnswers);
    final wait = pending;
    if (wait != null) await wait.future;
    final error = completeError;
    if (error != null) throw error;
    final mandatory = quizRequired && questions.isNotEmpty;
    final result = selectedAnswers == null ? null : quizResult;
    if (mandatory && (result == null || !result.passed)) {
      return CompleteLearningResult(
        status: WorkerLearningStatus.inProgress,
        contentCompleted: true,
        quizOutstanding: true,
        knowledgeCheckResult: result,
      );
    }
    return CompleteLearningResult(
      status: WorkerLearningStatus.completed,
      contentCompleted: true,
      knowledgeCheckResult: result,
    );
  }

  @override
  Future<KnowledgeCheckResult> practiceKnowledgeCheck({
    required String organizationId,
    required String learningId,
    required List<SubmittedAnswer> selectedAnswers,
  }) async {
    practiceCalls.add(selectedAnswers);
    return quizResult;
  }
}

SafetyLearning video({
  int? minimumWatchSeconds,
  String contentReference = 'https://example.com/video.mp4',
}) => SafetyLearning(
  id: 'l1',
  organizationId: 'org-alpha',
  title: 'Working at Height',
  type: SafetyLearningType.video,
  contentReference: contentReference,
  status: OrganizationRecordStatus.active,
  minimumWatchSeconds: minimumWatchSeconds,
);

SafetyLearning document({int? minimumWatchSeconds}) => SafetyLearning(
  id: 'l1',
  organizationId: 'org-alpha',
  title: 'PPE Handbook',
  type: SafetyLearningType.document,
  contentReference: 'https://example.com/handbook.pdf',
  status: OrganizationRecordStatus.active,
  minimumWatchSeconds: minimumWatchSeconds,
);

WorkerLearningRecord record({
  required WorkerLearningStatus status,
  DateTime? startedAt,
  DateTime? contentCompletedAt,
  DateTime? completedAt,
}) => WorkerLearningRecord(
  id: 'worker-1_l1',
  workerUid: 'worker-1',
  organizationId: 'org-alpha',
  learningId: 'l1',
  status: status,
  startedAt: startedAt,
  contentCompletedAt: contentCompletedAt,
  completedAt: completedAt,
);

void main() {
  Future<void> pumpLesson(
    WidgetTester tester, {
    required SafetyLearning learning,
    WorkerLearningRecord? lessonRecord,
    required _FakeService service,
    bool watchOnly = false,
    bool allowPracticeQuiz = false,
    bool generalLearning = false,
    bool settle = true,
    String watchOnlyNote = LearningDetailScreen.optionalWatchNote,
    ExternalLinkLauncher? launcher,
    String? storageBucket,
  }) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: LearningDetailScreen(
          organizationId: 'org-alpha',
          learning: learning,
          record: lessonRecord,
          watchOnly: watchOnly,
          watchOnlyNote: watchOnlyNote,
          allowPracticeQuiz: allowPracticeQuiz,
          generalLearning: generalLearning,
          workerLearningService: service,
          storageBucket: storageBucket,
          externalLinkLauncher: launcher ?? (_) async => true,
        ),
      ),
    );
    if (settle) await tester.pumpAndSettle();
  }

  ButtonStyleButton button(WidgetTester tester, String label) =>
      tester.widget<ButtonStyleButton>(
        find.ancestor(
          of: find.text(label),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
        ),
      );

  group('the video step (no quiz)', () {
    testWidgets(
      'not started: Watch Video is the action and starts the lesson',
      (tester) async {
        final service = _FakeService();
        await pumpLesson(
          tester,
          learning: video(),
          lessonRecord: record(status: WorkerLearningStatus.assigned),
          service: service,
        );
        expect(find.text('Not started'), findsOneWidget);
        await tester.tap(find.text('Watch Video'));
        await tester.pumpAndSettle();
        expect(service.startCalls, ['l1']);
        expect(find.text("I've Watched the Video"), findsOneWidget);
      },
    );

    testWidgets('an external (YouTube) video opens when started, and again '
        'with Continue Video', (tester) async {
      final launched = <Uri>[];
      final service = _FakeService();
      await pumpLesson(
        tester,
        learning: video(
          contentReference: 'https://www.youtube.com/watch?v=jfKfPfyJRdk',
        ),
        lessonRecord: record(status: WorkerLearningStatus.assigned),
        service: service,
        launcher: (uri) async {
          launched.add(uri);
          return true;
        },
      );
      await tester.tap(find.text('Watch Video'));
      await tester.pumpAndSettle();
      expect(launched, hasLength(1));
      expect(find.text('Continue Video'), findsOneWidget);
      await tester.tap(find.text('Continue Video'));
      await tester.pumpAndSettle();
      expect(launched, hasLength(2));
    });

    testWidgets('with no minimum watch time, the video can be marked watched '
        'at once, completing the lesson after a confirmation', (tester) async {
      final service = _FakeService();
      await pumpLesson(
        tester,
        learning: video(),
        lessonRecord: record(
          status: WorkerLearningStatus.inProgress,
          startedAt: DateTime.now(),
        ),
        service: service,
      );
      expect(find.textContaining('Keep this open'), findsNothing);
      await tester.tap(find.text("I've Watched the Video"));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Submit'));
      await tester.pumpAndSettle();
      expect(service.completeCalls, [null]);
      expect(find.textContaining('Completed on'), findsOneWidget);
    });

    testWidgets('an unmet minimum watch time disables it and explains why', (
      tester,
    ) async {
      await pumpLesson(
        tester,
        learning: video(minimumWatchSeconds: 120),
        lessonRecord: record(
          status: WorkerLearningStatus.inProgress,
          startedAt: DateTime.now(),
        ),
        service: _FakeService(),
      );
      expect(find.textContaining('Keep this open'), findsOneWidget);
      expect(button(tester, "I've Watched the Video").onPressed, isNull);
    });

    testWidgets('once the minimum watch time has elapsed it is enabled', (
      tester,
    ) async {
      await pumpLesson(
        tester,
        learning: video(minimumWatchSeconds: 30),
        lessonRecord: record(
          status: WorkerLearningStatus.inProgress,
          startedAt: DateTime.now().subtract(const Duration(seconds: 60)),
        ),
        service: _FakeService(),
      );
      expect(find.textContaining('Keep this open'), findsNothing);
      expect(button(tester, "I've Watched the Video").onPressed, isNotNull);
    });

    testWidgets(
      'a server refusal is shown verbatim and the lesson stays open',
      (tester) async {
        final service = _FakeService()
          ..completeError = const DataException(
            'You must start this learning item before completing it.',
          );
        await pumpLesson(
          tester,
          learning: video(),
          lessonRecord: record(status: WorkerLearningStatus.inProgress),
          service: service,
        );
        await tester.tap(find.text("I've Watched the Video"));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Submit'));
        await tester.pumpAndSettle();
        expect(
          find.text('You must start this learning item before completing it.'),
          findsOneWidget,
        );
        expect(find.textContaining('Completed on'), findsNothing);
      },
    );

    testWidgets('a document keeps Start Learning / Complete Learning, with '
        'the same watch-time gate when configured', (tester) async {
      await pumpLesson(
        tester,
        learning: document(minimumWatchSeconds: 120),
        lessonRecord: record(
          status: WorkerLearningStatus.inProgress,
          startedAt: DateTime.now(),
        ),
        service: _FakeService(),
      );
      expect(find.textContaining('Keep this open'), findsOneWidget);
      expect(button(tester, 'Complete Learning').onPressed, isNull);
    });

    testWidgets('a completed record shows its date and no actions', (
      tester,
    ) async {
      await pumpLesson(
        tester,
        learning: video(minimumWatchSeconds: 120),
        lessonRecord: record(
          status: WorkerLearningStatus.completed,
          completedAt: DateTime(2026, 1, 1, 9, 30),
        ),
        service: _FakeService(),
      );
      expect(find.textContaining('Completed on'), findsOneWidget);
      expect(find.text("I've Watched the Video"), findsNothing);
      expect(find.text('Take Quiz'), findsNothing);
    });

    testWidgets('a double tap submits once', (tester) async {
      final service = _FakeService(questions: const [_question])
        ..pending = Completer<void>();
      await pumpLesson(
        tester,
        learning: video(),
        lessonRecord: record(status: WorkerLearningStatus.inProgress),
        service: service,
      );
      await tester.tap(find.text("I've Watched the Video"));
      await tester.pump();
      await tester.tap(
        find.text("I've Watched the Video"),
        warnIfMissed: false,
      );
      await tester.pump();
      service.pending!.complete();
      service.pending = null;
      await tester.pumpAndSettle();
      expect(service.completeCalls, hasLength(1));
    });
  });

  group('a required quiz (video, then quiz)', () {
    testWidgets('watching the video alone does not complete the lesson; the '
        'quiz then becomes the action and completes it', (tester) async {
      final service = _FakeService(questions: const [_question]);
      await pumpLesson(
        tester,
        learning: video(),
        lessonRecord: record(status: WorkerLearningStatus.inProgress),
        service: service,
      );
      expect(find.text('Step 1 · Watch the video'), findsOneWidget);
      expect(find.text('Step 2 · Quiz'), findsOneWidget);
      expect(find.text('Required'), findsOneWidget);
      expect(
        find.textContaining('Unlocks once you have watched the video'),
        findsOneWidget,
      );
      // The video is the action — not the quiz.
      expect(find.text('Take Quiz'), findsNothing);

      // No "mark as completed?" dialog: this only records the video.
      await tester.tap(find.text("I've Watched the Video"));
      await tester.pumpAndSettle();
      expect(service.completeCalls, [null]);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.textContaining('Completed on'), findsNothing);
      expect(find.text('Video watched · quiz outstanding'), findsOneWidget);
      expect(find.text("I've Watched the Video"), findsNothing);

      await tester.tap(find.text('Take Quiz'));
      await tester.pumpAndSettle();
      expect(find.text('What must you always wear at height?'), findsOneWidget);
      // No answer key on the learner's screen; Submit waits for an answer.
      expect(button(tester, 'Submit').onPressed, isNull);
      await tester.tap(find.text('A harness'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Submit'));
      await tester.pumpAndSettle();

      expect(service.completeCalls, hasLength(2));
      expect(service.completeCalls.last, isNotNull);
      expect(find.textContaining('Knowledge check passed'), findsOneWidget);
      expect(find.textContaining('Completed on'), findsOneWidget);
    });

    testWidgets('a recorded video step opens straight on Take Quiz', (
      tester,
    ) async {
      await pumpLesson(
        tester,
        learning: video(),
        lessonRecord: record(
          status: WorkerLearningStatus.inProgress,
          contentCompletedAt: DateTime.now(),
        ),
        service: _FakeService(questions: const [_question]),
      );
      expect(find.text('Take Quiz'), findsOneWidget);
      expect(find.text("I've Watched the Video"), findsNothing);
      expect(find.text('Video watched · quiz outstanding'), findsOneWidget);
    });

    testWidgets('a failed attempt keeps the lesson open for a retry', (
      tester,
    ) async {
      final service = _FakeService(
        questions: const [_question],
        quizResult: _failed,
      );
      await pumpLesson(
        tester,
        learning: video(),
        lessonRecord: record(
          status: WorkerLearningStatus.inProgress,
          contentCompletedAt: DateTime.now(),
        ),
        service: service,
      );
      await tester.tap(find.text('Take Quiz'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sunglasses'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Submit'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Knowledge check not yet passed'),
        findsOneWidget,
      );
      expect(find.textContaining('0/1 correct'), findsOneWidget);
      expect(find.textContaining('Completed on'), findsNothing);
      expect(find.text('Take Quiz'), findsOneWidget);
    });

    testWidgets('the video watch time applies before the quiz is reachable', (
      tester,
    ) async {
      await pumpLesson(
        tester,
        learning: video(minimumWatchSeconds: 120),
        lessonRecord: record(
          status: WorkerLearningStatus.inProgress,
          startedAt: DateTime.now(),
        ),
        service: _FakeService(questions: const [_question]),
      );
      expect(find.textContaining('Keep this open'), findsOneWidget);
      expect(button(tester, "I've Watched the Video").onPressed, isNull);
      expect(find.text('Take Quiz'), findsNothing);
    });

    testWidgets('if the quiz details fail to load, nothing can be completed '
        'until a retry succeeds', (tester) async {
      final service = _FakeService(questions: const [_question])
        ..quizError = const NetworkException('No connection.');
      await pumpLesson(
        tester,
        learning: video(),
        lessonRecord: record(status: WorkerLearningStatus.inProgress),
        service: service,
      );
      expect(find.text('No connection.'), findsOneWidget);
      expect(button(tester, "I've Watched the Video").onPressed, isNull);

      service.quizError = null;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(service.quizLoads, 2);
      expect(button(tester, "I've Watched the Video").onPressed, isNotNull);
    });
  });

  group('an optional quiz', () {
    testWidgets('the video completes the lesson on its own; the quiz stays '
        'available afterwards', (tester) async {
      final service = _FakeService(
        questions: const [_question],
        quizRequired: false,
        quizResult: _failed,
      );
      await pumpLesson(
        tester,
        learning: video(),
        lessonRecord: record(status: WorkerLearningStatus.inProgress),
        service: service,
      );
      expect(find.text('Optional'), findsOneWidget);
      await tester.tap(find.text("I've Watched the Video"));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Submit'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Completed on'), findsOneWidget);

      await tester.tap(find.text('Take Optional Quiz'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sunglasses'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Submit'));
      await tester.pumpAndSettle();
      // A failed optional quiz never undoes the completed lesson.
      expect(
        find.textContaining('Knowledge check not yet passed'),
        findsOneWidget,
      );
      expect(find.textContaining('Completed on'), findsOneWidget);
      expect(service.completeCalls, hasLength(2));
    });
  });

  group('watch-only', () {
    for (final (name, hasRecord) in [
      ('with watchOnly set', true),
      ('without a record', false),
    ]) {
      testWidgets('$name: no actions, the optional note, and no learning '
          'call', (tester) async {
        final service = _FakeService(questions: const [_question]);
        await pumpLesson(
          tester,
          learning: video(minimumWatchSeconds: 60),
          lessonRecord: hasRecord
              ? record(status: WorkerLearningStatus.assigned)
              : null,
          watchOnly: hasRecord,
          service: service,
        );
        expect(
          find.text(LearningDetailScreen.optionalWatchNote),
          findsOneWidget,
        );
        expect(find.text('Watch Video'), findsNothing);
        expect(find.text("I've Watched the Video"), findsNothing);
        expect(find.text('Practice Quiz'), findsNothing);
        expect(find.textContaining('Keep this open'), findsNothing);
        expect(service.startCalls, isEmpty);
        expect(service.completeCalls, isEmpty);
        expect(service.quizLoads, 0);
      });
    }

    testWidgets('shows a custom note', (tester) async {
      await pumpLesson(
        tester,
        learning: video(),
        watchOnlyNote: 'Ask your Foreman.',
        service: _FakeService(),
      );
      expect(find.text('Ask your Foreman.'), findsOneWidget);
    });

    testWidgets('a learner can practise an optional video\'s quiz; nothing '
        'is recorded', (tester) async {
      final service = _FakeService(questions: const [_question]);
      await pumpLesson(
        tester,
        learning: video(),
        allowPracticeQuiz: true,
        service: service,
      );
      expect(find.text('Practice'), findsOneWidget);
      await tester.tap(find.text('Practice Quiz'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('A harness'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Submit'));
      await tester.pumpAndSettle();
      expect(service.practiceCalls, hasLength(1));
      expect(service.completeCalls, isEmpty);
      expect(service.startCalls, isEmpty);
      expect(
        find.textContaining('Practice: Knowledge check passed'),
        findsOneWidget,
      );
      expect(find.textContaining('Not recorded'), findsOneWidget);
    });
  });

  group('general learning (no longer required)', () {
    Future<void> practise(WidgetTester tester) async {
      await tester.tap(find.text('Practice Quiz'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('A harness'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Submit'));
      await tester.pumpAndSettle();
    }

    for (final role in ['Worker', 'Foreman']) {
      testWidgets('$role: an unfinished record the server no longer requires '
          'opens as general learning; the practice quiz records nothing', (
        tester,
      ) async {
        final service = _FakeService(
          questions: const [_question],
          lessonRequired: false,
        );
        await pumpLesson(
          tester,
          learning: video(),
          lessonRecord: record(status: WorkerLearningStatus.inProgress),
          service: service,
        );
        expect(
          find.text(LearningDetailScreen.generalLearningNote),
          findsOneWidget,
        );
        expect(find.text('Watch Video'), findsNothing);
        expect(find.text('I\'ve Watched the Video'), findsNothing);
        expect(find.text('Take Quiz'), findsNothing);

        await practise(tester);
        expect(service.practiceCalls, hasLength(1));
        // Nothing that writes a record, readiness or compliance is called.
        expect(service.startCalls, isEmpty);
        expect(service.completeCalls, isEmpty);
        expect(find.textContaining('Not recorded'), findsOneWidget);
      });
    }

    testWidgets('the list can say so up front, before the server answers', (
      tester,
    ) async {
      final service = _FakeService(questions: const [_question]);
      await pumpLesson(
        tester,
        learning: video(),
        lessonRecord: record(status: WorkerLearningStatus.assigned),
        generalLearning: true,
        service: service,
      );
      expect(
        find.text(LearningDetailScreen.generalLearningNote),
        findsOneWidget,
      );
      expect(find.text('Watch Video'), findsNothing);
      expect(find.text('Practice Quiz'), findsOneWidget);
    });

    testWidgets('a completed record keeps its completion; its quiz can only '
        'be practised', (tester) async {
      final completedAt = DateTime(2026, 9, 1, 8);
      final service = _FakeService(
        questions: const [_question],
        lessonRequired: false,
      );
      await pumpLesson(
        tester,
        learning: video(),
        lessonRecord: record(
          status: WorkerLearningStatus.completed,
          completedAt: completedAt,
        ),
        service: service,
      );
      expect(find.textContaining('Completed on'), findsOneWidget);
      expect(
        find.text(LearningDetailScreen.generalLearningNote),
        findsOneWidget,
      );
      expect(find.text('Take Optional Quiz'), findsNothing);

      await practise(tester);
      expect(service.practiceCalls, hasLength(1));
      expect(service.completeCalls, isEmpty);
      expect(find.textContaining('Completed on'), findsOneWidget);
    });

    testWidgets('a lesson still required is unchanged', (tester) async {
      final service = _FakeService(questions: const [_question]);
      await pumpLesson(
        tester,
        learning: video(),
        lessonRecord: record(status: WorkerLearningStatus.assigned),
        service: service,
      );
      expect(find.text(LearningDetailScreen.generalLearningNote), findsNothing);
      expect(find.text('Watch Video'), findsOneWidget);
      expect(find.text('Practice Quiz'), findsNothing);
    });

    testWidgets('an older server (which never says) keeps the required flow', (
      tester,
    ) async {
      final service = _FakeService(
        questions: const [_question],
        reportsRequirement: false,
      );
      await pumpLesson(
        tester,
        learning: video(),
        lessonRecord: record(status: WorkerLearningStatus.assigned),
        service: service,
      );
      expect(find.text(LearningDetailScreen.generalLearningNote), findsNothing);
      expect(find.text('Watch Video'), findsOneWidget);
    });

    testWidgets('Watch Video waits for the quiz details, so a no-longer-'
        'required lesson is never started', (tester) async {
      final service = _FakeService(lessonRequired: false)
        ..quizPending = Completer<void>();
      await pumpLesson(
        tester,
        learning: video(),
        lessonRecord: record(status: WorkerLearningStatus.assigned),
        service: service,
        settle: false,
      );
      await tester.pump();
      expect(button(tester, 'Watch Video').onPressed, isNull);
      await tester.tap(find.text('Watch Video'), warnIfMissed: false);
      await tester.pump();
      expect(service.startCalls, isEmpty);

      service.quizPending!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Watch Video'), findsNothing);
      expect(
        find.text(LearningDetailScreen.generalLearningNote),
        findsOneWidget,
      );
      expect(service.startCalls, isEmpty);
    });

    testWidgets('an outdated server refusing the quiz shows the update '
        'message, not a permission problem, and starts nothing', (
      tester,
    ) async {
      const message =
          "This quiz can't open yet because the server needs the latest "
          "update. This isn't a problem with your account — ask your "
          'administrator to deploy the update.';
      final service = _FakeService(questions: const [_question])
        ..quizError = const ServerUpdateRequiredException(message);
      await pumpLesson(
        tester,
        learning: video(),
        lessonRecord: record(status: WorkerLearningStatus.assigned),
        service: service,
      );
      expect(find.text(message), findsOneWidget);
      expect(find.textContaining('permission'), findsNothing);
      expect(find.text('Try again'), findsOneWidget);
      expect(button(tester, 'Watch Video').onPressed, isNull);
      expect(service.startCalls, isEmpty);
    });
  });

  group('an inactive lesson (reached through an old record or link)', () {
    SafetyLearning inactive({
      String contentReference = 'https://example.com/video.mp4',
    }) => SafetyLearning(
      id: 'l1',
      organizationId: 'org-alpha',
      title: 'Working at Height',
      type: SafetyLearningType.video,
      contentReference: contentReference,
      status: OrganizationRecordStatus.inactive,
    );

    for (final status in WorkerLearningStatus.values) {
      for (final link in [
        'https://example.com/video.mp4',
        'https://www.youtube.com/watch?v=jfKfPfyJRdk',
      ]) {
        testWidgets('${status.name} record, $link: no player, link, quiz or '
            'action, and the server is never asked', (tester) async {
          final service = _FakeService(questions: const [_question]);
          final opened = <Uri>[];
          await pumpLesson(
            tester,
            learning: inactive(contentReference: link),
            lessonRecord: record(status: status),
            allowPracticeQuiz: true,
            service: service,
            launcher: (uri) async {
              opened.add(uri);
              return true;
            },
          );
          expect(find.text(LearningDetailScreen.inactiveNote), findsOneWidget);
          expect(find.text('Your record'), findsOneWidget);
          for (final label in [
            'Watch Video',
            'Watch on YouTube',
            'Play video',
            'Open lesson',
            "I've Watched the Video",
            'Take Quiz',
            'Practice Quiz',
            'Take Optional Quiz',
            'Step 2 · Quiz',
          ]) {
            expect(find.text(label), findsNothing, reason: label);
          }
          // No content is built at all: no player, no video or lesson link.
          expect(
            find.byWidgetPredicate(
              (w) => const {
                '_VideoContent',
                '_VideoPlayerContent',
                '_ContentLink',
                'VideoPlayer',
              }.contains(w.runtimeType.toString()),
            ),
            findsNothing,
          );
          expect(opened, isEmpty);
          expect(service.quizLoads, 0);
          expect(service.startCalls, isEmpty);
          expect(service.completeCalls, isEmpty);
          expect(service.practiceCalls, isEmpty);
        });
      }
    }

    testWidgets('a completed record keeps its history: dates and the '
        'recorded quiz result', (tester) async {
      final service = _FakeService(questions: const [_question]);
      await pumpLesson(
        tester,
        learning: inactive(),
        lessonRecord: WorkerLearningRecord(
          id: 'worker-1_l1',
          workerUid: 'worker-1',
          organizationId: 'org-alpha',
          learningId: 'l1',
          status: WorkerLearningStatus.completed,
          startedAt: DateTime(2026, 9, 1, 8),
          contentCompletedAt: DateTime(2026, 9, 1, 8, 10),
          completedAt: DateTime(2026, 9, 1, 8, 15),
          knowledgeCheckResult: const KnowledgeCheckResult(
            passed: true,
            score: 3,
            totalQuestions: 4,
          ),
        ),
        service: service,
      );
      expect(find.textContaining('Status: Completed'), findsOneWidget);
      expect(find.textContaining('Started 2026-09-01'), findsOneWidget);
      expect(find.textContaining('Watched 2026-09-01'), findsOneWidget);
      expect(find.textContaining('Completed 2026-09-01'), findsOneWidget);
      expect(find.text('Quiz passed · 3/4'), findsOneWidget);
      expect(service.quizLoads, 0);
    });

    testWidgets('no record at all (an old link): only the message', (
      tester,
    ) async {
      final service = _FakeService(questions: const [_question]);
      await pumpLesson(
        tester,
        learning: inactive(),
        allowPracticeQuiz: true,
        service: service,
      );
      expect(find.text(LearningDetailScreen.inactiveNote), findsOneWidget);
      expect(find.text('You have no record for this lesson.'), findsOneWidget);
      expect(find.text('Practice Quiz'), findsNothing);
      expect(service.quizLoads, 0);
    });
  });

  group('video sources', () {
    const bucket = 'jva-test.firebasestorage.app';

    Future<void> pumpVideo(
      WidgetTester tester,
      String contentReference, {
      WorkerLearningStatus? status = WorkerLearningStatus.assigned,
    }) => pumpLesson(
      tester,
      learning: video(contentReference: contentReference),
      lessonRecord: status == null ? null : record(status: status),
      service: _FakeService(),
      storageBucket: bucket,
    );

    testWidgets('YouTube opens outside the app with a start-first hint', (
      tester,
    ) async {
      await pumpVideo(tester, 'https://www.youtube.com/watch?v=dQw4w9WgXcQ');
      expect(find.text('Watch on YouTube'), findsOneWidget);
      expect(find.textContaining('Tap Watch Video to start'), findsOneWidget);
      // Never handed to the video-file player.
      expect(find.textContaining('could not be played'), findsNothing);
      expect(find.textContaining('unavailable'), findsNothing);
    });

    testWidgets('an in-progress YouTube lesson says to come back', (
      tester,
    ) async {
      await pumpVideo(
        tester,
        'https://youtu.be/dQw4w9WgXcQ',
        status: WorkerLearningStatus.inProgress,
      );
      expect(find.textContaining('come back here and tap'), findsOneWidget);
    });

    testWidgets('watch-only YouTube shows no learning hint', (tester) async {
      await pumpVideo(tester, 'https://youtu.be/dQw4w9WgXcQ', status: null);
      expect(find.text('Watch on YouTube'), findsOneWidget);
      expect(find.textContaining('Tap Watch Video'), findsNothing);
    });

    testWidgets('Vimeo opens outside the app', (tester) async {
      await pumpVideo(tester, 'https://player.vimeo.com/video/76979871');
      expect(find.text('Open video on Vimeo'), findsOneWidget);
    });

    testWidgets('a JVA video without a file extension still tries the '
        'in-app player, then falls back with a clear message', (tester) async {
      await pumpVideo(
        tester,
        'https://firebasestorage.googleapis.com/v0/b/$bucket/o/'
        'organizations%2Forg-alpha%2Fsafety_learning%2F1%2FIMG_0042'
        '?alt=media&token=t',
      );
      // No video plugin in tests, so playback fails — the fallback, not a
      // blank player or a plain link, is what shows.
      expect(
        find.text('This video is unavailable right now. Tell your supervisor.'),
        findsOneWidget,
      );
      expect(find.text('Open video'), findsOneWidget);
    });

    testWidgets('an unusable link shows unavailable and opens nothing', (
      tester,
    ) async {
      await pumpVideo(tester, 'https://example.org/not-a-video');
      expect(
        find.text('This video is unavailable. Tell your supervisor.'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.open_in_new), findsNothing);
    });

    testWidgets('another organization\'s JVA file is unavailable', (
      tester,
    ) async {
      await pumpVideo(
        tester,
        'https://firebasestorage.googleapis.com/v0/b/$bucket/o/'
        'organizations%2Forg-beta%2Fsafety_learning%2F1%2Fclip.mp4'
        '?alt=media&token=t',
      );
      expect(
        find.text('This video is unavailable. Tell your supervisor.'),
        findsOneWidget,
      );
    });

    testWidgets('a document is unchanged: Open lesson / Start Learning', (
      tester,
    ) async {
      await pumpLesson(
        tester,
        learning: document(),
        lessonRecord: record(status: WorkerLearningStatus.assigned),
        service: _FakeService(),
      );
      expect(find.text('Open lesson'), findsOneWidget);
      expect(find.text('Start Learning'), findsOneWidget);
    });
  });
}
