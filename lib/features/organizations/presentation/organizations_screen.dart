import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../routing/app_routes.dart';
import '../../authentication/domain/app_role.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../data/organization_admin_service.dart';
import '../data/organization_repository.dart';
import '../domain/organization.dart';
import '../domain/organization_record_status.dart';

/// Lists organizations and lets a System Administrator create or edit one.
///
/// Reachable by [UserProfile.isPlatformAdministrator] (every organization,
/// full create/edit — the same authorization [AdministrationScreen]
/// requires) or an [AppRole.siteManager] (their own
/// organization only, view/navigate to Projects/Sites only — Create/Edit
/// stay hidden, since `createOrganization`/`updateOrganization` have no
/// Organization Administrator authorization server-side). That check is
/// duplicated on purpose, each instance doing a different job, exactly as
/// documented on [OrganizationUsersScreen]:
///
///  - the router redirects unauthorized users away;
///  - this widget renders nothing useful without the authorization, and
///    hides actions the signed-in role cannot actually perform;
///  - `firestore.rules`' `belongsToOrganization`/`isSystemAdministrator()`
///    gate the read, and `organization_callable.ts`'s
///    `requireSystemAdministrator` gates every write, independently of this
///    screen.
///
/// Only the rules/callables are enforcement. Reads stream live from
/// [OrganizationRepository]; writes go through [OrganizationAdminService],
/// which the server re-validates regardless of what this screen sent.
class OrganizationsScreen extends StatefulWidget {
  const OrganizationsScreen({
    super.key,
    this.repository,
    this.adminService,
  });

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real dependencies.
  final OrganizationRepository? repository;
  final OrganizationAdminService? adminService;

  @override
  State<OrganizationsScreen> createState() => _OrganizationsScreenState();
}

class _OrganizationsScreenState extends State<OrganizationsScreen> {
  late final OrganizationRepository _repository = widget.repository ??
      OrganizationRepository(firestoreService: FirestoreService());
  late final OrganizationAdminService _adminService =
      widget.adminService ?? OrganizationAdminService();

  String? _errorMessage;
  bool _isSaving = false;

  Future<void> _openCreateDialog() async {
    final result = await showDialog<_OrganizationFormResult>(
      context: context,
      builder: (_) => const _OrganizationFormDialog(),
    );
    if (result == null || !mounted) return;
    await _save(() => _adminService.createOrganization(
      name: result.name,
      code: result.code,
      status: result.status,
    ));
  }

  Future<void> _openEditDialog(Organization organization) async {
    final result = await showDialog<_OrganizationFormResult>(
      context: context,
      builder: (_) => _OrganizationFormDialog(existing: organization),
    );
    if (result == null || !mounted) return;
    await _save(() => _adminService.updateOrganization(
      organization.id,
      name: result.name,
      code: result.code,
      status: result.status,
    ));
  }

  Future<void> _save(Future<void> Function() action) async {
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

  @override
  Widget build(BuildContext context) {
    final sessionController = context.watch<SessionController>();
    final profile = sessionController.profile;
    final isPlatformAdministrator = profile?.isPlatformAdministrator ?? false;
    // A Site Manager with a real membership already has one; a Site Manager
    // just approved with no organization yet (the documented "create your
    // own org afterward" path — PROJECT_CONTEXT.md §12/§16/§18) has NO
    // membership at all yet, so `activeMembership` is null. For exactly that
    // transient window, `approveAccount` writes `platformRole: siteManager`
    // directly onto the profile as the only signal available — see
    // `UserProfile`'s own doc comment and `account_approval.ts`'s
    // `approveAccount`. Without this fallback, a brand-new Site Manager can
    // never see or reach the one action (create an organization) that would
    // give them their first membership.
    final isSiteManager =
        sessionController.activeMembership?.role == AppRole.siteManager ||
            profile?.platformRole == AppRole.siteManager;
    final canManage = isPlatformAdministrator || isSiteManager;

    if (!canManage) {
      // Defence in depth: the router should never route an unauthorized
      // user here.
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: Text(
            'You do not have permission to manage organizations.',
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    // An Admin's read of `organizations/*` is an unconstrained collection
    // LIST — permitted only for Admin, via `isAdmin()`. A non-Admin
    // (Site Manager, ...) can only ever read the SPECIFIC organizations
    // their own memberships name (`belongsToOrganization`, a per-document
    // grant) — `watchAll()` is denied outright for them, not merely
    // filtered down. See [OrganizationRepository.watchAll]'s doc comment.
    // Scoping to every one of the caller's own membership organization ids
    // (not just `activeOrganizationId`) so a Site Manager who manages
    // several organizations sees all of them here, matching this screen's
    // "manage the organizations you're authorized to manage" purpose.
    final organizationIds = sessionController.memberships
        .map((m) => m.organizationId)
        .toSet()
        .toList(growable: false);
    final orgStream = isPlatformAdministrator
        ? _repository.watchAll()
        : _repository.watchByIds(organizationIds);

    return StreamBuilder<List<Organization>>(
      stream: orgStream,
      builder: (context, snapshot) {
        final organizations = snapshot.data ?? const [];
        final isLoading = snapshot.connectionState == ConnectionState.waiting;
        final streamError = snapshot.hasError
            ? 'Could not load organizations. Please try again.'
            : null;

        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Organizations', style: AppTextStyles.headlineMedium),
                ),
                // A Site Manager may also create an organization —
                // PROJECT_CONTEXT.md §12: "A Site Manager/Site
                // Superintendent must be able to create an organization
                // because they are the field operational manager" — and may
                // create more than one, so this is not limited to the
                // zero-membership case above.
                if (isPlatformAdministrator || isSiteManager)
                  IconButton(
                    tooltip: 'Add organization',
                    onPressed: _isSaving ? null : _openCreateDialog,
                    icon: const Icon(Icons.add_circle_outline),
                  ),
              ],
            ),
            if ((_errorMessage ?? streamError) != null) ...[
              const SizedBox(height: AppSpacing.md),
              AuthErrorBanner(message: _errorMessage ?? streamError!),
            ],
            const SizedBox(height: AppSpacing.md),
            if (isLoading && organizations.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (!isLoading && organizations.isEmpty && streamError == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                child: Text(
                  'No organizations yet.',
                  style: AppTextStyles.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              ),
            for (final organization in organizations) ...[
              _OrganizationCard(
                organization: organization,
                onEdit: isPlatformAdministrator
                    ? () => _openEditDialog(organization)
                    : null,
                onViewProjects: () => context.go(
                  AppRoutes.manageProjects,
                  extra: organization,
                ),
                onViewSafetyMeetingPoints: () => context.go(
                  AppRoutes.manageSafetyMeetingPoints,
                  extra: organization,
                ),
                onViewDailySafetyMeetings: () => context.go(
                  AppRoutes.manageDailySafetyMeetings,
                  extra: organization,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
            ],
          ],
        );
      },
    );
  }
}

class _OrganizationCard extends StatelessWidget {
  const _OrganizationCard({
    required this.organization,
    required this.onEdit,
    required this.onViewProjects,
    required this.onViewSafetyMeetingPoints,
    required this.onViewDailySafetyMeetings,
  });

  final Organization organization;

  /// Null hides the Edit action entirely — an Organization Administrator has
  /// no server-side authority to edit an organization, so the button is
  /// absent rather than merely disabled.
  final VoidCallback? onEdit;
  final VoidCallback onViewProjects;

  /// Opens [AppRoutes.manageSafetyMeetingPoints] for this organization — the
  /// entry point for `createSafetyMeetingPoint`/`updateSafetyMeetingPoint`/
  /// `activateSafetyMeetingPoint`/`deactivateSafetyMeetingPoint`, authorized
  /// for both a System Administrator and an Organization Administrator of
  /// this organization. That screen and its authorization already existed;
  /// this card is what makes it reachable.
  final VoidCallback onViewSafetyMeetingPoints;

  /// Opens [AppRoutes.manageDailySafetyMeetings] for this organization — a
  /// read-only review of every foreman's meeting records, distinct from the
  /// foreman's own operational meeting workspace.
  final VoidCallback onViewDailySafetyMeetings;

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
                  child: Text(organization.name, style: AppTextStyles.titleLarge),
                ),
                _StatusChip(status: organization.status),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            _DetailRow(icon: Icons.qr_code_outlined, value: organization.code),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                if (onEdit != null)
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: AppSpacing.minTouchTarget,
                      minWidth: 140,
                    ),
                    child: OutlinedButton.icon(
                      onPressed: onEdit,
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('Edit'),
                    ),
                  ),
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: AppSpacing.minTouchTarget,
                    minWidth: 140,
                  ),
                  child: ElevatedButton.icon(
                    onPressed: onViewProjects,
                    icon: const Icon(Icons.apartment_outlined),
                    label: const Text('Projects'),
                  ),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: AppSpacing.minTouchTarget,
                    minWidth: 140,
                  ),
                  child: OutlinedButton.icon(
                    onPressed: onViewSafetyMeetingPoints,
                    icon: const Icon(Icons.list_alt_outlined),
                    label: const Text('Safety Meeting Points'),
                  ),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: AppSpacing.minTouchTarget,
                    minWidth: 140,
                  ),
                  child: OutlinedButton.icon(
                    onPressed: onViewDailySafetyMeetings,
                    icon: const Icon(Icons.fact_check_outlined),
                    label: const Text('Daily Safety Meetings'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The values a System Administrator submitted from [_OrganizationFormDialog].
class _OrganizationFormResult {
  const _OrganizationFormResult({
    required this.name,
    required this.code,
    required this.status,
  });

  final String name;
  final String code;
  final OrganizationRecordStatus status;
}

/// Create/edit form for an organization. Shared between "Add organization"
/// and "Edit" so the two flows cannot drift in field validation.
class _OrganizationFormDialog extends StatefulWidget {
  const _OrganizationFormDialog({this.existing});

  /// Null for create; the record being edited otherwise.
  final Organization? existing;

  @override
  State<_OrganizationFormDialog> createState() =>
      _OrganizationFormDialogState();
}

class _OrganizationFormDialogState extends State<_OrganizationFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _nameController =
      TextEditingController(text: widget.existing?.name);
  late final _codeController =
      TextEditingController(text: widget.existing?.code);
  late OrganizationRecordStatus _status =
      widget.existing?.status ?? OrganizationRecordStatus.active;

  @override
  void dispose() {
    _nameController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existing != null;
    return AlertDialog(
      title: Text(isEditing ? 'Edit Organization' : 'Add Organization'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Name'),
              validator: (value) => (value == null || value.trim().isEmpty)
                  ? 'A name is required.'
                  : null,
            ),
            const SizedBox(height: AppSpacing.sm),
            TextFormField(
              controller: _codeController,
              decoration: const InputDecoration(labelText: 'Code'),
              validator: (value) => (value == null || value.trim().isEmpty)
                  ? 'A code is required.'
                  : null,
            ),
            const SizedBox(height: AppSpacing.sm),
            DropdownButtonFormField<OrganizationRecordStatus>(
              initialValue: _status,
              decoration: const InputDecoration(labelText: 'Status'),
              items: [
                for (final status in OrganizationRecordStatus.values)
                  DropdownMenuItem(value: status, child: Text(status.label)),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _status = value);
              },
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
            if (!(_formKey.currentState?.validate() ?? false)) return;
            Navigator.of(context).pop(
              _OrganizationFormResult(
                name: _nameController.text.trim(),
                code: _codeController.text.trim(),
                status: _status,
              ),
            );
          },
          child: Text(isEditing ? 'Save' : 'Create'),
        ),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final OrganizationRecordStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      OrganizationRecordStatus.active => AppColors.success,
      OrganizationRecordStatus.inactive => AppColors.textSecondary,
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
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: AppColors.textSecondary),
        const SizedBox(width: AppSpacing.sm),
        Expanded(child: Text(value, style: AppTextStyles.bodyMedium)),
      ],
    );
  }
}
