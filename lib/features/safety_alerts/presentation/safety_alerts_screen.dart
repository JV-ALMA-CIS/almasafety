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
import '../../organizations/data/site_repository.dart';
import '../../organizations/domain/site.dart';
import '../data/safety_alert_repository.dart';
import '../data/safety_alert_service.dart';
import '../domain/safety_alert.dart';
import '../domain/safety_alert_category.dart';
import '../domain/safety_alert_severity.dart';
import '../domain/safety_alert_status.dart';

/// The Safety Alerts screen.
///
/// **Two audiences, one screen.** An authorized reviewer
/// (`admin`/`siteManager` — the same role set
/// `AppRole.canReviewPendingAccounts` already grants review authority to
/// elsewhere in this app, reused here exactly like
/// [CorrectiveActionsScreen]'s own authority check) sees every
/// alert across the organization with severity/status filters and
/// acknowledge/resolve controls. A `worker`/`foreman` — anyone without that
/// role — sees a simpler, read-only list narrowed to their own assigned
/// site(s), matching the task's "Workers/foremen can view alerts applicable
/// to their organization/site" requirement. Neither audience can create,
/// acknowledge or resolve an alert from a client that isn't an authorized
/// reviewer; `safety_alert_callable.ts` re-checks the same role server-side
/// regardless of what this screen shows.
class SafetyAlertsScreen extends StatefulWidget {
  const SafetyAlertsScreen({
    super.key,
    this.repository,
    this.service,
    this.siteRepository,
    this.organizationRepository,
  });

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real dependencies scoped to the signed-in user's
  /// organization.
  final SafetyAlertRepository? repository;
  final SafetyAlertService? service;
  final SiteRepository? siteRepository;

  /// Injected in tests. Backs [OrganizationScopeSelector] for a System
  /// Administrator, who has no organization of their own to scope
  /// [repository]/[siteRepository] to.
  final OrganizationRepository? organizationRepository;

  @override
  State<SafetyAlertsScreen> createState() => _SafetyAlertsScreenState();
}

class _SafetyAlertsScreenState extends State<SafetyAlertsScreen> {
  late final SafetyAlertService _service =
      widget.service ?? SafetyAlertService();

  SafetyAlertRepository? _repository;
  SiteRepository? _siteRepository;

  String? _errorMessage;
  bool _isSaving = false;
  SafetyAlertStatus? _statusFilter;
  SafetyAlertSeverity? _severityFilter;
  String? _selectedOrganizationId;

  SafetyAlertRepository _repositoryFor(String organizationId) {
    final existing = _repository;
    if (existing != null && existing.organizationId == organizationId) {
      return existing;
    }
    final created =
        widget.repository ??
        SafetyAlertRepository(
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

  Future<void> _acknowledge(String organizationId, SafetyAlert alert) => _run(
    () => _service.acknowledgeSafetyAlert(
      organizationId: organizationId,
      alertId: alert.id,
    ),
  );

  Future<void> _resolve(String organizationId, SafetyAlert alert) => _run(
    () => _service.resolveSafetyAlert(
      organizationId: organizationId,
      alertId: alert.id,
    ),
  );

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });
    try {
      await action();
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _openCreateDialog(
    String organizationId,
    List<Site> sites,
  ) async {
    if (sites.isEmpty) return;
    final result = await showDialog<_SafetyAlertFormResult>(
      context: context,
      builder: (_) => _SafetyAlertFormDialog(sites: sites),
    );
    if (result == null) return;
    await _run(
      () => _service.createSafetyAlert(
        organizationId: organizationId,
        projectId: result.site.projectId,
        siteId: result.site.id,
        title: result.title,
        description: result.description,
        severity: result.severity.id,
        category: result.category.id,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sessionController = context.watch<SessionController>();
    final profile = sessionController.profile;
    final membership = sessionController.activeMembership;
    final isPlatformAdministrator = profile?.isPlatformAdministrator ?? false;
    final canManage = isPlatformAdministrator ||
        (membership?.role.canReviewPendingAccounts ?? false);
    final siteIds = membership?.siteIds ?? const <String>[];
    final organizationId = isPlatformAdministrator
        ? _selectedOrganizationId
        : sessionController.activeOrganizationId;

    if (organizationId == null) {
      if (isPlatformAdministrator) {
        return Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: OrganizationScopeSelector(
            selectedOrganizationId: _selectedOrganizationId,
            onChanged: (value) => setState(() => _selectedOrganizationId = value),
            repository: widget.organizationRepository,
          ),
        );
      }
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: Text(
            'Safety Alerts are available once your account has an '
            'organization.',
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return StreamBuilder<List<SafetyAlert>>(
      stream: _repositoryFor(organizationId).watchForOrganization(),
      builder: (context, alertSnapshot) {
        final allAlerts = alertSnapshot.data ?? const <SafetyAlert>[];
        final isLoading =
            alertSnapshot.connectionState == ConnectionState.waiting;

        // A worker/foreman without reviewer authority sees only alerts for
        // their own assigned site(s) — UX narrowing only, since the
        // underlying read grant (see firestore.rules) is org-wide for any
        // active member; the callables are what actually gate writes.
        final visibleAlerts = canManage
            ? allAlerts
            : allAlerts.where((a) => siteIds.contains(a.siteId)).toList();

        final filteredAlerts = visibleAlerts.where((alert) {
          if (_statusFilter != null && alert.status != _statusFilter) {
            return false;
          }
          if (_severityFilter != null && alert.severity != _severityFilter) {
            return false;
          }
          return true;
        }).toList();

        return StreamBuilder<List<Site>>(
          stream: _siteRepositoryFor(organizationId).watchAll(),
          builder: (context, siteSnapshot) {
            final sites = siteSnapshot.data ?? const <Site>[];
            final sitesById = {for (final site in sites) site.id: site};

            return Scaffold(
              floatingActionButton: canManage
                  ? FloatingActionButton.extended(
                      onPressed: () => _openCreateDialog(organizationId, sites),
                      icon: const Icon(Icons.add_alert_outlined),
                      label: const Text('New Alert'),
                    )
                  : null,
              body: ListView(
                padding: const EdgeInsets.all(AppSpacing.md),
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  Text('Safety Alerts', style: AppTextStyles.headlineMedium),
                  const SizedBox(height: AppSpacing.xs),
                  if (isPlatformAdministrator)
                    OrganizationScopeSelector(
                      selectedOrganizationId: _selectedOrganizationId,
                      onChanged: (value) =>
                          setState(() => _selectedOrganizationId = value),
                      repository: widget.organizationRepository,
                    ),
                  Text(
                    canManage
                        ? '${visibleAlerts.length} across every site'
                        : '${visibleAlerts.length} for your site(s)',
                    style: AppTextStyles.bodyMedium,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  if (_errorMessage != null) ...[
                    AuthErrorBanner(message: _errorMessage!),
                    const SizedBox(height: AppSpacing.md),
                  ],
                  _AlertFilters(
                    statusFilter: _statusFilter,
                    severityFilter: _severityFilter,
                    onStatusChanged: (status) =>
                        setState(() => _statusFilter = status),
                    onSeverityChanged: (severity) =>
                        setState(() => _severityFilter = severity),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  if (isLoading && visibleAlerts.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  if (!isLoading && filteredAlerts.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                      child: Text(
                        'No safety alerts to show.',
                        style: AppTextStyles.bodyMedium,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  for (final alert in filteredAlerts) ...[
                    _SafetyAlertCard(
                      alert: alert,
                      siteName: sitesById[alert.siteId]?.name ?? alert.siteId,
                      canManage: canManage,
                      isSaving: _isSaving,
                      onAcknowledge: () => _acknowledge(organizationId, alert),
                      onResolve: () => _resolve(organizationId, alert),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _AlertFilters extends StatelessWidget {
  const _AlertFilters({
    required this.statusFilter,
    required this.severityFilter,
    required this.onStatusChanged,
    required this.onSeverityChanged,
  });

  final SafetyAlertStatus? statusFilter;
  final SafetyAlertSeverity? severityFilter;
  final void Function(SafetyAlertStatus?) onStatusChanged;
  final void Function(SafetyAlertSeverity?) onSeverityChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Status', style: AppTextStyles.label),
        const SizedBox(height: AppSpacing.xs),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            ChoiceChip(
              label: const Text('All'),
              selected: statusFilter == null,
              onSelected: (_) => onStatusChanged(null),
            ),
            for (final status in SafetyAlertStatus.values)
              ChoiceChip(
                label: Text(status.label),
                selected: statusFilter == status,
                onSelected: (_) => onStatusChanged(status),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Text('Severity', style: AppTextStyles.label),
        const SizedBox(height: AppSpacing.xs),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            ChoiceChip(
              label: const Text('All'),
              selected: severityFilter == null,
              onSelected: (_) => onSeverityChanged(null),
            ),
            for (final severity in SafetyAlertSeverity.values)
              ChoiceChip(
                label: Text(severity.label),
                selected: severityFilter == severity,
                onSelected: (_) => onSeverityChanged(severity),
              ),
          ],
        ),
      ],
    );
  }
}

class _SafetyAlertCard extends StatelessWidget {
  const _SafetyAlertCard({
    required this.alert,
    required this.siteName,
    required this.canManage,
    required this.isSaving,
    required this.onAcknowledge,
    required this.onResolve,
  });

  final SafetyAlert alert;
  final String siteName;
  final bool canManage;
  final bool isSaving;
  final VoidCallback onAcknowledge;
  final VoidCallback onResolve;

  Color get _severityColor => switch (alert.severity) {
    SafetyAlertSeverity.low => AppColors.textSecondary,
    SafetyAlertSeverity.medium => AppColors.warning,
    SafetyAlertSeverity.high => AppColors.danger,
    SafetyAlertSeverity.critical => AppColors.danger,
  };

  Color get _statusColor => switch (alert.status) {
    SafetyAlertStatus.active => AppColors.danger,
    SafetyAlertStatus.acknowledged => AppColors.warning,
    SafetyAlertStatus.resolved => AppColors.success,
  };

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(alert.title, style: AppTextStyles.titleLarge),
                ),
                _Badge(label: alert.severity.label, color: _severityColor),
                const SizedBox(width: AppSpacing.xs),
                _Badge(label: alert.status.label, color: _statusColor),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(alert.description, style: AppTextStyles.bodyMedium),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Site: $siteName · Category: ${alert.category.label}',
              style: AppTextStyles.bodyMedium,
            ),
            Text(
              'Reported ${_formatDate(alert.createdAt)}',
              style: AppTextStyles.bodyMedium,
            ),
            if (canManage && !alert.isResolved) ...[
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  if (alert.isActive)
                    Expanded(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          minHeight: AppSpacing.minTouchTarget,
                        ),
                        child: OutlinedButton.icon(
                          onPressed: isSaving ? null : onAcknowledge,
                          icon: const Icon(Icons.visibility_outlined),
                          label: const Text('Acknowledge'),
                        ),
                      ),
                    ),
                  if (alert.isActive) const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minHeight: AppSpacing.minTouchTarget,
                      ),
                      child: ElevatedButton.icon(
                        onPressed: isSaving ? null : onResolve,
                        icon: const Icon(Icons.check_circle_outline),
                        label: const Text('Resolve'),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
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
  if (date == null) return 'recently';
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}

class _SafetyAlertFormResult {
  const _SafetyAlertFormResult({
    required this.site,
    required this.title,
    required this.description,
    required this.severity,
    required this.category,
  });

  final Site site;
  final String title;
  final String description;
  final SafetyAlertSeverity severity;
  final SafetyAlertCategory category;
}

/// A dialog for creating a safety alert: site, title, description, severity
/// and category. Only shown to an authorized reviewer (see
/// [_SafetyAlertsScreenState._openCreateDialog]) — the server re-checks the
/// same role regardless.
class _SafetyAlertFormDialog extends StatefulWidget {
  const _SafetyAlertFormDialog({required this.sites});

  final List<Site> sites;

  @override
  State<_SafetyAlertFormDialog> createState() =>
      _SafetyAlertFormDialogState();
}

class _SafetyAlertFormDialogState extends State<_SafetyAlertFormDialog> {
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  late Site _site = widget.sites.first;
  SafetyAlertSeverity _severity = SafetyAlertSeverity.medium;
  SafetyAlertCategory _category = SafetyAlertCategory.safety;

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  void _submit() {
    final title = _titleController.text.trim();
    final description = _descriptionController.text.trim();
    if (title.isEmpty || description.isEmpty) return;
    Navigator.of(context).pop(
      _SafetyAlertFormResult(
        site: _site,
        title: title,
        description: description,
        severity: _severity,
        category: _category,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New Safety Alert'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<Site>(
                initialValue: _site,
                decoration: const InputDecoration(labelText: 'Site'),
                items: [
                  for (final site in widget.sites)
                    DropdownMenuItem(value: site, child: Text(site.name)),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _site = value);
                },
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _titleController,
                decoration: const InputDecoration(labelText: 'Title'),
                autofocus: true,
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _descriptionController,
                decoration: const InputDecoration(labelText: 'Description'),
                minLines: 1,
                maxLines: 3,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text('Severity', style: AppTextStyles.label),
              const SizedBox(height: AppSpacing.xs),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  for (final severity in SafetyAlertSeverity.values)
                    ChoiceChip(
                      label: Text(severity.label),
                      selected: _severity == severity,
                      onSelected: (_) => setState(() => _severity = severity),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Text('Category', style: AppTextStyles.label),
              const SizedBox(height: AppSpacing.xs),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  for (final category in SafetyAlertCategory.values)
                    ChoiceChip(
                      label: Text(category.label),
                      selected: _category == category,
                      onSelected: (_) => setState(() => _category = category),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }
}
