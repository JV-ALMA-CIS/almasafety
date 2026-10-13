import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/widgets/feature_header.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/safety_learning_repository.dart';
import '../data/worker_learning_repository.dart';
import '../data/worker_learning_service.dart';
import '../domain/safety_learning.dart';
import '../domain/safety_learning_type.dart';
import '../domain/todays_safety_readiness.dart';
import '../domain/worker_learning_record.dart';
import '../domain/worker_learning_status.dart';
import 'learning_detail_screen.dart';
import 'my_safety_learning_screen.dart';

/// Opens the full learning inventory ([MySafetyLearningScreen]) as its own
/// page — deliberately one step away from Today's Safety Readiness, so the
/// catalogue is never the first thing presented as today's task list.
Future<void> openAllMyLearning(BuildContext context) {
  return Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('All My Learning')),
        body: const MySafetyLearningScreen(),
      ),
    ),
  );
}

/// The Safety Learning tab for a Worker or Foreman: Today's Safety
/// Readiness first, with the full inventory one tap away
/// ([openAllMyLearning]). Reads the signed-in user from [SessionController].
class SafetyLearningTab extends StatelessWidget {
  const SafetyLearningTab({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final organizationId = session.activeOrganizationId;
    final uid = session.profile?.uid;
    if (organizationId == null || uid == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: Text(
            'Your account is not yet assigned to an organization.',
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return TodaysSafetyReadinessScreen(
      // Keyed so switching organization or user re-fetches.
      key: ValueKey('safety-learning-tab-$organizationId-$uid'),
      organizationId: organizationId,
      workerUid: uid,
      embedded: true,
    );
  }
}

/// Loads the signed-in worker's [TodaysSafetyReadiness]: first
/// materializes their required-learning records (`getMyRequiredLearning`,
/// best-effort — exactly what [MySafetyLearningScreen] does on open, so a
/// tapped item already has a record to open), then fetches today's focused
/// view from `getMyTodaysSafetyReadiness`.
///
/// Shared by [TodaysSafetyReadinessScreen] and the worker dashboard's
/// "Ready for Today" card so both always show the same server answer.
Future<TodaysSafetyReadiness> loadTodaysSafetyReadiness(
  WorkerLearningService service,
  String organizationId,
) async {
  try {
    await service.getMyRequiredLearning(organizationId: organizationId);
  } on Object {
    // Best-effort: readiness below is still authoritative on its own.
  }
  return service.getMyTodaysSafetyReadiness(organizationId: organizationId);
}

/// The worker's primary daily learning view — only what matters for
/// TODAY's project, site, activity and meeting, split into "Needed today",
/// "Before you work", "Get ahead for tomorrow" and a collapsed "When you
/// can" section. The broader [MySafetyLearningScreen] inventory stays available
/// separately.
///
/// Items disappear the moment the worker completes them: the server's
/// answer is filtered through the live [WorkerLearningRepository.watchMine]
/// stream, so returning from [LearningDetailScreen] needs no re-fetch.
class TodaysSafetyReadinessScreen extends StatefulWidget {
  const TodaysSafetyReadinessScreen({
    super.key,
    required this.organizationId,
    required this.workerUid,
    this.workerLearningService,
    this.workerLearningRepository,
    this.safetyLearningRepository,
    this.embedded = false,
  });

  final String organizationId;
  final String workerUid;

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real dependencies.
  final WorkerLearningService? workerLearningService;
  final WorkerLearningRepository? workerLearningRepository;
  final SafetyLearningRepository? safetyLearningRepository;

  /// True when shown inside the app shell as the Safety Learning tab: no
  /// Scaffold/AppBar of its own (the shell provides them), a page heading
  /// instead, and an "All my learning" button to the full inventory.
  final bool embedded;

  @override
  State<TodaysSafetyReadinessScreen> createState() =>
      _TodaysSafetyReadinessScreenState();
}

class _TodaysSafetyReadinessScreenState
    extends State<TodaysSafetyReadinessScreen> {
  late final WorkerLearningService _service =
      widget.workerLearningService ?? WorkerLearningService();
  late final WorkerLearningRepository _recordRepository =
      widget.workerLearningRepository ??
      WorkerLearningRepository(
        firestoreService: FirestoreService(),
        organizationId: widget.organizationId,
      );
  late final SafetyLearningRepository _learningRepository =
      widget.safetyLearningRepository ??
      SafetyLearningRepository(
        firestoreService: FirestoreService(),
        organizationId: widget.organizationId,
      );
  late final Stream<List<WorkerLearningRecord>> _records = _recordRepository
      .watchMine(widget.workerUid);
  late final Stream<List<SafetyLearning>> _learning = _learningRepository
      .watchAll();

  late Future<TodaysSafetyReadiness> _future = _load();

  Future<TodaysSafetyReadiness> _load() =>
      loadTodaysSafetyReadiness(_service, widget.organizationId);

  Future<void> _refresh() async {
    final future = _load();
    setState(() {
      _future = future;
    });
    try {
      await future;
    } on Object {
      // Surfaced by the FutureBuilder below.
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = _content();
    if (!widget.embedded) {
      return Scaffold(appBar: AppBar(), body: content);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.md,
            0,
          ),
          // The screen's title lives in the colored header below; this row
          // keeps only the way into the full learning list.
          child: Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => openAllMyLearning(context),
              icon: const Icon(Icons.menu_book_outlined),
              label: const Text('All my learning'),
            ),
          ),
        ),
        Expanded(child: content),
      ],
    );
  }

  Widget _content() {
    return RefreshIndicator(
      onRefresh: _refresh,
      child: FutureBuilder<TodaysSafetyReadiness>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return _MessageList(
              message: "Could not load today's safety readiness.",
              onRetry: _refresh,
            );
          }
          final readiness = snapshot.data;
          if (readiness == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return StreamBuilder<List<WorkerLearningRecord>>(
            stream: _records,
            builder: (context, recordSnapshot) {
              final records =
                  recordSnapshot.data ?? const <WorkerLearningRecord>[];
              return StreamBuilder<List<SafetyLearning>>(
                stream: _learning,
                builder: (context, learningSnapshot) {
                  final learningById = {
                    for (final item
                        in learningSnapshot.data ?? const <SafetyLearning>[])
                      item.id: item,
                  };
                  final recordsById = {
                    for (final record in records) record.learningId: record,
                  };
                  return TodaysSafetyReadinessView(
                    readiness: readiness,
                    records: records,
                    onOpen: (item) => _open(item, learningById, recordsById),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _open(
    ReadinessItem item,
    Map<String, SafetyLearning> learningById,
    Map<String, WorkerLearningRecord> recordsById,
  ) async {
    final learning = learningById[item.learningId];
    if (learning == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('That learning item is still loading. Try again.'),
        ),
      );
      return;
    }
    // A record not yet materialized is equivalent to `assigned`:
    // `startLearning` creates it server-side on first start.
    final record =
        recordsById[item.learningId] ??
        WorkerLearningRecord(
          id: '${widget.workerUid}_${item.learningId}',
          workerUid: widget.workerUid,
          organizationId: widget.organizationId,
          learningId: item.learningId,
          status: WorkerLearningStatus.assigned,
        );
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => LearningDetailScreen(
          organizationId: widget.organizationId,
          learning: learning,
          record: record,
          workerLearningService: widget.workerLearningService,
        ),
      ),
    );
  }
}

/// The pure presentation of [TodaysSafetyReadiness] — no data loading, so it
/// can be widget-tested directly.
///
/// [records] is the worker's live record list: any item whose record is
/// `completed` is hidden even if [readiness] (fetched earlier) still lists
/// it.
class TodaysSafetyReadinessView extends StatefulWidget {
  const TodaysSafetyReadinessView({
    super.key,
    required this.readiness,
    required this.onOpen,
    this.records = const [],
  });

  final TodaysSafetyReadiness readiness;
  final List<WorkerLearningRecord> records;
  final ValueChanged<ReadinessItem> onOpen;

  @override
  State<TodaysSafetyReadinessView> createState() =>
      _TodaysSafetyReadinessViewState();
}

class _TodaysSafetyReadinessViewState extends State<TodaysSafetyReadinessView> {
  bool _showAdditional = false;

  List<Widget> _tiles(
    List<ReadinessItem> items,
    Map<String, WorkerLearningStatus> statusById,
  ) => [
    for (final item in items)
      _ItemTile(
        item: item,
        status: statusById[item.learningId],
        onOpen: widget.onOpen,
      ),
  ];

  @override
  Widget build(BuildContext context) {
    final statusById = {
      for (final record in widget.records) record.learningId: record.status,
    };
    final readiness = widget.readiness.withoutCompleted({
      for (final entry in statusById.entries)
        if (entry.value == WorkerLearningStatus.completed) entry.key,
    });

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        ReadinessHeader(readiness: readiness),
        const SizedBox(height: AppSpacing.lg),
        if (readiness.isReady)
          const _ReadyBanner()
        else ...[
          if (readiness.beforeMeeting.isNotEmpty) ...[
            _SectionPanel(
              key: const Key('readiness-before-meeting'),
              tag: 'TODAY',
              title: 'Needed today',
              instruction: readiness.isForeman
                  ? 'Complete before you can start the safety meeting.'
                  : 'Complete before the safety meeting.',
              note: readiness.gatingSource != ReadinessGatingSource.assignments
                  ? null
                  : readiness.isForeman
                  ? "Based on your site's active activities."
                  : 'Based on your assigned activities. Confirmed when your '
                        'Foreman starts the meeting.',
              icon: Icons.alarm,
              color: AppColors.stop,
              count: readiness.beforeMeeting.length,
              children: _tiles(readiness.beforeMeeting, statusById),
            ),
            const SizedBox(height: AppSpacing.xl),
          ],
          if (readiness.beforeWork.isNotEmpty) ...[
            _SectionPanel(
              key: const Key('readiness-before-work'),
              tag: 'TODAY',
              title: 'Before you work',
              instruction: 'Complete before starting this activity.',
              icon: Icons.construction,
              color: AppColors.hazards,
              count: readiness.beforeWork.length,
              children: _tiles(readiness.beforeWork, statusById),
            ),
            const SizedBox(height: AppSpacing.xl),
          ],
        ],
        if (readiness.neededTomorrow.isNotEmpty) ...[
          _SectionPanel(
            key: const Key('readiness-tomorrow'),
            tag: 'TOMORROW',
            title: 'Get ahead for tomorrow',
            instruction:
                'Do this tonight or on your way in, and tomorrow morning '
                'is free.',
            icon: Icons.nightlight_round,
            color: AppColors.learning,
            count: readiness.neededTomorrow.length,
            children: _tiles(readiness.neededTomorrow, statusById),
          ),
          const SizedBox(height: AppSpacing.xl),
        ],
        if (readiness.additional.isNotEmpty)
          _SectionPanel(
            key: const Key('readiness-additional'),
            tag: 'ANYTIME',
            title:
                'When you can: ${readiness.additional.length} more '
                '${readiness.additional.length == 1 ? 'lesson' : 'lessons'}',
            instruction:
                'Still required, but not needed today. They come up one at '
                'a time on later days — or do them early.',
            icon: Icons.menu_book,
            color: AppColors.meetings,
            trailing: TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              onPressed: () =>
                  setState(() => _showAdditional = !_showAdditional),
              child: Text(_showAdditional ? 'Hide' : 'View'),
            ),
            children: _showAdditional
                ? _tiles(readiness.additional, statusById)
                : const [],
          ),
      ],
    );
  }
}

/// Project · Site · Activity · Meeting status for today — shared by the
/// readiness screen and the dashboard card.
class ReadinessScopeSummary extends StatelessWidget {
  const ReadinessScopeSummary({super.key, required this.readiness});

  final TodaysSafetyReadiness readiness;

  @override
  Widget build(BuildContext context) {
    String join(List<ReadinessScopeRef> refs) =>
        refs.map((ref) => ref.label).join(', ');
    final projects = join(readiness.projects);
    final sites = join(readiness.sites);
    final activities = join(readiness.activities);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (projects.isNotEmpty)
          Text(projects, style: AppTextStyles.titleLarge),
        if (sites.isNotEmpty) Text(sites, style: AppTextStyles.bodyLarge),
        if (activities.isNotEmpty)
          Text(activities, style: AppTextStyles.bodyMedium),
        if (projects.isEmpty && sites.isEmpty && activities.isEmpty)
          const Text(
            'You are not yet assigned to an activity.',
            style: AppTextStyles.bodyMedium,
          ),
        const SizedBox(height: AppSpacing.xs),
        Row(
          children: [
            const Icon(
              Icons.fact_check_outlined,
              size: 18,
              color: AppColors.textSecondary,
            ),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: Text(
                meetingStatusLabel(context, readiness.meeting),
                style: AppTextStyles.bodyMedium,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The readiness screen's colored header: the title, then today's project,
/// site, activities and meeting status as chips.
class ReadinessHeader extends StatelessWidget {
  const ReadinessHeader({super.key, required this.readiness});

  final TodaysSafetyReadiness readiness;

  @override
  Widget build(BuildContext context) {
    String join(List<ReadinessScopeRef> refs) =>
        refs.map((ref) => ref.label).join(', ');
    final projects = join(readiness.projects);
    final sites = join(readiness.sites);
    final activities = join(readiness.activities);
    final assigned =
        projects.isNotEmpty || sites.isNotEmpty || activities.isNotEmpty;
    return FeatureHeader(
      title: "Today's Safety Readiness",
      subtitle: readiness.isReady
          ? "You're all set for today's meeting and work."
          : "What you need to do before today's meeting and work.",
      icon: Icons.verified_user,
      color: AppColors.learning,
      chips: [
        if (projects.isNotEmpty)
          FeatureChip(icon: Icons.apartment, label: projects),
        if (sites.isNotEmpty) FeatureChip(icon: Icons.place, label: sites),
        if (activities.isNotEmpty)
          FeatureChip(icon: Icons.handyman, label: activities),
        if (!assigned)
          const FeatureChip(
            icon: Icons.info_outline,
            label: 'You are not yet assigned to an activity.',
          ),
        FeatureChip(
          icon: Icons.fact_check,
          label: meetingStatusLabel(context, readiness.meeting),
        ),
      ],
    );
  }
}

/// "Safety Meeting — …" for [meeting]. There is no scheduled meeting time
/// in this system — a meeting exists only once a Foreman starts it — so
/// this reports its actual state and start time.
String meetingStatusLabel(BuildContext context, ReadinessMeeting? meeting) {
  if (meeting == null) return 'Safety Meeting — not started yet';
  final start = meeting.startTime;
  final at = start == null
      ? ''
      : ' ${TimeOfDay.fromDateTime(start).format(context)}';
  return meeting.isCompleted
      ? 'Safety Meeting — completed (started$at)'
      : 'Safety Meeting — in progress${at.isEmpty ? '' : ' since$at'}';
}

class _ReadyBanner extends StatelessWidget {
  const _ReadyBanner();

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('readiness-ready'),
      margin: EdgeInsets.zero,
      child: const ListTile(
        leading: Icon(Icons.verified_outlined, color: AppColors.success),
        title: Text("You're ready for today"),
        subtitle: Text(
          'No learning is needed before today’s meeting or your work.',
        ),
      ),
    );
  }
}

/// One clearly separated group of lessons: a solid colored header (when
/// tag, title, count and what to do) above its own lesson rows, so "Needed
/// today", "Before you work", "Get ahead for tomorrow" and "When you can"
/// never run together.
class _SectionPanel extends StatelessWidget {
  const _SectionPanel({
    super.key,
    required this.tag,
    required this.title,
    required this.instruction,
    required this.icon,
    required this.color,
    required this.children,
    this.count,
    this.note,
    this.trailing,
  });

  /// When this is for: TODAY, TOMORROW or ANYTIME.
  final String tag;
  final String title;
  final String instruction;
  final String? note;
  final IconData icon;
  final Color color;
  final int? count;
  final Widget? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final onColor = AppColors.onColor(color);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          color.withValues(alpha: isDark ? 0.14 : 0.06),
          Theme.of(context).colorScheme.surface,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color, width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: color,
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.sm,
              AppSpacing.md,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: onColor.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: onColor),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tag,
                        style: AppTextStyles.label.copyWith(
                          color: onColor.withValues(alpha: 0.85),
                          letterSpacing: 1.2,
                        ),
                      ),
                      Text(
                        title,
                        style: AppTextStyles.titleLarge.copyWith(
                          color: onColor,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        instruction,
                        style: AppTextStyles.bodyMedium.copyWith(
                          color: onColor,
                        ),
                      ),
                    ],
                  ),
                ),
                if (count != null)
                  Container(
                    margin: const EdgeInsets.only(left: AppSpacing.sm),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: onColor,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '$count',
                      style: AppTextStyles.label.copyWith(color: color),
                    ),
                  ),
                ?trailing,
              ],
            ),
          ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.sm,
                AppSpacing.md,
                0,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, size: 16, color: color),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(child: Text(note!, style: AppTextStyles.label)),
                ],
              ),
            ),
          if (children.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: Column(
                children: [
                  for (final (index, child) in children.indexed) ...[
                    if (index > 0) const SizedBox(height: AppSpacing.sm),
                    child,
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// One lesson: its own card, with an icon for its type, the title, and its
/// status — tapping opens it.
class _ItemTile extends StatelessWidget {
  const _ItemTile({
    required this.item,
    required this.status,
    required this.onOpen,
  });

  final ReadinessItem item;

  /// The live record status, when a record exists — fresher than
  /// [ReadinessItem.status], which was captured when readiness was fetched.
  final WorkerLearningStatus? status;
  final ValueChanged<ReadinessItem> onOpen;

  static IconData _iconFor(SafetyLearningType? type) => switch (type) {
    SafetyLearningType.video => Icons.play_circle_fill,
    SafetyLearningType.course => Icons.school,
    SafetyLearningType.visualGuide => Icons.image,
    SafetyLearningType.document => Icons.description,
    SafetyLearningType.knowledgeCheck => Icons.quiz,
    null => Icons.menu_book,
  };

  @override
  Widget build(BuildContext context) {
    final type = SafetyLearningType.tryFromId(item.type);
    final inProgress =
        status == WorkerLearningStatus.inProgress ||
        (status == null && item.status == ReadinessItemStatus.inProgress);
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        leading: CircleAvatar(
          backgroundColor: AppColors.learning.withValues(alpha: 0.15),
          child: Icon(_iconFor(type), color: AppColors.learning),
        ),
        title: Text(
          item.title,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: item.canStart
            ? (type == null ? null : Text(type.label))
            : const Text(
                'Not yet linked to your assigned activities — speak to your '
                'Foreman.',
              ),
        trailing: item.canStart
            ? StatusBadge(
                label: inProgress ? 'In progress' : 'Not started',
                color: inProgress ? AppColors.warning : AppColors.textSecondary,
              )
            : null,
        onTap: item.canStart ? () => onOpen(item) : null,
      ),
    );
  }
}

class _MessageList extends StatelessWidget {
  const _MessageList({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        Text(
          message,
          style: AppTextStyles.bodyMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.md),
        Center(
          child: OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
        ),
      ],
    );
  }
}
