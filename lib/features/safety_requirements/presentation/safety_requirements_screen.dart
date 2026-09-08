import 'package:flutter/material.dart';
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
import '../../safety_learning/data/safety_learning_repository.dart';
import '../../safety_learning/domain/safety_learning.dart';
import '../data/safety_requirement_admin_service.dart';
import '../data/safety_requirement_repository.dart';
import '../domain/safety_requirement.dart';
import '../domain/safety_requirement_risk.dart';

/// Lists the safety requirements in one organization and lets an authorized
/// admin create or edit one, including which [SafetyLearning] items it
/// requires.
///
/// Follows [SafetyLearningLibraryScreen]'s pattern exactly, including its
/// `canManage` getter.
class SafetyRequirementsScreen extends StatefulWidget {
  const SafetyRequirementsScreen({
    required this.organization,
    super.key,
    this.repository,
    this.adminService,
    this.learningRepository,
  });

  final Organization organization;

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real dependencies scoped to [organization].
  final SafetyRequirementRepository? repository;
  final SafetyRequirementAdminService? adminService;
  final SafetyLearningRepository? learningRepository;

  @override
  State<SafetyRequirementsScreen> createState() =>
      _SafetyRequirementsScreenState();
}

class _SafetyRequirementsScreenState extends State<SafetyRequirementsScreen> {
  late final SafetyLearningRepository _learningRepository =
      widget.learningRepository ??
          SafetyLearningRepository(
            firestoreService: FirestoreService(),
            organizationId: widget.organization.id,
          );
  late final SafetyRequirementRepository _repository = widget.repository ??
      SafetyRequirementRepository(
        firestoreService: FirestoreService(),
        organizationId: widget.organization.id,
        safetyLearningRepository: _learningRepository,
      );
  late final SafetyRequirementAdminService _adminService =
      widget.adminService ?? SafetyRequirementAdminService();

  String? _errorMessage;
  bool _isSaving = false;

  Future<void> _openCreateDialog(List<SafetyLearning> learningItems) async {
    final result = await showDialog<_SafetyRequirementFormResult>(
      context: context,
      builder: (_) => _SafetyRequirementFormDialog(
        learningItems: learningItems,
      ),
    );
    if (result == null || !mounted) return;
    await _save(() => _adminService.createSafetyRequirement(
      organizationId: widget.organization.id,
      name: result.name,
      category: result.category,
      risk: result.risk,
      description: result.description,
      requiredLearningIds: result.requiredLearningIds,
      status: result.status,
    ));
  }

  Future<void> _openEditDialog(
    SafetyRequirement requirement,
    List<SafetyLearning> learningItems,
  ) async {
    final result = await showDialog<_SafetyRequirementFormResult>(
      context: context,
      builder: (_) => _SafetyRequirementFormDialog(
        existing: requirement,
        learningItems: learningItems,
      ),
    );
    if (result == null || !mounted) return;
    await _save(() => _adminService.updateSafetyRequirement(
      widget.organization.id,
      requirement.id,
      name: result.name,
      category: result.category,
      risk: result.risk,
      description: result.description,
      requiredLearningIds: result.requiredLearningIds,
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
    // A non-Admin's canManageOrgContent now lives on their membership FOR
    // THIS SPECIFIC organization (checked via membershipFor, not
    // activeMembership — see ProjectsScreen's matching comment for why),
    // not on UserProfile.platformRole, which is admin-only under the
    // multi-org membership model — except the one transient case of a
    // Site Manager just approved with no organization yet
    // (profile.platformRole == siteManager), which membershipFor cannot
    // catch since no membership exists yet either way.
    final canManageOrgContent = profile?.canManageOrgContent == true ||
        sessionController.membershipFor(widget.organization.id)?.role
                .canManageOrgContent ==
            true;
    final canManage =
        profile?.isPlatformAdministrator == true || canManageOrgContent;

    if (!canManage) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: Text(
            'You do not have permission to manage safety requirements.',
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return StreamBuilder<List<SafetyLearning>>(
      stream: _learningRepository.watchAll(),
      builder: (context, learningSnapshot) {
        final learningItems = learningSnapshot.data ?? const [];
        return StreamBuilder<List<SafetyRequirement>>(
          stream: _repository.watchAll(),
          builder: (context, snapshot) {
            final requirements = snapshot.data ?? const [];
            final isLoading =
                snapshot.connectionState == ConnectionState.waiting;
            final streamError = snapshot.hasError
                ? 'Could not load safety requirements. Please try again.'
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
                            'Safety Requirements',
                            style: AppTextStyles.headlineMedium,
                          ),
                          Text(
                            widget.organization.name,
                            style: AppTextStyles.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Add requirement',
                      onPressed: _isSaving
                          ? null
                          : () => _openCreateDialog(learningItems),
                      icon: const Icon(Icons.add_circle_outline),
                    ),
                  ],
                ),
                if ((_errorMessage ?? streamError) != null) ...[
                  const SizedBox(height: AppSpacing.md),
                  AuthErrorBanner(message: _errorMessage ?? streamError!),
                ],
                const SizedBox(height: AppSpacing.md),
                if (isLoading && requirements.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                if (!isLoading && requirements.isEmpty && streamError == null)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                    child: Text(
                      'No safety requirements yet.',
                      style: AppTextStyles.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                  ),
                for (final requirement in requirements) ...[
                  _SafetyRequirementCard(
                    requirement: requirement,
                    learningItems: learningItems,
                    onEdit: () => _openEditDialog(requirement, learningItems),
                  ),
                  const SizedBox(height: AppSpacing.md),
                ],
              ],
            );
          },
        );
      },
    );
  }
}

class _SafetyRequirementCard extends StatelessWidget {
  const _SafetyRequirementCard({
    required this.requirement,
    required this.learningItems,
    required this.onEdit,
  });

  final SafetyRequirement requirement;
  final List<SafetyLearning> learningItems;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final learningById = {for (final item in learningItems) item.id: item};
    final requiredTitles = [
      for (final id in requirement.requiredLearningIds)
        learningById[id]?.title ?? id,
    ];
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
                    requirement.name,
                    style: AppTextStyles.titleLarge,
                  ),
                ),
                _StatusChip(status: requirement.status),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            _DetailRow(
              icon: Icons.category_outlined,
              value: requirement.category,
            ),
            _DetailRow(
              icon: Icons.warning_amber_outlined,
              value: 'Risk: ${requirement.risk.label}',
            ),
            if (requirement.description != null)
              _DetailRow(
                icon: Icons.description_outlined,
                value: requirement.description!,
              ),
            _DetailRow(
              icon: Icons.school_outlined,
              value: requiredTitles.isEmpty
                  ? 'No required learning items.'
                  : 'Requires: ${requiredTitles.join(', ')}',
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

class _SafetyRequirementFormResult {
  const _SafetyRequirementFormResult({
    required this.name,
    required this.category,
    required this.risk,
    required this.status,
    required this.requiredLearningIds,
    this.description,
  });

  final String name;
  final String category;
  final SafetyRequirementRisk risk;
  final String? description;
  final List<String> requiredLearningIds;
  final OrganizationRecordStatus status;
}

class _SafetyRequirementFormDialog extends StatefulWidget {
  const _SafetyRequirementFormDialog({
    required this.learningItems,
    this.existing,
  });

  final SafetyRequirement? existing;
  final List<SafetyLearning> learningItems;

  @override
  State<_SafetyRequirementFormDialog> createState() =>
      _SafetyRequirementFormDialogState();
}

class _SafetyRequirementFormDialogState
    extends State<_SafetyRequirementFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _nameController =
      TextEditingController(text: widget.existing?.name);
  late final _categoryController =
      TextEditingController(text: widget.existing?.category);
  late final _descriptionController =
      TextEditingController(text: widget.existing?.description);
  late SafetyRequirementRisk _risk =
      widget.existing?.risk ?? SafetyRequirementRisk.medium;
  late OrganizationRecordStatus _status =
      widget.existing?.status ?? OrganizationRecordStatus.active;
  late final Set<String> _selectedLearningIds =
      {...?widget.existing?.requiredLearningIds};

  @override
  void dispose() {
    _nameController.dispose();
    _categoryController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existing != null;
    return AlertDialog(
      title: Text(isEditing ? 'Edit Requirement' : 'Add Requirement'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _nameController,
                  decoration: const InputDecoration(labelText: 'Name'),
                  validator: (value) =>
                      (value == null || value.trim().isEmpty)
                          ? 'A name is required.'
                          : null,
                ),
                const SizedBox(height: AppSpacing.sm),
                TextFormField(
                  controller: _categoryController,
                  decoration: const InputDecoration(labelText: 'Category'),
                  validator: (value) =>
                      (value == null || value.trim().isEmpty)
                          ? 'A category is required.'
                          : null,
                ),
                const SizedBox(height: AppSpacing.sm),
                TextFormField(
                  controller: _descriptionController,
                  decoration: const InputDecoration(labelText: 'Description'),
                  maxLines: 2,
                ),
                const SizedBox(height: AppSpacing.sm),
                DropdownButtonFormField<SafetyRequirementRisk>(
                  initialValue: _risk,
                  decoration: const InputDecoration(labelText: 'Risk'),
                  items: [
                    for (final risk in SafetyRequirementRisk.values)
                      DropdownMenuItem(value: risk, child: Text(risk.label)),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _risk = value);
                  },
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
                const SizedBox(height: AppSpacing.md),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Required Learning',
                    style: AppTextStyles.titleLarge,
                  ),
                ),
                if (widget.learningItems.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
                    child: Text(
                      'No safety learning items exist yet.',
                      style: AppTextStyles.bodyMedium,
                    ),
                  ),
                for (final item in widget.learningItems)
                  CheckboxListTile(
                    value: _selectedLearningIds.contains(item.id),
                    title: Text(item.title),
                    subtitle: Text(item.type.label),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    onChanged: (checked) {
                      setState(() {
                        if (checked ?? false) {
                          _selectedLearningIds.add(item.id);
                        } else {
                          _selectedLearningIds.remove(item.id);
                        }
                      });
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
              _SafetyRequirementFormResult(
                name: _nameController.text.trim(),
                category: _categoryController.text.trim(),
                risk: _risk,
                description: description.isEmpty ? null : description,
                requiredLearningIds: _selectedLearningIds.toList(),
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
