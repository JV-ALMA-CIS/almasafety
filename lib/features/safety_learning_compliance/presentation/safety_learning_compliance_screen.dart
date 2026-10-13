import 'package:flutter/material.dart';
import '../../../core/widgets/live_stream_builder.dart';
import 'package:provider/provider.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/empty_state.dart';
import '../../../core/widgets/organization_scope_selector.dart';
import '../../authentication/domain/app_role.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../../organizations/data/organization_repository.dart';
import '../../organizations/data/site_repository.dart';
import '../../organizations/domain/site.dart';
import '../data/safety_compliance_repository.dart';
import '../domain/activity_compliance_summary.dart';
import '../domain/worker_compliance_row.dart';
import '../../../core/widgets/feature_header.dart';
import '../../../core/widgets/person_avatar.dart';
import '../../../core/widgets/status_badge.dart';
import '../../pre_start_checks/presentation/pre_start_visuals.dart';

/// Admin/Site Manager/Foreman oversight screen answering "which workers are
/// ready for the work happening at my site, and what learning are they
/// missing."
///
/// **Site -> Activity -> Workers.** Landing view lists sites; picking one
/// shows every active activity at that site as a card ("Roofing — 18
/// workers, 15 Ready, 3 Not Ready"); tapping an activity drills into its
/// worker list, and tapping a worker drills into their
/// required/completed/outstanding learning detail. All data comes from
/// [SafetyComplianceRepository], which itself resolves required learning
/// through the SAME `SafetyRequirementRepository.watchResolvedRequiredLearning`
/// every other Safety Learning surface in this codebase already uses — see
/// that repository's doc comment for why this introduces no second
/// resolution concept.
///
/// **A Foreman sees this too, scoped to their own site(s) only** — they are
/// the one who runs the Daily Safety Meeting and needs to know, BEFORE it
/// starts, which of their crew are actually eligible
/// (`requireForemanLearningComplete` already enforces the same rule
/// server-side as a hard gate — this screen answers the same question ahead
/// of time instead of a Foreman finding out mid-meeting). Unlike Admin/Site
/// Manager, who see and choose among every site in the organization, a
/// Foreman's landing list is pre-filtered to `activeMembership.siteIds` —
/// the same site-assignment field their own account was granted, exactly
/// like [MyWorkersScreen] already scopes their worker list. This grants no
/// new authority: every read this screen triggers already flows through
/// repositories/services (`ActivityRepository`,
/// `ActivityAssignmentRepository`, `SafetyRequirementRepository`,
/// `WorkerLearningRepository`, `AccountApprovalService`) whose own
/// `firestore.rules`/callable authorization already lets any org member
/// read this data — the site filter is a within-organization VIEW
/// narrowing, not a second, narrower server boundary.
///
/// **Authorization for Admin/Site Manager** mirrors [ReportsScreen] exactly:
/// gated on `canManageOrgContent` (Admin, any organization, or a Site
/// Manager of their own), with [OrganizationScopeSelector] standing in for
/// an Admin's organization choice.
class SafetyLearningComplianceScreen extends StatefulWidget {
  const SafetyLearningComplianceScreen({
    super.key,
    this.repository,
    this.siteRepository,
    this.organizationRepository,
  });

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real dependencies scoped to the signed-in user's (or, for
  /// an Admin, the selected) organization.
  final SafetyComplianceRepository? repository;
  final SiteRepository? siteRepository;

  /// Injected in tests. Backs [OrganizationScopeSelector] for a System
  /// Administrator, who has no organization of their own.
  final OrganizationRepository? organizationRepository;

  @override
  State<SafetyLearningComplianceScreen> createState() =>
      _SafetyLearningComplianceScreenState();
}

class _SafetyLearningComplianceScreenState
    extends State<SafetyLearningComplianceScreen> {
  SafetyComplianceRepository? _repository;
  SiteRepository? _siteRepository;
  String? _selectedOrganizationId;
  Site? _selectedSite;

  SafetyComplianceRepository _repositoryFor(String organizationId) {
    final existing = _repository;
    if (existing != null && existing.organizationId == organizationId) {
      return existing;
    }
    final created =
        widget.repository ??
        SafetyComplianceRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );
    _repository = created;
    return created;
  }

  SiteRepository _siteRepositoryFor(String organizationId) {
    final existing = _siteRepository;
    if (existing != null && existing.organizationId == organizationId) {
      return existing;
    }
    final created =
        widget.siteRepository ??
        SiteRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );
    _siteRepository = created;
    return created;
  }

  @override
  Widget build(BuildContext context) {
    final sessionController = context.watch<SessionController>();
    final profile = sessionController.profile;
    final isPlatformAdministrator = profile?.isPlatformAdministrator ?? false;
    final activeMembership = sessionController.activeMembership;
    final isForeman = activeMembership?.role == AppRole.foreman;
    final canManage =
        isPlatformAdministrator ||
        activeMembership?.role.canManageOrgContent == true ||
        isForeman;
    final organizationId = isPlatformAdministrator
        ? _selectedOrganizationId
        : sessionController.activeOrganizationId;
    // A Foreman's own site assignment — null for Admin/Site Manager, who see
    // every site instead. See this screen's own doc comment.
    final foremanSiteIds = isForeman ? activeMembership?.siteIds : null;

    if (!canManage) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: Text(
            'Safety Learning compliance is available to Admins, Site '
            'Managers and Foremen.',
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    if (organizationId == null) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: OrganizationScopeSelector(
          selectedOrganizationId: _selectedOrganizationId,
          onChanged: (value) => setState(() {
            _selectedOrganizationId = value;
            _selectedSite = null;
          }),
          repository: widget.organizationRepository,
        ),
      );
    }

    final selectedSite = _selectedSite;
    if (selectedSite != null) {
      return _SiteComplianceView(
        organizationId: organizationId,
        site: selectedSite,
        repository: _repositoryFor(organizationId),
        onBack: () => setState(() => _selectedSite = null),
      );
    }

    // A Foreman's `firestore.rules` read grant on `sites` is scoped to their
    // own `siteIds` only — an unconstrained `watchAll()` listing is refused
    // outright for them (see SiteRepository.watchByIds's own doc comment),
    // so this must query by id directly rather than fetch everything and
    // filter client-side, which silently returned nothing and read as "not
    // assigned to a site" for a Foreman who plainly was.
    final siteStream = foremanSiteIds != null
        ? _siteRepositoryFor(organizationId).watchByIds(foremanSiteIds)
        : _siteRepositoryFor(organizationId).watchAll();

    return LiveStreamBuilder<List<Site>>(
      streamKey: (organizationId, foremanSiteIds?.join(',')),
      stream: () => siteStream,
      builder: (context, siteSnapshot) {
        final sites = (siteSnapshot.data ?? const <Site>[])
            .where((s) => s.status.id == 'active')
            .toList(growable: false);
        final isLoading =
            siteSnapshot.connectionState == ConnectionState.waiting;

        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            const FeatureHeader(
              title: 'Safety Learning Compliance',
              subtitle:
                  'Choose a site to see which workers are ready for the work '
                  "happening there, and what they're missing.",
              icon: Icons.verified_user,
              color: AppColors.compliance,
            ),
            const SizedBox(height: AppSpacing.md),
            if (isPlatformAdministrator)
              OrganizationScopeSelector(
                selectedOrganizationId: _selectedOrganizationId,
                onChanged: (value) => setState(() {
                  _selectedOrganizationId = value;
                  _selectedSite = null;
                }),
                repository: widget.organizationRepository,
              ),
            if (isLoading && sites.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (!isLoading && sites.isEmpty)
              EmptyState(
                icon: Icons.location_city_outlined,
                title: 'No active sites',
                message: isForeman
                    ? 'You are not yet assigned to a site.'
                    : 'Add a site before reviewing compliance here.',
              ),
            for (final site in sites) ...[
              Card(
                margin: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(
                    color: AppColors.projects.withValues(alpha: 0.4),
                  ),
                ),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.xs,
                  ),
                  leading: const CircleAvatar(
                    backgroundColor: AppColors.projects,
                    child: Icon(Icons.location_city, color: Colors.white),
                  ),
                  title: Text(
                    site.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: const Text('Tap to review crew readiness'),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: AppColors.projects,
                  ),
                  onTap: () => setState(() => _selectedSite = site),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
          ],
        );
      },
    );
  }
}

/// Step 2: every active activity at [site], each an
/// [_ActivitySummaryCard]("Roofing — 18 workers, 15 Ready, 3 Not Ready")
/// that drills into [_ActivityWorkerListView].
class _SiteComplianceView extends StatefulWidget {
  const _SiteComplianceView({
    required this.organizationId,
    required this.site,
    required this.repository,
    required this.onBack,
  });

  final String organizationId;
  final Site site;
  final SafetyComplianceRepository repository;
  final VoidCallback onBack;

  @override
  State<_SiteComplianceView> createState() => _SiteComplianceViewState();
}

class _SiteComplianceViewState extends State<_SiteComplianceView> {
  late Future<List<ActivityComplianceSummary>> _future = _load();
  ActivityComplianceSummary? _selectedActivity;

  Future<List<ActivityComplianceSummary>> _load() =>
      widget.repository.buildSiteCompliance(widget.site.id);

  Future<void> _refresh() async {
    final future = _load();
    setState(() => _future = future);
    await future;
  }

  @override
  Widget build(BuildContext context) {
    final selectedActivity = _selectedActivity;
    if (selectedActivity != null) {
      return _ActivityWorkerListView(
        summary: selectedActivity,
        onBack: () => setState(() => _selectedActivity = null),
      );
    }

    return FutureBuilder<List<ActivityComplianceSummary>>(
      future: _future,
      builder: (context, snapshot) {
        final isLoading = snapshot.connectionState == ConnectionState.waiting;
        final summaries = snapshot.data ?? const <ActivityComplianceSummary>[];
        final totalWorkers = summaries.fold<int>(
          0,
          (sum, s) => sum + s.workerCount,
        );
        final totalReady = summaries.fold<int>(
          0,
          (sum, s) => sum + s.readyCount,
        );

        return RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              _BackRow(
                tooltip: 'Back to sites',
                label: 'All sites',
                onPressed: widget.onBack,
              ),
              const SizedBox(height: AppSpacing.sm),
              FeatureHeader(
                eyebrow: 'Site',
                title: widget.site.name,
                subtitle: isLoading || snapshot.hasError
                    ? null
                    : totalWorkers == 0
                    ? 'No workers assigned yet'
                    : '$totalReady of $totalWorkers workers Ready',
                icon: Icons.location_city,
                color: AppColors.compliance,
                footer: totalWorkers == 0
                    ? null
                    : _ReadinessBar(
                        ready: totalReady,
                        total: totalWorkers,
                        onColored: true,
                      ),
              ),
              const SizedBox(height: AppSpacing.md),
              if (snapshot.hasError)
                AuthErrorBanner(
                  // The raw error is appended for a non-AppException
                  // failure (an uncaught FirebaseException or similar) —
                  // this repository's Firestore/callable calls aren't
                  // wrapped in AppException translation the way most
                  // repositories are, so a generic "Could not load" banner
                  // alone gave no way to tell a permission problem apart
                  // from a data problem apart from a network problem.
                  message: switch (snapshot.error) {
                    AppException(:final message) => '$message Pull to retry.',
                    final error =>
                      'Could not load compliance data: $error Pull to '
                          'retry.',
                  },
                ),
              if (isLoading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (!isLoading && summaries.isEmpty && !snapshot.hasError)
                const EmptyState(
                  icon: Icons.engineering_outlined,
                  title: 'No active activities',
                  message:
                      'Add an activity at this site to review its crew\'s '
                      'readiness.',
                ),
              for (final summary in summaries) ...[
                _ActivitySummaryCard(
                  summary: summary,
                  onTap: () => setState(() => _selectedActivity = summary),
                ),
                const SizedBox(height: AppSpacing.sm),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// "Roofing — 18 workers, 15 Ready, 3 Not Ready."
class _ActivitySummaryCard extends StatelessWidget {
  const _ActivitySummaryCard({required this.summary, required this.onTap});

  final ActivityComplianceSummary summary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final allReady = summary.workerCount > 0 && summary.notReadyCount == 0;
    final color = summary.workerCount == 0
        ? AppColors.textSecondary
        : allReady
        ? AppColors.success
        : AppColors.hazards;
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: color.withValues(alpha: 0.5)),
      ),
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        leading: Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            hazardEmojiFor(summary.activityName),
            style: const TextStyle(fontSize: 22),
          ),
        ),
        title: Text(
          summary.activityName,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              summary.workerCount == 0
                  ? 'No workers assigned'
                  : '${summary.workerCount} '
                        '${summary.workerCount == 1 ? 'worker' : 'workers'} · '
                        '${summary.readyCount} Ready · '
                        '${summary.notReadyCount} Not Ready',
            ),
            if (summary.workerCount > 0) ...[
              const SizedBox(height: AppSpacing.xs),
              _ReadinessBar(
                ready: summary.readyCount,
                total: summary.workerCount,
              ),
            ],
          ],
        ),
        trailing: Icon(Icons.chevron_right, color: color),
      ),
    );
  }
}

/// Step 3: every worker assigned to one activity, each a
/// [_WorkerComplianceCard] that drills into [_WorkerComplianceDetailScreen].
class _ActivityWorkerListView extends StatelessWidget {
  const _ActivityWorkerListView({required this.summary, required this.onBack});

  final ActivityComplianceSummary summary;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        _BackRow(
          tooltip: 'Back to activities',
          label: 'All activities',
          onPressed: onBack,
        ),
        const SizedBox(height: AppSpacing.sm),
        FeatureHeader(
          eyebrow: 'Activity',
          title: summary.activityName,
          subtitle:
              '${summary.readyCount} Ready · '
              '${summary.notReadyCount} Not Ready',
          icon: Icons.engineering,
          color: summary.notReadyCount == 0
              ? AppColors.compliance
              : AppColors.hazards,
          footer: summary.workerCount == 0
              ? null
              : _ReadinessBar(
                  ready: summary.readyCount,
                  total: summary.workerCount,
                  onColored: true,
                ),
        ),
        const SizedBox(height: AppSpacing.md),
        if (summary.rows.isEmpty)
          const EmptyState(
            icon: Icons.groups_outlined,
            title: 'No workers assigned',
            message: 'Assign workers to this activity to review readiness.',
          ),
        for (final row in summary.rows) ...[
          _WorkerComplianceCard(
            row: row,
            onTap: () => Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute<void>(
                builder: (_) => _WorkerComplianceDetailScreen(row: row),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ],
    );
  }
}

class _WorkerComplianceCard extends StatelessWidget {
  const _WorkerComplianceCard({required this.row, required this.onTap});

  final WorkerComplianceRow row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final subtitleParts = [
      if (row.roleLabel != null) row.roleLabel!,
      if (row.workerTypeLabel != null) row.workerTypeLabel!,
      '${row.completedCount}/${row.requiredCount} completed',
    ];
    final color = row.isReady ? AppColors.success : AppColors.danger;
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: color.withValues(alpha: 0.45)),
      ),
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        leading: PersonAvatar(name: row.workerName),
        title: Text(
          row.workerName,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(subtitleParts.join(' · ')),
            if (row.requiredCount > 0) ...[
              const SizedBox(height: AppSpacing.xs),
              _ReadinessBar(
                ready: row.completedCount,
                total: row.requiredCount,
              ),
            ],
          ],
        ),
        trailing: _ReadinessChip(isReady: row.isReady),
      ),
    );
  }
}

class _ReadinessChip extends StatelessWidget {
  const _ReadinessChip({required this.isReady});

  final bool isReady;

  @override
  Widget build(BuildContext context) {
    return StatusBadge(
      label: isReady ? 'Ready' : 'Not Ready',
      color: isReady ? AppColors.success : AppColors.danger,
    );
  }
}

/// A green/red progress bar: [ready] of [total], green when complete.
/// [onColored] draws it in white for use on a colored header.
class _ReadinessBar extends StatelessWidget {
  const _ReadinessBar({
    required this.ready,
    required this.total,
    this.onColored = false,
  });

  final int ready;
  final int total;
  final bool onColored;

  @override
  Widget build(BuildContext context) {
    final fraction = total == 0 ? 0.0 : ready / total;
    final done = ready >= total;
    final fill = onColored
        ? Colors.white
        : done
        ? AppColors.success
        : AppColors.hazards;
    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 8,
              color: fill,
              backgroundColor: fill.withValues(alpha: 0.2),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Text(
          '${(fraction * 100).round()}%',
          style: AppTextStyles.label.copyWith(
            color: onColored ? Colors.white : fill,
          ),
        ),
      ],
    );
  }
}

/// "← All sites" — the way back up one level of the drill-down.
class _BackRow extends StatelessWidget {
  const _BackRow({
    required this.tooltip,
    required this.label,
    required this.onPressed,
  });

  final String tooltip;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          tooltip: tooltip,
          onPressed: onPressed,
          icon: const Icon(Icons.arrow_back, color: AppColors.compliance),
        ),
        Text(
          label,
          style: AppTextStyles.label.copyWith(color: AppColors.compliance),
        ),
      ],
    );
  }
}

/// Step 4: one worker's required/completed/outstanding learning detail,
/// with completion dates where available.
class _WorkerComplianceDetailScreen extends StatelessWidget {
  const _WorkerComplianceDetailScreen({required this.row});

  final WorkerComplianceRow row;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          FeatureHeader(
            eyebrow: row.activityName,
            title: row.workerName,
            subtitle: [
              if (row.roleLabel != null) row.roleLabel!,
              if (row.workerTypeLabel != null) row.workerTypeLabel!,
            ].join(' · '),
            icon: Icons.person,
            color: row.isReady ? AppColors.compliance : AppColors.hazards,
            trailing: _ReadinessChip(isReady: row.isReady),
            footer: row.requiredCount == 0
                ? null
                : _ReadinessBar(
                    ready: row.completedCount,
                    total: row.requiredCount,
                    onColored: true,
                  ),
          ),
          const SizedBox(height: AppSpacing.lg),
          FeatureSectionTitle(
            title: 'Outstanding (${row.outstandingCount})',
            icon: Icons.pending_actions,
            color: AppColors.danger,
          ),
          const SizedBox(height: AppSpacing.sm),
          if (row.outstandingLearning.isEmpty)
            const Text('Nothing outstanding.', style: AppTextStyles.bodyMedium),
          for (final learning in row.outstandingLearning)
            _LessonRow(
              color: AppColors.danger,
              icon: Icons.warning_amber,
              title: learning.title,
              subtitle: learning.type.label,
            ),
          const SizedBox(height: AppSpacing.lg),
          FeatureSectionTitle(
            title: 'Completed (${row.completedCount})',
            icon: Icons.task_alt,
            color: AppColors.success,
          ),
          const SizedBox(height: AppSpacing.sm),
          if (row.completedLearning.isEmpty)
            const Text(
              'No completed items yet.',
              style: AppTextStyles.bodyMedium,
            ),
          for (final learning in row.completedLearning)
            _LessonRow(
              color: AppColors.success,
              icon: Icons.check_circle,
              title: learning.title,
              subtitle: row.completedAtByLearningId[learning.id] != null
                  ? 'Completed on '
                            '${row.completedAtByLearningId[learning.id]!.toLocal()}'
                        .split('.')
                        .first
                  : learning.type.label,
            ),
        ],
      ),
    );
  }
}

/// One lesson on the worker readiness page, tinted red (outstanding) or
/// green (completed).
class _LessonRow extends StatelessWidget {
  const _LessonRow({
    required this.color,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final Color color;
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      color: Color.alphaBlend(
        color.withValues(alpha: 0.07),
        Theme.of(context).colorScheme.surface,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color.withValues(alpha: 0.45)),
      ),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color,
          child: Icon(icon, color: Colors.white),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle),
      ),
    );
  }
}
