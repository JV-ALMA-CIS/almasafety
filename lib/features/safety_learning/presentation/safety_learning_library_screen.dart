import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../../organizations/domain/organization_record_status.dart';
import '../data/safety_learning_admin_service.dart';
import '../data/safety_learning_repository.dart';
import '../domain/safety_learning.dart';
import '../domain/safety_learning_type.dart';

/// The Safety Learning library: lists an organization's learning content and
/// lets an authorized administrator create or edit an item.
///
/// Follows [ActivitiesScreen]'s pattern exactly, including its `canManage`
/// gate — a System Administrator OR an Organization Administrator of the
/// matching organization, which is precisely what
/// `createSafetyLearning`/`updateSafetyLearning` authorize server-side via
/// `requireOrganizationScopedAdmin`. The status dropdown doubles as
/// activate/deactivate; there is no delete, matching every other record type
/// here (an inactive item is retained so historical learning records keep
/// referring to something real).
///
/// Unlike [ActivitiesScreen], this screen resolves its organization from the
/// signed-in user's own profile rather than an `extra`-threaded
/// [Organization]: it is reached directly from [AdministrationScreen] rather
/// than by drilling down through Organization -> Project -> Site. A System
/// Administrator belongs to no organization, so they must arrive with one
/// supplied — see [organizationId].
class SafetyLearningLibraryScreen extends StatefulWidget {
  const SafetyLearningLibraryScreen({
    super.key,
    this.organizationId,
    this.repository,
    this.adminService,
  });

  /// The organization whose library to show. When null, falls back to the
  /// signed-in user's own `organizationId` — the Organization Administrator
  /// case. A System Administrator has no organization of their own and so
  /// sees the "no organization" message unless one is supplied.
  final String? organizationId;

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real dependencies scoped to the resolved organization.
  final SafetyLearningRepository? repository;
  final SafetyLearningAdminService? adminService;

  @override
  State<SafetyLearningLibraryScreen> createState() =>
      _SafetyLearningLibraryScreenState();
}

class _SafetyLearningLibraryScreenState
    extends State<SafetyLearningLibraryScreen> {
  late final SafetyLearningAdminService _adminService =
      widget.adminService ?? SafetyLearningAdminService();

  SafetyLearningRepository? _repository;
  String? _errorMessage;
  bool _isSaving = false;

  /// Builds (once per organization) the repository this screen streams from.
  /// Constructed lazily in [build] rather than in a field initializer because
  /// the organization is not known until the session profile is read.
  SafetyLearningRepository _repositoryFor(String organizationId) {
    final existing = _repository;
    if (existing != null && existing.organizationId == organizationId) {
      return existing;
    }
    final created = widget.repository ??
        SafetyLearningRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );
    _repository = created;
    return created;
  }

  Future<void> _openCreateDialog(String organizationId) async {
    final result = await showDialog<_SafetyLearningFormResult>(
      context: context,
      builder: (_) => const _SafetyLearningFormDialog(),
    );
    if (result == null || !mounted) return;
    await _save(() => _adminService.createSafetyLearning(
      organizationId: organizationId,
      title: result.title,
      type: result.type,
      contentReference: result.contentReference,
      description: result.description,
      status: result.status,
    ));
  }

  Future<void> _openEditDialog(
    String organizationId,
    SafetyLearning learning,
  ) async {
    final result = await showDialog<_SafetyLearningFormResult>(
      context: context,
      builder: (_) => _SafetyLearningFormDialog(existing: learning),
    );
    if (result == null || !mounted) return;
    await _save(() => _adminService.updateSafetyLearning(
      organizationId,
      learning.id,
      title: result.title,
      type: result.type,
      contentReference: result.contentReference,
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
    final organizationId = widget.organizationId ?? profile?.organizationId;
    // Admin-only: the Safety Learning library is a platform-level,
    // company-wide responsibility deliberately not delegated to Site
    // Managers (PROJECT_CONTEXT.md §4, §12).
    final canManage = profile?.canManageSafetyLearningLibrary == true;

    if (!canManage || organizationId == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: Text(
            'You do not have permission to manage safety learning.',
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return StreamBuilder<List<SafetyLearning>>(
      stream: _repositoryFor(organizationId).watchAll(),
      builder: (context, snapshot) {
        final items = snapshot.data ?? const <SafetyLearning>[];
        final isLoading = snapshot.connectionState == ConnectionState.waiting;
        final streamError = snapshot.hasError
            ? 'Could not load safety learning. Please try again.'
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
                      Text(
                        'Safety Learning',
                        style: AppTextStyles.headlineMedium,
                      ),
                      const Text(
                        'Videos, courses, guides, documents and knowledge '
                        'checks available to this organization.',
                        style: AppTextStyles.bodyMedium,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Add learning item',
                  onPressed:
                      _isSaving ? null : () => _openCreateDialog(organizationId),
                  icon: const Icon(Icons.add_circle_outline),
                ),
              ],
            ),
            if ((_errorMessage ?? streamError) != null) ...[
              const SizedBox(height: AppSpacing.md),
              AuthErrorBanner(message: _errorMessage ?? streamError!),
            ],
            const SizedBox(height: AppSpacing.md),
            if (isLoading && items.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (!isLoading && items.isEmpty && streamError == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                child: Text(
                  'No safety learning items yet.',
                  style: AppTextStyles.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              ),
            for (final item in items) ...[
              _SafetyLearningCard(
                learning: item,
                onEdit: () => _openEditDialog(organizationId, item),
              ),
              const SizedBox(height: AppSpacing.md),
            ],
          ],
        );
      },
    );
  }
}

class _SafetyLearningCard extends StatelessWidget {
  const _SafetyLearningCard({required this.learning, required this.onEdit});

  final SafetyLearning learning;
  final VoidCallback onEdit;

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
                  child: Text(learning.title, style: AppTextStyles.titleLarge),
                ),
                _StatusChip(status: learning.status),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            _DetailRow(
              icon: Icons.category_outlined,
              value: learning.type.label,
            ),
            _DetailRow(
              icon: Icons.link_outlined,
              value: learning.contentReference,
            ),
            if (learning.description != null)
              _DetailRow(
                icon: Icons.description_outlined,
                value: learning.description!,
              ),
            const SizedBox(height: AppSpacing.md),
            Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
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
            ),
          ],
        ),
      ),
    );
  }
}

class _SafetyLearningFormResult {
  const _SafetyLearningFormResult({
    required this.title,
    required this.type,
    required this.contentReference,
    required this.status,
    this.description,
  });

  final String title;
  final SafetyLearningType type;
  final String contentReference;
  final String? description;
  final OrganizationRecordStatus status;
}

class _SafetyLearningFormDialog extends StatefulWidget {
  const _SafetyLearningFormDialog({this.existing});

  final SafetyLearning? existing;

  @override
  State<_SafetyLearningFormDialog> createState() =>
      _SafetyLearningFormDialogState();
}

class _SafetyLearningFormDialogState extends State<_SafetyLearningFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _titleController =
      TextEditingController(text: widget.existing?.title);
  late final _contentReferenceController =
      TextEditingController(text: widget.existing?.contentReference);
  late final _descriptionController =
      TextEditingController(text: widget.existing?.description);
  late SafetyLearningType _type =
      widget.existing?.type ?? SafetyLearningType.document;
  late OrganizationRecordStatus _status =
      widget.existing?.status ?? OrganizationRecordStatus.active;

  @override
  void dispose() {
    _titleController.dispose();
    _contentReferenceController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existing != null;
    return AlertDialog(
      title: Text(isEditing ? 'Edit Learning Item' : 'Add Learning Item'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _titleController,
                  decoration: const InputDecoration(labelText: 'Title'),
                  validator: (value) =>
                      (value == null || value.trim().isEmpty)
                          ? 'A title is required.'
                          : null,
                ),
                const SizedBox(height: AppSpacing.sm),
                DropdownButtonFormField<SafetyLearningType>(
                  initialValue: _type,
                  decoration: const InputDecoration(labelText: 'Type'),
                  items: [
                    for (final type in SafetyLearningType.values)
                      DropdownMenuItem(value: type, child: Text(type.label)),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _type = value);
                  },
                ),
                const SizedBox(height: AppSpacing.sm),
                TextFormField(
                  controller: _contentReferenceController,
                  decoration: const InputDecoration(
                    labelText: 'Content reference',
                    helperText: 'A URL or document reference.',
                  ),
                  validator: (value) =>
                      (value == null || value.trim().isEmpty)
                          ? 'A content reference is required.'
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
                      DropdownMenuItem(
                        value: status,
                        child: Text(status.label),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _status = value);
                  },
                ),
              ],
            ),
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
            if (!(_formKey.currentState?.validate() ?? false)) return;
            final description = _descriptionController.text.trim();
            Navigator.of(context).pop(
              _SafetyLearningFormResult(
                title: _titleController.text.trim(),
                type: _type,
                contentReference: _contentReferenceController.text.trim(),
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
