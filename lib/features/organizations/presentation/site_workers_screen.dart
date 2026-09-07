import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../authentication/data/account_approval_service.dart';
import '../../authentication/domain/account_status.dart';
import '../../authentication/domain/app_role.dart';
import '../../authentication/domain/organization_user.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../data/site_assignment_service.dart';
import '../domain/organization.dart';
import '../domain/project.dart';
import '../domain/site.dart';

/// Shows the workers/foremen currently assigned to one site and lets an
/// authorized administrator assign or remove one.
///
/// This is the production entry point for `assignWorkerToSite`/
/// `removeWorkerFromSite` (`SiteAssignmentService`) — those callables and
/// their client wrapper existed before this screen did, but had no UI call
/// site, so a foreman/worker approved into an organization had no path to
/// ever receive `profile.siteIds`, which
/// `DailySafetyMeetingScreen`/`ActivityWorkersScreen` both require.
///
/// **Authorization** mirrors [ActivitiesScreen]/[SitesScreen]'s own
/// `canManage` split exactly: a System Administrator (any organization) or
/// an [AppRole.siteManager] of [organization] may assign or
/// remove. This matches `requireOrganizationScopedAdmin`
/// (`site_assignment_callable.ts`) — the same authorization
/// `assignWorkerToActivity`/`createActivity` already use — so there is no
/// new backend authorization introduced here, only a UI surface for what
/// the callable already permits. The UI gate is presentation-only; the
/// callable re-verifies the same role server-side regardless of what this
/// screen sends.
///
/// **Eligible users** reuses [AccountApprovalService.listUsers] exactly like
/// [ActivityWorkersScreen] — no second user-listing path is introduced.
/// Unlike [ActivityWorkersScreen] (whose `listOrganizationUsers` caller is
/// always organization-scoped server-side, since only a
/// `siteManager`/reviewer of one organization ever reaches
/// it), an Admin's call to that same callable returns users
/// across every organization it has authority over — so this screen
/// additionally filters candidates to `user.organizationId == organization.id`
/// client-side, which `ActivityWorkersScreen` does not need to do. Only
/// `AccountStatus.active` accounts are requested at all: pending, suspended
/// and rejected accounts are never assignable, matching the product
/// requirement that only an active account can hold operational access.
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

class _SiteWorkersScreenState extends State<SiteWorkersScreen> {
  late final SiteAssignmentService _assignmentService =
      widget.assignmentService ?? SiteAssignmentService();
  late final AccountApprovalService _approvalService =
      widget.approvalService ?? AccountApprovalService();

  String? _errorMessage;
  bool _isBusy = false;

  /// The organization's active members, refreshed after every
  /// assign/remove so the assigned list and the candidate picker both stay
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

  Future<void> _removeWorker(String uid) async {
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
    final candidates = _members
        .where((u) => !u.siteIds.contains(widget.site.id))
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

  @override
  Widget build(BuildContext context) {
    final sessionController = context.watch<SessionController>();
    final profile = sessionController.profile;
    final isPlatformAdministrator = profile?.isPlatformAdministrator ?? false;
    final canManage = isPlatformAdministrator ||
        (sessionController.activeMembership?.role.canManageOrgContent ==
                true &&
            sessionController.activeOrganizationId == widget.organization.id);

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

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Workers · ${widget.site.name}', style: AppTextStyles.headlineMedium),
                  Text(
                    '${widget.organization.name} · ${widget.project.name}',
                    style: AppTextStyles.bodyMedium,
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Assign worker',
              onPressed: _isBusy || _isLoadingMembers ? null : _openAssignPicker,
              icon: const Icon(Icons.person_add_alt_1_outlined),
            ),
          ],
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
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
            child: Text(
              'No workers assigned yet.',
              style: AppTextStyles.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ),
        for (final member in assignedMembers) ...[
          _AssignedWorkerCard(
            worker: member,
            isBusy: _isBusy,
            onRemove: () => _removeWorker(member.uid),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ],
    );
  }
}

class _AssignedWorkerCard extends StatelessWidget {
  const _AssignedWorkerCard({
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
      child: ListTile(
        title: Text(worker.name),
        subtitle: Text([
          if (worker.role != null) worker.role!.label,
          if (worker.workerType != null) worker.workerType!.label,
          worker.accountStatus.label,
        ].join(' · ')),
        trailing: IconButton(
          tooltip: 'Remove',
          onPressed: isBusy ? null : onRemove,
          icon: const Icon(Icons.person_remove_outlined, color: AppColors.danger),
        ),
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
      title: const Text('Assign Worker'),
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
                      subtitle: Text(
                        candidate.role?.label ?? candidate.email,
                      ),
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
