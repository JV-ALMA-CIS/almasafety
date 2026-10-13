import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/features/safety_learning/data/safety_learning_repository.dart';
import 'package:jva_safety/features/safety_learning/data/worker_learning_repository.dart';
import 'package:jva_safety/features/safety_learning/data/worker_learning_service.dart';
import 'package:jva_safety/features/safety_learning/domain/todays_safety_readiness.dart';
import 'package:jva_safety/features/safety_learning/presentation/todays_safety_readiness_screen.dart';

/// Returns [results] in order (last one repeats); a thrown [AppException]
/// entry is rethrown.
class _FakeWorkerLearningService extends WorkerLearningService {
  _FakeWorkerLearningService(this.results);

  final List<Object> results;
  int readinessCalls = 0;
  Completer<TodaysSafetyReadiness>? pending;

  @override
  Future<void> getMyRequiredLearning({required String organizationId}) async {}

  @override
  Future<TodaysSafetyReadiness> getMyTodaysSafetyReadiness({
    required String organizationId,
  }) async {
    final completer = pending;
    if (completer != null) return completer.future;
    final result =
        results[readinessCalls < results.length
            ? readinessCalls
            : results.length - 1];
    readinessCalls++;
    if (result is AppException) throw result;
    return result as TodaysSafetyReadiness;
  }
}

ReadinessItem item(String id, {bool canStart = true}) => ReadinessItem(
  learningId: id,
  title: 'Learning $id',
  status: ReadinessItemStatus.notStarted,
  canStart: canStart,
);

TodaysSafetyReadiness readiness({
  List<ReadinessItem> beforeMeeting = const [],
  List<ReadinessItem> beforeWork = const [],
  List<ReadinessItem> additional = const [],
  List<ReadinessScopeRef> activities = const [
    ReadinessScopeRef(id: 'a1', name: 'Roofing'),
  ],
  ReadinessGatingSource gatingSource = ReadinessGatingSource.meeting,
  ReadinessMeeting? meeting,
  bool isForeman = false,
}) => TodaysSafetyReadiness(
  gatingSource: gatingSource,
  isForeman: isForeman,
  meeting: meeting,
  projects: const [ReadinessScopeRef(id: 'p1', name: 'Rosslyn Project')],
  sites: const [ReadinessScopeRef(id: 's1', name: 'Site A')],
  activities: activities,
  beforeMeeting: beforeMeeting,
  beforeWork: beforeWork,
  additional: additional,
);

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Widget wrapScreen(_FakeWorkerLearningService service) {
    final firestoreService = FirestoreService(firestore: firestore);
    return MaterialApp(
      home: TodaysSafetyReadinessScreen(
        organizationId: 'org-alpha',
        workerUid: 'worker-1',
        workerLearningService: service,
        workerLearningRepository: WorkerLearningRepository(
          firestoreService: firestoreService,
          organizationId: 'org-alpha',
        ),
        safetyLearningRepository: SafetyLearningRepository(
          firestoreService: firestoreService,
          organizationId: 'org-alpha',
        ),
      ),
    );
  }

  Widget wrapView(TodaysSafetyReadiness value, {List<String>? opened}) {
    return MaterialApp(
      home: Scaffold(
        body: TodaysSafetyReadinessView(
          readiness: value,
          onOpen: (item) => opened?.add(item.learningId),
        ),
      ),
    );
  }

  Future<void> completeRecord(String learningId) async {
    await firestore
        .doc(
          'organizations/org-alpha/worker_learning_records/'
          'worker-1_$learningId',
        )
        .set({
          'workerUid': 'worker-1',
          'organizationId': 'org-alpha',
          'learningId': learningId,
          'status': 'completed',
          'assignedAt': Timestamp.now(),
          'completedAt': Timestamp.now(),
        });
  }

  group('TodaysSafetyReadinessView', () {
    testWidgets('renders the attendance-gating and pre-work sections with '
        'their instructions', (tester) async {
      await tester.pumpWidget(
        wrapView(
          readiness(beforeMeeting: [item('g1')], beforeWork: [item('p1')]),
        ),
      );

      final meeting = find.byKey(const Key('readiness-before-meeting'));
      final work = find.byKey(const Key('readiness-before-work'));
      expect(
        find.descendant(of: meeting, matching: find.text('Learning g1')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: meeting,
          matching: find.text('Complete before the safety meeting.'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: work, matching: find.text('Learning p1')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: work,
          matching: find.text('Complete before starting this activity.'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('shows today\'s project, site, activity and meeting status', (
      tester,
    ) async {
      await tester.pumpWidget(wrapView(readiness(beforeMeeting: [item('g')])));

      expect(find.text('Rosslyn Project'), findsOneWidget);
      expect(find.text('Site A'), findsOneWidget);
      expect(find.text('Roofing'), findsOneWidget);
      expect(find.text('Safety Meeting — not started yet'), findsOneWidget);
    });

    testWidgets('an item that is both gating and pre-work is shown once, in '
        'Before today\'s meeting', (tester) async {
      // The server places a both-flags item only in beforeMeeting; the view
      // must not repeat it anywhere else.
      await tester.pumpWidget(
        wrapView(
          readiness(beforeMeeting: [item('both')], beforeWork: [item('p1')]),
        ),
      );

      expect(find.text('Learning both'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('readiness-before-meeting')),
          matching: find.text('Learning both'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('additional learning is collapsed behind a count', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrapView(
          readiness(
            beforeMeeting: [item('g')],
            additional: [item('x1'), item('x2'), item('x3')],
          ),
        ),
      );

      expect(find.text('When you can: 3 more lessons'), findsOneWidget);
      expect(find.text('Learning x1'), findsNothing);

      await tester.tap(find.text('View'));
      await tester.pump();

      expect(find.text('Learning x1'), findsOneWidget);
      expect(find.text('Learning x3'), findsOneWidget);
    });

    testWidgets('empty readiness shows the ready state', (tester) async {
      await tester.pumpWidget(wrapView(readiness()));

      expect(find.text("You're ready for today"), findsOneWidget);
      expect(find.byKey(const Key('readiness-before-meeting')), findsNothing);
      expect(find.byKey(const Key('readiness-before-work')), findsNothing);
    });

    testWidgets('lists every assigned activity for a multi-activity worker', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrapView(
          readiness(
            activities: const [
              ReadinessScopeRef(id: 'a1', name: 'Roofing'),
              ReadinessScopeRef(id: 'a2', name: 'Scaffolding'),
            ],
          ),
        ),
      );

      expect(find.text('Roofing, Scaffolding'), findsOneWidget);
    });

    testWidgets('notes when gating is not yet confirmed by a meeting', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrapView(
          readiness(
            beforeMeeting: [item('g')],
            gatingSource: ReadinessGatingSource.assignments,
          ),
        ),
      );

      expect(
        find.textContaining('Confirmed when your Foreman starts the meeting'),
        findsOneWidget,
      );
    });

    testWidgets('a Foreman sees start-the-meeting wording, not the worker '
        'note', (tester) async {
      await tester.pumpWidget(
        wrapView(
          readiness(
            beforeMeeting: [item('g')],
            gatingSource: ReadinessGatingSource.assignments,
            isForeman: true,
          ),
        ),
      );

      expect(
        find.text('Complete before you can start the safety meeting.'),
        findsOneWidget,
      );
      expect(
        find.text("Based on your site's active activities."),
        findsOneWidget,
      );
      expect(find.textContaining('Confirmed when your Foreman'), findsNothing);
    });

    testWidgets('tapping a startable item opens it; a non-startable one '
        'explains why and is not tappable', (tester) async {
      final opened = <String>[];
      await tester.pumpWidget(
        wrapView(
          readiness(beforeMeeting: [item('ok'), item('no', canStart: false)]),
          opened: opened,
        ),
      );

      await tester.tap(find.text('Learning ok'));
      await tester.tap(find.text('Learning no'));

      expect(opened, ['ok']);
      expect(
        find.textContaining('Not yet linked to your assigned activities'),
        findsOneWidget,
      );
    });
  });

  group(
    'TodaysSafetyReadinessScreen (embedded as the Safety Learning tab)',
    () {
      testWidgets('shows a page heading and an All my learning link instead '
          'of its own app bar', (tester) async {
        final firestoreService = FirestoreService(firestore: firestore);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TodaysSafetyReadinessScreen(
                organizationId: 'org-alpha',
                workerUid: 'worker-1',
                embedded: true,
                workerLearningService: _FakeWorkerLearningService([
                  readiness(beforeMeeting: [item('g1')]),
                ]),
                workerLearningRepository: WorkerLearningRepository(
                  firestoreService: firestoreService,
                  organizationId: 'org-alpha',
                ),
                safetyLearningRepository: SafetyLearningRepository(
                  firestoreService: firestoreService,
                  organizationId: 'org-alpha',
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(AppBar), findsNothing);
        expect(find.text("Today's Safety Readiness"), findsOneWidget);
        expect(find.text('All my learning'), findsOneWidget);
        expect(find.text('Learning g1'), findsOneWidget);
      });
    },
  );

  group('TodaysSafetyReadinessScreen', () {
    testWidgets('shows a loading indicator until readiness arrives', (
      tester,
    ) async {
      final service = _FakeWorkerLearningService([readiness()])
        ..pending = Completer<TodaysSafetyReadiness>();
      await tester.pumpWidget(wrapScreen(service));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      service.pending!.complete(readiness());
      service.pending = null;
      await tester.pumpAndSettle();

      expect(find.text("You're ready for today"), findsOneWidget);
    });

    testWidgets('shows an error with Retry, and recovers', (tester) async {
      final service = _FakeWorkerLearningService([
        const DataException('boom'),
        readiness(beforeMeeting: [item('g1')]),
      ]);
      await tester.pumpWidget(wrapScreen(service));
      await tester.pumpAndSettle();

      expect(
        find.text("Could not load today's safety readiness."),
        findsOneWidget,
      );

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(find.text('Learning g1'), findsOneWidget);
    });

    testWidgets('completed learning disappears from today\'s list live', (
      tester,
    ) async {
      final service = _FakeWorkerLearningService([
        readiness(beforeMeeting: [item('g1')], beforeWork: [item('p1')]),
      ]);
      await tester.pumpWidget(wrapScreen(service));
      await tester.pumpAndSettle();

      expect(find.text('Learning g1'), findsOneWidget);

      await completeRecord('g1');
      await tester.pumpAndSettle();

      expect(find.text('Learning g1'), findsNothing);
      expect(find.text('Learning p1'), findsOneWidget);

      await completeRecord('p1');
      await tester.pumpAndSettle();

      expect(find.text("You're ready for today"), findsOneWidget);
      // No re-fetch was needed.
      expect(service.readinessCalls, 1);
    });
  });
}
