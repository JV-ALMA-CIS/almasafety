import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../../organizations/domain/organization.dart';
import '../../organizations/domain/organization_record_status.dart';
import '../../organizations/domain/project.dart';
import '../../organizations/domain/site.dart';
import '../../../routing/app_routes.dart';
import '../data/activity_admin_service.dart';
import '../data/activity_repository.dart';
import '../domain/activity.dart';

/// Lists the activities belonging to one site and lets an authorized admin
/// create or edit one.
///
/// Follows [SitesScreen]'s pattern exactly, except `canManage` is broader
/// than [SitesScreen]'s: a System Administrator OR an Organization
/// Administrator of the matching organization may manage activities, since
/// `createActivity`/`updateActivity` authorize both — see
/// `functions/src/activity_callable.ts`'s doc comment.
class ActivitiesScreen extends StatefulWidget {
  const ActivitiesScreen({
    required this.organization,
    required this.project,
    required this.site,
    super.key,
    this.repository,
    this.adminService,
  });

  /// The organization [site] belongs to, and the project it belongs to.
  /// Passed explicitly rather than re-derived, matching [SitesScreen].
  final Organization organization;
  final Project project;
  final Site site;

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real dependencies scoped to [organization]/[site].
  final ActivityRepository? repository;
  final ActivityAdminService? adminService;

  @override
  State<ActivitiesScreen> createState() => _ActivitiesScreenState();
}

class _ActivitiesScreenState extends State<ActivitiesScreen> {
  late final ActivityRepository _repository = widget.repository ??
      ActivityRepository(
        firestoreService: FirestoreService(),
        organizationId: widget.organization.id,
      );
  late final ActivityAdminService _adminService =
      widget.adminService ?? ActivityAdminService();

  String? _errorMessage;
  bool _isSaving = false;

  Future<void> _openCreateDialog() async {
    final result = await showDialog<_ActivityFormResult>(
      context: context,
      builder: (_) => const _ActivityFormDialog(),
    );
    if (result == null || !mounted) return;
    await _save(() => _adminService.createActivity(
      organizationId: widget.organization.id,
      projectId: widget.project.id,
      siteId: widget.site.id,
      name: result.name,
      code: result.code,
      description: result.description,
      status: result.status,
    ));
  }

  Future<void> _openEditDialog(Activity activity) async {
    final result = await showDialog<_ActivityFormResult>(
      context: context,
      builder: (_) => _ActivityFormDialog(existing: activity),
    );
    if (result == null || !mounted) return;
    await _save(() => _adminService.updateActivity(
      widget.organization.id,
      activity.id,
      name: result.name,
      code: result.code,
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

  void _openWorkers(Activity activity) {
    context.go(
      AppRoutes.manageActivityWorkers,
      extra: (
        organization: widget.organization,
        project: widget.project,
        site: widget.site,
        activity: activity,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sessionController = context.watch<SessionController>();
    final profile = sessionController.profile;
    // Checked against membershipFor(widget.organization.id) SPECIFICALLY,
    // not activeMembership — see ProjectsScreen's matching comment for why.
    final canManage = profile?.isPlatformAdministrator == true ||
        sessionController.membershipFor(widget.organization.id)?.role
                .canManageOrgContent ==
            true;

    if (!canManage) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: Text(
            'You do not have permission to manage activities.',
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return StreamBuilder<List<Activity>>(
      stream: _repository.watchBySite(widget.site.id),
      builder: (context, snapshot) {
        final activities = snapshot.data ?? const [];
        final isLoading = snapshot.connectionState == ConnectionState.waiting;
        final streamError = snapshot.hasError
            ? 'Could not load activities. Please try again.'
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
                      Text('Activities', style: AppTextStyles.headlineMedium),
                      Text(
                        '${widget.organization.name} · ${widget.project.name}'
                        ' · ${widget.site.name}',
                        style: AppTextStyles.bodyMedium,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Add activity',
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
            if (isLoading && activities.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (!isLoading && activities.isEmpty && streamError == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                child: Text(
                  'No activities yet.',
                  style: AppTextStyles.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              ),
            for (final activity in activities) ...[
              _ActivityCard(
                activity: activity,
                onEdit: () => _openEditDialog(activity),
                onWorkers: () => _openWorkers(activity),
              ),
              const SizedBox(height: AppSpacing.md),
            ],
          ],
        );
      },
    );
  }
}

class _ActivityCard extends StatelessWidget {
  const _ActivityCard({
    required this.activity,
    required this.onEdit,
    required this.onWorkers,
  });

  final Activity activity;
  final VoidCallback onEdit;
  final VoidCallback onWorkers;

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
                  child: Text(activity.name, style: AppTextStyles.titleLarge),
                ),
                _StatusChip(status: activity.status),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            _DetailRow(icon: Icons.qr_code_outlined, value: activity.code),
            if (activity.description != null)
              _DetailRow(
                icon: Icons.description_outlined,
                value: activity.description!,
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
                    onPressed: onWorkers,
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

class _ActivityFormResult {
  const _ActivityFormResult({
    required this.name,
    required this.code,
    required this.status,
    this.description,
  });

  final String name;
  final String code;
  final String? description;
  final OrganizationRecordStatus status;
}

class _ActivityFormDialog extends StatefulWidget {
  const _ActivityFormDialog({this.existing});

  final Activity? existing;

  @override
  State<_ActivityFormDialog> createState() => _ActivityFormDialogState();
}

class _ActivityFormDialogState extends State<_ActivityFormDialog> {
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
      title: Text(isEditing ? 'Edit Activity' : 'Add Activity'),
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
              _ActivityFormResult(
                name: _nameController.text.trim(),
                code: _codeController.text.trim(),
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
