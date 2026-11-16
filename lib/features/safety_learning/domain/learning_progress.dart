import 'worker_learning_status.dart';

/// Where a learner is with one required lesson — derived only from
/// persisted data (their learning record, and whether the lesson's quiz is
/// part of their requirement), never guessed.
enum LearningStage {
  notStarted,

  /// Started; the content step (the video) is not recorded as done yet.
  inProgress,

  /// The video is watched; a mandatory quiz still has to be passed.
  quizOutstanding,

  completed,
}

/// The one thing the learner should do next.
enum LearningNextAction {
  watchVideo,
  continueVideo,
  startLesson,
  finishLesson,
  takeQuiz,
  none,
}

class LearningProgress {
  const LearningProgress._({
    required this.stage,
    required this.nextAction,
    required this.isVideo,
  });

  /// [status] is null when no record exists yet (not started).
  /// [quizRequired] is whether passing the quiz is part of the learner's
  /// requirement (false when there is no quiz, or it is optional).
  factory LearningProgress.of({
    required WorkerLearningStatus? status,
    required bool contentCompleted,
    required bool isVideo,
    required bool quizRequired,
  }) {
    final stage = switch (status) {
      WorkerLearningStatus.completed => LearningStage.completed,
      _ when contentCompleted && quizRequired => LearningStage.quizOutstanding,
      WorkerLearningStatus.inProgress => LearningStage.inProgress,
      _ => LearningStage.notStarted,
    };
    final next = switch (stage) {
      LearningStage.completed => LearningNextAction.none,
      LearningStage.quizOutstanding => LearningNextAction.takeQuiz,
      LearningStage.inProgress =>
        isVideo
            ? LearningNextAction.continueVideo
            : LearningNextAction.finishLesson,
      LearningStage.notStarted =>
        isVideo
            ? LearningNextAction.watchVideo
            : LearningNextAction.startLesson,
    };
    return LearningProgress._(stage: stage, nextAction: next, isVideo: isVideo);
  }

  final LearningStage stage;
  final LearningNextAction nextAction;
  final bool isVideo;

  String get stageLabel => switch (stage) {
    LearningStage.notStarted => 'Not started',
    LearningStage.inProgress => isVideo ? 'Video in progress' : 'In progress',
    LearningStage.quizOutstanding =>
      isVideo ? 'Video watched · quiz outstanding' : 'Quiz outstanding',
    LearningStage.completed => 'Completed',
  };

  /// "Next: Watch Video" etc.; empty when nothing is left to do.
  String get nextActionLabel => switch (nextAction) {
    LearningNextAction.watchVideo => 'Watch Video',
    LearningNextAction.continueVideo => 'Continue Video',
    LearningNextAction.startLesson => 'Start Learning',
    LearningNextAction.finishLesson => 'Complete Learning',
    LearningNextAction.takeQuiz => 'Take Quiz',
    LearningNextAction.none => '',
  };
}
