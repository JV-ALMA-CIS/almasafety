import 'package:flutter/material.dart';
import 'site_emergency_contacts.dart';
import '../../../core/widgets/live_stream_builder.dart';
import '../../../core/widgets/choice_list.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/empty_state.dart';
import '../../../routing/app_routes.dart';
import '../../authentication/domain/app_role.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../data/organization_admin_service.dart';
import '../data/site_repository.dart';
import '../domain/organization.dart';
import '../domain/organization_record_status.dart';
import '../domain/project.dart';
import '../domain/site.dart';
import '../../../core/widgets/accent_card.dart';
import '../../../core/widgets/feature_header.dart';
import '../../../core/widgets/color_choice_chips.dart';

/// Lists the sites belonging to one project. A System Administrator (any
/// organization) or an [AppRole.siteManager] of THIS organization may
/// create or edit sites — `createSite`/`updateSite` both use
/// `requireOrganizationScopedManager` server-side
/// (`organization_callable.ts`), so Create/Edit are gated on [canManage]
/// here exactly like [ProjectsScreen], NOT on [isPlatformAdministrator]
/// alone. Worker assignment (`assignWorkerToSite`/`removeWorkerFromSite`)
/// uses the same authorization — see [AppRoutes.manageSiteWorkers].
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
  late final SiteRepository _repository =
      widget.repository ??
      SiteRepository(
        firestoreService: FirestoreService(),
        organizationId: widget.organization.id,
      );
  late final OrganizationAdminService _adminService =
      widget.adminService ?? OrganizationAdminService();

  String? _errorMessage;
  bool _isSaving = false;

  Future<void> _openCreateDialog() async {
    final result = await Navigator.of(context, rootNavigator: true)
        .push<_SiteFormResult>(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => const _SiteFormDialog(),
          ),
        );
    if (result == null || !mounted) return;
    await _save(
      () => _adminService.createSite(
        organizationId: widget.organization.id,
        projectId: widget.project.id,
        name: result.name,
        code: result.code,
        location: result.location,
        description: result.description,
        status: result.status,
      ),
    );
  }

  Future<void> _openEditDialog(Site site) async {
    final result = await Navigator.of(context, rootNavigator: true)
        .push<_SiteFormResult>(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => _SiteFormDialog(existing: site),
          ),
        );
    if (result == null || !mounted) return;
    await _save(
      () => _adminService.updateSite(
        widget.organization.id,
        site.id,
        name: result.name,
        code: result.code,
        location: result.location,
        description: result.description,
        status: result.status,
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
    final isPlatformAdministrator = profile?.isPlatformAdministrator ?? false;
    // Checked against membershipFor(widget.organization.id) SPECIFICALLY,
    // not activeMembership — see ProjectsScreen's matching comment for why.
    final canManage =
        isPlatformAdministrator ||
        sessionController
                .membershipFor(widget.organization.id)
                ?.role
                .canManageOrgContent ==
            true;

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

    return LiveStreamBuilder<List<Site>>(
      streamKey: (_repository, widget.project.id),
      stream: () => _repository.watchByProject(widget.project.id),
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
            FeatureHeader(
              title: 'Sites',
              subtitle: '${widget.organization.name} · ${widget.project.name}',
              icon: Icons.location_city,
              color: AppColors.analytics,
              chips: [
                FeatureChip(
                  icon: Icons.check_circle,
                  label:
                      '${sites.where((s) => s.status == OrganizationRecordStatus.active).length} active',
                ),
                FeatureChip(icon: Icons.place, label: '${sites.length} total'),
              ],
              footer: canManage
                  ? ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: AppColors.analytics,
                        minimumSize: const Size(0, AppSpacing.minTouchTarget),
                      ),
                      onPressed: _isSaving ? null : _openCreateDialog,
                      icon: const Icon(Icons.add),
                      label: const Text('Add Site'),
                    )
                  : null,
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
              EmptyState(
                icon: Icons.location_city_outlined,
                title: 'No sites yet',
                message: canManage
                    ? 'Create a site to start assigning workers.'
                    : null,
                action: canManage
                    ? ElevatedButton.icon(
                        onPressed: _isSaving ? null : _openCreateDialog,
                        icon: const Icon(Icons.add),
                        label: const Text('Add Site'),
                      )
                    : null,
              ),
            for (final site in sites) ...[
              _SiteCard(
                site: site,
                onEdit: canManage ? () => _openEditDialog(site) : null,
                onEmergency: canManage
                    ? () => openSiteEmergencyEditor(
                        context,
                        organizationId: widget.organization.id,
                        site: site,
                      )
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
    this.onEmergency,
    required this.onEdit,
    required this.onViewActivities,
    required this.onViewWorkers,
  });

  final Site site;

  /// Opens the site's emergency contacts editor; null hides it.
  final VoidCallback? onEmergency;

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
    final active = site.status == OrganizationRecordStatus.active;
    return AccentCard(
      color: active ? AppColors.analytics : AppColors.textSecondary,
      icon: Icons.location_city,
      title: site.name,
      dimmed: !active,
      badges: [
        AccentBadge(
          label: site.status.label,
          color: active ? AppColors.success : AppColors.textSecondary,
        ),
      ],
      details: [
        AccentDetail(icon: Icons.qr_code, text: site.code),
        if (site.location != null)
          AccentDetail(icon: Icons.place, text: site.location!),
        if (site.description != null)
          AccentDetail(icon: Icons.description, text: site.description!),
        AccentDetail(
          icon: Icons.emergency,
          text: site.emergency == null
              ? 'No emergency contacts yet'
              : 'Emergency contacts set',
        ),
      ],
      actions: [
        if (onEdit != null)
          AccentButton(
            label: 'Edit',
            icon: Icons.edit,
            color: AppColors.analytics,
            outlined: true,
            onPressed: onEdit,
          ),
        if (onEmergency != null)
          AccentButton(
            label: site.emergency == null ? 'Add emergency' : 'Emergency',
            icon: Icons.emergency,
            color: AppColors.stop,
            outlined: true,
            onPressed: onEmergency,
          ),
        AccentButton(
          label: 'Activities',
          icon: Icons.engineering,
          color: AppColors.projects,
          outlined: true,
          onPressed: onViewActivities,
        ),
        AccentButton(
          label: 'Workers',
          icon: Icons.groups,
          color: AppColors.people,
          onPressed: onViewWorkers,
        ),
      ],
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
  late final _nameController = TextEditingController(
    text: widget.existing?.name,
  );
  late final _codeController = TextEditingController(
    text: widget.existing?.code,
  );
  late final _locationController = TextEditingController(
    text: widget.existing?.location,
  );
  late final _descriptionController = TextEditingController(
    text: widget.existing?.description,
  );
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
    final actions = <Widget>[
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
    ];
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: SingleChildScrollView(
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FeatureHeader(
                    eyebrow: isEditing ? 'Edit' : 'New',
                    title: _nameController.text.trim().isEmpty
                        ? 'Site'
                        : _nameController.text.trim(),
                    icon: Icons.location_city,
                    color: AppColors.analytics,
                    chips: [
                      FeatureChip(
                        icon: Icons.place,
                        label: _locationController.text.trim().isEmpty
                            ? 'No location yet'
                            : _locationController.text.trim(),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  FormSection(
                    title: 'About this site',
                    icon: Icons.edit_note,
                    color: AppColors.analytics,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextFormField(
                          controller: _nameController,
                          onChanged: (_) => setState(() {}),
                          decoration: const InputDecoration(labelText: 'Name'),
                          autofillHints: const [],
                          validator: (value) =>
                              (value == null || value.trim().isEmpty)
                              ? 'A name is required.'
                              : null,
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        TextFormField(
                          controller: _codeController,
                          decoration: const InputDecoration(labelText: 'Code'),
                          autofillHints: const [],
                          validator: (value) =>
                              (value == null || value.trim().isEmpty)
                              ? 'A code is required.'
                              : null,
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        TextFormField(
                          controller: _locationController,
                          decoration: const InputDecoration(
                            labelText: 'Location',
                          ),
                          autofillHints: const [],
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
                  ChoiceList<OrganizationRecordStatus>(
                    label: 'Status',
                    selected: _status,
                    onChanged: (value) {
                      if (value != null) setState(() => _status = value);
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
