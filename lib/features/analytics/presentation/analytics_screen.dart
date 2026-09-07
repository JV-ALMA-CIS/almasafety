import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/organization_scope_selector.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../../organizations/data/organization_repository.dart';
import '../../organizations/data/project_repository.dart';
import '../../organizations/data/site_repository.dart';
import '../../organizations/domain/project.dart';
import '../../organizations/domain/site.dart';
import '../data/analytics_repository.dart';
import '../domain/analytics_dashboard.dart';
import '../domain/attendance_metrics.dart';
import '../domain/concern_metrics.dart';
import '../domain/corrective_action_metrics.dart';
import '../domain/safety_alert_metrics.dart';
import '../domain/safety_learning_metrics.dart';

/// The Analytics dashboard — read-only summary metrics across Safety
/// Meetings, Attendance, Concerns, Corrective Actions, Safety Alerts and
/// Safety Learning.
///
/// **Authorized management users only**, using the exact same role gate
/// [ReportsScreen]/[CorrectiveActionsScreen]/[SafetyAlertsScreen] already
/// use (`AppRole.canReviewPendingAccounts`) — this is not a new RBAC
/// concept, it is the existing reviewer-role boundary applied to a fifth
/// screen. A `foreman`/`worker` sees an access message instead.
///
/// Generated on demand ("Refresh"), matching [ReportsScreen]'s own
/// point-in-time-snapshot rationale — a dashboard summary is an
/// analysis surface, not an operational worklist, and this avoids
/// re-running [AnalyticsRepository]'s per-meeting attendance/concern
/// fan-out on every Firestore write anywhere in the organization.
class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({
    super.key,
    this.repository,
    this.projectRepository,
    this.siteRepository,
    this.organizationRepository,
  });

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real dependencies scoped to the signed-in user's
  /// organization.
  final AnalyticsRepository? repository;
  final ProjectRepository? projectRepository;
  final SiteRepository? siteRepository;

  /// Injected in tests. Backs [OrganizationScopeSelector] for a System
  /// Administrator, who has no organization of their own to scope
  /// [repository]/[projectRepository]/[siteRepository] to.
  final OrganizationRepository? organizationRepository;

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  AnalyticsRepository? _repository;
  ProjectRepository? _projectRepository;
  SiteRepository? _siteRepository;

  String? _projectId;
  String? _siteId;
  DateTime? _from;
  DateTime? _to;

  bool _isLoading = false;
  String? _errorMessage;
  AnalyticsDashboard? _dashboard;
  String? _selectedOrganizationId;

  AnalyticsRepository _repositoryFor(String organizationId) {
    final existing = _repository;
    if (existing != null && existing.organizationId == organizationId) {
      return existing;
    }
    final created = widget.repository ??
        AnalyticsRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );
    _repository = created;
    return created;
  }

  ProjectRepository _projectRepositoryFor(String organizationId) {
    return _projectRepository ??=
        widget.projectRepository ??
        ProjectRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );
  }

  SiteRepository _siteRepositoryFor(String organizationId) {
    return _siteRepository ??=
        widget.siteRepository ??
        SiteRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );
  }

  Future<void> _generate(String organizationId) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final dashboard = await _repositoryFor(organizationId).build(
        projectId: _projectId,
        siteId: _siteId,
        from: _from,
        to: _to,
      );
      if (!mounted) return;
      setState(() => _dashboard = dashboard);
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 2),
      lastDate: now.add(const Duration(days: 1)),
      initialDateRange: _from != null && _to != null
          ? DateTimeRange(start: _from!, end: _to!)
          : null,
    );
    if (picked != null) {
      setState(() {
        _from = picked.start;
        _to = picked.end;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final sessionController = context.watch<SessionController>();
    final profile = sessionController.profile;
    final isPlatformAdministrator = profile?.isPlatformAdministrator ?? false;
    final canManage = isPlatformAdministrator ||
        (sessionController.activeMembership?.role.canReviewPendingAccounts ??
            false);
    final organizationId = isPlatformAdministrator
        ? _selectedOrganizationId
        : sessionController.activeOrganizationId;

    if (!canManage) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: Text(
            'Analytics is available to Organization Administrators, '
            'Safety Managers and Site Superintendents.',
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
          onChanged: (value) => setState(() => _selectedOrganizationId = value),
          repository: widget.organizationRepository,
        ),
      );
    }

    return StreamBuilder<List<Project>>(
      stream: _projectRepositoryFor(organizationId).watchAll(),
      builder: (context, projectSnapshot) {
        final projects = projectSnapshot.data ?? const <Project>[];

        return StreamBuilder<List<Site>>(
          stream: _siteRepositoryFor(organizationId).watchAll(),
          builder: (context, siteSnapshot) {
            final sites = siteSnapshot.data ?? const <Site>[];
            final visibleSites = _projectId == null
                ? sites
                : sites.where((s) => s.projectId == _projectId).toList();

            return ListView(
              padding: const EdgeInsets.all(AppSpacing.md),
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                Text('Analytics', style: AppTextStyles.headlineMedium),
                const SizedBox(height: AppSpacing.md),
                if (isPlatformAdministrator)
                  OrganizationScopeSelector(
                    selectedOrganizationId: _selectedOrganizationId,
                    onChanged: (value) =>
                        setState(() => _selectedOrganizationId = value),
                    repository: widget.organizationRepository,
                  ),
                if (_errorMessage != null) ...[
                  AuthErrorBanner(message: _errorMessage!),
                  const SizedBox(height: AppSpacing.md),
                ],
                Text('Project', style: AppTextStyles.label),
                const SizedBox(height: AppSpacing.xs),
                DropdownButtonFormField<String?>(
                  initialValue: _projectId,
                  decoration: const InputDecoration(hintText: 'All projects'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('All projects')),
                    for (final project in projects)
                      DropdownMenuItem(
                        value: project.id,
                        child: Text(project.name),
                      ),
                  ],
                  onChanged: (value) => setState(() {
                    _projectId = value;
                    _siteId = null;
                  }),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text('Site', style: AppTextStyles.label),
                const SizedBox(height: AppSpacing.xs),
                DropdownButtonFormField<String?>(
                  initialValue: _siteId,
                  decoration: const InputDecoration(hintText: 'All sites'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('All sites')),
                    for (final site in visibleSites)
                      DropdownMenuItem(value: site.id, child: Text(site.name)),
                  ],
                  onChanged: (value) => setState(() => _siteId = value),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text('Date range', style: AppTextStyles.label),
                const SizedBox(height: AppSpacing.xs),
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: AppSpacing.minTouchTarget,
                  ),
                  child: OutlinedButton.icon(
                    onPressed: _pickDateRange,
                    icon: const Icon(Icons.date_range_outlined),
                    label: Text(
                      _from == null || _to == null
                          ? 'All dates'
                          : '${_formatDate(_from)} – ${_formatDate(_to)}',
                    ),
                  ),
                ),
                if (_from != null)
                  TextButton(
                    onPressed: () => setState(() {
                      _from = null;
                      _to = null;
                    }),
                    child: const Text('Clear date range'),
                  ),
                const SizedBox(height: AppSpacing.md),
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: AppSpacing.minTouchTarget,
                  ),
                  child: ElevatedButton.icon(
                    onPressed: _isLoading ? null : () => _generate(organizationId),
                    icon: const Icon(Icons.dashboard_outlined),
                    label: Text(_isLoading ? 'Loading…' : 'Refresh'),
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                if (_isLoading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_dashboard == null)
                  const _EmptyDashboard()
                else
                  _DashboardView(dashboard: _dashboard!),
              ],
            );
          },
        );
      },
    );
  }
}

class _EmptyDashboard extends StatelessWidget {
  const _EmptyDashboard();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
      child: Column(
        children: [
          Icon(
            Icons.bar_chart_outlined,
            size: 48,
            color: AppColors.textSecondary,
          ),
          SizedBox(height: AppSpacing.sm),
          Text(
            'Choose your filters and tap Refresh to load the dashboard.',
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _DashboardView extends StatelessWidget {
  const _DashboardView({required this.dashboard});

  final AnalyticsDashboard dashboard;

  @override
  Widget build(BuildContext context) {
    final hasAnyData = dashboard.meetings.totalCount > 0 ||
        dashboard.safetyAlerts.totalCount > 0 ||
        dashboard.correctiveActions.totalCount > 0 ||
        dashboard.safetyLearning.assignedCount > 0;

    if (!hasAnyData) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
        child: Text(
          'No data for the selected filters.',
          style: AppTextStyles.bodyMedium,
          textAlign: TextAlign.center,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle('Safety Meetings'),
        _MetricRow(
          cards: [
            _MetricCard(label: 'Completed', value: '${dashboard.meetings.completedCount}'),
            _MetricCard(label: 'In Progress', value: '${dashboard.meetings.inProgressCount}'),
          ],
        ),
        if (dashboard.meetings.bySite.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          _BarBreakdown(title: 'Meetings by site', values: dashboard.meetings.bySite),
        ],
        if (dashboard.meetings.byDate.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          _BarBreakdown(title: 'Meetings by date', values: dashboard.meetings.byDate),
        ],
        const SizedBox(height: AppSpacing.lg),
        _SectionTitle('Attendance'),
        _AttendanceSection(metrics: dashboard.attendance),
        const SizedBox(height: AppSpacing.lg),
        _SectionTitle('Concerns'),
        _ConcernSection(metrics: dashboard.concerns),
        const SizedBox(height: AppSpacing.lg),
        _SectionTitle('Corrective Actions'),
        _CorrectiveActionSection(metrics: dashboard.correctiveActions),
        const SizedBox(height: AppSpacing.lg),
        _SectionTitle('Safety Alerts'),
        _SafetyAlertSection(metrics: dashboard.safetyAlerts),
        const SizedBox(height: AppSpacing.lg),
        _SectionTitle('Safety Learning'),
        _SafetyLearningSection(metrics: dashboard.safetyLearning),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Text(title, style: AppTextStyles.titleLarge),
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({required this.cards});

  final List<_MetricCard> cards;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        for (final card in cards)
          SizedBox(width: 150, child: card),
      ],
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              style: AppTextStyles.headlineMedium.copyWith(color: color),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(label, style: AppTextStyles.bodyMedium),
          ],
        ),
      ),
    );
  }
}

/// A simple horizontal-bar breakdown — proportional bars sized against the
/// largest value, with a numeric label. Deliberately not a charting
/// library: this stage's scope is "simple summary information," not a
/// general analytics/visualization surface.
class _BarBreakdown extends StatelessWidget {
  const _BarBreakdown({required this.title, required this.values});

  final String title;
  final Map<String, int> values;

  @override
  Widget build(BuildContext context) {
    final maxValue = values.values.isEmpty
        ? 0
        : values.values.reduce((a, b) => a > b ? a : b);
    final entries = values.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: AppTextStyles.label),
            const SizedBox(height: AppSpacing.sm),
            for (final entry in entries)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                child: Row(
                  children: [
                    SizedBox(
                      width: 96,
                      child: Text(
                        entry.key,
                        style: AppTextStyles.bodyMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.xs,
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: maxValue == 0 ? 0 : entry.value / maxValue,
                            minHeight: 8,
                            backgroundColor: AppColors.background,
                            valueColor: const AlwaysStoppedAnimation(
                              AppColors.primary,
                            ),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 24,
                      child: Text(
                        '${entry.value}',
                        style: AppTextStyles.bodyMedium,
                        textAlign: TextAlign.right,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AttendanceSection extends StatelessWidget {
  const _AttendanceSection({required this.metrics});

  final AttendanceMetrics metrics;

  @override
  Widget build(BuildContext context) {
    return _MetricRow(
      cards: [
        _MetricCard(label: 'Present', value: '${metrics.presentCount}'),
        _MetricCard(label: 'Absent', value: '${metrics.absentCount}'),
        _MetricCard(
          label: 'Attendance %',
          value: '${metrics.attendancePercentage.toStringAsFixed(0)}%',
        ),
      ],
    );
  }
}

class _ConcernSection extends StatelessWidget {
  const _ConcernSection({required this.metrics});

  final ConcernMetrics metrics;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _MetricRow(
          cards: [
            _MetricCard(label: 'Total', value: '${metrics.totalCount}'),
            _MetricCard(label: 'Open', value: '${metrics.openCount}'),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        _BarBreakdown(
          title: 'Concerns by category',
          values: {
            for (final entry in metrics.byCategory.entries)
              entry.key.label: entry.value,
          },
        ),
      ],
    );
  }
}

class _CorrectiveActionSection extends StatelessWidget {
  const _CorrectiveActionSection({required this.metrics});

  final CorrectiveActionMetrics metrics;

  @override
  Widget build(BuildContext context) {
    return _MetricRow(
      cards: [
        _MetricCard(label: 'Total', value: '${metrics.totalCount}'),
        _MetricCard(label: 'Open', value: '${metrics.openCount}'),
        _MetricCard(label: 'In Progress', value: '${metrics.inProgressCount}'),
        _MetricCard(label: 'Completed', value: '${metrics.completedCount}'),
        _MetricCard(
          label: 'Overdue',
          value: '${metrics.overdueCount}',
          color: metrics.overdueCount > 0 ? AppColors.danger : null,
        ),
        _MetricCard(
          label: 'Completion Rate',
          value: '${metrics.completionRate.toStringAsFixed(0)}%',
        ),
      ],
    );
  }
}

class _SafetyAlertSection extends StatelessWidget {
  const _SafetyAlertSection({required this.metrics});

  final SafetyAlertMetrics metrics;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _MetricRow(
          cards: [
            _MetricCard(label: 'Active', value: '${metrics.activeCount}'),
            _MetricCard(
              label: 'Acknowledged',
              value: '${metrics.acknowledgedCount}',
            ),
            _MetricCard(label: 'Resolved', value: '${metrics.resolvedCount}'),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        _BarBreakdown(
          title: 'Alerts by severity',
          values: {
            for (final entry in metrics.bySeverity.entries)
              entry.key.label: entry.value,
          },
        ),
        const SizedBox(height: AppSpacing.sm),
        _BarBreakdown(
          title: 'Alerts by category',
          values: {
            for (final entry in metrics.byCategory.entries)
              entry.key.label: entry.value,
          },
        ),
      ],
    );
  }
}

class _SafetyLearningSection extends StatelessWidget {
  const _SafetyLearningSection({required this.metrics});

  final SafetyLearningMetrics metrics;

  @override
  Widget build(BuildContext context) {
    return _MetricRow(
      cards: [
        _MetricCard(label: 'Assigned', value: '${metrics.assignedCount}'),
        _MetricCard(label: 'Completed', value: '${metrics.completedCount}'),
        _MetricCard(
          label: 'In Progress',
          value: '${metrics.inProgressCount}',
        ),
        _MetricCard(
          label: 'Outstanding',
          value: '${metrics.outstandingCount}',
        ),
        _MetricCard(
          label: 'Completion %',
          value: '${metrics.completionPercentage.toStringAsFixed(0)}%',
        ),
      ],
    );
  }
}

String _formatDate(DateTime? date) {
  if (date == null) return '—';
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}
