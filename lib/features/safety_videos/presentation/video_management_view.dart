import 'package:flutter/material.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/color_choice_chips.dart';
import '../../../core/widgets/empty_state.dart';
import '../../../core/widgets/feature_header.dart';
import '../../../core/widgets/live_stream_builder.dart';
import '../../../core/widgets/status_badge.dart';
import '../../organizations/domain/organization_record_status.dart';
import '../../safety_learning/data/safety_learning_admin_service.dart';
import '../../safety_learning/domain/safety_learning.dart';
import '../../safety_learning/domain/safety_learning_type.dart';
import '../../safety_learning/domain/video_source.dart';
import '../../safety_requirements/data/safety_requirement_repository.dart';
import '../../safety_requirements/domain/safety_requirement.dart';
import 'safety_videos_screen.dart' show VideoThumbnailTile;

enum _StatusFilter { all, active, inactive }

enum _QuizFilter { any, withQuiz, withoutQuiz }

enum _RequirementFilter { any, required, general }

/// Safety Videos for the people who manage them — a platform Admin, or a
/// Site Manager of the organization (`AppRole.canAuthorSafetyVideos`,
/// enforced server-side by `requireLibraryAuthor`).
///
/// It manages CONTENT: add, edit, (de)activate a video and its quiz. Who
/// must watch a video is never set here — only Safety Requirements make a
/// video mandatory, and each card says how many active requirements list
/// it. Every number on the page is computed from loaded data: the quiz
/// counts come from `getVideoQuizSummary` (the same saved questions the
/// quiz editor lists) and each card shows a [QuizCount] — never zero unless
/// the server counted zero.
class VideoManagementView extends StatefulWidget {
  const VideoManagementView({
    super.key,
    required this.organizationId,
    required this.items,
    required this.storageBucket,
    required this.requirementRepository,
    required this.adminService,
    required this.onAddVideo,
    required this.onEdit,
    required this.onManageQuiz,
    required this.onOpen,
  });

  final String organizationId;

  /// Every learning item in the organization (only videos are shown).
  final List<SafetyLearning> items;
  final String? storageBucket;
  final SafetyRequirementRepository requirementRepository;
  final SafetyLearningAdminService adminService;
  final Future<void> Function() onAddVideo;
  final Future<void> Function(SafetyLearning video) onEdit;
  final Future<void> Function(SafetyLearning video) onManageQuiz;
  final Future<void> Function(SafetyLearning video) onOpen;

  @override
  State<VideoManagementView> createState() => _VideoManagementViewState();
}

/// One card's quiz count, as far as the page knows it.
sealed class QuizCount {
  const QuizCount();
}

/// The count is being fetched.
class QuizCountLoading extends QuizCount {
  const QuizCountLoading();
}

/// The server counted [questions] saved questions (0 = no quiz).
class QuizCountKnown extends QuizCount {
  const QuizCountKnown(this.questions);
  final int questions;
}

/// The count request failed; [needsServerUpdate] when the server does not
/// have the counting function yet.
class QuizCountUnavailable extends QuizCount {
  const QuizCountUnavailable(this.message, {this.needsServerUpdate = false});
  final String message;
  final bool needsServerUpdate;
}

/// The request succeeded but this video was not in the answer — for
/// example it was added after the counts were fetched, or its data does not
/// match what the server counts.
class QuizCountMissing extends QuizCount {
  const QuizCountMissing();
}

class _VideoManagementViewState extends State<VideoManagementView> {
  final _search = TextEditingController();
  _StatusFilter _status = _StatusFilter.all;
  _QuizFilter _quiz = _QuizFilter.any;
  _RequirementFilter _requirement = _RequirementFilter.any;
  int _requirementsAttempt = 0;

  /// The last successful answer; null while loading or after a failure.
  Map<String, int>? _quizCounts;
  QuizCountUnavailable? _quizCountsError;
  bool _quizCountsLoading = true;
  int _quizCountsRequest = 0;

  @override
  void initState() {
    super.initState();
    _loadQuizCounts();
  }

  /// Fetches the counts; a newer request always wins over an older one.
  Future<void> _loadQuizCounts() async {
    final request = ++_quizCountsRequest;
    try {
      final counts = await widget.adminService.getVideoQuizSummary(
        organizationId: widget.organizationId,
      );
      if (!mounted || request != _quizCountsRequest) return;
      final missing = [
        for (final video in _videos)
          if (!counts.containsKey(video.id)) video.id,
      ];
      if (missing.isNotEmpty) {
        debugPrint(
          'Safety Videos: quiz counts missing for ${missing.join(', ')}',
        );
      }
      setState(() {
        _quizCounts = counts;
        _quizCountsError = null;
        _quizCountsLoading = false;
      });
    } on Object catch (e) {
      debugPrint('Safety Videos: could not load quiz counts: $e');
      if (!mounted || request != _quizCountsRequest) return;
      setState(() {
        _quizCounts = null;
        _quizCountsError = switch (e) {
          ServerUpdateRequiredException(:final message) => QuizCountUnavailable(
            message,
            needsServerUpdate: true,
          ),
          AppException(:final message) => QuizCountUnavailable(message),
          _ => const QuizCountUnavailable(
            'Quiz counts could not be loaded. Try again.',
          ),
        };
        _quizCountsLoading = false;
      });
    }
  }

  void _reloadQuizCounts() {
    setState(() => _quizCountsLoading = true);
    _loadQuizCounts();
  }

  /// Videos already re-counted because they were missing — so a video the
  /// server genuinely leaves out is fetched once, not in a loop.
  final Set<String> _recountedIds = {};

  @override
  void didUpdateWidget(VideoManagementView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A video that arrived after the counts were fetched (just added) is
    // counted again rather than shown as missing.
    final counts = _quizCounts;
    if (_quizCountsLoading || counts == null) return;
    final unseen = [
      for (final video in _videos)
        if (!counts.containsKey(video.id) && !_recountedIds.contains(video.id))
          video.id,
    ];
    if (unseen.isEmpty) return;
    _recountedIds.addAll(unseen);
    _quizCountsLoading = true;
    _loadQuizCounts();
  }

  /// What one card shows — see [QuizCount].
  QuizCount _countFor(SafetyLearning video) {
    if (_quizCountsLoading) return const QuizCountLoading();
    final error = _quizCountsError;
    if (error != null) return error;
    final count = _quizCounts?[video.id];
    return count == null ? const QuizCountMissing() : QuizCountKnown(count);
  }

  /// Runs an action that may change quiz counts, then refreshes them.
  Future<void> _thenRefresh(Future<void> Function() action) async {
    await action();
    if (mounted) _reloadQuizCounts();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<SafetyLearning> get _videos {
    final videos = [
      for (final item in widget.items)
        if (item.type == SafetyLearningType.video) item,
    ];
    videos.sort(
      (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
    );
    return videos;
  }

  bool _matches(
    SafetyLearning video,
    bool quizFilterAvailable,
    Map<String, int>? usage,
  ) {
    final query = _search.text.trim().toLowerCase();
    if (query.isNotEmpty &&
        !video.title.toLowerCase().contains(query) &&
        !(video.description ?? '').toLowerCase().contains(query)) {
      return false;
    }
    final active = video.status == OrganizationRecordStatus.active;
    if (_status == _StatusFilter.active && !active) return false;
    if (_status == _StatusFilter.inactive && active) return false;
    if (_quiz != _QuizFilter.any && quizFilterAvailable) {
      // A video without a confirmed count matches neither quiz filter.
      final count = _countFor(video);
      if (count is! QuizCountKnown) return false;
      final hasQuiz = count.questions > 0;
      if (_quiz == _QuizFilter.withQuiz && !hasQuiz) return false;
      if (_quiz == _QuizFilter.withoutQuiz && hasQuiz) return false;
    }
    // Only from confirmed requirement data; hidden while it is unknown.
    if (_requirement != _RequirementFilter.any && usage != null) {
      final required = (usage[video.id] ?? 0) > 0;
      if (_requirement == _RequirementFilter.required && !required) {
        return false;
      }
      if (_requirement == _RequirementFilter.general && required) return false;
    }
    return true;
  }

  void _clearFilters() => setState(() {
    _search.clear();
    _status = _StatusFilter.all;
    _quiz = _QuizFilter.any;
    _requirement = _RequirementFilter.any;
  });

  @override
  Widget build(BuildContext context) {
    final videos = _videos;
    final activeCount = videos
        .where((v) => v.status == OrganizationRecordStatus.active)
        .length;
    final counts = {for (final video in videos) video.id: _countFor(video)};
    final quizFilterAvailable = _quizCounts != null && !_quizCountsLoading;
    final quizError = _quizCountsLoading ? null : _quizCountsError;
    // Only when every video has a confirmed count — never a partial total.
    final allKnown = counts.values.every((c) => c is QuizCountKnown);
    final withQuiz = counts.values
        .where((c) => c is QuizCountKnown && c.questions > 0)
        .length;
    return Builder(
      builder: (context) {
        return LiveStreamBuilder<List<SafetyRequirement>>(
          streamKey: (widget.organizationId, _requirementsAttempt),
          stream: () => widget.requirementRepository.watchAll(),
          builder: (context, requirementsSnapshot) {
            final usedBy = requirementsSnapshot.hasError
                ? null
                : _activeRequirementsByVideo(requirementsSnapshot.data);
            final usage = usedBy == null
                ? null
                : {for (final e in usedBy.entries) e.key: e.value.length};
            final shown = [
              for (final video in videos)
                if (_matches(video, quizFilterAvailable, usage)) video,
            ];
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(AppSpacing.md),
              children: [
                FeatureHeader(
                  title: 'Safety Videos',
                  subtitle:
                      'Manage video-based safety learning: add and update '
                      'videos and their quizzes. Who must watch a video is '
                      'set in Safety Requirements.',
                  icon: Icons.video_library,
                  color: AppColors.videos,
                  chips: [
                    FeatureChip(
                      icon: Icons.video_library_outlined,
                      label:
                          '${videos.length} '
                          '${videos.length == 1 ? 'video' : 'videos'}',
                    ),
                    FeatureChip(
                      icon: Icons.check_circle_outline,
                      label: '$activeCount active',
                    ),
                    if (quizFilterAvailable && allKnown)
                      FeatureChip(
                        icon: Icons.quiz_outlined,
                        label: '$withQuiz with a quiz',
                      ),
                  ],
                  footer: _AddVideoButton(
                    onPressed: () => _thenRefresh(widget.onAddVideo),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                if (quizError != null) ...[
                  _InlineRetry(
                    message: quizError.needsServerUpdate
                        ? '${quizError.message} The quiz filter is off '
                              'until then.'
                        : 'Quiz counts are unavailable right now, so the '
                              'quiz filter is off. ${quizError.message}',
                    onRetry: _reloadQuizCounts,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],
                if (requirementsSnapshot.hasError) ...[
                  _InlineRetry(
                    message:
                        'Couldn\'t check which requirements use each video.',
                    onRetry: () => setState(() => _requirementsAttempt++),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],
                if (videos.isEmpty)
                  EmptyState(
                    icon: Icons.video_library_outlined,
                    title: 'No safety videos yet',
                    message:
                        'Add a JVA video or a YouTube, Vimeo or direct video '
                        'link. Make it mandatory in Safety Requirements.',
                    action: _AddVideoButton(
                      onPressed: () => _thenRefresh(widget.onAddVideo),
                    ),
                  )
                else ...[
                  _Toolbar(
                    search: _search,
                    status: _status,
                    quiz: _quiz,
                    quizFilterAvailable: quizFilterAvailable,
                    requirement: _requirement,
                    requirementFilterAvailable: usage != null,
                    onChanged: () => setState(() {}),
                    onStatus: (value) => setState(() => _status = value),
                    onQuiz: (value) => setState(() => _quiz = value),
                    onRequirement: (value) =>
                        setState(() => _requirement = value),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  if (shown.isEmpty)
                    EmptyState(
                      icon: Icons.filter_alt_off_outlined,
                      title: 'No videos match',
                      message: 'Try another search or filter.',
                      action: OutlinedButton(
                        onPressed: _clearFilters,
                        child: const Text('Clear filters'),
                      ),
                    )
                  else
                    _ManagedGrid(
                      videos: shown,
                      quizCounts: counts,
                      onRetryQuizCount: _reloadQuizCounts,
                      usage: usage,
                      sourceOf: (video) => VideoSource.classify(
                        video.contentReference,
                        organizationId: widget.organizationId,
                        storageBucket: widget.storageBucket,
                      ),
                      onOpen: widget.onOpen,
                      onEdit: (video) =>
                          _thenRefresh(() => widget.onEdit(video)),
                      onManageQuiz: (video) =>
                          _thenRefresh(() => widget.onManageQuiz(video)),
                      changingStatus: _changingStatus,
                      onSetActive: (video, active) => _setActive(
                        video,
                        active: active,
                        // Null: not known (loading, or the check
                        // failed) — never treated as "none".
                        requirementNames: usedBy == null
                            ? null
                            : usedBy[video.id] ?? const [],
                      ),
                      onDelete: _delete,
                    ),
                ],
              ],
            );
          },
        );
      },
    );
  }

  /// Permanently deletes [video] after a confirmation naming it. The server
  /// (`deleteSafetyLearning`) decides: it refuses — with the reason — when
  /// any learner has a record for the video or any Safety Requirement lists
  /// it, and when it cannot complete that check. Nothing is deleted then.
  Future<void> _delete(SafetyLearning video) async {
    if (_changingStatus.contains(video.id)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.delete_forever, color: AppColors.danger),
        title: const Text('Delete this video permanently?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              video.title,
              style: AppTextStyles.titleLarge,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: AppSpacing.sm),
            const Text(
              'The video, its quiz questions and its uploaded file are '
              'removed for good. This is only allowed when no learner has a '
              'record for it and no Safety Requirement lists it — otherwise '
              'deactivate it instead, which keeps everyone\'s history.',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete permanently'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _changingStatus.add(video.id));
    String message;
    try {
      final fileDeleted = await widget.adminService.deleteSafetyLearning(
        organizationId: widget.organizationId,
        id: video.id,
      );
      message = fileDeleted
          ? 'Deleted "${video.title}".'
          : 'Deleted "${video.title}". Its uploaded file could not be '
                'removed — it is no longer used.';
      _reloadQuizCounts();
    } on NetworkException catch (e) {
      debugPrint('Safety Videos: could not delete a video: ${e.message}');
      message =
          'Couldn\'t check whether this video is still used, so nothing '
          'was deleted. Try again.';
    } on AppException catch (e) {
      debugPrint('Safety Videos: could not delete a video: ${e.message}');
      message = e.message;
    } on Object catch (e) {
      debugPrint('Safety Videos: could not delete a video: $e');
      message = 'Nothing was deleted. Try again.';
    } finally {
      if (mounted) setState(() => _changingStatus.remove(video.id));
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 6)),
    );
  }

  /// Videos whose status change is being saved — a double tap saves once.
  final Set<String> _changingStatus = {};

  /// Activate or deactivate [video] after a confirmation. Deactivating
  /// takes it out of the learner library and out of every requirement's
  /// obligations; completion records already made are kept.
  Future<void> _setActive(
    SafetyLearning video, {
    required bool active,
    required List<String>? requirementNames,
  }) async {
    if (_changingStatus.contains(video.id)) return;
    // A video an ACTIVE requirement lists cannot be deactivated (the server
    // refuses too); without a confirmed answer it is not tried at all.
    if (!active) {
      final usedBy = requirementNames;
      if (usedBy == null || usedBy.isNotEmpty) {
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Can\'t deactivate this video'),
            content: Text(
              usedBy == null
                  ? 'We couldn\'t check which Safety Requirements use '
                        '"${video.title}". Try again once they have loaded.'
                  : '"${video.title}" is required by '
                        '${usedBy.length == 1 ? 'this active Safety '
                                  'Requirement' : 'these active Safety '
                                  'Requirements'}: ${usedBy.join(', ')}. '
                        'Remove it from ${usedBy.length == 1 ? 'that '
                                  'requirement' : 'those requirements'} '
                        '(or deactivate ${usedBy.length == 1 ? 'it' : 'them'})'
                        ' in Safety Requirements first.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
        return;
      }
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(active ? 'Activate this video?' : 'Deactivate this video?'),
        content: Text(
          active
              ? 'Workers and Foremen will see "${video.title}" in Safety '
                    'Videos again, and any requirement that lists it will '
                    'make it required again.'
              : 'Workers and Foremen will no longer see "${video.title}" '
                    'in Safety Videos, and it can\'t be opened for new '
                    'learning. Completion records already made are kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(active ? 'Activate' : 'Deactivate'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _changingStatus.add(video.id));
    try {
      await widget.adminService.updateSafetyLearning(
        widget.organizationId,
        video.id,
        status: active
            ? OrganizationRecordStatus.active
            : OrganizationRecordStatus.inactive,
      );
    } on Object catch (e) {
      debugPrint('Safety Videos: could not change a video\'s status: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e is AppException
                  ? e.message
                  : 'Could not change the video. Try again.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _changingStatus.remove(video.id));
    }
  }

  /// The names of the ACTIVE requirements listing each video; null while
  /// loading.
  static Map<String, List<String>>? _activeRequirementsByVideo(
    List<SafetyRequirement>? data,
  ) {
    if (data == null) return null;
    final usedBy = <String, List<String>>{};
    for (final requirement in data) {
      if (requirement.status != OrganizationRecordStatus.active) continue;
      for (final id in requirement.requiredLearningIds.toSet()) {
        (usedBy[id] ??= []).add(requirement.name);
      }
    }
    return usedBy;
  }
}

class _AddVideoButton extends StatelessWidget {
  const _AddVideoButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.videos,
        minimumSize: const Size(0, AppSpacing.minTouchTarget),
      ),
      onPressed: onPressed,
      icon: const Icon(Icons.add),
      label: const Text('Add video'),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.search,
    required this.status,
    required this.quiz,
    required this.quizFilterAvailable,
    required this.requirement,
    required this.requirementFilterAvailable,
    required this.onChanged,
    required this.onStatus,
    required this.onQuiz,
    required this.onRequirement,
  });

  final TextEditingController search;
  final _StatusFilter status;
  final _QuizFilter quiz;
  final bool quizFilterAvailable;
  final _RequirementFilter requirement;
  final bool requirementFilterAvailable;
  final VoidCallback onChanged;
  final ValueChanged<_StatusFilter> onStatus;
  final ValueChanged<_QuizFilter> onQuiz;
  final ValueChanged<_RequirementFilter> onRequirement;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: search,
          decoration: InputDecoration(
            hintText: 'Search videos by title or description',
            filled: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(28),
              borderSide: BorderSide.none,
            ),
            prefixIcon: const Icon(Icons.search),
            suffixIcon: search.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      search.clear();
                      onChanged();
                    },
                  ),
          ),
          onChanged: (_) => onChanged(),
        ),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.lg,
          runSpacing: AppSpacing.sm,
          children: [
            ColorChoiceChips<_StatusFilter>(
              label: 'Status',
              selected: status,
              onSelected: onStatus,
              choices: const [
                ColorChoice(
                  value: _StatusFilter.all,
                  label: 'All',
                  color: AppColors.videos,
                ),
                ColorChoice(
                  value: _StatusFilter.active,
                  label: 'Active',
                  color: AppColors.success,
                ),
                ColorChoice(
                  value: _StatusFilter.inactive,
                  label: 'Inactive',
                  color: AppColors.textSecondary,
                ),
              ],
            ),
            if (quizFilterAvailable)
              ColorChoiceChips<_QuizFilter>(
                label: 'Quiz',
                selected: quiz,
                onSelected: onQuiz,
                choices: const [
                  ColorChoice(
                    value: _QuizFilter.any,
                    label: 'Any',
                    color: AppColors.correctiveActions,
                  ),
                  ColorChoice(
                    value: _QuizFilter.withQuiz,
                    label: 'Has quiz',
                    color: AppColors.correctiveActions,
                  ),
                  ColorChoice(
                    value: _QuizFilter.withoutQuiz,
                    label: 'No quiz',
                    color: AppColors.correctiveActions,
                  ),
                ],
              ),
            if (requirementFilterAvailable)
              ColorChoiceChips<_RequirementFilter>(
                label: 'Requirement',
                selected: requirement,
                onSelected: onRequirement,
                choices: const [
                  ColorChoice(
                    value: _RequirementFilter.any,
                    label: 'Any',
                    color: AppColors.learning,
                  ),
                  ColorChoice(
                    value: _RequirementFilter.required,
                    label: 'Required',
                    color: AppColors.learning,
                  ),
                  ColorChoice(
                    value: _RequirementFilter.general,
                    label: 'General learning',
                    color: AppColors.videos,
                  ),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

/// One column on a phone, two on a tablet, three on a desktop.
class _ManagedGrid extends StatelessWidget {
  const _ManagedGrid({
    required this.videos,
    required this.quizCounts,
    required this.onRetryQuizCount,
    required this.usage,
    required this.sourceOf,
    required this.onOpen,
    required this.onEdit,
    required this.onManageQuiz,
    required this.changingStatus,
    required this.onSetActive,
    required this.onDelete,
  });

  final List<SafetyLearning> videos;
  final Map<String, QuizCount> quizCounts;
  final VoidCallback onRetryQuizCount;
  final Map<String, int>? usage;
  final VideoSource Function(SafetyLearning) sourceOf;
  final Future<void> Function(SafetyLearning) onOpen;
  final Future<void> Function(SafetyLearning) onEdit;
  final Future<void> Function(SafetyLearning) onManageQuiz;
  final Set<String> changingStatus;
  final void Function(SafetyLearning video, bool active) onSetActive;
  final void Function(SafetyLearning video) onDelete;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = width >= 1000
            ? 3
            : width >= 640
            ? 2
            : 1;
        final cardWidth = (width - AppSpacing.md * (columns - 1)) / columns;
        return Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.md,
          children: [
            for (final video in videos)
              SizedBox(
                width: cardWidth,
                child: ManagedVideoCard(
                  video: video,
                  source: sourceOf(video),
                  quizCount: quizCounts[video.id] ?? const QuizCountLoading(),
                  onRetryQuizCount: onRetryQuizCount,
                  requirementCount: usage == null
                      ? null
                      : usage![video.id] ?? 0,
                  onOpen: () => onOpen(video),
                  onEdit: () => onEdit(video),
                  onManageQuiz: () => onManageQuiz(video),
                  statusChanging: changingStatus.contains(video.id),
                  onSetActive: (active) => onSetActive(video, active),
                  onDelete: () => onDelete(video),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// A video as its author sees it: thumbnail and source, status, quiz and
/// how many requirements make it mandatory (or that it is General
/// learning). Actions in order of use: Edit (primary), Preview and Manage
/// Quiz, then Activate/Deactivate and Delete under "More actions".
class ManagedVideoCard extends StatelessWidget {
  const ManagedVideoCard({
    super.key,
    required this.video,
    required this.source,
    required this.quizCount,
    required this.onRetryQuizCount,
    required this.requirementCount,
    required this.onOpen,
    required this.onEdit,
    required this.onManageQuiz,
    this.onSetActive,
    this.onDelete,
    this.statusChanging = false,
  });

  final SafetyLearning video;
  final VideoSource source;

  /// This video's quiz count — see [QuizCount].
  final QuizCount quizCount;

  /// Fetches the counts again (shown when this card's count is not known).
  final VoidCallback onRetryQuizCount;

  /// Active requirements listing this video; null when unknown.
  final int? requirementCount;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onManageQuiz;

  /// Activate (true) or deactivate (false); null hides the action.
  final ValueChanged<bool>? onSetActive;

  /// Permanent deletion (the server decides whether it is allowed); null
  /// hides the action.
  final VoidCallback? onDelete;

  /// A status change or deletion is being saved.
  final bool statusChanging;

  @override
  Widget build(BuildContext context) {
    final active = video.status == OrganizationRecordStatus.active;
    final requirements = requirementCount;
    final count = quizCount;
    final tileColor = active ? AppColors.videos : AppColors.textSecondary;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: tileColor.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          VideoThumbnailTile(
            source: source,
            unavailable: source.isUnsupported,
            showLinkProblems: true,
            inactive: !active,
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  video.title,
                  style: AppTextStyles.titleLarge,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if ((video.description ?? '').trim().isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    video.description!,
                    style: AppTextStyles.bodyMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: AppSpacing.xs,
                  runSpacing: AppSpacing.xs,
                  children: [
                    if (video.deletionPending)
                      const StatusBadge(
                        label: 'Deletion not finished',
                        color: AppColors.danger,
                      )
                    else
                      StatusBadge(
                        label: active ? 'Active' : 'Inactive',
                        color: active
                            ? AppColors.success
                            : AppColors.textSecondary,
                      ),
                    _QuizCountBadge(count: count),
                  ],
                ),
                if (count is QuizCountUnavailable ||
                    count is QuizCountMissing) ...[
                  const SizedBox(height: AppSpacing.xs),
                  _QuizCountProblem(count: count, onRetry: onRetryQuizCount),
                ],
                if (requirements != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Row(
                    children: [
                      Icon(
                        requirements > 0
                            ? Icons.assignment_turned_in
                            : Icons.assignment_outlined,
                        size: 16,
                        color: AppColors.textSecondary,
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Expanded(
                        child: Text(
                          requirements > 0
                              ? 'Required by $requirements '
                                    '${requirements == 1 ? 'requirement' : 'requirements'}'
                              : 'General learning — not in any requirement',
                          style: AppTextStyles.label,
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.videos,
                          minimumSize: const Size(0, AppSpacing.minTouchTarget),
                        ),
                        onPressed: statusChanging || video.deletionPending
                            ? null
                            : onEdit,
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('Edit'),
                      ),
                    ),
                    if (onSetActive != null || onDelete != null)
                      PopupMenuButton<String>(
                        tooltip: 'More actions',
                        enabled: !statusChanging,
                        icon: statusChanging
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.more_vert),
                        onSelected: (value) {
                          if (value == 'toggle') onSetActive!(!active);
                          if (value == 'delete') onDelete!();
                        },
                        itemBuilder: (context) => [
                          if (onSetActive != null && !video.deletionPending)
                            PopupMenuItem(
                              value: 'toggle',
                              child: ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(
                                  active
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                ),
                                title: Text(active ? 'Deactivate' : 'Activate'),
                              ),
                            ),
                          if (onDelete != null)
                            PopupMenuItem(
                              value: 'delete',
                              child: ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(
                                  Icons.delete_outline,
                                  color: AppColors.danger,
                                ),
                                title: Text(
                                  video.deletionPending
                                      ? 'Finish deleting'
                                      : 'Delete',
                                  style: const TextStyle(
                                    color: AppColors.danger,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    _CardAction(
                      label: 'Preview',
                      icon: Icons.play_arrow,
                      onPressed: source.isUnsupported ? null : onOpen,
                    ),
                    _CardAction(
                      label: 'Manage Quiz',
                      icon: Icons.quiz_outlined,
                      onPressed: onManageQuiz,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The quiz badge on a card: a spinner while counting, the confirmed
/// count, or what went wrong.
class _QuizCountBadge extends StatelessWidget {
  const _QuizCountBadge({required this.count});

  final QuizCount count;

  @override
  Widget build(BuildContext context) {
    return switch (count) {
      QuizCountLoading() => const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: AppSpacing.xs),
          Text('Counting quiz…', style: AppTextStyles.label),
        ],
      ),
      QuizCountKnown(questions: 0) => const StatusBadge(
        label: 'No quiz',
        color: AppColors.textSecondary,
      ),
      QuizCountKnown(:final questions) => StatusBadge(
        label: 'Quiz · $questions ${questions == 1 ? 'question' : 'questions'}',
        color: AppColors.correctiveActions,
      ),
      QuizCountUnavailable(needsServerUpdate: true) => const StatusBadge(
        label: 'Quiz count: server update needed',
        color: AppColors.warning,
      ),
      QuizCountUnavailable() => const StatusBadge(
        label: 'Count unavailable',
        color: AppColors.warning,
      ),
      QuizCountMissing() => const StatusBadge(
        label: 'Count missing',
        color: AppColors.warning,
      ),
    };
  }
}

/// Why a card's quiz count is not shown, with a Retry on the card.
class _QuizCountProblem extends StatelessWidget {
  const _QuizCountProblem({required this.count, required this.onRetry});

  final QuizCount count;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final message = switch (count) {
      QuizCountUnavailable(needsServerUpdate: true) =>
        'Counting quizzes needs the latest server update. Manage Quiz still '
            'shows the saved questions.',
      QuizCountUnavailable(:final message) => message,
      _ =>
        'The server didn\'t return a count for this video. Manage Quiz '
            'shows its saved questions.',
    };
    return Row(
      children: [
        Expanded(child: Text(message, style: AppTextStyles.label)),
        TextButton.icon(
          style: TextButton.styleFrom(
            minimumSize: const Size(0, AppSpacing.minTouchTarget),
          ),
          onPressed: onRetry,
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Retry'),
        ),
      ],
    );
  }
}

class _CardAction extends StatelessWidget {
  const _CardAction({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, AppSpacing.minTouchTarget),
      ),
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label),
    );
  }
}

class _InlineRetry extends StatelessWidget {
  const _InlineRetry({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppSpacing.sm),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, size: 18, color: AppColors.warning),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(message, style: AppTextStyles.bodyMedium)),
          TextButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    );
  }
}
