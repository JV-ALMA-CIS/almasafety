import 'package:flutter/material.dart';
import '../../corrective_actions/presentation/report_progress.dart';
import '../../corrective_actions/presentation/review_corrective_action_screen.dart';
import '../../../core/widgets/live_stream_builder.dart';
import 'package:provider/provider.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/organization_scope_selector.dart';
import '../../../core/widgets/status_badge.dart';
import '../../authentication/data/account_approval_service.dart';
import '../../authentication/data/people_directory.dart';
import '../../authentication/domain/app_role.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../../corrective_actions/data/corrective_action_repository.dart';
import '../../corrective_actions/domain/corrective_action.dart';
import '../../organizations/data/organization_repository.dart';
import '../../organizations/data/site_repository.dart';
import '../../organizations/domain/site.dart';
import '../data/hazard_repository.dart';
import '../data/hazard_service.dart';
import '../domain/hazard.dart';
import '../domain/hazard_kind.dart';
import '../domain/hazard_status.dart';
import '../../../core/widgets/accent_card.dart';
import '../../../core/widgets/color_choice_chips.dart';
import '../../../core/widgets/feature_header.dart';
import 'hazard_style.dart';
import '../../corrective_actions/presentation/corrective_action_form_screen.dart';
import '../../authentication/domain/organization_user.dart';

/// The Hazard Management screen for an authorized reviewer — `admin`/
/// `siteManager`/`foreman`, the same role set [AppRole.canReviewPendingAccounts]
/// already grants review authority to elsewhere in this app, matching
/// [CorrectiveActionsScreen]'s own authority check and the exact role set
/// `hazard_callable.ts`'s `requireOrganizationScopedReviewer` accepts for
/// `acknowledgeHazard`/`linkHazardCorrectiveAction`/`closeHazard`.
///
/// Distinct from [MyHazardsScreen] (a worker's own read-only "what have I
/// reported" list): this screen shows every hazard across the organization,
/// filterable by status, with the reviewer actions `MyHazardsScreen`
/// deliberately omits — acknowledge, create/link a corrective action, or
/// close directly. Every mutation goes through [HazardService], which calls
/// the existing callables; this screen never writes to Firestore directly.
///
/// An `admin` has no organization of their own, so this screen shows
/// [OrganizationScopeSelector] for that role instead of blocking it, exactly
/// like [CorrectiveActionsScreen].
class HazardsManagementScreen extends StatefulWidget {
  const HazardsManagementScreen({
    super.key,
    this.repository,
    this.service,
    this.siteRepository,
    this.organizationRepository,
    this.correctiveActionRepository,
    this.approvalService,
  });

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real dependencies scoped to the signed-in user's
  /// organization.
  final HazardRepository? repository;
  final HazardService? service;
  final SiteRepository? siteRepository;
  final CorrectiveActionRepository? correctiveActionRepository;
  final AccountApprovalService? approvalService;

  /// Injected in tests. Backs [OrganizationScopeSelector] for a System
  /// Administrator, who has no organization of their own to scope
  /// [repository]/[siteRepository] to.
  final OrganizationRepository? organizationRepository;

  @override
  State<HazardsManagementScreen> createState() =>
      _HazardsManagementScreenState();
}

/// The status filter options shown to a reviewer — `All` plus each
/// [HazardStatus], in lifecycle order.
enum _HazardFilter {
  all,
  reported,
  acknowledged,
  correctiveActionCreated,
  closed;

  String get label => switch (this) {
    _HazardFilter.all => 'All',
    _HazardFilter.reported => 'Reported',
    _HazardFilter.acknowledged => 'Acknowledged',
    _HazardFilter.correctiveActionCreated => 'Corrective Action',
    _HazardFilter.closed => 'Closed',
  };

  /// The status this filter selects, or null for "All".
  HazardStatus? get status => switch (this) {
    _HazardFilter.all => null,
    _HazardFilter.reported => HazardStatus.reported,
    _HazardFilter.acknowledged => HazardStatus.acknowledged,
    _HazardFilter.correctiveActionCreated =>
      HazardStatus.correctiveActionCreated,
    _HazardFilter.closed => HazardStatus.closed,
  };

  bool matches(Hazard hazard) => switch (this) {
    _HazardFilter.all => true,
    _HazardFilter.reported => hazard.status == HazardStatus.reported,
    _HazardFilter.acknowledged => hazard.status == HazardStatus.acknowledged,
    _HazardFilter.correctiveActionCreated =>
      hazard.status == HazardStatus.correctiveActionCreated,
    _HazardFilter.closed => hazard.status == HazardStatus.closed,
  };
}

class _HazardsManagementScreenState extends State<HazardsManagementScreen> {
  late final HazardService _service = widget.service ?? HazardService();

  HazardRepository? _repository;
  SiteRepository? _siteRepository;
  CorrectiveActionRepository? _correctiveActionRepository;

  String? _errorMessage;
  bool _isSaving = false;
  String? _selectedOrganizationId;

  /// Defaults to the operationally useful "needs attention" view — every
  /// hazard not yet closed — rather than dumping the full closed history on
  /// a reviewer the moment they open the screen. `All` remains one tap away.
  _HazardFilter _filter = _HazardFilter.reported;

  HazardRepository _repositoryFor(String organizationId) {
    final existing = _repository;
    if (existing != null && existing.organizationId == organizationId) {
      return existing;
    }
    final created =
        widget.repository ??
        HazardRepository(
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

  CorrectiveActionRepository _correctiveActionRepositoryFor(
    String organizationId,
  ) {
    final existing = _correctiveActionRepository;
    if (existing != null && existing.organizationId == organizationId) {
      return existing;
    }
    final created =
        widget.correctiveActionRepository ??
        CorrectiveActionRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );
    _correctiveActionRepository = created;
    return created;
  }

  Future<void> _acknowledge(String organizationId, Hazard hazard) => _run(
    () => _service.acknowledgeHazard(
      organizationId: organizationId,
      hazardId: hazard.id,
    ),
  );

  Future<void> _close(String organizationId, Hazard hazard) => _run(
    () => _service.closeHazard(
      organizationId: organizationId,
      hazardId: hazard.id,
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

  Future<void> _confirmClose(String organizationId, Hazard hazard) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Close Hazard?'),
        content: const Text(
          'This closes the hazard directly, with no corrective action. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Close Hazard'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _close(organizationId, hazard);
  }

  Future<void> _openCreateCorrectiveActionDialog(
    String organizationId,
    Hazard hazard,
  ) async {
    final approvalService = widget.approvalService ?? AccountApprovalService();
    List<String> assigneeUids;
    List<OrganizationUser> users;
    try {
      users = await approvalService.listUsers(organizationId: organizationId);
      assigneeUids =
          users
              .where(
                (u) =>
                    u.uid != hazard.reportedByUid &&
                    u.siteIds.contains(hazard.siteId),
              )
              .map((u) => u.uid)
              .toList()
            ..sort();
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
      return;
    }
    if (!mounted) return;

    final result = await Navigator.of(context, rootNavigator: true)
        .push<CorrectiveActionFormResult>(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => CorrectiveActionFormScreen(
              eyebrow: 'From a reported hazard',
              candidateAssignees: assigneeUids,
              people: users,
            ),
          ),
        );
    if (result == null) return;

    await _run(
      () => _service.linkCorrectiveAction(
        organizationId: organizationId,
        hazardId: hazard.id,
        title: result.title,
        description: result.description,
        assignedTo: result.assignedTo,
        dueDate: result.dueDate,
        evidenceRequired: result.evidenceRequired,
        evidenceKinds: result.evidenceKinds,
        evidenceInstructions: result.evidenceInstructions,
      ),
    );
  }

  late final PeopleDirectory _people = PeopleDirectory(
    service: widget.approvalService,
  );

  Future<void> _openDetail(
    String organizationId,
    Hazard hazard,
    String siteName,
  ) async {
    final names = await _people.namesFor(organizationId);
    if (!mounted) return;
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => _HazardDetailScreen(
          organizationId: organizationId,
          hazard: hazard,
          siteName: siteName,
          names: names,
          service: _service,
          correctiveActionRepository: _correctiveActionRepositoryFor(
            organizationId,
          ),
          onAcknowledge: () => _acknowledge(organizationId, hazard),
          onClose: () => _confirmClose(organizationId, hazard),
          onCreateCorrectiveAction: () =>
              _openCreateCorrectiveActionDialog(organizationId, hazard),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sessionController = context.watch<SessionController>();
    final profile = sessionController.profile;
    final isPlatformAdministrator = profile?.isPlatformAdministrator ?? false;
    final membershipRole = sessionController.activeMembership?.role;
    final canManage =
        isPlatformAdministrator ||
        (membershipRole?.canReviewPendingAccounts ?? false);
    final organizationId = isPlatformAdministrator
        ? _selectedOrganizationId
        : sessionController.activeOrganizationId;
    // A Foreman's `firestore.rules` read grant on `sites` is scoped to their
    // own `siteIds` only — an unconstrained `watchAll()` listing is refused
    // outright for them (unlike Admin/Site Manager, who see every site) —
    // see SiteRepository.watchByIds's own doc comment.
    final foremanSiteIds = membershipRole == AppRole.foreman
        ? sessionController.activeMembership?.siteIds
        : null;

    if (!canManage) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: Text(
            'Hazard Management is available to Organization Administrators, '
            'Safety Managers and Foremen.',
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

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
            'Hazard Management is available to Organization Administrators, '
            'Safety Managers and Foremen.',
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return LiveStreamBuilder<List<Hazard>>(
      streamKey: _repositoryFor(organizationId),
      stream: () => _repositoryFor(organizationId).watchForOrganization(),
      builder: (context, hazardSnapshot) {
        final allHazards = hazardSnapshot.data ?? const <Hazard>[];
        final isLoading =
            hazardSnapshot.connectionState == ConnectionState.waiting;
        final hasError = hazardSnapshot.hasError;
        final hazards = allHazards.where(_filter.matches).toList();

        final siteStream = foremanSiteIds != null
            ? _siteRepositoryFor(organizationId).watchByIds(foremanSiteIds)
            : _siteRepositoryFor(organizationId).watchAll();

        return LiveStreamBuilder<List<Site>>(
          streamKey: (organizationId, foremanSiteIds?.join(',')),
          stream: () => siteStream,
          builder: (context, siteSnapshot) {
            final sitesById = {
              for (final site in siteSnapshot.data ?? const <Site>[])
                site.id: site,
            };

            return ListView(
              padding: const EdgeInsets.all(AppSpacing.md),
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                FeatureHeader(
                  title: 'Hazard Management',
                  subtitle: '${allHazards.length} hazards across every site',
                  icon: Icons.warning_amber,
                  color: AppColors.hazards,
                  chips: [
                    for (final status in HazardStatus.values)
                      FeatureChip(
                        icon: status.icon,
                        label:
                            '${allHazards.where((h) => h.status == status).length} '
                            '${status.label.toLowerCase()}',
                      ),
                    FeatureChip(
                      icon: HazardKind.nearMiss.icon,
                      label:
                          '${allHazards.where((h) => h.kind == HazardKind.nearMiss).length} '
                          'near-misses',
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
                ColorChoiceChips<_HazardFilter>(
                  selected: _filter,
                  onSelected: (filter) => setState(() => _filter = filter),
                  choices: [
                    for (final filter in _HazardFilter.values)
                      ColorChoice(
                        value: filter,
                        label: filter.label,
                        color: filter.status?.color ?? AppColors.textSecondary,
                        icon: filter.status?.icon ?? Icons.all_inclusive,
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                if (isLoading && allHazards.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                if (hasError)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                    child: Text(
                      'Could not load hazards. Please try again.',
                      style: AppTextStyles.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                  ),
                if (!isLoading && !hasError && allHazards.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                    child: Text(
                      'No hazards have been reported yet.',
                      style: AppTextStyles.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                  ),
                if (!isLoading &&
                    !hasError &&
                    allHazards.isNotEmpty &&
                    hazards.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                    child: Text(
                      'No hazards match this filter.',
                      style: AppTextStyles.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                  ),
                if (hazards.isNotEmpty)
                  LiveStreamBuilder<List<CorrectiveAction>>(
                    streamKey: organizationId,
                    stream: () => _correctiveActionRepositoryFor(
                      organizationId,
                    ).watchForOrganization(),
                    builder: (context, actionSnapshot) {
                      final actionsById = {
                        for (final action
                            in actionSnapshot.data ??
                                const <CorrectiveAction>[])
                          action.id: action,
                      };
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final hazard in hazards) ...[
                            _HazardManagementRow(
                              hazard: hazard,
                              siteName:
                                  sitesById[hazard.siteId]?.name ??
                                  'Unknown site',
                              action: actionsById[hazard.correctiveActionId],
                              isSaving: _isSaving,
                              onTap: () => _openDetail(
                                organizationId,
                                hazard,
                                sitesById[hazard.siteId]?.name ??
                                    'Unknown site',
                              ),
                              onAcknowledge: () =>
                                  _acknowledge(organizationId, hazard),
                              onClose: () =>
                                  _confirmClose(organizationId, hazard),
                              onCreateCorrectiveAction: () =>
                                  _openCreateCorrectiveActionDialog(
                                    organizationId,
                                    hazard,
                                  ),
                            ),
                            const SizedBox(height: AppSpacing.sm),
                          ],
                        ],
                      );
                    },
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

class _HazardManagementRow extends StatelessWidget {
  const _HazardManagementRow({
    required this.hazard,
    required this.siteName,
    this.action,
    required this.isSaving,
    required this.onTap,
    required this.onAcknowledge,
    required this.onClose,
    required this.onCreateCorrectiveAction,
  });

  final Hazard hazard;
  final String siteName;

  /// Its linked corrective action, when it has one — decides the tag.
  final CorrectiveAction? action;
  final bool isSaving;
  final VoidCallback onTap;
  final VoidCallback onAcknowledge;
  final VoidCallback onClose;
  final VoidCallback onCreateCorrectiveAction;

  @override
  Widget build(BuildContext context) {
    final category = hazard.category;
    final reported = hazard.status == HazardStatus.reported;
    final acknowledged = hazard.status == HazardStatus.acknowledged;
    return AccentCard(
      color: category.color,
      icon: category.icon,
      title: category.label,
      onTap: onTap,
      dimmed: hazard.status == HazardStatus.closed,
      trailing: Text(category.emoji, style: const TextStyle(fontSize: 26)),
      badges: [
        if (hazard.kind == HazardKind.nearMiss)
          AccentBadge(label: hazard.kind.label, color: hazard.kind.color),
        AccentBadge(
          label: ReportProgress.forHazard(hazard, action).label,
          color: ReportProgress.forHazard(hazard, action).color,
        ),
      ],
      body: hazard.description,
      details: [
        AccentDetail(
          icon: Icons.place,
          text:
              'Site: $siteName'
              '${hazard.location != null ? ' · ${hazard.location}' : ''}',
        ),
        AccentDetail(
          icon: Icons.schedule,
          text: 'Reported: ${_formatDate(hazard.createdAt)}',
        ),
        if (hazard.inspectionName != null)
          AccentDetail(
            icon: Icons.fact_check_outlined,
            text: 'Found in: ${hazard.inspectionName}',
          ),
        if (hazard.photoUrl != null)
          const AccentDetail(icon: Icons.photo_camera, text: 'Photo attached'),
      ],
      actions: [
        if (reported)
          AccentButton(
            label: 'Acknowledge',
            icon: Icons.visibility,
            color: AppColors.meetings,
            onPressed: isSaving ? null : onAcknowledge,
          ),
        if (reported || acknowledged)
          AccentButton(
            label: 'Create Corrective Action',
            icon: Icons.build_circle,
            color: AppColors.correctiveActions,
            outlined: reported,
            onPressed: isSaving ? null : onCreateCorrectiveAction,
          ),
        if (reported || acknowledged)
          AccentButton(
            label: 'Close Hazard',
            icon: Icons.check_circle,
            color: AppColors.success,
            outlined: true,
            onPressed: isSaving ? null : onClose,
          ),
      ],
    );
  }
}

Color _hazardStatusColor(HazardStatus status) => status.color;

String _formatDate(DateTime? date) {
  if (date == null) return 'unknown';
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}

/// The full-detail view for one hazard, reached by tapping a row in
/// [HazardsManagementScreen]. Shows every field the current [Hazard] model
/// actually has, the linked corrective action (if any, resolved through the
/// existing [CorrectiveActionRepository] rather than a new data model), and
/// the same reviewer actions as the list row — a closed hazard shows none,
/// since there is intentionally no reopen path.
class _HazardDetailScreen extends StatelessWidget {
  const _HazardDetailScreen({
    required this.organizationId,
    required this.hazard,
    required this.siteName,
    required this.names,
    required this.service,
    required this.correctiveActionRepository,
    required this.onAcknowledge,
    required this.onClose,
    required this.onCreateCorrectiveAction,
  });

  final String organizationId;
  final Hazard hazard;
  final String siteName;

  /// uid → name, so people show by name — see [PeopleDirectory].
  final Map<String, String> names;
  final HazardService service;
  final CorrectiveActionRepository correctiveActionRepository;
  final VoidCallback onAcknowledge;
  final VoidCallback onClose;
  final VoidCallback onCreateCorrectiveAction;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          FeatureHeader(
            eyebrow: hazard.kind.label,
            title: hazard.category.label,
            icon: hazard.category.icon,
            color: hazard.category.color,
            trailing: StatusBadge(
              label: hazard.status.label,
              color: _hazardStatusColor(hazard.status),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Text(hazard.description, style: AppTextStyles.bodyLarge),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          if (hazard.photoUrl != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(AppSpacing.sm),
              child: Image.network(
                hazard.photoUrl!,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => const Padding(
                  padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
                  child: Text(
                    'Could not load the hazard photo.',
                    style: AppTextStyles.bodyMedium,
                  ),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          const FeatureSectionTitle(
            title: 'Details',
            icon: Icons.list_alt,
            color: AppColors.hazards,
          ),
          const SizedBox(height: AppSpacing.sm),
          _DetailRow(label: 'Type', value: hazard.kind.label),
          _DetailRow(label: 'Site', value: siteName),
          if (hazard.location != null)
            _DetailRow(label: 'Location', value: hazard.location!),
          _DetailRow(
            label: 'Reported by',
            value: nameOf(hazard.reportedByUid, names),
          ),
          _DetailRow(
            label: 'Reported at',
            value: _formatDateTime(hazard.createdAt),
          ),
          if (hazard.acknowledgedBy != null)
            _DetailRow(
              label: 'Acknowledged by',
              value: nameOf(hazard.acknowledgedBy, names),
            ),
          if (hazard.acknowledgedAt != null)
            _DetailRow(
              label: 'Acknowledged at',
              value: _formatDateTime(hazard.acknowledgedAt),
            ),
          if (hazard.closedBy != null)
            _DetailRow(
              label: 'Closed by',
              value: nameOf(hazard.closedBy, names),
            ),
          if (hazard.closedAt != null)
            _DetailRow(
              label: 'Closed at',
              value: _formatDateTime(hazard.closedAt),
            ),
          const SizedBox(height: AppSpacing.md),
          if (hazard.correctiveActionId != null) ...[
            const FeatureSectionTitle(
              title: 'Corrective Action',
              icon: Icons.build_circle,
              color: AppColors.correctiveActions,
            ),
            const SizedBox(height: AppSpacing.sm),
            LiveStreamBuilder<CorrectiveAction?>(
              streamKey: (
                correctiveActionRepository,
                hazard.correctiveActionId,
              ),
              stream: () => correctiveActionRepository
                  .getById(hazard.correctiveActionId!)
                  .asStream(),
              builder: (context, snapshot) {
                final action = snapshot.data;
                if (action == null) {
                  return const Text(
                    'Loading the linked corrective action…',
                    style: AppTextStyles.bodyMedium,
                  );
                }
                final assignedToName = nameOf(
                  action.assignedTo,
                  names,
                  stored: action.assignedToName,
                );
                return Card(
                  margin: EdgeInsets.zero,
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    // Opens the action: the assignee submits evidence there,
                    // a reviewer approves or sends it back.
                    onTap: () =>
                        Navigator.of(context, rootNavigator: true).push(
                          MaterialPageRoute<void>(
                            builder: (_) => ReviewCorrectiveActionScreen(
                              organizationId: organizationId,
                              action: action,
                              assignedToName: assignedToName,
                              siteName: siteName,
                              currentUid: context
                                  .read<SessionController>()
                                  .profile
                                  ?.uid,
                            ),
                          ),
                        ),
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(action.title, style: AppTextStyles.titleLarge),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            action.description,
                            style: AppTextStyles.bodyMedium,
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            'Status: ${action.status.label} · '
                            'Assigned: $assignedToName',
                            style: AppTextStyles.bodyMedium,
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            action.assignedTo ==
                                    context
                                        .read<SessionController>()
                                        .profile
                                        ?.uid
                                ? 'Tap to submit your evidence ›'
                                : 'Tap to view or review ›',
                            style: AppTextStyles.label.copyWith(
                              color: AppColors.correctiveActions,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          if (hazard.status == HazardStatus.reported ||
              hazard.status == HazardStatus.acknowledged) ...[
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                if (hazard.status == HazardStatus.reported)
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: AppSpacing.minTouchTarget,
                    ),
                    child: ElevatedButton(
                      onPressed: onAcknowledge,
                      child: const Text('Acknowledge'),
                    ),
                  ),
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: AppSpacing.minTouchTarget,
                  ),
                  child: OutlinedButton(
                    onPressed: onCreateCorrectiveAction,
                    child: const Text('Create Corrective Action'),
                  ),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: AppSpacing.minTouchTarget,
                  ),
                  child: OutlinedButton(
                    onPressed: onClose,
                    child: const Text('Close Hazard'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 120, child: Text(label, style: AppTextStyles.label)),
          Expanded(child: Text(value, style: AppTextStyles.bodyMedium)),
        ],
      ),
    );
  }
}

String _formatDateTime(DateTime? date) {
  if (date == null) return 'unknown';
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  final hour = date.hour.toString().padLeft(2, '0');
  final minute = date.minute.toString().padLeft(2, '0');
  return '${date.year}-$month-$day $hour:$minute';
}
