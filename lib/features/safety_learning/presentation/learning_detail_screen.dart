import 'dart:async';
import '../../../core/widgets/choice_list.dart';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import '../../../core/widgets/feature_header.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../data/worker_learning_service.dart';
import '../domain/complete_learning_result.dart';
import '../domain/knowledge_check_question.dart';
import '../domain/knowledge_check_result.dart';
import '../domain/safety_learning.dart';
import '../domain/safety_learning_type.dart';
import '../domain/submitted_answer.dart';
import '../domain/worker_learning_record.dart';
import '../domain/worker_learning_status.dart';

/// The detail screen for one required learning item, reached via a plain
/// `Navigator.push` from [MySafetyLearningScreen] — this codebase does not
/// use go_router path parameters anywhere, so a new detail route is not
/// introduced here for consistency.
///
/// Shows the learning content. For [SafetyLearningType.video], an actual
/// in-app video player is embedded (see [_VideoPlayerContent]) when
/// `contentReference` looks like a direct playable media URL. Every other
/// content reference (and any video URL that isn't obviously a direct media
/// file, e.g. a YouTube page) opens externally via [_ContentLink] — no
/// rendering pipeline. The worker's own progress is shown alongside, with
/// the one action available at each status:
///  - [WorkerLearningStatus.assigned]: "Start Learning" -> `startLearning`.
///  - [WorkerLearningStatus.inProgress]: "Complete Learning" -> requests
///    `completeLearning`, which is the sole SERVER-AUTHORITATIVE gate. The
///    dialog shown depends on what the item is actually configured with,
///    never on its [SafetyLearningType] alone:
///      * zero configured knowledge-check questions -> a plain "mark as
///        completed?" confirmation ([_CompleteLearningDialog]).
///      * one or more configured questions (regardless of type, including
///        `video`) -> [_KnowledgeCheckDialog], fetched fresh from
///        `getKnowledgeCheckQuestions` (never containing `correctOptionId`
///        — see that callable's own doc comment). The server grades the
///        submission and returns the authoritative pass/fail; a failed
///        attempt is shown via [_KnowledgeCheckResultBanner] and the record
///        stays `inProgress` so the worker can retry indefinitely.
///    Independently, when [SafetyLearning.minimumWatchSeconds] is positive
///    (any type, not just video), Complete is disabled client-side until
///    that many seconds have elapsed since `startedAt` — see
///    [_minimumWatchSeconds]/[_remainingWatchTime]. This is UX only: the
///    server enforces the same requirement independently and is the only
///    authority on whether completion actually succeeds.
///  - [WorkerLearningStatus.completed]: read-only completion summary.
///
/// Both callables derive the acting worker from the caller's own auth token
/// server-side — see [WorkerLearningService]'s doc comment — so this screen
/// never sends a worker identifier of any kind.
class LearningDetailScreen extends StatefulWidget {
  const LearningDetailScreen({
    required this.organizationId,
    required this.learning,
    required this.record,
    super.key,
    this.workerLearningService,
  });

  final String organizationId;
  final SafetyLearning learning;
  final WorkerLearningRecord record;

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real service.
  final WorkerLearningService? workerLearningService;

  @override
  State<LearningDetailScreen> createState() => _LearningDetailScreenState();
}

class _LearningDetailScreenState extends State<LearningDetailScreen> {
  late final WorkerLearningService _service =
      widget.workerLearningService ?? WorkerLearningService();

  WorkerLearningStatus? _localStatus;
  DateTime? _localCompletedAt;
  DateTime? _localStartedAt;
  String? _errorMessage;
  bool _isSaving = false;
  Timer? _countdownTimer;

  /// The last graded knowledge-check outcome — shown after a submission,
  /// whether it passed or not. A failed attempt is an expected result, not
  /// an error: see [CompleteLearningResult]'s doc comment.
  KnowledgeCheckResult? _lastKnowledgeCheckResult;

  WorkerLearningStatus get _status => _localStatus ?? widget.record.status;
  DateTime? get _completedAt => _localCompletedAt ?? widget.record.completedAt;
  DateTime? get _startedAt => _localStartedAt ?? widget.record.startedAt;

  /// Whether this item is subject to the minimum-engagement-time gate at
  /// all — applies to any [SafetyLearningType], not just
  /// [SafetyLearningType.video]; see `completeLearning`'s doc comment
  /// (`functions/src/worker_learning_callable.ts`) for the mechanism this
  /// mirrors client-side for display only. The server independently
  /// enforces this regardless of what this getter or [_remainingWatchTime]
  /// compute; a stale/wrong client clock only ever makes the button
  /// temporarily too strict or too lax, never the actual completion.
  int get _minimumWatchSeconds => widget.learning.minimumWatchSeconds ?? 0;

  /// Seconds still remaining before the server will accept completion, or
  /// null once the requirement is satisfied (or doesn't apply). Purely a
  /// client-side ESTIMATE from [_startedAt] — a real server timestamp, but
  /// read here without any guarantee the device clock agrees with the
  /// server's; that possible drift is why the server, not this value, is
  /// the actual authority (see `_minimumWatchSeconds`'s doc comment).
  Duration? get _remainingWatchTime {
    final minimum = _minimumWatchSeconds;
    if (minimum <= 0) return null;
    final startedAt = _startedAt;
    if (startedAt == null) return Duration(seconds: minimum);
    final elapsed = DateTime.now().difference(startedAt);
    final remaining = Duration(seconds: minimum) - elapsed;
    return remaining.isNegative ? null : remaining;
  }

  @override
  void initState() {
    super.initState();
    if (_minimumWatchSeconds > 0) {
      _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  Future<void> _startLearning() async {
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });
    try {
      await _service.startLearning(
        organizationId: widget.organizationId,
        learningId: widget.learning.id,
      );
      if (!mounted) return;
      setState(() {
        _localStatus = WorkerLearningStatus.inProgress;
        _localStartedAt = DateTime.now();
      });
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// Fetches this item's knowledge-check questions once and caches the
  /// result for this screen's lifetime — the questions never change while a
  /// worker is on this screen, and re-fetching per tap would just add
  /// latency to every attempt.
  Future<List<KnowledgeCheckQuestion>>? _questionsFuture;

  Future<List<KnowledgeCheckQuestion>> _loadQuestions() {
    return _questionsFuture ??= _service.getKnowledgeCheckQuestions(
      organizationId: widget.organizationId,
      learningId: widget.learning.id,
    );
  }

  Future<void> _completeLearning() async {
    final List<KnowledgeCheckQuestion> questions;
    try {
      questions = await _loadQuestions();
    } on AppException catch (e) {
      // Previously unhandled: a failure here (e.g. the server's
      // `getKnowledgeCheckQuestions` refusing because this item no longer
      // reads as "currently required" — see that callable's own
      // `resolveRequiredLearning` check) silently did nothing, which looked
      // exactly like "the questions never showed" with no explanation at
      // all. Surfacing it here lets the worker see why, instead of a
      // Complete Learning tap that appears to do nothing.
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
      // Clear the cached failed future so a retry actually re-fetches
      // rather than replaying the same rejected Future forever.
      _questionsFuture = null;
      return;
    }
    if (!mounted) return;

    // ZERO QUESTIONS -> NO GATE: matches the server's own rule exactly (see
    // `completeLearning`'s doc comment, `worker_learning_callable.ts`) — an
    // item with no configured questions falls back to the original plain
    // confirmation, never a quiz UI with nothing to show.
    if (questions.isEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => const _CompleteLearningDialog(),
      );
      if (confirmed != true || !mounted) return;
      await _submitCompletion(selectedAnswers: null);
      return;
    }

    final answers = await showDialog<List<SubmittedAnswer>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _KnowledgeCheckDialog(questions: questions),
    );
    if (answers == null || !mounted) return;
    await _submitCompletion(selectedAnswers: answers);
  }

  Future<void> _submitCompletion({
    required List<SubmittedAnswer>? selectedAnswers,
  }) async {
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });
    try {
      final result = await _service.completeLearning(
        organizationId: widget.organizationId,
        learningId: widget.learning.id,
        selectedAnswers: selectedAnswers,
      );
      if (!mounted) return;
      setState(() {
        _lastKnowledgeCheckResult = result.knowledgeCheckResult;
        if (result.status == WorkerLearningStatus.completed) {
          _localStatus = WorkerLearningStatus.completed;
          _localCompletedAt = DateTime.now();
        }
        // A failed knowledge check leaves status unchanged (still
        // assigned/inProgress) — the result banner below shows the score
        // and the worker may tap Complete again to retry, matching the
        // "no retry limit in this phase" decision.
      });
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final learning = widget.learning;
    final color = _typeColor(learning.type);
    return Scaffold(
      appBar: AppBar(),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          FeatureHeader(
            eyebrow: learning.type.label,
            title: learning.title,
            icon: _typeIcon(learning.type),
            color: color,
            trailing: _StatusBadge(status: _status),
          ),
          const SizedBox(height: AppSpacing.md),
          _LessonSteps(status: _status, color: color),
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
          _LessonCard(
            title: 'Lesson content',
            icon: _typeIcon(learning.type),
            color: color,
            child:
                learning.type == SafetyLearningType.video &&
                    _looksLikeDirectVideoUrl(learning.contentReference)
                ? _VideoPlayerContent(url: learning.contentReference)
                : _ContentLink(url: learning.contentReference, color: color),
          ),
          const SizedBox(height: AppSpacing.lg),
          if (_errorMessage != null) ...[
            AuthErrorBanner(message: _errorMessage!),
            const SizedBox(height: AppSpacing.md),
          ],
          if (_status == WorkerLearningStatus.assigned)
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.go,
                foregroundColor: Colors.white,
              ),
              onPressed: _isSaving ? null : _startLearning,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Start Learning'),
            ),
          if (_lastKnowledgeCheckResult != null) ...[
            _KnowledgeCheckResultBanner(result: _lastKnowledgeCheckResult!),
            const SizedBox(height: AppSpacing.sm),
          ],
          if (_status == WorkerLearningStatus.inProgress) ...[
            if (_remainingWatchTime != null) ...[
              _WatchTimeNotice(remaining: _remainingWatchTime!),
              const SizedBox(height: AppSpacing.sm),
            ],
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.learning,
                foregroundColor: Colors.white,
              ),
              onPressed: _isSaving || _remainingWatchTime != null
                  ? null
                  : _completeLearning,
              icon: const Icon(Icons.check_circle),
              label: const Text('Complete Learning'),
            ),
          ],
          if (_status == WorkerLearningStatus.completed)
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
        ],
      ),
    );
  }
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

/// Start → Learn → Complete, with the steps already done filled in.
class _LessonSteps extends StatelessWidget {
  const _LessonSteps({required this.status, required this.color});

  final WorkerLearningStatus status;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final reached = switch (status) {
      WorkerLearningStatus.assigned => 0,
      WorkerLearningStatus.inProgress => 2,
      WorkerLearningStatus.completed => 3,
    };
    const steps = [
      (label: 'Start', icon: Icons.play_arrow),
      (label: 'Learn', icon: Icons.menu_book),
      (label: 'Complete', icon: Icons.check),
    ];
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
                  color: index < reached ? color : idle,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: index < reached ? color : idle,
                child: Icon(
                  step.icon,
                  size: 18,
                  color: index < reached
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
  });

  final String title;
  final IconData icon;
  final Color color;
  final Widget child;

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
            FeatureSectionTitle(title: title, icon: icon, color: color),
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
  const _KnowledgeCheckResultBanner({required this.result});

  final KnowledgeCheckResult result;

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
              result.passed
                  ? 'Knowledge check passed'
                        '${scoreText != null ? ' — $scoreText' : ''}.'
                  : 'Knowledge check not yet passed'
                        '${scoreText != null ? ' ($scoreText)' : ''}. '
                        'Tap Complete Learning to try again.',
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

/// Whether [url] looks like a direct playable media file rather than a page
/// that merely links to a video (e.g. a YouTube watch page) — a common
/// video-hosting file extension, or a Firebase Storage download URL for one.
/// This is a display heuristic only: a false negative just falls back to the
/// existing plain-link rendering, never breaking anything; a false positive
/// would show a player that fails to load, which [_VideoPlayerContent]
/// itself already handles via its own error state.
/// A tappable content link, opened in the device's browser/viewer app via
/// [url_launcher] — used for every non-video learning item (document,
/// course, visual guide) and as the fallback when a video can't be played
/// in-app. Previously this was `SelectableText`, which lets a worker copy
/// the URL but never actually open it — a worker who wasn't already
/// comfortable manually pasting a URL into a browser had no way to read the
/// content at all. Falls back to a plain (still copyable) text display with
/// an error message if the url can't be parsed or the launch fails, rather
/// than silently doing nothing.
class _ContentLink extends StatefulWidget {
  const _ContentLink({required this.url, required this.color});

  final String url;
  final Color color;

  @override
  State<_ContentLink> createState() => _ContentLinkState();
}

class _ContentLinkState extends State<_ContentLink> {
  String? _launchError;

  Future<void> _open() async {
    setState(() => _launchError = null);
    final uri = Uri.tryParse(widget.url);
    final launched =
        uri != null &&
        await launchUrl(uri, mode: LaunchMode.externalApplication);
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
          label: const Text('Open lesson'),
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

bool _looksLikeDirectVideoUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) return false;
  const videoExtensions = ['.mp4', '.mov', '.m4v', '.webm'];
  final path = uri.path.toLowerCase();
  return videoExtensions.any(path.endsWith);
}

/// Embeds [url] as an actual playing video using `video_player`, with
/// controls and a loading/error state — see [LearningDetailScreen]'s doc
/// comment for why no watch-time tracking is attempted here.
class _VideoPlayerContent extends StatefulWidget {
  const _VideoPlayerContent({required this.url});

  final String url;

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
              const Text(
                'This video could not be played here.',
                style: AppTextStyles.bodyMedium,
              ),
              const SizedBox(height: AppSpacing.xs),
              _ContentLink(url: widget.url, color: AppColors.videos),
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

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final WorkerLearningStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      WorkerLearningStatus.assigned => AppColors.textSecondary,
      WorkerLearningStatus.inProgress => AppColors.warning,
      WorkerLearningStatus.completed => AppColors.success,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white, width: 1.5),
      ),
      child: Text(
        status.label,
        style: AppTextStyles.label.copyWith(color: AppColors.onColor(color)),
      ),
    );
  }
}
