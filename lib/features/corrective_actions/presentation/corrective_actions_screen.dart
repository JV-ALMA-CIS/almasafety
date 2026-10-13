import 'package:flutter/material.dart';
import '../../../core/widgets/live_stream_builder.dart';
import 'package:provider/provider.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/widgets/accent_card.dart';
import '../../../core/widgets/color_choice_chips.dart';
import '../../../core/widgets/empty_state.dart';
import '../../../core/widgets/feature_header.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/organization_scope_selector.dart';
import '../../authentication/data/people_directory.dart';
import '../../authentication/domain/app_role.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../../organizations/data/organization_repository.dart';
import '../../organizations/data/site_repository.dart';
import '../../organizations/domain/site.dart';
import '../data/corrective_action_repository.dart';
import '../data/corrective_action_service.dart';
import '../domain/corrective_action.dart';
import '../domain/corrective_action_status.dart';
import 'corrective_action_status_color.dart';
import 'review_corrective_action_screen.dart';
import 'submit_corrective_action_screen.dart';
import '../../../core/theme/app_colors.dart';

/// The Corrective Actions list for an authorized supervisor/manager —
/// `admin`/`siteManager`, the same role set
/// `AppRole.canReviewPendingAccounts` already grants review authority to
/// elsewhere in this app. A `foreman` or
/// `worker` sees an access message instead: they create corrective actions
/// from within a meeting ([DailySafetyMeetingScreen]'s Concerns step), but
/// status management is a supervisor/management responsibility, not a
/// per-meeting one — see `corrective_action_callable.ts`'s
/// `requireOrganizationScopedReviewer`, which this screen's actions mirror.
///
/// An `admin` has no organization of their own, so this screen
/// shows [OrganizationScopeSelector] for that role instead of blocking it —
/// `firestore.rules`'s `isAdmin()` already permits reading
/// every organization's corrective actions; the selector only decides which
/// organization's data to display.
///
/// Shows every corrective action across the organization's sites and
/// meetings — action, site, assigned person, due date, status — with a
/// large status control per row for the common "move this along" action.
/// Tapping an action opens [ReviewCorrectiveActionScreen]: submitted work
/// is approved or sent back there, with the assignee's evidence in view.
class CorrectiveActionsScreen extends StatefulWidget {
  const CorrectiveActionsScreen({
    super.key,
    this.repository,
    this.service,
    this.siteRepository,
    this.organizationRepository,
    this.peopleDirectory,
  });

  /// Injected in tests — resolves assignees' names for actions created
  /// before names were stored on the action itself.
  final PeopleDirectory? peopleDirectory;

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real dependencies scoped to the signed-in user's
  /// organization.
  final CorrectiveActionRepository? repository;
  final CorrectiveActionService? service;
  final SiteRepository? siteRepository;

  /// Injected in tests. Backs [OrganizationScopeSelector] for a System
  /// Administrator, who has no organization of their own to scope
  /// [repository]/[siteRepository] to.
  final OrganizationRepository? organizationRepository;

  @override
  State<CorrectiveActionsScreen> createState() =>
      _CorrectiveActionsScreenState();
}

class _CorrectiveActionsScreenState extends State<CorrectiveActionsScreen> {
  CorrectiveActionStatus? _statusFilter;

  late final CorrectiveActionService _service =
      widget.service ?? CorrectiveActionService();
  late final PeopleDirectory _people =
      widget.peopleDirectory ?? PeopleDirectory();

  Future<void> _openAction(
    String organizationId,
    CorrectiveAction action,
    String assignedToName,
    String siteName,
  ) async {
    final decided = await Navigator.of(context, rootNavigator: true).push<bool>(
      MaterialPageRoute(
        builder: (_) => ReviewCorrectiveActionScreen(
          organizationId: organizationId,
          action: action,
          assignedToName: assignedToName,
          siteName: siteName,
          currentUid: context.read<SessionController>().profile?.uid,
          service: _service,
        ),
      ),
    );
    if (decided == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Corrective action updated.')),
      );
    }
  }

  /// Opens [SubmitCorrectiveActionScreen] for an action assigned to the
  /// signed-in reviewer themselves (e.g. a Foreman assigned by their Site
  /// Manager) — reviewers get this org-wide list, never "My Corrective
  /// Actions", so their own work is submitted from here.
  Future<void> _openSubmit(
    String organizationId,
    CorrectiveAction action,
  ) async {
    final submitted = await Navigator.of(context, rootNavigator: true)
        .push<bool>(
          MaterialPageRoute(
            builder: (_) => SubmitCorrectiveActionScreen(
              organizationId: organizationId,
              action: action,
              service: _service,
            ),
          ),
        );
    if (submitted == true && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Submitted for review.')));
    }
  }

  CorrectiveActionRepository? _repository;
  SiteRepository? _siteRepository;

  String? _errorMessage;
  bool _isSaving = false;
  String? _selectedOrganizationId;

  CorrectiveActionRepository _repositoryFor(String organizationId) {
    final existing = _repository;
    if (existing != null && existing.organizationId == organizationId) {
      return existing;
    }
    final created =
        widget.repository ??
        CorrectiveActionRepository(
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

  Future<void> _updateStatus(
    String organizationId,
    CorrectiveAction action,
    CorrectiveActionStatus status,
  ) async {
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });
    try {
      await _service.updateCorrectiveActionStatus(
        organizationId: organizationId,
        actionId: action.id,
        status: status.id,
      );
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sessionController = context.watch<SessionController>();
    final profile = sessionController.profile;
    final currentUid = profile?.uid;
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
    // outright for them (unlike Admin/Site Manager) — see
    // SiteRepository.watchByIds's own doc comment.
    final foremanSiteIds = membershipRole == AppRole.foreman
        ? sessionController.activeMembership?.siteIds
        : null;

    if (!canManage) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: Text(
            'Corrective Actions are available to Organization '
            'Administrators, Safety Managers and Site Superintendents.',
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
            'Corrective Actions are available to Organization '
            'Administrators, Safety Managers and Site Superintendents.',
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return LiveStreamBuilder<List<CorrectiveAction>>(
      streamKey: _repositoryFor(organizationId),
      stream: () => _repositoryFor(organizationId).watchForOrganization(),
      builder: (context, actionSnapshot) {
        final actions = actionSnapshot.data ?? const <CorrectiveAction>[];
        final isLoading =
            actionSnapshot.connectionState == ConnectionState.waiting;

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

            return FutureBuilder<Map<String, String>>(
              future: _people.namesFor(organizationId),
              builder: (context, namesSnapshot) {
                final names = namesSnapshot.data ?? const <String, String>{};
                return ListView(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    FeatureHeader(
                      title: 'Corrective Actions',
                      subtitle: '${actions.length} across every site',
                      icon: Icons.build_circle,
                      color: AppColors.correctiveActions,
                      chips: [
                        for (final status in CorrectiveActionStatus.values)
                          FeatureChip(
                            icon: correctiveActionStatusIcon(status),
                            label:
                                '${actions.where((a) => a.status == status).length} '
                                '${status.label.toLowerCase()}',
                          ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.md),
                    ColorChoiceChips<CorrectiveActionStatus?>(
                      label: 'Show',
                      selected: _statusFilter,
                      onSelected: (status) =>
                          setState(() => _statusFilter = status),
                      choices: [
                        const ColorChoice(
                          value: null,
                          label: 'All',
                          color: AppColors.textSecondary,
                          icon: Icons.all_inclusive,
                        ),
                        for (final status in CorrectiveActionStatus.values)
                          ColorChoice(
                            value: status,
                            label: status.label,
                            color: correctiveActionStatusColor(status),
                            icon: correctiveActionStatusIcon(status),
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
                    if (isLoading && actions.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    if (!isLoading && actions.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                        child: EmptyState(
                          icon: Icons.build_circle_outlined,
                          title: 'No corrective actions recorded yet.',
                        ),
                      ),
                    // Work assigned to the signed-in reviewer themselves —
                    // what they need to do, first.
                    if (myOpenWork(actions, currentUid).isNotEmpty) ...[
                      FeatureSectionTitle(
                        title: 'Assigned to you',
                        icon: Icons.assignment_ind,
                        color: AppColors.correctiveActions,
                        count: myOpenWork(actions, currentUid).length,
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      for (final action in myOpenWork(actions, currentUid)) ...[
                        _CorrectiveActionRow(
                          action: action,
                          siteName:
                              sitesById[action.siteId]?.name ?? 'Unknown site',
                          assignedToName: nameOf(
                            action.assignedTo,
                            names,
                            stored: action.assignedToName,
                          ),
                          isMine: action.assignedTo == currentUid,
                          onSubmit: () => _openSubmit(organizationId, action),
                          isSaving: _isSaving,
                          onStatusChange: (status) =>
                              _updateStatus(organizationId, action, status),
                          onOpen: () => _openAction(
                            organizationId,
                            action,
                            nameOf(
                              action.assignedTo,
                              names,
                              stored: action.assignedToName,
                            ),
                            sitesById[action.siteId]?.name ?? 'Unknown site',
                          ),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                      ],
                      const SizedBox(height: AppSpacing.sm),
                      const FeatureSectionTitle(
                        title: 'All corrective actions',
                        icon: Icons.build_circle,
                        color: AppColors.correctiveActions,
                      ),
                      const SizedBox(height: AppSpacing.sm),
                    ],
                    for (final action in actions.where(
                      (a) => _statusFilter == null || a.status == _statusFilter,
                    )) ...[
                      _CorrectiveActionRow(
                        action: action,
                        siteName:
                            sitesById[action.siteId]?.name ?? 'Unknown site',
                        assignedToName: nameOf(
                          action.assignedTo,
                          names,
                          stored: action.assignedToName,
                        ),
                        isMine: action.assignedTo == currentUid,
                        onSubmit: () => _openSubmit(organizationId, action),
                        isSaving: _isSaving,
                        onStatusChange: (status) =>
                            _updateStatus(organizationId, action, status),
                        onOpen: () => _openAction(
                          organizationId,
                          action,
                          nameOf(
                            action.assignedTo,
                            names,
                            stored: action.assignedToName,
                          ),
                          sitesById[action.siteId]?.name ?? 'Unknown site',
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                    ],
                  ],
                );
              },
            );
          },
        );
      },
    );
  }
}

class _CorrectiveActionRow extends StatelessWidget {
  const _CorrectiveActionRow({
    required this.action,
    required this.siteName,
    required this.assignedToName,
    required this.isMine,
    required this.onSubmit,
    required this.isSaving,
    required this.onStatusChange,
    required this.onOpen,
  });

  /// Assigned to the signed-in reviewer themselves — they can submit it.
  final bool isMine;
  final VoidCallback onSubmit;

  bool get _canSubmit =>
      isMine &&
      (action.status == CorrectiveActionStatus.open ||
          action.status == CorrectiveActionStatus.inProgress);

  final CorrectiveAction action;
  final String siteName;
  final String assignedToName;
  final bool isSaving;
  final void Function(CorrectiveActionStatus status) onStatusChange;

  /// Opens the action — the review screen, where submitted work is
  /// approved or sent back with its evidence in view.
  final VoidCallback onOpen;

  /// The statuses a reviewer may move THIS action to from its current
  /// status — `completed` only appears once the action is
  /// `submittedForReview` (matching `updateCorrectiveActionStatus`'s own
  /// server-side gate); sending a `submittedForReview` action back to
  /// `open`/`inProgress` is how a reviewer rejects the assignee's claim,
  /// since there is no separate "rejected" status.
  List<CorrectiveActionStatus> get _availableTransitions {
    // Submitted work is approved or sent back on the review screen, where
    // its evidence is in view; "Completed" is never a blind one-tap move.
    if (action.status == CorrectiveActionStatus.submittedForReview ||
        action.status == CorrectiveActionStatus.completed) {
      return const [];
    }
    return const [
      CorrectiveActionStatus.open,
      CorrectiveActionStatus.inProgress,
      CorrectiveActionStatus.overdue,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final color = correctiveActionStatusColor(action.status);
    final moves = _availableTransitions
        .where((status) => status != action.status)
        .toList();
    return AccentCard(
      color: color,
      icon: correctiveActionStatusIcon(action.status),
      title: action.title,
      onTap: onOpen,
      dimmed: action.status == CorrectiveActionStatus.completed,
      badges: [
        AccentBadge(label: action.status.label, color: color),
        if (isMine)
          const AccentBadge(
            label: 'Assigned to you',
            color: AppColors.correctiveActions,
          ),
      ],
      body: action.description,
      details: [
        AccentDetail(icon: Icons.place, text: 'Site: $siteName'),
        if (_canSubmit && action.reviewFeedback != null)
          AccentDetail(
            icon: Icons.reply,
            text: 'Sent back: ${action.reviewFeedback}',
          ),
        if (isMine &&
            action.status == CorrectiveActionStatus.submittedForReview)
          const AccentDetail(
            icon: Icons.hourglass_top,
            text: 'Submitted — another reviewer must approve your own work.',
          ),
        AccentDetail(icon: Icons.person, text: 'Assigned: $assignedToName'),
        AccentDetail(
          icon: Icons.event,
          text: 'Due: ${_formatDate(action.dueDate)}',
        ),
        AccentDetail(
          icon: action.incidentId != null
              ? Icons.personal_injury
              : action.hazardId != null
              ? Icons.warning_amber
              : Icons.groups,
          text: action.incidentId != null
              ? 'Origin: incident investigation'
              : action.hazardId != null
              ? 'Origin: reported hazard'
              : 'Origin: daily safety meeting',
        ),
      ],
      actions: [
        if (_canSubmit)
          AccentButton(
            label: 'Complete & Submit',
            icon: Icons.task_alt,
            color: AppColors.correctiveActions,
            onPressed: isSaving ? null : onSubmit,
          ),
        if (action.status == CorrectiveActionStatus.submittedForReview &&
            !isMine)
          AccentButton(
            label: 'Review submission',
            icon: Icons.fact_check,
            color: AppColors.correctiveActions,
            onPressed: isSaving ? null : onOpen,
          ),
        if (moves.isNotEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text('Move to:', style: AppTextStyles.label),
          ),
        for (final status in moves)
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, AppSpacing.minTouchTarget),
              foregroundColor: AppColors.readable(
                correctiveActionStatusColor(status),
                Theme.of(context).brightness,
              ),
              side: BorderSide(
                color: correctiveActionStatusColor(status),
                width: 1.5,
              ),
            ),
            onPressed: isSaving ? null : () => onStatusChange(status),
            child: Text(status.label),
          ),
      ],
    );
  }
}

String _formatDate(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}

/// The signed-in person's own work still to do: actions assigned to
/// [uid] that are open or in progress (newest first, as listed).
List<CorrectiveAction> myOpenWork(List<CorrectiveAction> actions, String? uid) {
  if (uid == null) return const [];
  return [
    for (final action in actions)
      if (action.assignedTo == uid &&
          (action.status == CorrectiveActionStatus.open ||
              action.status == CorrectiveActionStatus.inProgress))
        action,
  ];
}
