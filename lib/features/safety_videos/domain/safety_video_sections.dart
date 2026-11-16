import '../../organizations/domain/organization_record_status.dart';
import '../../safety_learning/domain/safety_learning.dart';
import '../../safety_learning/domain/safety_learning_type.dart';
import '../../safety_learning/domain/todays_safety_readiness.dart';
import '../../safety_learning/domain/worker_learning_record.dart';
import '../../safety_learning/domain/worker_learning_status.dart';

/// Why a video is on someone's list. Comes ONLY from the readiness response
/// and their own learning records — never from a video's title or source.
enum VideoRequirement {
  /// In today's "Needed today" plan (`beforeMeeting`).
  neededToday,

  /// In `beforeWork` or `additional`.
  required,

  /// In tomorrow's plan only — required, and can be done early.
  getAhead,

  /// The person's own record says they completed it.
  completed,

  /// Readiness loaded and this video is not required of them.
  optional,

  /// No requirement label applies: readiness could not be checked, or the
  /// viewer (Site Manager, Admin) has no personal learning. Never shown as
  /// "Optional", since that could hide a required video.
  none,
}

/// One video card on the Safety Videos screen.
class SafetyVideoEntry {
  const SafetyVideoEntry({
    required this.learning,
    required this.requirement,
    this.record,
    this.progress,
    this.canStart = false,
    this.questionCount = 0,
    this.quizRequired = false,
    this.contentCompleted = false,
  });

  final SafetyLearning learning;
  final VideoRequirement requirement;

  /// The person's own learning record, when one exists.
  final WorkerLearningRecord? record;

  /// Started/not started, for a required video — from [record] when there
  /// is one, else from the readiness item. Null for anything not required.
  final WorkerLearningStatus? progress;

  /// Whether the server will let this person start the lesson — true only
  /// for a required video the readiness response says they may start. When
  /// false the lesson opens watch-only, so no learning function is called.
  final bool canStart;

  /// The video's quiz size (0 = no quiz) — known for required videos.
  final int questionCount;

  /// Whether passing that quiz is part of this person's requirement.
  final bool quizRequired;

  /// The video step is recorded as done (live record, else readiness).
  final bool contentCompleted;
}

/// The three sections, with each video in at most one of them.
class SafetyVideoSections {
  const SafetyVideoSections({
    this.today = const [],
    this.required = const [],
    this.completed = const [],
    this.browse = const [],
    this.otherLessonsDueToday = 0,
    this.requirementsKnown = false,
  });

  /// Section A — videos in today's plan.
  final List<SafetyVideoEntry> today;

  /// Section B — other required videos, not yet completed.
  final List<SafetyVideoEntry> required;

  /// Section B's completed group.
  final List<SafetyVideoEntry> completed;

  /// Section C — every other active video.
  final List<SafetyVideoEntry> browse;

  /// Non-video lessons in today's plan — the screen links to Safety
  /// Learning for these.
  final int otherLessonsDueToday;

  /// False when readiness was not available (or does not apply), so no
  /// required/optional labels were decided.
  final bool requirementsKnown;

  bool get isEmpty =>
      today.isEmpty && required.isEmpty && completed.isEmpty && browse.isEmpty;
}

/// The active videos among [items], sorted by title.
List<SafetyLearning> activeVideos(Iterable<SafetyLearning> items) {
  final videos = [
    for (final item in items)
      if (item.type == SafetyLearningType.video &&
          item.status == OrganizationRecordStatus.active)
        item,
  ];
  videos.sort(_byTitle);
  return videos;
}

/// Builds the Safety Videos sections.
///
/// [personal] is true for a Worker or Foreman, who have their own learning;
/// false for a Site Manager or Admin, who only browse. For a personal viewer,
/// [readiness] null means it failed to load: every video is then shown in
/// [SafetyVideoSections.browse] with [VideoRequirement.none] (completed
/// records still show as completed), never labelled optional.
SafetyVideoSections buildSafetyVideoSections({
  required Iterable<SafetyLearning> items,
  required bool personal,
  TodaysSafetyReadiness? readiness,
  List<WorkerLearningRecord> records = const [],
}) {
  final videos = activeVideos(items);
  if (!personal) {
    return SafetyVideoSections(
      browse: [
        for (final video in videos)
          SafetyVideoEntry(learning: video, requirement: VideoRequirement.none),
      ],
    );
  }

  final recordsById = {for (final record in records) record.learningId: record};
  final completedIds = {
    for (final record in records)
      if (record.status == WorkerLearningStatus.completed) record.learningId,
  };

  if (readiness == null) {
    return SafetyVideoSections(
      browse: [
        for (final video in videos)
          SafetyVideoEntry(
            learning: video,
            requirement: completedIds.contains(video.id)
                ? VideoRequirement.completed
                : VideoRequirement.none,
            record: recordsById[video.id],
          ),
      ],
    );
  }

  final live = readiness.withoutCompleted(completedIds);
  final todayItems = {
    for (final item in live.beforeMeeting) item.learningId: item,
  };
  final beforeWorkItems = {
    for (final item in live.beforeWork) item.learningId: item,
  };
  final additionalItems = {
    for (final item in live.additional) item.learningId: item,
  };
  final tomorrowItems = {
    for (final item in live.neededTomorrow) item.learningId: item,
  };

  final today = <SafetyVideoEntry>[];
  final required = <SafetyVideoEntry>[];
  final completed = <SafetyVideoEntry>[];
  final browse = <SafetyVideoEntry>[];

  SafetyVideoEntry entry(
    SafetyLearning video,
    VideoRequirement requirement,
    ReadinessItem item,
  ) {
    final record = recordsById[video.id];
    return SafetyVideoEntry(
      learning: video,
      requirement: requirement,
      record: record,
      progress: record?.status ?? _progressOf(item.status),
      canStart: item.canStart,
      questionCount: item.questionCount,
      quizRequired: item.quizRequired,
      contentCompleted:
          (record?.contentCompleted ?? false) || item.contentCompleted,
    );
  }

  // Most urgent first: needed today, then needed before work today, then
  // tomorrow's plan ("Get ahead"), then the rest of the required set.
  for (final video in videos) {
    final todayItem = todayItems[video.id];
    final beforeWorkItem = beforeWorkItems[video.id];
    final tomorrowItem = tomorrowItems[video.id];
    final additionalItem = additionalItems[video.id];
    if (todayItem != null) {
      today.add(entry(video, VideoRequirement.neededToday, todayItem));
    } else if (beforeWorkItem != null) {
      required.add(entry(video, VideoRequirement.required, beforeWorkItem));
    } else if (tomorrowItem != null) {
      required.add(entry(video, VideoRequirement.getAhead, tomorrowItem));
    } else if (additionalItem != null) {
      required.add(entry(video, VideoRequirement.required, additionalItem));
    } else if (completedIds.contains(video.id)) {
      completed.add(
        SafetyVideoEntry(
          learning: video,
          requirement: VideoRequirement.completed,
          record: recordsById[video.id],
          progress: WorkerLearningStatus.completed,
        ),
      );
    } else {
      browse.add(
        SafetyVideoEntry(
          learning: video,
          requirement: VideoRequirement.optional,
        ),
      );
    }
  }

  today.sort(_byProgress);
  required.sort(_byProgress);

  return SafetyVideoSections(
    today: today,
    required: required,
    completed: completed,
    browse: browse,
    otherLessonsDueToday: live.beforeMeeting
        .where((item) => item.type != SafetyLearningType.video.id)
        .length,
    requirementsKnown: true,
  );
}

WorkerLearningStatus _progressOf(ReadinessItemStatus status) =>
    switch (status) {
      ReadinessItemStatus.inProgress => WorkerLearningStatus.inProgress,
      _ => WorkerLearningStatus.assigned,
    };

int _byTitle(SafetyLearning a, SafetyLearning b) =>
    a.title.toLowerCase().compareTo(b.title.toLowerCase());

/// Started first, then the rest, each by title.
int _byProgress(SafetyVideoEntry a, SafetyVideoEntry b) {
  int rank(SafetyVideoEntry e) =>
      e.progress == WorkerLearningStatus.inProgress ? 0 : 1;
  final byRank = rank(a).compareTo(rank(b));
  return byRank != 0 ? byRank : _byTitle(a.learning, b.learning);
}
