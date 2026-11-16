import '../../daily_safety_meetings/domain/daily_safety_meeting_status.dart';

/// Where [TodaysSafetyReadiness.beforeMeeting] was resolved from — see
/// `getMyTodaysSafetyReadiness`'s doc comment
/// (`functions/src/worker_learning_callable.ts`).
enum ReadinessGatingSource {
  /// Today's Daily Safety Meeting has been started: the attendance-gating
  /// set is exactly what `recordMeetingAttendance` will enforce.
  meeting,

  /// No meeting has been started yet: the attendance-gating set is the one
  /// the worker's own activity assignments are EXPECTED to produce.
  assignments,
}

/// A worker's progress on one [ReadinessItem], as reported by the server.
enum ReadinessItemStatus {
  notStarted,
  assigned,
  inProgress;

  static ReadinessItemStatus fromId(Object? id) => switch (id) {
    'assigned' => ReadinessItemStatus.assigned,
    'inProgress' => ReadinessItemStatus.inProgress,
    _ => ReadinessItemStatus.notStarted,
  };
}

/// One incomplete learning item in Today's Safety Readiness.
class ReadinessItem {
  const ReadinessItem({
    required this.learningId,
    required this.title,
    required this.status,
    required this.canStart,
    this.type,
    this.questionCount = 0,
    this.quizRequired = false,
    this.contentCompleted = false,
  });

  /// How many quiz questions the item has (0 = no quiz).
  final int questionCount;

  /// Whether passing that quiz is part of this requirement.
  final bool quizRequired;

  /// Whether the content step (watching the video) is already recorded.
  final bool contentCompleted;

  final String learningId;
  final String title;
  final String? type;
  final ReadinessItemStatus status;

  /// False when this item gates today's meeting (resolved from the
  /// MEETING's own scope) but is not in the worker's own assignment-derived
  /// required set — `startLearning` would refuse it, so the UI offers no
  /// start action. See `ReadinessItem` in `worker_learning_callable.ts`.
  final bool canStart;

  static ReadinessItem? tryFromMap(Map<Object?, Object?> map) {
    final learningId = map['learningId'];
    if (learningId is! String || learningId.isEmpty) return null;
    final title = map['title'];
    final type = map['type'];
    return ReadinessItem(
      learningId: learningId,
      title: title is String && title.isNotEmpty ? title : learningId,
      type: type is String ? type : null,
      status: ReadinessItemStatus.fromId(map['status']),
      canStart: map['canStart'] != false,
      questionCount: map['questionCount'] is num
          ? (map['questionCount'] as num).toInt()
          : 0,
      quizRequired: map['quizRequired'] == true,
      contentCompleted: map['contentCompleted'] == true,
    );
  }
}

/// An id/name pair labelling today's project, site or activity.
class ReadinessScopeRef {
  const ReadinessScopeRef({required this.id, required this.name});

  final String id;
  final String name;

  /// [name], or [id] when the stored name is blank.
  String get label => name.isEmpty ? id : name;
}

/// Today's Daily Safety Meeting, once a Foreman has started it. There is
/// no scheduled time — a meeting document only exists from the moment it
/// is started — so [startTime] is when it actually began.
class ReadinessMeeting {
  const ReadinessMeeting({
    required this.id,
    required this.status,
    this.startTime,
  });

  final String id;
  final DailySafetyMeetingStatus? status;
  final DateTime? startTime;

  bool get isCompleted => status == DailySafetyMeetingStatus.completed;
}

/// The signed-in worker's focused learning view for today, returned by the
/// `getMyTodaysSafetyReadiness` callable — see that callable's doc comment
/// for how each section is resolved.
///
/// The three sections are disjoint: an item that is both attendance-gating
/// and required before work appears once, in [beforeMeeting]. Only
/// incomplete learning is ever included; completion is persistent (there
/// is no daily reset).
class TodaysSafetyReadiness {
  const TodaysSafetyReadiness({
    required this.gatingSource,
    this.isForeman = false,
    this.meeting,
    this.projects = const [],
    this.sites = const [],
    this.activities = const [],
    this.beforeMeeting = const [],
    this.beforeWork = const [],
    this.additional = const [],
    this.neededTomorrow = const [],
  });

  final ReadinessGatingSource gatingSource;

  /// The caller is a Foreman: "before today's meeting" is the learning they
  /// must complete before they can START (and complete) the meeting they
  /// run, resolved from the site(s) they lead rather than assignments.
  final bool isForeman;
  final ReadinessMeeting? meeting;
  final List<ReadinessScopeRef> projects;
  final List<ReadinessScopeRef> sites;
  final List<ReadinessScopeRef> activities;

  /// Section 1 — "Needed today": the person's small daily plan (one lesson
  /// per activity they do today plus one general lesson — see
  /// `functions/src/daily_learning_plan.ts`). The only learning that
  /// blocks them at today's meeting.
  final List<ReadinessItem> beforeMeeting;

  /// Section 2 — required-before-work learning not already in
  /// [beforeMeeting] ("Before you work").
  final List<ReadinessItem> beforeWork;

  /// Section 3 — "When you can": the rest of the worker's required
  /// learning, shown collapsed so it never reads as today's task list. Still
  /// required; later days' plans draw from it.
  final List<ReadinessItem> additional;

  /// Tomorrow's "Needed today" lessons, shown now so a worker can get ahead
  /// the evening before. Completing one now means it is already done
  /// tomorrow morning.
  final List<ReadinessItem> neededTomorrow;

  factory TodaysSafetyReadiness.fromMap(Map<Object?, Object?> map) {
    final scope = _asMap(map['scope']);
    final meeting = _asMap(map['meeting']);
    final meetingId = meeting['id'];
    final startTime = meeting['startTime'];
    return TodaysSafetyReadiness(
      isForeman: map['role'] == 'foreman',
      gatingSource: map['gatingSource'] == 'meeting'
          ? ReadinessGatingSource.meeting
          : ReadinessGatingSource.assignments,
      meeting: meetingId is String
          ? ReadinessMeeting(
              id: meetingId,
              status: DailySafetyMeetingStatus.tryFromId(
                meeting['status'] is String
                    ? meeting['status'] as String
                    : null,
              ),
              startTime: startTime is String
                  ? DateTime.tryParse(startTime)?.toLocal()
                  : null,
            )
          : null,
      projects: _refs(scope['projects']),
      sites: _refs(scope['sites']),
      activities: _refs(scope['activities']),
      beforeMeeting: _items(map['beforeMeeting']),
      beforeWork: _items(map['beforeWork']),
      additional: _items(map['additional']),
      neededTomorrow: _items(map['neededTomorrow']),
    );
  }

  /// A copy with every item whose id is in [completedIds] removed — lets
  /// the UI drop learning the moment the worker completes it, from the live
  /// `watchMine()` stream, without re-calling the server.
  TodaysSafetyReadiness withoutCompleted(Set<String> completedIds) {
    if (completedIds.isEmpty) return this;
    List<ReadinessItem> keep(List<ReadinessItem> items) => [
      for (final item in items)
        if (!completedIds.contains(item.learningId)) item,
    ];
    return TodaysSafetyReadiness(
      gatingSource: gatingSource,
      isForeman: isForeman,
      meeting: meeting,
      projects: projects,
      sites: sites,
      activities: activities,
      beforeMeeting: keep(beforeMeeting),
      beforeWork: keep(beforeWork),
      additional: keep(additional),
      neededTomorrow: keep(neededTomorrow),
    );
  }

  /// Nothing stands between the worker and today's meeting or work.
  bool get isReady => beforeMeeting.isEmpty && beforeWork.isEmpty;

  static Map<Object?, Object?> _asMap(Object? value) =>
      value is Map ? value.cast<Object?, Object?>() : const {};

  static List<ReadinessScopeRef> _refs(Object? value) => [
    if (value is List)
      for (final raw in value.whereType<Map>())
        if (raw['id'] is String)
          ReadinessScopeRef(
            id: raw['id'] as String,
            name: raw['name'] is String ? raw['name'] as String : '',
          ),
  ];

  static List<ReadinessItem> _items(Object? value) => [
    if (value is List)
      for (final raw in value.whereType<Map>())
        ?ReadinessItem.tryFromMap(raw.cast<Object?, Object?>()),
  ];
}
