import 'package:flutter/material.dart';
import '../../corrective_actions/presentation/report_progress.dart';
import '../../authentication/domain/app_role.dart';
import '../../corrective_actions/domain/corrective_action_status.dart';
import '../../corrective_actions/presentation/submit_corrective_action_screen.dart';
import '../../safety_reporting/presentation/report_safety_issue_screen.dart';
import '../../corrective_actions/presentation/review_corrective_action_screen.dart';
import '../../organizations/data/site_repository.dart';
import '../../authentication/data/people_directory.dart';
import '../../../core/widgets/live_stream_builder.dart';
import 'package:provider/provider.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/accent_card.dart';
import '../../../core/widgets/color_choice_chips.dart';
import '../../../core/widgets/feature_header.dart';
import '../../../core/widgets/organization_scope_selector.dart';
import '../../authentication/data/account_approval_service.dart';
import '../../authentication/domain/organization_user.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../../corrective_actions/data/corrective_action_repository.dart';
import '../../corrective_actions/domain/corrective_action.dart';
import '../../corrective_actions/presentation/corrective_action_form_screen.dart';
import '../../organizations/data/organization_repository.dart';
import '../data/incident_repository.dart';
import '../data/incident_service.dart';
import '../domain/incident.dart';
import '../domain/incident_enums.dart';
import 'incident_style.dart';

/// The "Incidents" nav destination ([AppRoutes.incidents]).
///
/// A reviewer role (`admin`/`siteManager`/`foreman` — the same set
/// `incident_callable.ts` and `firestore.rules` accept) sees every incident
/// in the organization, filterable by status, and can open one to
/// investigate, raise corrective actions and close it. Anyone else sees only
/// the incidents they reported themselves — `firestore.rules` admits nothing
/// more for them. Everyone can report a new incident from here.
class IncidentsScreen extends StatefulWidget {
  const IncidentsScreen({
    super.key,
    this.repository,
    this.service,
    this.correctiveActionRepository,
    this.approvalService,
    this.organizationRepository,
  });

  /// Injected in tests.
  final IncidentRepository? repository;
  final IncidentService? service;
  final CorrectiveActionRepository? correctiveActionRepository;
  final AccountApprovalService? approvalService;
  final OrganizationRepository? organizationRepository;

  @override
  State<IncidentsScreen> createState() => _IncidentsScreenState();
}

/// The reviewer's status filter — `Open` (anything not closed) by default.
enum _IncidentFilter {
  open,
  reported,
  underInvestigation,
  closed,
  all;

  String get label => switch (this) {
    _IncidentFilter.open => 'Open',
    _IncidentFilter.reported => 'Reported',
    _IncidentFilter.underInvestigation => 'Investigating',
    _IncidentFilter.closed => 'Closed',
    _IncidentFilter.all => 'All',
  };

  Color get color => switch (this) {
    _IncidentFilter.open => AppColors.stop,
    _IncidentFilter.reported => IncidentStatus.reported.color,
    _IncidentFilter.underInvestigation =>
      IncidentStatus.underInvestigation.color,
    _IncidentFilter.closed => IncidentStatus.closed.color,
    _IncidentFilter.all => AppColors.textSecondary,
  };

  bool matches(Incident incident) => switch (this) {
    _IncidentFilter.open => !incident.isClosed,
    _IncidentFilter.reported => incident.status == IncidentStatus.reported,
    _IncidentFilter.underInvestigation =>
      incident.status == IncidentStatus.underInvestigation,
    _IncidentFilter.closed => incident.isClosed,
    _IncidentFilter.all => true,
  };
}

class _IncidentsScreenState extends State<IncidentsScreen> {
  IncidentRepository? _repository;
  CorrectiveActionRepository? _actionRepository;
  String? _selectedOrganizationId;
  _IncidentFilter _filter = _IncidentFilter.open;

  IncidentRepository _repositoryFor(String organizationId) {
    final existing = _repository;
    if (existing != null && existing.organizationId == organizationId) {
      return existing;
    }
    return _repository =
        widget.repository ??
        IncidentRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );
  }

  CorrectiveActionRepository _actionRepositoryFor(String organizationId) {
    final existing = _actionRepository;
    if (existing != null && existing.organizationId == organizationId) {
      return existing;
    }
    return _actionRepository =
        widget.correctiveActionRepository ??
        CorrectiveActionRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );
  }

  void _openReport() {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            ReportSafetyIssueScreen(organizationId: _selectedOrganizationId),
      ),
    );
  }

  void _openDetail(String organizationId, Incident incident, bool canManage) {
    final session = context.read<SessionController>();
    final role = session.activeMembership?.role;
    // Investigating (start, add actions, close) is the Site Manager's /
    // Admin's job — matching `incident_callable.ts`'s
    // `requireIncidentInvestigator`. A Foreman sees the incident and
    // submits evidence on the actions assigned to them.
    final canInvestigate =
        (session.profile?.isPlatformAdministrator ?? false) ||
        role == AppRole.admin ||
        role == AppRole.siteManager;
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => IncidentDetailScreen(
          organizationId: organizationId,
          incidentId: incident.id,
          canManage: canManage,
          canInvestigate: canInvestigate,
          repository: _repositoryFor(organizationId),
          correctiveActionRepository: _actionRepositoryFor(organizationId),
          service: widget.service,
          approvalService: widget.approvalService,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final isPlatformAdministrator =
        session.profile?.isPlatformAdministrator ?? false;
    final canManage =
        isPlatformAdministrator ||
        (session.activeMembership?.role.canReviewPendingAccounts ?? false);
    final uid = session.profile?.uid;
    final organizationId = isPlatformAdministrator
        ? _selectedOrganizationId
        : session.activeOrganizationId;

    if (organizationId == null || uid == null) {
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
            'Your account is not yet assigned to an organization.',
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final repository = _repositoryFor(organizationId);
    final stream = canManage
        ? repository.watchForOrganization()
        : repository.watchReportedBy(uid);

    return Scaffold(
      body: LiveStreamBuilder<List<Incident>>(
        streamKey: (repository, canManage, uid),
        stream: () => stream,
        builder: (context, snapshot) {
          final all = snapshot.data ?? const <Incident>[];
          final incidents = canManage
              ? all.where(_filter.matches).toList()
              : all;
          final isLoading = snapshot.connectionState == ConnectionState.waiting;

          return ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.md,
              96,
            ),
            children: [
              FeatureHeader(
                title: canManage ? 'Incidents' : 'My Incident Reports',
                subtitle: canManage
                    ? 'Everything that actually happened on site, and its '
                          'investigation.'
                    : 'Incidents you have reported and their status.',
                icon: Icons.personal_injury,
                color: AppColors.stop,
                chips: [
                  for (final status in IncidentStatus.values)
                    FeatureChip(
                      icon: status.icon,
                      label:
                          '${all.where((i) => i.status == status).length} '
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
              if (canManage) ...[
                ColorChoiceChips<_IncidentFilter>(
                  selected: _filter,
                  onSelected: (value) => setState(() => _filter = value),
                  choices: [
                    for (final filter in _IncidentFilter.values)
                      ColorChoice(
                        value: filter,
                        label: filter.label,
                        color: filter.color,
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
              ],
              if (isLoading && all.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (snapshot.hasError)
                const _Message('Could not load incidents. Please try again.'),
              if (!isLoading && !snapshot.hasError && incidents.isEmpty)
                _Message(
                  all.isEmpty
                      ? 'No incidents have been reported.'
                      : 'No incidents match this filter.',
                ),
              // Each card's tag follows its corrective actions — see
              // ReportProgress.
              if (incidents.isNotEmpty)
                LiveStreamBuilder<List<CorrectiveAction>>(
                  streamKey: organizationId,
                  stream: () => _actionRepositoryFor(
                    organizationId,
                  ).watchForOrganization(),
                  builder: (context, actionSnapshot) {
                    final byIncident = actionsByIncident(
                      actionSnapshot.data ?? const <CorrectiveAction>[],
                    );
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final incident in incidents) ...[
                          IncidentCard(
                            incident: incident,
                            actions: byIncident[incident.id] ?? const [],
                            onTap: () => _openDetail(
                              organizationId,
                              incident,
                              canManage,
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
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'report-incident',
        backgroundColor: AppColors.stop,
        foregroundColor: AppColors.onColor(AppColors.stop),
        onPressed: _openReport,
        icon: const Icon(Icons.campaign),
        label: const Text('Report a Safety Issue'),
      ),
    );
  }
}

/// One incident in a list — its type in its own colour, with status and
/// (once classified) severity badges.
class IncidentCard extends StatelessWidget {
  const IncidentCard({
    super.key,
    required this.incident,
    this.actions = const [],
    this.onTap,
  });

  final Incident incident;

  /// Its corrective actions — they decide the progress tag.
  final List<CorrectiveAction> actions;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final severity = incident.severity;
    final progress = ReportProgress.forIncident(incident, actions);
    return AccentCard(
      color: incident.type.color,
      icon: incident.type.icon,
      title: incident.type.label,
      onTap: onTap,
      dimmed: incident.isClosed,
      trailing: Text(incident.type.emoji, style: const TextStyle(fontSize: 26)),
      badges: [
        AccentBadge(label: progress.label, color: progress.color),
        if (severity != null)
          AccentBadge(label: severity.label, color: severity.color),
      ],
      body: incident.description,
      details: [
        AccentDetail(
          icon: Icons.schedule,
          text: 'Happened: ${_formatDateTime(incident.occurredAt)}',
        ),
        if (incident.location != null)
          AccentDetail(icon: Icons.place, text: incident.location!),
        if (incident.correctiveActionIds.isNotEmpty)
          AccentDetail(
            icon: Icons.build_circle,
            text: '${incident.correctiveActionIds.length} corrective action(s)',
          ),
      ],
    );
  }
}

/// One incident in full, live — so it updates as the investigation moves
/// on. A reviewer gets the investigation actions for its current status:
/// start the investigation (classifying severity), raise corrective
/// actions, and close it with a root cause.
class IncidentDetailScreen extends StatefulWidget {
  const IncidentDetailScreen({
    super.key,
    required this.organizationId,
    required this.incidentId,
    required this.canManage,
    this.canInvestigate = false,
    required this.repository,
    required this.correctiveActionRepository,
    this.service,
    this.approvalService,
    this.siteRepository,
  });

  /// Injected in tests — looks up the incident's site name.
  final SiteRepository? siteRepository;

  final String organizationId;
  final String incidentId;
  final bool canManage;

  /// May start the investigation, raise corrective actions and close the
  /// incident — Site Manager/Admin only (see `requireIncidentInvestigator`).
  final bool canInvestigate;
  final IncidentRepository repository;
  final CorrectiveActionRepository correctiveActionRepository;
  final IncidentService? service;
  final AccountApprovalService? approvalService;

  @override
  State<IncidentDetailScreen> createState() => _IncidentDetailScreenState();
}

class _IncidentDetailScreenState extends State<IncidentDetailScreen> {
  late final IncidentService _service = widget.service ?? IncidentService();
  late final Stream<Incident?> _incident = widget.repository.watchById(
    widget.incidentId,
  );
  late final Stream<List<CorrectiveAction>> _actions = widget
      .correctiveActionRepository
      .watchForIncident(widget.incidentId);

  bool _isSaving = false;
  String? _errorMessage;

  /// uid → name for reviewers (see [PeopleDirectory]); stays empty for a
  /// worker, who sees their own report as "You".
  Map<String, String> _names = const {};
  final Map<String, Future<String?>> _siteNames = {};

  @override
  void initState() {
    super.initState();
    if (widget.canManage) {
      PeopleDirectory(
        service: widget.approvalService,
      ).namesFor(widget.organizationId).then((names) {
        if (mounted) setState(() => _names = names);
      });
    }
  }

  /// The site's name, looked up once; null when it can't be loaded.
  Future<String?> _siteNameFor(String siteId) {
    return _siteNames.putIfAbsent(siteId, () async {
      try {
        final repository =
            widget.siteRepository ??
            SiteRepository(
              firestoreService: FirestoreService(),
              organizationId: widget.organizationId,
            );
        return (await repository.getById(siteId))?.name;
      } on Object {
        return null;
      }
    });
  }

  bool _isMine(CorrectiveAction action) =>
      action.assignedTo == context.read<SessionController>().profile?.uid;

  bool _canSubmit(CorrectiveAction action) =>
      _isMine(action) &&
      (action.status == CorrectiveActionStatus.open ||
          action.status == CorrectiveActionStatus.inProgress);

  String _personName(String? uid, {String? stored}) {
    final me = context.read<SessionController>().profile?.uid;
    if (uid != null && uid == me) return 'You';
    return nameOf(uid, _names, stored: stored);
  }

  Future<void> _openSubmit(CorrectiveAction action) async {
    final submitted = await Navigator.of(context, rootNavigator: true)
        .push<bool>(
          MaterialPageRoute(
            builder: (_) => SubmitCorrectiveActionScreen(
              organizationId: widget.organizationId,
              action: action,
            ),
          ),
        );
    if (submitted == true && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Submitted for review.')));
    }
  }

  Future<void> _openAction(CorrectiveAction action, String siteName) {
    return Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => ReviewCorrectiveActionScreen(
          organizationId: widget.organizationId,
          action: action,
          assignedToName: _personName(
            action.assignedTo,
            stored: action.assignedToName,
          ),
          siteName: siteName,
          currentUid: context.read<SessionController>().profile?.uid,
        ),
      ),
    );
  }

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

  Future<void> _startInvestigation() async {
    final severity = await showDialog<IncidentSeverity>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('How serious was it?'),
        children: [
          for (final option in IncidentSeverity.values)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(option),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: option.color,
                  radius: 10,
                ),
                title: Text(option.label),
                subtitle: Text(option.guidance),
              ),
            ),
        ],
      ),
    );
    if (severity == null) return;
    await _run(
      () => _service.startInvestigation(
        organizationId: widget.organizationId,
        incidentId: widget.incidentId,
        severity: severity.id,
      ),
    );
  }

  Future<void> _raiseCorrectiveAction(Incident incident) async {
    final approvalService = widget.approvalService ?? AccountApprovalService();
    final List<OrganizationUser> people;
    try {
      people = await approvalService.listUsers(
        organizationId: widget.organizationId,
      );
    } on AppException catch (e) {
      if (mounted) setState(() => _errorMessage = e.message);
      return;
    }
    if (!mounted) return;
    final candidates = [
      for (final user in people)
        if (user.siteIds.contains(incident.siteId)) user.uid,
    ]..sort();

    final result = await Navigator.of(context, rootNavigator: true)
        .push<CorrectiveActionFormResult>(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => CorrectiveActionFormScreen(
              eyebrow: 'From an incident investigation',
              candidateAssignees: candidates,
              people: people,
            ),
          ),
        );
    if (result == null) return;
    await _run(
      () => _service.linkCorrectiveAction(
        organizationId: widget.organizationId,
        incidentId: widget.incidentId,
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

  Future<void> _close() async {
    final result = await showDialog<(String, String?)>(
      context: context,
      builder: (_) => const _CloseIncidentDialog(),
    );
    if (result == null) return;
    await _run(
      () => _service.closeIncident(
        organizationId: widget.organizationId,
        incidentId: widget.incidentId,
        rootCause: result.$1,
        closingNotes: result.$2,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: StreamBuilder<Incident?>(
        stream: _incident,
        builder: (context, snapshot) {
          final incident = snapshot.data;
          if (incident == null) {
            return snapshot.hasError
                ? const _Message('Could not load this incident.')
                : const Center(child: CircularProgressIndicator());
          }
          return StreamBuilder<List<CorrectiveAction>>(
            stream: _actions,
            builder: (context, actionSnapshot) => _buildBody(
              incident,
              actionSnapshot.data ?? const <CorrectiveAction>[],
            ),
          );
        },
      ),
    );
  }

  Widget _buildBody(Incident incident, List<CorrectiveAction> actions) {
    final severity = incident.severity;
    final incomplete = actions.where((a) => !a.isCompleted).length;
    final investigating = incident.status == IncidentStatus.underInvestigation;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        FeatureHeader(
          eyebrow: 'Incident',
          title: incident.type.label,
          icon: incident.type.icon,
          color: incident.type.color,
          chips: [
            FeatureChip(
              icon: ReportProgress.forIncident(incident, actions).icon,
              label: ReportProgress.forIncident(incident, actions).label,
            ),
            if (severity != null)
              FeatureChip(icon: Icons.speed, label: severity.label),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        if (_errorMessage != null) ...[
          AuthErrorBanner(message: _errorMessage!),
          const SizedBox(height: AppSpacing.md),
        ],
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Text(incident.description, style: AppTextStyles.bodyLarge),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        if (incident.photoUrl != null) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(AppSpacing.sm),
            child: Image.network(
              incident.photoUrl!,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) =>
                  const _Message('Could not load the incident photo.'),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        const FeatureSectionTitle(
          title: 'Details',
          icon: Icons.list_alt,
          color: AppColors.stop,
        ),
        const SizedBox(height: AppSpacing.sm),
        _DetailRow('Happened', _formatDateTime(incident.occurredAt)),
        if (incident.createdAt != null)
          _DetailRow('Reported', _formatDateTime(incident.createdAt!)),
        FutureBuilder<String?>(
          future: _siteNameFor(incident.siteId),
          builder: (context, snapshot) =>
              _DetailRow('Site', snapshot.data ?? 'Loading…'),
        ),
        if (incident.location != null)
          _DetailRow('Location', incident.location!),
        if (incident.injuredPersonName != null)
          _DetailRow('Person hurt', incident.injuredPersonName!),
        if (incident.immediateAction != null)
          _DetailRow('Done straight away', incident.immediateAction!),
        _DetailRow('Reported by', _personName(incident.reportedByUid)),
        if (incident.rootCause != null)
          _DetailRow('Root cause', incident.rootCause!),
        if (incident.closingNotes != null)
          _DetailRow('Closing notes', incident.closingNotes!),
        if (incident.closedAt != null)
          _DetailRow('Closed', _formatDateTime(incident.closedAt!)),
        const SizedBox(height: AppSpacing.md),
        if (actions.isNotEmpty) ...[
          const FeatureSectionTitle(
            title: 'Corrective Actions',
            icon: Icons.build_circle,
            color: AppColors.correctiveActions,
          ),
          const SizedBox(height: AppSpacing.sm),
          for (final action in actions) ...[
            AccentCard(
              color: AppColors.correctiveActions,
              icon: Icons.build_circle,
              title: action.title,
              onTap: widget.canManage || _isMine(action)
                  ? () async => _openAction(
                      action,
                      await _siteNameFor(incident.siteId) ?? 'Unknown site',
                    )
                  : null,
              dimmed: action.isCompleted,
              badges: [
                AccentBadge(
                  label: action.status.label,
                  color: action.isCompleted
                      ? AppColors.success
                      : AppColors.correctiveActions,
                ),
                if (_isMine(action))
                  const AccentBadge(
                    label: 'Assigned to you',
                    color: AppColors.correctiveActions,
                  ),
              ],
              actions: [
                if (_canSubmit(action))
                  AccentButton(
                    label: 'Complete & Submit',
                    icon: Icons.task_alt,
                    color: AppColors.correctiveActions,
                    onPressed: () => _openSubmit(action),
                  ),
                if (action.status ==
                        CorrectiveActionStatus.submittedForReview &&
                    widget.canManage &&
                    !_isMine(action))
                  AccentButton(
                    label: 'Review submission',
                    icon: Icons.fact_check,
                    color: AppColors.correctiveActions,
                    onPressed: () async => _openAction(
                      action,
                      await _siteNameFor(incident.siteId) ?? 'Unknown site',
                    ),
                  ),
              ],
              body: action.description,
              details: [
                AccentDetail(
                  icon: Icons.person,
                  text:
                      'Assigned: '
                      '${_personName(action.assignedTo, stored: action.assignedToName)}',
                ),
                AccentDetail(
                  icon: Icons.event,
                  text: 'Due: ${_formatDateTime(action.dueDate)}',
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
          const SizedBox(height: AppSpacing.sm),
        ],
        if (widget.canInvestigate && !incident.isClosed)
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              if (incident.status == IncidentStatus.reported)
                AccentButton(
                  label: 'Start Investigation',
                  icon: Icons.manage_search,
                  color: AppColors.meetings,
                  onPressed: _isSaving ? null : _startInvestigation,
                ),
              if (investigating)
                AccentButton(
                  label: 'Add Corrective Action',
                  icon: Icons.build_circle,
                  color: AppColors.correctiveActions,
                  outlined: true,
                  onPressed: _isSaving
                      ? null
                      : () => _raiseCorrectiveAction(incident),
                ),
              if (investigating)
                AccentButton(
                  label: 'Close Incident',
                  icon: Icons.check_circle,
                  color: AppColors.success,
                  onPressed: _isSaving || incomplete > 0 ? null : _close,
                ),
            ],
          ),
        if (widget.canInvestigate && investigating && incomplete > 0)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: Text(
              '$incomplete corrective action(s) must be completed before '
              'this incident can be closed.',
              style: AppTextStyles.bodyMedium,
            ),
          ),
      ],
    );
  }
}

/// Asks for the root cause (required) and optional closing notes.
class _CloseIncidentDialog extends StatefulWidget {
  const _CloseIncidentDialog();

  @override
  State<_CloseIncidentDialog> createState() => _CloseIncidentDialogState();
}

class _CloseIncidentDialogState extends State<_CloseIncidentDialog> {
  final _rootCause = TextEditingController();
  final _notes = TextEditingController();

  @override
  void dispose() {
    _rootCause.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rootCause = _rootCause.text.trim();
    return AlertDialog(
      title: const Text('Close Incident'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _rootCause,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Root cause',
                hintText: 'Why did it happen?',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _notes,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Closing notes (optional)',
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            const Text(
              'Closing cannot be undone.',
              style: AppTextStyles.bodyMedium,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: rootCause.isEmpty
              ? null
              : () {
                  final notes = _notes.text.trim();
                  Navigator.of(
                    context,
                  ).pop((rootCause, notes.isEmpty ? null : notes));
                },
          child: const Text('Close Incident'),
        ),
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 140, child: Text(label, style: AppTextStyles.label)),
          Expanded(child: Text(value, style: AppTextStyles.bodyMedium)),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
      child: Text(
        text,
        style: AppTextStyles.bodyMedium,
        textAlign: TextAlign.center,
      ),
    );
  }
}

String _formatDateTime(DateTime date) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)} '
      '${two(date.hour)}:${two(date.minute)}';
}
