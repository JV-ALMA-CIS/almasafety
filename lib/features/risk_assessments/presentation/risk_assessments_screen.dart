import 'aha_pdf.dart';
import '../../../core/reports/report_context.dart';
import '../../../core/reports/pdf_report.dart';
import 'package:flutter/material.dart';
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
import '../../authentication/domain/app_role.dart';
import '../../activities/domain/activity.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../../organizations/data/site_repository.dart';
import '../data/risk_assessment_repository.dart';
import '../data/risk_assessment_service.dart';
import '../domain/risk_assessment.dart';
import '../domain/standard_ahas.dart';
import 'risk_assessment_editor_screen.dart';
import 'risk_assessment_style.dart';
import '../../../core/widgets/mobile_title.dart';

/// The "Risk Assessments (AHA)" page — the Safety Plan's Activity Hazard
/// Analyses (Section 10): one per phase / feature of work.
///
/// Everyone sees the accepted AHAs for their own sites (the crew must know
/// the hazards and controls of their work). Site Managers/Admins also see
/// drafts and earlier revisions, prepare new AHAs (from the plan's standard
/// drafts or blank), and accept each other's.
class RiskAssessmentsScreen extends StatefulWidget {
  const RiskAssessmentsScreen({
    super.key,
    this.repository,
    this.service,
    this.siteRepository,
    this.loadActivities,
  });

  /// Injected in tests.
  final RiskAssessmentRepository? repository;
  final RiskAssessmentService? service;
  final SiteRepository? siteRepository;
  final SiteActivitiesLoader? loadActivities;

  @override
  State<RiskAssessmentsScreen> createState() => _RiskAssessmentsScreenState();
}

class _RiskAssessmentsScreenState extends State<RiskAssessmentsScreen> {
  RiskAssessmentRepository? _repository;
  bool _showEarlier = false;

  RiskAssessmentRepository _repositoryFor(String organizationId) {
    final existing = _repository;
    if (existing != null && existing.organizationId == organizationId) {
      return existing;
    }
    return _repository =
        widget.repository ??
        RiskAssessmentRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );
  }

  Future<void> _prepare(
    String organizationId,
    List<RiskAssessment> copyable,
  ) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    final start = await navigator.push<AhaContent>(
      MaterialPageRoute(builder: (_) => _ChooseStartScreen(copyable: copyable)),
    );
    if (start == null || !mounted) return;
    final id = await navigator.push<String>(
      MaterialPageRoute(
        builder: (_) => RiskAssessmentEditorScreen(
          organizationId: organizationId,
          initial: start,
          service: widget.service,
          siteRepository: widget.siteRepository,
          loadActivities: widget.loadActivities,
        ),
      ),
    );
    if (id != null && mounted) _open(organizationId, id);
  }

  void _open(String organizationId, String id) {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => RiskAssessmentDetailScreen(
          organizationId: organizationId,
          id: id,
          repository: _repositoryFor(organizationId),
          service: widget.service,
          siteRepository: widget.siteRepository,
          loadActivities: widget.loadActivities,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final organizationId = session.activeOrganizationId;
    final role = session.activeMembership?.role;
    final isManager =
        (session.profile?.isPlatformAdministrator ?? false) ||
        role == AppRole.admin ||
        role == AppRole.siteManager;
    final mySiteIds = session.activeMembership?.siteIds ?? const <String>[];

    if (organizationId == null) {
      return const Center(child: Text('No organization selected.'));
    }

    final repository = _repositoryFor(organizationId);
    return LiveStreamBuilder<List<RiskAssessment>>(
      streamKey: organizationId,
      stream: () => repository.watchAll(),
      builder: (context, snapshot) {
        final all = [
          for (final aha in snapshot.data ?? const <RiskAssessment>[])
            if (isManager ||
                (aha.status == RiskAssessmentStatus.accepted &&
                    mySiteIds.contains(aha.siteId)))
              aha,
        ];
        final inUse = all
            .where((a) => a.status == RiskAssessmentStatus.accepted)
            .toList();
        final drafts = all
            .where((a) => a.status == RiskAssessmentStatus.draft)
            .toList();
        final earlier = all
            .where((a) => a.status == RiskAssessmentStatus.superseded)
            .toList();
        final loading =
            snapshot.connectionState == ConnectionState.waiting &&
            snapshot.data == null;

        Widget cards(List<RiskAssessment> list) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final aha in list) ...[
              RiskAssessmentCard(
                assessment: aha,
                onTap: () => _open(organizationId, aha.id),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
          ],
        );

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
                title: 'Risk Assessments (AHA)',
                subtitle:
                    'Activity Hazard Analyses: the hazards of each phase of '
                    'work and how they are controlled. Read the one for your '
                    'work before you start.',
                icon: Icons.assignment_late,
                color: AppColors.riskAssessments,
                chips: [
                  FeatureChip(
                    icon: Icons.verified,
                    label: '${inUse.length} in use',
                  ),
                  if (isManager)
                    FeatureChip(
                      icon: Icons.edit_note,
                      label:
                          '${drafts.length} draft'
                          '${drafts.length == 1 ? '' : 's'}',
                    ),
                ],
              ),
              if (snapshot.hasError) ...[
                const SizedBox(height: AppSpacing.md),
                const Text(
                  'Could not load the risk assessments. Please try again.',
                  style: AppTextStyles.bodyMedium,
                ),
              ],
              if (loading)
                const Padding(
                  padding: EdgeInsets.all(AppSpacing.xl),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (!loading && all.isEmpty) ...[
                const SizedBox(height: AppSpacing.md),
                EmptyState(
                  icon: Icons.assignment_late,
                  title: 'No risk assessments yet',
                  message: isManager
                      ? 'Tap "Prepare AHA" to start one for a site\'s work — '
                            'paste your own into a blank form, copy another '
                            'AHA, or start from a library draft.'
                      : 'Your Site Manager has not published a risk '
                            'assessment for your site yet.',
                ),
              ],
              if (drafts.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.md),
                FeatureSectionTitle(
                  title: 'Drafts — waiting to be accepted',
                  icon: Icons.edit_note,
                  color: AppColors.warning,
                  count: drafts.length,
                ),
                const SizedBox(height: AppSpacing.sm),
                cards(drafts),
              ],
              if (inUse.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.md),
                FeatureSectionTitle(
                  title: 'In use',
                  icon: Icons.verified,
                  color: AppColors.go,
                  count: inUse.length,
                ),
                const SizedBox(height: AppSpacing.sm),
                cards(inUse),
              ],
              if (earlier.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.sm),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () =>
                        setState(() => _showEarlier = !_showEarlier),
                    icon: Icon(
                      _showEarlier ? Icons.expand_less : Icons.history,
                    ),
                    label: Text(
                      _showEarlier
                          ? 'Hide earlier revisions'
                          : 'Show ${earlier.length} earlier '
                                'revision${earlier.length == 1 ? '' : 's'}',
                    ),
                  ),
                ),
                if (_showEarlier) cards(earlier),
              ],
            ],
          ),
          floatingActionButton: isManager
              ? FloatingActionButton.extended(
                  heroTag: 'prepare-aha',
                  backgroundColor: AppColors.riskAssessments,
                  foregroundColor: Colors.white,
                  onPressed: () =>
                      _prepare(organizationId, [...inUse, ...drafts]),
                  icon: const Icon(Icons.add),
                  label: const Text('Prepare AHA'),
                )
              : null,
        );
      },
    );
  }
}

/// One AHA in a list.
class RiskAssessmentCard extends StatelessWidget {
  const RiskAssessmentCard({super.key, required this.assessment, this.onTap});

  final RiskAssessment assessment;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final aha = assessment;
    return AccentCard(
      color: AppColors.riskAssessments,
      icon: Icons.assignment_late,
      title: aha.featureOfWork,
      onTap: onTap,
      dimmed: aha.status == RiskAssessmentStatus.superseded,
      badges: [
        AccentBadge(label: aha.status.label, color: aha.status.color),
        AccentBadge(
          label: 'Rev ${aha.revision}',
          color: AppColors.textSecondary,
        ),
      ],
      details: [
        AccentDetail(icon: Icons.location_city, text: aha.siteName ?? 'Site'),
        AccentDetail(
          icon: Icons.format_list_numbered,
          text:
              '${aha.steps.length} step${aha.steps.length == 1 ? '' : 's'} · '
              '${aha.hazardCount} hazard${aha.hazardCount == 1 ? '' : 's'}',
        ),
        if (aha.acceptedByName != null)
          AccentDetail(
            icon: Icons.verified,
            text:
                'Accepted by ${aha.acceptedByName} · '
                '${formatAhaDate(aha.acceptedAt)}',
          )
        else if (aha.preparedByName != null)
          AccentDetail(
            icon: Icons.person_outline,
            text: 'Prepared by ${aha.preparedByName}',
          ),
      ],
    );
  }
}

/// Where a new AHA starts from: a blank form, a copy of an existing AHA
/// (any site, accepted or draft), or a starting draft from the library.
/// Pops the chosen [AhaContent].
class _ChooseStartScreen extends StatefulWidget {
  const _ChooseStartScreen({required this.copyable});

  /// AHAs (any site, accepted or draft) that can be copied as a start.
  final List<RiskAssessment> copyable;

  @override
  State<_ChooseStartScreen> createState() => _ChooseStartScreenState();
}

/// One choice on [_ChooseStartScreen].
class _StartOption {
  const _StartOption({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.content,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final AhaContent content;
}

class _ChooseStartScreenState extends State<_ChooseStartScreen> {
  int? _choice;

  @override
  Widget build(BuildContext context) {
    final options = <_StartOption>[
      const _StartOption(
        title: 'Blank form',
        subtitle: 'For any kind of work — or paste your own AHA into it',
        icon: Icons.note_add_outlined,
        color: AppColors.textSecondary,
        content: AhaContent(featureOfWork: ''),
      ),
      for (final aha in widget.copyable)
        _StartOption(
          title: 'Copy: ${aha.featureOfWork} (${aha.siteName ?? 'a site'})',
          subtitle:
              '${aha.status == RiskAssessmentStatus.draft ? 'Draft' : 'In use'}'
              ' · revision ${aha.revision} · ${aha.steps.length} steps — '
              'adjust it for the site',
          icon: Icons.copy_all,
          color: AppColors.riskAssessments,
          content: copyAhaContent(aha),
        ),
      for (final draft in standardAhas)
        _StartOption(
          title: '${draft.content.featureOfWork} — ${draft.label}',
          subtitle: '${draft.source} · ${draft.content.steps.length} steps',
          icon: Icons.menu_book_outlined,
          color: AppColors.projects,
          content: draft.content,
        ),
    ];
    return Scaffold(
      appBar: AppBar(title: const MobileTitle('Prepare an AHA')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          const FeatureHeader(
            title: 'Prepare an AHA',
            subtitle:
                'Start from a blank form (and paste your own AHA), a copy of '
                'an existing AHA, or a starting draft from the library — '
                'then adjust it for the site.',
            icon: Icons.assignment_late,
            color: AppColors.riskAssessments,
          ),
          const SizedBox(height: AppSpacing.md),
          ChoiceList<int>(
            items: [
              for (var i = 0; i < options.length; i++)
                ChoiceItem(
                  value: i,
                  title: options[i].title,
                  subtitle: options[i].subtitle,
                  icon: options[i].icon,
                  color: options[i].color,
                ),
            ],
            selected: _choice,
            searchHint: 'Search AHAs and drafts',
            onChanged: (i) => setState(() => _choice = i),
          ),
          const SizedBox(height: AppSpacing.lg),
          SizedBox(
            height: AppSpacing.minTouchTarget,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.riskAssessments,
                foregroundColor: Colors.white,
              ),
              onPressed: _choice == null
                  ? null
                  : () => Navigator.of(context).pop(options[_choice!].content),
              icon: const Icon(Icons.arrow_forward),
              label: const Text('Continue'),
            ),
          ),
        ],
      ),
    );
  }
}

/// One AHA laid out like the plan's form: details, each principal step with
/// its hazards (red) and controls (green), equipment, inspection and
/// training requirements, and who prepared and accepted it. Site
/// Managers/Admins edit, accept, discard or revise it from here.
class RiskAssessmentDetailScreen extends StatefulWidget {
  const RiskAssessmentDetailScreen({
    super.key,
    required this.organizationId,
    required this.id,
    required this.repository,
    this.service,
    this.siteRepository,
    this.loadActivities,
    this.printReport,
  });

  final String organizationId;
  final String id;
  final RiskAssessmentRepository repository;
  final RiskAssessmentService? service;
  final SiteRepository? siteRepository;
  final SiteActivitiesLoader? loadActivities;

  /// Injected in tests; defaults to the device's print window.
  final ReportPrinter? printReport;

  @override
  State<RiskAssessmentDetailScreen> createState() =>
      _RiskAssessmentDetailScreenState();
}

class _RiskAssessmentDetailScreenState
    extends State<RiskAssessmentDetailScreen> {
  late final RiskAssessmentService _service =
      widget.service ?? RiskAssessmentService();
  late String _id = widget.id;
  bool _isBusy = false;
  bool _isPrinting = false;
  String? _activitiesSiteId;
  Future<List<Activity>>? _activities;

  Future<List<Activity>> _activitiesFor(String siteId) {
    if (_activitiesSiteId != siteId || _activities == null) {
      _activitiesSiteId = siteId;
      _activities = (widget.loadActivities ?? loadSiteActivities)(
        widget.organizationId,
        siteId,
      ).catchError((Object _) => const <Activity>[]);
    }
    return _activities!;
  }

  String? _errorMessage;

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _isBusy = true;
      _errorMessage = null;
    });
    try {
      await action();
    } on AppException catch (e) {
      if (mounted) setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _edit(RiskAssessment aha) async {
    await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => RiskAssessmentEditorScreen(
          organizationId: widget.organizationId,
          existing: aha,
          service: widget.service,
          siteRepository: widget.siteRepository,
          loadActivities: widget.loadActivities,
        ),
      ),
    );
  }

  Future<void> _accept(RiskAssessment aha) async {
    final result = await showDialog<(String?, String?)>(
      context: context,
      builder: (_) => _AcceptDialog(featureOfWork: aha.featureOfWork),
    );
    if (result == null) return;
    await _run(
      () => _service.accept(
        organizationId: widget.organizationId,
        id: aha.id,
        corName: result.$1,
        note: result.$2,
      ),
    );
  }

  Future<void> _discard(RiskAssessment aha) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard this draft?'),
        content: Text('"${aha.featureOfWork}" will be deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.stop),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(() async {
      await _service.discardDraft(
        organizationId: widget.organizationId,
        id: aha.id,
      );
      if (mounted) Navigator.of(context).pop();
    });
  }

  /// Prints the AHA (or saves it as PDF) in the Safety Plan's form layout.
  Future<void> _print(RiskAssessment aha) async {
    setState(() => _isPrinting = true);
    try {
      final organizationName = await organizationNameFor(widget.organizationId);
      final activities = aha.activityIds.isEmpty
          ? const <Activity>[]
          : await _activitiesFor(aha.siteId);
      final names = {for (final a in activities) a.id: a.name};
      await (widget.printReport ?? PdfReport.printDocument)(
        name:
            'AHA - ${aha.featureOfWork} - ${aha.siteName ?? 'site'} - '
            'rev ${aha.revision}',
        build: (format) => buildAhaPdf(
          aha: aha,
          organizationName: organizationName,
          activityNames: [for (final id in aha.activityIds) ?names[id]],
          format: format,
        ),
      );
    } on Object {
      if (mounted) {
        setState(() => _errorMessage = 'Could not prepare the PDF. Try again.');
      }
    } finally {
      if (mounted) setState(() => _isPrinting = false);
    }
  }

  Future<void> _revise(RiskAssessment aha) async {
    await _run(() async {
      final id = await _service.revise(
        organizationId: widget.organizationId,
        id: aha.id,
      );
      if (mounted) setState(() => _id = id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final uid = session.profile?.uid;
    final role = session.activeMembership?.role;
    final isManager =
        (session.profile?.isPlatformAdministrator ?? false) ||
        role == AppRole.admin ||
        role == AppRole.siteManager;

    return Scaffold(
      appBar: AppBar(title: const MobileTitle('AHA Details')),
      body: LiveStreamBuilder<RiskAssessment?>(
        streamKey: _id,
        stream: () => widget.repository.watch(_id),
        builder: (context, snapshot) {
          final aha = snapshot.data;
          if (aha == null) {
            return Center(
              child: snapshot.connectionState == ConnectionState.waiting
                  ? const CircularProgressIndicator()
                  : const Text('This risk assessment is no longer available.'),
            );
          }
          final missing = aha.missingForAcceptance;
          final isPreparer = aha.preparedByUid == uid;

          return ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.xl,
            ),
            children: [
              FeatureHeader(
                eyebrow: 'Activity Hazard Analysis',
                title: aha.featureOfWork,
                subtitle: aha.activity,
                icon: Icons.assignment_late,
                color: AppColors.riskAssessments,
                chips: [
                  FeatureChip(icon: aha.status.icon, label: aha.status.label),
                  FeatureChip(
                    icon: Icons.history,
                    label: 'Revision ${aha.revision}',
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, AppSpacing.minTouchTarget),
                  ),
                  onPressed: _isPrinting ? null : () => _print(aha),
                  icon: _isPrinting
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.print),
                  label: const Text('Print / PDF'),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              AccentCard(
                color: AppColors.projects,
                icon: Icons.info_outline,
                title: 'Details',
                details: [
                  AccentDetail(
                    icon: Icons.location_city,
                    text: 'Site: ${aha.siteName ?? '—'}',
                  ),
                  if (aha.activityIds.isEmpty)
                    const AccentDetail(
                      icon: Icons.handyman,
                      text: 'Covers: all work at this site',
                    ),
                  if (aha.location != null)
                    AccentDetail(
                      icon: Icons.place_outlined,
                      text: 'Location: ${aha.location}',
                    ),
                  if (aha.contractNo != null)
                    AccentDetail(
                      icon: Icons.description_outlined,
                      text: 'Contract No.: ${aha.contractNo}',
                    ),
                  AccentDetail(
                    icon: Icons.event,
                    text: 'Estimated start: ${aha.estimatedStartDate ?? '—'}',
                  ),
                ],
              ),
              if (aha.activityIds.isNotEmpty)
                FutureBuilder<List<Activity>>(
                  future: _activitiesFor(aha.siteId),
                  builder: (context, snapshot) {
                    final names = {
                      for (final a in snapshot.data ?? const <Activity>[])
                        a.id: a.name,
                    };
                    return Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.sm),
                      child: Text(
                        'Covers: '
                        '${aha.activityIds.map((id) => names[id] ?? 'an activity').join(', ')}',
                        style: AppTextStyles.bodyLarge,
                      ),
                    );
                  },
                ),
              if (_errorMessage != null) ...[
                const SizedBox(height: AppSpacing.md),
                AuthErrorBanner(message: _errorMessage!),
              ],
              if (isManager) ...[
                const SizedBox(height: AppSpacing.md),
                _Actions(
                  assessment: aha,
                  isPreparer: isPreparer,
                  missing: missing,
                  busy: _isBusy,
                  onEdit: () => _edit(aha),
                  onAccept: () => _accept(aha),
                  onDiscard: () => _discard(aha),
                  onRevise: () => _revise(aha),
                  onOpenRevision: () =>
                      setState(() => _id = aha.revisionDraftId!),
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
              FeatureSectionTitle(
                title: 'Principal steps',
                icon: Icons.format_list_numbered,
                color: AppColors.riskAssessments,
                count: aha.steps.length,
              ),
              for (var i = 0; i < aha.steps.length; i++) ...[
                const SizedBox(height: AppSpacing.sm),
                _StepView(number: i + 1, step: aha.steps[i]),
              ],
              const SizedBox(height: AppSpacing.lg),
              _ListSection(
                title: 'Equipment to be used',
                icon: Icons.handyman,
                lines: aha.equipment,
              ),
              _ListSection(
                title: 'Inspection requirements',
                icon: Icons.fact_check,
                lines: aha.inspectionRequirements,
              ),
              _ListSection(
                title: 'Training requirements',
                icon: Icons.school,
                lines: aha.trainingRequirements,
              ),
              AccentCard(
                color: aha.status.color,
                icon: Icons.draw,
                title: 'Prepared and accepted',
                details: [
                  AccentDetail(
                    icon: Icons.person_outline,
                    text:
                        'Prepared by ${aha.preparedByName ?? '—'} · '
                        '${formatAhaDate(aha.updatedAt ?? aha.createdAt)}',
                  ),
                  AccentDetail(
                    icon: Icons.verified,
                    text: aha.acceptedByName == null
                        ? 'Not accepted yet'
                        : 'Accepted by ${aha.acceptedByName} · '
                              '${formatAhaDate(aha.acceptedAt)}',
                  ),
                  if (aha.corName != null)
                    AccentDetail(
                      icon: Icons.badge_outlined,
                      text: 'Reviewed by COR: ${aha.corName}',
                    ),
                  if (aha.acceptanceNote != null)
                    AccentDetail(icon: Icons.notes, text: aha.acceptanceNote!),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// What a Site Manager/Admin can do with the AHA in its current state.
class _Actions extends StatelessWidget {
  const _Actions({
    required this.assessment,
    required this.isPreparer,
    required this.missing,
    required this.busy,
    required this.onEdit,
    required this.onAccept,
    required this.onDiscard,
    required this.onRevise,
    required this.onOpenRevision,
  });

  final RiskAssessment assessment;
  final bool isPreparer;
  final List<String> missing;
  final bool busy;
  final VoidCallback onEdit;
  final VoidCallback onAccept;
  final VoidCallback onDiscard;
  final VoidCallback onRevise;
  final VoidCallback onOpenRevision;

  @override
  Widget build(BuildContext context) {
    final aha = assessment;
    switch (aha.status) {
      case RiskAssessmentStatus.draft:
        final String? acceptHint = missing.isNotEmpty
            ? 'Before it can be accepted, add ${missing.join(', ')}.'
            : isPreparer
            ? 'You prepared this draft, so another Site Manager or Admin '
                  'must accept it.'
            : null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.go,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: busy || acceptHint != null ? null : onAccept,
                  icon: const Icon(Icons.verified),
                  label: const Text('Accept'),
                ),
                OutlinedButton.icon(
                  onPressed: busy ? null : onEdit,
                  icon: const Icon(Icons.edit),
                  label: const Text('Edit'),
                ),
                TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: AppColors.stop),
                  onPressed: busy ? null : onDiscard,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Discard'),
                ),
              ],
            ),
            if (acceptHint != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(acceptHint, style: AppTextStyles.bodyMedium),
            ],
          ],
        );
      case RiskAssessmentStatus.accepted:
        return Align(
          alignment: Alignment.centerLeft,
          child: aha.revisionDraftId != null
              ? OutlinedButton.icon(
                  onPressed: onOpenRevision,
                  icon: const Icon(Icons.edit_note),
                  label: const Text('Open the revision being prepared'),
                )
              : OutlinedButton.icon(
                  onPressed: busy ? null : onRevise,
                  icon: const Icon(Icons.edit_note),
                  label: const Text('Start a revision'),
                ),
        );
      case RiskAssessmentStatus.superseded:
        return const Text(
          'This revision has been replaced. The newer one is under "In use".',
          style: AppTextStyles.bodyMedium,
        );
    }
  }
}

class _StepView extends StatelessWidget {
  const _StepView({required this.number, required this.step});

  final int number;
  final AhaStep step;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.riskAssessments.withValues(alpha: 0.4),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sm + 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: AppColors.riskAssessments,
                  child: Text(
                    '$number',
                    style: AppTextStyles.label.copyWith(color: Colors.white),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    step.step,
                    style: AppTextStyles.bodyLarge.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            _Bullets(
              label: 'Hazards',
              icon: Icons.warning_amber,
              color: ahaHazardColor,
              lines: step.hazards,
            ),
            const SizedBox(height: AppSpacing.sm),
            _Bullets(
              label: 'Controls',
              icon: Icons.shield_outlined,
              color: ahaControlColor,
              lines: step.controls,
            ),
          ],
        ),
      ),
    );
  }
}

class _Bullets extends StatelessWidget {
  const _Bullets({
    required this.label,
    required this.icon,
    required this.color,
    required this.lines,
  });

  final String label;
  final IconData icon;
  final Color color;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: AppSpacing.xs),
            Text(
              label,
              style: AppTextStyles.label.copyWith(
                color: color,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        if (lines.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: AppSpacing.xs),
            child: Text('None listed yet', style: AppTextStyles.bodyMedium),
          ),
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 7),
                  child: Icon(Icons.circle, size: 7, color: color),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: Text(line, style: AppTextStyles.bodyLarge)),
              ],
            ),
          ),
      ],
    );
  }
}

class _ListSection extends StatelessWidget {
  const _ListSection({
    required this.title,
    required this.icon,
    required this.lines,
  });

  final String title;
  final IconData icon;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: _Bullets(
        label: title,
        icon: icon,
        color: AppColors.riskAssessments,
        lines: lines,
      ),
    );
  }
}

/// Accepting an AHA: optionally the COR who reviewed it and a note. Pops
/// `(corName, note)`.
class _AcceptDialog extends StatefulWidget {
  const _AcceptDialog({required this.featureOfWork});

  final String featureOfWork;

  @override
  State<_AcceptDialog> createState() => _AcceptDialogState();
}

class _AcceptDialogState extends State<_AcceptDialog> {
  final _cor = TextEditingController();
  final _note = TextEditingController();

  @override
  void dispose() {
    _cor.dispose();
    _note.dispose();
    super.dispose();
  }

  String? _value(TextEditingController controller) {
    final text = controller.text.trim();
    return text.isEmpty ? null : text;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Accept "${widget.featureOfWork}"?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'It becomes part of the Safety Plan and is shown to the crews '
              'of this site. It cannot be edited afterwards — changes are '
              'made as a new revision.',
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _cor,
              decoration: const InputDecoration(
                labelText: 'Reviewed by COR (optional)',
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _note,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Note (optional)'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop((_value(_cor), _value(_note))),
          child: const Text('Accept'),
        ),
      ],
    );
  }
}
