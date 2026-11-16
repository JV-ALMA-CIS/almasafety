import 'package:flutter/material.dart';
import '../../../core/widgets/live_stream_builder.dart';
import '../../../core/widgets/choice_list.dart';
import 'package:provider/provider.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/accent_card.dart';
import '../../../core/widgets/color_choice_chips.dart';
import '../../../core/widgets/empty_state.dart';
import '../../../core/widgets/feature_header.dart';
import '../../../core/widgets/organization_scope_selector.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../../organizations/data/organization_repository.dart';
import '../../organizations/data/site_repository.dart';
import '../../organizations/domain/site.dart';
import '../../organizations/presentation/site_select_list.dart';
import '../data/safety_alert_repository.dart';
import '../data/safety_alert_service.dart';
import '../domain/safety_alert.dart';
import '../domain/safety_alert_category.dart';
import '../domain/safety_alert_severity.dart';
import '../domain/safety_alert_status.dart';
import '../../authentication/domain/app_role.dart';
import '../../daily_safety_meetings/data/daily_safety_meeting_repository.dart';
import '../../../core/widgets/mobile_title.dart';

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
    this.todaysMeetingSiteLookup,
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

  /// Injected in tests. Finds the site of the Foreman's own meeting today,
  /// used to pre-select "where you are" on a new alert when they have more
  /// than one site. Defaults to reading their meeting history.
  final Future<String?> Function(String organizationId, String foremanUid)?
  todaysMeetingSiteLookup;

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

  /// The site of [foremanUid]'s own meeting today, if they have started
  /// one — the best available signal of where they are right now.
  Future<String?> _todaysMeetingSite(
    String organizationId,
    String foremanUid,
  ) async {
    final lookup = widget.todaysMeetingSiteLookup;
    if (lookup != null) return lookup(organizationId, foremanUid);
    try {
      final meetings =
          await DailySafetyMeetingRepository(
                firestoreService: FirestoreService(),
                organizationId: organizationId,
              )
              .watchHistoryForForeman(foremanUid)
              .first
              .timeout(const Duration(seconds: 5));
      // Meetings are dated by the server's UTC day.
      final today = DateTime.now().toUtc().toIso8601String().substring(0, 10);
      for (final meeting in meetings) {
        if (meeting.date == today) return meeting.siteId;
      }
    } catch (_) {
      // No hint — the Foreman simply picks the site.
    }
    return null;
  }

  Future<void> _openCreateDialog(
    String organizationId,
    List<Site> sites, {
    String? foremanUid,
  }) async {
    if (sites.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'You are not assigned to a site yet, so there is nowhere to '
            'send an alert. Ask your Site Manager to add you to a site.',
          ),
        ),
      );
      return;
    }
    String? initialSiteId;
    if (sites.length == 1) {
      initialSiteId = sites.single.id;
    } else if (foremanUid != null) {
      initialSiteId = await _todaysMeetingSite(organizationId, foremanUid);
      if (!sites.any((site) => site.id == initialSiteId)) {
        initialSiteId = null;
      }
    }
    if (!mounted) return;
    final result = await Navigator.of(context, rootNavigator: true)
        .push<_SafetyAlertFormResult>(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => _SafetyAlertFormDialog(
              sites: sites,
              initialSiteId: initialSiteId,
            ),
          ),
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
    final canManage =
        isPlatformAdministrator ||
        (membership?.role.canReviewPendingAccounts ?? false);
    final siteIds = membership?.siteIds ?? const <String>[];
    // Admin and Site Manager work across the whole organization; a Foreman
    // raises and manages alerts only at their own site(s) — the server
    // enforces the same rule (`requireForemanSiteScope`).
    final isOrganizationWide =
        isPlatformAdministrator || membership?.role == AppRole.siteManager;
    final isForeman =
        !isPlatformAdministrator && membership?.role == AppRole.foreman;
    final organizationId = isPlatformAdministrator
        ? _selectedOrganizationId
        : sessionController.activeOrganizationId;

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

    return LiveStreamBuilder<List<SafetyAlert>>(
      streamKey: _repositoryFor(organizationId),
      stream: () => _repositoryFor(organizationId).watchForOrganization(),
      builder: (context, alertSnapshot) {
        final allAlerts = alertSnapshot.data ?? const <SafetyAlert>[];
        final isLoading =
            alertSnapshot.connectionState == ConnectionState.waiting;

        // A worker/foreman without reviewer authority sees only alerts for
        // their own assigned site(s) — UX narrowing only, since the
        // underlying read grant (see firestore.rules) is org-wide for any
        // active member; the callables are what actually gate writes.
        final visibleAlerts = isOrganizationWide
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

        // A worker/foreman's `firestore.rules` read grant on `sites` is
        // scoped to their own `siteIds` only — an unconstrained `watchAll()`
        // listing is refused outright for them (see
        // SiteRepository.watchByIds's own doc comment), so a non-reviewer
        // must query by id directly.
        final siteStream = isOrganizationWide
            ? _siteRepositoryFor(organizationId).watchAll()
            : _siteRepositoryFor(organizationId).watchByIds(siteIds);

        return LiveStreamBuilder<List<Site>>(
          streamKey: (organizationId, isOrganizationWide, siteIds.join(',')),
          stream: () => siteStream,
          builder: (context, siteSnapshot) {
            final sites = siteSnapshot.data ?? const <Site>[];
            final sitesById = {for (final site in sites) site.id: site};

            return Scaffold(
              floatingActionButton: canManage
                  ? FloatingActionButton.extended(
                      onPressed: () => _openCreateDialog(
                        organizationId,
                        sites,
                        foremanUid: isForeman ? profile?.uid : null,
                      ),
                      icon: const Icon(Icons.add_alert_outlined),
                      label: const Text('New Alert'),
                    )
                  : null,
              body: ListView(
                padding: const EdgeInsets.all(AppSpacing.md),
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  FeatureHeader(
                    title: 'Safety Alerts',
                    subtitle: isOrganizationWide
                        ? '${visibleAlerts.length} across every site'
                        : '${visibleAlerts.length} for your site(s)',
                    icon: Icons.campaign,
                    color: AppColors.safetyAlerts,
                    chips: [
                      for (final status in SafetyAlertStatus.values)
                        FeatureChip(
                          icon: _statusIcon(status),
                          label:
                              '${visibleAlerts.where((a) => a.status == status).length} '
                              '${status.label.toLowerCase()}',
                        ),
                    ],
                  ),
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
                      child: EmptyState(
                        icon: Icons.campaign_outlined,
                        title: 'No safety alerts to show.',
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

/// Each alert severity's color — low blue, medium amber, high orange,
/// critical red.
Color _severityColor(SafetyAlertSeverity severity) => switch (severity) {
  SafetyAlertSeverity.low => AppColors.meetings,
  SafetyAlertSeverity.medium => AppColors.warning,
  SafetyAlertSeverity.high => AppColors.hazards,
  SafetyAlertSeverity.critical => AppColors.stop,
};

IconData _severityIcon(SafetyAlertSeverity severity) => switch (severity) {
  SafetyAlertSeverity.low => Icons.info,
  SafetyAlertSeverity.medium => Icons.warning_amber,
  SafetyAlertSeverity.high => Icons.warning,
  SafetyAlertSeverity.critical => Icons.dangerous,
};

String _severityHint(SafetyAlertSeverity severity) => switch (severity) {
  SafetyAlertSeverity.low => 'Good to know',
  SafetyAlertSeverity.medium => 'Take care today',
  SafetyAlertSeverity.high => 'Act on it now',
  SafetyAlertSeverity.critical => 'Stop and act immediately',
};

Color _statusColor(SafetyAlertStatus status) => switch (status) {
  SafetyAlertStatus.active => AppColors.stop,
  SafetyAlertStatus.acknowledged => AppColors.warning,
  SafetyAlertStatus.resolved => AppColors.success,
};

IconData _statusIcon(SafetyAlertStatus status) => switch (status) {
  SafetyAlertStatus.active => Icons.notifications_active,
  SafetyAlertStatus.acknowledged => Icons.visibility,
  SafetyAlertStatus.resolved => Icons.check_circle,
};

IconData _categoryIcon(SafetyAlertCategory category) => switch (category) {
  SafetyAlertCategory.safety => Icons.health_and_safety,
  SafetyAlertCategory.equipment => Icons.construction,
  SafetyAlertCategory.environment => Icons.eco,
  SafetyAlertCategory.weather => Icons.thunderstorm,
  SafetyAlertCategory.site => Icons.location_city,
  SafetyAlertCategory.other => Icons.campaign,
};

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
        ColorChoiceChips<SafetyAlertStatus?>(
          label: 'Status',
          selected: statusFilter,
          onSelected: onStatusChanged,
          choices: [
            const ColorChoice(
              value: null,
              label: 'All',
              color: AppColors.textSecondary,
              icon: Icons.all_inclusive,
            ),
            for (final status in SafetyAlertStatus.values)
              ColorChoice(
                value: status,
                label: status.label,
                color: _statusColor(status),
                icon: _statusIcon(status),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        ColorChoiceChips<SafetyAlertSeverity?>(
          label: 'Severity',
          selected: severityFilter,
          onSelected: onSeverityChanged,
          choices: [
            const ColorChoice(
              value: null,
              label: 'All',
              color: AppColors.textSecondary,
              icon: Icons.all_inclusive,
            ),
            for (final severity in SafetyAlertSeverity.values)
              ColorChoice(
                value: severity,
                label: severity.label,
                color: _severityColor(severity),
                icon: _severityIcon(severity),
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

  @override
  Widget build(BuildContext context) {
    final color = _severityColor(alert.severity);
    return AccentCard(
      color: color,
      icon: _categoryIcon(alert.category),
      title: alert.title,
      dimmed: alert.isResolved,
      badges: [
        AccentBadge(label: alert.severity.label, color: color),
        AccentBadge(
          label: alert.status.label,
          color: _statusColor(alert.status),
        ),
      ],
      body: alert.description,
      details: [
        AccentDetail(icon: Icons.place, text: siteName),
        AccentDetail(
          icon: _categoryIcon(alert.category),
          text: alert.category.label,
        ),
        AccentDetail(
          icon: Icons.schedule,
          text: 'Reported ${_formatDate(alert.createdAt)}',
        ),
      ],
      actions: [
        if (canManage && alert.isActive)
          AccentButton(
            label: 'Acknowledge',
            icon: Icons.visibility,
            color: AppColors.warning,
            outlined: true,
            onPressed: isSaving ? null : onAcknowledge,
          ),
        if (canManage && !alert.isResolved)
          AccentButton(
            label: 'Resolve',
            icon: Icons.check_circle,
            color: AppColors.success,
            onPressed: isSaving ? null : onResolve,
          ),
      ],
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
  const _SafetyAlertFormDialog({required this.sites, this.initialSiteId});

  final List<Site> sites;

  /// Pre-selected site, or null to make the Foreman choose.
  final String? initialSiteId;

  @override
  State<_SafetyAlertFormDialog> createState() => _SafetyAlertFormDialogState();
}

class _SafetyAlertFormDialogState extends State<_SafetyAlertFormDialog> {
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  late Site? _site = widget.sites.length == 1
      ? widget.sites.single
      : widget.sites.where((s) => s.id == widget.initialSiteId).firstOrNull;
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
    final site = _site;
    if (title.isEmpty || description.isEmpty || site == null) return;
    Navigator.of(context).pop(
      _SafetyAlertFormResult(
        site: site,
        title: title,
        description: description,
        severity: _severity,
        category: _category,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final color = _severityColor(_severity);
    return Scaffold(
      appBar: AppBar(title: const MobileTitle('Safety Alert')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          FeatureHeader(
            title: _titleController.text.trim().isEmpty
                ? 'New Safety Alert'
                : _titleController.text.trim(),
            subtitle: _site == null
                ? 'Choose the site you are at.'
                : 'Everyone at ${_site!.name} will see this alert.',
            icon: _categoryIcon(_category),
            color: color,
            chips: [
              FeatureChip(
                icon: _severityIcon(_severity),
                label: _severity.label,
              ),
              FeatureChip(
                icon: _categoryIcon(_category),
                label: _category.label,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          FormSection(
            title: 'Where',
            icon: Icons.place,
            color: AppColors.projects,
            child: SiteSelectList(
              sites: widget.sites,
              selectedSiteId: _site?.id,
              onChanged: (id) => setState(() {
                _site = id == null
                    ? null
                    : widget.sites.firstWhere((site) => site.id == id);
              }),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          FormSection(
            title: "What's happening",
            icon: Icons.edit_note,
            color: AppColors.meetings,
            child: Column(
              children: [
                TextField(
                  controller: _titleController,
                  decoration: const InputDecoration(
                    labelText: 'Title',
                    hintText: 'e.g. Strong winds this afternoon',
                  ),
                  autofocus: true,
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: _descriptionController,
                  decoration: const InputDecoration(
                    labelText: 'Description',
                    hintText: 'What should people know or do?',
                  ),
                  minLines: 2,
                  maxLines: 4,
                  onChanged: (_) => setState(() {}),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          FormSection(
            title: 'How serious is it?',
            icon: Icons.priority_high,
            color: color,
            child: Column(
              children: [
                for (final severity in SafetyAlertSeverity.values)
                  _SeverityOption(
                    severity: severity,
                    selected: _severity == severity,
                    onTap: () => setState(() => _severity = severity),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          FormSection(
            title: 'Type',
            icon: Icons.category,
            color: AppColors.analytics,
            child: ChoiceList<SafetyAlertCategory>(
              selected: _category,
              onChanged: (category) {
                if (category != null) setState(() => _category = category);
              },
              items: [
                for (final category in SafetyAlertCategory.values)
                  ChoiceItem(
                    value: category,
                    title: category.label,
                    color: AppColors.analytics,
                    icon: _categoryIcon(category),
                  ),
              ],
              allowDeselect: false,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: color,
              foregroundColor: AppColors.onColor(color),
            ),
            onPressed:
                _site == null ||
                    _titleController.text.trim().isEmpty ||
                    _descriptionController.text.trim().isEmpty
                ? null
                : _submit,
            icon: const Icon(Icons.campaign),
            label: const Text('Send Alert'),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}

/// One large, colored severity choice with a plain-language hint.
class _SeverityOption extends StatelessWidget {
  const _SeverityOption({
    required this.severity,
    required this.selected,
    required this.onTap,
  });

  final SafetyAlertSeverity severity;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = _severityColor(severity);
    final foreground = selected ? AppColors.onColor(color) : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Material(
        color: selected ? color : color.withValues(alpha: 0.08),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: color, width: selected ? 2 : 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.sm + 2),
            child: Row(
              children: [
                Icon(_severityIcon(severity), color: foreground ?? color),
                const SizedBox(width: AppSpacing.sm),
                // Label left, hint right — or the hint on its own line
                // when both don't fit.
                Expanded(
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    spacing: AppSpacing.sm,
                    children: [
                      Text(
                        severity.label,
                        style: AppTextStyles.bodyLarge.copyWith(
                          color: foreground,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        _severityHint(severity),
                        style: AppTextStyles.bodyMedium.copyWith(
                          color: foreground,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
