import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/accent_card.dart';
import '../../../core/widgets/choice_list.dart';
import '../../../core/widgets/empty_state.dart';
import '../../../core/widgets/feature_header.dart';
import '../../../core/widgets/live_stream_builder.dart';
import '../../../routing/app_routes.dart';
import '../../authentication/domain/app_role.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../../organizations/data/site_repository.dart';
import '../../organizations/presentation/report_site_picker.dart';
import '../data/inspection_repository.dart';
import '../data/inspection_service.dart';
import '../domain/inspection.dart';
import 'deficiency_log_screen.dart';
import 'inspection_run_screen.dart';
import 'inspection_style.dart';
import 'inspection_templates_screen.dart';

/// The "Inspections" page — the Safety Plan's daily site inspections and
/// weekly HSE walk-downs (Section 7).
///
/// For Foremen (their own sites) and Site Managers/Admins (every site):
/// start an inspection, resume your own in-progress ones, and see recent
/// results. Site Managers/Admins also sign off submitted inspections (the
/// Safety Manager's review — never their own), manage the checklists, and
/// open the Deficiency Log.
class InspectionsScreen extends StatefulWidget {
  const InspectionsScreen({
    super.key,
    this.repository,
    this.service,
    this.siteRepository,
  });

  /// Injected in tests.
  final InspectionRepository? repository;
  final InspectionService? service;
  final SiteRepository? siteRepository;

  @override
  State<InspectionsScreen> createState() => _InspectionsScreenState();
}

class _InspectionsScreenState extends State<InspectionsScreen> {
  InspectionRepository? _repository;
  late final InspectionService _service = widget.service ?? InspectionService();
  bool _isInstalling = false;
  String? _errorMessage;

  InspectionRepository _repositoryFor(String organizationId) {
    final existing = _repository;
    if (existing != null && existing.organizationId == organizationId) {
      return existing;
    }
    return _repository =
        widget.repository ??
        InspectionRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );
  }

  Future<void> _install(String organizationId) async {
    setState(() {
      _isInstalling = true;
      _errorMessage = null;
    });
    try {
      await _service.installDefaultTemplates(organizationId);
    } on AppException catch (e) {
      if (mounted) setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isInstalling = false);
    }
  }

  Future<void> _start(
    String organizationId,
    List<InspectionTemplate> templates,
  ) async {
    final repository = _repositoryFor(organizationId);
    final id = await Navigator.of(context, rootNavigator: true).push<String>(
      MaterialPageRoute(
        builder: (_) => _StartInspectionScreen(
          organizationId: organizationId,
          templates: templates.where((t) => t.isActive).toList(),
          service: _service,
          siteRepository: widget.siteRepository,
        ),
      ),
    );
    if (id == null || !mounted) return;
    await _openRun(organizationId, id, repository);
  }

  Future<void> _openRun(
    String organizationId,
    String inspectionId,
    InspectionRepository repository,
  ) async {
    final submitted = await Navigator.of(context, rootNavigator: true)
        .push<bool>(
          MaterialPageRoute(
            builder: (_) => InspectionRunScreen(
              organizationId: organizationId,
              inspectionId: inspectionId,
              repository: repository,
              service: _service,
            ),
          ),
        );
    if (submitted == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Inspection submitted for sign-off.')),
      );
    }
  }

  void _openDetail(
    String organizationId,
    Inspection inspection,
    bool canSignOff,
  ) {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => InspectionDetailScreen(
          organizationId: organizationId,
          inspectionId: inspection.id,
          repository: _repositoryFor(organizationId),
          service: _service,
          canSignOff: canSignOff,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final organizationId = session.activeOrganizationId;
    final uid = session.profile?.uid;
    final role = session.activeMembership?.role;
    final isPlatformAdmin = session.profile?.isPlatformAdministrator ?? false;
    final isManager =
        isPlatformAdmin || role == AppRole.admin || role == AppRole.siteManager;
    final isForeman = role == AppRole.foreman;
    final mySiteIds = session.activeMembership?.siteIds ?? const <String>[];

    if (organizationId == null || uid == null || !(isManager || isForeman)) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: Text(
            'Inspections are carried out by Foremen and Site Managers.',
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final repository = _repositoryFor(organizationId);
    return LiveStreamBuilder<List<InspectionTemplate>>(
      streamKey: organizationId,
      stream: () => repository.watchTemplates(),
      builder: (context, templateSnapshot) {
        final templates = templateSnapshot.data ?? const <InspectionTemplate>[];
        return LiveStreamBuilder<List<Inspection>>(
          streamKey: organizationId,
          stream: () => repository.watchInspections(),
          builder: (context, snapshot) {
            final all = [
              for (final inspection in snapshot.data ?? const <Inspection>[])
                if (isManager || mySiteIds.contains(inspection.siteId))
                  inspection,
            ];
            final mine = all
                .where(
                  (i) =>
                      i.inspectorUid == uid &&
                      i.status == InspectionStatus.inProgress,
                )
                .toList();
            final toSignOff = all
                .where((i) => i.status == InspectionStatus.submitted)
                .toList();
            final recent = all
                .where((i) => i.status != InspectionStatus.inProgress)
                .take(20)
                .toList();
            final loading =
                snapshot.connectionState == ConnectionState.waiting &&
                snapshot.data == null;

            return Scaffold(
              body: ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.md,
                  AppSpacing.md,
                  96,
                ),
                children: [
                  FeatureHeader(
                    title: 'Inspections',
                    subtitle:
                        'Daily site inspections and weekly HSE walk-downs, '
                        'with deficiencies tracked until fixed.',
                    icon: Icons.fact_check,
                    color: AppColors.inspections,
                    chips: [
                      FeatureChip(
                        icon: Icons.edit_note,
                        label: '${mine.length} in progress',
                      ),
                      FeatureChip(
                        icon: Icons.hourglass_top,
                        label: '${toSignOff.length} awaiting sign-off',
                      ),
                    ],
                  ),
                  if (isManager) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Wrap(
                      spacing: AppSpacing.sm,
                      runSpacing: AppSpacing.sm,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () =>
                              Navigator.of(context, rootNavigator: true).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => InspectionTemplatesScreen(
                                    organizationId: organizationId,
                                    repository: repository,
                                    service: _service,
                                    siteRepository: widget.siteRepository,
                                  ),
                                ),
                              ),
                          icon: const Icon(Icons.checklist),
                          label: const Text('Checklists'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () =>
                              Navigator.of(context, rootNavigator: true).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => DeficiencyLogScreen(
                                    organizationId: organizationId,
                                  ),
                                ),
                              ),
                          icon: const Icon(Icons.list_alt),
                          label: const Text('Deficiency Log'),
                        ),
                      ],
                    ),
                  ],
                  if (_errorMessage != null) ...[
                    const SizedBox(height: AppSpacing.md),
                    AuthErrorBanner(message: _errorMessage!),
                  ],
                  if (templateSnapshot.hasData && templates.isEmpty) ...[
                    const SizedBox(height: AppSpacing.md),
                    EmptyState(
                      icon: Icons.checklist,
                      title: 'No checklists yet',
                      message: isManager
                          ? 'Install the standard checklists from the Safety '
                                'Plan: the daily site inspection and the '
                                'weekly HSE walk-down. You can edit them '
                                'afterwards.'
                          : 'Ask your Site Manager to set up the inspection '
                                'checklists.',
                      action: isManager
                          ? FilledButton.icon(
                              onPressed: _isInstalling
                                  ? null
                                  : () => _install(organizationId),
                              icon: const Icon(Icons.download),
                              label: const Text('Install standard checklists'),
                            )
                          : null,
                    ),
                  ],
                  if (loading)
                    const Padding(
                      padding: EdgeInsets.all(AppSpacing.xl),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  if (mine.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.md),
                    FeatureSectionTitle(
                      title: 'Your inspections in progress',
                      icon: Icons.edit_note,
                      color: AppColors.warning,
                      count: mine.length,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    for (final inspection in mine) ...[
                      InspectionCard(
                        inspection: inspection,
                        action: 'Continue',
                        onTap: () =>
                            _openRun(organizationId, inspection.id, repository),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                    ],
                  ],
                  if (toSignOff.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.md),
                    FeatureSectionTitle(
                      title: 'Awaiting sign-off',
                      icon: Icons.hourglass_top,
                      color: AppColors.analytics,
                      count: toSignOff.length,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    for (final inspection in toSignOff) ...[
                      InspectionCard(
                        inspection: inspection,
                        action: isManager && inspection.inspectorUid != uid
                            ? 'Review & sign off'
                            : null,
                        onTap: () => _openDetail(
                          organizationId,
                          inspection,
                          isManager && inspection.inspectorUid != uid,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                    ],
                  ],
                  const SizedBox(height: AppSpacing.md),
                  FeatureSectionTitle(
                    title: 'Recent inspections',
                    icon: Icons.history,
                    color: AppColors.inspections,
                    count: recent.length,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  if (!loading && recent.isEmpty)
                    const Text(
                      'No inspections submitted yet.',
                      style: AppTextStyles.bodyMedium,
                    ),
                  for (final inspection in recent) ...[
                    InspectionCard(
                      inspection: inspection,
                      onTap: () => _openDetail(
                        organizationId,
                        inspection,
                        isManager && inspection.inspectorUid != uid,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                ],
              ),
              floatingActionButton: templates.any((t) => t.isActive)
                  ? FloatingActionButton.extended(
                      heroTag: 'start-inspection',
                      backgroundColor: AppColors.inspections,
                      foregroundColor: Colors.white,
                      onPressed: () => _start(organizationId, templates),
                      icon: const Icon(Icons.playlist_add_check),
                      label: const Text('Start inspection'),
                    )
                  : null,
            );
          },
        );
      },
    );
  }
}

/// One inspection in a list: checklist, site, who and when, status and
/// score.
class InspectionCard extends StatelessWidget {
  const InspectionCard({
    super.key,
    required this.inspection,
    this.onTap,
    this.action,
  });

  final Inspection inspection;
  final VoidCallback? onTap;

  /// A button label, e.g. "Continue" or "Review & sign off".
  final String? action;

  @override
  Widget build(BuildContext context) {
    final inProgress = inspection.status == InspectionStatus.inProgress;
    return AccentCard(
      color: inspection.kind.color,
      icon: inspection.kind.icon,
      title: inspection.templateName,
      onTap: onTap,
      badges: [
        AccentBadge(
          label: inspection.status.label,
          color: inspection.status.color,
        ),
        if (!inProgress && inspection.notOkCount > 0)
          AccentBadge(
            label:
                '${inspection.notOkCount} '
                'deficienc${inspection.notOkCount == 1 ? 'y' : 'ies'}',
            color: AppColors.stop,
          ),
      ],
      details: [
        AccentDetail(
          icon: Icons.location_city,
          text: inspection.siteName ?? 'Site',
        ),
        AccentDetail(
          icon: Icons.person_outline,
          text:
              '${inspection.inspectorName ?? 'Inspector'} · '
              '${formatInspectionDate(inspection.submittedAt ?? inspection.startedAt)}',
        ),
        AccentDetail(
          icon: Icons.checklist,
          text: inProgress
              ? '${inspection.answeredCount} / ${inspection.items.length} '
                    'answered'
              : '${inspection.okCount} OK · ${inspection.notOkCount} Not OK · '
                    '${inspection.naCount} N/A',
        ),
        if (inspection.signedOffByName != null)
          AccentDetail(
            icon: Icons.verified,
            text: 'Signed off by ${inspection.signedOffByName}',
          ),
      ],
      actions: [
        if (action != null)
          AccentButton(
            label: action!,
            icon: inProgress ? Icons.play_arrow : Icons.verified,
            color: AppColors.inspections,
            onPressed: onTap,
          ),
      ],
    );
  }
}

/// Picks the site and checklist, then starts the inspection.
class _StartInspectionScreen extends StatefulWidget {
  const _StartInspectionScreen({
    required this.organizationId,
    required this.templates,
    required this.service,
    this.siteRepository,
  });

  final String organizationId;
  final List<InspectionTemplate> templates;
  final InspectionService service;
  final SiteRepository? siteRepository;

  @override
  State<_StartInspectionScreen> createState() => _StartInspectionScreenState();
}

class _StartInspectionScreenState extends State<_StartInspectionScreen> {
  String? _siteId;
  String? _templateId;
  bool _isStarting = false;
  String? _errorMessage;

  Future<void> _start() async {
    final siteId = _siteId;
    final templateId = _templateId;
    if (siteId == null || templateId == null) return;
    setState(() {
      _isStarting = true;
      _errorMessage = null;
    });
    try {
      final id = await widget.service.start(
        organizationId: widget.organizationId,
        siteId: siteId,
        templateId: templateId,
      );
      if (mounted) Navigator.of(context).pop(id);
    } on AppException catch (e) {
      if (mounted) setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isStarting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final siteIds = reportableSiteIds(
      isPlatformAdministrator:
          session.profile?.isPlatformAdministrator ?? false,
      role: session.activeMembership?.role,
      assignedSiteIds: session.activeMembership?.siteIds ?? const [],
    );
    return Scaffold(
      appBar: AppBar(),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          const FeatureHeader(
            title: 'Start an inspection',
            subtitle: 'Choose the site and the checklist.',
            icon: Icons.playlist_add_check,
            color: AppColors.inspections,
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: AppSpacing.md),
            AuthErrorBanner(message: _errorMessage!),
          ],
          const SizedBox(height: AppSpacing.md),
          const FeatureSectionTitle(
            title: 'Site',
            icon: Icons.location_city,
            color: AppColors.projects,
          ),
          const SizedBox(height: AppSpacing.sm),
          ReportSitePicker(
            organizationId: widget.organizationId,
            siteIds: siteIds,
            selectedSiteId: _siteId,
            onChanged: (id) => setState(() {
              _siteId = id;
              // A checklist not used at the newly chosen site is dropped.
              final chosen = widget.templates.where((t) => t.id == _templateId);
              if (id != null && chosen.any((t) => !t.isUsedAt(id))) {
                _templateId = null;
              }
            }),
            siteRepository: widget.siteRepository,
          ),
          const SizedBox(height: AppSpacing.md),
          const FeatureSectionTitle(
            title: 'Checklist',
            icon: Icons.checklist,
            color: AppColors.inspections,
          ),
          const SizedBox(height: AppSpacing.sm),
          ChoiceList<String>(
            items: [
              for (final template in widget.templates)
                if (_siteId == null || template.isUsedAt(_siteId!))
                  ChoiceItem(
                    value: template.id,
                    title: template.name,
                    subtitle:
                        '${template.kind.label} · ${template.itemCount} items',
                    icon: template.kind.icon,
                    color: template.kind.color,
                  ),
            ],
            selected: _templateId,
            onChanged: (id) => setState(() => _templateId = id),
          ),
          const SizedBox(height: AppSpacing.xl),
          SizedBox(
            height: AppSpacing.minTouchTarget,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.inspections,
                foregroundColor: Colors.white,
              ),
              onPressed: _siteId == null || _templateId == null || _isStarting
                  ? null
                  : _start,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Start'),
            ),
          ),
        ],
      ),
    );
  }
}

/// One inspection's result: score, every Not OK with its note and photo,
/// and the full checklist — plus sign-off for the Safety Manager.
class InspectionDetailScreen extends StatefulWidget {
  const InspectionDetailScreen({
    super.key,
    required this.organizationId,
    required this.inspectionId,
    required this.repository,
    required this.canSignOff,
    this.service,
  });

  final String organizationId;
  final String inspectionId;
  final InspectionRepository repository;

  /// A Site Manager/Admin who is not the inspector.
  final bool canSignOff;
  final InspectionService? service;

  @override
  State<InspectionDetailScreen> createState() => _InspectionDetailScreenState();
}

class _InspectionDetailScreenState extends State<InspectionDetailScreen> {
  late final InspectionService _service = widget.service ?? InspectionService();
  bool _isSaving = false;
  String? _errorMessage;

  Future<void> _signOff() async {
    final note = await showDialog<String>(
      context: context,
      builder: (_) => const _SignOffDialog(),
    );
    if (note == null) return;
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });
    try {
      await _service.signOff(
        organizationId: widget.organizationId,
        inspectionId: widget.inspectionId,
        note: note.isEmpty ? null : note,
      );
    } on AppException catch (e) {
      if (mounted) setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: LiveStreamBuilder<Inspection?>(
        streamKey: widget.inspectionId,
        stream: () => widget.repository.watchInspection(widget.inspectionId),
        builder: (context, snapshot) {
          final inspection = snapshot.data;
          if (inspection == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final failed = inspection.items
              .where((i) => i.result == InspectionResult.notOk)
              .toList();
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              FeatureHeader(
                eyebrow: inspection.kind.label,
                title: inspection.templateName,
                subtitle:
                    '${inspection.siteName ?? 'Site'} · '
                    '${inspection.inspectorName ?? 'Inspector'} · '
                    '${formatInspectionDate(inspection.submittedAt ?? inspection.startedAt)}',
                icon: inspection.kind.icon,
                color: AppColors.inspections,
                chips: [
                  FeatureChip(
                    icon: inspection.status.icon,
                    label: inspection.status.label,
                  ),
                  FeatureChip(
                    icon: Icons.check_circle,
                    label: '${inspection.okCount} OK',
                  ),
                  FeatureChip(
                    icon: Icons.cancel,
                    label: '${inspection.notOkCount} Not OK',
                  ),
                  FeatureChip(
                    icon: Icons.remove_circle_outline,
                    label: '${inspection.naCount} N/A',
                  ),
                ],
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: AppSpacing.md),
                AuthErrorBanner(message: _errorMessage!),
              ],
              if (inspection.signedOffByName != null) ...[
                const SizedBox(height: AppSpacing.md),
                AccentCard(
                  color: AppColors.success,
                  icon: Icons.verified,
                  title: 'Signed off by ${inspection.signedOffByName}',
                  body: inspection.signOffNote,
                  details: [
                    AccentDetail(
                      icon: Icons.event,
                      text: formatInspectionDate(inspection.signedOffAt),
                    ),
                  ],
                ),
              ],
              if (widget.canSignOff &&
                  inspection.status == InspectionStatus.submitted) ...[
                const SizedBox(height: AppSpacing.md),
                SizedBox(
                  height: AppSpacing.minTouchTarget,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.success,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: _isSaving ? null : _signOff,
                    icon: const Icon(Icons.verified),
                    label: const Text('Sign off'),
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              FeatureSectionTitle(
                title: 'Deficiencies',
                icon: Icons.report,
                color: AppColors.stop,
                count: failed.length,
              ),
              const SizedBox(height: AppSpacing.sm),
              if (failed.isEmpty)
                const Text(
                  'None — everything checked was OK.',
                  style: AppTextStyles.bodyMedium,
                ),
              for (final item in failed) ...[
                AccentCard(
                  color: AppColors.stop,
                  icon: Icons.cancel,
                  title: item.text,
                  body: item.note,
                  details: [
                    AccentDetail(icon: Icons.label_outline, text: item.section),
                    if (item.hazardId != null)
                      const AccentDetail(
                        icon: Icons.build_circle_outlined,
                        text:
                            'Tracked in Hazards until fixed (assign a '
                            'corrective action there).',
                      ),
                  ],
                  actions: [
                    if (item.photoUrl != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.network(
                          item.photoUrl!,
                          width: 120,
                          height: 120,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) =>
                              const SizedBox.shrink(),
                        ),
                      ),
                    if (item.hazardId != null)
                      AccentButton(
                        label: 'Open Hazards',
                        icon: Icons.warning_amber,
                        color: AppColors.hazards,
                        outlined: true,
                        onPressed: () {
                          Navigator.of(context).pop();
                          GoRouter.of(context).go(AppRoutes.hazards);
                        },
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
              ],
              const SizedBox(height: AppSpacing.md),
              FeatureSectionTitle(
                title: 'Full checklist',
                icon: Icons.checklist,
                color: AppColors.inspections,
                count: inspection.items.length,
              ),
              const SizedBox(height: AppSpacing.sm),
              for (final item in inspection.items)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Text(
                    item.result?.emoji ?? '·',
                    style: const TextStyle(fontSize: 20),
                  ),
                  title: Text(item.text),
                  subtitle: Text(item.section),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _SignOffDialog extends StatefulWidget {
  const _SignOffDialog();

  @override
  State<_SignOffDialog> createState() => _SignOffDialogState();
}

class _SignOffDialogState extends State<_SignOffDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Sign off inspection'),
      content: TextField(
        controller: _controller,
        minLines: 1,
        maxLines: 3,
        decoration: const InputDecoration(
          labelText: 'Comment (optional)',
          hintText: 'e.g. Reviewed — deficiencies assigned',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Sign off'),
        ),
      ],
    );
  }
}

String formatInspectionDate(DateTime? date) {
  if (date == null) return '—';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)} '
      '${two(date.hour)}:${two(date.minute)}';
}
