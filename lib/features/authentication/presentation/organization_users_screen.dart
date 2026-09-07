import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../organizations/data/organization_repository.dart';
import '../../organizations/domain/organization.dart';
import '../data/account_approval_service.dart';
import '../domain/account_status.dart';
import '../domain/app_role.dart';
import '../domain/membership.dart';
import '../domain/organization_user.dart';
import '../domain/worker_type.dart';
import 'auth_error_banner.dart';

/// Lists already-reviewed users at one or more [AccountStatus] values and
/// lets an authorized reviewer suspend an active one or reinstate a
/// suspended one.
///
/// Reachable only by a user whose role authorizes reviewing accounts
/// ([AppRole.canReviewPendingAccounts]) — the same authorization
/// [PendingApprovalsScreen] requires, since managing already-reviewed users
/// is part of the same review authority. That check is duplicated in three
/// places on purpose, each doing a different job, exactly as documented on
/// [PendingApprovalsScreen]:
///
///  - the router redirects unauthorized users away;
///  - this widget renders nothing useful without the authorization;
///  - the Cloud Functions callables (`listOrganizationUsers`,
///    `suspendActiveAccount`, `reinstateSuspendedAccount`) verify it
///    server-side, and additionally confine the reviewer to their own
///    organization (`systemAdministrator` excepted) — see
///    `functions/src/approval_callable.ts`.
///
/// Only the third is enforcement. The list is scoped to the caller's own
/// organization server-side — there is no client parameter for it, so a
/// modified client cannot widen the list to another organization.
class OrganizationUsersScreen extends StatefulWidget {
  const OrganizationUsersScreen({
    required this.statuses,
    required this.title,
    super.key,
    this.service,
    this.organizationRepository,
  });

  /// The statuses shown together in this list, e.g. `[active]` for Active
  /// Users or `[suspended, rejected]` for Suspended/Rejected Users. Each
  /// status is fetched with a separate `listOrganizationUsers` call — the
  /// server only ever lists one status at a time — and the results are
  /// merged client-side. `AccountStatus.pending` is not supported here; that
  /// queue is [PendingApprovalsScreen].
  final List<AccountStatus> statuses;

  /// Heading shown at the top of the list, e.g. "Active Users".
  final String title;

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real service, which resolves FirebaseFunctions lazily.
  final AccountApprovalService? service;

  /// Injected in tests. Backs the "Add to another organization" dialog's
  /// Admin-only organization picker (mirroring
  /// `_RoleAssignmentDialog.organizationRepository` in
  /// pending_approvals_screen.dart). Production builds pass nothing and the
  /// state constructs the real repository.
  final OrganizationRepository? organizationRepository;

  @override
  State<OrganizationUsersScreen> createState() =>
      _OrganizationUsersScreenState();
}

class _OrganizationUsersScreenState extends State<OrganizationUsersScreen> {
  late final AccountApprovalService _service =
      widget.service ?? AccountApprovalService();
  late final OrganizationRepository _organizationRepository =
      widget.organizationRepository ??
      OrganizationRepository(firestoreService: FirestoreService());

  List<OrganizationUser> _users = const [];
  bool _isLoading = true;
  String? _errorMessage;

  /// Uids with a suspend/reinstate (account- or membership-level) or
  /// add-to-organization call in flight. Tracked per-row so acting on one
  /// user does not lock the rest of the list, and so a row cannot be
  /// double-submitted by an impatient second tap.
  final Set<String> _busyUids = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      // Required (not merely accepted) for a non-Admin caller under the
      // multi-organization membership model — see
      // AccountApprovalService.listUsers's doc comment. Read once via
      // `context.read` rather than `watch`: this is a one-shot action, not
      // something that should re-run every time the active organization
      // notifies.
      final sessionController = context.read<SessionController>();
      final isPlatformAdministrator =
          sessionController.profile?.isPlatformAdministrator ?? false;
      final organizationId = isPlatformAdministrator
          ? null
          : sessionController.activeOrganizationId;
      final results = await Future.wait(
        widget.statuses.map(
          (status) => _service.listUsers(
            status: status,
            organizationId: organizationId,
          ),
        ),
      );
      if (!mounted) return;
      setState(() => _users = results.expand((users) => users).toList());
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _suspend(OrganizationUser user) => _decide(
    user,
    action: () => _service.suspend(user.uid),
    successMessage: '${user.name} was suspended.',
  );

  Future<void> _reinstate(OrganizationUser user) => _decide(
    user,
    action: () => _service.reinstate(user.uid),
    successMessage: '${user.name} was reinstated.',
  );

  /// Suspends [user]'s membership in [organizationId] only — ACCOUNT-level
  /// access and this person's other memberships are untouched. Distinct from
  /// [_suspend], which withdraws the whole account.
  Future<void> _suspendMembership(
    OrganizationUser user,
    String organizationId,
  ) => _decide(
    user,
    action: () =>
        _service.suspendMembership(user.uid, organizationId: organizationId),
    successMessage: '${user.name} was suspended in this organization.',
    removeFromList: false,
    newMembershipStatus: MembershipStatus.suspended,
  );

  Future<void> _reinstateMembership(
    OrganizationUser user,
    String organizationId,
  ) => _decide(
    user,
    action: () => _service.reinstateMembership(
      user.uid,
      organizationId: organizationId,
    ),
    successMessage: '${user.name} was reinstated in this organization.',
    removeFromList: false,
    newMembershipStatus: MembershipStatus.active,
  );

  Future<void> _decide(
    OrganizationUser user, {
    required Future<void> Function() action,
    required String successMessage,
    bool removeFromList = true,
    MembershipStatus? newMembershipStatus,
  }) async {
    if (_busyUids.contains(user.uid)) return;
    setState(() {
      _busyUids.add(user.uid);
      _errorMessage = null;
    });

    try {
      await action();
      if (!mounted) return;
      setState(() {
        if (removeFromList) {
          // Drop the row locally rather than refetching: the decision
          // succeeded, and the user no longer matches this list's status by
          // definition. Rows are per person PER ORGANIZATION under the
          // multi-org model, so match on both — an account-level decision
          // still only concerns the one row it was invoked from.
          _users = _users
              .where((candidate) => !(candidate.uid == user.uid &&
                  candidate.organizationId == user.organizationId))
              .toList(growable: false);
        } else if (newMembershipStatus != null) {
          // A membership-level decision does not remove the row from an
          // account-status-scoped list (the account itself is untouched) —
          // update just its membershipStatus in place instead.
          _users = [
            for (final candidate in _users)
              if (candidate.uid == user.uid &&
                  candidate.organizationId == user.organizationId)
                OrganizationUser(
                  uid: candidate.uid,
                  name: candidate.name,
                  email: candidate.email,
                  accountStatus: candidate.accountStatus,
                  phone: candidate.phone,
                  role: candidate.role,
                  workerType: candidate.workerType,
                  organizationId: candidate.organizationId,
                  membershipStatus: newMembershipStatus,
                  registeredAt: candidate.registeredAt,
                  siteIds: candidate.siteIds,
                )
              else
                candidate,
          ];
        }
      });
      _showMessage(successMessage);
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _busyUids.remove(user.uid));
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Opens [_AddMembershipDialog] for [user], then calls
  /// [AccountApprovalService.addOrganizationMembership] with the chosen
  /// role/workerType/siteIds if the reviewer confirms.
  Future<void> _addToAnotherOrganization(OrganizationUser user) async {
    if (_busyUids.contains(user.uid)) return;
    final sessionController = context.read<SessionController>();
    final profile = sessionController.profile;
    // Mirrors PendingApprovalsScreen._approve: a non-Admin reviewer's own
    // role lives on their active Membership, not the (now admin-only)
    // profile.platformRole.
    final reviewerRole =
        profile?.platformRole ?? sessionController.activeMembership?.role;
    if (reviewerRole == null) return;

    final selection = await showDialog<_AddMembershipSelection>(
      context: context,
      builder: (_) => _AddMembershipDialog(
        user: user,
        reviewerRole: reviewerRole,
        organizationRepository: _organizationRepository,
      ),
    );
    if (selection == null || !mounted) return;

    // Exactly like PendingApprovalsScreen._approve: only an Admin picks an
    // organization explicitly. Every other reviewer acts within their own
    // active organization, resolved automatically, never from a picker.
    final organizationId = reviewerRole == AppRole.admin
        ? selection.organizationId
        : sessionController.activeOrganizationId;
    if (organizationId == null) {
      setState(
        () => _errorMessage =
            'Choose an organization to add this person to.',
      );
      return;
    }

    setState(() {
      _busyUids.add(user.uid);
      _errorMessage = null;
    });
    try {
      await _service.addOrganizationMembership(
        user.uid,
        role: selection.role,
        workerType: selection.workerType,
        siteIds: selection.siteIds,
        organizationId: organizationId,
      );
      if (!mounted) return;
      _showMessage('${user.name} was added to that organization.');
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _busyUids.remove(user.uid));
    }
  }

  @override
  Widget build(BuildContext context) {
    final sessionController = context.watch<SessionController>();
    final profile = sessionController.profile;
    final canReview = profile?.isPlatformAdministrator == true ||
        (sessionController.activeMembership?.role.canReviewPendingAccounts ??
            false);

    if (!canReview) {
      // Defence in depth: the router should never route an unauthorized
      // user here.
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: Text(
            'You do not have permission to view this list.',
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading && _users.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    return ListView(
      // Always scrollable so pull-to-refresh works even when the list is
      // empty or an error replaced it.
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(widget.title, style: AppTextStyles.headlineMedium),
            ),
            IconButton(
              tooltip: 'Refresh',
              onPressed: _isLoading ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        if (_errorMessage != null) ...[
          const SizedBox(height: AppSpacing.md),
          AuthErrorBanner(message: _errorMessage!),
        ],
        const SizedBox(height: AppSpacing.md),
        if (_users.isEmpty && _errorMessage == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
            child: Text(
              'No users to show.',
              style: AppTextStyles.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ),
        for (final user in _users) ...[
          _OrganizationUserCard(
            user: user,
            isBusy: _busyUids.contains(user.uid),
            onSuspend: user.accountStatus == AccountStatus.active
                ? () => _suspend(user)
                : null,
            onReinstate: user.accountStatus == AccountStatus.suspended
                ? () => _reinstate(user)
                : null,
            onSuspendMembership:
                user.organizationId != null &&
                        user.membershipStatus == MembershipStatus.active
                    ? () => _suspendMembership(user, user.organizationId!)
                    : null,
            onReinstateMembership:
                user.organizationId != null &&
                        user.membershipStatus == MembershipStatus.suspended
                    ? () => _reinstateMembership(user, user.organizationId!)
                    : null,
            onAddToAnotherOrganization: () => _addToAnotherOrganization(user),
          ),
          const SizedBox(height: AppSpacing.md),
        ],
      ],
    );
  }
}

/// One user row. Shows an account-level Suspend action for an active
/// account, an account-level Reinstate for a suspended one, and no
/// account-level action for a rejected one — rejection is terminal (see
/// PROJECT_CONTEXT.md and `denyAccount` in
/// `functions/src/account_approval.ts`). Separately, a membership-level
/// "Suspend in this org" / "Reinstate in this org" action is offered
/// whenever this row's own [OrganizationUser.membershipStatus] allows it —
/// DISTINCT from the account-level actions: an active account with an
/// active membership can show both at once, and the labels are deliberately
/// prefixed ("account" vs "in this org") so the two are never confused.
class _OrganizationUserCard extends StatelessWidget {
  const _OrganizationUserCard({
    required this.user,
    required this.isBusy,
    required this.onSuspend,
    required this.onReinstate,
    required this.onSuspendMembership,
    required this.onReinstateMembership,
    required this.onAddToAnotherOrganization,
  });

  final OrganizationUser user;
  final bool isBusy;
  final VoidCallback? onSuspend;
  final VoidCallback? onReinstate;
  final VoidCallback? onSuspendMembership;
  final VoidCallback? onReinstateMembership;
  final VoidCallback onAddToAnotherOrganization;

  @override
  Widget build(BuildContext context) {
    final hasAnyAction = onSuspend != null ||
        onReinstate != null ||
        onSuspendMembership != null ||
        onReinstateMembership != null;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    user.name.isEmpty ? 'Unnamed account' : user.name,
                    style: AppTextStyles.titleLarge,
                  ),
                ),
                _StatusChip(status: user.accountStatus),
                if (user.membershipStatus != null) ...[
                  const SizedBox(width: AppSpacing.xs),
                  _MembershipStatusChip(status: user.membershipStatus!),
                ],
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            _DetailRow(icon: Icons.mail_outline, value: user.email),
            if (user.phone != null)
              _DetailRow(icon: Icons.phone_outlined, value: user.phone!),
            if (user.role != null)
              _DetailRow(
                icon: Icons.badge_outlined,
                value: user.role!.label, // OrganizationUser.role: display DTO field, not the Firestore `platformRole` field.
              ),
            if (user.workerType != null)
              _DetailRow(
                icon: Icons.engineering_outlined,
                value: user.workerType!.label,
              ),
            if (user.organizationId != null)
              _DetailRow(
                icon: Icons.apartment_outlined,
                value: user.organizationId!,
              ),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                if (onSuspend != null)
                  _ActionButton(
                    onPressed: isBusy ? null : onSuspend,
                    isBusy: isBusy,
                    icon: Icons.pause_circle_outline,
                    label: 'Suspend account',
                    outlined: true,
                    color: AppColors.warning,
                  ),
                if (onReinstate != null)
                  _ActionButton(
                    onPressed: isBusy ? null : onReinstate,
                    isBusy: isBusy,
                    icon: Icons.check_circle_outline,
                    label: 'Reinstate account',
                  ),
                if (onSuspendMembership != null)
                  _ActionButton(
                    onPressed: isBusy ? null : onSuspendMembership,
                    isBusy: isBusy,
                    icon: Icons.block_outlined,
                    label: 'Suspend in this org',
                    outlined: true,
                    color: AppColors.warning,
                  ),
                if (onReinstateMembership != null)
                  _ActionButton(
                    onPressed: isBusy ? null : onReinstateMembership,
                    isBusy: isBusy,
                    icon: Icons.how_to_reg_outlined,
                    label: 'Reinstate in this org',
                  ),
                _ActionButton(
                  onPressed: isBusy ? null : onAddToAnotherOrganization,
                  isBusy: false,
                  icon: Icons.group_add_outlined,
                  label: 'Add to another organization',
                  outlined: true,
                ),
              ],
            ),
            if (!hasAnyAction) const SizedBox.shrink(),
          ],
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.onPressed,
    required this.isBusy,
    required this.icon,
    required this.label,
    this.outlined = false,
    this.color,
  });

  final VoidCallback? onPressed;
  final bool isBusy;
  final IconData icon;
  final String label;
  final bool outlined;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final child = isBusy
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(icon);

    return ConstrainedBox(
      constraints: const BoxConstraints(
        minHeight: AppSpacing.minTouchTarget,
        minWidth: 140,
      ),
      child: outlined
          ? OutlinedButton.icon(
              onPressed: onPressed,
              style: color != null
                  ? OutlinedButton.styleFrom(foregroundColor: color)
                  : null,
              icon: child,
              label: Text(label),
            )
          : ElevatedButton.icon(
              onPressed: onPressed,
              icon: child,
              label: Text(label),
            ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final AccountStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      AccountStatus.active => AppColors.success,
      AccountStatus.suspended => AppColors.warning,
      AccountStatus.rejected => AppColors.danger,
      AccountStatus.pending => AppColors.info,
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppSpacing.sm),
      ),
      child: Text(
        status.label,
        style: AppTextStyles.label.copyWith(color: color),
      ),
    );
  }
}

/// Shows this row's own per-organization [MembershipStatus] — distinct from
/// (and visually never confused with) [_StatusChip]'s account-level
/// [AccountStatus]: labelled "Org:" so a reviewer cannot mistake "this
/// person's membership in this specific organization" for "this person's
/// whole account".
class _MembershipStatusChip extends StatelessWidget {
  const _MembershipStatusChip({required this.status});

  final MembershipStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      MembershipStatus.active => AppColors.success,
      MembershipStatus.suspended => AppColors.warning,
    };
    final label = switch (status) {
      MembershipStatus.active => 'Org: Active',
      MembershipStatus.suspended => 'Org: Suspended',
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(AppSpacing.sm),
      ),
      child: Text(
        label,
        style: AppTextStyles.label.copyWith(color: color),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.icon, required this.value});

  final IconData icon;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: AppColors.textSecondary),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(value, style: AppTextStyles.bodyMedium)),
        ],
      ),
    );
  }
}

/// The role, worker type, site ids and (for a System Administrator only)
/// organization a reviewer chose, returned by [_AddMembershipDialog].
class _AddMembershipSelection {
  const _AddMembershipSelection({
    required this.role,
    this.workerType,
    this.siteIds,
    this.organizationId,
  });

  final AppRole role;
  final WorkerType? workerType;
  final List<String>? siteIds;
  final String? organizationId;
}

/// Prompts the reviewer to place an already-active user into an ADDITIONAL
/// organization, via [AccountApprovalService.addOrganizationMembership].
///
/// Mirrors `_RoleAssignmentDialog` in pending_approvals_screen.dart closely
/// — same grantable-roles switch (duplicated here rather than shared,
/// matching that file's own precedent of keeping this logic local to its
/// dialog), same Admin-only organization picker, same
/// "non-Admin acts within their own active organization, never a picker"
/// rule (enforced by the caller, [_OrganizationUsersScreenState]
/// ._addToAnotherOrganization, exactly like `PendingApprovalsScreen._approve`
/// resolves it). Adds an optional site-ids field, entered as a simple
/// comma-separated list — this app has no existing reusable multi-select
/// site-picker widget to draw on (checked site_workers_screen.dart and
/// worker_detail_screen.dart; neither exposes one), and a comma-separated
/// text field is consistent with this screen's "optional, simple" ask
/// without inventing new picker chrome for one dialog.
class _AddMembershipDialog extends StatefulWidget {
  const _AddMembershipDialog({
    required this.user,
    required this.reviewerRole,
    required this.organizationRepository,
  });

  final OrganizationUser user;
  final AppRole reviewerRole;
  final OrganizationRepository organizationRepository;

  @override
  State<_AddMembershipDialog> createState() => _AddMembershipDialogState();
}

class _AddMembershipDialogState extends State<_AddMembershipDialog> {
  late AppRole _role = _grantableRoles.first;
  WorkerType? _workerType;
  final _siteIdsController = TextEditingController();

  Organization? _selectedOrganization;
  List<Organization> _organizations = const [];
  bool _isLoadingOrganizations = true;
  String? _organizationsError;

  /// Mirrors `_RoleAssignmentDialog._grantableRoles` exactly (see that
  /// class's doc comment for why no reviewer is ever offered a role equal to
  /// or above their own).
  List<AppRole> get _grantableRoles => switch (widget.reviewerRole) {
    AppRole.admin => const [AppRole.siteManager],
    AppRole.siteManager => const [AppRole.foreman],
    AppRole.foreman => const [AppRole.worker],
    AppRole.worker => const [],
  };

  bool get _needsOrganizationField => widget.reviewerRole == AppRole.admin;

  @override
  void initState() {
    super.initState();
    if (_needsOrganizationField) _loadOrganizations();
  }

  @override
  void dispose() {
    _siteIdsController.dispose();
    super.dispose();
  }

  Future<void> _loadOrganizations() async {
    setState(() => _isLoadingOrganizations = true);
    try {
      final organizations =
          await widget.organizationRepository.watchAll().first;
      if (!mounted) return;
      setState(() => _organizations = organizations);
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _organizationsError = 'Could not load organizations. '
            'Please try again.',
      );
    } finally {
      if (mounted) setState(() => _isLoadingOrganizations = false);
    }
  }

  List<String>? _parseSiteIds() {
    final raw = _siteIdsController.text.trim();
    if (raw.isEmpty) return null;
    final ids = raw
        .split(',')
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    return ids.isEmpty ? null : ids;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Add ${widget.user.name} to another organization'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _needsOrganizationField
                  ? 'Choose the organization, role and worker type to '
                        'assign. This does not touch any of their existing '
                        'memberships.'
                  : 'Choose the role and worker type to assign. This adds '
                        'them to your organization without touching any of '
                        'their existing memberships.',
              style: AppTextStyles.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.md),
            if (_needsOrganizationField) ...[
              if (_isLoadingOrganizations)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              else if (_organizationsError != null)
                AuthErrorBanner(message: _organizationsError!)
              else
                DropdownButtonFormField<Organization?>(
                  initialValue: _selectedOrganization,
                  decoration: const InputDecoration(
                    labelText: 'Organization',
                  ),
                  items: [
                    for (final organization in _organizations)
                      DropdownMenuItem(
                        value: organization,
                        child: Text(
                          '${organization.name} (${organization.code})',
                        ),
                      ),
                  ],
                  onChanged: (value) =>
                      setState(() => _selectedOrganization = value),
                ),
              const SizedBox(height: AppSpacing.sm),
            ],
            DropdownButtonFormField<AppRole>(
              initialValue: _role,
              decoration: const InputDecoration(labelText: 'Role'),
              items: [
                for (final role in _grantableRoles)
                  DropdownMenuItem(value: role, child: Text(role.label)),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _role = value);
              },
            ),
            const SizedBox(height: AppSpacing.sm),
            DropdownButtonFormField<WorkerType?>(
              initialValue: _workerType,
              decoration: const InputDecoration(labelText: 'Worker type'),
              items: [
                const DropdownMenuItem(value: null, child: Text('Not set')),
                for (final type in WorkerType.values)
                  DropdownMenuItem(value: type, child: Text(type.label)),
              ],
              onChanged: (value) => setState(() => _workerType = value),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _siteIdsController,
              decoration: const InputDecoration(
                labelText: 'Site ids (optional, comma-separated)',
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
        ElevatedButton(
          onPressed: (_needsOrganizationField && _selectedOrganization == null)
              ? null
              : () => Navigator.of(context).pop(
                    _AddMembershipSelection(
                      role: _role,
                      workerType: _workerType,
                      siteIds: _parseSiteIds(),
                      organizationId: _needsOrganizationField
                          ? _selectedOrganization?.id
                          : null,
                    ),
                  ),
          child: const Text('Add'),
        ),
      ],
    );
  }
}
