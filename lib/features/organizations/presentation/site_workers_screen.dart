import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/empty_state.dart';
import '../../authentication/data/account_approval_service.dart';
import '../../authentication/domain/account_status.dart';
import '../../authentication/domain/app_role.dart';
import '../../authentication/domain/organization_user.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../data/site_assignment_service.dart';
import '../domain/organization.dart';
import '../domain/project.dart';
import '../domain/site.dart';
import '../../../core/widgets/feature_header.dart';
import '../../../core/widgets/person_avatar.dart';

/// Shows this site's workforce grouped by the real operational hierarchy —
/// **Foreman -> Crew** — rather than one flat list of names, and lets an
/// authorized administrator assign or remove a Foreman/Worker.
///
/// PHASE 2 (workforce redesign): the Site Manager oversees a site through
/// its Foremen, not by personally tracking every worker — PROJECT_CONTEXT.md
/// §16 and the product brief's "Site Manager -> Foreman -> Workers"
/// operational chain. This screen's landing view is therefore one card per
/// Foreman assigned to the site ("John Kamau — Foreman, 12 workers"); tapping
/// one opens [_CrewScreen], a read-only-plus-remove view of that Foreman's
/// own crew. A site with no Foreman assigned yet, or Workers with no Foreman
/// sharing their site, still show up — see [_groupBySite]'s doc comment for
/// exactly how the grouping works and its one known limitation.
///
/// This is the production entry point for `assignWorkerToSite`/
/// `removeWorkerFromSite` (`SiteAssignmentService`) — those callables and
/// their client wrapper existed before this screen did, so a foreman/worker
/// approved into the company had no path to ever receive
/// `membership.siteIds`, which `DailySafetyMeetingScreen`/
/// `ActivityWorkersScreen` both require.
///
/// **Authorization** mirrors [ActivitiesScreen]/[SitesScreen]'s own
/// `canManage` split exactly: an Admin (any organization) or a Site Manager
/// of [organization] may assign or remove. This matches
/// `requireOrganizationScopedAdmin` (`site_assignment_callable.ts`) — the
/// same authorization `assignWorkerToActivity`/`createActivity` already
/// use — so there is no new backend authorization introduced here, only a
/// UI surface for what the callable already permits. The UI gate is
/// presentation-only; the callable re-verifies the same role server-side
/// regardless of what this screen sends.
///
/// **Eligible users** reuses [AccountApprovalService.listUsers] exactly like
/// [ActivityWorkersScreen] — no second user-listing path is introduced.
/// Only `AccountStatus.active` accounts are requested at all: pending,
/// suspended and rejected accounts are never assignable, matching the
/// product requirement that only an active account can hold operational
/// access.
class SiteWorkersScreen extends StatefulWidget {
  const SiteWorkersScreen({
    required this.organization,
    required this.project,
    required this.site,
    super.key,
    this.assignmentService,
    this.approvalService,
  });

  final Organization organization;
  final Project project;
  final Site site;

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real dependencies.
  final SiteAssignmentService? assignmentService;
  final AccountApprovalService? approvalService;

  @override
  State<SiteWorkersScreen> createState() => _SiteWorkersScreenState();
}

/// One Foreman assigned to this site, and the Workers sharing that site
/// with them (their inferred crew).
class _Crew {
  const _Crew({required this.foreman, required this.workers});

  final OrganizationUser foreman;
  final List<OrganizationUser> workers;
}

class _SiteWorkersScreenState extends State<SiteWorkersScreen> {
  late final SiteAssignmentService _assignmentService =
      widget.assignmentService ?? SiteAssignmentService();
  late final AccountApprovalService _approvalService =
      widget.approvalService ?? AccountApprovalService();

  String? _errorMessage;
  bool _isBusy = false;

  /// The organization's active members, refreshed after every
  /// assign/remove so the crew groupings and the candidate picker both stay
  /// current without a second, separate stream.
  List<OrganizationUser> _members = const [];
  bool _isLoadingMembers = true;

  @override
  void initState() {
    super.initState();
    _loadMembers();
  }

  Future<void> _loadMembers() async {
    setState(() => _isLoadingMembers = true);
    try {
      // Explicitly scoped to this screen's own organization: an Admin may be
      // viewing any organization, while a Site Manager reviewer's own
      // acting organization must equal it too (see `canManage` in build()),
      // so passing widget.organization.id directly is correct for both.
      final users = await _approvalService.listUsers(
        status: AccountStatus.active,
        organizationId: widget.organization.id,
      );
      if (!mounted) return;
      setState(() {
        _members = users
            .where((user) => user.organizationId == widget.organization.id)
            .toList(growable: false);
      });
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isLoadingMembers = false);
    }
  }

  Future<void> _removeAssignment(String uid) async {
    setState(() {
      _isBusy = true;
      _errorMessage = null;
    });
    try {
      await _assignmentService.removeWorkerFromSite(
        uid: uid,
        organizationId: widget.organization.id,
        siteId: widget.site.id,
      );
      await _loadMembers();
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _openAssignPicker() async {
    final assignedUids = _members
        .where((u) => u.siteIds.contains(widget.site.id))
        .map((u) => u.uid)
        .toSet();
    final candidates = _members
        .where((u) => !assignedUids.contains(u.uid))
        .toList(growable: false);

    final selected = await showDialog<OrganizationUser>(
      context: context,
      builder: (_) => _WorkerPickerDialog(candidates: candidates),
    );
    if (selected == null || !mounted) return;

    setState(() {
      _isBusy = true;
      _errorMessage = null;
    });
    try {
      await _assignmentService.assignWorkerToSite(
        uid: selected.uid,
        organizationId: widget.organization.id,
        siteId: widget.site.id,
      );
      await _loadMembers();
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  /// Groups this site's assigned members into Foreman -> Crew.
  ///
  /// There is no explicit supervisor link in the data today (the schema's
  /// `supervisorUid` field exists but is never actually written by any
  /// approval flow — see PROJECT_CONTEXT.md and `account_approval.ts`), so
  /// a Worker's crew is inferred from sharing this SITE with a Foreman:
  /// every Worker assigned here is grouped under every Foreman also
  /// assigned here. This matches the real JV ALMA CIS workflow (one Foreman
  /// per site) exactly, but is a KNOWN LIMITATION if a site is ever shared
  /// by two Foremen at once — a Worker would then appear under both, since
  /// nothing in the data says which one actually supervises them.
  ///
  /// Workers with no Foreman assigned to this site at all are collected
  /// separately (`unassignedWorkers` in the returned record) rather than
  /// silently dropped — an operational gap worth surfacing, not hiding.
  ({List<_Crew> crews, List<OrganizationUser> unassignedWorkers}) _groupBySite(
    List<OrganizationUser> assignedMembers,
  ) {
    final foremen = assignedMembers
        .where((u) => u.role == AppRole.foreman)
        .toList(growable: false);
    final workers = assignedMembers
        .where((u) => u.role == AppRole.worker)
        .toList(growable: false);

    final crews = [
      for (final foreman in foremen) _Crew(foreman: foreman, workers: workers),
    ];
    final unassignedWorkers = foremen.isEmpty
        ? workers
        : const <OrganizationUser>[];

    return (crews: crews, unassignedWorkers: unassignedWorkers);
  }

  Future<void> _openCrew(_Crew crew) async {
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => _CrewScreen(
          crew: crew,
          isBusy: _isBusy,
          onRemoveWorker: (uid) => _removeAssignment(uid),
        ),
      ),
    );
    // A removal inside the crew screen already updated `_members` via
    // `_loadMembers` (shared state, not screen-local) — this rebuild just
    // reflects that on return, in case the removed worker's card needs to
    // update (e.g. the crew count shown here).
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final sessionController = context.watch<SessionController>();
    final profile = sessionController.profile;
    final isPlatformAdministrator = profile?.isPlatformAdministrator ?? false;
    // Checked against membershipFor(widget.organization.id) SPECIFICALLY,
    // not activeMembership — see ProjectsScreen's matching comment for why.
    final canManage =
        isPlatformAdministrator ||
        sessionController
                .membershipFor(widget.organization.id)
                ?.role
                .canManageOrgContent ==
            true;

    if (!canManage) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: Text(
            'You do not have permission to manage site workers.',
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final assignedMembers = _members
        .where((u) => u.siteIds.contains(widget.site.id))
        .toList(growable: false);
    final grouped = _groupBySite(assignedMembers);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        FeatureHeader(
          eyebrow: 'Workforce',
          title: widget.site.name,
          subtitle: '${widget.organization.name} · ${widget.project.name}',
          icon: Icons.groups,
          color: AppColors.people,
          chips: [
            FeatureChip(
              icon: Icons.engineering,
              label:
                  '${grouped.crews.length} '
                  '${grouped.crews.length == 1 ? 'crew' : 'crews'}',
            ),
            FeatureChip(
              icon: Icons.person,
              label:
                  '${assignedMembers.length} '
                  '${assignedMembers.length == 1 ? 'person' : 'people'} on site',
            ),
          ],
          footer: Tooltip(
            message: 'Assign to this site',
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: AppColors.people,
                minimumSize: const Size(0, AppSpacing.minTouchTarget),
              ),
              onPressed: _isBusy || _isLoadingMembers
                  ? null
                  : _openAssignPicker,
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('Add Person'),
            ),
          ),
        ),

        if (_errorMessage != null) ...[
          const SizedBox(height: AppSpacing.md),
          AuthErrorBanner(message: _errorMessage!),
        ],
        const SizedBox(height: AppSpacing.md),
        if (_isLoadingMembers && assignedMembers.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (!_isLoadingMembers && assignedMembers.isEmpty)
          EmptyState(
            icon: Icons.groups_outlined,
            title: 'No one assigned yet',
            message: 'Assign a Foreman, then their crew, to this site.',
            action: ElevatedButton.icon(
              onPressed: _isBusy ? null : _openAssignPicker,
              icon: const Icon(Icons.person_add_alt_1_outlined),
              label: const Text('Assign to this site'),
            ),
          ),
        for (final crew in grouped.crews) ...[
          _ForemanCrewCard(
            crew: crew,
            isBusy: _isBusy,
            onTap: () => _openCrew(crew),
            onRemoveForeman: () => _removeAssignment(crew.foreman.uid),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        if (grouped.unassignedWorkers.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          Container(
            padding: const EdgeInsets.all(AppSpacing.sm + 2),
            decoration: BoxDecoration(
              color: AppColors.warning.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.warning),
            ),
            child: Row(
              children: [
                const Icon(Icons.warning_amber, color: AppColors.warning),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'No Foreman assigned — workers below have no supervisor '
                    'at this site yet',
                    style: AppTextStyles.label,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          for (final worker in grouped.unassignedWorkers) ...[
            _WorkerCard(
              worker: worker,
              isBusy: _isBusy,
              onRemove: () => _removeAssignment(worker.uid),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ],
      ],
    );
  }
}

/// A Foreman's summary card on the site's landing list: name, role, and
/// crew size — tapping it opens [_CrewScreen] for the detail.
class _ForemanCrewCard extends StatelessWidget {
  const _ForemanCrewCard({
    required this.crew,
    required this.isBusy,
    required this.onTap,
    required this.onRemoveForeman,
  });

  final _Crew crew;
  final bool isBusy;
  final VoidCallback onTap;
  final VoidCallback onRemoveForeman;

  @override
  Widget build(BuildContext context) {
    final workerCount = crew.workers.length;
    return Card(
      margin: EdgeInsets.zero,
      color: Color.alphaBlend(
        AppColors.hazards.withValues(alpha: 0.07),
        Theme.of(context).colorScheme.surface,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: AppColors.hazards.withValues(alpha: 0.5)),
      ),
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        leading: PersonAvatar(name: crew.foreman.name),
        title: Text(
          crew.foreman.name,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          [
            'Foreman',
            workerCount == 1 ? '1 worker' : '$workerCount workers',
          ].join(' · '),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Remove from this site',
              onPressed: isBusy ? null : onRemoveForeman,
              icon: const Icon(
                Icons.person_remove_outlined,
                color: AppColors.danger,
              ),
            ),
            const Icon(Icons.chevron_right, color: AppColors.hazards),
          ],
        ),
      ),
    );
  }
}

/// One worker with no Foreman covering their site — shown flat, outside
/// any crew grouping, since there is nothing to group them under.
class _WorkerCard extends StatelessWidget {
  const _WorkerCard({
    required this.worker,
    required this.isBusy,
    required this.onRemove,
  });

  final OrganizationUser worker;
  final bool isBusy;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: AppColors.people.withValues(alpha: 0.4)),
      ),
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
          ].join(' · '),
        ),
        trailing: IconButton(
          tooltip: 'Remove',
          onPressed: isBusy ? null : onRemove,
          icon: const Icon(
            Icons.person_remove_outlined,
            color: AppColors.danger,
          ),
        ),
      ),
    );
  }
}

/// Drill-down view of one Foreman's crew — reached by tapping their card
/// on [SiteWorkersScreen]'s landing list.
class _CrewScreen extends StatelessWidget {
  const _CrewScreen({
    required this.crew,
    required this.isBusy,
    required this.onRemoveWorker,
  });

  final _Crew crew;
  final bool isBusy;
  final ValueChanged<String> onRemoveWorker;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          FeatureHeader(
            eyebrow: 'Crew',
            title: crew.foreman.name,
            subtitle: crew.foreman.email,
            icon: Icons.engineering,
            color: AppColors.hazards,
            chips: [
              FeatureChip(
                icon: Icons.groups,
                label:
                    '${crew.workers.length} '
                    '${crew.workers.length == 1 ? 'crew member' : 'crew members'}',
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          const FeatureSectionTitle(
            title: 'Foreman',
            icon: Icons.engineering,
            color: AppColors.hazards,
          ),
          const SizedBox(height: AppSpacing.sm),
          Card(
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: AppColors.hazards.withValues(alpha: 0.5)),
            ),
            child: ListTile(
              leading: PersonAvatar(name: crew.foreman.name),
              title: Text(
                crew.foreman.name,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(crew.foreman.email),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          FeatureSectionTitle(
            title: crew.workers.length == 1
                ? 'Workers (1)'
                : 'Workers (${crew.workers.length})',
            icon: Icons.groups,
            color: AppColors.people,
          ),
          const SizedBox(height: AppSpacing.xs),
          if (crew.workers.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
              child: Text(
                'No workers assigned to this crew yet.',
                style: AppTextStyles.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ),
          for (final worker in crew.workers) ...[
            _WorkerCard(
              worker: worker,
              isBusy: isBusy,
              onRemove: () => onRemoveWorker(worker.uid),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ],
      ),
    );
  }
}

class _WorkerPickerDialog extends StatefulWidget {
  const _WorkerPickerDialog({required this.candidates});

  final List<OrganizationUser> candidates;

  @override
  State<_WorkerPickerDialog> createState() => _WorkerPickerDialogState();
}

class _WorkerPickerDialogState extends State<_WorkerPickerDialog> {
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final query = _search.trim().toLowerCase();
    final filtered = query.isEmpty
        ? widget.candidates
        : widget.candidates
              .where((c) => c.name.toLowerCase().contains(query))
              .toList(growable: false);

    return AlertDialog(
      title: const Text('Assign to this site'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.candidates.isNotEmpty)
              TextField(
                decoration: const InputDecoration(hintText: 'Search...'),
                onChanged: (value) => setState(() => _search = value),
              ),
            if (widget.candidates.isNotEmpty)
              const SizedBox(height: AppSpacing.sm),
            if (widget.candidates.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
                child: Text(
                  'No eligible active users in this organization to assign.',
                  style: AppTextStyles.bodyMedium,
                ),
              )
            else if (filtered.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
                child: Text(
                  'No users match that search.',
                  style: AppTextStyles.bodyMedium,
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final candidate = filtered[index];
                    return ListTile(
                      title: Text(candidate.name),
                      subtitle: Text(candidate.role?.label ?? candidate.email),
                      onTap: () => Navigator.of(context).pop(candidate),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
