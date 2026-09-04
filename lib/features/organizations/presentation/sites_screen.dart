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
import '../data/site_repository.dart';
import '../domain/organization.dart';
import '../domain/organization_record_status.dart';
import '../domain/project.dart';
import '../domain/site.dart';

/// Lists the sites belonging to one project. A System Administrator may
/// create or edit one; an [AppRole.siteManager] of the
/// matching organization may view, navigate to Activities, and manage each
/// site's assigned workers — `createSite`/`updateSite` have no Organization
/// Administrator authorization server-side, so Create/Edit stay hidden for
/// that role, matching [ProjectsScreen]'s own split. Worker assignment
/// (`assignWorkerToSite`/`removeWorkerFromSite`) IS authorized for both
/// roles — see [AppRoutes.manageSiteWorkers].
///
/// Follows [ProjectsScreen]'s pattern exactly — see [OrganizationsScreen]'s
/// doc comment for the three-places-authorization-is-checked rationale.
class SitesScreen extends StatefulWidget {
  const SitesScreen({
    required this.organization,
    required this.project,
    super.key,
    this.repository,
    this.adminService,
  });

  /// The organization [project] belongs to. A site must belong to both its
  /// organization and its project — passing the organization explicitly
  /// (rather than re-deriving it) is what lets [SiteRepository] and
  /// [OrganizationAdminService] enforce that relationship without a second
  /// lookup.
  final Organization organization;
  final Project project;

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real dependencies scoped to [organization]/[project].
  final SiteRepository? repository;
  final OrganizationAdminService? adminService;

  @override
  State<SitesScreen> createState() => _SitesScreenState();
}

class _SitesScreenState extends State<SitesScreen> {
  late final SiteRepository _repository = widget.repository ??
      SiteRepository(
        firestoreService: FirestoreService(),
        organizationId: widget.organization.id,
      );
  late final OrganizationAdminService _adminService =
      widget.adminService ?? OrganizationAdminService();

  String? _errorMessage;
  bool _isSaving = false;

  Future<void> _openCreateDialog() async {
    final result = await showDialog<_SiteFormResult>(
      context: context,
      builder: (_) => const _SiteFormDialog(),
    );
    if (result == null || !mounted) return;
    await _save(() => _adminService.createSite(
      organizationId: widget.organization.id,
      projectId: widget.project.id,
      name: result.name,
      code: result.code,
      location: result.location,
      description: result.description,
      status: result.status,
    ));
  }

  Future<void> _openEditDialog(Site site) async {
    final result = await showDialog<_SiteFormResult>(
      context: context,
      builder: (_) => _SiteFormDialog(existing: site),
    );
    if (result == null || !mounted) return;
    await _save(() => _adminService.updateSite(
      widget.organization.id,
      site.id,
      name: result.name,
      code: result.code,
      location: result.location,
      description: result.description,
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
    final profile = context.watch<SessionController>().profile;
    final isPlatformAdministrator = profile?.isPlatformAdministrator ?? false;
    final canManage = isPlatformAdministrator ||
        (profile?.canManageOrgContent == true &&
            profile?.organizationId == widget.organization.id);

    if (!canManage) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: Text(
            'You do not have permission to manage sites.',
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return StreamBuilder<List<Site>>(
      stream: _repository.watchByProject(widget.project.id),
      builder: (context, snapshot) {
        final sites = snapshot.data ?? const [];
        final isLoading = snapshot.connectionState == ConnectionState.waiting;
        final streamError = snapshot.hasError
            ? 'Could not load sites. Please try again.'
            : null;

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
                      Text('Sites', style: AppTextStyles.headlineMedium),
                      Text(
                        '${widget.organization.name} · ${widget.project.name}',
                        style: AppTextStyles.bodyMedium,
                      ),
                    ],
                  ),
                ),
                if (isPlatformAdministrator)
                  IconButton(
                    tooltip: 'Add site',
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
            if (isLoading && sites.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (!isLoading && sites.isEmpty && streamError == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                child: Text(
                  'No sites yet.',
                  style: AppTextStyles.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              ),
            for (final site in sites) ...[
              _SiteCard(
                site: site,
                onEdit: isPlatformAdministrator
                    ? () => _openEditDialog(site)
                    : null,
                onViewActivities: () => context.go(
                  AppRoutes.manageActivities,
                  extra: (
                    organization: widget.organization,
                    project: widget.project,
                    site: site,
                  ),
                ),
                onViewWorkers: () => context.go(
                  AppRoutes.manageSiteWorkers,
                  extra: (
                    organization: widget.organization,
                    project: widget.project,
                    site: site,
                  ),
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

class _SiteCard extends StatelessWidget {
  const _SiteCard({
    required this.site,
    required this.onEdit,
    required this.onViewActivities,
    required this.onViewWorkers,
  });

  final Site site;

  /// Null hides the Edit action — matches [OrganizationsScreen]'s own
  /// `_OrganizationCard.onEdit`.
  final VoidCallback? onEdit;
  final VoidCallback onViewActivities;

  /// Opens [AppRoutes.manageSiteWorkers] for this site — the entry point for
  /// `assignWorkerToSite`/`removeWorkerFromSite`, authorized for both a
  /// System Administrator and an Organization Administrator of this site's
  /// organization.
  final VoidCallback onViewWorkers;

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
                  child: Text(site.name, style: AppTextStyles.titleLarge),
                ),
                _StatusChip(status: site.status),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            _DetailRow(icon: Icons.qr_code_outlined, value: site.code),
            if (site.location != null)
              _DetailRow(
                icon: Icons.location_on_outlined,
                value: site.location!,
              ),
            if (site.description != null)
              _DetailRow(
                icon: Icons.description_outlined,
                value: site.description!,
              ),
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
                  child: OutlinedButton.icon(
                    onPressed: onViewActivities,
                    icon: const Icon(Icons.engineering_outlined),
                    label: const Text('Activities'),
                  ),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: AppSpacing.minTouchTarget,
                    minWidth: 140,
                  ),
                  child: ElevatedButton.icon(
                    onPressed: onViewWorkers,
                    icon: const Icon(Icons.groups_outlined),
                    label: const Text('Workers'),
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

class _SiteFormResult {
  const _SiteFormResult({
    required this.name,
    required this.code,
    required this.status,
    this.location,
    this.description,
  });

  final String name;
  final String code;
  final String? location;
  final String? description;
  final OrganizationRecordStatus status;
}

class _SiteFormDialog extends StatefulWidget {
  const _SiteFormDialog({this.existing});

  final Site? existing;

  @override
  State<_SiteFormDialog> createState() => _SiteFormDialogState();
}

class _SiteFormDialogState extends State<_SiteFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _nameController =
      TextEditingController(text: widget.existing?.name);
  late final _codeController =
      TextEditingController(text: widget.existing?.code);
  late final _locationController =
      TextEditingController(text: widget.existing?.location);
  late final _descriptionController =
      TextEditingController(text: widget.existing?.description);
  late OrganizationRecordStatus _status =
      widget.existing?.status ?? OrganizationRecordStatus.active;

  @override
  void dispose() {
    _nameController.dispose();
    _codeController.dispose();
    _locationController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existing != null;
    return AlertDialog(
      title: Text(isEditing ? 'Edit Site' : 'Add Site'),
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
            TextFormField(
              controller: _locationController,
              decoration: const InputDecoration(labelText: 'Location'),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextFormField(
              controller: _descriptionController,
              decoration: const InputDecoration(labelText: 'Description'),
              maxLines: 2,
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
            final location = _locationController.text.trim();
            final description = _descriptionController.text.trim();
            Navigator.of(context).pop(
              _SiteFormResult(
                name: _nameController.text.trim(),
                code: _codeController.text.trim(),
                location: location.isEmpty ? null : location,
                description: description.isEmpty ? null : description,
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
