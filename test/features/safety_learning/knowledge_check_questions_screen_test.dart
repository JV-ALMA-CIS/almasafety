import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/features/organizations/domain/organization_record_status.dart';
import 'package:jva_safety/features/safety_learning/data/safety_learning_admin_service.dart';
import 'package:jva_safety/features/safety_learning/domain/knowledge_check_admin_question.dart';
import 'package:jva_safety/features/safety_learning/domain/knowledge_check_question.dart';
import 'package:jva_safety/features/safety_learning/domain/safety_learning.dart';
import 'package:jva_safety/features/safety_learning/domain/safety_learning_type.dart';
import 'package:jva_safety/features/safety_learning/presentation/knowledge_check_questions_screen.dart';

/// Answers `listKnowledgeCheckQuestions` from [results] in order (the last
/// repeats); an [AppException] or other error entry is thrown.
class _FakeAdminService extends SafetyLearningAdminService {
  _FakeAdminService(this.results);

  final List<Object> results;
  int listCalls = 0;

  @override
  Future<List<KnowledgeCheckAdminQuestion>> listKnowledgeCheckQuestions({
    required String organizationId,
    required String learningId,
  }) async {
    final result =
        results[listCalls < results.length ? listCalls : results.length - 1];
    listCalls++;
    if (result is List<KnowledgeCheckAdminQuestion>) return result;
    throw result;
  }
}

const _video = SafetyLearning(
  id: 'v1',
  organizationId: 'org-alpha',
  title: 'Ladder Safety',
  type: SafetyLearningType.video,
  contentReference: 'https://www.youtube.com/watch?v=jfKfPfyJRdk',
  status: OrganizationRecordStatus.active,
);

void main() {
  Future<void> pumpScreen(
    WidgetTester tester,
    _FakeAdminService service,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: KnowledgeCheckQuestionsScreen(
          organizationId: 'org-alpha',
          learning: _video,
          adminService: service,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  ElevatedButton addButton(WidgetTester tester) =>
      tester.widget(find.widgetWithText(ElevatedButton, 'Add Question'));

  testWidgets('loading -> empty: says there are no questions yet', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      _FakeAdminService([<KnowledgeCheckAdminQuestion>[]]),
    );
    expect(find.text('No questions yet.'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
    expect(addButton(tester).onPressed, isNotNull);
  });

  testWidgets('a failed load is not shown as "no questions", Add is '
      'disabled, and Try again reloads', (tester) async {
    final service = _FakeAdminService([
      const NetworkException('No connection.'),
      <KnowledgeCheckAdminQuestion>[],
    ]);
    await pumpScreen(tester, service);
    expect(find.text('No connection.'), findsOneWidget);
    expect(find.text('No questions yet.'), findsNothing);
    expect(addButton(tester).onPressed, isNull);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(service.listCalls, 2);
    expect(find.text('No connection.'), findsNothing);
    expect(find.text('No questions yet.'), findsOneWidget);
    expect(addButton(tester).onPressed, isNotNull);
  });

  testWidgets('repeated failure keeps the retry and never pretends success', (
    tester,
  ) async {
    final service = _FakeAdminService([Exception('offline')]);
    await pumpScreen(tester, service);
    for (var i = 0; i < 2; i++) {
      expect(
        find.textContaining('Could not load the questions'),
        findsOneWidget,
      );
      expect(find.text('No questions yet.'), findsNothing);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
    }
    expect(service.listCalls, 3);
    expect(addButton(tester).onPressed, isNull);
  });

  testWidgets('back stays available while the load has failed', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => KnowledgeCheckQuestionsScreen(
                    organizationId: 'org-alpha',
                    learning: _video,
                    adminService: _FakeAdminService([Exception('offline')]),
                  ),
                ),
              ),
              child: const Text('Open quiz'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open quiz'));
    await tester.pumpAndSettle();
    expect(find.text('Try again'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Open quiz'), findsOneWidget);
  });

  quizEditorTests();
}

/// Keeps questions in memory like the server does; [nextError] fails the
/// next save and [pending] holds saves open.
class _QuizStore extends SafetyLearningAdminService {
  _QuizStore([List<KnowledgeCheckAdminQuestion> initial = const []])
    : questions = [...initial];

  final List<KnowledgeCheckAdminQuestion> questions;
  int addCalls = 0;
  final List<(String, int)> updates = [];
  Object? nextError;
  Completer<void>? pending;

  Future<void> _gate() async {
    final wait = pending;
    if (wait != null) await wait.future;
    final error = nextError;
    nextError = null;
    if (error != null) throw error;
  }

  @override
  Future<List<KnowledgeCheckAdminQuestion>> listKnowledgeCheckQuestions({
    required String organizationId,
    required String learningId,
  }) async => [...questions]..sort((a, b) => a.order.compareTo(b.order));

  @override
  Future<String> addKnowledgeCheckQuestion({
    required String organizationId,
    required String learningId,
    required String prompt,
    required List<KnowledgeCheckOption> options,
    required String correctOptionId,
    required int order,
  }) async {
    addCalls++;
    await _gate();
    final id = 'q${questions.length + 1}';
    questions.add(
      KnowledgeCheckAdminQuestion(
        id: id,
        prompt: prompt,
        options: options,
        correctOptionId: correctOptionId,
        order: order,
      ),
    );
    return id;
  }

  @override
  Future<void> updateKnowledgeCheckQuestion({
    required String organizationId,
    required String learningId,
    required String questionId,
    required String prompt,
    required List<KnowledgeCheckOption> options,
    required String correctOptionId,
    required int order,
  }) async {
    await _gate();
    updates.add((questionId, order));
    final index = questions.indexWhere((q) => q.id == questionId);
    questions[index] = KnowledgeCheckAdminQuestion(
      id: questionId,
      prompt: prompt,
      options: options,
      correctOptionId: correctOptionId,
      order: order,
    );
  }
}

KnowledgeCheckAdminQuestion _q(String id, int order, {String? prompt}) =>
    KnowledgeCheckAdminQuestion(
      id: id,
      prompt: prompt ?? 'Question $id',
      options: const [
        KnowledgeCheckOption(id: 'a', text: 'Yes'),
        KnowledgeCheckOption(id: 'b', text: 'No'),
      ],
      correctOptionId: 'b',
      order: order,
    );

void quizEditorTests() {
  Future<void> pump(WidgetTester tester, _QuizStore store) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: KnowledgeCheckQuestionsScreen(
          organizationId: 'org-alpha',
          learning: _video,
          adminService: store,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> fillNewQuestion(WidgetTester tester) async {
    await tester.tap(find.text('Add Question'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Question'),
      'Where do you tie off?',
    );
    final options = find.widgetWithText(TextFormField, 'Option text');
    await tester.enterText(options.at(0), 'An anchor point');
    await tester.enterText(options.at(1), 'A handrail');
    await tester.tap(find.byTooltip('Mark as the correct answer').first);
    await tester.pumpAndSettle();
  }

  group('quiz editor', () {
    testWidgets('a failed save keeps the dialog and everything typed; a '
        'retry saves it once', (tester) async {
      final store = _QuizStore()
        ..nextError = const NetworkException('No connection.');
      await pump(tester, store);
      await fillNewQuestion(tester);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Add'));
      await tester.pumpAndSettle();
      expect(find.text('No connection.'), findsOneWidget);
      expect(find.text('Where do you tie off?'), findsOneWidget);
      expect(find.text('An anchor point'), findsOneWidget);
      expect(store.questions, isEmpty);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Add'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(store.questions, hasLength(1));
      expect(store.questions.single.correctOptionId, isNotEmpty);
      expect(find.text('1 saved question'), findsOneWidget);
    });

    testWidgets('a double tap on Add saves once', (tester) async {
      final store = _QuizStore()..pending = Completer<void>();
      await pump(tester, store);
      await fillNewQuestion(tester);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Add'));
      await tester.pump();
      await tester.tap(find.byType(ElevatedButton).last, warnIfMissed: false);
      await tester.pump();
      store.pending!.complete();
      store.pending = null;
      await tester.pumpAndSettle();
      expect(store.addCalls, 1);
      expect(store.questions, hasLength(1));
    });

    testWidgets('editing updates the same question rather than adding one', (
      tester,
    ) async {
      final store = _QuizStore([_q('q1', 0)]);
      await pump(tester, store);
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Question'),
        'Edited question',
      );
      await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
      await tester.pumpAndSettle();
      expect(store.addCalls, 0);
      expect(store.questions, hasLength(1));
      expect(store.questions.single.id, 'q1');
      expect(store.questions.single.prompt, 'Edited question');
      expect(find.text('Edited question'), findsOneWidget);
    });

    testWidgets('moving a question keeps its identity and correct answer', (
      tester,
    ) async {
      final store = _QuizStore([
        _q('q1', 0, prompt: 'First'),
        _q('q2', 1, prompt: 'Second'),
      ]);
      await pump(tester, store);
      await tester.tap(find.byTooltip('Move down').first);
      await tester.pumpAndSettle();

      expect(store.updates, containsAll([('q1', 1), ('q2', 0)]));
      expect(store.questions.map((q) => q.correctOptionId), ['b', 'b']);
      final first = tester.getTopLeft(find.text('Second')).dy;
      final second = tester.getTopLeft(find.text('First')).dy;
      expect(first, lessThan(second));
    });

    testWidgets('a new question goes after the highest existing order', (
      tester,
    ) async {
      final store = _QuizStore([_q('q1', 4)]);
      await pump(tester, store);
      await fillNewQuestion(tester);
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add'));
      await tester.pumpAndSettle();
      expect(store.questions.last.order, 5);
    });
  });
}
