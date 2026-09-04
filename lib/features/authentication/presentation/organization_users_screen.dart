import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../data/account_approval_service.dart';
import '../domain/account_status.dart';
import '../domain/organization_user.dart';
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

  /// Uids with a suspend/reinstate call in flight. Tracked per-row so acting
  /// on one user does not lock the rest of the list, and so a row cannot be
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
      final results = await Future.wait(
        widget.statuses.map((status) => _service.listUsers(status: status)),
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

  Future<void> _decide(
    OrganizationUser user, {
    required Future<void> Function() action,
    required String successMessage,
  }) async {
    if (_busyUids.contains(user.uid)) return;
    setState(() {
      _busyUids.add(user.uid);
      _errorMessage = null;
    });

    try {
      await action();
      if (!mounted) return;
      // Drop the row locally rather than refetching: the decision succeeded,
      // and the user no longer matches this list's status by definition.
      setState(() => _users = _users
          .where((candidate) => candidate.uid != user.uid)
          .toList(growable: false));
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
    final canReview = context
            .watch<SessionController>()
            .profile
            ?.canReviewPendingAccounts ??
        false;

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
          ),
          const SizedBox(height: AppSpacing.md),
        ],
      ],
    );
  }
}

/// One user row. Shows a Suspend action for an active user, a Reinstate
/// action for a suspended one, and no action for a rejected one — rejection
/// is terminal (see PROJECT_CONTEXT.md and `denyAccount` in
/// `functions/src/account_approval.ts`).
class _OrganizationUserCard extends StatelessWidget {
  const _OrganizationUserCard({
    required this.user,
    required this.isBusy,
    required this.onSuspend,
    required this.onReinstate,
  });

  final OrganizationUser user;
  final bool isBusy;
  final VoidCallback? onSuspend;
  final VoidCallback? onReinstate;

  @override
  Widget build(BuildContext context) {
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
            if (onSuspend != null || onReinstate != null) ...[
              const SizedBox(height: AppSpacing.md),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  if (onSuspend != null)
                    ConstrainedBox(
                      constraints: const BoxConstraints(
                        minHeight: AppSpacing.minTouchTarget,
                        minWidth: 140,
                      ),
                      child: OutlinedButton.icon(
                        onPressed: isBusy ? null : onSuspend,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.warning,
                        ),
                        icon: isBusy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.pause_circle_outline),
                        label: const Text('Suspend'),
                      ),
                    ),
                  if (onReinstate != null)
                    ConstrainedBox(
                      constraints: const BoxConstraints(
                        minHeight: AppSpacing.minTouchTarget,
                        minWidth: 140,
                      ),
                      child: ElevatedButton.icon(
                        onPressed: isBusy ? null : onReinstate,
                        icon: isBusy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.check_circle_outline),
                        label: const Text('Reinstate'),
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
