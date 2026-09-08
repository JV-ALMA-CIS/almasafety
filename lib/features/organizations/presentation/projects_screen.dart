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
import '../data/project_repository.dart';
import '../domain/organization.dart';
import '../domain/organization_record_status.dart';
import '../domain/project.dart';

/// Lists the projects belonging to one organization. A System Administrator
/// may create or edit one; an [AppRole.siteManager] of the
/// matching organization may view and navigate to Sites only —
/// `createProject`/`updateProject` have no Organization Administrator
/// authorization server-side, so Create/Edit stay hidden for that role,
/// matching [OrganizationsScreen]'s own split.
///
/// Follows [OrganizationsScreen]'s pattern exactly — see that screen's doc
/// comment for the three-places-authorization-is-checked rationale, which
/// applies identically here.
class ProjectsScreen extends StatefulWidget {
  const ProjectsScreen({
    required this.organization,
    super.key,
    this.repository,
    this.adminService,
  });

  /// The organization these projects belong to. Passed in from
  /// [OrganizationsScreen] rather than looked up again — the organization
  /// list already has it.
  final Organization organization;

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real dependencies scoped to [organization].
  final ProjectRepository? repository;
  final OrganizationAdminService? adminService;

  @override
  State<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends State<ProjectsScreen> {
  late final ProjectRepository _repository = widget.repository ??
      ProjectRepository(
        firestoreService: FirestoreService(),
        organizationId: widget.organization.id,
      );
  late final OrganizationAdminService _adminService =
      widget.adminService ?? OrganizationAdminService();

  String? _errorMessage;
  bool _isSaving = false;

  Future<void> _openCreateDialog() async {
    final result = await showDialog<_ProjectFormResult>(
      context: context,
      builder: (_) => const _ProjectFormDialog(),
    );
    if (result == null || !mounted) return;
    await _save(() => _adminService.createProject(
      organizationId: widget.organization.id,
      name: result.name,
      code: result.code,
      description: result.description,
      status: result.status,
      startDate: result.startDate,
      endDate: result.endDate,
    ));
  }

  Future<void> _openEditDialog(Project project) async {
    final result = await showDialog<_ProjectFormResult>(
      context: context,
      builder: (_) => _ProjectFormDialog(existing: project),
    );
    if (result == null || !mounted) return;
    await _save(() => _adminService.updateProject(
      widget.organization.id,
      project.id,
      name: result.name,
      code: result.code,
      description: result.description,
      status: result.status,
      startDate: result.startDate,
      endDate: result.endDate,
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
    // Checked against membershipFor(widget.organization.id) SPECIFICALLY,
    // not activeMembership: this screen is reached by navigating to one
    // particular organization's card (independent of which organization
    // happens to be "active" in the switcher), so a Site Manager of
    // several organizations must not be refused just because the one they
    // tapped into isn't the currently-active one.
    final canManage = isPlatformAdministrator ||
        sessionController.membershipFor(widget.organization.id)?.role
                .canManageOrgContent ==
            true;

    if (!canManage) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: Text(
            'You do not have permission to manage projects.',
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return StreamBuilder<List<Project>>(
      stream: _repository.watchAll(),
      builder: (context, snapshot) {
        final projects = snapshot.data ?? const [];
        final isLoading = snapshot.connectionState == ConnectionState.waiting;
        final streamError = snapshot.hasError
            ? 'Could not load projects. Please try again.'
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
                      Text('Projects', style: AppTextStyles.headlineMedium),
                      Text(
                        widget.organization.name,
                        style: AppTextStyles.bodyMedium,
                      ),
                    ],
                  ),
                ),
                if (isPlatformAdministrator)
                  IconButton(
                    tooltip: 'Add project',
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
            if (isLoading && projects.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (!isLoading && projects.isEmpty && streamError == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                child: Text(
                  'No projects yet.',
                  style: AppTextStyles.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              ),
            for (final project in projects) ...[
              _ProjectCard(
                project: project,
                onEdit: isPlatformAdministrator
                    ? () => _openEditDialog(project)
                    : null,
                onViewSites: () => context.go(
                  AppRoutes.manageSites,
                  extra: (organization: widget.organization, project: project),
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

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({
    required this.project,
    required this.onEdit,
    required this.onViewSites,
  });

  final Project project;

  /// Null hides the Edit action — matches [OrganizationsScreen]'s own
  /// `_OrganizationCard.onEdit`.
  final VoidCallback? onEdit;
  final VoidCallback onViewSites;

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
                  child: Text(project.name, style: AppTextStyles.titleLarge),
                ),
                _StatusChip(status: project.status),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            _DetailRow(icon: Icons.qr_code_outlined, value: project.code),
            if (project.description != null)
              _DetailRow(
                icon: Icons.description_outlined,
                value: project.description!,
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
                  child: ElevatedButton.icon(
                    onPressed: onViewSites,
                    icon: const Icon(Icons.location_city_outlined),
                    label: const Text('Sites'),
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

class _ProjectFormResult {
  const _ProjectFormResult({
    required this.name,
    required this.code,
    required this.status,
    this.description,
    this.startDate,
    this.endDate,
  });

  final String name;
  final String code;
  final String? description;
  final OrganizationRecordStatus status;
  final DateTime? startDate;
  final DateTime? endDate;
}

class _ProjectFormDialog extends StatefulWidget {
  const _ProjectFormDialog({this.existing});

  final Project? existing;

  @override
  State<_ProjectFormDialog> createState() => _ProjectFormDialogState();
}

class _ProjectFormDialogState extends State<_ProjectFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _nameController =
      TextEditingController(text: widget.existing?.name);
  late final _codeController =
      TextEditingController(text: widget.existing?.code);
  late final _descriptionController =
      TextEditingController(text: widget.existing?.description);
  late OrganizationRecordStatus _status =
      widget.existing?.status ?? OrganizationRecordStatus.active;

  @override
  void dispose() {
    _nameController.dispose();
    _codeController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existing != null;
    return AlertDialog(
      title: Text(isEditing ? 'Edit Project' : 'Add Project'),
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
            final description = _descriptionController.text.trim();
            Navigator.of(context).pop(
              _ProjectFormResult(
                name: _nameController.text.trim(),
                code: _codeController.text.trim(),
                description: description.isEmpty ? null : description,
                status: _status,
                startDate: widget.existing?.startDate,
                endDate: widget.existing?.endDate,
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
