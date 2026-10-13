import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/features/daily_safety_meetings/domain/daily_safety_meeting_status.dart';
import 'package:jva_safety/features/safety_learning/data/worker_learning_repository.dart';
import 'package:jva_safety/features/safety_learning/data/worker_learning_service.dart';
import 'package:jva_safety/features/safety_learning/domain/todays_safety_readiness.dart';
import 'package:jva_safety/features/safety_learning/presentation/ready_for_today_card.dart';

class _FakeWorkerLearningService extends WorkerLearningService {
  _FakeWorkerLearningService(this.result);

  Object result;
  int calls = 0;

  @override
  Future<void> getMyRequiredLearning({required String organizationId}) async {}

  @override
  Future<TodaysSafetyReadiness> getMyTodaysSafetyReadiness({
    required String organizationId,
  }) async {
    calls++;
    final value = result;
    if (value is AppException) throw value;
    return value as TodaysSafetyReadiness;
  }
}

ReadinessItem item(String id) => ReadinessItem(
  learningId: id,
  title: 'Learning $id',
  status: ReadinessItemStatus.notStarted,
  canStart: true,
);

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Widget wrap(_FakeWorkerLearningService service, {List<String>? continued}) {
    return MaterialApp(
      home: Scaffold(
        body: ReadyForTodayCard(
          organizationId: 'org-alpha',
          workerUid: 'worker-1',
          workerLearningService: service,
          workerLearningRepository: WorkerLearningRepository(
            firestoreService: FirestoreService(firestore: firestore),
            organizationId: 'org-alpha',
          ),
          onContinue: (_) async => continued?.add('continue'),
        ),
      ),
    );
  }

  testWidgets('summarizes today: scope, meeting and remaining counts', (
    tester,
  ) async {
    final service = _FakeWorkerLearningService(
      TodaysSafetyReadiness(
        gatingSource: ReadinessGatingSource.meeting,
        meeting: ReadinessMeeting(
          id: 'm1',
          status: DailySafetyMeetingStatus.inProgress,
          startTime: DateTime(2026, 9, 25, 7, 52),
        ),
        projects: const [ReadinessScopeRef(id: 'p', name: 'Rosslyn Project')],
        activities: const [ReadinessScopeRef(id: 'a', name: 'Roofing')],
        beforeMeeting: [item('g1'), item('g2')],
        beforeWork: [item('p1'), item('p2')],
        additional: [item('x1'), item('x2'), item('x3')],
      ),
    );
    final continued = <String>[];
    await tester.pumpWidget(wrap(service, continued: continued));
    await tester.pumpAndSettle();

    expect(find.text('Rosslyn Project'), findsOneWidget);
    expect(find.text('Roofing'), findsOneWidget);
    expect(
      find.textContaining('Safety Meeting — in progress since'),
      findsOneWidget,
    );
    expect(find.text('Needed today'), findsOneWidget);
    expect(find.text('Before work'), findsOneWidget);
    expect(find.text('2 items remaining'), findsNWidgets(2));
    // The additional-learning inventory is never presented as today's task.
    expect(find.textContaining('additional'), findsNothing);
    expect(find.text('Learning x1'), findsNothing);

    await tester.tap(find.text('Continue Learning'));
    await tester.pumpAndSettle();

    expect(continued, ['continue']);
    // Returning re-fetches the server answer.
    expect(service.calls, 2);
  });

  testWidgets('counts drop live as the worker completes learning', (
    tester,
  ) async {
    final service = _FakeWorkerLearningService(
      TodaysSafetyReadiness(
        gatingSource: ReadinessGatingSource.assignments,
        beforeMeeting: [item('g1')],
      ),
    );
    await tester.pumpWidget(wrap(service));
    await tester.pumpAndSettle();

    expect(find.text('1 item remaining'), findsOneWidget);

    await firestore
        .doc('organizations/org-alpha/worker_learning_records/worker-1_g1')
        .set({
          'workerUid': 'worker-1',
          'organizationId': 'org-alpha',
          'learningId': 'g1',
          'status': 'completed',
          'assignedAt': Timestamp.now(),
          'completedAt': Timestamp.now(),
        });
    await tester.pumpAndSettle();

    expect(find.text("You're ready for today"), findsOneWidget);
  });

  testWidgets('shows an error with Retry', (tester) async {
    final service = _FakeWorkerLearningService(const DataException('boom'));
    await tester.pumpWidget(wrap(service));
    await tester.pumpAndSettle();

    expect(find.text("Could not load today's readiness."), findsOneWidget);

    service.result = const TodaysSafetyReadiness(
      gatingSource: ReadinessGatingSource.assignments,
    );
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text("You're ready for today"), findsOneWidget);
  });
}
