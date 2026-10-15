import 'package:flutter/material.dart';
import 'safety_reports_card.dart';
import 'whats_due_card.dart';
import '../../incidents/domain/incident.dart';
import '../../incidents/data/incident_repository.dart';
import 'package:go_router/go_router.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/dashboard_grid.dart';
import '../../../core/widgets/dashboard_header.dart';
import '../../../core/widgets/dashboard_section.dart';
import '../../../core/widgets/kpi_card.dart';
import '../../../routing/app_routes.dart';
import '../../authentication/domain/app_role.dart';
import '../../analytics/data/analytics_repository.dart';
import '../../analytics/domain/analytics_dashboard.dart';
import '../../corrective_actions/data/corrective_action_repository.dart';
import '../../corrective_actions/domain/corrective_action.dart';
import '../../hazards/data/hazard_repository.dart';
import '../../hazards/domain/hazard.dart';
import '../../hazards/domain/hazard_status.dart';
import '../../organizations/data/organization_repository.dart';
import '../../organizations/data/project_repository.dart';
import '../../organizations/data/site_repository.dart';
import '../../organizations/domain/organization.dart';
import '../../organizations/domain/site.dart';
import '../../safety_learning_compliance/data/safety_compliance_repository.dart';

/// An Admin's dashboard: organization-wide KPIs, sites/projects, learning
/// compliance, hazards/corrective actions, recent activity, and
/// organization attention items.
///
/// **An Admin has no organization of their own** (org-less by construction
/// — see [AppRole.isPlatformLevel]). JV Safety runs a single company today
/// — JV ALMA CIS is the only organization that exists, for every user, with
/// no multi-organization selection anywhere in the app (see
/// [OrganizationScopeSelector]'s own doc comment on the single-company
/// model) — so this screen resolves that sole organization silently via
/// [OrganizationRepository.getAll] instead of ever showing a picker: there
/// is nothing for an Admin to choose between. Uses [getAll] (a one-time
/// fetch), not [OrganizationRepository.watchAll] (a live stream) — the
/// stream's `.snapshots()` listener can emit an empty LOCAL CACHE result
/// before the server's real (non-empty) answer arrives on a cold client,
/// which this screen would have misread as "JV ALMA CIS has not been set up
/// yet" for a brief, confusing flash before the real dashboard loaded.
///
/// Every number is composed from EXISTING sources — no new backend:
/// [AnalyticsRepository.build] (the same org-wide aggregation
/// [SiteManagerDashboardScreen] already uses) for meetings/learning/
/// corrective-action metrics, [SiteRepository.watchAll]/
/// [ProjectRepository.watchAll] for the sites/projects counts, and
/// [HazardRepository.watchForOrganization]/
/// [CorrectiveActionRepository.watchForOrganization] merged and sorted by
/// `createdAt`/`updatedAt` client-side for "recent activity" — there is no
/// existing activity-feed repository, so this composes one from streams
/// already read elsewhere rather than introducing a new collection.
///
/// **Learning Readiness is deliberately NOT computed here.**
/// [SafetyComplianceRepository.buildSiteCompliance] fans out one
/// `watchResolvedRequiredLearning` query per worker at a site — exactly the
/// same per-worker query pattern that, when [AnalyticsRepository.build]
/// auto-fired it for every worker in the organization from this dashboard,
/// broke Firestore's read budget in production (see [AnalyticsRepository
/// .build]'s own `includeSafetyLearning` doc comment). Calling
/// [SafetyComplianceRepository.buildSiteCompliance] automatically here for
/// every site in the organization, on every dashboard visit, is the same
/// risk. [SafetyLearningComplianceScreen] already computes this safely, ON
/// DEMAND, for exactly one site the user picks — this screen links there
/// instead of recomputing it.
class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({
    super.key,
    this.userUid,
    this.analyticsRepository,
    this.incidentRepository,
    this.hazardRepository,
    this.correctiveActionRepository,
    this.siteRepository,
    this.projectRepository,
    this.organizationRepository,
    this.safetyComplianceRepository,
    this.userName,
  });

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real dependencies scoped to the selected organization.
  /// The signed-in Admin's name, shown in the dashboard banner. Passed in
  /// by [DashboardRouterScreen] rather than read from [SessionController]
  /// here, so this screen keeps working without one (as in its tests).
  final String? userName;

  /// The signed-in Admin, for "What's Due" (what awaits THEIR sign-off).
  final String? userUid;

  final AnalyticsRepository? analyticsRepository;
  final IncidentRepository? incidentRepository;
  final HazardRepository? hazardRepository;
  final CorrectiveActionRepository? correctiveActionRepository;
  final SiteRepository? siteRepository;
  final ProjectRepository? projectRepository;
  final SafetyComplianceRepository? safetyComplianceRepository;

  /// Injected in tests. Backs the silent sole-organization resolution.
  final OrganizationRepository? organizationRepository;

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  late final OrganizationRepository _organizationRepository =
      widget.organizationRepository ??
      OrganizationRepository(firestoreService: FirestoreService());

  String? _loadedForOrganizationId;
  bool _isLoading = false;
  String? _errorMessage;
  AnalyticsDashboard? _dashboard;
  List<Hazard> _hazards = const [];
  List<Incident> _incidents = const [];
  List<CorrectiveAction> _correctiveActions = const [];
  int _siteCount = 0;
  int _projectCount = 0;

  Future<void> _load(String organizationId) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _loadedForOrganizationId = organizationId;
    });
    final firestoreService = FirestoreService();
    final analyticsRepository =
        widget.analyticsRepository ??
        AnalyticsRepository(
          firestoreService: firestoreService,
          organizationId: organizationId,
        );
    final hazardRepository =
        widget.hazardRepository ??
        HazardRepository(
          firestoreService: firestoreService,
          organizationId: organizationId,
        );
    final incidentRepository =
        widget.incidentRepository ??
        IncidentRepository(
          firestoreService: firestoreService,
          organizationId: organizationId,
        );
    final correctiveActionRepository =
        widget.correctiveActionRepository ??
        CorrectiveActionRepository(
          firestoreService: firestoreService,
          organizationId: organizationId,
        );
    final siteRepository =
        widget.siteRepository ??
        SiteRepository(
          firestoreService: firestoreService,
          organizationId: organizationId,
        );
    final projectRepository =
        widget.projectRepository ??
        ProjectRepository(
          firestoreService: firestoreService,
          organizationId: organizationId,
        );
    try {
      final results = await Future.wait([
        // Safety Learning is deliberately excluded from this build — see
        // AnalyticsRepository.build's own doc comment on why an
        // auto-loading dashboard must not trigger its per-worker
        // collection-group fan-out.
        analyticsRepository.build(includeSafetyLearning: false),
        hazardRepository.watchForOrganization().first,
        correctiveActionRepository.watchForOrganization().first,
        siteRepository.watchAll().first,
        projectRepository.watchAll().first,
        incidentRepository.watchForOrganization().first.catchError(
          (Object _) => const <Incident>[],
        ),
      ]);
      if (!mounted) return;
      final sites = results[3] as List<Site>;
      setState(() {
        _dashboard = results[0] as AnalyticsDashboard;
        _hazards = results[1] as List<Hazard>;
        _correctiveActions = results[2] as List<CorrectiveAction>;
        _siteCount = sites.length;
        _projectCount = (results[4] as List).length;
        _incidents = results[5] as List<Incident>;
      });
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  late final Future<List<Organization>> _organizationsFuture =
      _organizationRepository.getAll();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Organization>>(
      future: _organizationsFuture,
      builder: (context, snapshot) {
        final organizations = snapshot.data;
        if (organizations == null) {
          return const Center(child: CircularProgressIndicator());
        }
        // JV Safety is single-company: exactly one organization ever
        // exists, for every user — see this screen's own doc comment. No
        // picker is ever shown; an unexpected zero/multi-organization state
        // (e.g. a fresh deployment with none set up yet) gets a plain
        // message instead of silently guessing one.
        if (organizations.length != 1) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.lg),
              child: Text(
                'JV ALMA CIS has not been set up yet.',
                style: AppTextStyles.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return _buildDashboard(context, organizations.single.id);
      },
    );
  }

  Widget _buildDashboard(BuildContext context, String organizationId) {
    if (_loadedForOrganizationId != organizationId) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _load(organizationId),
      );
    }

    final dashboard = _dashboard;

    return RefreshIndicator(
      onRefresh: () => _load(organizationId),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          DashboardHeader(
            title: 'Dashboard',
            role: AppRole.admin,
            userName: widget.userName,
            subtitle: 'JV ALMA CIS — organization overview',
            icon: Icons.admin_panel_settings,
          ),
          const SizedBox(height: AppSpacing.lg),
          if (widget.userUid != null) ...[
            DashboardSection(
              title: "What's Due",
              color: AppColors.warning,
              icon: Icons.event_available,
              child: WhatsDueCard(
                organizationId: organizationId,
                uid: widget.userUid!,
                isManager: true,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
          ],
          if (_errorMessage != null) ...[
            Text(
              _errorMessage!,
              style: AppTextStyles.bodyMedium.copyWith(color: AppColors.danger),
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          if (_isLoading && dashboard == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (dashboard != null) ...[
            DashboardSection(
              title: 'Organization KPIs',
              color: AppColors.dashboard,
              icon: Icons.insights,
              child: DashboardGrid(
                children: [
                  KpiCard(
                    value: '$_siteCount',
                    label: _siteCount == 1 ? 'site' : 'sites',
                    icon: Icons.location_city_outlined,
                    color: AppColors.projects,
                    onTap: () => context.go(AppRoutes.projects),
                  ),
                  KpiCard(
                    value: '$_projectCount',
                    label: _projectCount == 1 ? 'project' : 'projects',
                    icon: Icons.apartment_outlined,
                    color: AppColors.projects,
                    onTap: () => context.go(AppRoutes.projects),
                  ),
                  KpiCard(
                    value: '${dashboard.meetings.totalCount}',
                    label: 'meetings',
                    icon: Icons.fact_check_outlined,
                    color: AppColors.meetings,
                    onTap: () => context.go(AppRoutes.dailySafetyMeetings),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            DashboardSection(
              title: 'Learning Compliance',
              color: AppColors.compliance,
              icon: Icons.verified_user_outlined,
              child: Card(
                margin: EdgeInsets.zero,
                child: ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    decoration: BoxDecoration(
                      color: AppColors.compliance,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.verified_user_outlined,
                      color: Colors.white,
                    ),
                  ),
                  title: const Text('View site learning readiness'),
                  subtitle: const Text(
                    'See who is ready for the work at each site.',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.go(AppRoutes.safetyLearningCompliance),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            DashboardSection(
              title: 'Safety Reports',
              color: AppColors.stop,
              icon: Icons.campaign_outlined,
              child: SafetyReportsCard(
                hazards: _hazards,
                incidents: _incidents,
                showToInvestigate: true,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            DashboardSection(
              title: 'Corrective Actions',
              color: AppColors.correctiveActions,
              icon: Icons.build_outlined,
              child: DashboardGrid(
                children: [
                  KpiCard(
                    value: '${dashboard.correctiveActions.openCount}',
                    label: 'open actions',
                    icon: Icons.build_outlined,
                    color: AppColors.correctiveActions,
                    onTap: () => context.go(AppRoutes.correctiveActions),
                  ),
                  KpiCard(
                    value: '${dashboard.correctiveActions.overdueCount}',
                    label: 'overdue',
                    icon: Icons.schedule_outlined,
                    color: dashboard.correctiveActions.overdueCount > 0
                        ? AppColors.danger
                        : AppColors.success,
                    onTap: () => context.go(AppRoutes.correctiveActions),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            DashboardSection(
              title: 'Recent Activity',
              color: AppColors.analytics,
              icon: Icons.history,
              child: _RecentActivity(
                hazards: _hazards,
                correctiveActions: _correctiveActions,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            DashboardSection(
              title: 'Attention Required',
              color: AppColors.danger,
              icon: Icons.priority_high,
              child: _AttentionRequired(
                overdueActionCount: dashboard.correctiveActions.overdueCount,
                openHazardCount: _openHazardCount(_hazards),
                onOverdueActionsTap: () =>
                    context.go(AppRoutes.correctiveActions),
                onHazardsTap: () => context.go(AppRoutes.hazards),
              ),
            ),
          ],
        ],
      ),
    );
  }

  int _openHazardCount(List<Hazard> hazards) =>
      hazards.where((h) => h.status != HazardStatus.closed).length;
}

/// Merges hazards and corrective actions into one feed, most-recent-first
/// by `createdAt` — composed client-side from streams already read above;
/// there is no existing activity-feed repository to reuse.
class _RecentActivity extends StatelessWidget {
  const _RecentActivity({
    required this.hazards,
    required this.correctiveActions,
  });

  final List<Hazard> hazards;
  final List<CorrectiveAction> correctiveActions;

  @override
  Widget build(BuildContext context) {
    final entries = [
      for (final hazard in hazards)
        if (hazard.createdAt != null)
          (
            time: hazard.createdAt!,
            icon: Icons.warning_amber_outlined,
            message: 'Hazard reported: ${hazard.category.label}',
          ),
      for (final action in correctiveActions)
        if (action.createdAt != null)
          (
            time: action.createdAt!,
            icon: Icons.build_outlined,
            message: 'Corrective action created: ${action.title}',
          ),
    ]..sort((a, b) => b.time.compareTo(a.time));

    if (entries.isEmpty) {
      return const Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.md),
          child: Text(
            'No recent activity yet.',
            style: AppTextStyles.bodyMedium,
          ),
        ),
      );
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          for (final entry in entries.take(10))
            ListTile(
              leading: Icon(entry.icon),
              title: Text(entry.message),
              subtitle: Text(_formatDate(entry.time)),
            ),
        ],
      ),
    );
  }
}

class _AttentionRequired extends StatelessWidget {
  const _AttentionRequired({
    required this.overdueActionCount,
    required this.openHazardCount,
    required this.onOverdueActionsTap,
    required this.onHazardsTap,
  });

  final int overdueActionCount;
  final int openHazardCount;
  final VoidCallback onOverdueActionsTap;
  final VoidCallback onHazardsTap;

  @override
  Widget build(BuildContext context) {
    final items = [
      if (overdueActionCount > 0)
        _AttentionItem(
          icon: Icons.schedule_outlined,
          message: overdueActionCount == 1
              ? '1 corrective action is overdue.'
              : '$overdueActionCount corrective actions are overdue.',
          onTap: onOverdueActionsTap,
        ),
      if (openHazardCount > 0)
        _AttentionItem(
          icon: Icons.warning_amber_outlined,
          message: openHazardCount == 1
              ? '1 hazard is still open.'
              : '$openHazardCount hazards are still open.',
          onTap: onHazardsTap,
        ),
    ];

    if (items.isEmpty) {
      return const Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.md),
          child: Text(
            'Nothing needs attention right now.',
            style: AppTextStyles.bodyMedium,
          ),
        ),
      );
    }

    return Column(
      children: [
        for (final item in items) ...[
          item,
          const SizedBox(height: AppSpacing.sm),
        ],
      ],
    );
  }
}

class _AttentionItem extends StatelessWidget {
  const _AttentionItem({required this.icon, required this.message, this.onTap});

  final IconData icon;
  final String message;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppSpacing.sm),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              Icon(icon, color: AppColors.danger),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: Text(message, style: AppTextStyles.bodyMedium)),
            ],
          ),
        ),
      ),
    );
  }
}

String _formatDate(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}
