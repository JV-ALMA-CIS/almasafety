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
import '../../corrective_actions/domain/corrective_action_status.dart';
import '../../organizations/data/organization_repository.dart';
import '../../organizations/data/project_repository.dart';
import '../../organizations/data/site_repository.dart';
import '../../organizations/domain/project.dart';
import '../../organizations/domain/site.dart';
import '../data/reports_repository.dart';
import '../domain/corrective_action_report_row.dart';
import '../domain/daily_safety_meeting_report_row.dart';
import '../domain/report_category.dart';
import '../domain/safety_alert_report_row.dart';
import '../domain/safety_learning_report_row.dart';

/// The Reports screen — read-only operational summaries across the four
/// report categories this foundation supports.
///
/// **Authorized management users only**, using the exact same role gate
/// [CorrectiveActionsScreen]/[SafetyAlertsScreen] already use
/// (`AppRole.canReviewPendingAccounts` — `admin`/`siteManager`), reused
/// rather than re-derived: this is not a new
/// RBAC concept, it is the existing reviewer-role boundary applied to a
/// fourth screen. A `foreman`/`worker` sees an access message instead.
///
/// Every report is generated on demand ("Generate Report") rather than
/// streamed live — this is a summary/analysis surface, not an operational
/// worklist, so a point-in-time snapshot matches user expectations better
/// than a continuously-resorting live view, and avoids re-running the
/// per-meeting attendance/concern fan-out in [ReportsRepository] on every
/// Firestore write anywhere in the organization.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({
    super.key,
    this.repository,
    this.projectRepository,
    this.siteRepository,
    this.organizationRepository,
  });

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real dependencies scoped to the signed-in user's
  /// organization.
  final ReportsRepository? repository;
  final ProjectRepository? projectRepository;
  final SiteRepository? siteRepository;

  /// Injected in tests. Backs [OrganizationScopeSelector] for a System
  /// Administrator, who has no organization of their own to scope
  /// [repository]/[projectRepository]/[siteRepository] to.
  final OrganizationRepository? organizationRepository;

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  ReportsRepository? _repository;
  ProjectRepository? _projectRepository;
  SiteRepository? _siteRepository;

  ReportCategory _category = ReportCategory.dailySafetyMeetings;
  String? _projectId;
  String? _siteId;
  DateTime? _from;
  DateTime? _to;

  bool _isLoading = false;
  String? _errorMessage;
  bool _hasGenerated = false;
  String? _selectedOrganizationId;
  List<DailySafetyMeetingReportRow> _meetingRows = const [];
  List<SafetyAlertReportRow> _alertRows = const [];
  List<CorrectiveActionReportRow> _actionRows = const [];
  List<SafetyLearningReportRow> _learningRows = const [];

  ReportsRepository _repositoryFor(String organizationId) {
    final existing = _repository;
    if (existing != null && existing.organizationId == organizationId) {
      return existing;
    }
    final created = widget.repository ??
        ReportsRepository(
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
      final repository = _repositoryFor(organizationId);
      switch (_category) {
        case ReportCategory.dailySafetyMeetings:
          _meetingRows = await repository.buildDailySafetyMeetingReport(
            projectId: _projectId,
            siteId: _siteId,
            from: _from,
            to: _to,
          );
        case ReportCategory.safetyAlerts:
          _alertRows = await repository.buildSafetyAlertsReport(
            siteId: _siteId,
            from: _from,
            to: _to,
          );
        case ReportCategory.correctiveActions:
          _actionRows = await repository.buildCorrectiveActionsReport(
            siteId: _siteId,
            from: _from,
            to: _to,
          );
        case ReportCategory.safetyLearning:
          _learningRows = await repository.buildSafetyLearningReport();
      }
      if (!mounted) return;
      setState(() => _hasGenerated = true);
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
    final profile = context.watch<SessionController>().profile;
    final canManage = profile?.canReviewPendingAccounts ?? false;
    final isPlatformAdministrator = profile?.isPlatformAdministrator ?? false;
    final organizationId =
        isPlatformAdministrator ? _selectedOrganizationId : profile?.organizationId;

    if (!canManage) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: Text(
            'Reports are available to Organization Administrators, Safety '
            'Managers and Site Superintendents.',
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
                Text('Reports', style: AppTextStyles.headlineMedium),
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
                Text('Report', style: AppTextStyles.label),
                const SizedBox(height: AppSpacing.xs),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    for (final category in ReportCategory.values)
                      ChoiceChip(
                        label: Text(category.label),
                        selected: _category == category,
                        onSelected: (_) {
                          setState(() {
                            _category = category;
                            _hasGenerated = false;
                          });
                        },
                      ),
                  ],
                ),
                if (_category == ReportCategory.dailySafetyMeetings) ...[
                  const SizedBox(height: AppSpacing.sm),
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
                ],
                if (_category != ReportCategory.safetyLearning) ...[
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
                ],
                const SizedBox(height: AppSpacing.md),
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: AppSpacing.minTouchTarget,
                  ),
                  child: ElevatedButton.icon(
                    onPressed: _isLoading ? null : () => _generate(organizationId),
                    icon: const Icon(Icons.summarize_outlined),
                    label: Text(_isLoading ? 'Generating…' : 'Generate Report'),
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                if (_isLoading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_hasGenerated)
                  _ReportResults(
                    category: _category,
                    meetingRows: _meetingRows,
                    alertRows: _alertRows,
                    actionRows: _actionRows,
                    learningRows: _learningRows,
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

class _ReportResults extends StatelessWidget {
  const _ReportResults({
    required this.category,
    required this.meetingRows,
    required this.alertRows,
    required this.actionRows,
    required this.learningRows,
  });

  final ReportCategory category;
  final List<DailySafetyMeetingReportRow> meetingRows;
  final List<SafetyAlertReportRow> alertRows;
  final List<CorrectiveActionReportRow> actionRows;
  final List<SafetyLearningReportRow> learningRows;

  @override
  Widget build(BuildContext context) {
    switch (category) {
      case ReportCategory.dailySafetyMeetings:
        return _DailySafetyMeetingReportView(rows: meetingRows);
      case ReportCategory.safetyAlerts:
        return _SafetyAlertsReportView(rows: alertRows);
      case ReportCategory.correctiveActions:
        return _CorrectiveActionsReportView(rows: actionRows);
      case ReportCategory.safetyLearning:
        return _SafetyLearningReportView(rows: learningRows);
    }
  }
}

class _EmptyReport extends StatelessWidget {
  const _EmptyReport();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
      child: Column(
        children: [
          Icon(
            Icons.insert_drive_file_outlined,
            size: 48,
            color: AppColors.textSecondary,
          ),
          SizedBox(height: AppSpacing.sm),
          Text(
            'No results for the selected filters.',
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value, style: AppTextStyles.headlineMedium),
            const SizedBox(height: AppSpacing.xs),
            Text(label, style: AppTextStyles.bodyMedium),
          ],
        ),
      ),
    );
  }
}

class _DailySafetyMeetingReportView extends StatelessWidget {
  const _DailySafetyMeetingReportView({required this.rows});

  final List<DailySafetyMeetingReportRow> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const _EmptyReport();

    final totalConcerns = rows.fold<int>(0, (sum, r) => sum + r.concernCount);
    final totalActions = rows.fold<int>(
      0,
      (sum, r) => sum + r.correctiveActionCount,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _SummaryCard(label: 'Meetings', value: '${rows.length}'),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: _SummaryCard(label: 'Concerns', value: '$totalConcerns'),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: _SummaryCard(
                label: 'Corrective Actions',
                value: '$totalActions',
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        for (final row in rows) ...[
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${row.projectName} · ${row.siteName}',
                    style: AppTextStyles.titleLarge,
                  ),
                  Text(
                    '${row.date} · ${row.status.label}',
                    style: AppTextStyles.bodyMedium,
                  ),
                  Text(
                    'Foreman: ${row.foremanId}',
                    style: AppTextStyles.bodyMedium,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    '${row.activityCount} activities · '
                    '${row.meetingPointCount} meeting points',
                    style: AppTextStyles.bodyMedium,
                  ),
                  Text(
                    'Attendance: ${row.presentCount} present, '
                    '${row.absentCount} absent',
                    style: AppTextStyles.bodyMedium,
                  ),
                  Text(
                    '${row.concernCount} concerns · '
                    '${row.correctiveActionCount} corrective actions',
                    style: AppTextStyles.bodyMedium,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ],
    );
  }
}

class _SafetyAlertsReportView extends StatelessWidget {
  const _SafetyAlertsReportView({required this.rows});

  final List<SafetyAlertReportRow> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const _EmptyReport();

    final activeCount = rows.where((r) => r.status.id == 'active').length;
    final resolvedCount = rows.where((r) => r.status.id == 'resolved').length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _SummaryCard(label: 'Total', value: '${rows.length}'),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: _SummaryCard(label: 'Active', value: '$activeCount'),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: _SummaryCard(label: 'Resolved', value: '$resolvedCount'),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        for (final row in rows) ...[
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(row.siteName, style: AppTextStyles.titleLarge),
                  Text(
                    '${row.severity.label} · ${row.category.label} · '
                    '${row.status.label}',
                    style: AppTextStyles.bodyMedium,
                  ),
                  Text(
                    'Created ${_formatDate(row.createdAt)}'
                    '${row.resolvedAt != null ? ' · Resolved ${_formatDate(row.resolvedAt)}' : ''}',
                    style: AppTextStyles.bodyMedium,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ],
    );
  }
}

class _CorrectiveActionsReportView extends StatelessWidget {
  const _CorrectiveActionsReportView({required this.rows});

  final List<CorrectiveActionReportRow> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const _EmptyReport();

    final now = DateTime.now();
    final overdueCount = rows.where((r) => r.isOverdueAsOf(now)).length;
    final completedCount = rows
        .where((r) => r.status == CorrectiveActionStatus.completed)
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _SummaryCard(label: 'Total', value: '${rows.length}'),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: _SummaryCard(label: 'Overdue', value: '$overdueCount'),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: _SummaryCard(
                label: 'Completed',
                value: '$completedCount',
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        for (final row in rows) ...[
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(row.title, style: AppTextStyles.titleLarge),
                      ),
                      if (row.isOverdueAsOf(now))
                        const _Badge(label: 'Overdue', color: AppColors.danger),
                    ],
                  ),
                  Text(row.siteName, style: AppTextStyles.bodyMedium),
                  Text(
                    'Assigned: ${row.assignedTo}',
                    style: AppTextStyles.bodyMedium,
                  ),
                  Text(
                    'Due ${_formatDate(row.dueDate)} · ${row.status.label}',
                    style: AppTextStyles.bodyMedium,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ],
    );
  }
}

class _SafetyLearningReportView extends StatelessWidget {
  const _SafetyLearningReportView({required this.rows});

  final List<SafetyLearningReportRow> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const _EmptyReport();

    final totalCompleted = rows.fold<int>(
      0,
      (sum, r) => sum + r.completedCount,
    );
    final totalOutstanding = rows.fold<int>(
      0,
      (sum, r) => sum + r.outstandingCount,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _SummaryCard(label: 'Workers', value: '${rows.length}'),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: _SummaryCard(
                label: 'Completed',
                value: '$totalCompleted',
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: _SummaryCard(
                label: 'Outstanding',
                value: '$totalOutstanding',
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        for (final row in rows) ...[
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(row.workerUid, style: AppTextStyles.titleLarge),
                  Text(
                    'Required: ${row.requiredCount} · '
                    'Completed: ${row.completedCount} · '
                    'In progress: ${row.inProgressCount} · '
                    'Outstanding: ${row.outstandingCount}',
                    style: AppTextStyles.bodyMedium,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppSpacing.sm),
      ),
      child: Text(label, style: AppTextStyles.label.copyWith(color: color)),
    );
  }
}

String _formatDate(DateTime? date) {
  if (date == null) return '—';
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}
