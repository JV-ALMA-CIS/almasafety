import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/services/storage_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/color_choice_chips.dart';
import '../../../core/widgets/empty_state.dart';
import '../../../core/widgets/feature_header.dart';
import '../../../core/widgets/live_stream_builder.dart';
import '../../../core/widgets/organization_scope_selector.dart';
import '../../../core/widgets/status_badge.dart';
import '../../../routing/app_routes.dart';
import '../../authentication/domain/app_role.dart';
import '../../authentication/domain/membership.dart';
import '../../organizations/data/organization_repository.dart';
import '../../safety_learning/data/safety_learning_admin_service.dart';
import '../../safety_learning/data/safety_learning_repository.dart';
import '../../safety_learning/data/worker_learning_repository.dart';
import '../../safety_learning/data/worker_learning_service.dart';
import '../../safety_learning/domain/safety_learning.dart';
import '../../safety_learning/domain/todays_safety_readiness.dart';
import '../../safety_learning/domain/video_source.dart';
import '../../safety_learning/domain/worker_learning_record.dart';
import '../../safety_learning/domain/worker_learning_status.dart';
import '../../safety_learning/presentation/knowledge_check_questions_screen.dart';
import '../../safety_learning/presentation/learning_detail_screen.dart';
import '../../safety_learning/presentation/safety_learning_library_screen.dart';
import '../../safety_learning/presentation/todays_safety_readiness_screen.dart';
import '../../safety_learning/domain/learning_progress.dart';
import '../../safety_requirements/data/safety_requirement_repository.dart';
import '../domain/safety_video_sections.dart';
import 'video_management_view.dart';

/// Safety Videos — a way to find and watch the organization's video lessons.
///
/// Not a separate library: it shows the `video` items of the existing Safety
/// Learning library and opens them in the existing [LearningDetailScreen],
/// so starting and completing a required video updates the same
/// `worker_learning_records` as Safety Learning does.
///
/// A Worker or Foreman sees "Watch before today's meeting", "Required for
/// your work" and "More safety videos" (every other ACTIVE video — General
/// learning, no Safety Requirement needed), sorted from the same
/// [loadTodaysSafetyReadiness] answer the Safety Learning tab uses (which
/// includes a Foreman's site scope). A Site Manager or Admin only browses:
/// no worker learning function is ever called for them. Anything that is
/// not a required, startable lesson opens watch-only, so viewing an optional
/// video never creates a record. Search narrows every section; each card
/// says whether the video has a quiz from the server's own question counts
/// (`getVideoQuizSummary`), never from a guess.
///
/// A video author — platform Admin, or a Site Manager of this organization
/// (`AppRole.canAuthorSafetyVideos`) — also gets Add video, and Edit and
/// Quiz on every card, plus the inactive videos so one can be re-activated.
/// These open the Safety Learning library's own form
/// ([showSafetyLearningForm], locked to Video) and questions screen; the
/// server (`requireLibraryAuthor`) is what actually allows the save.
class SafetyVideosScreen extends StatefulWidget {
  const SafetyVideosScreen({
    super.key,
    this.workerLearningService,
    this.safetyLearningRepository,
    this.workerLearningRepository,
    this.organizationRepository,
    this.adminService,
    this.requirementRepository,
    this.storageBucket,
    this.externalLinkLauncher,
  });

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real dependencies for the active organization.
  final WorkerLearningService? workerLearningService;
  final SafetyLearningRepository? safetyLearningRepository;
  final WorkerLearningRepository? workerLearningRepository;
  final OrganizationRepository? organizationRepository;
  final SafetyLearningAdminService? adminService;
  final SafetyRequirementRepository? requirementRepository;

  /// Passed to the lesson screen; injected in tests.
  final ExternalLinkLauncher? externalLinkLauncher;

  /// The Storage bucket used to recognise JVA videos. Defaults to the
  /// running Firebase app's configured bucket.
  final String? storageBucket;

  @override
  State<SafetyVideosScreen> createState() => _SafetyVideosScreenState();
}

/// The learner's Required / General learning filter.
enum _LearnerFilter { all, required, general }

class _SafetyVideosScreenState extends State<SafetyVideosScreen> {
  late final WorkerLearningService _service =
      widget.workerLearningService ?? WorkerLearningService();
  late final String? _storageBucket =
      widget.storageBucket ?? StorageService().bucket;

  String? _selectedOrganizationId;
  final _search = TextEditingController();
  _LearnerFilter _filter = _LearnerFilter.all;

  /// Question counts per active video for the learner view; null while
  /// loading or when they could not be loaded (then no quiz badge is shown
  /// at all — never a wrong "no quiz").
  Map<String, int>? _quizCounts;
  String? _quizCountsKey;
  Future<TodaysSafetyReadiness>? _readiness;
  String? _readinessKey;
  int _itemsAttempt = 0;
  int _recordsAttempt = 0;

  /// True while a lesson, form or questions screen is being opened — stops
  /// a double tap from pushing the same screen twice.
  bool _navigating = false;

  /// Loaded once per organization/person; [_retryRequirements] reloads it.
  Future<TodaysSafetyReadiness> _readinessFor(
    String organizationId,
    String uid,
  ) {
    final key = '$organizationId/$uid';
    if (_readiness == null || _readinessKey != key) {
      _readinessKey = key;
      _readiness = _loadReadiness(organizationId);
    }
    return _readiness!;
  }

  Future<TodaysSafetyReadiness> _loadReadiness(String organizationId) async {
    try {
      return await loadTodaysSafetyReadiness(_service, organizationId);
    } on Object catch (e) {
      debugPrint('Safety Videos: could not load readiness: $e');
      rethrow;
    }
  }

  /// Logs a stream failure (once per error) and passes it on unchanged.
  static Stream<T> _logged<T>(Stream<T> stream, String what) =>
      stream.handleError((Object error) {
        debugPrint('Safety Videos: could not load $what: $error');
        throw error;
      });

  /// Runs [open] unless another screen is already being opened.
  Future<void> _guarded(Future<void> Function() open) async {
    if (_navigating) return;
    _navigating = true;
    try {
      await open();
    } finally {
      _navigating = false;
    }
  }

  Future<void> _openVideoForm(_ViewContext view, {SafetyLearning? existing}) =>
      _guarded(
        () => showSafetyLearningForm(
          context,
          organizationId: view.organizationId,
          existing: existing,
          videoOnly: true,
          adminService: widget.adminService,
          storageBucket: view.storageBucket,
        ),
      );

  Future<void> _openQuiz(_ViewContext view, SafetyLearning learning) =>
      _guarded(
        () => Navigator.of(context, rootNavigator: true).push(
          MaterialPageRoute<void>(
            builder: (_) => KnowledgeCheckQuestionsScreen(
              organizationId: view.organizationId,
              learning: learning,
              adminService: widget.adminService,
            ),
          ),
        ),
      );

  void _loadQuizCounts(String organizationId) {
    if (_quizCountsKey == organizationId) return;
    _quizCountsKey = organizationId;
    _quizCounts = null;
    (widget.adminService ?? SafetyLearningAdminService())
        .getVideoQuizSummary(organizationId: organizationId)
        .then(
          (counts) {
            if (mounted && _quizCountsKey == organizationId) {
              setState(() => _quizCounts = counts);
            }
          },
          onError: (Object e) {
            debugPrint('Safety Videos: could not load quiz counts: $e');
          },
        );
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Reloads both halves of the requirement labels: readiness and records.
  void _retryRequirements() => setState(() {
    _readiness = null;
    _recordsAttempt++;
  });

  void _retryItems() => setState(() => _itemsAttempt++);

  SafetyLearningRepository _learningRepository(String organizationId) =>
      widget.safetyLearningRepository ??
      SafetyLearningRepository(
        firestoreService: FirestoreService(),
        organizationId: organizationId,
      );

  WorkerLearningRepository _recordRepository(String organizationId) =>
      widget.workerLearningRepository ??
      WorkerLearningRepository(
        firestoreService: FirestoreService(),
        organizationId: organizationId,
      );

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final profile = session.profile;
    final isPlatformAdministrator = profile?.isPlatformAdministrator ?? false;
    final role = session.activeMembership?.role;
    final uid = profile?.uid;
    final personal =
        !isPlatformAdministrator &&
        uid != null &&
        (role == AppRole.worker || role == AppRole.foreman);
    final membership = session.activeMembership;
    final canAuthor =
        isPlatformAdministrator ||
        (membership != null &&
            membership.status == MembershipStatus.active &&
            membership.role.canAuthorSafetyVideos);
    final organizationId =
        session.activeOrganizationId ??
        (isPlatformAdministrator ? _selectedOrganizationId : null);

    if (organizationId == null) {
      if (isPlatformAdministrator) {
        return Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: OrganizationScopeSelector(
            selectedOrganizationId: _selectedOrganizationId,
            onChanged: (value) =>
                setState(() => _selectedOrganizationId = value),
            repository: widget.organizationRepository,
          ),
        );
      }
      return const _Message(
        'Your account is not yet assigned to an organization.',
      );
    }

    final view = _ViewContext(
      organizationId: organizationId,
      uid: uid,
      personal: personal,
      canAuthor: canAuthor,
      storageBucket: _storageBucket,
    );

    return LiveStreamBuilder<List<SafetyLearning>>(
      streamKey: (organizationId, _itemsAttempt),
      stream: () =>
          _logged(_learningRepository(organizationId).watchAll(), 'videos'),
      builder: (context, itemsSnapshot) {
        if (itemsSnapshot.hasError) {
          return _page(
            view,
            videoCount: null,
            children: [
              _RetryPanel(
                message: 'Couldn\'t load safety videos. Please try again.',
                onRetry: _retryItems,
              ),
            ],
          );
        }
        final items = itemsSnapshot.data;
        if (items == null) {
          return _page(view, videoCount: null, children: const [_Loading()]);
        }
        if (!personal && canAuthor) {
          // Authors manage content; learners get the sections below.
          return VideoManagementView(
            organizationId: organizationId,
            items: items,
            storageBucket: _storageBucket,
            requirementRepository:
                widget.requirementRepository ??
                SafetyRequirementRepository(
                  firestoreService: FirestoreService(),
                  organizationId: organizationId,
                ),
            adminService: widget.adminService ?? SafetyLearningAdminService(),
            onAddVideo: () => _openVideoForm(view),
            onEdit: (video) => _openVideoForm(view, existing: video),
            onManageQuiz: (video) => _openQuiz(view, video),
            onOpen: (video) => _open(
              context,
              view,
              SafetyVideoEntry(
                learning: video,
                requirement: VideoRequirement.none,
              ),
              false,
            ),
          );
        }
        _loadQuizCounts(organizationId);
        if (!personal) {
          final sections = buildSafetyVideoSections(
            items: items,
            personal: false,
          );
          return _page(
            view,
            videoCount: sections.browse.length,
            children: _sectionWidgets(view, sections, readinessFailed: false),
          );
        }
        return FutureBuilder<TodaysSafetyReadiness>(
          future: _readinessFor(organizationId, uid),
          builder: (context, readinessSnapshot) {
            if (readinessSnapshot.connectionState != ConnectionState.done) {
              return _page(
                view,
                videoCount: null,
                children: const [_Loading(label: 'Checking what you need…')],
              );
            }
            final readiness = readinessSnapshot.hasError
                ? null
                : readinessSnapshot.data;
            return LiveStreamBuilder<List<WorkerLearningRecord>>(
              streamKey: (organizationId, uid, _recordsAttempt),
              stream: () => _logged(
                _recordRepository(organizationId).watchMine(uid),
                'learning records',
              ),
              builder: (context, recordsSnapshot) {
                // Readiness lists only INCOMPLETE learning, so a completed
                // required video is recognised from the person's records
                // alone. Labels wait for them: without records it would
                // read as "Optional". If they fail, show no labels at all,
                // exactly as for a readiness failure.
                final recordsFailed = recordsSnapshot.hasError;
                final records = recordsSnapshot.data;
                if (!recordsFailed && records == null) {
                  return _page(
                    view,
                    videoCount: null,
                    children: const [
                      _Loading(label: 'Checking what you need…'),
                    ],
                  );
                }
                final labelsKnown = readiness != null && !recordsFailed;
                final sections = buildSafetyVideoSections(
                  items: items,
                  personal: true,
                  readiness: labelsKnown ? readiness : null,
                  records: recordsFailed ? const [] : records!,
                );
                return _page(
                  view,
                  videoCount: activeVideos(items).length,
                  children: _sectionWidgets(
                    view,
                    sections,
                    readinessFailed: !labelsKnown,
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _page(
    _ViewContext view, {
    required int? videoCount,
    required List<Widget> children,
  }) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        FeatureHeader(
          title: 'Safety Videos',
          subtitle: view.personal
              ? 'Watch what your work needs first, then any other safety '
                    'video.'
              : view.canAuthor
              ? 'Every safety video in this organization. Add, edit or '
                    'deactivate videos and their quizzes here.'
              : 'Every active safety video in this organization.',
          icon: Icons.play_circle_fill,
          color: AppColors.videos,
          chips: [
            if (videoCount != null)
              FeatureChip(
                icon: Icons.video_library_outlined,
                label: '$videoCount ${videoCount == 1 ? 'video' : 'videos'}',
              ),
          ],
          footer: view.canAuthor
              ? _AddVideoButton(onPressed: () => _openVideoForm(view))
              : null,
        ),
        const SizedBox(height: AppSpacing.md),
        ...children,
      ],
    );
  }

  List<Widget> _sectionWidgets(
    _ViewContext view,
    SafetyVideoSections sections, {
    required bool readinessFailed,
  }) {
    void open(SafetyVideoEntry entry) =>
        _open(context, view, entry, sections.requirementsKnown);
    Widget grid(List<SafetyVideoEntry> entries) => _VideoGrid(
      entries: entries,
      view: view,
      quizCounts: _quizCounts,
      onOpen: open,
    );

    if (sections.isEmpty) {
      return [
        const EmptyState(
          icon: Icons.video_library_outlined,
          title: 'No safety videos yet',
          message: 'Your safety team will add videos here.',
        ),
      ];
    }

    final query = _search.text.trim().toLowerCase();
    List<SafetyVideoEntry> matching(List<SafetyVideoEntry> entries) =>
        query.isEmpty
        ? entries
        : [
            for (final entry in entries)
              if (entry.learning.title.toLowerCase().contains(query) ||
                  (entry.learning.description ?? '').toLowerCase().contains(
                    query,
                  ))
                entry,
          ];
    // Required / General learning — only when requirement status is known.
    final canFilter =
        view.personal && sections.requirementsKnown && !readinessFailed;
    final filter = canFilter ? _filter : _LearnerFilter.all;
    final showRequired = filter != _LearnerFilter.general;
    final showGeneral = filter != _LearnerFilter.required;
    final today = showRequired
        ? matching(sections.today)
        : const <SafetyVideoEntry>[];
    final requiredEntries = showRequired
        ? matching(sections.required)
        : const <SafetyVideoEntry>[];
    final completed = showRequired
        ? matching(sections.completed)
        : const <SafetyVideoEntry>[];
    final browse = showGeneral
        ? matching(sections.browse)
        : const <SafetyVideoEntry>[];
    final searchField = TextField(
      controller: _search,
      decoration: InputDecoration(
        hintText: 'Search safety videos',
        filled: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(28),
          borderSide: BorderSide.none,
        ),
        prefixIcon: const Icon(Icons.search),
        suffixIcon: _search.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear search',
                icon: const Icon(Icons.clear),
                onPressed: () => setState(_search.clear),
              ),
      ),
      onChanged: (_) => setState(() {}),
    );
    final filters = canFilter
        ? ColorChoiceChips<_LearnerFilter>(
            label: 'Show',
            selected: filter,
            onSelected: (value) => setState(() => _filter = value),
            choices: const [
              ColorChoice(
                value: _LearnerFilter.all,
                label: 'All',
                color: AppColors.videos,
              ),
              ColorChoice(
                value: _LearnerFilter.required,
                label: 'Required',
                color: AppColors.learning,
              ),
              ColorChoice(
                value: _LearnerFilter.general,
                label: 'General learning',
                color: AppColors.videos,
              ),
            ],
          )
        : null;
    final nothingShown =
        today.isEmpty &&
        requiredEntries.isEmpty &&
        completed.isEmpty &&
        browse.isEmpty;
    if (nothingShown && (query.isNotEmpty || filter != _LearnerFilter.all)) {
      return [
        searchField,
        if (filters != null) ...[
          const SizedBox(height: AppSpacing.sm),
          filters,
        ],
        const SizedBox(height: AppSpacing.md),
        EmptyState(
          icon: query.isNotEmpty ? Icons.search_off : Icons.filter_alt_off,
          title: query.isNotEmpty
              ? 'No videos match'
              : filter == _LearnerFilter.required
              ? 'No required videos'
              : 'No general learning videos',
          message: query.isNotEmpty
              ? 'Try another word from the title or description.'
              : 'Show all videos to see the rest.',
          action: OutlinedButton(
            onPressed: () => setState(() {
              _search.clear();
              _filter = _LearnerFilter.all;
            }),
            child: Text(query.isNotEmpty ? 'Clear search' : 'Show all'),
          ),
        ),
      ];
    }

    return [
      searchField,
      if (filters != null) ...[const SizedBox(height: AppSpacing.sm), filters],
      const SizedBox(height: AppSpacing.md),
      if (readinessFailed) ...[
        _RetryPanel(
          message:
              'Couldn\'t check which videos are required of you. They are '
              'shown below without labels — open Safety Learning for your '
              'required lessons.',
          onRetry: _retryRequirements,
        ),
        const SizedBox(height: AppSpacing.md),
      ],
      if (view.personal && !readinessFailed && showRequired) ...[
        FeatureSectionTitle(
          title: 'Watch before today\'s meeting',
          icon: Icons.today,
          color: AppColors.hazards,
          count: today.isEmpty ? null : today.length,
        ),
        const SizedBox(height: AppSpacing.sm),
        if (today.isEmpty)
          const _Note(
            icon: Icons.check_circle,
            color: AppColors.success,
            text: 'No videos needed before today\'s meeting.',
          )
        else
          grid(today),
        if (sections.otherLessonsDueToday > 0) ...[
          const SizedBox(height: AppSpacing.sm),
          _OtherLessonsLink(count: sections.otherLessonsDueToday),
        ],
        const SizedBox(height: AppSpacing.lg),
      ],
      if (requiredEntries.isNotEmpty || completed.isNotEmpty) ...[
        FeatureSectionTitle(
          title: 'Required for your work',
          icon: Icons.assignment_turned_in,
          color: AppColors.learning,
          count: requiredEntries.isEmpty ? null : requiredEntries.length,
        ),
        const SizedBox(height: AppSpacing.sm),
        if (requiredEntries.isNotEmpty) grid(requiredEntries),
        if (completed.isNotEmpty)
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              key: const ValueKey('completed-videos'),
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: AppSpacing.sm),
              initiallyExpanded:
                  requiredEntries.isEmpty && completed.length <= 3 ||
                  query.isNotEmpty,
              leading: const Icon(Icons.verified, color: AppColors.success),
              title: Text(
                'Completed (${completed.length})',
                style: AppTextStyles.bodyLarge.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              children: [grid(completed)],
            ),
          ),
        const SizedBox(height: AppSpacing.lg),
      ],
      if (browse.isNotEmpty) ...[
        FeatureSectionTitle(
          title: view.personal && sections.requirementsKnown
              ? 'More safety videos'
              : 'All safety videos',
          icon: Icons.video_library,
          color: AppColors.videos,
          count: browse.length,
        ),
        const SizedBox(height: AppSpacing.sm),
        grid(browse),
      ],
    ];
  }

  /// Opens [entry] in the existing lesson screen. Only a required lesson
  /// the server says this person may start is opened with its learning
  /// actions; everything else is watch-only, so no learning function runs.
  Future<void> _open(
    BuildContext context,
    _ViewContext view,
    SafetyVideoEntry entry,
    bool requirementsKnown,
  ) {
    final isRequired = switch (entry.requirement) {
      VideoRequirement.neededToday ||
      VideoRequirement.required ||
      VideoRequirement.getAhead => true,
      _ => false,
    };
    final uid = view.uid;
    WorkerLearningRecord? record;
    String? watchOnlyNote;
    if (view.personal && uid != null && isRequired && entry.canStart) {
      // A record not yet created is equivalent to `assigned`: the server
      // creates it on Start, after re-checking the lesson is required.
      record =
          entry.record ??
          WorkerLearningRecord(
            id: '${uid}_${entry.learning.id}',
            workerUid: uid,
            organizationId: view.organizationId,
            learningId: entry.learning.id,
            status: WorkerLearningStatus.assigned,
          );
    } else if (view.personal &&
        entry.requirement == VideoRequirement.completed &&
        entry.record?.status == WorkerLearningStatus.completed) {
      // A completed lesson has no actions left — it shows its summary.
      record = entry.record;
    } else if (view.personal && isRequired) {
      watchOnlyNote =
          'This lesson isn\'t assigned to you yet, so watching it won\'t '
          'count toward your training. Ask your Foreman.';
    } else if (view.personal && !requirementsKnown) {
      watchOnlyNote =
          'We couldn\'t check whether this is required of you. To complete '
          'required lessons, open Safety Learning.';
    }

    return _guarded(
      () => Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(
          builder: (_) => LearningDetailScreen(
            organizationId: view.organizationId,
            learning: entry.learning,
            record: record,
            watchOnly: record == null,
            watchOnlyNote:
                watchOnlyNote ?? LearningDetailScreen.optionalWatchNote,
            // A learner can practise an optional video's quiz; an author
            // manages quizzes instead.
            allowPracticeQuiz: view.personal,
            workerLearningService: widget.workerLearningService,
            storageBucket: view.storageBucket,
            externalLinkLauncher: widget.externalLinkLauncher,
          ),
        ),
      ),
    );
  }
}

/// What every widget below needs to know about the viewer.
class _ViewContext {
  const _ViewContext({
    required this.organizationId,
    required this.uid,
    required this.personal,
    required this.canAuthor,
    required this.storageBucket,
  });

  final String organizationId;
  final String? uid;
  final bool personal;

  /// May add/edit videos and their quizzes — see
  /// `AppRole.canAuthorSafetyVideos`.
  final bool canAuthor;
  final String? storageBucket;

  VideoSource sourceOf(SafetyLearning learning) => VideoSource.classify(
    learning.contentReference,
    organizationId: organizationId,
    storageBucket: storageBucket,
  );
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

/// Cards in one column on a phone, two on a tablet, three on a desktop.
class _VideoGrid extends StatelessWidget {
  const _VideoGrid({
    required this.entries,
    required this.view,
    required this.quizCounts,
    required this.onOpen,
  });

  final List<SafetyVideoEntry> entries;
  final _ViewContext view;
  final Map<String, int>? quizCounts;
  final void Function(SafetyVideoEntry) onOpen;

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
            for (final entry in entries)
              SizedBox(
                width: cardWidth,
                child: SafetyVideoCard(
                  entry: entry,
                  source: view.sourceOf(entry.learning),
                  quizQuestions: quizCounts?[entry.learning.id],
                  showLinkProblems: view.canAuthor,
                  onOpen: () => onOpen(entry),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// One video a learner can watch: its thumbnail (or a play tile) with its
/// source, the title, description and labels, and one clear action. A
/// REQUIRED video also shows where the learner is (video, quiz) and its next
/// step — the video first, then the quiz once the video is watched; any
/// other video says Watch Video. Required status comes from the learner's
/// Safety Requirements, never from having a quiz. A video whose link is
/// unusable cannot be opened.
class SafetyVideoCard extends StatelessWidget {
  const SafetyVideoCard({
    super.key,
    required this.entry,
    required this.source,
    required this.showLinkProblems,
    required this.onOpen,
    this.quizQuestions,
  });

  final SafetyVideoEntry entry;
  final VideoSource source;

  /// The video's question count from `getVideoQuizSummary`; null when not
  /// known (then no quiz badge, rather than a guessed "no quiz").
  final int? quizQuestions;

  /// True for a video author, who sees "Link problem" instead of the
  /// worker-facing "Video unavailable".
  final bool showLinkProblems;
  final VoidCallback onOpen;

  bool get _isRequired => switch (entry.requirement) {
    VideoRequirement.neededToday ||
    VideoRequirement.required ||
    VideoRequirement.getAhead => true,
    _ => false,
  };

  /// Where the learner is — only for a required video, from persisted data.
  LearningProgress? get _progress => _isRequired
      ? LearningProgress.of(
          status: entry.progress,
          contentCompleted: entry.contentCompleted,
          isVideo: true,
          quizRequired: entry.quizRequired,
        )
      : null;

  @override
  Widget build(BuildContext context) {
    final learning = entry.learning;
    final unavailable = source.isUnsupported;
    final minimumSeconds = learning.minimumWatchSeconds ?? 0;
    final progress = _progress;
    final badges = [
      ?_requirementBadge(entry.requirement),
      if (progress != null) _progressBadge(progress),
      if (_isRequired && entry.questionCount > 0)
        StatusBadge(
          label: entry.quizRequired ? 'Quiz required' : 'Optional quiz',
          color: entry.quizRequired
              ? AppColors.correctiveActions
              : AppColors.textSecondary,
        )
      else if (!_isRequired && (quizQuestions ?? 0) > 0)
        StatusBadge(
          label:
              'Quiz · $quizQuestions '
              '${quizQuestions == 1 ? 'question' : 'questions'}',
          color: AppColors.correctiveActions,
        ),
    ];
    final next = progress?.nextAction ?? LearningNextAction.none;
    // Every card has one clear action: a required video's next step, or
    // Watch Video for anything else.
    final String? actionLabel;
    final IconData actionIcon;
    if (progress != null) {
      actionLabel = next == LearningNextAction.none
          ? null
          : progress.nextActionLabel;
      actionIcon = next == LearningNextAction.takeQuiz
          ? Icons.quiz
          : Icons.play_arrow;
    } else {
      actionLabel = entry.requirement == VideoRequirement.completed
          ? 'Watch Again'
          : 'Watch Video';
      actionIcon = Icons.play_arrow;
    }
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: AppColors.videos.withValues(alpha: 0.4)),
      ),
      child: InkWell(
        onTap: unavailable ? null : onOpen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            VideoThumbnailTile(
              source: source,
              unavailable: unavailable,
              showLinkProblems: showLinkProblems,
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    learning.title,
                    style: AppTextStyles.titleLarge,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (learning.description != null &&
                      learning.description!.trim().isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      learning.description!,
                      style: AppTextStyles.bodyMedium,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  if (badges.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Wrap(
                      spacing: AppSpacing.xs,
                      runSpacing: AppSpacing.xs,
                      children: badges,
                    ),
                  ],
                  if (minimumSeconds > 0) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Row(
                      children: [
                        const Icon(
                          Icons.timer_outlined,
                          size: 16,
                          color: AppColors.textSecondary,
                        ),
                        const SizedBox(width: AppSpacing.xs),
                        Expanded(
                          child: Text(
                            'Keep open at least '
                            '${formatMinimumWatchTime(minimumSeconds)}',
                            style: AppTextStyles.label,
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (actionLabel != null && !unavailable) ...[
                    const SizedBox(height: AppSpacing.sm),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size(0, AppSpacing.minTouchTarget),
                          backgroundColor: next == LearningNextAction.takeQuiz
                              ? AppColors.correctiveActions
                              : AppColors.videos,
                          foregroundColor: Colors.white,
                        ),
                        onPressed: onOpen,
                        icon: Icon(actionIcon),
                        label: Text(actionLabel),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Widget? _requirementBadge(VideoRequirement requirement) =>
      switch (requirement) {
        VideoRequirement.neededToday => const StatusBadge(
          label: 'Needed today',
          color: AppColors.hazards,
        ),
        VideoRequirement.required => const StatusBadge(
          label: 'Required',
          color: AppColors.learning,
        ),
        VideoRequirement.getAhead => const StatusBadge(
          label: 'Get ahead',
          color: AppColors.meetings,
        ),
        VideoRequirement.completed => const StatusBadge(
          label: 'Done',
          color: AppColors.success,
        ),
        VideoRequirement.optional => const StatusBadge(
          label: 'General learning',
          color: AppColors.videos,
        ),
        VideoRequirement.none => null,
      };

  static Widget _progressBadge(LearningProgress progress) => StatusBadge(
    label: switch (progress.stage) {
      LearningStage.notStarted => 'New',
      LearningStage.inProgress => 'Started',
      LearningStage.quizOutstanding => 'Quiz outstanding',
      LearningStage.completed => 'Done',
    },
    color: switch (progress.stage) {
      LearningStage.notStarted => AppColors.info,
      LearningStage.inProgress => AppColors.warning,
      LearningStage.quizOutstanding => AppColors.correctiveActions,
      LearningStage.completed => AppColors.success,
    },
  );
}

// "3 min" / "45 sec" — a minimum time, never the video's length.
String formatMinimumWatchTime(int seconds) {
  if (seconds < 60) return '$seconds sec';
  final minutes = (seconds / 60).ceil();
  return '$minutes min';
}

/// The top of a video card: the video's own thumbnail when one exists (a
/// YouTube video's public still — see [VideoSource.thumbnailUri]), over the
/// coloured play tile that is shown on its own for every other video and
/// whenever the image cannot load. Shared by the learner and manager cards.
class VideoThumbnailTile extends StatelessWidget {
  const VideoThumbnailTile({
    super.key,
    required this.source,
    required this.unavailable,
    required this.showLinkProblems,
    this.height,
    this.inactive = false,
  });

  final VideoSource source;
  final bool unavailable;
  final bool showLinkProblems;

  /// A fixed height; null (the default) is a 16:9 tile, like the video.
  final double? height;

  /// Drawn in grey, for an inactive video on the manager's card.
  final bool inactive;

  @override
  Widget build(BuildContext context) {
    final color = unavailable || inactive
        ? AppColors.textSecondary
        : AppColors.videos;
    final thumbnail = unavailable ? null : source.thumbnailUri;
    final tile = Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [color, Color.lerp(color, Colors.black, 0.3)!],
            ),
          ),
        ),
        if (thumbnail != null) ...[
          Image.network(
            thumbnail.toString(),
            fit: BoxFit.cover,
            color: inactive ? Colors.grey : null,
            colorBlendMode: inactive ? BlendMode.saturation : null,
            // No image (offline, blocked): the play tile stays.
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
          // Keeps the play icon and source chip readable on any image.
          const DecoratedBox(
            decoration: BoxDecoration(color: Color(0x33000000)),
          ),
        ],
        Center(
          child: unavailable
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.videocam_off,
                      size: 40,
                      color: Colors.white,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      showLinkProblems ? 'Link problem' : 'Video unavailable',
                      style: AppTextStyles.bodyLarge.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                )
              : const Icon(
                  Icons.play_circle_fill,
                  size: 56,
                  color: Colors.white,
                ),
        ),
        if (!unavailable)
          Positioned(
            top: AppSpacing.sm,
            left: AppSpacing.sm,
            right: AppSpacing.sm,
            child: Align(
              alignment: Alignment.centerLeft,
              child: VideoSourceChip(source: source),
            ),
          ),
      ],
    );
    final fixed = height;
    return fixed != null
        ? SizedBox(height: fixed, child: tile)
        : AspectRatio(aspectRatio: 16 / 9, child: tile);
  }
}

/// "JVA video" on a white chip; an external source with an open-outside
/// icon when it leaves the app.
class VideoSourceChip extends StatelessWidget {
  const VideoSourceChip({super.key, required this.source});

  final VideoSource source;

  @override
  Widget build(BuildContext context) {
    final opensOutside =
        source.kind == VideoSourceKind.youtube ||
        source.kind == VideoSourceKind.vimeo;
    final background = source.isJva
        ? Colors.white
        : Colors.black.withValues(alpha: 0.55);
    final foreground = source.isJva ? AppColors.videos : Colors.white;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            source.isJva
                ? Icons.verified
                : opensOutside
                ? Icons.open_in_new
                : Icons.public,
            size: 14,
            color: foreground,
          ),
          const SizedBox(width: AppSpacing.xs),
          Flexible(
            child: Text(
              source.label,
              style: AppTextStyles.label.copyWith(
                color: foreground,
                fontWeight: FontWeight.w700,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _OtherLessonsLink extends StatelessWidget {
  const _OtherLessonsLink({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.learning,
          minimumSize: const Size(0, AppSpacing.minTouchTarget),
        ),
        onPressed: () => context.go(AppRoutes.safetyLearning),
        icon: const Icon(Icons.school),
        label: Text(
          '$count other ${count == 1 ? 'lesson is' : 'lessons are'} due '
          'today — open Safety Learning',
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppSpacing.sm),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(text, style: AppTextStyles.bodyMedium)),
        ],
      ),
    );
  }
}

class _RetryPanel extends StatelessWidget {
  const _RetryPanel({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.wifi_off, color: AppColors.warning),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: Text(message, style: AppTextStyles.bodyMedium)),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, AppSpacing.minTouchTarget),
            ),
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading({this.label});

  final String? label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
      child: Column(
        children: [
          const CircularProgressIndicator(),
          if (label != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(label!, style: AppTextStyles.bodyMedium),
          ],
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Text(
          text,
          style: AppTextStyles.bodyMedium,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
