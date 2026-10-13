import 'package:flutter/material.dart';
import '../../../core/widgets/live_stream_builder.dart';
import 'package:provider/provider.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../activities/data/activity_repository.dart';
import '../../activities/domain/activity.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../../organizations/data/project_repository.dart';
import '../../organizations/data/site_repository.dart';
import '../../organizations/domain/organization.dart';
import '../../organizations/domain/organization_record_status.dart';
import '../../organizations/domain/project.dart';
import '../../organizations/domain/site.dart';
import '../../safety_learning/data/safety_learning_repository.dart';
import '../../safety_learning/domain/safety_learning.dart';
import '../data/safety_requirement_admin_service.dart';
import '../data/safety_requirement_repository.dart';
import '../domain/safety_requirement.dart';
import '../domain/safety_requirement_risk.dart';
import '../../../core/widgets/accent_card.dart';
import '../../../core/widgets/feature_header.dart';
import '../../../core/widgets/status_badge.dart';
import '../../../core/widgets/empty_state.dart';
import '../../pre_start_checks/presentation/pre_start_visuals.dart';
import '../../../core/widgets/choice_list.dart';
import '../../../core/widgets/color_choice_chips.dart';
import '../../organizations/presentation/site_select_list.dart';

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
    this.projectRepository,
    this.siteRepository,
    this.activityRepository,
  });

  final Organization organization;

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real dependencies scoped to [organization].
  final SafetyRequirementRepository? repository;
  final SafetyRequirementAdminService? adminService;
  final SafetyLearningRepository? learningRepository;
  final ProjectRepository? projectRepository;
  final SiteRepository? siteRepository;
  final ActivityRepository? activityRepository;

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
  late final SafetyRequirementRepository _repository =
      widget.repository ??
      SafetyRequirementRepository(
        firestoreService: FirestoreService(),
        organizationId: widget.organization.id,
        safetyLearningRepository: _learningRepository,
      );
  late final SafetyRequirementAdminService _adminService =
      widget.adminService ?? SafetyRequirementAdminService();
  late final ProjectRepository _projectRepository =
      widget.projectRepository ??
      ProjectRepository(
        firestoreService: FirestoreService(),
        organizationId: widget.organization.id,
      );
  late final SiteRepository _siteRepository =
      widget.siteRepository ??
      SiteRepository(
        firestoreService: FirestoreService(),
        organizationId: widget.organization.id,
      );
  late final ActivityRepository _activityRepository =
      widget.activityRepository ??
      ActivityRepository(
        firestoreService: FirestoreService(),
        organizationId: widget.organization.id,
      );

  String? _errorMessage;
  bool _isSaving = false;

  Future<void> _openCreateDialog(
    List<SafetyLearning> learningItems,
    List<Project> projects,
    List<Site> sites,
    List<Activity> activities,
  ) async {
    final result = await Navigator.of(context, rootNavigator: true)
        .push<_SafetyRequirementFormResult>(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => _SafetyRequirementFormDialog(
              learningItems: learningItems,
              projects: projects,
              sites: sites,
              activities: activities,
            ),
          ),
        );
    if (result == null || !mounted) return;
    await _save(
      () => _adminService.createSafetyRequirement(
        organizationId: widget.organization.id,
        name: result.name,
        category: result.category,
        risk: result.risk,
        description: result.description,
        requiredLearningIds: result.requiredLearningIds,
        status: result.status,
        learningSettings: result.learningSettings,
        projectId: result.projectId,
        siteId: result.siteId,
        activityId: result.activityId,
      ),
    );
  }

  Future<void> _openEditDialog(
    SafetyRequirement requirement,
    List<SafetyLearning> learningItems,
    List<Project> projects,
    List<Site> sites,
    List<Activity> activities,
  ) async {
    final result = await Navigator.of(context, rootNavigator: true)
        .push<_SafetyRequirementFormResult>(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => _SafetyRequirementFormDialog(
              existing: requirement,
              learningItems: learningItems,
              projects: projects,
              sites: sites,
              activities: activities,
            ),
          ),
        );
    if (result == null || !mounted) return;
    await _save(
      () => _adminService.updateSafetyRequirement(
        widget.organization.id,
        requirement.id,
        name: result.name,
        category: result.category,
        risk: result.risk,
        description: result.description,
        requiredLearningIds: result.requiredLearningIds,
        status: result.status,
        // Per-lesson settings are authoritative for every selected lesson;
        // the requirement-level flags are left untouched as the fallback for
        // older data.
        learningSettings: result.learningSettings,
        // Empty string clears the scope back to organization-wide — see
        // `SafetyRequirementAdminService.updateSafetyRequirement`'s doc
        // comment.
        projectId: result.projectId ?? '',
        siteId: result.siteId ?? '',
        activityId: result.activityId ?? '',
      ),
    );
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
    final canManageOrgContent =
        profile?.canManageOrgContent == true ||
        sessionController
                .membershipFor(widget.organization.id)
                ?.role
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

    return LiveStreamBuilder<List<SafetyLearning>>(
      streamKey: _learningRepository,
      stream: () => _learningRepository.watchAll(),
      builder: (context, learningSnapshot) {
        final learningItems = learningSnapshot.data ?? const [];
        return LiveStreamBuilder<List<Project>>(
          streamKey: _projectRepository,
          stream: () => _projectRepository.watchAll(),
          builder: (context, projectSnapshot) {
            final projects = projectSnapshot.data ?? const [];
            return LiveStreamBuilder<List<Site>>(
              streamKey: _siteRepository,
              stream: () => _siteRepository.watchAll(),
              builder: (context, siteSnapshot) {
                final sites = siteSnapshot.data ?? const [];
                return LiveStreamBuilder<List<Activity>>(
                  streamKey: _activityRepository,
                  stream: () => _activityRepository.watchAll(),
                  builder: (context, activitySnapshot) {
                    final activities = activitySnapshot.data ?? const [];
                    return _buildRequirementsList(
                      learningItems,
                      projects,
                      sites,
                      activities,
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildRequirementsList(
    List<SafetyLearning> learningItems,
    List<Project> projects,
    List<Site> sites,
    List<Activity> activities,
  ) {
    return LiveStreamBuilder<List<SafetyRequirement>>(
      streamKey: _repository,
      stream: () => _repository.watchAll(),
      builder: (context, snapshot) {
        final requirements = snapshot.data ?? const [];
        final isLoading = snapshot.connectionState == ConnectionState.waiting;
        final streamError = snapshot.hasError
            ? 'Could not load safety requirements. Please try again.'
            : null;
        final projectNamesById = {
          for (final project in projects) project.id: project.name,
        };
        final siteNamesById = {for (final site in sites) site.id: site.name};
        final activityNamesById = {
          for (final activity in activities) activity.id: activity.name,
        };

        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            FeatureHeader(
              title: 'Safety Requirements',
              subtitle: widget.organization.name,
              icon: Icons.rule,
              color: AppColors.hazards,
              chips: [
                for (final risk in SafetyRequirementRisk.values)
                  FeatureChip(
                    icon: Icons.warning_amber,
                    label:
                        '${requirements.where((r) => r.risk == risk).length} ${risk.label.toLowerCase()} risk',
                  ),
              ],
              footer: Tooltip(
                message: 'Add requirement',
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: AppColors.hazards,
                    minimumSize: const Size(0, AppSpacing.minTouchTarget),
                  ),
                  onPressed: _isSaving
                      ? null
                      : () => _openCreateDialog(
                          learningItems,
                          projects,
                          sites,
                          activities,
                        ),
                  icon: const Icon(Icons.add),
                  label: const Text('New Requirement'),
                ),
              ),
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
                child: EmptyState(
                  icon: Icons.rule,
                  title: 'No safety requirements yet.',
                ),
              ),
            for (final requirement in requirements) ...[
              _SafetyRequirementCard(
                requirement: requirement,
                learningItems: learningItems,
                scopeLabel: _scopeLabel(
                  requirement,
                  projectNamesById,
                  siteNamesById,
                  activityNamesById,
                ),
                onEdit: () => _openEditDialog(
                  requirement,
                  learningItems,
                  projects,
                  sites,
                  activities,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
            ],
          ],
        );
      },
    );
  }

  /// A short "Project: X" / "Site: X" / "Activity: X" label for
  /// [requirement]'s scope, or null when it applies organization-wide.
  String? _scopeLabel(
    SafetyRequirement requirement,
    Map<String, String> projectNamesById,
    Map<String, String> siteNamesById,
    Map<String, String> activityNamesById,
  ) {
    final projectId = requirement.projectId;
    if (projectId != null) {
      return 'Project: ${projectNamesById[projectId] ?? projectId}';
    }
    final siteId = requirement.siteId;
    if (siteId != null) return 'Site: ${siteNamesById[siteId] ?? siteId}';
    final activityId = requirement.activityId;
    if (activityId != null) {
      return 'Activity: ${activityNamesById[activityId] ?? activityId}';
    }
    return null;
  }
}

/// High risk red, medium amber, low blue.
Color _riskColor(SafetyRequirementRisk risk) => switch (risk) {
  SafetyRequirementRisk.high => AppColors.stop,
  SafetyRequirementRisk.medium => AppColors.warning,
  SafetyRequirementRisk.low => AppColors.meetings,
};

class _SafetyRequirementCard extends StatelessWidget {
  const _SafetyRequirementCard({
    required this.requirement,
    required this.learningItems,
    required this.onEdit,
    this.scopeLabel,
  });

  final SafetyRequirement requirement;
  final List<SafetyLearning> learningItems;
  final String? scopeLabel;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final learningById = {for (final item in learningItems) item.id: item};
    final requiredTitles = [
      for (final id in requirement.requiredLearningIds)
        learningById[id]?.title ?? id,
    ];
    final lessonCount = requirement.requiredLearningIds.length;
    final gatingCount = requirement.requiredLearningIds
        .where(requirement.gatesAttendanceFor)
        .length;
    final preWorkCount = requirement.requiredLearningIds
        .where(requirement.requiredBeforeWorkFor)
        .length;
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: (_riskColor(requirement.risk)).withValues(alpha: 0.5),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                AccentIconBadge(
                  color: _riskColor(requirement.risk),
                  emoji: hazardEmojiFor(
                    '${requirement.name} ${requirement.category}',
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
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
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Align(
                alignment: Alignment.centerLeft,
                child: StatusBadge(
                  label: 'Risk: ${requirement.risk.label}',
                  color: _riskColor(requirement.risk),
                ),
              ),
            ),
            _DetailRow(
              icon: Icons.place_outlined,
              value: scopeLabel ?? 'Organization-wide',
            ),
            if (lessonCount > 0) ...[
              _DetailRow(
                icon: Icons.block_outlined,
                value:
                    'Blocks attendance: $gatingCount of $lessonCount '
                    '${lessonCount == 1 ? 'lesson' : 'lessons'}',
              ),
              _DetailRow(
                icon: Icons.construction_outlined,
                value:
                    'Before work: $preWorkCount of $lessonCount '
                    '${lessonCount == 1 ? 'lesson' : 'lessons'}',
              ),
            ],
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
    required this.learningSettings,
    this.description,
    this.projectId,
    this.siteId,
    this.activityId,
  });

  final String name;
  final String category;
  final SafetyRequirementRisk risk;
  final String? description;
  final List<String> requiredLearningIds;
  final OrganizationRecordStatus status;

  /// One entry per selected lesson — always complete, both flags set.
  final Map<String, RequirementLearningSetting> learningSettings;

  /// Null means organization-wide — see [SafetyRequirement]'s doc comment.
  final String? projectId;
  final String? siteId;
  final String? activityId;
}

/// The four mutually-exclusive scope choices a requirement's form offers —
/// mirrors [SafetyRequirement]'s doc comment on
/// `projectId`/`siteId`/`activityId`.
enum _RequirementScopeKind { organizationWide, project, site, activity }

class _SafetyRequirementFormDialog extends StatefulWidget {
  const _SafetyRequirementFormDialog({
    required this.learningItems,
    required this.projects,
    required this.sites,
    required this.activities,
    this.existing,
  });

  final SafetyRequirement? existing;
  final List<SafetyLearning> learningItems;
  final List<Project> projects;
  final List<Site> sites;
  final List<Activity> activities;

  @override
  State<_SafetyRequirementFormDialog> createState() =>
      _SafetyRequirementFormDialogState();
}

class _SafetyRequirementFormDialogState
    extends State<_SafetyRequirementFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _nameController = TextEditingController(
    text: widget.existing?.name,
  );
  late final _categoryController = TextEditingController(
    text: widget.existing?.category,
  );
  late final _descriptionController = TextEditingController(
    text: widget.existing?.description,
  );
  late SafetyRequirementRisk _risk =
      widget.existing?.risk ?? SafetyRequirementRisk.medium;
  late OrganizationRecordStatus _status =
      widget.existing?.status ?? OrganizationRecordStatus.active;
  late final Set<String> _selectedLearningIds = {
    ...?widget.existing?.requiredLearningIds,
  };

  /// Per-lesson settings for the selected lessons. An existing requirement
  /// pre-fills each lesson with its EFFECTIVE setting (its own entry, else
  /// the requirement-level fallback), so opening and saving an older
  /// requirement unchanged keeps its behavior exactly. A newly ticked
  /// lesson starts with both off — the Admin opts it in deliberately.
  late final Set<String> _gatingLearningIds = {
    ...?widget.existing?.requiredLearningIds.where(
      widget.existing!.gatesAttendanceFor,
    ),
  };
  late final Set<String> _preWorkLearningIds = {
    ...?widget.existing?.requiredLearningIds.where(
      widget.existing!.requiredBeforeWorkFor,
    ),
  };

  late _RequirementScopeKind _scopeKind = widget.existing?.projectId != null
      ? _RequirementScopeKind.project
      : widget.existing?.siteId != null
      ? _RequirementScopeKind.site
      : widget.existing?.activityId != null
      ? _RequirementScopeKind.activity
      : _RequirementScopeKind.organizationWide;
  late String? _scopedProjectId = widget.existing?.projectId;
  late String? _scopedSiteId = widget.existing?.siteId;
  late String? _scopedActivityId = widget.existing?.activityId;

  /// Active projects, plus the currently-selected one even if it has since
  /// gone inactive — an inactive scope shouldn't be silently offerable to
  /// pick again, but a requirement already scoped to it must still show
  /// that choice selected rather than an orphaned/blank dropdown value.
  List<Project> get _activeProjects => [
    for (final project in widget.projects)
      if (project.status == OrganizationRecordStatus.active ||
          project.id == _scopedProjectId)
        project,
  ];

  List<Site> get _activeSites => [
    for (final site in widget.sites)
      if (site.status == OrganizationRecordStatus.active ||
          site.id == _scopedSiteId)
        site,
  ];

  List<Activity> get _activeActivities => [
    for (final activity in widget.activities)
      if (activity.status == OrganizationRecordStatus.active ||
          activity.id == _scopedActivityId)
        activity,
  ];

  /// "Site name (Project name)" — disambiguates same-named sites across
  /// different projects, since [Site]/[Activity] names have no
  /// organization-wide uniqueness guarantee.
  /// The project a site/activity belongs to — its detail line in a
  /// [ChoiceList].
  String? _projectName(String projectId) => widget.projects
      .where((project) => project.id == projectId)
      .firstOrNull
      ?.name;

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
    final actions = <Widget>[
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
              learningSettings: {
                for (final id in _selectedLearningIds)
                  id: RequirementLearningSetting(
                    gatesAttendance: _gatingLearningIds.contains(id),
                    requiredBeforeWork: _preWorkLearningIds.contains(id),
                  ),
              },
              projectId: _scopeKind == _RequirementScopeKind.project
                  ? _scopedProjectId
                  : null,
              siteId: _scopeKind == _RequirementScopeKind.site
                  ? _scopedSiteId
                  : null,
              activityId: _scopeKind == _RequirementScopeKind.activity
                  ? _scopedActivityId
                  : null,
            ),
          );
        },
        child: Text(isEditing ? 'Save' : 'Create'),
      ),
    ];
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: SizedBox(
            width: 420,
            child: Form(
              key: _formKey,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FeatureHeader(
                      eyebrow: isEditing
                          ? 'Edit requirement'
                          : 'New requirement',
                      title: _nameController.text.trim().isEmpty
                          ? 'Safety Requirement'
                          : _nameController.text.trim(),
                      icon: Icons.rule,
                      color: _riskColor(_risk),
                      chips: [
                        FeatureChip(
                          icon: Icons.warning_amber,
                          label: '${_risk.label} risk',
                        ),
                        FeatureChip(
                          icon: Icons.school,
                          label:
                              '${_selectedLearningIds.length} '
                              '${_selectedLearningIds.length == 1 ? 'lesson' : 'lessons'}',
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.md),
                    FormSection(
                      title: 'About this requirement',
                      icon: Icons.edit_note,
                      color: AppColors.meetings,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextFormField(
                            controller: _nameController,
                            decoration: const InputDecoration(
                              labelText: 'Name',
                            ),
                            onChanged: (_) => setState(() {}),
                            autofillHints: const [],
                            validator: (value) =>
                                (value == null || value.trim().isEmpty)
                                ? 'A name is required.'
                                : null,
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          TextFormField(
                            controller: _categoryController,
                            decoration: const InputDecoration(
                              labelText: 'Category',
                            ),
                            autofillHints: const [],
                            validator: (value) =>
                                (value == null || value.trim().isEmpty)
                                ? 'A category is required.'
                                : null,
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          TextFormField(
                            controller: _descriptionController,
                            decoration: const InputDecoration(
                              labelText: 'Description',
                            ),
                            maxLines: 2,
                            autofillHints: const [],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    const SizedBox(height: AppSpacing.sm),
                    FormSection(
                      title: 'Risk and status',
                      icon: Icons.priority_high,
                      color: _riskColor(_risk),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ChoiceList<SafetyRequirementRisk>(
                            label: 'Risk',
                            selected: _risk,
                            onChanged: (value) {
                              if (value != null) setState(() => _risk = value);
                            },
                            items: [
                              for (final risk in SafetyRequirementRisk.values)
                                ChoiceItem(
                                  value: risk,
                                  title: risk.label,
                                  color: _riskColor(risk),
                                  icon: switch (risk) {
                                    SafetyRequirementRisk.high =>
                                      Icons.dangerous,
                                    SafetyRequirementRisk.medium =>
                                      Icons.warning,
                                    SafetyRequirementRisk.low => Icons.info,
                                  },
                                ),
                            ],
                            allowDeselect: false,
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          ChoiceList<OrganizationRecordStatus>(
                            label: 'Status',
                            selected: _status,
                            onChanged: (value) {
                              if (value != null) {
                                setState(() => _status = value);
                              }
                            },
                            items: const [
                              ChoiceItem(
                                value: OrganizationRecordStatus.active,
                                title: 'Active',
                                color: AppColors.success,
                                icon: Icons.check_circle,
                              ),
                              ChoiceItem(
                                value: OrganizationRecordStatus.inactive,
                                title: 'Inactive',
                                color: AppColors.textSecondary,
                                icon: Icons.pause_circle,
                              ),
                            ],
                            allowDeselect: false,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    const SizedBox(height: AppSpacing.md),
                    FormSection(
                      title: 'Where it applies',
                      icon: Icons.place,
                      color: AppColors.projects,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ChoiceList<_RequirementScopeKind>(
                            label: 'Applies to',
                            items: const [
                              ChoiceItem(
                                value: _RequirementScopeKind.organizationWide,
                                title: 'Whole organization',
                                icon: Icons.domain,
                              ),
                              ChoiceItem(
                                value: _RequirementScopeKind.project,
                                title: 'One project',
                                icon: Icons.apartment,
                              ),
                              ChoiceItem(
                                value: _RequirementScopeKind.site,
                                title: 'One site',
                                icon: Icons.location_city,
                              ),
                              ChoiceItem(
                                value: _RequirementScopeKind.activity,
                                title: 'One activity',
                                icon: Icons.construction,
                              ),
                            ],
                            selected: _scopeKind,
                            allowDeselect: false,
                            onChanged: (value) {
                              if (value == null) return;
                              setState(() {
                                _scopeKind = value;
                                _scopedProjectId = null;
                                _scopedSiteId = null;
                                _scopedActivityId = null;
                              });
                            },
                          ),
                          if (_scopeKind == _RequirementScopeKind.project) ...[
                            const SizedBox(height: AppSpacing.sm),
                            ChoiceList<String>(
                              label: 'Project',
                              items: [
                                for (final project in _activeProjects)
                                  projectChoice(project),
                              ],
                              selected: _scopedProjectId,
                              searchHint: 'Search projects',
                              validator: (value) =>
                                  value == null ? 'Choose a project.' : null,
                              onChanged: (value) =>
                                  setState(() => _scopedProjectId = value),
                            ),
                          ],
                          if (_scopeKind == _RequirementScopeKind.site) ...[
                            const SizedBox(height: AppSpacing.sm),
                            ChoiceList<String>(
                              label: 'Site',
                              items: [
                                for (final site in _activeSites)
                                  ChoiceItem(
                                    value: site.id,
                                    title: site.name,
                                    badge: site.code.isNotEmpty
                                        ? site.code
                                        : null,
                                    subtitle: _projectName(site.projectId),
                                  ),
                              ],
                              selected: _scopedSiteId,
                              searchHint:
                                  'Search sites by name, code or project',
                              validator: (value) =>
                                  value == null ? 'Choose a site.' : null,
                              onChanged: (value) =>
                                  setState(() => _scopedSiteId = value),
                            ),
                          ],
                          if (_scopeKind == _RequirementScopeKind.activity) ...[
                            const SizedBox(height: AppSpacing.sm),
                            ChoiceList<String>(
                              label: 'Activity',
                              items: [
                                for (final activity in _activeActivities)
                                  ChoiceItem(
                                    value: activity.id,
                                    title: activity.name,
                                    icon: Icons.construction,
                                    subtitle: _projectName(activity.projectId),
                                  ),
                              ],
                              selected: _scopedActivityId,
                              searchHint: 'Search activities',
                              validator: (value) =>
                                  value == null ? 'Choose an activity.' : null,
                              onChanged: (value) =>
                                  setState(() => _scopedActivityId = value),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    const SizedBox(height: AppSpacing.md),
                    FormSection(
                      title: 'Required Learning',
                      icon: Icons.school,
                      color: AppColors.learning,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(top: AppSpacing.xs),
                            child: Text(
                              'Tick each lesson this requirement needs, then choose '
                              'how urgent it is. These settings apply to the lesson '
                              'within this requirement only — they do not change the '
                              'lesson in the Safety Learning Library.',
                              style: AppTextStyles.bodyMedium,
                            ),
                          ),
                          if (widget.learningItems.isEmpty)
                            const Padding(
                              padding: EdgeInsets.symmetric(
                                vertical: AppSpacing.sm,
                              ),
                              child: Text(
                                'No safety learning items exist yet.',
                                style: AppTextStyles.bodyMedium,
                              ),
                            ),
                          for (final (index, item)
                              in widget.learningItems.indexed) ...[
                            ChoiceTile(
                              multi: true,
                              title: item.title,
                              subtitle: item.type.label,
                              icon: Icons.school,
                              color: choicePaletteColor(index),
                              selected: _selectedLearningIds.contains(item.id),
                              onTap: () {
                                setState(() {
                                  if (!_selectedLearningIds.remove(item.id)) {
                                    _selectedLearningIds.add(item.id);
                                  } else {
                                    _gatingLearningIds.remove(item.id);
                                    _preWorkLearningIds.remove(item.id);
                                  }
                                });
                              },
                            ),
                            const SizedBox(height: AppSpacing.xs + 2),
                            if (_selectedLearningIds.contains(item.id))
                              Padding(
                                padding: const EdgeInsets.only(
                                  left: AppSpacing.xl,
                                ),
                                child: Column(
                                  children: [
                                    SwitchListTile(
                                      key: Key('blocks-attendance-${item.id}'),
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                      value: _gatingLearningIds.contains(
                                        item.id,
                                      ),
                                      title: const Text('Blocks attendance'),
                                      subtitle: const Text(
                                        'Must be completed before the worker can be '
                                        'marked Present at the Daily Safety Meeting.',
                                      ),
                                      onChanged: (on) => setState(() {
                                        if (on) {
                                          _gatingLearningIds.add(item.id);
                                        } else {
                                          _gatingLearningIds.remove(item.id);
                                        }
                                      }),
                                    ),
                                    SwitchListTile(
                                      key: Key(
                                        'required-before-work-${item.id}',
                                      ),
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                      value: _preWorkLearningIds.contains(
                                        item.id,
                                      ),
                                      title: const Text('Required before work'),
                                      subtitle: const Text(
                                        'Must be completed before performing the '
                                        'activity.',
                                      ),
                                      onChanged: (on) => setState(() {
                                        if (on) {
                                          _preWorkLearningIds.add(item.id);
                                        } else {
                                          _preWorkLearningIds.remove(item.id);
                                        }
                                      }),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              for (final (index, action) in actions.indexed) ...[
                if (index > 0) const SizedBox(width: AppSpacing.sm),
                Expanded(child: action),
              ],
            ],
          ),
        ),
      ),
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
    return StatusBadge(label: status.label, color: color);
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
