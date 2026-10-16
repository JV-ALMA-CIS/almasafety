import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/core/offline/outbox.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:jva_safety/features/pre_start_checks/data/pre_start_check_service.dart';
import 'package:jva_safety/features/pre_start_checks/domain/pre_start_answer.dart';
import 'package:jva_safety/features/pre_start_checks/domain/pre_start_check.dart';
import 'package:jva_safety/features/pre_start_checks/domain/pre_start_outcome.dart';
import 'package:jva_safety/features/pre_start_checks/presentation/crew_pre_start_card.dart';
import 'package:jva_safety/features/pre_start_checks/presentation/pre_start_check_screen.dart';
import 'package:jva_safety/features/pre_start_checks/presentation/worker_pre_start_card.dart';

const _questions = [
  PreStartQuestion(id: 'std-ppe', prompt: 'I am wearing PPE.', kind: 'std'),
  PreStartQuestion(
    id: 'req-height',
    prompt: 'Height controls are in place.',
    kind: 'requirement',
    risk: 'high',
  ),
];

class _FakeService extends PreStartCheckService {
  _FakeService({
    this.check,
    this.crew = const [],
    this.outcome = PreStartOutcome.go,
    this.submitError,
  });

  MyPreStartCheck? check;
  final List<CrewPreStartRow> crew;
  final PreStartOutcome outcome;
  final AppException? submitError;
  Map<String, PreStartResponse>? submitted;
  String? submittedFor;

  @override
  Future<MyPreStartCheck> getMyPreStartCheck({
    required String organizationId,
  }) async => check!;

  @override
  Future<PreStartOutcome> submitPreStartCheck({
    required String organizationId,
    required Map<String, PreStartResponse> answers,
    String? forDate,
  }) async {
    submittedFor = forDate;
    final error = submitError;
    if (error != null) throw error;
    submitted = answers;
    return outcome;
  }

  @override
  Future<List<CrewPreStartRow>> getSiteCrewPreStartChecks({
    required String organizationId,
    required String siteId,
  }) async => crew;
}

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

Future<void> _pumpScreen(WidgetTester tester, _FakeService service) async {
  tester.view.physicalSize = const Size(600, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: PreStartCheckScreen(
        organizationId: 'org-1',
        check: const MyPreStartCheck(
          date: '2026-10-07',
          siteName: 'Rosslyn Site',
          questions: _questions,
        ),
        service: service,
      ),
    ),
  );
}

Finder _yes(int index) => find.widgetWithText(OutlinedButton, 'Yes').at(index);
Finder _no(int index) => find.widgetWithText(OutlinedButton, 'No').at(index);

void main() {
  group('domain parsing', () {
    test('MyPreStartCheck parses questions and an existing submission', () {
      final check = MyPreStartCheck.fromMap({
        'date': '2026-10-07',
        'site': {'id': 'site-1', 'name': 'Rosslyn Site'},
        'questions': [
          {'id': 'q1', 'prompt': 'P', 'kind': 'standard', 'risk': null},
          {'prompt': 'missing id is skipped'},
        ],
        'submission': {
          'outcome': 'goCorrected',
          'answers': [
            {'prompt': 'P', 'answer': 'yes', 'note': null},
            {'prompt': 'Q', 'answer': 'fixed', 'note': 'Swapped gloves'},
          ],
        },
      });

      expect(check.siteName, 'Rosslyn Site');
      expect(check.questions.map((q) => q.id), ['q1']);
      expect(check.isDone, isTrue);
      expect(check.submission!.outcome, PreStartOutcome.goCorrected);
      expect(check.submission!.issues.single.note, 'Swapped gloves');
    });

    test('an unknown outcome is never coerced into one', () {
      expect(PreStartOutcome.tryFromId('maybe'), isNull);
      expect(
        CrewPreStartRow.fromMap({'workerId': 'w1', 'outcome': 'x'})!.outcome,
        isNull,
      );
    });
  });

  group('PreStartCheckScreen', () {
    testWidgets('Submit stays disabled until every question is answered', (
      tester,
    ) async {
      final service = _FakeService();
      await _pumpScreen(tester, service);

      ElevatedButton submit() => tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Submit Check'),
      );
      expect(submit().onPressed, isNull);
      expect(find.text('HIGH RISK'), findsOneWidget);

      await tester.tap(_yes(0));
      await tester.pump();
      expect(submit().onPressed, isNull);
      expect(find.text('1 of 2 answered'), findsOneWidget);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Yes'));
      await tester.pump();
      expect(submit().onPressed, isNotNull);
    });

    testWidgets('all yes submits every answer and shows GO', (tester) async {
      final service = _FakeService();
      await _pumpScreen(tester, service);

      await tester.tap(_yes(0));
      await tester.pump();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Yes'));
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Submit Check'));
      await tester.pumpAndSettle();

      expect(service.submitted!.keys, ['std-ppe', 'req-height']);
      expect(
        service.submitted!.values.map((r) => r.answer),
        everyElement(PreStartAnswer.yes),
      );
      expect(find.text('GO'), findsOneWidget);
      expect(find.text('Safe to start work.'), findsOneWidget);
    });

    testWidgets('a No needs fixed / cannot fix and a note before submitting, '
        'and the server STOP is shown', (tester) async {
      final service = _FakeService(outcome: PreStartOutcome.stop);
      await _pumpScreen(tester, service);

      await tester.tap(_yes(0));
      await tester.pump();
      await tester.tap(_no(1));
      await tester.pump();
      ElevatedButton submit() => tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Submit Check'),
      );
      expect(submit().onPressed, isNull);

      await tester.tap(find.text("No — I can't fix it"));
      await tester.pump();
      expect(find.text('What is wrong?'), findsOneWidget);
      expect(submit().onPressed, isNull);

      await tester.enterText(find.byType(TextField), 'No harness anchor');
      await tester.pump();
      expect(find.text('So far: STOP'), findsOneWidget);
      await tester.tap(find.widgetWithText(ElevatedButton, 'Submit Check'));
      await tester.pumpAndSettle();

      final response = service.submitted!['req-height']!;
      expect(response.answer, PreStartAnswer.cannotFix);
      expect(response.note, 'No harness anchor');
      expect(find.text('STOP'), findsOneWidget);
      expect(find.textContaining('Your Foreman has been told'), findsOneWidget);
    });

    testWidgets('a server refusal is shown and the form stays open', (
      tester,
    ) async {
      final service = _FakeService(
        submitError: const DataException(
          "Today's questions have changed. Please reopen the check.",
        ),
      );
      await _pumpScreen(tester, service);

      await tester.tap(_yes(0));
      await tester.pump();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Yes'));
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Submit Check'));
      await tester.pumpAndSettle();

      expect(
        find.text("Today's questions have changed. Please reopen the check."),
        findsOneWidget,
      );
      expect(find.text('Submit Check'), findsOneWidget);
    });
  });

  group('no signal', () {
    testWidgets('a check made with no signal is saved on the phone; a STOP '
        'tells the worker to find their Foreman in person', (tester) async {
      final service = _FakeService(submitError: const SavedOfflineException());
      await _pumpScreen(tester, service);

      await tester.tap(_yes(0));
      await tester.pump();
      await tester.tap(_no(1));
      await tester.pump();
      await tester.tap(find.text("No — I can't fix it"));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'No harness anchor');
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Submit Check'));
      await tester.pumpAndSettle();

      expect(service.submittedFor, '2026-10-07');
      expect(find.text('STOP'), findsOneWidget);
      expect(
        find.textContaining('your check is saved on this phone'),
        findsOneWidget,
      );
      expect(
        find.textContaining('your Foreman has NOT been told yet'),
        findsOneWidget,
      );
      expect(find.textContaining('Your Foreman has been told'), findsNothing);
    });

    testWidgets('the card shows a check waiting on this phone, then the '
        'result once it is sent', (tester) async {
      SharedPreferences.setMockInitialValues({});
      var online = false;
      final outbox = Outbox(
        caller: (name, data) async => {'outcome': 'go'},
        uploader: (path, bytes) async => '',
        currentUid: () => 'w1',
        isOnline: () => online,
        preferences: SharedPreferences.getInstance,
      );
      addTearDown(outbox.dispose);
      await tester.runAsync(() async {
        try {
          await outbox.send(
            callable: 'submitPreStartCheck',
            data: {'organizationId': 'org-1', 'forDate': '2026-10-07'},
            label: 'Daily Pre-Start Check',
          );
        } on SavedOfflineException {
          // Expected: no signal.
        }
      });
      final service = _FakeService(
        check: const MyPreStartCheck(
          date: '2026-10-07',
          siteName: 'Rosslyn Site',
          questions: _questions,
        ),
      );
      await tester.pumpWidget(
        _wrap(
          WorkerPreStartCard(
            organizationId: 'org-1',
            service: service,
            outbox: outbox,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Pre-Start Check done - saved on this phone'),
        findsOneWidget,
      );
      expect(find.text('Start Check'), findsNothing);

      // Signal back: it is sent and the card asks the server again.
      service.check = const MyPreStartCheck(
        date: '2026-10-07',
        siteName: 'Rosslyn Site',
        questions: [],
        submission: PreStartSubmission(
          outcome: PreStartOutcome.go,
          answers: [],
        ),
      );
      online = true;
      await tester.runAsync(outbox.flush);
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(find.textContaining('saved on this phone'), findsNothing);
      expect(find.text('GO'), findsOneWidget);
    });
  });

  group('WorkerPreStartCard', () {
    testWidgets('prompts a worker who has not checked in yet', (tester) async {
      final service = _FakeService(
        check: const MyPreStartCheck(
          date: '2026-10-07',
          siteName: 'Rosslyn Site',
          questions: _questions,
        ),
      );
      await tester.pumpWidget(
        _wrap(WorkerPreStartCard(organizationId: 'org-1', service: service)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Do your Pre-Start Check'), findsOneWidget);
      expect(
        find.text('2 quick questions before you start work at Rosslyn Site.'),
        findsOneWidget,
      );
      expect(find.text('Start Check'), findsOneWidget);
    });

    testWidgets("shows today's result and the worker's notes once done", (
      tester,
    ) async {
      final service = _FakeService(
        check: const MyPreStartCheck(
          date: '2026-10-07',
          siteName: 'Rosslyn Site',
          questions: [],
          submission: PreStartSubmission(
            outcome: PreStartOutcome.goCorrected,
            answers: [
              PreStartAnsweredQuestion(
                prompt: 'I am wearing PPE.',
                answer: PreStartAnswer.fixed,
                note: 'Collected a helmet',
              ),
            ],
          ),
        ),
      );
      await tester.pumpWidget(
        _wrap(WorkerPreStartCard(organizationId: 'org-1', service: service)),
      );
      await tester.pumpAndSettle();

      expect(find.text('GO corrected'), findsOneWidget);
      expect(
        find.text('Fixed: I am wearing PPE. — Collected a helmet'),
        findsOneWidget,
      );
      expect(find.text('Start Check'), findsNothing);
    });
  });

  group('CrewPreStartCard', () {
    testWidgets('counts each result and lists STOP first, then GO corrected, '
        'then not done — never a plain GO', (tester) async {
      final service = _FakeService(
        crew: const [
          CrewPreStartRow(
            workerId: 'w1',
            workerName: 'Amina',
            outcome: PreStartOutcome.go,
            issues: [],
          ),
          CrewPreStartRow(
            workerId: 'w2',
            workerName: 'Brian',
            outcome: null,
            issues: [],
          ),
          CrewPreStartRow(
            workerId: 'w3',
            workerName: 'Chebet',
            outcome: PreStartOutcome.stop,
            issues: [
              PreStartAnsweredQuestion(
                prompt: 'My tools are checked.',
                answer: PreStartAnswer.cannotFix,
                note: 'Grinder guard broken',
              ),
            ],
          ),
        ],
      );
      await tester.pumpWidget(
        _wrap(
          SingleChildScrollView(
            child: CrewPreStartCard(
              organizationId: 'org-1',
              siteId: 'site-1',
              service: service,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('2 of 3 checked in'), findsOneWidget);
      expect(find.text('1 GO'), findsOneWidget);
      expect(find.text('1 STOP'), findsOneWidget);
      expect(find.text('1 Not done'), findsOneWidget);
      expect(
        find.text('Not fixed: My tools are checked. — Grinder guard broken'),
        findsOneWidget,
      );
      expect(find.text('Amina — GO'), findsNothing);
      final stopY = tester.getTopLeft(find.text('Chebet — STOP')).dy;
      final notDoneY = tester.getTopLeft(find.text('Brian — Not done yet')).dy;
      expect(stopY, lessThan(notDoneY));
    });
  });
}
