import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/features/safety_learning/domain/learning_progress.dart';
import 'package:jva_safety/features/safety_learning/domain/worker_learning_status.dart';

LearningProgress progress({
  WorkerLearningStatus? status,
  bool contentCompleted = false,
  bool isVideo = true,
  bool quizRequired = false,
}) => LearningProgress.of(
  status: status,
  contentCompleted: contentCompleted,
  isVideo: isVideo,
  quizRequired: quizRequired,
);

void main() {
  test('not started: the video is the action', () {
    final p = progress();
    expect(p.stage, LearningStage.notStarted);
    expect(p.nextAction, LearningNextAction.watchVideo);
    expect(p.nextActionLabel, 'Watch Video');
    expect(
      progress(status: WorkerLearningStatus.assigned).nextAction,
      LearningNextAction.watchVideo,
    );
  });

  test('started, video not done: Continue Video — never the quiz', () {
    final p = progress(
      status: WorkerLearningStatus.inProgress,
      quizRequired: true,
    );
    expect(p.stage, LearningStage.inProgress);
    expect(p.nextAction, LearningNextAction.continueVideo);
    expect(p.stageLabel, 'Video in progress');
  });

  test('video watched + required quiz: the quiz is next, not complete', () {
    final p = progress(
      status: WorkerLearningStatus.inProgress,
      contentCompleted: true,
      quizRequired: true,
    );
    expect(p.stage, LearningStage.quizOutstanding);
    expect(p.nextAction, LearningNextAction.takeQuiz);
    expect(p.stageLabel, 'Video watched · quiz outstanding');
  });

  test('an optional quiz never becomes the next action', () {
    final p = progress(
      status: WorkerLearningStatus.inProgress,
      contentCompleted: true,
    );
    expect(p.nextAction, isNot(LearningNextAction.takeQuiz));
  });

  test('completed only from the persisted completed status', () {
    final p = progress(
      status: WorkerLearningStatus.completed,
      contentCompleted: true,
      quizRequired: true,
    );
    expect(p.stage, LearningStage.completed);
    expect(p.nextAction, LearningNextAction.none);
    expect(p.nextActionLabel, isEmpty);
  });

  test('a non-video lesson keeps Start / Complete Learning', () {
    expect(progress(isVideo: false).nextActionLabel, 'Start Learning');
    expect(
      progress(
        isVideo: false,
        status: WorkerLearningStatus.inProgress,
      ).nextActionLabel,
      'Complete Learning',
    );
  });
}
