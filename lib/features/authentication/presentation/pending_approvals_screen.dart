import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/widgets/choice_list.dart';
import '../../../core/widgets/dashboard_header.dart';
import '../../../core/widgets/status_badge.dart';
import '../../../core/widgets/person_avatar.dart';
import '../../../core/widgets/feature_header.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../organizations/data/organization_repository.dart';
import '../../organizations/data/site_repository.dart';
import '../../organizations/domain/organization.dart';
import '../../organizations/domain/organization_record_status.dart';
import '../../organizations/domain/site.dart';
import '../../organizations/presentation/site_select_list.dart';
import '../data/account_approval_service.dart';
import '../domain/app_role.dart';
import '../domain/membership.dart';
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
    this.siteRepositoryFor,
  });

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real service, which resolves FirebaseFunctions lazily.
  final AccountApprovalService? service;

  /// Injected in tests. Backs [_RoleAssignmentDialog]'s organization
  /// dropdown for a System Administrator reviewer. Production builds pass
  /// nothing and the state constructs the real repository.
  final OrganizationRepository? organizationRepository;

  /// Injected in tests. Backs [_RoleAssignmentDialog]'s site picker, shown
  /// when the role being granted is [AppRole.foreman] — see that dialog's
  /// doc comment. Production builds pass nothing and the state constructs
  /// the real, organization-scoped repository per call.
  final SiteRepository Function(String organizationId)? siteRepositoryFor;

  @override
  State<PendingApprovalsScreen> createState() => _PendingApprovalsScreenState();
}

class _PendingApprovalsScreenState extends State<PendingApprovalsScreen> {
  late final AccountApprovalService _service =
      widget.service ?? AccountApprovalService();
  late final OrganizationRepository _organizationRepository =
      widget.organizationRepository ??
      OrganizationRepository(firestoreService: FirestoreService());
  late final SiteRepository Function(String organizationId) _siteRepositoryFor =
      widget.siteRepositoryFor ??
      (organizationId) => SiteRepository(
        firestoreService: FirestoreService(),
        organizationId: organizationId,
      );

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

    // Every organization this reviewer holds an ACTIVE membership with
    // review authority in — the choices offered by the org picker below for
    // a non-Admin reviewer. A Site Manager/Foreman managing several
    // organizations must not have to remember which one happens to be
    // "active" in the switcher just to approve into a DIFFERENT one; the
    // dialog lets them pick explicitly every time instead. The server
    // independently re-verifies whichever one is chosen (requireApprover /
    // requireGrantWithinScope) — this list is a UI convenience only.
    final reviewerMemberships = reviewerRole == AppRole.admin
        ? const <Membership>[]
        : sessionController.memberships
              .where(
                (m) =>
                    m.status == MembershipStatus.active &&
                    m.role.canReviewPendingAccounts,
              )
              .toList(growable: false);

    if (reviewerRole != AppRole.admin && reviewerMemberships.isEmpty) {
      if (!mounted) return;
      setState(
        () => _errorMessage =
            'JV ALMA CIS has not been set up yet, so you cannot approve '
            'accounts. Set it up from Operations first.',
      );
      return;
    }

    final selection = await showDialog<_RoleAssignmentSelection>(
      context: context,
      builder: (_) => _RoleAssignmentDialog(
        account: account,
        reviewerRole: reviewerRole,
        reviewerMemberships: reviewerMemberships,
        initialOrganizationId: sessionController.activeOrganizationId,
        organizationRepository: _organizationRepository,
        siteRepositoryFor: _siteRepositoryFor,
      ),
    );
    if (selection == null || !mounted) return;

    await _decide(
      account,
      action: () => _service.approve(
        account.uid,
        role: selection.role,
        workerType: selection.workerType,
        organizationId: selection.organizationId,
        siteIds: selection.siteIds,
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
      setState(
        () => _accounts = _accounts
            .where((candidate) => candidate.uid != account.uid)
            .toList(growable: false),
      );
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
    // A non-Admin's review authority now lives on their active Membership,
    // not on the (now admin-only) profile.platformRole — except for the
    // one transient case of a Site Manager just approved with no
    // organization yet, signalled instead by profile.platformRole ==
    // siteManager (see account_approval.ts's approveAccount). Without this
    // fallback, that Site Manager is let in by the router (which already
    // accounts for it) only to hit this screen's own "you do not have
    // permission" message immediately afterward.
    final canReview =
        profile?.isPlatformAdministrator == true ||
        (sessionController.activeMembership?.role.canReviewPendingAccounts ??
            false) ||
        profile?.platformRole == AppRole.siteManager;

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

    return RefreshIndicator(onRefresh: _load, child: _buildBody());
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
        FeatureHeader(
          title: 'Pending Approvals',
          subtitle:
              'Approving a request assigns the role and worker type you '
              'choose, and activates the account.',
          icon: Icons.how_to_reg,
          color: AppColors.people,
          chips: [
            FeatureChip(
              icon: Icons.hourglass_top,
              label: '${_accounts.length} waiting for review',
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
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: AppColors.people.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                PersonAvatar(name: account.name),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    account.name.isEmpty ? 'Unnamed account' : account.name,
                    style: AppTextStyles.titleLarge,
                  ),
                ),
                const StatusBadge(label: 'Pending', color: AppColors.warning),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
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
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.go,
                      foregroundColor: Colors.white,
                    ),
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
                      side: const BorderSide(color: AppColors.danger),
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

/// The role, worker type, (for a System Administrator only) organization and
/// (for a [AppRole.foreman] grant) site(s) a reviewer chose to assign,
/// returned by [_RoleAssignmentDialog].
class _RoleAssignmentSelection {
  const _RoleAssignmentSelection({
    required this.role,
    this.workerType,
    this.organizationId,
    this.siteIds = const [],
  });

  final AppRole role;
  final WorkerType? workerType;
  final String? organizationId;

  /// The site(s) to assign alongside this grant — populated only when
  /// [role] is [AppRole.foreman] (see [_RoleAssignmentDialog]'s site
  /// picker); empty otherwise. A brand-new Foreman needs at least one site
  /// assigned to run Daily Safety Meetings at all, so this lets a Site
  /// Manager set it in the same step as approval rather than a separate,
  /// easy-to-forget visit to Organizations → Project → Site → Workers.
  final List<String> siteIds;
}

/// Prompts the reviewer to choose an organization (for a non-Admin holding
/// more than one authorized membership), a role (required) and worker type
/// (optional) before approving.
///
/// Only offers roles the reviewer's own role is authorized to grant — this
/// mirrors `grantableRoles` in `functions/src/approval_callable.ts`, so the
/// dialog cannot offer a choice the server would refuse. That mirroring is
/// UX only: the callable independently re-validates the choice server-side
/// regardless of what this dialog allowed to be selected.
///
/// ORGANIZATION PICKER — two shapes depending on reviewer role:
///
///  - An Admin sees an OPTIONAL picker over EVERY organization, backed by
///    [OrganizationRepository.watchAll] and displayed by name/code. Leaving
///    it unset is the common case: an Admin in the office approving a Site
///    Manager they know personally typically has no way to know which of
///    possibly several organizations that colleague operates in — that Site
///    Manager creates (or is assigned into) their own organization
///    afterward via `createOrganization` (PROJECT_CONTEXT.md §12/§16/§18).
///  - A Site Manager or Foreman — who may hold several authorized
///    memberships and, managing many sites/organizations, cannot be
///    expected to remember or double-check which one is currently "active"
///    in the switcher before approving — sees a REQUIRED picker scoped to
///    [reviewerMemberships]: only the organizations they hold an active,
///    review-authorized membership in, resolved to names via
///    [OrganizationRepository.watchByIds]. With exactly one membership the
///    picker still renders (so the reviewer can see, not just assume, which
///    organization they're approving into), pre-selected and effectively
///    fixed. The value sent to `approvePendingAccount` is always the
///    selected [Organization.id], never a name the reviewer typed — the
///    server independently re-verifies it is one of their own authorized
///    memberships regardless (`requireApprover`/`requireGrantWithinScope`).
///
/// SITE PICKER — shown once the selected role is [AppRole.foreman] or
/// [AppRole.worker], as checkboxes. Without at least one assigned site, a
/// Foreman cannot run Daily Safety Meetings at all (`DailySafetyMeetingScreen`
/// requires a non-empty `membership.siteIds`), and a Worker cannot be
/// assigned to any activity (`assignWorkerToActivity` requires the worker's
/// own `siteIds` to already contain the activity's site) — so this lets the
/// reviewer set it in the same step as approval rather than a separate,
/// easy-to-forget visit to Workforce afterward. Optional, not required: a
/// reviewer who does not yet know which site to assign can still approve
/// and assign the site later via that same screen.
///
/// Listed sites differ by WHO is reviewing, matching PROJECT_CONTEXT.md
/// §16's "a Site Manager places a Foreman; a Foreman places the Workers they
/// deal with daily": a Site Manager or Admin approving a Foreman sees every
/// site in the selected organization ([SiteRepository.watchAll]); a Foreman
/// approving a Worker sees ONLY their own site(s) — see
/// [_reviewerOwnSiteIds] — never the whole organization's, since a Foreman
/// has no standing to place a Worker somewhere they do not themselves work.
class _RoleAssignmentDialog extends StatefulWidget {
  const _RoleAssignmentDialog({
    required this.account,
    required this.reviewerRole,
    required this.reviewerMemberships,
    required this.initialOrganizationId,
    required this.organizationRepository,
    required this.siteRepositoryFor,
  });

  final PendingAccount account;
  final AppRole reviewerRole;

  /// The reviewer's own active, review-authorized memberships — the choices
  /// offered by the non-Admin organization picker. Empty (and unused) for
  /// an Admin reviewer, who instead sees every organization via
  /// [OrganizationRepository.watchAll].
  final List<Membership> reviewerMemberships;

  /// [SessionController.activeOrganizationId] at the moment the dialog was
  /// opened, used only to pre-select a default in the non-Admin picker —
  /// the reviewer may still change it to any of [reviewerMemberships].
  final String? initialOrganizationId;

  /// Backs the organization dropdown for both reviewer shapes: every
  /// organization for an Admin ([OrganizationRepository.watchAll]), or just
  /// [reviewerMemberships]'s organizations for anyone else
  /// ([OrganizationRepository.watchByIds]).
  final OrganizationRepository organizationRepository;

  /// Backs the site picker shown when the role being granted is
  /// [AppRole.foreman] — see this dialog's class doc comment. Constructs an
  /// [OrganizationRepository]-scoped [SiteRepository] for whichever
  /// organization is currently selected.
  final SiteRepository Function(String organizationId) siteRepositoryFor;

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
  /// null/unset state even once [_organizations] finishes loading. Unused
  /// for a non-Admin reviewer — see [_selectedMembershipOrganizationId].
  Organization? _selectedOrganization;

  /// The organization id a non-Admin reviewer has picked from
  /// [_membershipOrganizations] — defaults to [_RoleAssignmentDialog.
  /// initialOrganizationId] when that is one of [_RoleAssignmentDialog.
  /// reviewerMemberships], falling back to the first membership otherwise
  /// (e.g. the active organization is not one this reviewer can approve
  /// into, or there was no active organization at all).
  String? _selectedMembershipOrganizationId;

  List<Organization> _organizations = const [];
  Map<String, Organization> _membershipOrganizations = const {};
  bool _isLoadingOrganizations = true;
  String? _organizationsError;
  final _formKey = GlobalKey<FormState>();

  /// The site(s) picked in the [AppRole.foreman] site picker. Cleared
  /// whenever the picked organization changes, since a site belongs to
  /// exactly one organization and a stale selection from a previously
  /// selected organization must never be sent alongside a different one.
  final Set<String> _selectedSiteIds = {};
  List<Site> _sites = const [];
  bool _isLoadingSites = false;
  String? _sitesError;

  /// The organization id the site picker is (or would be) scoped to —
  /// whichever organization is currently selected, regardless of reviewer
  /// shape. Null when nothing is selected yet (Admin's optional picker,
  /// left unset).
  String? get _effectiveOrganizationId => _isAdminReviewer
      ? _selectedOrganization?.id
      : _selectedMembershipOrganizationId;

  /// [AppRole.foreman] and [AppRole.worker] both need a site assignment at
  /// approval time — see this dialog's class doc comment. Without at least
  /// one assigned site, a Worker cannot be assigned to any activity either
  /// (`assignWorkerToActivity` requires the worker's own membership
  /// `siteIds` to already contain the activity's site — see
  /// `site_assignment_callable.ts`), so this closes the same gap for a
  /// Worker that the Foreman site picker already closed for a Foreman.
  bool get _needsSiteField =>
      _role == AppRole.foreman || _role == AppRole.worker;

  /// A Foreman reviewer approving a Worker only ever manages their OWN
  /// site(s) (PROJECT_CONTEXT.md §16: "a foreman places workers since he
  /// deals with them daily") — unlike a Site Manager placing a Foreman
  /// anywhere in the organization, a Foreman must not be offered every site
  /// in the organization to place a Worker at, only the site(s) their own
  /// membership already carries. Unused (returns null) for every other
  /// reviewer shape, which sees every site in the selected organization.
  List<String>? get _reviewerOwnSiteIds =>
      widget.reviewerRole == AppRole.foreman
      ? widget.reviewerMemberships
            .firstWhere(
              (m) => m.organizationId == _effectiveOrganizationId,
              orElse: () => const Membership(
                organizationId: '',
                role: AppRole.foreman,
                status: MembershipStatus.active,
              ),
            )
            .siteIds
      : null;

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

  bool get _isAdminReviewer => widget.reviewerRole == AppRole.admin;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialOrganizationId;
    if (initial != null &&
        widget.reviewerMemberships.any((m) => m.organizationId == initial)) {
      _selectedMembershipOrganizationId = initial;
    } else if (widget.reviewerMemberships.isNotEmpty) {
      _selectedMembershipOrganizationId =
          widget.reviewerMemberships.first.organizationId;
    }
    _loadOrganizations();
    // _grantableRoles' first entry — the field initializer default for
    // _role — may already be AppRole.foreman (true for every siteManager
    // reviewer, since foreman is their ONLY grantable role): the site
    // picker must load immediately rather than waiting for a role change
    // that will never come.
    if (_needsSiteField) _loadSites();
  }

  Future<void> _loadOrganizations() async {
    setState(() => _isLoadingOrganizations = true);
    try {
      // A one-shot read of the current list is enough for a selection
      // dialog — no need to keep it live-streaming for the dialog's short
      // lifetime.
      if (_isAdminReviewer) {
        final organizations = await widget.organizationRepository
            .watchAll()
            .first;
        if (!mounted) return;
        // Defaults to unset (no organization) even when organizations
        // exist — an Admin approving a Site Manager usually doesn't know
        // which organization to pick, so the safer default is "let them
        // create their own" rather than silently pre-selecting the first
        // one in the list.
        setState(() => _organizations = organizations);
      } else {
        final organizationIds = widget.reviewerMemberships
            .map((m) => m.organizationId)
            .toList(growable: false);
        final organizations = await widget.organizationRepository
            .watchByIds(organizationIds)
            .first;
        if (!mounted) return;
        setState(
          () => _membershipOrganizations = {
            for (final organization in organizations)
              organization.id: organization,
          },
        );
      }
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _organizationsError =
            'Could not load organizations. '
            'Please try again.',
      );
    } finally {
      if (mounted) setState(() => _isLoadingOrganizations = false);
    }
  }

  Future<void> _loadSites() async {
    final organizationId = _effectiveOrganizationId;
    if (organizationId == null) return;
    setState(() {
      _isLoadingSites = true;
      _sitesError = null;
    });
    try {
      // A Foreman reviewer only ever places a Worker at their OWN site(s)
      // — see [_reviewerOwnSiteIds]'s doc comment. Their firestore.rules
      // grant is scoped the same way (a Foreman may only read a site whose
      // id is in their own membership's siteIds), so an unconstrained
      // watchAll() is refused outright for them — not merely over-broad —
      // and must query by id instead (SiteRepository.watchByIds). Every
      // other reviewer shape (Admin, Site Manager) has a broader grant and
      // still sees every site in the organization via watchAll().
      final ownSiteIds = _reviewerOwnSiteIds;
      final sites = ownSiteIds == null
          ? await widget.siteRepositoryFor(organizationId).watchAll().first
          : await widget
                .siteRepositoryFor(organizationId)
                .watchByIds(ownSiteIds)
                .first;
      if (!mounted) return;
      // New people are only placed on open sites.
      setState(
        () => _sites = [
          for (final site in sites)
            if (site.status == OrganizationRecordStatus.active) site,
        ],
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _sitesError = 'Could not load sites. Please try again.');
    } finally {
      if (mounted) setState(() => _isLoadingSites = false);
    }
  }

  /// Called whenever the granted role changes: loads sites the first time
  /// it becomes [AppRole.foreman] or [AppRole.worker] with an organization
  /// already selected, and clears any previously picked site(s) when it
  /// stops needing one (a picked site is meaningless for any other role).
  void _onRoleChanged(AppRole role) {
    final needsSites = role == AppRole.foreman || role == AppRole.worker;
    setState(() {
      _role = role;
      if (!needsSites) _selectedSiteIds.clear();
    });
    if (needsSites && _sites.isEmpty && !_isLoadingSites) {
      _loadSites();
    }
  }

  /// Called whenever the picked organization changes: a previously loaded
  /// site list and any selected site(s) belong to the OLD organization, so
  /// both are invalidated and reloaded if still needed.
  void _onOrganizationChanged() {
    setState(() {
      _sites = const [];
      _selectedSiteIds.clear();
    });
    if (_needsSiteField) _loadSites();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Approve ${widget.account.name}'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _isAdminReviewer
                    ? 'Choose the role and worker type to assign. If you '
                          'know which organization this person belongs to, '
                          'you may pick it — otherwise leave it unset and '
                          'they will create or be assigned to one after '
                          'being approved.'
                    : 'Choose the role and worker type to assign. This '
                          'activates the account.',
                style: AppTextStyles.bodyMedium,
              ),
              const SizedBox(height: AppSpacing.md),
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
              else if (_isAdminReviewer)
                ChoiceList<Organization>(
                  // Optional: left unselected, they create their own.
                  label: 'Organization (optional)',
                  items: [
                    for (final organization in _organizations)
                      ChoiceItem(
                        value: organization,
                        title: organization.name,
                        badge: organization.code,
                        subtitle: organization.code,
                      ),
                  ],
                  selected: _selectedOrganization,
                  onChanged: (value) {
                    setState(() => _selectedOrganization = value);
                    _onOrganizationChanged();
                  },
                )
              // PHASE 1 (single-company model): a non-Admin reviewer holds
              // at most one membership in practice (there is only ever one
              // company, JV ALMA CIS), so the choice below is resolved
              // silently — via _selectedMembershipOrganizationId, already
              // defaulted to the reviewer's one membership in initState —
              // rather than shown as a picker with a single, pointless
              // option. The dropdown only reappears if a reviewer somehow
              // holds more than one membership (kept, not deleted: the
              // underlying membership model still supports it — see
              // SessionController.membershipFor's doc comment).
              else if (widget.reviewerMemberships.length > 1)
                ChoiceList<String>(
                  label: 'Organization',
                  items: [
                    for (final membership in widget.reviewerMemberships)
                      ChoiceItem(
                        value: membership.organizationId,
                        title:
                            _membershipOrganizations[membership.organizationId]
                                ?.name ??
                            membership.organizationId,
                        icon: Icons.business,
                      ),
                  ],
                  selected: _selectedMembershipOrganizationId,
                  onChanged: (value) {
                    setState(() => _selectedMembershipOrganizationId = value);
                    _onOrganizationChanged();
                  },
                  validator: (value) =>
                      value == null ? 'Choose an organization.' : null,
                ),
              const SizedBox(height: AppSpacing.sm),
              ChoiceList<AppRole>(
                label: 'Role',
                items: [
                  for (final role in _grantableRoles)
                    ChoiceItem(
                      value: role,
                      title: role.label,
                      icon: _roleIcon(role),
                      color: DashboardHeader.roleColor(role),
                    ),
                ],
                selected: _role,
                // A role is always required; tapping another switches it.
                allowDeselect: false,
                onChanged: (value) {
                  if (value != null) _onRoleChanged(value);
                },
              ),
              if (_needsSiteField) ...[
                const SizedBox(height: AppSpacing.sm),
                _SitePicker(
                  isLoading: _isLoadingSites,
                  error: _sitesError,
                  sites: _sites,
                  selectedSiteIds: _selectedSiteIds,
                  isForemanReviewer: widget.reviewerRole == AppRole.foreman,
                  onToggle: (siteId, selected) => setState(() {
                    if (selected) {
                      _selectedSiteIds.add(siteId);
                    } else {
                      _selectedSiteIds.remove(siteId);
                    }
                  }),
                ),
              ],
              const SizedBox(height: AppSpacing.sm),
              ChoiceList<WorkerType>(
                label: 'Worker type (optional)',
                items: [
                  for (final type in WorkerType.values)
                    ChoiceItem(
                      value: type,
                      title: type.label,
                      icon: switch (type) {
                        WorkerType.jvaEmployee => Icons.badge,
                        WorkerType.contractor => Icons.handshake,
                        WorkerType.subcontractor => Icons.group_work,
                        WorkerType.other => Icons.person_outline,
                      },
                    ),
                ],
                selected: _workerType,
                onChanged: (value) => setState(() => _workerType = value),
              ),
            ],
          ),
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
                organizationId: _isAdminReviewer
                    ? _selectedOrganization?.id
                    : _selectedMembershipOrganizationId,
                siteIds: _needsSiteField
                    ? _selectedSiteIds.toList(growable: false)
                    : const [],
              ),
            );
          },
          child: const Text('Approve'),
        ),
      ],
    );
  }
}

/// A checkbox list of an organization's sites, letting the reviewer pick
/// zero or more to assign the Foreman being approved to.
///
/// Optional by design: leaving every box unchecked is valid (a Site Manager
/// who does not yet know the right site can still approve, and assign a
/// site later via Organizations → Project → Site → Workers) — the dialog's
/// submit action never blocks on this field, unlike the required
/// organization picker.
class _SitePicker extends StatelessWidget {
  const _SitePicker({
    required this.isLoading,
    required this.error,
    required this.sites,
    required this.selectedSiteIds,
    required this.onToggle,
    this.isForemanReviewer = false,
  });

  final bool isLoading;
  final String? error;
  final List<Site> sites;
  final Set<String> selectedSiteIds;
  final void Function(String siteId, bool selected) onToggle;

  /// True when this picker is scoped to a Foreman reviewer's OWN site(s)
  /// (see [_RoleAssignmentDialogState._reviewerOwnSiteIds]) rather than
  /// every site in the organization. An empty list here almost always means
  /// the Foreman themself has not been assigned a site yet — not that the
  /// organization has no sites — so the empty-state message below is
  /// worded accordingly instead of the misleading "No sites exist yet."
  final bool isForemanReviewer;

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (error != null) {
      return AuthErrorBanner(message: error!);
    }
    if (sites.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Text(
          isForemanReviewer
              ? "You have not been assigned to a site yet, so there is "
                    "nothing to place this worker at. Ask your Site "
                    "Manager to assign you a site first, then approve "
                    "this account."
              : 'No sites exist yet. You can assign one later from '
                    'Operations.',
          style: AppTextStyles.bodyMedium,
        ),
      );
    }
    return MultiChoiceList<String>(
      label: 'Site(s) — optional',
      items: [for (final site in sites) siteChoice(site)],
      selected: selectedSiteIds.toSet(),
      searchHint: 'Search sites by name, code or location',
      onChanged: (next) {
        for (final site in sites) {
          final wasOn = selectedSiteIds.contains(site.id);
          final isOn = next.contains(site.id);
          if (wasOn != isOn) onToggle(site.id, isOn);
        }
      },
    );
  }
}

IconData _roleIcon(AppRole role) => switch (role) {
  AppRole.admin => Icons.admin_panel_settings,
  AppRole.siteManager => Icons.apartment,
  AppRole.foreman => Icons.engineering,
  AppRole.worker => Icons.construction,
};
