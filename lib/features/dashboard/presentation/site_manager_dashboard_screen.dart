import 'package:flutter/material.dart';
import '../../incidents/domain/incident_enums.dart';
import 'safety_reports_card.dart';
import 'whats_due_card.dart';
import '../../incidents/domain/incident.dart';
import '../../incidents/data/incident_repository.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
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
import '../../hazards/data/hazard_repository.dart';
import '../../hazards/domain/hazard.dart';
import '../../hazards/domain/hazard_status.dart';
import '../../organizations/data/site_repository.dart';
import '../../safety_learning_compliance/data/safety_compliance_repository.dart';

/// A Site Manager's dashboard: Site KPIs, Learning compliance, Hazards,
/// Corrective Actions, Meetings, and Attention Required — every number
/// drawn from [AnalyticsRepository.build] (the exact same org-wide
/// aggregation [AnalyticsScreen] already computes across Safety Meetings,
/// Attendance, Concerns, Corrective Actions, Safety Alerts and Safety
/// Learning) plus [HazardRepository.watchForOrganization] for the one
/// metric Analytics does not yet cover (hazards). No new backend, no new
/// aggregation logic beyond what those two sources already provide.
///
/// **Generated once per visit, not live-streamed** — matching
/// [AnalyticsScreen]'s own "point-in-time snapshot, not an operational
/// worklist" rationale: [AnalyticsRepository.build] fans out per meeting for
/// attendance/concerns, so re-running it on every Firestore write anywhere
/// in the organization would be wasteful. A pull-to-refresh re-runs it.
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
class SiteManagerDashboardScreen extends StatefulWidget {
  const SiteManagerDashboardScreen({
    super.key,
    this.analyticsRepository,
    this.incidentRepository,
    this.hazardRepository,
    this.siteRepository,
    this.safetyComplianceRepository,
  });

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real dependencies scoped to the signed-in user's
  /// organization.
  final AnalyticsRepository? analyticsRepository;
  final IncidentRepository? incidentRepository;
  final HazardRepository? hazardRepository;
  final SiteRepository? siteRepository;
  final SafetyComplianceRepository? safetyComplianceRepository;

  @override
  State<SiteManagerDashboardScreen> createState() =>
      _SiteManagerDashboardScreenState();
}

class _SiteManagerDashboardScreenState
    extends State<SiteManagerDashboardScreen> {
  String? _loadedForOrganizationId;
  bool _isLoading = false;
  String? _errorMessage;
  AnalyticsDashboard? _dashboard;
  List<Hazard> _hazards = const [];
  List<Incident> _incidents = const [];

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
    try {
      final results = await Future.wait([
        // Safety Learning is deliberately excluded from this build — see
        // AnalyticsRepository.build's own doc comment on why an
        // auto-loading dashboard must not trigger its per-worker
        // collection-group fan-out.
        analyticsRepository.build(includeSafetyLearning: false),
        hazardRepository.watchForOrganization().first,
        incidentRepository.watchForOrganization().first.catchError(
          (Object _) => const <Incident>[],
        ),
      ]);
      if (!mounted) return;
      setState(() {
        _dashboard = results[0] as AnalyticsDashboard;
        _hazards = results[1] as List<Hazard>;
        _incidents = results[2] as List<Incident>;
      });
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sessionController = context.watch<SessionController>();
    final organizationId = sessionController.activeOrganizationId;

    if (organizationId == null) {
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

    if (_loadedForOrganizationId != organizationId) {
      // Fires during build, deliberately — mirrors the established pattern
      // in this codebase's other screens whose data depends on the active
      // organization (e.g. MyWorkersScreen).
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
            role: AppRole.siteManager,
            userName: sessionController.profile?.name,
            icon: Icons.engineering,
          ),
          const SizedBox(height: AppSpacing.lg),
          if (sessionController.profile?.uid != null) ...[
            DashboardSection(
              title: "What's Due",
              color: AppColors.warning,
              icon: Icons.event_available,
              child: WhatsDueCard(
                organizationId: organizationId,
                uid: sessionController.profile!.uid,
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
              title: 'Site KPIs',
              color: AppColors.dashboard,
              icon: Icons.insights,
              child: DashboardGrid(
                children: [
                  KpiCard(
                    value: '${dashboard.meetings.totalCount}',
                    label: 'meetings',
                    icon: Icons.fact_check_outlined,
                    color: AppColors.meetings,
                    onTap: () => context.go(AppRoutes.dailySafetyMeetings),
                  ),
                  KpiCard(
                    value: '${dashboard.attendance.presentCount}',
                    label: 'present',
                    icon: Icons.groups_outlined,
                    color: AppColors.success,
                  ),
                  KpiCard(
                    value: '${dashboard.concerns.openCount}',
                    label: 'open concerns',
                    icon: Icons.report_problem_outlined,
                    color: dashboard.concerns.openCount > 0
                        ? AppColors.warning
                        : AppColors.success,
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
              trailing: TextButton(
                onPressed: () => context.go(AppRoutes.correctiveActions),
                child: const Text('See all'),
              ),
              child: DashboardGrid(
                children: [
                  KpiCard(
                    value: '${dashboard.correctiveActions.openCount}',
                    label: 'open',
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
                  KpiCard(
                    value:
                        '${dashboard.correctiveActions.completionRate.round()}%',
                    label: 'completed',
                    icon: Icons.task_alt_outlined,
                    color: AppColors.success,
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            DashboardSection(
              title: 'Meetings',
              color: AppColors.meetings,
              icon: Icons.fact_check_outlined,
              trailing: TextButton(
                onPressed: () => context.go(AppRoutes.dailySafetyMeetings),
                child: const Text('See all'),
              ),
              child: DashboardGrid(
                children: [
                  KpiCard(
                    value: '${dashboard.meetings.completedCount}',
                    label: 'completed',
                    icon: Icons.check_circle_outline,
                    color: AppColors.success,
                  ),
                  KpiCard(
                    value: '${dashboard.meetings.inProgressCount}',
                    label: 'in progress',
                    icon: Icons.pending_outlined,
                    color: AppColors.warning,
                  ),
                ],
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
                incidentsToInvestigate: _incidents
                    .where((i) => i.status == IncidentStatus.reported)
                    .length,
                openConcernCount: dashboard.concerns.openCount,
                onOverdueActionsTap: () =>
                    context.go(AppRoutes.correctiveActions),
                onHazardsTap: () => context.go(AppRoutes.hazards),
                onIncidentsTap: () => context.go(AppRoutes.incidents),
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

class _AttentionRequired extends StatelessWidget {
  const _AttentionRequired({
    required this.overdueActionCount,
    required this.openHazardCount,
    required this.incidentsToInvestigate,
    required this.openConcernCount,
    required this.onOverdueActionsTap,
    required this.onHazardsTap,
    required this.onIncidentsTap,
  });

  final int overdueActionCount;
  final int openHazardCount;
  final int incidentsToInvestigate;
  final int openConcernCount;
  final VoidCallback onOverdueActionsTap;
  final VoidCallback onHazardsTap;
  final VoidCallback onIncidentsTap;

  @override
  Widget build(BuildContext context) {
    final items = [
      if (incidentsToInvestigate > 0)
        _AttentionItem(
          icon: Icons.personal_injury_outlined,
          message: incidentsToInvestigate == 1
              ? '1 incident is waiting for investigation.'
              : '$incidentsToInvestigate incidents are waiting for '
                    'investigation.',
          onTap: onIncidentsTap,
        ),
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
      if (openConcernCount > 0)
        _AttentionItem(
          icon: Icons.report_problem_outlined,
          message: openConcernCount == 1
              ? '1 meeting concern is still open.'
              : '$openConcernCount meeting concerns are still open.',
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
