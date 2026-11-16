import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/membership.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/organizations/domain/organization_record_status.dart';
import 'package:jva_safety/features/safety_learning/data/safety_learning_admin_service.dart';
import 'package:jva_safety/features/safety_learning/data/safety_learning_repository.dart';
import 'package:jva_safety/features/safety_learning/data/worker_learning_repository.dart';
import 'package:jva_safety/features/safety_learning/data/worker_learning_service.dart';
import 'package:jva_safety/features/safety_learning/domain/complete_learning_result.dart';
import 'package:jva_safety/features/safety_learning/domain/knowledge_check_admin_question.dart';
import 'package:jva_safety/features/safety_learning/domain/knowledge_check_question.dart';
import 'package:jva_safety/features/safety_learning/domain/knowledge_check_result.dart';
import 'package:jva_safety/features/safety_learning/domain/lesson_quiz.dart';
import 'package:jva_safety/features/safety_learning/domain/safety_learning.dart';
import 'package:jva_safety/features/safety_learning/domain/safety_learning_type.dart';
import 'package:jva_safety/features/safety_learning/domain/submitted_answer.dart';
import 'package:jva_safety/features/safety_learning/domain/todays_safety_readiness.dart';
import 'package:jva_safety/features/safety_learning/domain/worker_learning_record.dart';
import 'package:jva_safety/features/safety_learning/domain/worker_learning_status.dart';
import 'package:jva_safety/features/safety_learning/presentation/knowledge_check_questions_screen.dart';
import 'package:jva_safety/features/safety_learning/presentation/learning_detail_screen.dart';
import 'package:jva_safety/features/safety_learning/presentation/todays_safety_readiness_screen.dart';
import 'package:jva_safety/features/safety_requirements/data/safety_requirement_repository.dart';
import 'package:jva_safety/features/safety_requirements/domain/safety_requirement.dart';
import 'package:jva_safety/features/safety_videos/presentation/safety_videos_screen.dart';
import 'package:jva_safety/features/safety_videos/presentation/video_management_view.dart';

const _org = 'org-alpha';
const _bucket = 'jva-test.firebasestorage.app';

/// The public YouTube video used as the manual test candidate.
const youtubeTestUrl = 'https://www.youtube.com/watch?v=jfKfPfyJRdk';

const _question = KnowledgeCheckQuestion(
  id: 'q1',
  prompt: 'Which way does a ladder face?',
  options: [
    KnowledgeCheckOption(id: 'a', text: 'Towards the wall'),
    KnowledgeCheckOption(id: 'b', text: 'Away from the wall'),
  ],
  order: 0,
);

/// What a fake save recorded.
class _Created {
  const _Created(this.title, this.type, this.contentReference, this.status);

  final String title;
  final SafetyLearningType type;
  final String contentReference;
  final OrganizationRecordStatus status;
}

/// Records authoring calls; [nextError] fails the next save, and
/// [quizCounts] / [quizCountsError] answer `getVideoQuizSummary`.
class _FakeAdminService extends SafetyLearningAdminService {
  _FakeAdminService({this.quizCounts = const {}});

  final List<_Created> created = [];
  final List<(String, OrganizationRecordStatus?)> updated = [];
  final List<String> listedFor = [];
  Map<String, int> quizCounts;
  Object? quizCountsError;
  int summaryCalls = 0;

  /// When set, `getVideoQuizSummary` waits for it.
  Completer<void>? pendingCounts;
  Object? nextError;

  void _maybeFail() {
    final error = nextError;
    nextError = null;
    if (error != null) throw error;
  }

  @override
  Future<String> createSafetyLearning({
    required String organizationId,
    required String title,
    required SafetyLearningType type,
    required String contentReference,
    String? description,
    OrganizationRecordStatus status = OrganizationRecordStatus.active,
    int? minimumWatchSeconds,
    int? passingScorePercent,
  }) async {
    _maybeFail();
    created.add(_Created(title, type, contentReference, status));
    return 'new-id';
  }

  @override
  Future<void> updateSafetyLearning(
    String organizationId,
    String id, {
    String? title,
    SafetyLearningType? type,
    String? contentReference,
    String? description,
    OrganizationRecordStatus? status,
    int? minimumWatchSeconds,
    int? passingScorePercent,
  }) async {
    _maybeFail();
    updated.add((id, status));
  }

  @override
  Future<List<KnowledgeCheckAdminQuestion>> listKnowledgeCheckQuestions({
    required String organizationId,
    required String learningId,
  }) async {
    listedFor.add(learningId);
    return const [];
  }

  final List<String> deleted = [];
  Completer<void>? pendingDelete;

  @override
  Future<bool> deleteSafetyLearning({
    required String organizationId,
    required String id,
  }) async {
    deleted.add(id);
    final wait = pendingDelete;
    if (wait != null) await wait.future;
    _maybeFail();
    return true;
  }

  @override
  Future<Map<String, int>> getVideoQuizSummary({
    required String organizationId,
  }) async {
    summaryCalls++;
    final wait = pendingCounts;
    if (wait != null) await wait.future;
    final error = quizCountsError;
    if (error != null) throw error;
    return quizCounts;
  }
}

String jvaUrl(String file) =>
    'https://firebasestorage.googleapis.com/v0/b/$_bucket/o/'
    '${Uri.encodeComponent('organizations/$_org/safety_learning/1/$file')}'
    '?alt=media&token=t';

class _FakeSession extends SessionController {
  _FakeSession({required AppRole role, String? organizationId = _org})
    : _profile = UserProfile(
        uid: 'worker-1',
        name: 'Test User',
        email: 'user@example.com',
        accountStatus: AccountStatus.active,
        platformRole: role == AppRole.admin ? role : null,
      ),
      _organizationId = organizationId,
      _membership = role == AppRole.admin || organizationId == null
          ? null
          : Membership(
              organizationId: organizationId,
              role: role,
              status: MembershipStatus.active,
            );

  final UserProfile _profile;
  final String? _organizationId;
  final Membership? _membership;

  @override
  UserProfile? get profile => _profile;

  @override
  String? get activeOrganizationId => _organizationId;

  @override
  Membership? get activeMembership => _membership;
}

/// Records every learning call; readiness answers come from [results] in
/// order (the last repeats), and an [AppException] entry is thrown.
/// [quizzes] answers `getLessonQuiz` per learning id (default: none).
class _FakeService extends WorkerLearningService {
  _FakeService([this.results = const [], this.quizzes = const {}]);

  final List<Object> results;
  final Map<String, LessonQuiz> quizzes;
  final List<String> calls = [];
  Completer<TodaysSafetyReadiness>? pending;

  int get readinessCalls =>
      calls.where((c) => c == 'getMyTodaysSafetyReadiness').length;

  /// The calls that would write or record learning.
  List<String> get recordingCalls => [
    for (final call in calls)
      if (call.startsWith('startLearning') ||
          call.startsWith('completeLearning'))
        call,
  ];

  @override
  Future<void> getMyRequiredLearning({required String organizationId}) async {
    calls.add('getMyRequiredLearning');
  }

  @override
  Future<TodaysSafetyReadiness> getMyTodaysSafetyReadiness({
    required String organizationId,
  }) async {
    final index = readinessCalls;
    calls.add('getMyTodaysSafetyReadiness');
    final completer = pending;
    if (completer != null) return completer.future;
    final result = results[index < results.length ? index : results.length - 1];
    if (result is AppException) throw result;
    return result as TodaysSafetyReadiness;
  }

  @override
  Future<void> startLearning({
    required String organizationId,
    required String learningId,
  }) async {
    calls.add('startLearning:$learningId');
  }

  @override
  Future<LessonQuiz> getLessonQuiz({
    required String organizationId,
    required String learningId,
  }) async {
    calls.add('getLessonQuiz:$learningId');
    return quizzes[learningId] ??
        const LessonQuiz(questions: [], required: true, quizRequired: false);
  }

  @override
  Future<CompleteLearningResult> completeLearning({
    required String organizationId,
    required String learningId,
    List<SubmittedAnswer>? selectedAnswers,
  }) async {
    calls.add('completeLearning:$learningId');
    return const CompleteLearningResult(
      status: WorkerLearningStatus.completed,
      contentCompleted: true,
    );
  }

  @override
  Future<KnowledgeCheckResult> practiceKnowledgeCheck({
    required String organizationId,
    required String learningId,
    required List<SubmittedAnswer> selectedAnswers,
  }) async {
    calls.add('practiceKnowledgeCheck:$learningId');
    return const KnowledgeCheckResult(
      passed: true,
      score: 1,
      totalQuestions: 1,
    );
  }
}

/// Requirements that never load.
class _FailingRequirementRepository extends SafetyRequirementRepository {
  _FailingRequirementRepository(FirestoreService service)
    : super(firestoreService: service, organizationId: _org);

  @override
  Stream<List<SafetyRequirement>> watchAll() =>
      Stream.error(Exception('offline'));
}

class _FailingLearningRepository extends SafetyLearningRepository {
  _FailingLearningRepository(FirestoreService service)
    : super(firestoreService: service, organizationId: _org);

  int attempts = 0;

  @override
  Stream<List<SafetyLearning>> watchAll() {
    attempts++;
    return Stream.error(Exception('offline'));
  }
}

/// A records stream the test controls: nothing until [controller] emits, or
/// an error on every subscription when [fail] is set.
class _ControlledRecordRepository extends WorkerLearningRepository {
  _ControlledRecordRepository(FirestoreService service)
    : super(firestoreService: service, organizationId: _org);

  final controller = StreamController<List<WorkerLearningRecord>>.broadcast();
  bool fail = false;
  int subscriptions = 0;

  /// When set, each new subscription gets this straight away.
  List<WorkerLearningRecord>? ready;

  @override
  Stream<List<WorkerLearningRecord>> watchMine(String workerUid) {
    subscriptions++;
    if (fail) return Stream.error(Exception('offline'));
    final value = ready;
    return value != null ? Stream.value(value) : controller.stream;
  }
}

ReadinessItem item(
  String id, {
  String type = 'video',
  bool canStart = true,
  int questionCount = 0,
  bool quizRequired = false,
  bool contentCompleted = false,
  ReadinessItemStatus status = ReadinessItemStatus.notStarted,
}) => ReadinessItem(
  learningId: id,
  title: id,
  type: type,
  status: status,
  canStart: canStart,
  questionCount: questionCount,
  quizRequired: quizRequired,
  contentCompleted: contentCompleted,
);

TodaysSafetyReadiness readiness({
  List<ReadinessItem> beforeMeeting = const [],
  List<ReadinessItem> beforeWork = const [],
  List<ReadinessItem> additional = const [],
  List<ReadinessItem> neededTomorrow = const [],
}) => TodaysSafetyReadiness(
  gatingSource: ReadinessGatingSource.assignments,
  beforeMeeting: beforeMeeting,
  beforeWork: beforeWork,
  additional: additional,
  neededTomorrow: neededTomorrow,
);

void main() {
  late FakeFirebaseFirestore firestore;
  late FirestoreService firestoreService;

  setUp(() {
    firestore = FakeFirebaseFirestore();
    firestoreService = FirestoreService(firestore: firestore);
  });

  Future<void> seed(
    String id, {
    String? title,
    String type = 'video',
    String status = 'active',
    String contentReference = 'https://cdn.example.org/clip.mp4',
    String? description,
    int? minimumWatchSeconds,
  }) => firestore.doc('organizations/$_org/safety_learning/$id').set({
    'organizationId': _org,
    'title': title ?? id,
    'type': type,
    'status': status,
    'contentReference': contentReference,
    'description': ?description,
    'minimumWatchSeconds': ?minimumWatchSeconds,
  });

  Future<void> seedRequirement(
    String id,
    List<String> learningIds, {
    String status = 'active',
  }) => firestore.doc('organizations/$_org/safety_requirements/$id').set({
    'organizationId': _org,
    'name': 'Requirement $id',
    'category': 'General',
    'risk': 'medium',
    'requiredLearningIds': learningIds,
    'status': status,
  });

  Future<void> seedRecord(
    String learningId,
    String status, {
    bool contentCompleted = false,
  }) => firestore
      .doc('organizations/$_org/worker_learning_records/worker-1_$learningId')
      .set({
        'workerUid': 'worker-1',
        'organizationId': _org,
        'learningId': learningId,
        'status': status,
        'assignedAt': Timestamp.now(),
        if (contentCompleted) 'contentCompletedAt': Timestamp.now(),
      });

  Widget wrap({
    required AppRole role,
    _FakeService? service,
    SafetyLearningRepository? learningRepository,
    WorkerLearningRepository? recordRepository,
    SafetyLearningAdminService? adminService,
    ExternalLinkLauncher? launcher,
    SafetyRequirementRepository? requirementRepository,
  }) {
    return ChangeNotifierProvider<SessionController>(
      create: (_) => _FakeSession(role: role),
      child: MaterialApp(
        home: Scaffold(
          body: SafetyVideosScreen(
            workerLearningService: service ?? _FakeService(),
            safetyLearningRepository:
                learningRepository ??
                SafetyLearningRepository(
                  firestoreService: firestoreService,
                  organizationId: _org,
                ),
            workerLearningRepository:
                recordRepository ??
                WorkerLearningRepository(
                  firestoreService: firestoreService,
                  organizationId: _org,
                ),
            requirementRepository:
                requirementRepository ??
                SafetyRequirementRepository(
                  firestoreService: firestoreService,
                  organizationId: _org,
                ),
            storageBucket: _bucket,
            adminService: adminService ?? _FakeAdminService(),
            externalLinkLauncher: launcher ?? (_) async => true,
          ),
        ),
      ),
    );
  }

  /// A phone-width, very tall view, so every section of the (lazily built)
  /// list is on screen.
  ///
  /// [settle] false stops after a few frames instead — needed while a
  /// spinner is showing, since it never settles.
  /// A status or progress badge ON A CARD (the filter chips use the same
  /// words).
  Finder badge(String text) => find.descendant(
    of: find.byType(SafetyVideoCard),
    matching: find.text(text),
  );

  /// Opens a manager card's "More actions" menu.
  Future<void> openMore(WidgetTester tester) async {
    await tester.tap(find.byTooltip('More actions').first);
    await tester.pumpAndSettle();
  }

  Future<void> pumpScreen(
    WidgetTester tester,
    Widget widget, {
    bool settle = true,
  }) async {
    if (tester.view.physicalSize == const Size(2400, 1800)) {
      tester.view.physicalSize = const Size(420, 5000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }
    await tester.pumpWidget(widget);
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }
  }

  group('Worker: required training first', () {
    testWidgets('splits videos into today, required and more — once each', (
      tester,
    ) async {
      await seed('today-video', title: 'Ladder Safety');
      await seed('work-video', title: 'Working at Height');
      await seed('tomorrow-video', title: 'Manual Handling');
      await seed('free-video', title: 'Fire Safety');
      await seed('old-video', title: 'Retired Video', status: 'inactive');
      await seed('doc', title: 'PPE Handbook', type: 'document');
      final service = _FakeService([
        readiness(
          beforeMeeting: [
            item('today-video'),
            item('doc', type: 'document'),
          ],
          beforeWork: [item('work-video'), item('today-video')],
          neededTomorrow: [item('tomorrow-video')],
        ),
      ]);

      await pumpScreen(tester, wrap(role: AppRole.worker, service: service));

      expect(find.text('Watch before today\'s meeting'), findsOneWidget);
      expect(find.text('Required for your work'), findsOneWidget);
      expect(find.text('More safety videos'), findsOneWidget);
      expect(find.text('Needed today'), findsOneWidget);
      expect(badge('Required'), findsOneWidget);
      expect(find.text('Get ahead'), findsOneWidget);
      // No Safety Requirement: still listed, as General learning.
      expect(badge('General learning'), findsOneWidget);
      expect(find.text('Retired Video'), findsNothing);
      expect(find.text('PPE Handbook'), findsNothing);
      expect(
        find.text('1 other lesson is due today — open Safety Learning'),
        findsOneWidget,
      );
      expect(service.calls, contains('getMyRequiredLearning'));
    });

    testWidgets('a required video not started shows Watch Video as its next '
        'step; a General learning video offers Watch Video too', (
      tester,
    ) async {
      await seed('v1', title: 'Ladder Safety');
      await seed('v2', title: 'Fire Safety');
      await pumpScreen(
        tester,
        wrap(
          role: AppRole.worker,
          service: _FakeService([
            readiness(
              beforeWork: [item('v1', questionCount: 2, quizRequired: true)],
            ),
          ]),
        ),
      );
      expect(find.text('Watch Video'), findsNWidgets(2));
      expect(find.text('New'), findsOneWidget);
      expect(find.text('Quiz required'), findsOneWidget);
      expect(find.text('Take Quiz'), findsNothing);
    });

    testWidgets('a started video shows Continue Video', (tester) async {
      await seed('v1', title: 'Ladder Safety');
      await seedRecord('v1', 'inProgress');
      await pumpScreen(
        tester,
        wrap(
          role: AppRole.worker,
          service: _FakeService([
            readiness(
              beforeWork: [
                item(
                  'v1',
                  status: ReadinessItemStatus.inProgress,
                  questionCount: 1,
                  quizRequired: true,
                ),
              ],
            ),
          ]),
        ),
      );
      expect(find.text('Continue Video'), findsOneWidget);
      expect(find.text('Started'), findsOneWidget);
    });

    testWidgets('once the video is watched, the required quiz is the next '
        'action', (tester) async {
      await seed('v1', title: 'Ladder Safety');
      await seedRecord('v1', 'inProgress', contentCompleted: true);
      await pumpScreen(
        tester,
        wrap(
          role: AppRole.worker,
          service: _FakeService([
            readiness(
              beforeWork: [
                item(
                  'v1',
                  status: ReadinessItemStatus.inProgress,
                  questionCount: 1,
                  quizRequired: true,
                ),
              ],
            ),
          ]),
        ),
      );
      expect(find.text('Take Quiz'), findsOneWidget);
      expect(find.text('Quiz outstanding'), findsOneWidget);
      expect(find.text('Watch Video'), findsNothing);
      expect(find.text('Continue Video'), findsNothing);
    });

    testWidgets('an optional quiz never becomes the next action', (
      tester,
    ) async {
      await seed('v1', title: 'Ladder Safety');
      await pumpScreen(
        tester,
        wrap(
          role: AppRole.worker,
          service: _FakeService([
            readiness(beforeWork: [item('v1', questionCount: 2)]),
          ]),
        ),
      );
      expect(find.text('Optional quiz'), findsOneWidget);
      expect(find.text('Watch Video'), findsOneWidget);
      expect(find.text('Take Quiz'), findsNothing);
    });

    testWidgets('says so when no video is needed before today\'s meeting', (
      tester,
    ) async {
      await seed('v1');
      await pumpScreen(
        tester,
        wrap(role: AppRole.worker, service: _FakeService([readiness()])),
      );
      expect(
        find.text('No videos needed before today\'s meeting.'),
        findsOneWidget,
      );
    });

    testWidgets('a completed required video is grouped under Completed', (
      tester,
    ) async {
      await seed('v1', title: 'Ladder Safety');
      await seedRecord('v1', 'completed');
      await pumpScreen(
        tester,
        wrap(
          role: AppRole.worker,
          service: _FakeService([
            readiness(beforeWork: [item('v1')]),
          ]),
        ),
      );
      expect(find.text('Completed (1)'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
      expect(badge('Required'), findsNothing);
      expect(find.text('Watch Video'), findsNothing);
    });

    testWidgets('shows a loading message while readiness is checked', (
      tester,
    ) async {
      await seed('v1');
      final service = _FakeService()
        ..pending = Completer<TodaysSafetyReadiness>();
      await tester.pumpWidget(wrap(role: AppRole.worker, service: service));
      await tester.pump();
      expect(find.text('Checking what you need…'), findsOneWidget);
      service.pending!.complete(readiness());
      service.pending = null;
      await tester.pumpAndSettle();
      expect(find.text('Checking what you need…'), findsNothing);
    });

    testWidgets('a readiness failure shows every video without requirement '
        'labels (each can still be watched), and Try again reloads', (
      tester,
    ) async {
      await seed('v1', title: 'Ladder Safety');
      await seed('v2', title: 'Fire Safety');
      final service = _FakeService([
        const NetworkException('offline'),
        readiness(beforeWork: [item('v1')]),
      ]);
      await pumpScreen(tester, wrap(role: AppRole.worker, service: service));

      expect(
        find.textContaining('Couldn\'t check which videos'),
        findsOneWidget,
      );
      expect(find.text('All safety videos'), findsOneWidget);
      expect(badge('General learning'), findsNothing);
      expect(badge('Required'), findsNothing);
      expect(find.text('Watch Video'), findsNWidgets(2));

      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(service.readinessCalls, 2);
      expect(badge('Required'), findsOneWidget);
      expect(badge('General learning'), findsOneWidget);
    });

    testWidgets('Watch Video opens the existing lesson and completes it '
        'through the same learning flow', (tester) async {
      await seed('v1', title: 'Ladder Safety');
      final service = _FakeService([
        readiness(beforeMeeting: [item('v1')]),
      ]);
      await pumpScreen(tester, wrap(role: AppRole.worker, service: service));

      await tester.tap(find.text('Watch Video'));
      await tester.pumpAndSettle();
      expect(find.byType(LearningDetailScreen), findsOneWidget);
      expect(find.text(LearningDetailScreen.optionalWatchNote), findsNothing);

      await tester.tap(find.text('Watch Video'));
      await tester.pumpAndSettle();
      expect(service.calls, contains('startLearning:v1'));

      await tester.tap(find.text("I've Watched the Video"));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Submit'));
      await tester.pumpAndSettle();
      expect(service.calls, contains('completeLearning:v1'));
    });

    testWidgets(
      'a completed video moves to Completed when its record updates',
      (tester) async {
        await seed('v1', title: 'Ladder Safety');
        await pumpScreen(
          tester,
          wrap(
            role: AppRole.worker,
            service: _FakeService([
              readiness(beforeMeeting: [item('v1')]),
            ]),
          ),
        );
        expect(find.text('Needed today'), findsOneWidget);

        // What `completeLearning` writes server-side — the same record
        // Safety Learning, Crew Compliance and Reports read.
        await seedRecord('v1', 'completed');
        await tester.pumpAndSettle();
        expect(find.text('Needed today'), findsNothing);
        expect(find.text('Completed (1)'), findsOneWidget);
      },
    );

    testWidgets('an optional video opens watch-only: no learning record is '
        'touched, and its quiz can be practised', (tester) async {
      await seed('v1', title: 'Fire Safety');
      final service = _FakeService(
        [readiness()],
        {
          'v1': const LessonQuiz(
            questions: [_question],
            required: false,
            quizRequired: false,
          ),
        },
      );
      await pumpScreen(tester, wrap(role: AppRole.worker, service: service));

      await tester.tap(find.text('Fire Safety'));
      await tester.pumpAndSettle();
      expect(find.text(LearningDetailScreen.optionalWatchNote), findsOneWidget);
      expect(find.text('Watch Video'), findsNothing);
      await tester.tap(find.text('Practice Quiz'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Towards the wall'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Submit'));
      await tester.pumpAndSettle();
      expect(service.calls, contains('practiceKnowledgeCheck:v1'));
      expect(service.recordingCalls, isEmpty);
    });

    testWidgets('a required video the server would refuse opens watch-only', (
      tester,
    ) async {
      await seed('v1', title: 'Ladder Safety');
      final service = _FakeService([
        readiness(beforeMeeting: [item('v1', canStart: false)]),
      ]);
      await pumpScreen(tester, wrap(role: AppRole.worker, service: service));
      await tester.tap(find.text('Ladder Safety'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Ask your Foreman'), findsOneWidget);
      expect(find.text('Watch Video'), findsNothing);
      expect(service.recordingCalls, isEmpty);
    });
  });

  group('Foreman', () {
    testWidgets('sees their own required training, with no authoring '
        'controls', (tester) async {
      await seed('v1', title: 'Ladder Safety');
      final service = _FakeService([
        readiness(beforeMeeting: [item('v1')]),
      ]);
      await pumpScreen(tester, wrap(role: AppRole.foreman, service: service));
      expect(service.readinessCalls, 1);
      expect(find.text('Needed today'), findsOneWidget);
      expect(find.text('Watch Video'), findsOneWidget);
      expect(find.text('Add video'), findsNothing);
      expect(find.text('Manage Quiz'), findsNothing);
    });
  });

  group('Workers and Foremen never get authoring controls', () {
    for (final role in [AppRole.foreman, AppRole.worker]) {
      for (final hasVideos in [true, false]) {
        testWidgets('${role.name} '
            '(${hasVideos ? 'with' : 'without'} videos)', (tester) async {
          if (hasVideos) await seed('v1');
          final admin = _FakeAdminService();
          await pumpScreen(
            tester,
            wrap(
              role: role,
              service: _FakeService([readiness()]),
              adminService: admin,
            ),
          );
          expect(find.text('Add video'), findsNothing);
          expect(find.text('Edit'), findsNothing);
          expect(find.text('Manage Quiz'), findsNothing);
          expect(find.byIcon(Icons.add), findsNothing);
          expect(find.text('Deactivate'), findsNothing);
          // Only the question counts are asked for — nothing that authors.
          expect(admin.created, isEmpty);
          expect(admin.updated, isEmpty);
          expect(admin.listedFor, isEmpty);
        });
      }
    }
  });

  group('management (Site Manager and Admin)', () {
    for (final role in [AppRole.siteManager, AppRole.admin]) {
      testWidgets('${role.name} gets the management view and never calls a '
          'learner function', (tester) async {
        await seed('v1', title: 'Ladder Safety');
        final service = _FakeService();
        await pumpScreen(tester, wrap(role: role, service: service));

        expect(find.text('Add video'), findsOneWidget);
        expect(find.text('Manage Quiz'), findsOneWidget);
        expect(find.text('Watch before today\'s meeting'), findsNothing);

        await tester.tap(find.text('Preview'));
        await tester.pumpAndSettle();
        expect(
          find.text(LearningDetailScreen.optionalWatchNote),
          findsOneWidget,
        );
        expect(find.text('Practice Quiz'), findsNothing);
        expect(service.calls, isEmpty);
      });
    }

    testWidgets('metrics, quiz counts and requirement use come from real '
        'data', (tester) async {
      await seed('v1', title: 'Ladder Safety');
      await seed('v2', title: 'Fire Safety', status: 'inactive');
      await seed('d1', title: 'PPE Handbook', type: 'document');
      await seedRequirement('r1', ['v1']);
      await seedRequirement('r2', ['v1', 'v2'], status: 'inactive');
      await pumpScreen(
        tester,
        wrap(
          role: AppRole.siteManager,
          adminService: _FakeAdminService(quizCounts: {'v1': 2, 'v2': 0}),
        ),
      );
      expect(find.text('2 videos'), findsOneWidget);
      expect(find.text('1 active'), findsOneWidget);
      expect(find.text('1 with a quiz'), findsOneWidget);
      expect(find.text('Quiz · 2 questions'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ManagedVideoCard),
          matching: find.text('No quiz'),
        ),
        findsOneWidget,
      );
      // Only ACTIVE requirements count; an inactive one never does.
      expect(find.text('Required by 1 requirement'), findsOneWidget);
      expect(
        find.text('General learning — not in any requirement'),
        findsOneWidget,
      );
      expect(find.text('PPE Handbook'), findsNothing);
    });

    testWidgets('search and filters narrow the list; Clear filters resets', (
      tester,
    ) async {
      await seed('v1', title: 'Ladder Safety', description: 'Three points');
      await seed('v2', title: 'Fire Safety', status: 'inactive');
      await pumpScreen(
        tester,
        wrap(
          role: AppRole.siteManager,
          adminService: _FakeAdminService(quizCounts: {'v1': 1, 'v2': 0}),
        ),
      );

      await tester.enterText(find.byType(TextField), 'points');
      await tester.pumpAndSettle();
      expect(find.text('Ladder Safety'), findsOneWidget);
      expect(find.text('Fire Safety'), findsNothing);

      await tester.enterText(find.byType(TextField), '');
      await tester.tap(find.widgetWithText(ChoiceChip, 'Inactive'));
      await tester.pumpAndSettle();
      expect(find.text('Ladder Safety'), findsNothing);
      expect(find.text('Fire Safety'), findsOneWidget);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Has quiz'));
      await tester.pumpAndSettle();
      expect(find.text('No videos match'), findsOneWidget);

      await tester.tap(find.text('Clear filters'));
      await tester.pumpAndSettle();
      expect(find.text('Ladder Safety'), findsOneWidget);
      expect(find.text('Fire Safety'), findsOneWidget);
    });

    testWidgets('if quiz counts fail, the card says Count unavailable (never '
        'zero), the quiz filter is hidden, and Try again reloads', (
      tester,
    ) async {
      await seed('v1', title: 'Ladder Safety');
      final admin = _FakeAdminService(quizCounts: {'v1': 3})
        ..quizCountsError = const NetworkException('offline');
      await pumpScreen(
        tester,
        wrap(role: AppRole.siteManager, adminService: admin),
      );
      expect(
        find.textContaining('Quiz counts are unavailable'),
        findsOneWidget,
      );
      expect(find.text('Count unavailable'), findsOneWidget);
      expect(find.text('No quiz'), findsNothing);
      expect(find.textContaining('with a quiz'), findsNothing);
      expect(find.widgetWithText(ChoiceChip, 'Has quiz'), findsNothing);

      admin.quizCountsError = null;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(admin.summaryCalls, 2);
      expect(find.text('Quiz · 3 questions'), findsOneWidget);
      expect(find.text('Count unavailable'), findsNothing);
    });

    group('quiz count on each card', () {
      Finder onCard(String text) => find.descendant(
        of: find.byType(ManagedVideoCard),
        matching: find.text(text),
      );

      testWidgets('zero, one and many confirmed questions', (tester) async {
        await seed('v1', title: 'A video');
        await seed('v2', title: 'B video');
        await seed('v3', title: 'C video');
        await pumpScreen(
          tester,
          wrap(
            role: AppRole.siteManager,
            adminService: _FakeAdminService(
              quizCounts: {'v1': 0, 'v2': 1, 'v3': 3},
            ),
          ),
        );
        expect(onCard('No quiz'), findsOneWidget);
        expect(onCard('Quiz · 1 question'), findsOneWidget);
        expect(onCard('Quiz · 3 questions'), findsOneWidget);
        expect(find.text('2 with a quiz'), findsOneWidget);
      });

      testWidgets('shows a loading state while counting, then the count', (
        tester,
      ) async {
        await seed('v1', title: 'Ladder Safety');
        final admin = _FakeAdminService(quizCounts: {'v1': 2})
          ..pendingCounts = Completer<void>();
        await pumpScreen(
          tester,
          wrap(role: AppRole.siteManager, adminService: admin),
          settle: false,
        );
        await tester.pump();
        expect(find.text('Counting quiz…'), findsOneWidget);
        expect(onCard('No quiz'), findsNothing);
        expect(find.text('Retry'), findsNothing);

        admin.pendingCounts!.complete();
        admin.pendingCounts = null;
        await tester.pumpAndSettle();
        expect(find.text('Counting quiz…'), findsNothing);
        expect(find.text('Quiz · 2 questions'), findsOneWidget);
      });

      testWidgets('a failure offers Retry on the card; retrying shows loading, '
          'not the old error', (tester) async {
        await seed('v1', title: 'Ladder Safety');
        final admin = _FakeAdminService(quizCounts: {'v1': 1})
          ..quizCountsError = const NetworkException('No connection.');
        await pumpScreen(
          tester,
          wrap(role: AppRole.siteManager, adminService: admin),
        );
        expect(onCard('Count unavailable'), findsOneWidget);
        expect(onCard('No connection.'), findsOneWidget);

        admin
          ..quizCountsError = null
          ..pendingCounts = Completer<void>();
        await tester.tap(find.text('Retry'));
        await tester.pump();
        expect(find.text('Counting quiz…'), findsOneWidget);
        expect(find.text('Count unavailable'), findsNothing);

        admin.pendingCounts!.complete();
        admin.pendingCounts = null;
        await tester.pumpAndSettle();
        expect(admin.summaryCalls, 2);
        expect(onCard('Quiz · 1 question'), findsOneWidget);
        expect(find.text('Retry'), findsNothing);
      });

      testWidgets('a server without the counting function says it needs the '
          'update — distinct from a network failure', (tester) async {
        await seed('v1', title: 'Ladder Safety');
        final admin = _FakeAdminService()
          ..quizCountsError = const ServerUpdateRequiredException(
            'Quiz counts needs the latest server update.',
          );
        await pumpScreen(
          tester,
          wrap(role: AppRole.siteManager, adminService: admin),
        );
        expect(onCard('Quiz count: server update needed'), findsOneWidget);
        expect(onCard('Count unavailable'), findsNothing);
        expect(
          find.textContaining('needs the latest server update'),
          findsWidgets,
        );
        expect(find.text('Retry'), findsOneWidget);
        expect(find.text('Manage Quiz'), findsOneWidget);
      });

      testWidgets('a video left out of a successful answer says Count missing '
          '— never No quiz — and Retry recounts it', (tester) async {
        await seed('v1', title: 'A video');
        await seed('v2', title: 'B video');
        final admin = _FakeAdminService(quizCounts: {'v1': 2});
        await pumpScreen(
          tester,
          wrap(role: AppRole.siteManager, adminService: admin),
        );
        expect(onCard('Quiz · 2 questions'), findsOneWidget);
        expect(onCard('Count missing'), findsOneWidget);
        expect(onCard('No quiz'), findsNothing);
        // No partial total while a count is missing.
        expect(find.textContaining('with a quiz'), findsNothing);

        admin.quizCounts = {'v1': 2, 'v2': 0};
        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(onCard('Count missing'), findsNothing);
        expect(onCard('No quiz'), findsOneWidget);
        expect(find.text('1 with a quiz'), findsOneWidget);
      });

      testWidgets('returning from Manage Quiz refreshes the saved count', (
        tester,
      ) async {
        await seed('v1', title: 'Ladder Safety');
        final admin = _FakeAdminService(quizCounts: {'v1': 0});
        await pumpScreen(
          tester,
          wrap(role: AppRole.siteManager, adminService: admin),
        );
        expect(onCard('No quiz'), findsOneWidget);

        await tester.tap(find.text('Manage Quiz'));
        await tester.pumpAndSettle();
        expect(find.byType(KnowledgeCheckQuestionsScreen), findsOneWidget);
        // A question was saved while the editor was open.
        admin.quizCounts = {'v1': 1};
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(admin.summaryCalls, 2);
        expect(onCard('Quiz · 1 question'), findsOneWidget);
      });
    });

    testWidgets('Add video opens the form locked to Video and saves a video '
        'that is not made required', (tester) async {
      final admin = _FakeAdminService();
      await pumpScreen(
        tester,
        wrap(role: AppRole.siteManager, adminService: admin),
      );
      await tester.tap(find.text('Add video').first);
      await tester.pumpAndSettle();
      expect(find.text('NEW VIDEO'), findsOneWidget);
      expect(find.text('Document'), findsNothing);
      expect(find.textContaining('Save the video first'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Title'),
        'Safety Videos — YouTube Test',
      );
      await tester.tap(find.text('Link to an external video'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Video link'),
        youtubeTestUrl,
      );
      await tester.pumpAndSettle();
      expect(find.text('External · YouTube'), findsWidgets);
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(admin.created, hasLength(1));
      expect(admin.created.single.type, SafetyLearningType.video);
      expect(admin.created.single.contentReference, youtubeTestUrl);
      expect(admin.created.single.status, OrganizationRecordStatus.active);
      expect(find.text('NEW VIDEO'), findsNothing);
      // Quiz counts are refreshed after authoring.
      expect(admin.summaryCalls, 2);
    });

    testWidgets('an arbitrary web page is still refused as a video link', (
      tester,
    ) async {
      final admin = _FakeAdminService();
      await pumpScreen(
        tester,
        wrap(role: AppRole.siteManager, adminService: admin),
      );
      await tester.tap(find.text('Add video').first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Title'),
        'OSHA library',
      );
      await tester.tap(find.text('Link to an external video'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Video link'),
        'https://www.osha.gov/video',
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Only YouTube, Vimeo'), findsOneWidget);
      expect(admin.created, isEmpty);
    });

    testWidgets('a failed save keeps the form and what was typed', (
      tester,
    ) async {
      final admin = _FakeAdminService()
        ..nextError = const PermissionDeniedException(
          'You do not have permission to manage this learning item.',
        );
      await pumpScreen(
        tester,
        wrap(role: AppRole.siteManager, adminService: admin),
      );
      await tester.tap(find.text('Add video').first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Title'),
        'Ladder Safety',
      );
      await tester.tap(find.text('Link to an external video'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Video link'),
        youtubeTestUrl,
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(
        find.text('You do not have permission to manage this learning item.'),
        findsOneWidget,
      );
      expect(find.text('NEW VIDEO'), findsOneWidget);
      expect(find.text(youtubeTestUrl), findsOneWidget);
      expect(admin.created, isEmpty);
    });

    testWidgets('Edit deactivates a video someone else created', (
      tester,
    ) async {
      await seed('v1', title: 'Ladder Safety');
      final admin = _FakeAdminService();
      await pumpScreen(
        tester,
        wrap(role: AppRole.siteManager, adminService: admin),
      );
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(find.text('EDIT VIDEO'), findsOneWidget);
      expect(find.text('Manage Quiz'), findsWidgets);
      await tester.tap(find.text('Inactive').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(admin.updated.single.$1, 'v1');
      expect(admin.updated.single.$2, OrganizationRecordStatus.inactive);
      expect(find.text('EDIT VIDEO'), findsNothing);
    });

    testWidgets('Manage Quiz opens the questions screen; back returns', (
      tester,
    ) async {
      await seed('v1', title: 'Ladder Safety');
      final admin = _FakeAdminService();
      await pumpScreen(
        tester,
        wrap(role: AppRole.siteManager, adminService: admin),
      );
      await tester.tap(find.text('Manage Quiz'));
      await tester.pumpAndSettle();
      expect(find.byType(KnowledgeCheckQuestionsScreen), findsOneWidget);
      expect(admin.listedFor, ['v1']);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(KnowledgeCheckQuestionsScreen), findsNothing);
      expect(find.text('Ladder Safety'), findsOneWidget);
    });
  });

  group('navigation', () {
    testWidgets('a double tap on a learner card opens the lesson once, and '
        'back returns to the list', (tester) async {
      await seed('v1', title: 'Ladder Safety');
      await pumpScreen(
        tester,
        wrap(role: AppRole.worker, service: _FakeService([readiness()])),
      );

      await tester.tap(find.text('Ladder Safety'));
      await tester.tap(find.text('Ladder Safety'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.byType(LearningDetailScreen), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(LearningDetailScreen), findsNothing);
      expect(find.text('Ladder Safety'), findsOneWidget);
    });

    testWidgets('a double tap on Preview opens one lesson', (tester) async {
      await seed('v1', title: 'Ladder Safety');
      await pumpScreen(tester, wrap(role: AppRole.siteManager));
      await tester.tap(find.text('Preview'));
      await tester.tap(find.text('Preview'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.byType(LearningDetailScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(LearningDetailScreen), findsNothing);
    });

    testWidgets('a double tap on Add video opens one form; Cancel returns', (
      tester,
    ) async {
      await pumpScreen(tester, wrap(role: AppRole.siteManager));
      await tester.tap(find.text('Add video').first);
      await tester.tap(find.text('Add video').first, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('NEW VIDEO'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('NEW VIDEO'), findsNothing);
      expect(find.text('Add video'), findsWidgets);
    });

    testWidgets('opening a YouTube lesson launches YouTube once; coming back '
        'leaves the app usable', (tester) async {
      await seed(
        'yt',
        title: 'Safety Videos — YouTube Test',
        contentReference: youtubeTestUrl,
      );
      await seed('v2', title: 'Fire Safety');
      final launched = <Uri>[];
      // A real launch hands off to the platform and takes a moment; hold
      // each one open until released.
      var handOff = Completer<bool>();
      await pumpScreen(
        tester,
        wrap(
          role: AppRole.worker,
          service: _FakeService([readiness()]),
          launcher: (uri) {
            launched.add(uri);
            return handOff.future;
          },
        ),
      );
      await tester.tap(find.text('Safety Videos — YouTube Test'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Watch on YouTube'));
      await tester.pump();
      await tester.tap(find.text('Watch on YouTube'));
      await tester.pump();
      expect(launched, [Uri.parse(youtubeTestUrl)]);
      handOff.complete(true);
      await tester.pumpAndSettle();
      expect(find.text('Could not open this link.'), findsNothing);

      // "Returning" from YouTube: the lesson is still there and usable…
      handOff = Completer<bool>()..complete(true);
      await tester.tap(find.text('Watch on YouTube'));
      await tester.pumpAndSettle();
      expect(launched, hasLength(2));
      // …and back leads to the list, which still opens other videos.
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fire Safety'));
      await tester.pumpAndSettle();
      expect(find.byType(LearningDetailScreen), findsOneWidget);
    });

    testWidgets('a YouTube launch that fails or throws says so', (
      tester,
    ) async {
      await seed('yt', title: 'YouTube Test', contentReference: youtubeTestUrl);
      var attempt = 0;
      await pumpScreen(
        tester,
        wrap(
          role: AppRole.siteManager,
          launcher: (uri) async {
            attempt++;
            if (attempt == 1) return false;
            throw Exception('no browser');
          },
        ),
      );
      await tester.tap(find.text('Preview'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.text('Watch on YouTube'));
        await tester.pumpAndSettle();
        expect(find.text('Could not open this link.'), findsOneWidget);
      }
    });
  });

  group('requirement labels wait for the person\'s records', () {
    testWidgets('no labels until records load, then a completed required '
        'video shows as Done — never Optional', (tester) async {
      await seed('v1', title: 'Ladder Safety');
      final records = _ControlledRecordRepository(firestoreService);
      addTearDown(records.controller.close);
      await pumpScreen(
        tester,
        wrap(
          role: AppRole.worker,
          // Readiness lists only incomplete items, so a completed required
          // video is absent from it.
          service: _FakeService([readiness()]),
          recordRepository: records,
        ),
        settle: false,
      );
      expect(records.subscriptions, 1);
      expect(find.text('Checking what you need…'), findsOneWidget);
      expect(find.text('Optional'), findsNothing);
      expect(find.text('Ladder Safety'), findsNothing);

      records.controller.add([
        const WorkerLearningRecord(
          id: 'worker-1_v1',
          workerUid: 'worker-1',
          organizationId: _org,
          learningId: 'v1',
          status: WorkerLearningStatus.completed,
        ),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('Done'), findsOneWidget);
      expect(find.text('Optional'), findsNothing);
    });

    testWidgets('a records failure shows videos without labels, and Try '
        'again reloads readiness and records', (tester) async {
      await seed('v1', title: 'Ladder Safety');
      final records = _ControlledRecordRepository(firestoreService)
        ..fail = true;
      addTearDown(records.controller.close);
      final service = _FakeService([
        readiness(beforeWork: [item('v1')]),
      ]);
      await pumpScreen(
        tester,
        wrap(role: AppRole.worker, service: service, recordRepository: records),
      );
      expect(
        find.textContaining('Couldn\'t check which videos'),
        findsOneWidget,
      );
      expect(find.text('Ladder Safety'), findsOneWidget);
      expect(find.text('Optional'), findsNothing);
      expect(badge('Required'), findsNothing);

      records
        ..fail = false
        ..ready = const [];
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(service.readinessCalls, 2);
      expect(records.subscriptions, 2);
      expect(badge('Required'), findsOneWidget);
    });
  });

  group('sources', () {
    testWidgets('each card shows its source label', (tester) async {
      await seed('a', contentReference: jvaUrl('clip.mp4'));
      await seed('b', contentReference: 'https://youtu.be/dQw4w9WgXcQ');
      await seed('c', contentReference: 'https://vimeo.com/76979871');
      await seed('d', contentReference: 'https://www.example.org/clip.webm');
      await pumpScreen(
        tester,
        wrap(role: AppRole.worker, service: _FakeService([readiness()])),
      );
      expect(find.text('JVA video'), findsOneWidget);
      expect(find.text('External · YouTube'), findsOneWidget);
      expect(find.text('External · Vimeo'), findsOneWidget);
      expect(find.text('External · example.org'), findsOneWidget);
    });

    testWidgets('a worker sees an unusable link as Video unavailable and '
        'cannot open it', (tester) async {
      await seed('bad', title: 'Broken', contentReference: 'not a link');
      await pumpScreen(
        tester,
        wrap(role: AppRole.worker, service: _FakeService([readiness()])),
      );
      expect(find.text('Video unavailable'), findsOneWidget);
      expect(find.text('Link problem'), findsNothing);
      await tester.tap(find.text('Broken'));
      await tester.pumpAndSettle();
      expect(find.byType(LearningDetailScreen), findsNothing);
    });

    testWidgets('an author sees Link problem, and Preview is disabled', (
      tester,
    ) async {
      await seed('bad', contentReference: 'https://example.org/page');
      await pumpScreen(tester, wrap(role: AppRole.admin));
      expect(find.text('Link problem'), findsOneWidget);
      expect(find.text('Video unavailable'), findsNothing);
      final open = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('Preview'),
          matching: find.byWidgetPredicate((w) => w is OutlinedButton),
        ),
      );
      expect(open.onPressed, isNull);
    });

    testWidgets('minimum watch time is described as a minimum', (tester) async {
      await seed('v1', minimumWatchSeconds: 150);
      await pumpScreen(
        tester,
        wrap(role: AppRole.worker, service: _FakeService([readiness()])),
      );
      expect(find.text('Keep open at least 3 min'), findsOneWidget);
    });
  });

  group('empty and error states', () {
    testWidgets('a learner with no active videos', (tester) async {
      await seed('old', status: 'inactive');
      await pumpScreen(
        tester,
        wrap(role: AppRole.worker, service: _FakeService([readiness()])),
      );
      expect(find.text('No safety videos yet'), findsOneWidget);
      expect(
        find.text('Your safety team will add videos here.'),
        findsOneWidget,
      );
    });

    testWidgets('an author with no videos is offered Add video', (
      tester,
    ) async {
      await pumpScreen(tester, wrap(role: AppRole.siteManager));
      expect(find.text('No safety videos yet'), findsOneWidget);
      expect(find.text('Add video'), findsNWidgets(2));
    });

    testWidgets('a video list failure offers Try again', (tester) async {
      final repository = _FailingLearningRepository(firestoreService);
      await pumpScreen(
        tester,
        wrap(role: AppRole.siteManager, learningRepository: repository),
      );
      expect(
        find.text('Couldn\'t load safety videos. Please try again.'),
        findsOneWidget,
      );
      expect(find.text('No safety videos yet'), findsNothing);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(repository.attempts, 2);
    });

    testWidgets('no active organization', (tester) async {
      await tester.pumpWidget(
        ChangeNotifierProvider<SessionController>(
          create: (_) =>
              _FakeSession(role: AppRole.worker, organizationId: null),
          child: const MaterialApp(
            home: Scaffold(body: SafetyVideosScreen(storageBucket: _bucket)),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.text('Your account is not yet assigned to an organization.'),
        findsOneWidget,
      );
    });

    for (final role in [AppRole.worker, AppRole.siteManager]) {
      testWidgets('fits a 360px phone without overflow (${role.name})', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(360 * 3, 780 * 3);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        await seed('v1', title: 'A very long safety video title that wraps');
        await seed(
          'v2',
          contentReference:
              'https://a-very-long-domain-name-for-testing.example.org/clip.mp4',
        );
        await pumpScreen(
          tester,
          wrap(
            role: role,
            service: _FakeService([
              readiness(
                beforeMeeting: [
                  item('v1', questionCount: 2, quizRequired: true),
                ],
              ),
            ]),
            adminService: _FakeAdminService(quizCounts: {'v1': 2}),
          ),
        );
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('one library, two entry points', () {
    testWidgets('Safety Learning and Safety Videos open the same learning '
        'item and record in the same lesson screen', (tester) async {
      await seed('v1', title: 'Ladder Safety');
      await seedRecord('v1', 'inProgress');
      final service = _FakeService([
        readiness(beforeMeeting: [item('v1')]),
      ]);

      // From Safety Learning (Today's Safety Readiness).
      tester.view.physicalSize = const Size(420, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: TodaysSafetyReadinessScreen(
            organizationId: _org,
            workerUid: 'worker-1',
            workerLearningService: service,
            workerLearningRepository: WorkerLearningRepository(
              firestoreService: firestoreService,
              organizationId: _org,
            ),
            safetyLearningRepository: SafetyLearningRepository(
              firestoreService: firestoreService,
              organizationId: _org,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('v1').first);
      await tester.pumpAndSettle();
      final fromLearning = tester.widget<LearningDetailScreen>(
        find.byType(LearningDetailScreen),
      );

      // From Safety Videos.
      await pumpScreen(tester, wrap(role: AppRole.worker, service: service));
      await tester.tap(find.text('Ladder Safety'));
      await tester.pumpAndSettle();
      final fromVideos = tester.widget<LearningDetailScreen>(
        find.byType(LearningDetailScreen),
      );

      expect(fromVideos.learning.id, fromLearning.learning.id);
      expect(
        fromVideos.learning.contentReference,
        fromLearning.learning.contentReference,
      );
      expect(fromVideos.record?.id, fromLearning.record?.id);
      expect(fromVideos.record?.status, WorkerLearningStatus.inProgress);
      expect(fromVideos.watchOnly, isFalse);
      expect(fromLearning.watchOnly, isFalse);
    });
  });

  group('general learning library (no Safety Requirement)', () {
    for (final role in [AppRole.worker, AppRole.foreman]) {
      testWidgets('${role.name}: an active video with no requirement is '
          'listed as General learning, with Watch Video and its real quiz '
          'count', (tester) async {
        await seed(
          'v1',
          title: 'Working at Height',
          description: 'Harness checks for a future project',
        );
        await pumpScreen(
          tester,
          wrap(
            role: role,
            service: _FakeService([readiness()]),
            adminService: _FakeAdminService(quizCounts: {'v1': 2}),
          ),
        );
        expect(find.text('Working at Height'), findsOneWidget);
        expect(badge('General learning'), findsOneWidget);
        expect(badge('Required'), findsNothing);
        expect(find.text('Quiz · 2 questions'), findsOneWidget);
        expect(find.text('Watch Video'), findsOneWidget);
      });
    }

    testWidgets('having a quiz never makes a video Required', (tester) async {
      await seed('v1', title: 'Fire Safety');
      await pumpScreen(
        tester,
        wrap(
          role: AppRole.worker,
          service: _FakeService([readiness()]),
          adminService: _FakeAdminService(quizCounts: {'v1': 5}),
        ),
      );
      expect(badge('General learning'), findsOneWidget);
      expect(badge('Required'), findsNothing);
      expect(find.text('Quiz required'), findsNothing);
    });

    testWidgets('quiz counts that fail to load show no quiz badge — never a '
        'wrong "no quiz"', (tester) async {
      await seed('v1', title: 'Fire Safety');
      final admin = _FakeAdminService()
        ..quizCountsError = const NetworkException('offline');
      await pumpScreen(
        tester,
        wrap(
          role: AppRole.worker,
          service: _FakeService([readiness()]),
          adminService: admin,
        ),
      );
      expect(find.textContaining('Quiz ·'), findsNothing);
      expect(find.text('No quiz'), findsNothing);
      expect(find.text('Fire Safety'), findsOneWidget);
    });

    testWidgets('a required video shows Required; the same library also '
        'lists the general one', (tester) async {
      await seed('req', title: 'Ladder Safety');
      await seed('gen', title: 'Fire Safety');
      await pumpScreen(
        tester,
        wrap(
          role: AppRole.worker,
          service: _FakeService([
            readiness(beforeWork: [item('req')]),
          ]),
        ),
      );
      expect(badge('Required'), findsOneWidget);
      expect(badge('General learning'), findsOneWidget);
    });

    testWidgets('deactivating a video removes it from the learner library '
        'live; reactivating brings it back', (tester) async {
      await seed('v1', title: 'Fire Safety');
      await pumpScreen(
        tester,
        wrap(role: AppRole.worker, service: _FakeService([readiness()])),
      );
      expect(find.text('Fire Safety'), findsOneWidget);

      await firestore.doc('organizations/$_org/safety_learning/v1').update({
        'status': 'inactive',
      });
      await tester.pumpAndSettle();
      expect(find.text('Fire Safety'), findsNothing);

      await firestore.doc('organizations/$_org/safety_learning/v1').update({
        'status': 'active',
      });
      await tester.pumpAndSettle();
      expect(find.text('Fire Safety'), findsOneWidget);
    });

    testWidgets('opening a general video passes the SAME library item (same '
        'id) to the shared lesson screen', (tester) async {
      await seed('v1', title: 'Fire Safety');
      await pumpScreen(
        tester,
        wrap(role: AppRole.worker, service: _FakeService([readiness()])),
      );
      await tester.tap(find.text('Watch Video'));
      await tester.pumpAndSettle();
      final lesson = tester.widget<LearningDetailScreen>(
        find.byType(LearningDetailScreen),
      );
      expect(lesson.learning.id, 'v1');
      expect(lesson.watchOnly, isTrue);
      expect(lesson.allowPracticeQuiz, isTrue);
    });

    group('search', () {
      Future<void> pumpTwo(WidgetTester tester) async {
        await seed(
          'v1',
          title: 'Ladder Safety',
          description: 'Three points of contact',
        );
        await seed('v2', title: 'Fire Safety');
        await pumpScreen(
          tester,
          wrap(
            role: AppRole.worker,
            service: _FakeService([
              readiness(beforeWork: [item('v1')]),
            ]),
          ),
        );
      }

      testWidgets('narrows every section by title or description', (
        tester,
      ) async {
        await pumpTwo(tester);
        await tester.enterText(find.byType(TextField), 'contact');
        await tester.pumpAndSettle();
        expect(find.text('Ladder Safety'), findsOneWidget);
        expect(find.text('Fire Safety'), findsNothing);

        await tester.enterText(find.byType(TextField), 'fire');
        await tester.pumpAndSettle();
        expect(find.text('Ladder Safety'), findsNothing);
        expect(find.text('Fire Safety'), findsOneWidget);
      });

      testWidgets('no match says so, and Clear search brings everything '
          'back', (tester) async {
        await pumpTwo(tester);
        await tester.enterText(find.byType(TextField), 'scaffold');
        await tester.pumpAndSettle();
        expect(find.text('No videos match'), findsOneWidget);
        await tester.tap(find.text('Clear search'));
        await tester.pumpAndSettle();
        expect(find.text('Ladder Safety'), findsOneWidget);
        expect(find.text('Fire Safety'), findsOneWidget);
      });
    });

    testWidgets('a YouTube video shows its thumbnail; other sources keep '
        'the play tile', (tester) async {
      await seed('yt', title: 'From YouTube', contentReference: youtubeTestUrl);
      await seed('file', title: 'A file');
      await pumpScreen(
        tester,
        wrap(role: AppRole.worker, service: _FakeService([readiness()])),
      );
      final images = tester
          .widgetList<Image>(find.byType(Image))
          .map((image) => image.image)
          .whereType<NetworkImage>()
          .map((image) => image.url)
          .toList();
      expect(images, ['https://i.ytimg.com/vi/jfKfPfyJRdk/hqdefault.jpg']);
    });

    for (final width in [360.0, 768.0, 1280.0]) {
      testWidgets('the learner library fits ${width.toInt()}px', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 2400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await seed(
          'v1',
          title: 'A long video title about working safely on scaffolds',
          contentReference: youtubeTestUrl,
        );
        await seed('v2', title: 'Fire Safety');
        await pumpScreen(
          tester,
          wrap(
            role: AppRole.worker,
            service: _FakeService([
              readiness(beforeWork: [item('v1', questionCount: 2)]),
            ]),
            adminService: _FakeAdminService(quizCounts: {'v2': 1}),
          ),
        );
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('manager: activate and deactivate', () {
    Future<_FakeAdminService> pumpManager(
      WidgetTester tester, {
      String status = 'active',
    }) async {
      await seed('v1', title: 'Ladder Safety', status: status);
      final admin = _FakeAdminService(quizCounts: {'v1': 0});
      await pumpScreen(
        tester,
        wrap(role: AppRole.siteManager, adminService: admin),
      );
      return admin;
    }

    testWidgets('Deactivate asks first; Cancel changes nothing', (
      tester,
    ) async {
      final admin = await pumpManager(tester);
      await openMore(tester);
      await tester.tap(find.text('Deactivate'));
      await tester.pumpAndSettle();
      expect(find.text('Deactivate this video?'), findsOneWidget);
      expect(find.textContaining('Completion records'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(admin.updated, isEmpty);
    });

    testWidgets('confirming saves the same item as inactive, once', (
      tester,
    ) async {
      final admin = await pumpManager(tester);
      await openMore(tester);
      await tester.tap(find.text('Deactivate'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Deactivate'));
      await tester.pumpAndSettle();
      expect(admin.updated, [('v1', OrganizationRecordStatus.inactive)]);
      expect(admin.created, isEmpty);
    });

    testWidgets('an inactive video offers Activate', (tester) async {
      final admin = await pumpManager(tester, status: 'inactive');
      await openMore(tester);
      await tester.tap(find.text('Activate'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Activate'));
      await tester.pumpAndSettle();
      expect(admin.updated, [('v1', OrganizationRecordStatus.active)]);
    });

    testWidgets('refused while an ACTIVE requirement lists the video — it '
        'names the requirement and nothing is saved', (tester) async {
      await seedRequirement('r1', ['v1']);
      final admin = await pumpManager(tester);
      await openMore(tester);
      await tester.tap(find.text('Deactivate'));
      await tester.pumpAndSettle();
      expect(find.text('Can\'t deactivate this video'), findsOneWidget);
      expect(find.textContaining('Requirement r1'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(admin.updated, isEmpty);
    });

    testWidgets('an INACTIVE requirement does not block it', (tester) async {
      await seedRequirement('r1', ['v1'], status: 'inactive');
      final admin = await pumpManager(tester);
      await openMore(tester);
      await tester.tap(find.text('Deactivate'));
      await tester.pumpAndSettle();
      expect(find.text('Deactivate this video?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Deactivate'));
      await tester.pumpAndSettle();
      expect(admin.updated, [('v1', OrganizationRecordStatus.inactive)]);
    });

    testWidgets('if requirements can\'t be checked, deactivating is not '
        'tried', (tester) async {
      await seed('v1', title: 'Ladder Safety');
      final admin = _FakeAdminService(quizCounts: {'v1': 0});
      await pumpScreen(
        tester,
        wrap(
          role: AppRole.siteManager,
          adminService: admin,
          requirementRepository: _FailingRequirementRepository(
            firestoreService,
          ),
        ),
      );
      await openMore(tester);
      await tester.tap(find.text('Deactivate'));
      await tester.pumpAndSettle();
      expect(find.textContaining('couldn\'t check'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(admin.updated, isEmpty);
    });

    testWidgets('the server\'s own refusal is shown too', (tester) async {
      final admin = await pumpManager(tester);
      admin.nextError = const DataException(
        'This video is required by active Safety Requirements: Height.',
      );
      await openMore(tester);
      await tester.tap(find.text('Deactivate'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Deactivate'));
      await tester.pumpAndSettle();
      expect(find.textContaining('required by active Safety'), findsOneWidget);
    });

    testWidgets('a failed save is shown, not hidden', (tester) async {
      final admin = await pumpManager(tester);
      admin.nextError = const NetworkException('No connection.');
      await openMore(tester);
      await tester.tap(find.text('Deactivate'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Deactivate'));
      await tester.pumpAndSettle();
      expect(find.text('No connection.'), findsOneWidget);
    });
  });

  group('learner filters', () {
    Future<void> pumpMixed(WidgetTester tester, {List<Object>? results}) async {
      await seed('req', title: 'Ladder Safety');
      await seed('gen', title: 'Fire Safety');
      await pumpScreen(
        tester,
        wrap(
          role: AppRole.worker,
          service: _FakeService(
            results ??
                [
                  readiness(beforeWork: [item('req')]),
                ],
          ),
        ),
      );
    }

    Finder chip(String label) => find.widgetWithText(ChoiceChip, label);

    testWidgets('Required shows only required videos; General learning '
        'only the others; All both', (tester) async {
      await pumpMixed(tester);
      await tester.tap(chip('Required'));
      await tester.pumpAndSettle();
      expect(find.text('Ladder Safety'), findsOneWidget);
      expect(find.text('Fire Safety'), findsNothing);

      await tester.tap(chip('General learning'));
      await tester.pumpAndSettle();
      expect(find.text('Ladder Safety'), findsNothing);
      expect(find.text('Fire Safety'), findsOneWidget);
      expect(find.text('Watch before today\'s meeting'), findsNothing);

      await tester.tap(chip('All'));
      await tester.pumpAndSettle();
      expect(find.text('Ladder Safety'), findsOneWidget);
      expect(find.text('Fire Safety'), findsOneWidget);
    });

    testWidgets('a filter with nothing in it says so, with Show all', (
      tester,
    ) async {
      await seed('gen', title: 'Fire Safety');
      await pumpScreen(
        tester,
        wrap(role: AppRole.worker, service: _FakeService([readiness()])),
      );
      await tester.tap(chip('Required'));
      await tester.pumpAndSettle();
      expect(find.text('No required videos'), findsOneWidget);
      await tester.tap(find.text('Show all'));
      await tester.pumpAndSettle();
      expect(find.text('Fire Safety'), findsOneWidget);
    });

    testWidgets('no filter is offered while requirement status is unknown', (
      tester,
    ) async {
      await pumpMixed(tester, results: [const NetworkException('offline')]);
      expect(chip('Required'), findsNothing);
      expect(find.text('Ladder Safety'), findsOneWidget);
      expect(find.text('Fire Safety'), findsOneWidget);
    });

    testWidgets('learners get no management actions at all', (tester) async {
      await pumpMixed(tester);
      expect(find.byTooltip('More actions'), findsNothing);
      expect(find.text('Delete'), findsNothing);
      expect(find.text('Edit'), findsNothing);
      expect(find.text('Preview'), findsNothing);
    });
  });

  group('manager layout', () {
    testWidgets('Edit is the primary action; Preview and Manage Quiz are '
        'secondary; Deactivate and Delete sit under More actions', (
      tester,
    ) async {
      await seed('v1', title: 'Ladder Safety');
      await pumpScreen(tester, wrap(role: AppRole.siteManager));
      expect(find.widgetWithText(FilledButton, 'Edit'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Preview'), findsOneWidget);
      expect(
        find.widgetWithText(OutlinedButton, 'Manage Quiz'),
        findsOneWidget,
      );
      expect(find.text('Delete'), findsNothing);
      await openMore(tester);
      expect(find.text('Deactivate'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
    });

    testWidgets('the Requirement filter uses real requirement data', (
      tester,
    ) async {
      await seed('req', title: 'Ladder Safety');
      await seed('gen', title: 'Fire Safety');
      await seedRequirement('r1', ['req']);
      await pumpScreen(tester, wrap(role: AppRole.siteManager));
      await tester.tap(find.widgetWithText(ChoiceChip, 'Required'));
      await tester.pumpAndSettle();
      expect(find.text('Ladder Safety'), findsOneWidget);
      expect(find.text('Fire Safety'), findsNothing);
      await tester.tap(find.widgetWithText(ChoiceChip, 'General learning'));
      await tester.pumpAndSettle();
      expect(find.text('Ladder Safety'), findsNothing);
      expect(find.text('Fire Safety'), findsOneWidget);
    });

    testWidgets('the Requirement filter is hidden when requirements fail to '
        'load', (tester) async {
      await seed('v1', title: 'Ladder Safety');
      await pumpScreen(
        tester,
        wrap(
          role: AppRole.siteManager,
          requirementRepository: _FailingRequirementRepository(
            firestoreService,
          ),
        ),
      );
      expect(find.widgetWithText(ChoiceChip, 'General learning'), findsNothing);
      expect(find.text('Ladder Safety'), findsOneWidget);
    });

    for (final width in [360.0, 768.0, 1280.0]) {
      testWidgets('fits ${width.toInt()}px, menu included', (tester) async {
        tester.view.physicalSize = Size(width, 2400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await seed(
          'v1',
          title: 'A long video title about working safely on scaffolds',
          contentReference: youtubeTestUrl,
          description: 'Harness, anchor points and rescue plans.',
        );
        await seed('v2', title: 'Fire Safety', status: 'inactive');
        await seedRequirement('r1', ['v1']);
        await pumpScreen(
          tester,
          wrap(
            role: AppRole.siteManager,
            adminService: _FakeAdminService(quizCounts: {'v1': 3, 'v2': 0}),
          ),
        );
        expect(tester.takeException(), isNull);
        await openMore(tester);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('manager: delete', () {
    Future<_FakeAdminService> pumpOne(WidgetTester tester) async {
      await seed('v1', title: 'Ladder Safety');
      final admin = _FakeAdminService(quizCounts: {'v1': 0});
      await pumpScreen(
        tester,
        wrap(role: AppRole.siteManager, adminService: admin),
      );
      return admin;
    }

    Future<void> chooseDelete(WidgetTester tester) async {
      await openMore(tester);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
    }

    testWidgets('the confirmation names the video; Cancel deletes nothing', (
      tester,
    ) async {
      final admin = await pumpOne(tester);
      await chooseDelete(tester);
      expect(find.text('Delete this video permanently?'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Ladder Safety'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(admin.deleted, isEmpty);
    });

    testWidgets('confirming deletes that same item once, and says so', (
      tester,
    ) async {
      final admin = await pumpOne(tester);
      await chooseDelete(tester);
      await tester.tap(find.text('Delete permanently'));
      await tester.pumpAndSettle();
      expect(admin.deleted, ['v1']);
      expect(find.text('Deleted "Ladder Safety".'), findsOneWidget);
    });

    testWidgets('while deleting, the actions are locked — no second '
        'request', (tester) async {
      final admin = await pumpOne(tester);
      admin.pendingDelete = Completer<void>();
      await chooseDelete(tester);
      await tester.tap(find.text('Delete permanently'));
      await tester.pump();
      final menu = tester.widget<PopupMenuButton<String>>(
        find.byType(PopupMenuButton<String>),
      );
      expect(menu.enabled, isFalse);
      admin.pendingDelete!.complete();
      admin.pendingDelete = null;
      await tester.pumpAndSettle();
      expect(admin.deleted, ['v1']);
    });

    testWidgets('a refusal (records or requirements) shows the server\'s '
        'reason', (tester) async {
      final admin = await pumpOne(tester);
      admin.nextError = const DataException(
        'Learners already have training records for this item, so it '
        'can\'t be deleted — deactivate it instead to keep their history.',
      );
      await chooseDelete(tester);
      await tester.tap(find.text('Delete permanently'));
      await tester.pumpAndSettle();
      expect(find.textContaining('deactivate it instead'), findsOneWidget);
    });

    testWidgets('an inconclusive check says nothing was deleted', (
      tester,
    ) async {
      final admin = await pumpOne(tester);
      admin.nextError = const NetworkException('Network error.');
      await chooseDelete(tester);
      await tester.tap(find.text('Delete permanently'));
      await tester.pumpAndSettle();
      expect(find.textContaining('so nothing was deleted'), findsOneWidget);
    });
  });

  group('manager: a deletion that did not finish', () {
    Future<_FakeAdminService> pumpPending(WidgetTester tester) async {
      await seed('v1', title: 'Ladder Safety', status: 'inactive');
      await firestore.doc('organizations/$_org/safety_learning/v1').update({
        'deletion': {'pending': true, 'previousStatus': 'active'},
      });
      final admin = _FakeAdminService(quizCounts: {'v1': 0});
      await pumpScreen(
        tester,
        wrap(role: AppRole.siteManager, adminService: admin),
      );
      return admin;
    }

    testWidgets('is shown as such; Edit is locked; only Finish deleting is '
        'offered', (tester) async {
      await pumpPending(tester);
      expect(find.text('Deletion not finished'), findsOneWidget);
      final edit = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Edit'),
      );
      expect(edit.onPressed, isNull);
      await openMore(tester);
      expect(find.text('Finish deleting'), findsOneWidget);
      expect(find.text('Activate'), findsNothing);
      expect(find.text('Deactivate'), findsNothing);
    });

    testWidgets('Finish deleting asks first, then deletes that same item', (
      tester,
    ) async {
      final admin = await pumpPending(tester);
      await openMore(tester);
      await tester.tap(find.text('Finish deleting'));
      await tester.pumpAndSettle();
      expect(find.text('Delete this video permanently?'), findsOneWidget);
      await tester.tap(find.text('Delete permanently'));
      await tester.pumpAndSettle();
      expect(admin.deleted, ['v1']);
    });

    testWidgets('a part-way failure is reported as part-way — never as '
        'deleted', (tester) async {
      await seed('v2', title: 'Fire Safety');
      final admin = _FakeAdminService(quizCounts: {'v2': 0})
        ..nextError = const DataException(
          'Its uploaded file couldn\'t be removed yet. It is hidden and '
          'marked for deletion; nothing else was changed. Choose Delete '
          'again to finish — it is also retried automatically.',
        );
      await pumpScreen(
        tester,
        wrap(role: AppRole.siteManager, adminService: admin),
      );
      await openMore(tester);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete permanently'));
      await tester.pumpAndSettle();
      expect(find.textContaining('marked for deletion'), findsOneWidget);
      expect(find.textContaining('Deleted "'), findsNothing);
    });
  });
}
