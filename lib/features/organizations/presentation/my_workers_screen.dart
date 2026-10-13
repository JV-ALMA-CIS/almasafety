import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/person_avatar.dart';
import '../../../core/widgets/feature_header.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../activities/data/activity_admin_service.dart';
import '../../activities/data/activity_assignment_repository.dart';
import '../../activities/data/activity_assignment_service.dart';
import '../../activities/domain/activity.dart';
import '../../activities/presentation/activity_workers_screen.dart';
import '../../authentication/data/account_approval_service.dart';
import '../../authentication/domain/account_status.dart';
import '../../authentication/domain/app_role.dart';
import '../../authentication/domain/organization_user.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../data/organization_repository.dart';
import '../data/project_repository.dart';
import '../data/site_repository.dart';
import '../domain/organization.dart';
import '../domain/project.dart';
import '../domain/site.dart';

/// A Foreman's own Workers screen: who is currently assigned to their
/// site(s), grouped by activity, with the assign/remove authority this
/// role actually holds.
///
/// **Approving and assigning Workers is a Foreman's core, day-to-day
/// job** (PROJECT_CONTEXT.md §16) — a Site Manager/Admin approves and
/// places Foremen, but has no visibility into who is actually on the crew
/// day to day, since they hold no Daily Safety Meeting of their own. This
/// screen is therefore where a Foreman does that work directly, rather
/// than a read-only roster: tapping into one of their own site's
/// activities opens [ActivityWorkersScreen] — the SAME assign/remove UI a
/// Site Manager already uses for their own organization-wide oversight —
/// scoped fresh to the Foreman's own [Organization]/[Project]/[Site], all
/// resolved with single-document `get()` reads (always safe under
/// `firestore.rules`, unlike an unconstrained LIST query — see
/// [ActivityAdminService.getSiteActivities]'s own doc comment for why that
/// matters here specifically).
///
/// `firestore.rules`/`activity_assignment_callable.ts` independently
/// re-verify a Foreman's authority server-side (PHASE 3: confined to their
/// own `siteIds`, and only ever acting on a `worker`-role target) — this
/// screen shows nothing a server call would not already refuse if forged.
class MyWorkersScreen extends StatefulWidget {
  const MyWorkersScreen({
    super.key,
    this.approvalService,
    this.siteRepositoryFor,
    this.activityAdminService,
    this.organizationRepository,
    this.projectRepository,
    this.activityAssignmentRepositoryFor,
    this.activityAssignmentService,
  });

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real service.
  final AccountApprovalService? approvalService;

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real, organization-scoped repository.
  final SiteRepository Function(String organizationId)? siteRepositoryFor;

  /// Injected in tests. Backs `getSiteActivities` — a Foreman's
  /// `firestore.rules` grant on `activities` does not cover LIST queries
  /// (see that rule's own doc comment), so this screen's own activities
  /// are resolved via this callable instead of a direct query.
  final ActivityAdminService? activityAdminService;

  /// Injected in tests. Resolves the [Organization] handed to
  /// [ActivityWorkersScreen] when a Foreman drills into one activity.
  final OrganizationRepository? organizationRepository;

  /// Injected in tests. Resolves the [Project] handed to
  /// [ActivityWorkersScreen], mirroring [organizationRepository].
  final ProjectRepository Function(String organizationId)? projectRepository;

  /// Injected in tests. Passed straight through to [ActivityWorkersScreen]
  /// as its own `assignmentRepository`/`assignmentService`.
  final ActivityAssignmentRepository Function(String organizationId)?
  activityAssignmentRepositoryFor;
  final ActivityAssignmentService? activityAssignmentService;

  @override
  State<MyWorkersScreen> createState() => _MyWorkersScreenState();
}

class _MyWorkersScreenState extends State<MyWorkersScreen> {
  late final AccountApprovalService _approvalService =
      widget.approvalService ?? AccountApprovalService();
  late final SiteRepository Function(String organizationId) _siteRepositoryFor =
      widget.siteRepositoryFor ??
      (organizationId) => SiteRepository(
        firestoreService: FirestoreService(),
        organizationId: organizationId,
      );
  late final ActivityAdminService _activityAdminService =
      widget.activityAdminService ?? ActivityAdminService();
  late final OrganizationRepository _organizationRepository =
      widget.organizationRepository ??
      OrganizationRepository(firestoreService: FirestoreService());
  late final ProjectRepository Function(String organizationId)
  _projectRepositoryFor =
      widget.projectRepository ??
      (organizationId) => ProjectRepository(
        firestoreService: FirestoreService(),
        organizationId: organizationId,
      );

  List<OrganizationUser> _workers = const [];
  List<Site> _sites = const [];
  List<Activity> _activities = const [];
  bool _isLoading = true;
  String? _errorMessage;
  String? _loadedForOrganizationId;

  @override
  Widget build(BuildContext context) {
    final sessionController = context.watch<SessionController>();
    final membership = sessionController.activeMembership;
    final organizationId = sessionController.activeOrganizationId;
    final isForeman = membership?.role == AppRole.foreman;
    final siteIds = membership?.siteIds ?? const [];

    if (!isForeman || organizationId == null || siteIds.isEmpty) {
      // A Foreman with no site assigned yet reaches here rather than the
      // usual loading state — see this screen's class doc comment. Named
      // explicitly (rather than the generic "assigned to a site" wording)
      // so a Foreman seeing this for the first time knows this is a setup
      // step to ask their Site Manager for, not a broken screen.
      final message = isForeman
          ? "You have not been assigned to a site yet. Ask your Site "
                "Manager to assign you one from Operations → your "
                "project → your site → Workforce."
          : 'My Workers is available to a Foreman assigned to a site.';
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Text(
            message,
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    if (_loadedForOrganizationId != organizationId) {
      // Fires during build, deliberately: mirrors the established pattern
      // in this codebase's other screens whose data depends on the active
      // organization (e.g. DailySafetyMeetingScreen), since switching
      // organizations while this screen is open must reload rather than
      // silently keep showing the previous organization's data.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _load(organizationId, siteIds),
      );
    }

    return RefreshIndicator(
      onRefresh: () => _load(organizationId, siteIds),
      child: _buildBody(organizationId, siteIds),
    );
  }

  Future<void> _load(String organizationId, List<String> siteIds) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _loadedForOrganizationId = organizationId;
    });
    try {
      final activityLists = await Future.wait([
        for (final siteId in siteIds)
          _activityAdminService.getSiteActivities(
            organizationId: organizationId,
            siteId: siteId,
          ),
      ]);
      final results = await Future.wait([
        _approvalService.listUsers(
          status: AccountStatus.active,
          organizationId: organizationId,
        ),
        // watchByIds, not watchAll: firestore.rules only grants a Foreman
        // read access to sites whose id is in their OWN siteIds — an
        // unconstrained collection listing is refused outright for them.
        // See SiteRepository.watchByIds's doc comment.
        _siteRepositoryFor(organizationId).watchByIds(siteIds).first,
      ]);
      if (!mounted) return;
      final users = results[0] as List<OrganizationUser>;
      final sites = results[1] as List<Site>;
      setState(() {
        _workers = users
            .where(
              (user) =>
                  user.role == AppRole.worker &&
                  user.siteIds.any(siteIds.contains),
            )
            .toList(growable: false);
        _sites = sites;
        _activities = [
          for (final activities in activityLists)
            ...activities.where((a) => a.status.id == 'active'),
        ]..sort((a, b) => a.name.compareTo(b.name));
      });
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _openActivityWorkers(
    String organizationId,
    List<String> siteIds,
    Activity activity,
  ) async {
    setState(() => _errorMessage = null);
    try {
      final site = _sites.firstWhere((s) => s.id == activity.siteId);
      final results = await Future.wait([
        _organizationRepository.getById(organizationId),
        _projectRepositoryFor(organizationId).getById(activity.projectId),
      ]);
      if (!mounted) return;
      final organization = results[0] as Organization?;
      final project = results[1] as Project?;
      if (organization == null || project == null) {
        setState(
          () => _errorMessage =
              'Could not load that activity right now. Please try again.',
        );
        return;
      }
      await Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(
          builder: (_) => ActivityWorkersScreen(
            organization: organization,
            project: project,
            site: site,
            activity: activity,
            assignmentRepository: widget.activityAssignmentRepositoryFor?.call(
              organizationId,
            ),
            assignmentService: widget.activityAssignmentService,
            approvalService: widget.approvalService,
          ),
        ),
      );
      // The Foreman may have assigned/removed a worker while there —
      // refresh so this screen's own counts reflect it.
      if (mounted) _load(organizationId, siteIds);
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    }
  }

  Widget _buildBody(String organizationId, List<String> siteIds) {
    if (_isLoading && _workers.isEmpty && _errorMessage == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        FeatureHeader(
          title: 'My Workers',
          subtitle: 'Tap an activity to assign or remove a worker.',
          icon: Icons.groups,
          color: AppColors.people,
          chips: [
            FeatureChip(
              icon: Icons.handyman,
              label:
                  '${_activities.length} '
                  '${_activities.length == 1 ? 'activity' : 'activities'}',
            ),
            FeatureChip(
              icon: Icons.person,
              label:
                  '${_workers.length} '
                  '${_workers.length == 1 ? 'worker' : 'workers'}',
            ),
          ],
        ),
        if (_errorMessage != null) ...[
          const SizedBox(height: AppSpacing.md),
          AuthErrorBanner(message: _errorMessage!),
        ],
        const SizedBox(height: AppSpacing.lg),
        FeatureSectionTitle(
          title: 'Activities',
          icon: Icons.handyman,
          color: AppColors.projects,
          count: _activities.length,
        ),
        const SizedBox(height: AppSpacing.sm),
        if (!_isLoading && _activities.isEmpty && _errorMessage == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
            child: Text(
              'No active activities are recorded at your site(s) yet.',
              style: AppTextStyles.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ),
        for (final activity in _activities) ...[
          _ActivityCard(
            activity: activity,
            siteName: _sites
                .where((s) => s.id == activity.siteId)
                .map((s) => s.name)
                .firstOrNull,
            onTap: () =>
                _openActivityWorkers(organizationId, siteIds, activity),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        const SizedBox(height: AppSpacing.lg),
        FeatureSectionTitle(
          title: 'All Workers',
          icon: Icons.groups,
          color: AppColors.people,
          count: _workers.length,
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          siteIds.length > 1
              ? 'Every worker with access to your sites, whether or not '
                    "they're assigned to an activity yet."
              : 'Every worker with access to your site, whether or not '
                    "they're assigned to an activity yet.",
          style: AppTextStyles.bodyMedium,
        ),
        const SizedBox(height: AppSpacing.sm),
        if (!_isLoading && _workers.isEmpty && _errorMessage == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
            child: Text(
              'No workers are assigned to your site(s) yet. Approve one '
              'from Pending Approvals.',
              style: AppTextStyles.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ),
        for (final worker in _workers) ...[
          _WorkerCard(
            worker: worker,
            siteNames: {for (final site in _sites) site.id: site.name},
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ],
    );
  }
}

class _ActivityCard extends StatelessWidget {
  const _ActivityCard({
    required this.activity,
    required this.siteName,
    required this.onTap,
  });

  final Activity activity;
  final String? siteName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: AppColors.projects,
          child: const Icon(Icons.engineering, color: Colors.white),
        ),
        title: Text(
          activity.name,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: siteName != null ? Text(siteName!) : null,
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

class _WorkerCard extends StatelessWidget {
  const _WorkerCard({required this.worker, required this.siteNames});

  final OrganizationUser worker;
  final Map<String, String> siteNames;

  @override
  Widget build(BuildContext context) {
    final siteLabel = worker.siteIds
        .map((id) => siteNames[id] ?? id)
        .join(', ');
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: PersonAvatar(name: worker.name),
        title: Text(
          worker.name,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          [
            if (worker.trade != null) worker.trade!,
            if (worker.workerType != null) worker.workerType!.label,
            if (siteLabel.isNotEmpty) siteLabel,
          ].join(' · '),
        ),
      ),
    );
  }
}
