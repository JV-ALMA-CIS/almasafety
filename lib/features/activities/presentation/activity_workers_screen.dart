import 'package:flutter/material.dart';
import '../../../core/widgets/live_stream_builder.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/dashboard_header.dart';
import '../../../core/widgets/empty_state.dart';
import '../../../core/widgets/feature_header.dart';
import '../../../core/widgets/person_avatar.dart';
import '../../../core/widgets/status_badge.dart';
import '../../authentication/data/account_approval_service.dart';
import '../../authentication/domain/account_status.dart';
import '../../authentication/domain/organization_user.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../../organizations/domain/organization.dart';
import '../../organizations/domain/project.dart';
import '../../organizations/domain/site.dart';
import '../../workers/presentation/worker_detail_screen.dart';
import '../data/activity_assignment_repository.dart';
import '../data/activity_assignment_service.dart';
import '../domain/activity.dart';
import '../domain/activity_assignment.dart';

/// Shows the workers assigned to one activity and lets an authorized user
/// assign or remove one.
///
/// **Human-readable selection, matching [SiteWorkersScreen]'s established
/// pattern exactly.** [ActivityAssignment] deliberately stores only a
/// worker's `uid` (see its own doc comment) — this screen resolves each uid
/// against [AccountApprovalService.listUsers]'s organization member list
/// (loaded once via [_loadMembers], not re-fetched per row) to display a
/// name/role/worker-type/status, the same way [SiteWorkersScreen] does for
/// site assignment. A Firestore document id is never shown as the primary
/// value for a worker or an activity — `widget.activity.name`,
/// `widget.site.name` and `widget.organization.name` are used for the
/// activity/site/organization context already carried by this screen's
/// constructor, and each candidate/assigned row is keyed by `uid`
/// internally while always displaying `name` first.
///
/// The worker picker reuses `listOrganizationUsers`
/// ([AccountApprovalService.listUsers]) rather than adding a new Firestore
/// rule that would let a client query other users' profiles directly — see
/// `functions/src/approval_callable.ts`, which already returns exactly what
/// is needed here (including `siteIds`). The candidate list is filtered
/// client-side to active workers who already have this activity's site in
/// their `siteIds`; the server independently re-validates the same
/// relationship in `assignWorkerToActivity` before writing, so this filter
/// is a usability convenience, not the enforcement boundary.
class ActivityWorkersScreen extends StatefulWidget {
  const ActivityWorkersScreen({
    required this.organization,
    required this.project,
    required this.site,
    required this.activity,
    super.key,
    this.assignmentRepository,
    this.assignmentService,
    this.approvalService,
  });

  final Organization organization;
  final Project project;
  final Site site;
  final Activity activity;

  /// Injected in tests.
  final ActivityAssignmentRepository? assignmentRepository;
  final ActivityAssignmentService? assignmentService;
  final AccountApprovalService? approvalService;

  @override
  State<ActivityWorkersScreen> createState() => _ActivityWorkersScreenState();
}

class _ActivityWorkersScreenState extends State<ActivityWorkersScreen> {
  late final ActivityAssignmentRepository _repository =
      widget.assignmentRepository ??
      ActivityAssignmentRepository(
        firestoreService: FirestoreService(),
        organizationId: widget.organization.id,
      );
  late final ActivityAssignmentService _assignmentService =
      widget.assignmentService ?? ActivityAssignmentService();
  late final AccountApprovalService _approvalService =
      widget.approvalService ?? AccountApprovalService();

  String? _errorMessage;
  bool _isBusy = false;

  /// The organization's active members, loaded once and refreshed after
  /// every assign/remove — keyed by `uid` so an [ActivityAssignment] (which
  /// only stores `uid`) can be resolved to a human-readable name/role/
  /// worker-type for display, matching [SiteWorkersScreen]'s `_members`.
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
      final users = await _approvalService.listUsers(
        status: AccountStatus.active,
        organizationId: widget.organization.id,
      );
      if (!mounted) return;
      setState(() => _members = users);
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isLoadingMembers = false);
    }
  }

  OrganizationUser? _memberFor(String uid) {
    for (final member in _members) {
      if (member.uid == uid) return member;
    }
    return null;
  }

  Future<void> _removeWorker(String uid) async {
    setState(() {
      _isBusy = true;
      _errorMessage = null;
    });
    try {
      await _assignmentService.removeWorkerFromActivity(
        uid: uid,
        organizationId: widget.organization.id,
        activityId: widget.activity.id,
      );
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _openAssignPicker(List<String> alreadyAssignedUids) async {
    final candidates = _members
        .where((user) => user.siteIds.contains(widget.site.id))
        .where((user) => !alreadyAssignedUids.contains(user.uid))
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
      await _assignmentService.assignWorkerToActivity(
        uid: selected.uid,
        organizationId: widget.organization.id,
        activityId: widget.activity.id,
      );
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  void _openWorkerDetail(OrganizationUser worker) {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => WorkerDetailScreen(
          worker: worker,
          organizationId: widget.organization.id,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LiveStreamBuilder<List<ActivityAssignment>>(
      streamKey: (_repository, widget.activity.id),
      stream: () => _repository.watchAssignedWorkers(widget.activity.id),
      builder: (context, snapshot) {
        final assignments = snapshot.data ?? const [];
        final isLoading =
            snapshot.connectionState == ConnectionState.waiting ||
            _isLoadingMembers;
        final streamError = snapshot.hasError
            ? 'Could not load assigned workers. Please try again.'
            : null;

        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            FeatureHeader(
              eyebrow: 'Activity',
              title: widget.activity.name,
              icon: Icons.engineering,
              color: AppColors.projects,
              chips: [
                FeatureChip(
                  icon: Icons.business,
                  label: widget.organization.name,
                ),
                FeatureChip(icon: Icons.place, label: widget.site.name),
                FeatureChip(
                  icon: Icons.groups,
                  label:
                      '${assignments.length} '
                      '${assignments.length == 1 ? 'worker' : 'workers'} '
                      'assigned',
                ),
              ],
              footer: Tooltip(
                message: 'Assign worker',
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: AppColors.projects,
                  ),
                  onPressed: _isBusy || isLoading
                      ? null
                      : () => _openAssignPicker(
                          assignments.map((a) => a.uid).toList(),
                        ),
                  icon: const Icon(Icons.person_add_alt_1),
                  label: const Text('Assign Worker'),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            FeatureSectionTitle(
              title: 'Assigned Workers',
              icon: Icons.groups,
              color: AppColors.people,
              count: assignments.length,
            ),
            if ((_errorMessage ?? streamError) != null) ...[
              const SizedBox(height: AppSpacing.md),
              AuthErrorBanner(message: _errorMessage ?? streamError!),
            ],
            const SizedBox(height: AppSpacing.md),
            if (isLoading && assignments.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (!isLoading && assignments.isEmpty && streamError == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                child: EmptyState(
                  icon: Icons.group_add_outlined,
                  title: 'No workers assigned yet.',
                  message: 'Use "Assign Worker" above to add your crew.',
                ),
              ),
            for (final assignment in assignments) ...[
              _AssignmentCard(
                worker: _memberFor(assignment.uid),
                fallbackUid: assignment.uid,
                isBusy: _isBusy,
                onRemove: () => _removeWorker(assignment.uid),
                onOpenDetail: () {
                  final member = _memberFor(assignment.uid);
                  if (member != null) _openWorkerDetail(member);
                },
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
          ],
        );
      },
    );
  }
}

class _AssignmentCard extends StatelessWidget {
  const _AssignmentCard({
    required this.worker,
    required this.fallbackUid,
    required this.isBusy,
    required this.onRemove,
    required this.onOpenDetail,
  });

  /// The resolved organization member for this assignment's uid, or null if
  /// the member list hasn't loaded yet or no longer contains them (e.g. a
  /// suspended account) — [fallbackUid] keeps the row usable either way.
  final OrganizationUser? worker;
  final String fallbackUid;
  final bool isBusy;
  final VoidCallback onRemove;
  final VoidCallback onOpenDetail;

  @override
  Widget build(BuildContext context) {
    final resolved = worker;
    final name = resolved?.name ?? 'Worker';
    final role = resolved?.role;
    final active = resolved?.accountStatus == AccountStatus.active;
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: AppColors.people.withValues(alpha: 0.35)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: resolved != null ? onOpenDetail : null,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              PersonAvatar(name: name, radius: 24),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: AppTextStyles.bodyLarge.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    if (resolved == null)
                      const Text(
                        'Details unavailable',
                        style: AppTextStyles.bodyMedium,
                      )
                    else
                      Wrap(
                        spacing: AppSpacing.xs,
                        runSpacing: AppSpacing.xs,
                        children: [
                          if (role != null)
                            StatusBadge(
                              label: role.label,
                              color: DashboardHeader.roleColor(role),
                            ),
                          if (resolved.workerType != null)
                            StatusBadge(
                              label: resolved.workerType!.label,
                              color: AppColors.meetings,
                            ),
                          if (resolved.trade != null)
                            StatusBadge(
                              label: resolved.trade!,
                              color: AppColors.learning,
                            ),
                          StatusBadge(
                            label: resolved.accountStatus.label,
                            color: active
                                ? AppColors.success
                                : AppColors.textSecondary,
                          ),
                        ],
                      ),
                  ],
                ),
              ),
              IconButton.filledTonal(
                tooltip: 'Remove',
                style: IconButton.styleFrom(
                  backgroundColor: AppColors.danger.withValues(alpha: 0.12),
                ),
                onPressed: isBusy ? null : onRemove,
                icon: const Icon(Icons.person_remove, color: AppColors.danger),
              ),
            ],
          ),
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
                  'No eligible workers. A worker must already have access '
                  'to this activity\'s site before they can be assigned.',
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
                    final details = [
                      if (candidate.role != null) candidate.role!.label,
                      if (candidate.workerType != null)
                        candidate.workerType!.label,
                    ];
                    return ListTile(
                      leading: PersonAvatar(name: candidate.name),
                      title: Text(candidate.name),
                      subtitle: Text(
                        details.isEmpty ? candidate.email : details.join(' · '),
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
