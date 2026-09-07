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
import '../domain/app_role.dart';
import '../domain/pending_account.dart';
import '../domain/worker_type.dart';
import 'auth_error_banner.dart';

/// The approval inbox: accounts awaiting review, with approve/reject actions.
///
/// Reachable only by a user whose role authorizes reviewing pending accounts
/// ([AppRole.canReviewPendingAccounts]). That check is duplicated in three
/// places on purpose, each doing a different job:
///
///  - the router redirects unauthorized users away (so the screen is not
///    reachable by typing a URL);
///  - this widget renders nothing useful without the authorization (so a
///    stale route cannot leak the queue);
///  - the Cloud Functions callables verify it server-side against the
///    caller's stored profile, and additionally restrict which roles the
///    caller may grant (see `functions/src/approval_callable.ts`).
///
/// Only the third is enforcement. The first two are UX — a modified client
/// that skipped both would still get `permission-denied` (or a refused role
/// grant) from every callable, and Firestore rules independently deny it any
/// direct read of another user's document.
///
/// Approving assigns the *approver's own* organization for every reviewer
/// role except [AppRole.admin], which has no organization of its own and
/// must name one explicitly. [_RoleAssignmentDialog] only shows the
/// organization field to an Admin; every other reviewer's organization is
/// fixed server-side and never accepted as a parameter. The reviewer always
/// chooses the role and worker type to assign.
class PendingApprovalsScreen extends StatefulWidget {
  const PendingApprovalsScreen({
    super.key,
    this.service,
    this.organizationRepository,
  });

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real service, which resolves FirebaseFunctions lazily.
  final AccountApprovalService? service;

  /// Injected in tests. Backs [_RoleAssignmentDialog]'s organization
  /// dropdown for a System Administrator reviewer. Production builds pass
  /// nothing and the state constructs the real repository.
  final OrganizationRepository? organizationRepository;

  @override
  State<PendingApprovalsScreen> createState() => _PendingApprovalsScreenState();
}

class _PendingApprovalsScreenState extends State<PendingApprovalsScreen> {
  late final AccountApprovalService _service =
      widget.service ?? AccountApprovalService();
  late final OrganizationRepository _organizationRepository =
      widget.organizationRepository ??
      OrganizationRepository(firestoreService: FirestoreService());

  List<PendingAccount> _accounts = const [];
  bool _isLoading = true;
  String? _errorMessage;

  /// Uids with an approve/reject call in flight. Tracked per-row so acting on
  /// one account does not lock the rest of the queue, and so a row cannot be
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
      final accounts = await _service.listPendingApprovals();
      if (!mounted) return;
      setState(() => _accounts = accounts);
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Opens the role-assignment dialog, then approves with the chosen role
  /// and worker type if the reviewer confirms. Cancelling the dialog leaves
  /// the account in the queue untouched.
  Future<void> _approve(PendingAccount account) async {
    final sessionController = context.read<SessionController>();
    final profile = sessionController.profile;
    // A non-Admin reviewer's own role now lives on their active Membership,
    // not on the profile's (now admin-only) platformRole.
    final reviewerRole =
        profile?.platformRole ?? sessionController.activeMembership?.role;
    if (reviewerRole == null) return;

    final selection = await showDialog<_RoleAssignmentSelection>(
      context: context,
      builder: (_) => _RoleAssignmentDialog(
        account: account,
        reviewerRole: reviewerRole,
        organizationRepository: _organizationRepository,
      ),
    );
    if (selection == null || !mounted) return;

    // For a non-Admin reviewer, the server now REQUIRES organizationId
    // (the acting organization) rather than resolving it implicitly — see
    // AccountApprovalService.approve's doc comment. Resolved automatically
    // from the reviewer's own active membership, never a picker: a reviewer
    // acts in one organization at a time.
    final organizationId = reviewerRole == AppRole.admin
        ? selection.organizationId
        : sessionController.activeOrganizationId;

    await _decide(
      account,
      action: () => _service.approve(
        account.uid,
        role: selection.role,
        workerType: selection.workerType,
        organizationId: organizationId,
      ),
      successMessage: '${account.name} approved as ${selection.role.label}.',
    );
  }

  Future<void> _reject(PendingAccount account) => _decide(
    account,
    action: () => _service.reject(account.uid),
    successMessage: '${account.name}’s request was rejected.',
  );

  Future<void> _decide(
    PendingAccount account, {
    required Future<void> Function() action,
    required String successMessage,
  }) async {
    if (_busyUids.contains(account.uid)) return;
    setState(() {
      _busyUids.add(account.uid);
      _errorMessage = null;
    });

    try {
      await action();
      if (!mounted) return;
      // Drop the row locally rather than refetching: the decision succeeded,
      // and the account is no longer pending by definition.
      setState(() => _accounts = _accounts
          .where((candidate) => candidate.uid != account.uid)
          .toList(growable: false));
      _showMessage(successMessage);
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _busyUids.remove(account.uid));
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
            'You do not have permission to review accounts.',
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
    if (_isLoading && _accounts.isEmpty) {
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
              child: Text(
                'Pending Approvals',
                style: AppTextStyles.headlineMedium,
              ),
            ),
            IconButton(
              tooltip: 'Refresh',
              onPressed: _isLoading ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        const Text(
          'Approving a request assigns it to your organization with the '
          'role and worker type you choose, and activates the account.',
          style: AppTextStyles.bodyMedium,
        ),
        if (_errorMessage != null) ...[
          const SizedBox(height: AppSpacing.md),
          AuthErrorBanner(message: _errorMessage!),
        ],
        const SizedBox(height: AppSpacing.md),
        if (_accounts.isEmpty && _errorMessage == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
            child: Text(
              'No accounts are waiting for review.',
              style: AppTextStyles.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ),
        for (final account in _accounts) ...[
          _PendingAccountCard(
            account: account,
            isBusy: _busyUids.contains(account.uid),
            onApprove: () => _approve(account),
            onReject: () => _reject(account),
          ),
          const SizedBox(height: AppSpacing.md),
        ],
      ],
    );
  }
}

/// One reviewable account. Lays its actions out below the details rather than
/// beside them so the 48px touch targets survive a narrow phone viewport.
class _PendingAccountCard extends StatelessWidget {
  const _PendingAccountCard({
    required this.account,
    required this.isBusy,
    required this.onApprove,
    required this.onReject,
  });

  final PendingAccount account;
  final bool isBusy;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              account.name.isEmpty ? 'Unnamed account' : account.name,
              style: AppTextStyles.titleLarge,
            ),
            const SizedBox(height: AppSpacing.xs),
            _DetailRow(icon: Icons.mail_outline, value: account.email),
            if (account.phone != null)
              _DetailRow(icon: Icons.phone_outlined, value: account.phone!),
            _DetailRow(
              icon: Icons.schedule_outlined,
              value: 'Submitted ${_formatDate(account.submittedAt)}',
            ),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: AppSpacing.minTouchTarget,
                    minWidth: 140,
                  ),
                  child: ElevatedButton.icon(
                    onPressed: isBusy ? null : onApprove,
                    icon: isBusy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check),
                    label: const Text('Approve'),
                  ),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: AppSpacing.minTouchTarget,
                    minWidth: 140,
                  ),
                  child: OutlinedButton.icon(
                    onPressed: isBusy ? null : onReject,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.danger,
                    ),
                    icon: const Icon(Icons.close),
                    label: const Text('Reject'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _formatDate(DateTime? value) {
    if (value == null) return 'recently';
    final local = value.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '${local.year}-$month-$day';
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

/// The role, worker type and (for a System Administrator only) organization
/// a reviewer chose to assign, returned by [_RoleAssignmentDialog].
class _RoleAssignmentSelection {
  const _RoleAssignmentSelection({
    required this.role,
    this.workerType,
    this.organizationId,
  });

  final AppRole role;
  final WorkerType? workerType;
  final String? organizationId;
}

/// Prompts the reviewer to choose a role (required) and worker type
/// (optional) before approving.
///
/// Only offers roles the reviewer's own role is authorized to grant — this
/// mirrors `grantableRoles` in `functions/src/approval_callable.ts`, so the
/// dialog cannot offer a choice the server would refuse. That mirroring is
/// UX only: the callable independently re-validates the choice server-side
/// regardless of what this dialog allowed to be selected.
///
/// An Admin additionally sees an OPTIONAL organization picker, backed by
/// [OrganizationRepository.watchAll] and displayed by name/code — the value
/// sent to `approvePendingAccount` is always the selected [Organization.id]
/// (its Firestore document id), never a name/code an administrator typed or
/// might confuse for one. Leaving it unset is the common case: an Admin in
/// the office approving a Site Manager they know personally typically has no
/// way to know which of possibly several organizations that colleague
/// operates in — that Site Manager creates (or is assigned into) their own
/// organization afterward via `createOrganization` (PROJECT_CONTEXT.md
/// §12/§16/§18), which then backfills `users/{uid}.organizationId`. Picking
/// an existing organization here is only for the case where the Admin
/// already knows exactly which one this Site Manager belongs to.
class _RoleAssignmentDialog extends StatefulWidget {
  const _RoleAssignmentDialog({
    required this.account,
    required this.reviewerRole,
    required this.organizationRepository,
  });

  final PendingAccount account;
  final AppRole reviewerRole;

  /// Backs the organization dropdown for a System Administrator reviewer —
  /// see [_needsOrganizationField]. Unused by any other reviewer role, whose
  /// organization is always their own, fixed server-side.
  final OrganizationRepository organizationRepository;

  @override
  State<_RoleAssignmentDialog> createState() => _RoleAssignmentDialogState();
}

class _RoleAssignmentDialogState extends State<_RoleAssignmentDialog> {
  late AppRole _role = _grantableRoles.first;
  WorkerType? _workerType;

  /// The organization an Admin has picked from [_organizations] — its
  /// Firestore document id is what actually gets sent to
  /// `approvePendingAccount`, never a name/code the reviewer might type.
  /// Null means "no organization yet" (the common case — see this dialog's
  /// class doc comment), not "still loading"; the field defaults to that
  /// null/unset state even once [_organizations] finishes loading.
  Organization? _selectedOrganization;
  List<Organization> _organizations = const [];
  bool _isLoadingOrganizations = true;
  String? _organizationsError;
  final _formKey = GlobalKey<FormState>();

  /// An Admin may grant [AppRole.siteManager] (or reinstate any role); a
  /// [AppRole.siteManager] may grant [AppRole.foreman]; a [AppRole.foreman]
  /// may grant [AppRole.worker]. Mirrors `grantableRoles` in
  /// `functions/src/approval_callable.ts` exactly — see
  /// [AppRole.canReviewPendingAccounts] and the matching server-side check.
  /// No reviewer is ever offered a role equal to or above their own — the
  /// approval hierarchy forbids self-escalation and peer/superior grants.
  List<AppRole> get _grantableRoles => switch (widget.reviewerRole) {
    AppRole.admin => const [AppRole.siteManager],
    AppRole.siteManager => const [AppRole.foreman],
    AppRole.foreman => const [AppRole.worker],
    AppRole.worker => const [],
  };

  /// Only an Admin has no organization of their own to approve into, so
  /// only they are prompted to choose one.
  bool get _needsOrganizationField => widget.reviewerRole == AppRole.admin;

  @override
  void initState() {
    super.initState();
    if (_needsOrganizationField) _loadOrganizations();
  }

  Future<void> _loadOrganizations() async {
    setState(() => _isLoadingOrganizations = true);
    try {
      // A one-shot read of the current list is enough for a selection
      // dialog — no need to keep it live-streaming for the dialog's short
      // lifetime, matching how OrganizationsScreen's own stream would
      // settle to the same snapshot on first frame.
      final organizations = await widget.organizationRepository
          .watchAll()
          .first;
      if (!mounted) return;
      // Defaults to unset (no organization) even when organizations exist —
      // an Admin approving a Site Manager usually doesn't know which
      // organization to pick, so the safer default is "let them create
      // their own" rather than silently pre-selecting the first one in the
      // list.
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

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Approve ${widget.account.name}'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _needsOrganizationField
                  ? 'Choose the role and worker type to assign. If you '
                        'know which organization this person belongs to, '
                        'you may pick it — otherwise leave it unset and '
                        'they will create or be assigned to one after '
                        'being approved.'
                  : 'Choose the role and worker type to assign. This '
                        'activates the account in your organization.',
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
                    labelText: 'Organization (optional)',
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('None yet — they will create their own'),
                    ),
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
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            if (!(_formKey.currentState?.validate() ?? true)) return;
            Navigator.of(context).pop(
              _RoleAssignmentSelection(
                role: _role,
                workerType: _workerType,
                organizationId: _needsOrganizationField
                    ? _selectedOrganization?.id
                    : null,
              ),
            );
          },
          child: const Text('Approve'),
        ),
      ],
    );
  }
}
