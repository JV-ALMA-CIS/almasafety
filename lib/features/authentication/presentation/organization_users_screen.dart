import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../data/account_approval_service.dart';
import '../domain/account_status.dart';
import '../domain/membership.dart';
import '../domain/organization_user.dart';
import 'auth_error_banner.dart';
import '../../../core/widgets/feature_header.dart';
import '../../../core/widgets/status_badge.dart';
import '../../../core/widgets/dashboard_header.dart';
import '../../../core/widgets/person_avatar.dart';

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

  @override
  State<OrganizationUsersScreen> createState() =>
      _OrganizationUsersScreenState();
}

class _OrganizationUsersScreenState extends State<OrganizationUsersScreen> {
  late final AccountApprovalService _service =
      widget.service ?? AccountApprovalService();

  List<OrganizationUser> _users = const [];
  bool _isLoading = true;
  String? _errorMessage;

  /// Uids with a suspend/reinstate (account- or membership-level) call in
  /// flight. Tracked per-row so acting on one user does not lock the rest
  /// of the list, and so a row cannot be double-submitted by an impatient
  /// second tap.
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
    action: () =>
        _service.reinstateMembership(user.uid, organizationId: organizationId),
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
              .where(
                (candidate) =>
                    !(candidate.uid == user.uid &&
                        candidate.organizationId == user.organizationId),
              )
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

  @override
  Widget build(BuildContext context) {
    final sessionController = context.watch<SessionController>();
    final profile = sessionController.profile;
    final canReview =
        profile?.isPlatformAdministrator == true ||
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

    return RefreshIndicator(onRefresh: _load, child: _buildBody());
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
        FeatureHeader(
          title: widget.title,
          icon: Icons.groups,
          color: AppColors.people,
          chips: [
            FeatureChip(
              icon: Icons.person,
              label:
                  '${_users.length} ${_users.length == 1 ? 'user' : 'users'}',
            ),
          ],
          trailing: IconButton(
            tooltip: 'Refresh',
            color: Colors.white,
            onPressed: _isLoading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
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
/// "Suspend assignment" / "Reinstate assignment" action is offered whenever
/// this row's own [OrganizationUser.membershipStatus] allows it — DISTINCT
/// from the account-level actions: an active account with an active
/// membership can show both at once. "Assignment" here means this person's
/// placement/access under JV ALMA CIS (internally still a `Membership`
/// document, PHASE 1's single-company model), not the account itself.
class _OrganizationUserCard extends StatelessWidget {
  const _OrganizationUserCard({
    required this.user,
    required this.isBusy,
    required this.onSuspend,
    required this.onReinstate,
    required this.onSuspendMembership,
    required this.onReinstateMembership,
  });

  final OrganizationUser user;
  final bool isBusy;
  final VoidCallback? onSuspend;
  final VoidCallback? onReinstate;
  final VoidCallback? onSuspendMembership;
  final VoidCallback? onReinstateMembership;

  @override
  Widget build(BuildContext context) {
    final hasAnyAction =
        onSuspend != null ||
        onReinstate != null ||
        onSuspendMembership != null ||
        onReinstateMembership != null;

    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color:
              (user.role != null
                      ? DashboardHeader.roleColor(user.role!)
                      : AppColors.people)
                  .withValues(alpha: 0.5),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // On a narrow card the status chips move under the name
            // instead of squeezing it off the edge.
            LayoutBuilder(
              builder: (context, constraints) {
                final chips = [
                  _StatusChip(status: user.accountStatus),
                  if (user.membershipStatus != null)
                    _MembershipStatusChip(status: user.membershipStatus!),
                ];
                final name = Text(
                  user.name.isEmpty ? 'Unnamed account' : user.name,
                  style: AppTextStyles.titleLarge,
                );
                if (constraints.maxWidth >= 480) {
                  return Row(
                    children: [
                      PersonAvatar(name: user.name),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(child: name),
                      chips.first,
                      if (chips.length > 1) ...[
                        const SizedBox(width: AppSpacing.xs),
                        chips.last,
                      ],
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    PersonAvatar(name: user.name),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          name,
                          const SizedBox(height: AppSpacing.xs),
                          Wrap(
                            spacing: AppSpacing.xs,
                            runSpacing: AppSpacing.xs,
                            children: chips,
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: AppSpacing.xs),
            _DetailRow(icon: Icons.mail_outline, value: user.email),
            if (user.phone != null)
              _DetailRow(icon: Icons.phone_outlined, value: user.phone!),
            if (user.role != null)
              _DetailRow(
                icon: Icons.badge_outlined,
                value: user
                    .role!
                    .label, // OrganizationUser.role: display DTO field, not the Firestore `platformRole` field.
              ),
            if (user.workerType != null)
              _DetailRow(
                icon: Icons.engineering_outlined,
                value: user.workerType!.label,
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
                    label: 'Suspend assignment',
                    outlined: true,
                    color: AppColors.warning,
                  ),
                if (onReinstateMembership != null)
                  _ActionButton(
                    onPressed: isBusy ? null : onReinstateMembership,
                    isBusy: isBusy,
                    icon: Icons.how_to_reg_outlined,
                    label: 'Reinstate assignment',
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
    return StatusBadge(label: status.label, color: color);
  }
}

/// Shows this row's own [MembershipStatus] (internally still per-org, but
/// there is only ever one org under the single-company model) — distinct
/// from (and visually never confused with) [_StatusChip]'s account-level
/// [AccountStatus]: labelled "Assignment:" so a reviewer cannot mistake
/// "this person's work assignment" for "this person's whole account".
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
      MembershipStatus.active => 'Assignment: Active',
      MembershipStatus.suspended => 'Assignment: Suspended',
    };
    return StatusBadge(label: label, color: color);
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
          Icon(icon, size: 16, color: AppColors.primaryBright),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(value, style: AppTextStyles.bodyMedium)),
        ],
      ),
    );
  }
}
