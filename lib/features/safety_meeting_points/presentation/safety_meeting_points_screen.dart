import 'package:flutter/material.dart';
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
import '../../organizations/domain/organization_record_status.dart';
import '../../organizations/domain/project.dart';
import '../data/safety_meeting_point_admin_service.dart';
import '../data/safety_meeting_point_repository.dart';
import '../domain/safety_meeting_point.dart';

/// The Safety Meeting Point library: lists an organization's meeting points
/// and lets an authorized manager create, edit, activate or deactivate one.
///
/// `canManage` gate — [AppRole.admin] (any organization) OR
/// [AppRole.siteManager] of the matching organization, the SAME shape as
/// [ProjectsScreen]/[SitesScreen] — see
/// `requireOrganizationScopedManager` in `safety_meeting_point_callable.ts`.
/// This is field-level, per-organization content a Site Manager prepares
/// for the Foremen they approve and manage at their own sites
/// (PROJECT_CONTEXT.md §12/§16) — deliberately NOT the same admin-only
/// shape as [SafetyLearningLibraryScreen]'s company-wide library, which an
/// office-based Admin who has never visited the site has no way to author.
/// There is no delete, matching every other record type here — an inactive
/// meeting point is retained so historical references keep referring to
/// something real.
///
/// Resolves its organization from the signed-in user's own active
/// organization when not supplied explicitly — see [organizationId].
class SafetyMeetingPointsScreen extends StatefulWidget {
  const SafetyMeetingPointsScreen({
    super.key,
    this.organizationId,
    this.repository,
    this.adminService,
    this.activityRepository,
    this.projectRepository,
  });

  /// The organization whose meeting points to show. When null, falls back to
  /// the signed-in user's own `organizationId`.
  final String? organizationId;

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real dependencies scoped to the resolved organization.
  final SafetyMeetingPointRepository? repository;
  final SafetyMeetingPointAdminService? adminService;

  /// Injected in tests. Backs the "Applicable activities" picker in the
  /// create/edit dialog and the card's id-to-name resolution — see
  /// [_activityRepositoryFor].
  final ActivityRepository? activityRepository;

  /// Injected in tests. Groups the "Applicable activities" picker by
  /// project, so a Site Manager running several projects at once can tell
  /// apart two activities that happen to share a name (e.g. "Excavation" at
  /// both Rosslyn Ridge and Italian Ambassador's Residence) instead of
  /// picking blind from one flat organization-wide list — see
  /// [_activityRepositoryFor].
  final ProjectRepository? projectRepository;

  @override
  State<SafetyMeetingPointsScreen> createState() =>
      _SafetyMeetingPointsScreenState();
}

class _SafetyMeetingPointsScreenState extends State<SafetyMeetingPointsScreen> {
  late final SafetyMeetingPointAdminService _adminService =
      widget.adminService ?? SafetyMeetingPointAdminService();

  SafetyMeetingPointRepository? _repository;
  ActivityRepository? _activityRepository;
  ProjectRepository? _projectRepository;
  String? _errorMessage;
  bool _isSaving = false;

  /// Builds (once per organization) the repository this screen streams from.
  SafetyMeetingPointRepository _repositoryFor(String organizationId) {
    final existing = _repository;
    if (existing != null && existing.organizationId == organizationId) {
      return existing;
    }
    final created =
        widget.repository ??
        SafetyMeetingPointRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );
    _repository = created;
    return created;
  }

  /// Builds (once per organization) the repository backing the "Applicable
  /// activities" picker below and the card's id-to-name resolution — the
  /// same organization-scoped `ActivityRepository.watchAll()` used
  /// elsewhere (e.g. `AdminDailySafetyMeetingsScreen`), not a second
  /// activity-listing path.
  ActivityRepository _activityRepositoryFor(String organizationId) {
    final existing = _activityRepository;
    if (existing != null && existing.organizationId == organizationId) {
      return existing;
    }
    final created =
        widget.activityRepository ??
        ActivityRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );
    _activityRepository = created;
    return created;
  }

  /// Builds (once) the repository backing the "Applicable activities"
  /// picker's project grouping — see [projectRepository]'s doc comment.
  /// Unlike the other `_xFor` builders here, [ProjectRepository] carries no
  /// `organizationId` getter to compare against, so this only ever builds
  /// once per screen instance — matching the fact that this screen's own
  /// `organizationId` never changes after the first build.
  ProjectRepository _projectRepositoryFor(String organizationId) {
    return _projectRepository ??=
        widget.projectRepository ??
        ProjectRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );
  }

  Future<void> _openCreateDialog(
    String organizationId,
    List<Activity> activities,
    List<Project> projects,
  ) async {
    final result = await showDialog<_SafetyMeetingPointFormResult>(
      context: context,
      builder: (_) => _SafetyMeetingPointFormDialog(
        activities: activities,
        projects: projects,
      ),
    );
    if (result == null || !mounted) return;
    await _save(
      () => _adminService.createSafetyMeetingPoint(
        organizationId: organizationId,
        title: result.title,
        category: result.category,
        description: result.description,
        applicableActivities: result.applicableActivities,
        applicableRisks: result.applicableRisks,
        status: result.status,
      ),
    );
  }

  Future<void> _openEditDialog(
    String organizationId,
    SafetyMeetingPoint point,
    List<Activity> activities,
    List<Project> projects,
  ) async {
    final result = await showDialog<_SafetyMeetingPointFormResult>(
      context: context,
      builder: (_) => _SafetyMeetingPointFormDialog(
        existing: point,
        activities: activities,
        projects: projects,
      ),
    );
    if (result == null || !mounted) return;
    await _save(
      () => _adminService.updateSafetyMeetingPoint(
        organizationId,
        point.id,
        title: result.title,
        category: result.category,
        description: result.description,
        applicableActivities: result.applicableActivities,
        applicableRisks: result.applicableRisks,
        status: result.status,
      ),
    );
  }

  Future<void> _toggleStatus(
    String organizationId,
    SafetyMeetingPoint point,
  ) => _save(
    () => point.isActive
        ? _adminService.deactivateSafetyMeetingPoint(organizationId, point.id)
        : _adminService.activateSafetyMeetingPoint(organizationId, point.id),
  );

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
    final organizationId =
        widget.organizationId ?? sessionController.activeOrganizationId;
    final isPlatformAdministrator = profile?.isPlatformAdministrator ?? false;
    // Admin (any organization) or a Site Manager of THIS organization —
    // field-level content a Site Manager prepares for their own Foremen,
    // see this class's own doc comment for why this is not the same
    // admin-only shape as the Safety Learning library. Checked against
    // membershipFor(organizationId) SPECIFICALLY, not activeMembership: a
    // Site Manager reaches this screen by navigating to one particular
    // organization's card (independent of which organization happens to
    // be "active" in the switcher), so a Site Manager of several
    // organizations must not be refused just because the one they tapped
    // into isn't the currently-active one.
    final canManage = isPlatformAdministrator ||
        (organizationId != null &&
            sessionController.membershipFor(organizationId)?.role
                    .canManageOrgContent ==
                true);

    if (!canManage || organizationId == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: Text(
            'You do not have permission to manage safety meeting points.',
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return StreamBuilder<List<Activity>>(
      stream: _activityRepositoryFor(organizationId).watchAll(),
      builder: (context, activitySnapshot) {
        final activities = activitySnapshot.data ?? const <Activity>[];

        return StreamBuilder<List<Project>>(
          stream: _projectRepositoryFor(organizationId).watchAll(),
          builder: (context, projectSnapshot) {
            final projects = projectSnapshot.data ?? const <Project>[];

            return StreamBuilder<List<SafetyMeetingPoint>>(
              stream: _repositoryFor(organizationId).watchAll(),
              builder: (context, snapshot) {
                final items = snapshot.data ?? const <SafetyMeetingPoint>[];
                final isLoading =
                    snapshot.connectionState == ConnectionState.waiting;
                final streamError = snapshot.hasError
                    ? 'Could not load safety meeting points. Please try '
                          'again.'
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
                                'Safety Meeting Points',
                                style: AppTextStyles.headlineMedium,
                              ),
                              const Text(
                                'Reusable topics and locations available '
                                "for this organization's safety meetings.",
                                style: AppTextStyles.bodyMedium,
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Add meeting point',
                          onPressed: _isSaving
                              ? null
                              : () => _openCreateDialog(
                                  organizationId,
                                  activities,
                                  projects,
                                ),
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
                        padding: EdgeInsets.symmetric(
                          vertical: AppSpacing.xl,
                        ),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    if (!isLoading && items.isEmpty && streamError == null)
                      const Padding(
                        padding: EdgeInsets.symmetric(
                          vertical: AppSpacing.xl,
                        ),
                        child: Text(
                          'No safety meeting points yet.',
                          style: AppTextStyles.bodyMedium,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    for (final item in items) ...[
                      _SafetyMeetingPointCard(
                        point: item,
                        isBusy: _isSaving,
                        activities: activities,
                        onEdit: () => _openEditDialog(
                          organizationId,
                          item,
                          activities,
                          projects,
                        ),
                        onToggleStatus: () =>
                            _toggleStatus(organizationId, item),
                      ),
                      const SizedBox(height: AppSpacing.md),
                    ],
                  ],
                );
              },
            );
          },
        );
      },
    );
  }
}

class _SafetyMeetingPointCard extends StatelessWidget {
  const _SafetyMeetingPointCard({
    required this.point,
    required this.isBusy,
    required this.activities,
    required this.onEdit,
    required this.onToggleStatus,
  });

  final SafetyMeetingPoint point;
  final bool isBusy;

  /// The organization's activities, used to resolve
  /// [SafetyMeetingPoint.applicableActivities] (a list of real activity
  /// document ids — see [_SafetyMeetingPointFormDialog]'s doc comment) to
  /// human-readable names for display, rather than showing raw ids.
  final List<Activity> activities;
  final VoidCallback onEdit;
  final VoidCallback onToggleStatus;

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
                  child: Text(point.title, style: AppTextStyles.titleLarge),
                ),
                _StatusChip(status: point.status),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            _DetailRow(icon: Icons.category_outlined, value: point.category),
            if (point.description != null)
              _DetailRow(
                icon: Icons.description_outlined,
                value: point.description!,
              ),
            if (point.applicableActivities.isNotEmpty)
              _DetailRow(
                icon: Icons.engineering_outlined,
                value:
                    'Activities: ${point.applicableActivities.map((id) {
                      final match = activities.where((a) => a.id == id);
                      return match.isEmpty ? id : match.first.name;
                    }).join(', ')}',
              ),
            if (point.applicableRisks.isNotEmpty)
              _DetailRow(
                icon: Icons.warning_amber_outlined,
                value: 'Risks: ${point.applicableRisks.join(', ')}',
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
                    onPressed: isBusy ? null : onEdit,
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
                    onPressed: isBusy ? null : onToggleStatus,
                    icon: Icon(
                      point.isActive
                          ? Icons.toggle_off_outlined
                          : Icons.toggle_on_outlined,
                    ),
                    label: Text(point.isActive ? 'Deactivate' : 'Activate'),
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

class _SafetyMeetingPointFormResult {
  const _SafetyMeetingPointFormResult({
    required this.title,
    required this.category,
    required this.status,
    required this.applicableActivities,
    required this.applicableRisks,
    this.description,
  });

  final String title;
  final String category;
  final String? description;
  final List<String> applicableActivities;
  final List<String> applicableRisks;
  final OrganizationRecordStatus status;
}

class _SafetyMeetingPointFormDialog extends StatefulWidget {
  const _SafetyMeetingPointFormDialog({
    required this.activities,
    required this.projects,
    this.existing,
  });

  final SafetyMeetingPoint? existing;

  /// The organization's activities, offered as a multi-select for
  /// "Applicable activities" — see [SafetyMeetingPointRepository.watchActive]
  /// and `DailySafetyMeetingScreen`'s recommendation logic, both of which
  /// compare [SafetyMeetingPoint.applicableActivities] against real
  /// [Activity.id] values, not names. A free-text field here previously let
  /// an administrator type an activity's `name` (its own helper text said
  /// "ids or names"), which the matching logic — id-only — would then never
  /// match, silently breaking recommendations for that point. This picker
  /// makes it impossible to store anything but a real activity id, the same
  /// "display name, store the Firestore document id" principle already
  /// applied to Organization selection during account approval.
  final List<Activity> activities;

  /// The organization's projects, used only to GROUP [activities] by
  /// project in the checklist below (a heading per project, its activities
  /// listed underneath) — an organization running several projects at once
  /// can have two activities that share a name (e.g. "Excavation" at both
  /// Rosslyn Ridge and Italian Ambassador's Residence, two different
  /// documents with different ids), and a flat unlabelled list gave no way
  /// to tell them apart. Stored, never written back — [_SafetyMeetingPointFormResult]
  /// still only carries activity ids.
  final List<Project> projects;

  @override
  State<_SafetyMeetingPointFormDialog> createState() =>
      _SafetyMeetingPointFormDialogState();
}

class _SafetyMeetingPointFormDialogState
    extends State<_SafetyMeetingPointFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _titleController = TextEditingController(
    text: widget.existing?.title,
  );
  late final _categoryController = TextEditingController(
    text: widget.existing?.category,
  );
  late final _descriptionController = TextEditingController(
    text: widget.existing?.description,
  );
  late final Set<String> _selectedActivityIds = {
    ...?widget.existing?.applicableActivities,
  };

  /// `applicableRisks` remains free text: unlike `applicableActivities`, no
  /// real "risk" document/collection exists anywhere in this codebase for
  /// it to reference, and no matching logic anywhere reads it — see
  /// [SafetyMeetingPoint]'s own doc comment. Introducing a picker for it
  /// would mean inventing a new schema this task's scope excludes.
  late final _risksController = TextEditingController(
    text: widget.existing?.applicableRisks.join(', '),
  );
  late OrganizationRecordStatus _status =
      widget.existing?.status ?? OrganizationRecordStatus.active;

  @override
  void dispose() {
    _titleController.dispose();
    _categoryController.dispose();
    _descriptionController.dispose();
    _risksController.dispose();
    super.dispose();
  }

  List<String> _parseCsv(String value) =>
      value.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

  /// Builds the "Applicable activities" checklist GROUPED by project — a
  /// heading per project (its activities listed underneath, sorted by
  /// name), plus a trailing "Other" group for any activity whose
  /// `projectId` matches no known [Project] (a project deleted/renamed out
  /// from under an existing activity — kept visible rather than silently
  /// dropped from the picker). See [_SafetyMeetingPointFormDialog.projects]'
  /// doc comment for why this grouping exists at all.
  List<Widget> _groupedActivityTiles() {
    final projectsById = {for (final p in widget.projects) p.id: p};
    final byProject = <String?, List<Activity>>{};
    for (final activity in widget.activities) {
      final projectId = projectsById.containsKey(activity.projectId)
          ? activity.projectId
          : null;
      (byProject[projectId] ??= []).add(activity);
    }

    final projectIds = byProject.keys.whereType<String>().toList()
      ..sort((a, b) => projectsById[a]!.name.compareTo(projectsById[b]!.name));

    final tiles = <Widget>[];
    for (final projectId in projectIds) {
      tiles.add(_ActivityGroupHeading(title: projectsById[projectId]!.name));
      tiles.addAll(_activityTilesFor(byProject[projectId]!));
    }
    final ungrouped = byProject[null];
    if (ungrouped != null && ungrouped.isNotEmpty) {
      tiles.add(const _ActivityGroupHeading(title: 'Other'));
      tiles.addAll(_activityTilesFor(ungrouped));
    }
    return tiles;
  }

  List<Widget> _activityTilesFor(List<Activity> activities) {
    final sorted = [...activities]..sort((a, b) => a.name.compareTo(b.name));
    return [
      for (final activity in sorted)
        CheckboxListTile(
          value: _selectedActivityIds.contains(activity.id),
          onChanged: (checked) => setState(() {
            if (checked ?? false) {
              _selectedActivityIds.add(activity.id);
            } else {
              _selectedActivityIds.remove(activity.id);
            }
          }),
          title: Text(activity.name),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          dense: true,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existing != null;
    return AlertDialog(
      title: Text(isEditing ? 'Edit Meeting Point' : 'Add Meeting Point'),
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
                  validator: (value) => (value == null || value.trim().isEmpty)
                      ? 'A title is required.'
                      : null,
                ),
                const SizedBox(height: AppSpacing.sm),
                TextFormField(
                  controller: _categoryController,
                  decoration: const InputDecoration(labelText: 'Category'),
                  validator: (value) => (value == null || value.trim().isEmpty)
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
                Text('Applicable activities', style: AppTextStyles.label),
                Text(
                  'Leave all unchecked to apply to every activity.',
                  style: AppTextStyles.bodyMedium,
                ),
                const SizedBox(height: AppSpacing.xs),
                if (widget.activities.isEmpty)
                  const Text(
                    'No activities exist yet in this organization.',
                    style: AppTextStyles.bodyMedium,
                  )
                else
                  ..._groupedActivityTiles(),
                const SizedBox(height: AppSpacing.sm),
                TextFormField(
                  controller: _risksController,
                  decoration: const InputDecoration(
                    labelText: 'Applicable risks',
                    helperText: 'Comma-separated risk ids or names.',
                  ),
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
              _SafetyMeetingPointFormResult(
                title: _titleController.text.trim(),
                category: _categoryController.text.trim(),
                description: description.isEmpty ? null : description,
                applicableActivities: _selectedActivityIds.toList(),
                applicableRisks: _parseCsv(_risksController.text),
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

/// A small project-name heading inside the "Applicable activities"
/// checklist — see [_SafetyMeetingPointFormDialogState._groupedActivityTiles].
class _ActivityGroupHeading extends StatelessWidget {
  const _ActivityGroupHeading({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: 2),
      child: Text(
        title,
        style: AppTextStyles.label.copyWith(color: AppColors.textSecondary),
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
