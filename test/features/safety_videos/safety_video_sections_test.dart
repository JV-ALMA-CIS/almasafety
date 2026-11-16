import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/features/organizations/domain/organization_record_status.dart';
import 'package:jva_safety/features/safety_learning/domain/safety_learning.dart';
import 'package:jva_safety/features/safety_learning/domain/safety_learning_type.dart';
import 'package:jva_safety/features/safety_learning/domain/todays_safety_readiness.dart';
import 'package:jva_safety/features/safety_learning/domain/worker_learning_record.dart';
import 'package:jva_safety/features/safety_learning/domain/worker_learning_status.dart';
import 'package:jva_safety/features/safety_videos/domain/safety_video_sections.dart';

SafetyLearning learning(
  String id, {
  SafetyLearningType type = SafetyLearningType.video,
  OrganizationRecordStatus status = OrganizationRecordStatus.active,
  String contentReference = 'https://example.org/a.mp4',
}) => SafetyLearning(
  id: id,
  organizationId: 'org-alpha',
  title: 'Video $id',
  type: type,
  contentReference: contentReference,
  status: status,
);

ReadinessItem item(
  String id, {
  String type = 'video',
  bool canStart = true,
  ReadinessItemStatus status = ReadinessItemStatus.notStarted,
}) => ReadinessItem(
  learningId: id,
  title: 'Video $id',
  type: type,
  status: status,
  canStart: canStart,
);

WorkerLearningRecord record(String id, WorkerLearningStatus status) =>
    WorkerLearningRecord(
      id: 'worker-1_$id',
      workerUid: 'worker-1',
      organizationId: 'org-alpha',
      learningId: id,
      status: status,
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

List<String> ids(List<SafetyVideoEntry> entries) => [
  for (final e in entries) e.learning.id,
];

void main() {
  test('only active video items are shown', () {
    final sections = buildSafetyVideoSections(
      personal: false,
      items: [
        learning('v1'),
        learning('v2', status: OrganizationRecordStatus.inactive),
        learning('d1', type: SafetyLearningType.document),
        learning('k1', type: SafetyLearningType.knowledgeCheck),
      ],
    );
    expect(ids(sections.browse), ['v1']);
  });

  test('a browse-only viewer gets no requirement labels at all', () {
    final sections = buildSafetyVideoSections(
      personal: false,
      items: [learning('v1'), learning('v2')],
    );
    expect(sections.requirementsKnown, isFalse);
    expect(
      sections.browse.map((e) => e.requirement),
      everyElement(VideoRequirement.none),
    );
    expect(sections.browse.every((e) => !e.canStart), isTrue);
  });

  test('each video appears in exactly one section, highest priority first', () {
    final sections = buildSafetyVideoSections(
      personal: true,
      items: [
        learning('today'),
        learning('work'),
        learning('later'),
        learning('tomorrow'),
        learning('done'),
        learning('free'),
      ],
      readiness: readiness(
        // `today` is also listed lower down: it must only appear once.
        beforeMeeting: [item('today')],
        beforeWork: [item('work'), item('today')],
        additional: [item('later'), item('tomorrow')],
        neededTomorrow: [item('tomorrow')],
      ),
      records: [record('done', WorkerLearningStatus.completed)],
    );

    expect(ids(sections.today), ['today']);
    expect(ids(sections.required), containsAll(['work', 'later', 'tomorrow']));
    expect(sections.required, hasLength(3));
    expect(ids(sections.completed), ['done']);
    expect(ids(sections.browse), ['free']);

    final all = [
      ...ids(sections.today),
      ...ids(sections.required),
      ...ids(sections.completed),
      ...ids(sections.browse),
    ];
    expect(all.toSet(), hasLength(all.length));
  });

  test('before-work beats get-ahead; get-ahead beats the rest', () {
    final sections = buildSafetyVideoSections(
      personal: true,
      items: [learning('work'), learning('later')],
      readiness: readiness(
        beforeWork: [item('work')],
        additional: [item('later')],
        neededTomorrow: [item('work'), item('later')],
      ),
    );
    VideoRequirement of(String id) =>
        sections.required.firstWhere((e) => e.learning.id == id).requirement;
    expect(of('work'), VideoRequirement.required);
    expect(of('later'), VideoRequirement.getAhead);
  });

  test('labels come from readiness: needed today, required, get ahead', () {
    final sections = buildSafetyVideoSections(
      personal: true,
      items: [learning('a'), learning('b'), learning('c'), learning('d')],
      readiness: readiness(
        beforeMeeting: [item('a')],
        beforeWork: [item('b')],
        additional: [item('c')],
        neededTomorrow: [item('d')],
      ),
    );
    VideoRequirement of(String id) => [
      ...sections.today,
      ...sections.required,
    ].firstWhere((e) => e.learning.id == id).requirement;

    expect(of('a'), VideoRequirement.neededToday);
    expect(of('b'), VideoRequirement.required);
    expect(of('c'), VideoRequirement.required);
    expect(of('d'), VideoRequirement.getAhead);
    expect(sections.requirementsKnown, isTrue);
  });

  test('a video completed since readiness loaded moves to completed', () {
    final sections = buildSafetyVideoSections(
      personal: true,
      items: [learning('a')],
      readiness: readiness(beforeMeeting: [item('a')]),
      records: [record('a', WorkerLearningStatus.completed)],
    );
    expect(sections.today, isEmpty);
    expect(ids(sections.completed), ['a']);
    expect(sections.completed.single.progress, WorkerLearningStatus.completed);
  });

  test('progress comes from the record, else the readiness item', () {
    final sections = buildSafetyVideoSections(
      personal: true,
      items: [learning('a'), learning('b')],
      readiness: readiness(
        beforeWork: [
          item('a'),
          item('b', status: ReadinessItemStatus.inProgress),
        ],
      ),
      records: [record('a', WorkerLearningStatus.inProgress)],
    );
    expect(
      sections.required.map((e) => e.progress),
      everyElement(WorkerLearningStatus.inProgress),
    );
    expect(sections.required.first.record, isNotNull);
  });

  test('started videos sort before not-started ones', () {
    final sections = buildSafetyVideoSections(
      personal: true,
      items: [learning('a'), learning('b')],
      readiness: readiness(
        beforeWork: [
          item('a'),
          item('b', status: ReadinessItemStatus.inProgress),
        ],
      ),
    );
    expect(ids(sections.required), ['b', 'a']);
  });

  test('canStart is carried from readiness so the lesson opens watch-only', () {
    final sections = buildSafetyVideoSections(
      personal: true,
      items: [learning('a')],
      readiness: readiness(beforeMeeting: [item('a', canStart: false)]),
    );
    expect(sections.today.single.canStart, isFalse);
  });

  test('a readiness failure never produces an Optional label', () {
    final sections = buildSafetyVideoSections(
      personal: true,
      items: [learning('a'), learning('b')],
      readiness: null,
      records: [record('b', WorkerLearningStatus.completed)],
    );
    expect(sections.requirementsKnown, isFalse);
    expect(sections.today, isEmpty);
    expect(sections.required, isEmpty);
    expect(ids(sections.browse), ['a', 'b']);
    expect(
      sections.browse.map((e) => e.requirement),
      isNot(contains(VideoRequirement.optional)),
    );
    expect(
      sections.browse.firstWhere((e) => e.learning.id == 'b').requirement,
      VideoRequirement.completed,
    );
    expect(sections.browse.every((e) => !e.canStart), isTrue);
  });

  test('labels are identical whatever the video source', () {
    const sources = [
      'https://firebasestorage.googleapis.com/v0/b/bucket/o/'
          'organizations%2Forg-alpha%2Fsafety_learning%2F1%2Fa.mp4',
      'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      'https://vimeo.com/76979871',
      'https://cdn.example.org/a.mp4',
      'not even a link',
    ];
    final labels = <VideoRequirement>{};
    for (final source in sources) {
      final sections = buildSafetyVideoSections(
        personal: true,
        items: [learning('a', contentReference: source)],
        readiness: readiness(beforeWork: [item('a')]),
      );
      labels.add(sections.required.single.requirement);
    }
    expect(labels, {VideoRequirement.required});
  });

  test('counts non-video lessons due today for the Safety Learning link', () {
    final sections = buildSafetyVideoSections(
      personal: true,
      items: [learning('a')],
      readiness: readiness(
        beforeMeeting: [
          item('a'),
          item('doc', type: 'document'),
          item('quiz', type: 'knowledgeCheck'),
        ],
      ),
    );
    expect(sections.otherLessonsDueToday, 2);
  });

  test('a required inactive video is not shown', () {
    final sections = buildSafetyVideoSections(
      personal: true,
      items: [learning('a', status: OrganizationRecordStatus.inactive)],
      readiness: readiness(beforeMeeting: [item('a')]),
    );
    expect(sections.isEmpty, isTrue);
  });
}
