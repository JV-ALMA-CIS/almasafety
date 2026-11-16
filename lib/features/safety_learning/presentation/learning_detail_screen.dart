import 'dart:async';
import '../../../core/widgets/choice_list.dart';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import '../../../core/widgets/feature_header.dart';
import '../../../core/widgets/status_badge.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/storage_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../../organizations/domain/organization_record_status.dart';
import '../data/worker_learning_service.dart';
import '../domain/complete_learning_result.dart';
import '../domain/knowledge_check_question.dart';
import '../domain/knowledge_check_result.dart';
import '../domain/learning_progress.dart';
import '../domain/lesson_quiz.dart';
import '../domain/safety_learning.dart';
import '../domain/safety_learning_type.dart';
import '../domain/submitted_answer.dart';
import '../domain/video_source.dart';
import '../domain/worker_learning_record.dart';
import '../domain/worker_learning_status.dart';
import '../../../core/widgets/mobile_title.dart';

/// Opens [uri] outside the app; true when something opened it.
typedef ExternalLinkLauncher = Future<bool> Function(Uri uri);

/// The production [ExternalLinkLauncher]: the device's browser or the
/// provider's own app (YouTube, Vimeo).
Future<bool> launchExternally(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

//// The detail screen for one learning item, reached via a plain
/// `Navigator.push` from Safety Learning, the dashboard or Safety Videos —
/// every entry point opens this same screen on the same shared item.
///
/// A lesson has up to two parts, each shown as its own step:
///
/// 1. THE CONTENT. For [SafetyLearningType.video] the link's [VideoSource]
///    decides how it plays: a JVA video or a direct HTTPS video file in the
///    in-app player ([_VideoPlayerContent]); a YouTube or Vimeo video in
///    that app or the browser — never the file player; an unusable link
///    shows "unavailable". Other types open externally ([_ContentLink]).
/// 2. THE QUIZ, when the lesson has knowledge-check questions — loaded on
///    open from `getKnowledgeCheckQuestions` (never containing an answer),
///    which also says whether passing it is part of this learner's
///    requirement. A quiz is MANDATORY only when their Safety Requirement
///    says so; otherwise it is optional (and, for a lesson not required of
///    them at all, a practice run that records nothing).
///
/// The one next action follows [LearningProgress]:
///  - not started: "Watch Video" (or "Start Learning") -> `startLearning`
///    (an external video also opens).
///  - in progress: "Continue Video" (external) / "I've Watched the Video" /
///    "Complete Learning" -> `completeLearning` without answers: with a
///    mandatory quiz this records the content step only; otherwise it
///    completes the lesson (after a confirmation).
///  - video watched, mandatory quiz outstanding: "Take Quiz" ->
///    `completeLearning` with answers; a failed attempt can be retried.
///  - completed: the summary; an optional quiz can still be taken.
/// `completeLearning` is the sole authority: when
/// [SafetyLearning.minimumWatchSeconds] is set, the content step is
/// disabled here until that time has passed since `startedAt` too, but
/// only as a hint — see [_remainingWatchTime].
///
/// Both callables derive the acting worker from the caller's own auth token
/// server-side — see [WorkerLearningService]'s doc comment — so this screen
/// never sends a worker identifier of any kind.
///
/// WATCH-ONLY: with [watchOnly] (or no [record]) the content is shown with
/// [watchOnlyNote] and no Start/Complete actions, and no record is ever
/// written — used for an optional video, or for a Site Manager/Admin who
/// has no learning of their own. With [allowPracticeQuiz] (a Worker or
/// Foreman viewing an optional lesson) its quiz can be practised; nothing
/// is recorded.
///
/// GENERAL LEARNING: a [record] for a lesson that is no longer required of
/// the learner (its requirement was removed, or they moved site) — known
/// up front ([generalLearning]) or reported by the server when the quiz
/// loads. Start/Complete would be refused, so the lesson opens like an
/// optional one, labelled [generalLearningNote], with a practice quiz that
/// records nothing. A completed record still shows its completion — that
/// history is never changed.
class LearningDetailScreen extends StatefulWidget {
  const LearningDetailScreen({
    required this.organizationId,
    required this.learning,
    this.record,
    super.key,
    this.watchOnly = false,
    this.watchOnlyNote = optionalWatchNote,
    this.allowPracticeQuiz = false,
    this.generalLearning = false,
    this.workerLearningService,
    this.storageBucket,
    this.externalLinkLauncher,
  });

  /// The default [watchOnlyNote].
  static const optionalWatchNote =
      'Optional: watching this doesn\'t add to your training record.';

  /// Shown for a lesson that is no longer required of the learner.
  static const generalLearningNote =
      'No longer required — general learning. You can still watch it and '
      'practise the quiz; this doesn\'t change your training record.';

  /// Shown for a lesson that has been deactivated (reached through an old
  /// record or link): nothing to watch or practise, nothing asked of the
  /// server — only the record's history.
  static const inactiveNote =
      'This lesson is no longer active, so it can\'t be watched, started, '
      'completed or practised. Your record below is kept.';

  final String organizationId;
  final SafetyLearning learning;

  /// The worker's own record for this lesson. Required unless [watchOnly];
  /// without one the screen is always watch-only.
  final WorkerLearningRecord? record;

  /// Show the content only — see this class's doc comment.
  final bool watchOnly;

  /// Explains a watch-only view to the viewer.
  final String watchOnlyNote;

  /// In watch-only mode, offer the lesson's quiz as an unrecorded practice
  /// run. Only for a learner (Worker/Foreman) — never an author.
  final bool allowPracticeQuiz;

  /// The learner holds a [record] for this lesson, but it is no longer
  /// required of them — see this class's doc comment.
  final bool generalLearning;

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real service.
  final WorkerLearningService? workerLearningService;

  /// The Storage bucket used to recognise JVA videos. Defaults to the
  /// running Firebase app's configured bucket.
  final String? storageBucket;

  /// Opens a link outside the app. Defaults to `url_launcher`; injected in
  /// tests.
  final ExternalLinkLauncher? externalLinkLauncher;

  @override
  State<LearningDetailScreen> createState() => _LearningDetailScreenState();
}

class _LearningDetailScreenState extends State<LearningDetailScreen> {
  late final WorkerLearningService _service =
      widget.workerLearningService ?? WorkerLearningService();

  WorkerLearningStatus? _localStatus;
  DateTime? _localCompletedAt;
  DateTime? _localStartedAt;
  bool? _localContentCompleted;
  String? _errorMessage;
  bool _isSaving = false;
  Timer? _countdownTimer;

  /// The lesson's quiz and whether it is mandatory — null until loaded.
  LessonQuiz? _quiz;
  String? _quizError;
  bool _quizLoading = false;

  /// The last graded knowledge-check outcome — shown after a submission,
  /// whether it passed or not. A failed attempt is an expected result, not
  /// an error: see [CompleteLearningResult]'s doc comment.
  KnowledgeCheckResult? _lastKnowledgeCheckResult;

  /// Whether [_lastKnowledgeCheckResult] was an unrecorded practice run.
  bool _lastWasPractice = false;

  ExternalLinkLauncher get _launcher =>
      widget.externalLinkLauncher ?? launchExternally;

  /// A record exists, but the lesson is no longer required of the learner
  /// — said by the caller, or by the server when the quiz loaded. An older
  /// server's answer never says so (see [LessonQuiz]).
  bool get _generalLearning {
    if (widget.record == null || widget.watchOnly) return false;
    if (widget.generalLearning) return true;
    final quiz = _quiz;
    return quiz != null && quiz.serverReportsRequirement && !quiz.required;
  }

  /// The record was completed — kept and shown as history.
  bool get _recordCompleted =>
      widget.record?.status == WorkerLearningStatus.completed;

  /// No learning actions at all — see [LearningDetailScreen]'s doc comment.
  /// Deactivated by a manager — no new learning of any kind.
  bool get _inactive =>
      widget.learning.status != OrganizationRecordStatus.active;

  bool get _watchOnly =>
      _inactive ||
      widget.watchOnly ||
      widget.record == null ||
      (_generalLearning && !_recordCompleted);

  bool get _isVideo => widget.learning.type == SafetyLearningType.video;

  /// Whether the quiz is loaded/used at all on this screen.
  bool get _usesQuiz =>
      !_inactive &&
      ((widget.record != null && !widget.watchOnly) ||
          widget.allowPracticeQuiz);

  /// The quiz can be taken as an unrecorded practice run.
  bool get _canPractise =>
      !_inactive && (widget.allowPracticeQuiz || _generalLearning);

  WorkerLearningStatus get _status =>
      _localStatus ?? widget.record?.status ?? WorkerLearningStatus.assigned;
  DateTime? get _completedAt => _localCompletedAt ?? widget.record?.completedAt;
  DateTime? get _startedAt => _localStartedAt ?? widget.record?.startedAt;
  bool get _contentCompleted =>
      _localContentCompleted ??
      (widget.record?.contentCompleted ?? false) ||
          _status == WorkerLearningStatus.completed;

  bool get _quizMandatory => _quiz?.quizRequired ?? false;

  LearningProgress get _progress => LearningProgress.of(
    status: _status,
    contentCompleted: _contentCompleted,
    isVideo: _isVideo,
    quizRequired: _quizMandatory,
  );

  late final VideoSource? _videoSource = videoSourceFor(
    type: widget.learning.type,
    reference: widget.learning.contentReference,
    organizationId: widget.organizationId,
    storageBucket: widget.learning.type == SafetyLearningType.video
        ? widget.storageBucket ?? StorageService().bucket
        : null,
  );

  /// Whether this item is subject to the minimum-engagement-time gate at
  /// all — applies to any [SafetyLearningType], not just
  /// [SafetyLearningType.video]; see `completeLearning`'s doc comment
  /// (`functions/src/worker_learning_callable.ts`) for the mechanism this
  /// mirrors client-side for display only. The server independently
  /// enforces this regardless of what this getter or [_remainingWatchTime]
  /// compute; a stale/wrong client clock only ever makes the button
  /// temporarily too strict or too lax, never the actual completion.
  int get _minimumWatchSeconds => widget.learning.minimumWatchSeconds ?? 0;

  /// Seconds still remaining before the server will accept the content
  /// step, or null once the requirement is satisfied (or doesn't apply).
  /// Purely a client-side ESTIMATE from [_startedAt] — a real server
  /// timestamp, but read here without any guarantee the device clock
  /// agrees with the server's; that possible drift is why the server, not
  /// this value, is the actual authority.
  Duration? get _remainingWatchTime {
    final minimum = _minimumWatchSeconds;
    if (minimum <= 0 || _contentCompleted) return null;
    final startedAt = _startedAt;
    if (startedAt == null) return Duration(seconds: minimum);
    final elapsed = DateTime.now().difference(startedAt);
    final remaining = Duration(seconds: minimum) - elapsed;
    return remaining.isNegative ? null : remaining;
  }

  @override
  void initState() {
    super.initState();
    if (_minimumWatchSeconds > 0 && !_watchOnly) {
      _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
    if (_usesQuiz) _loadQuiz();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadQuiz() async {
    if (_quizLoading) return;
    setState(() {
      _quizLoading = true;
      _quizError = null;
    });
    try {
      final quiz = await _service.getLessonQuiz(
        organizationId: widget.organizationId,
        learningId: widget.learning.id,
      );
      if (mounted) setState(() => _quiz = quiz);
    } on AppException catch (e) {
      debugPrint('Learning: could not load the quiz: ${e.message}');
      if (mounted) setState(() => _quizError = e.message);
    } on Object catch (e) {
      debugPrint('Learning: could not load the quiz: $e');
      if (mounted) {
        setState(() => _quizError = 'Could not load the quiz details.');
      }
    } finally {
      if (mounted) setState(() => _quizLoading = false);
    }
  }

  /// Runs [action] as the screen's one in-flight save, showing any error.
  Future<void> _saving(Future<void> Function() action) async {
    if (_isSaving) return;
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });
    try {
      await action();
    } on AppException catch (e) {
      debugPrint('Learning: action failed: ${e.message}');
      if (mounted) setState(() => _errorMessage = e.message);
    } on Object catch (e) {
      debugPrint('Learning: action failed: $e');
      if (mounted) {
        setState(
          () => _errorMessage =
              'Something went wrong. Check your connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// "Watch Video" / "Start Learning": starts the lesson; an external video
  /// then opens straight away.
  Future<void> _startLearning() async {
    if (_watchOnly) return;
    var started = false;
    await _saving(() async {
      await _service.startLearning(
        organizationId: widget.organizationId,
        learningId: widget.learning.id,
      );
      started = true;
      if (!mounted) return;
      setState(() {
        _localStatus = WorkerLearningStatus.inProgress;
        _localStartedAt = DateTime.now();
      });
    });
    if (started && mounted) await _openExternalVideo();
  }

  /// Opens a YouTube/Vimeo video; a no-op for anything else.
  Future<void> _openExternalVideo() async {
    final source = _videoSource;
    final uri = source?.uri;
    if (source == null || uri == null || source.playsInApp) return;
    if (source.isUnsupported) return;
    try {
      final opened = await _launcher(uri);
      if (!opened && mounted) {
        setState(() => _errorMessage = 'Could not open this video.');
      }
    } on Object catch (e) {
      debugPrint('Learning: could not open a link: $e');
      if (mounted) setState(() => _errorMessage = 'Could not open this video.');
    }
  }

  /// "I've Watched the Video" / "Complete Learning": the content step. With
  /// a mandatory quiz it records the video as watched (the quiz is next);
  /// otherwise it completes the lesson, after a confirmation.
  Future<void> _completeContent() async {
    if (_watchOnly || _quiz == null && _usesQuiz) return;
    if (!_quizMandatory) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => const _CompleteLearningDialog(),
      );
      if (confirmed != true || !mounted) return;
    }
    await _submit(selectedAnswers: null);
  }

  /// "Take Quiz" / "Take Optional Quiz" / "Practice Quiz".
  Future<void> _takeQuiz({required bool practice}) async {
    final quiz = _quiz;
    if (quiz == null || !quiz.hasQuiz || _isSaving) return;
    final answers = await showDialog<List<SubmittedAnswer>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _KnowledgeCheckDialog(questions: quiz.questions),
    );
    if (answers == null || !mounted) return;
    if (practice) {
      await _saving(() async {
        final result = await _service.practiceKnowledgeCheck(
          organizationId: widget.organizationId,
          learningId: widget.learning.id,
          selectedAnswers: answers,
        );
        if (!mounted) return;
        setState(() {
          _lastKnowledgeCheckResult = result;
          _lastWasPractice = true;
        });
      });
      return;
    }
    await _submit(selectedAnswers: answers);
  }

  Future<void> _submit({required List<SubmittedAnswer>? selectedAnswers}) {
    return _saving(() async {
      final result = await _service.completeLearning(
        organizationId: widget.organizationId,
        learningId: widget.learning.id,
        selectedAnswers: selectedAnswers,
      );
      if (!mounted) return;
      setState(() {
        if (result.knowledgeCheckResult != null) {
          _lastKnowledgeCheckResult = result.knowledgeCheckResult;
          _lastWasPractice = false;
        }
        if (result.contentCompleted) _localContentCompleted = true;
        if (result.status == WorkerLearningStatus.completed &&
            _status != WorkerLearningStatus.completed) {
          _localStatus = WorkerLearningStatus.completed;
          _localCompletedAt = DateTime.now();
        } else if (result.status == WorkerLearningStatus.inProgress) {
          _localStatus = WorkerLearningStatus.inProgress;
        }
        // A failed knowledge check leaves the lesson open — the result
        // banner shows the score and the quiz can be retaken (no retry
        // limit is configured).
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final learning = widget.learning;
    final color = _typeColor(learning.type);
    final quiz = _quiz;
    final showQuizStep =
        _usesQuiz &&
        (quiz == null ? _quizError != null || _quizLoading : quiz.hasQuiz);
    return Scaffold(
      appBar: AppBar(title: const MobileTitle('Learning Details')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          FeatureHeader(
            eyebrow: learning.type.label,
            title: learning.title,
            icon: _typeIcon(learning.type),
            color: color,
            trailing: _watchOnly ? null : _ProgressBadge(progress: _progress),
          ),
          const SizedBox(height: AppSpacing.md),
          if (_inactive)
            const _WatchOnlyNotice(note: LearningDetailScreen.inactiveNote)
          else if (_generalLearning) ...[
            const _WatchOnlyNotice(
              note: LearningDetailScreen.generalLearningNote,
            ),
            if (!_watchOnly) const SizedBox(height: AppSpacing.md),
          ] else if (_watchOnly)
            _WatchOnlyNotice(note: widget.watchOnlyNote),
          if (!_watchOnly)
            _LessonSteps(
              color: color,
              steps: [
                (
                  label: 'Start',
                  icon: Icons.play_arrow,
                  done: _status != WorkerLearningStatus.assigned,
                ),
                (
                  label: _isVideo ? 'Watch' : 'Learn',
                  icon: _isVideo ? Icons.ondemand_video : Icons.menu_book,
                  done: _contentCompleted,
                ),
                if (_quizMandatory)
                  (
                    label: 'Quiz',
                    icon: Icons.quiz,
                    done: _status == WorkerLearningStatus.completed,
                  ),
                (
                  label: 'Complete',
                  icon: Icons.check,
                  done: _status == WorkerLearningStatus.completed,
                ),
              ],
            ),
          if (learning.description != null) ...[
            const SizedBox(height: AppSpacing.md),
            _LessonCard(
              title: 'About this lesson',
              icon: Icons.info_outline,
              color: color,
              child: Text(
                learning.description!,
                style: AppTextStyles.bodyLarge,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          // Inactive: the record's history only — no player, link or quiz.
          if (_inactive)
            _InactiveHistory(record: widget.record, color: color)
          else
            _LessonCard(
              title: showQuizStep
                  ? (_isVideo ? 'Step 1 · Watch the video' : 'Step 1 · Lesson')
                  : 'Lesson content',
              icon: _typeIcon(learning.type),
              color: color,
              trailing: !_watchOnly && showQuizStep
                  ? _StepState(done: _contentCompleted)
                  : null,
              child: switch (_videoSource) {
                null => _ContentLink(
                  url: learning.contentReference,
                  color: color,
                  launcher: _launcher,
                ),
                final source => _VideoContent(
                  source: source,
                  status: _watchOnly ? null : _status,
                  contentCompleted: _contentCompleted,
                  launcher: _launcher,
                ),
              },
            ),
          if (showQuizStep) ...[
            const SizedBox(height: AppSpacing.md),
            _LessonCard(
              title: 'Step 2 · Quiz',
              icon: Icons.quiz,
              color: AppColors.correctiveActions,
              trailing: quiz == null
                  ? null
                  : _QuizBadge(
                      mandatory: quiz.quizRequired && !_generalLearning,
                      practice: _watchOnly || _generalLearning,
                    ),
              child: _quizSummary(),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          if (_errorMessage != null) ...[
            AuthErrorBanner(message: _errorMessage!),
            const SizedBox(height: AppSpacing.md),
          ],
          if (_lastKnowledgeCheckResult != null) ...[
            _KnowledgeCheckResultBanner(
              result: _lastKnowledgeCheckResult!,
              practice: _lastWasPractice,
              canRetry: _lastWasPractice || _quizMandatory,
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
          ..._actions(),
        ],
      ),
    );
  }

  /// What the quiz step says: loading, an error with retry, or what it
  /// needs and where the learner is with it.
  Widget _quizSummary() {
    final quiz = _quiz;
    if (quiz == null) {
      if (_quizError != null) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_quizError!, style: AppTextStyles.bodyMedium),
            const SizedBox(height: AppSpacing.sm),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, AppSpacing.minTouchTarget),
              ),
              onPressed: _quizLoading ? null : _loadQuiz,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
          ],
        );
      }
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final count = quiz.questions.length;
    final passMark = widget.learning.passingScorePercent ?? 100;
    final recorded = widget.record?.knowledgeCheckResult;
    final String state;
    if (_watchOnly || _generalLearning) {
      state =
          'Practise any time — your answers are checked but not '
          'recorded.';
    } else if (_status == WorkerLearningStatus.completed && quiz.quizRequired) {
      state = 'Passed.';
    } else if (quiz.quizRequired && !_contentCompleted) {
      state = _isVideo
          ? 'Unlocks once you have watched the video.'
          : 'Unlocks once you have completed the lesson.';
    } else if (quiz.quizRequired) {
      state = 'Ready — pass it to complete this lesson.';
    } else if (recorded != null) {
      state = recorded.passed
          ? 'Optional — you passed it.'
          : 'Optional — not passed yet.';
    } else {
      state = 'Optional — it does not affect completing this lesson.';
    }
    return Text(
      '$count ${count == 1 ? 'question' : 'questions'} · pass mark '
      '$passMark%. $state',
      style: AppTextStyles.bodyMedium,
    );
  }

  /// The next action for this lesson (see [LearningDetailScreen]'s doc
  /// comment), plus the completed summary.
  List<Widget> _actions() {
    final quiz = _quiz;
    if (_watchOnly) {
      return [
        if (_canPractise && quiz != null && quiz.hasQuiz)
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, AppSpacing.minTouchTarget),
            ),
            onPressed: _isSaving ? null : () => _takeQuiz(practice: true),
            icon: const Icon(Icons.quiz_outlined),
            label: const Text('Practice Quiz'),
          ),
      ];
    }
    final progress = _progress;
    final quizReady = quiz != null || !_usesQuiz;
    final source = _videoSource;
    final external =
        source != null && !source.playsInApp && !source.isUnsupported;
    switch (progress.stage) {
      case LearningStage.notStarted:
        return [
          _PrimaryAction(
            label: progress.nextActionLabel,
            icon: Icons.play_arrow,
            color: AppColors.go,
            // Wait for the quiz details: they say whether the lesson is
            // still required, so a no-longer-required one is never started.
            onPressed: _isSaving || !quizReady ? null : _startLearning,
          ),
        ];
      case LearningStage.inProgress:
        final waiting = _remainingWatchTime;
        final finishLabel = _isVideo
            ? 'I\'ve Watched the Video'
            : 'Complete Learning';
        return [
          if (waiting != null) ...[
            _WatchTimeNotice(remaining: waiting),
            const SizedBox(height: AppSpacing.sm),
          ],
          if (external) ...[
            _PrimaryAction(
              label: 'Continue Video',
              icon: Icons.open_in_new,
              color: AppColors.videos,
              onPressed: _isSaving ? null : _openExternalVideo,
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
          _PrimaryAction(
            label: finishLabel,
            icon: Icons.check_circle,
            color: AppColors.learning,
            outlined: external,
            onPressed: _isSaving || waiting != null || !quizReady
                ? null
                : _completeContent,
          ),
        ];
      case LearningStage.quizOutstanding:
        return [
          _PrimaryAction(
            label: 'Take Quiz',
            icon: Icons.quiz,
            color: AppColors.correctiveActions,
            onPressed: _isSaving || quiz == null
                ? null
                : () => _takeQuiz(practice: false),
          ),
        ];
      case LearningStage.completed:
        return [
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppColors.success,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                const Icon(Icons.verified, color: Colors.white, size: 32),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    _completedAt != null
                        ? 'Completed on ${_completedAt!.toLocal()}'
                              .split('.')
                              .first
                        : 'Completed',
                    style: AppTextStyles.bodyLarge.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (quiz != null && quiz.hasQuiz && _generalLearning) ...[
            // History stays as it is: a practice run records nothing.
            const SizedBox(height: AppSpacing.sm),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, AppSpacing.minTouchTarget),
              ),
              onPressed: _isSaving ? null : () => _takeQuiz(practice: true),
              icon: const Icon(Icons.quiz_outlined),
              label: const Text('Practice Quiz'),
            ),
          ] else if (quiz != null && quiz.hasQuiz && !quiz.quizRequired) ...[
            const SizedBox(height: AppSpacing.sm),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, AppSpacing.minTouchTarget),
              ),
              onPressed: _isSaving ? null : () => _takeQuiz(practice: false),
              icon: const Icon(Icons.quiz_outlined),
              label: const Text('Take Optional Quiz'),
            ),
          ],
        ];
    }
  }
}

/// The history of an inactive lesson, from the learner's existing record
/// only: its status and the dates and quiz result already recorded.
class _InactiveHistory extends StatelessWidget {
  const _InactiveHistory({required this.record, required this.color});

  final WorkerLearningRecord? record;
  final Color color;

  static String _date(DateTime value) =>
      value.toLocal().toString().split('.').first;

  @override
  Widget build(BuildContext context) {
    final record = this.record;
    final result = record?.knowledgeCheckResult;
    final rows = <(IconData, String)>[
      if (record == null)
        (Icons.info_outline, 'You have no record for this lesson.')
      else ...[
        (Icons.flag_outlined, 'Status: ${record.status.label}'),
        if (record.startedAt != null)
          (Icons.play_arrow, 'Started ${_date(record.startedAt!)}'),
        if (record.contentCompletedAt != null)
          (
            Icons.ondemand_video,
            'Watched ${_date(record.contentCompletedAt!)}',
          ),
        if (record.completedAt != null)
          (Icons.verified, 'Completed ${_date(record.completedAt!)}'),
        if (result != null)
          (
            Icons.quiz,
            'Quiz ${result.passed ? 'passed' : 'not passed'}'
                '${result.score != null && result.totalQuestions != null ? ' · ${result.score}/${result.totalQuestions}' : ''}',
          ),
      ],
    ];
    return _LessonCard(
      title: 'Your record',
      icon: Icons.history,
      color: color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (icon, text) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(icon, size: 18, color: AppColors.textSecondary),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(child: Text(text, style: AppTextStyles.bodyMedium)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A full-width action button; [outlined] for a secondary one.
class _PrimaryAction extends StatelessWidget {
  const _PrimaryAction({
    required this.label,
    required this.icon,
    required this.color,
    required this.onPressed,
    this.outlined = false,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback? onPressed;
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    const size = Size(double.infinity, AppSpacing.minTouchTarget);
    return outlined
        ? OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              minimumSize: size,
              foregroundColor: color,
            ),
            onPressed: onPressed,
            icon: Icon(icon),
            label: Text(label),
          )
        : ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              minimumSize: size,
              backgroundColor: color,
              foregroundColor: Colors.white,
            ),
            onPressed: onPressed,
            icon: Icon(icon),
            label: Text(label),
          );
  }
}

/// The lesson's overall stage, in the header.
class _ProgressBadge extends StatelessWidget {
  const _ProgressBadge({required this.progress});

  final LearningProgress progress;

  @override
  Widget build(BuildContext context) {
    final color = switch (progress.stage) {
      LearningStage.notStarted => AppColors.info,
      LearningStage.inProgress => AppColors.warning,
      LearningStage.quizOutstanding => AppColors.correctiveActions,
      LearningStage.completed => AppColors.success,
    };
    return StatusBadge(label: progress.stageLabel, color: color);
  }
}

/// "Done" / "To do" on a lesson step.
class _StepState extends StatelessWidget {
  const _StepState({required this.done});

  final bool done;

  @override
  Widget build(BuildContext context) => StatusBadge(
    label: done ? 'Done' : 'To do',
    color: done ? AppColors.success : AppColors.textSecondary,
  );
}

/// Whether the quiz is required, optional or a practice run.
class _QuizBadge extends StatelessWidget {
  const _QuizBadge({required this.mandatory, required this.practice});

  final bool mandatory;
  final bool practice;

  @override
  Widget build(BuildContext context) => StatusBadge(
    label: practice
        ? 'Practice'
        : mandatory
        ? 'Required'
        : 'Optional',
    color: mandatory && !practice
        ? AppColors.correctiveActions
        : AppColors.textSecondary,
  );
}

/// Each lesson type's accent color — the lesson screen's header, cards and
/// progress steps all use it.
Color _typeColor(SafetyLearningType type) => switch (type) {
  SafetyLearningType.video => AppColors.videos,
  SafetyLearningType.course => AppColors.learning,
  SafetyLearningType.visualGuide => AppColors.analytics,
  SafetyLearningType.document => AppColors.meetings,
  SafetyLearningType.knowledgeCheck => AppColors.correctiveActions,
};

IconData _typeIcon(SafetyLearningType type) => switch (type) {
  SafetyLearningType.video => Icons.play_circle_fill,
  SafetyLearningType.course => Icons.school,
  SafetyLearningType.visualGuide => Icons.image,
  SafetyLearningType.document => Icons.description,
  SafetyLearningType.knowledgeCheck => Icons.quiz,
};

/// The lesson's steps — Start → Watch → (Quiz) → Complete — with the ones
/// already done filled in.
class _LessonSteps extends StatelessWidget {
  const _LessonSteps({required this.steps, required this.color});

  final List<({String label, IconData icon, bool done})> steps;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final idle = Theme.of(context).colorScheme.outlineVariant;
    return Row(
      children: [
        for (final (index, step) in steps.indexed) ...[
          if (index > 0)
            Expanded(
              child: Container(
                height: 4,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: step.done ? color : idle,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: step.done ? color : idle,
                child: Icon(
                  step.icon,
                  size: 18,
                  color: step.done
                      ? AppColors.onColor(color)
                      : AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 4),
              Text(step.label, style: AppTextStyles.label),
            ],
          ),
        ],
      ],
    );
  }
}

/// A card section on the lesson screen with a colored title row.
class _LessonCard extends StatelessWidget {
  const _LessonCard({
    required this.title,
    required this.icon,
    required this.color,
    required this.child,
    this.trailing,
  });

  final String title;
  final IconData icon;
  final Color color;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: color.withValues(alpha: 0.45)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FeatureSectionTitle(
              title: title,
              icon: icon,
              color: color,
              trailing: trailing,
            ),
            const SizedBox(height: AppSpacing.sm),
            child,
          ],
        ),
      ),
    );
  }
}

/// Tells the worker why Complete is disabled and how much longer they need
/// to wait — the honest client-side reflection of the server's own minimum-
/// engagement-time gate (see `completeLearning`'s doc comment in
/// `functions/src/worker_learning_callable.ts`). Deliberately says "keep
/// this open," not "keep watching" or "keep reading": this confirms elapsed
/// time only, never actual playback or reading, and applies the same way to
/// any [SafetyLearningType].
/// Shows the last knowledge-check attempt's server-graded outcome — score
/// and pass/fail. A failed attempt is shown the same way a passed one is
/// (no error styling beyond the color), since it is an expected outcome the
/// worker can act on by retrying — see [CompleteLearningResult]'s doc
/// comment.
class _KnowledgeCheckResultBanner extends StatelessWidget {
  const _KnowledgeCheckResultBanner({
    required this.result,
    this.practice = false,
    this.canRetry = true,
  });

  final KnowledgeCheckResult result;

  /// An unrecorded practice run.
  final bool practice;

  /// Whether another attempt is possible from this screen.
  final bool canRetry;

  @override
  Widget build(BuildContext context) {
    final color = result.passed ? AppColors.success : AppColors.warning;
    final scoreText = result.score != null && result.totalQuestions != null
        ? '${result.score}/${result.totalQuestions} correct'
        : null;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppSpacing.sm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            result.passed ? Icons.check_circle_outline : Icons.replay_outlined,
            size: 16,
            color: color,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              '${practice ? 'Practice: ' : ''}'
              '${result.passed ? 'Knowledge check passed' : 'Knowledge check not yet passed'}'
              '${scoreText == null
                  ? ''
                  : result.passed
                  ? ' — $scoreText'
                  : ' ($scoreText)'}.'
              '${!result.passed && canRetry ? ' Take the quiz again when you are ready.' : ''}'
              '${practice ? ' Not recorded.' : ''}',
              style: AppTextStyles.bodyMedium.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _WatchTimeNotice extends StatelessWidget {
  const _WatchTimeNotice({required this.remaining});

  final Duration remaining;

  @override
  Widget build(BuildContext context) {
    final totalSeconds = remaining.inSeconds.clamp(0, 1 << 31);
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    final label = minutes > 0
        ? '$minutes:${seconds.toString().padLeft(2, '0')}'
        : '${seconds}s';
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppSpacing.sm),
      ),
      child: Row(
        children: [
          const Icon(Icons.timer_outlined, size: 16, color: AppColors.warning),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              'Keep this open for $label more before you can '
              'complete it.',
              style: AppTextStyles.bodyMedium.copyWith(
                color: AppColors.warning,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Explains a watch-only lesson: nothing here is recorded.
class _WatchOnlyNotice extends StatelessWidget {
  const _WatchOnlyNotice({required this.note});

  final String note;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.info.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppSpacing.sm),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.visibility_outlined,
            size: 18,
            color: AppColors.info,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(note, style: AppTextStyles.bodyMedium)),
        ],
      ),
    );
  }
}

/// A video lesson's content, chosen by its [VideoSource]. [status] is the
/// learner's progress, or null when watch-only — it only decides which
/// "come back to complete" hint an external video shows.
class _VideoContent extends StatelessWidget {
  const _VideoContent({
    required this.source,
    required this.status,
    required this.launcher,
    this.contentCompleted = false,
  });

  final ExternalLinkLauncher launcher;

  final VideoSource source;
  final WorkerLearningStatus? status;

  /// The video step is already recorded — no "come back" hint is needed.
  final bool contentCompleted;

  @override
  Widget build(BuildContext context) {
    final uri = source.uri;
    if (source.isUnsupported || uri == null) {
      return const _UnavailableNotice(
        message: 'This video is unavailable. Tell your supervisor.',
      );
    }
    if (source.playsInApp) {
      return _VideoPlayerContent(
        launcher: launcher,
        url: uri.toString(),
        fallbackLabel: source.openLabel,
        unavailableMessage: source.isJva
            ? 'This video is unavailable right now. Tell your supervisor.'
            : 'This video could not be played here.',
      );
    }
    // YouTube or Vimeo: opened outside the app, never in the file player.
    final provider = source.kind == VideoSourceKind.youtube
        ? 'YouTube'
        : 'Vimeo';
    final hint = switch (status) {
      _ when contentCompleted => null,
      WorkerLearningStatus.assigned =>
        'Tap Watch Video to start — it opens on $provider. Then come back '
            'here to record it.',
      WorkerLearningStatus.inProgress =>
        'When you have watched it on $provider, come back here and tap '
            "I've Watched the Video.",
      _ => null,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ContentLink(
          url: uri.toString(),
          color: AppColors.videos,
          label: source.openLabel,
          launcher: launcher,
        ),
        if (hint != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(hint, style: AppTextStyles.bodyMedium),
        ],
      ],
    );
  }
}

class _UnavailableNotice extends StatelessWidget {
  const _UnavailableNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.videocam_off, color: AppColors.textSecondary),
        const SizedBox(width: AppSpacing.sm),
        Expanded(child: Text(message, style: AppTextStyles.bodyMedium)),
      ],
    );
  }
}

/// A tappable content link, opened in the device's browser/viewer app via
/// [url_launcher] — used for every non-video learning item (document,
/// course, visual guide), for a YouTube/Vimeo video, and as the fallback
/// when a video can't be played in-app. Previously this was
/// `SelectableText`, which lets a worker copy the URL but never actually
/// open it — a worker who wasn't already comfortable manually pasting a URL
/// into a browser had no way to read the content at all. Falls back to a
/// plain (still copyable) text display with an error message if the url
/// can't be parsed or the launch fails, rather than silently doing nothing.
class _ContentLink extends StatefulWidget {
  const _ContentLink({
    required this.url,
    required this.color,
    required this.launcher,
    this.label = 'Open lesson',
  });

  final ExternalLinkLauncher launcher;

  final String url;
  final Color color;
  final String label;

  @override
  State<_ContentLink> createState() => _ContentLinkState();
}

class _ContentLinkState extends State<_ContentLink> {
  String? _launchError;

  /// Set while a launch is in flight, so a double tap opens the link once.
  bool _launching = false;

  Future<void> _open() async {
    if (_launching) return;
    _launching = true;
    setState(() => _launchError = null);
    var launched = false;
    try {
      final uri = Uri.tryParse(widget.url);
      launched = uri != null && await widget.launcher(uri);
    } on Object catch (e) {
      debugPrint('Learning: could not open a link: $e');
    } finally {
      _launching = false;
    }
    if (!launched && mounted) {
      setState(() => _launchError = 'Could not open this link.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: widget.color,
            foregroundColor: AppColors.onColor(widget.color),
          ),
          onPressed: _open,
          icon: const Icon(Icons.open_in_new),
          label: Text(widget.label),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          widget.url,
          style: AppTextStyles.label.copyWith(color: AppColors.textSecondary),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (_launchError != null) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            _launchError!,
            style: AppTextStyles.bodyMedium.copyWith(color: AppColors.danger),
          ),
        ],
      ],
    );
  }
}

/// Embeds [url] as an actual playing video using `video_player`, with
/// controls and a loading/error state — see [LearningDetailScreen]'s doc
/// comment for why no watch-time tracking is attempted here. Only ever given
/// a JVA video or a direct HTTPS video file (see [VideoSource.playsInApp]).
class _VideoPlayerContent extends StatefulWidget {
  const _VideoPlayerContent({
    required this.url,
    required this.fallbackLabel,
    required this.unavailableMessage,
    required this.launcher,
  });

  final ExternalLinkLauncher launcher;

  final String url;

  /// The fallback link's button label when playback fails.
  final String fallbackLabel;

  /// Shown instead of a blank player when playback fails.
  final String unavailableMessage;

  @override
  State<_VideoPlayerContent> createState() => _VideoPlayerContentState();
}

class _VideoPlayerContentState extends State<_VideoPlayerContent> {
  late final VideoPlayerController _controller =
      VideoPlayerController.networkUrl(Uri.parse(widget.url));
  late final Future<void> _initialization = _controller.initialize();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _initialization,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          // Falls back to the plain link so the worker can still open the
          // content elsewhere if in-app playback fails (e.g. an
          // unsupported codec or a CORS-blocked host on web).
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _UnavailableNotice(message: widget.unavailableMessage),
              const SizedBox(height: AppSpacing.xs),
              _ContentLink(
                url: widget.url,
                color: AppColors.videos,
                label: widget.fallbackLabel,
                launcher: widget.launcher,
              ),
            ],
          );
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return AspectRatio(
          aspectRatio: _controller.value.aspectRatio == 0
              ? 16 / 9
              : _controller.value.aspectRatio,
          child: Stack(
            alignment: Alignment.center,
            children: [
              VideoPlayer(_controller),
              VideoProgressIndicator(_controller, allowScrubbing: true),
              _PlayPauseButton(controller: _controller),
            ],
          ),
        );
      },
    );
  }
}

class _PlayPauseButton extends StatefulWidget {
  const _PlayPauseButton({required this.controller});

  final VideoPlayerController controller;

  @override
  State<_PlayPauseButton> createState() => _PlayPauseButtonState();
}

class _PlayPauseButtonState extends State<_PlayPauseButton> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final isPlaying = widget.controller.value.isPlaying;
    return IconButton(
      iconSize: 56,
      color: Colors.white,
      icon: Icon(isPlaying ? Icons.pause_circle : Icons.play_circle),
      onPressed: () {
        setState(() {
          if (isPlaying) {
            widget.controller.pause();
          } else {
            widget.controller.play();
          }
        });
      },
    );
  }
}

/// The plain confirmation shown for an item with NO knowledge check
/// configured — unchanged from before this phase. An item WITH questions
/// goes through [_KnowledgeCheckDialog] instead; see
/// [_LearningDetailScreenState._completeLearning]'s "ZERO QUESTIONS -> NO
/// GATE" branch.
class _CompleteLearningDialog extends StatelessWidget {
  const _CompleteLearningDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Complete Learning'),
      content: const Text('Mark this learning item as completed?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Submit'),
        ),
      ],
    );
  }
}

/// Presents every configured knowledge-check question with its
/// multiple-choice options and lets the worker select one answer per
/// question before submitting. Pops the selected [SubmittedAnswer] list for
/// [_LearningDetailScreenState._completeLearning] to send to the server —
/// nothing about correctness is computed or known here; this dialog only
/// collects a selection per question.
class _KnowledgeCheckDialog extends StatefulWidget {
  const _KnowledgeCheckDialog({required this.questions});

  final List<KnowledgeCheckQuestion> questions;

  @override
  State<_KnowledgeCheckDialog> createState() => _KnowledgeCheckDialogState();
}

class _KnowledgeCheckDialogState extends State<_KnowledgeCheckDialog> {
  final Map<String, String> _selectedOptionByQuestionId = {};

  bool get _allAnswered =>
      _selectedOptionByQuestionId.length == widget.questions.length;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Knowledge Check'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final question in widget.questions) ...[
                Text(question.prompt, style: AppTextStyles.titleLarge),
                const SizedBox(height: AppSpacing.xs),
                ChoiceList<String>(
                  items: [
                    for (final (index, option) in question.options.indexed)
                      ChoiceItem(
                        value: option.id,
                        title: option.text,
                        badge: String.fromCharCode(65 + index),
                      ),
                  ],
                  selected: _selectedOptionByQuestionId[question.id],
                  // Quiz answers are never searched, however many.
                  searchThreshold: 1 << 30,
                  onChanged: (value) => setState(() {
                    if (value == null) {
                      _selectedOptionByQuestionId.remove(question.id);
                    } else {
                      _selectedOptionByQuestionId[question.id] = value;
                    }
                  }),
                ),
                const SizedBox(height: AppSpacing.md),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _allAnswered
              ? () => Navigator.of(context).pop([
                  for (final entry in _selectedOptionByQuestionId.entries)
                    SubmittedAnswer(
                      questionId: entry.key,
                      optionId: entry.value,
                    ),
                ])
              : null,
          child: const Text('Submit'),
        ),
      ],
    );
  }
}
