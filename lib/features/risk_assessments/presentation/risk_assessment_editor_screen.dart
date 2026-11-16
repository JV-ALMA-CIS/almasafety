import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/choice_list.dart';
import '../../../core/widgets/feature_header.dart';
import '../../activities/data/activity_admin_service.dart';
import '../../activities/domain/activity.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../../organizations/data/site_repository.dart';
import '../../organizations/presentation/report_site_picker.dart';
import '../data/risk_assessment_service.dart';
import '../domain/aha_text.dart';
import '../domain/risk_assessment.dart';
import 'risk_assessment_style.dart';
import '../../../core/widgets/mobile_title.dart';

/// Loads one site's activities. Injected in tests.
typedef SiteActivitiesLoader =
    Future<List<Activity>> Function(String organizationId, String siteId);

/// The default [SiteActivitiesLoader]: the `getSiteActivities` callable.
Future<List<Activity>> loadSiteActivities(
  String organizationId,
  String siteId,
) => ActivityAdminService().getSiteActivities(
  organizationId: organizationId,
  siteId: siteId,
);

/// Prepares an AHA: a new draft from [initial] (a standard draft or blank,
/// site chosen here) or edits the draft [existing]. Pops the draft's id once
/// saved.
///
/// Hazards, controls and the three lists are typed one per line — quicker on
/// a phone than a button per line, and what the paper form looks like.
class RiskAssessmentEditorScreen extends StatefulWidget {
  const RiskAssessmentEditorScreen({
    super.key,
    required this.organizationId,
    this.existing,
    this.initial,
    this.service,
    this.siteRepository,
    this.loadActivities,
  }) : assert(existing != null || initial != null);

  final String organizationId;
  final RiskAssessment? existing;
  final AhaContent? initial;

  /// Injected in tests.
  final RiskAssessmentService? service;
  final SiteRepository? siteRepository;
  final SiteActivitiesLoader? loadActivities;

  @override
  State<RiskAssessmentEditorScreen> createState() =>
      _RiskAssessmentEditorScreenState();
}

/// The text boxes of one step being edited.
class _StepFields {
  _StepFields(AhaStep step)
    : id = step.id,
      step = TextEditingController(text: step.step),
      hazards = TextEditingController(text: step.hazards.join('\n')),
      controls = TextEditingController(text: step.controls.join('\n'));

  final String? id;
  final TextEditingController step;
  final TextEditingController hazards;
  final TextEditingController controls;

  AhaStep toStep() => AhaStep(
    id: id,
    step: step.text.trim(),
    hazards: splitLines(hazards.text),
    controls: splitLines(controls.text),
  );

  void dispose() {
    step.dispose();
    hazards.dispose();
    controls.dispose();
  }
}

/// [text] split into its non-blank lines.
List<String> splitLines(String text) => [
  for (final line in text.split('\n'))
    if (line.trim().isNotEmpty) line.trim(),
];

class _RiskAssessmentEditorScreenState
    extends State<RiskAssessmentEditorScreen> {
  late final RiskAssessmentService _service =
      widget.service ?? RiskAssessmentService();
  late final AhaContent _start = widget.existing ?? widget.initial!;
  late final _featureOfWork = TextEditingController(text: _start.featureOfWork);
  late final _activity = TextEditingController(text: _start.activity);
  late final _location = TextEditingController(text: _start.location);
  late final _contractNo = TextEditingController(text: _start.contractNo);
  late final _equipment = TextEditingController(
    text: _start.equipment.join('\n'),
  );
  late final _inspections = TextEditingController(
    text: _start.inspectionRequirements.join('\n'),
  );
  late final _training = TextEditingController(
    text: _start.trainingRequirements.join('\n'),
  );
  late final List<_StepFields> _steps = [
    for (final step in _start.steps) _StepFields(step),
  ];
  late String? _startDate = _start.estimatedStartDate;
  String? _siteId;

  /// The site's activities this AHA covers; empty = the whole site.
  late final Set<String> _activityIds = {...?widget.existing?.activityIds};
  String? _activitiesSiteId;
  Future<List<Activity>>? _activities;

  String? get _effectiveSiteId => widget.existing?.siteId ?? _siteId;

  /// The chosen site's activities, fetched once per site.
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

  bool _isSaving = false;
  String? _errorMessage;

  bool get _isNew => widget.existing == null;

  @override
  void dispose() {
    for (final controller in [
      _featureOfWork,
      _activity,
      _location,
      _contractNo,
      _equipment,
      _inspections,
      _training,
    ]) {
      controller.dispose();
    }
    for (final step in _steps) {
      step.dispose();
    }
    super.dispose();
  }

  String? _optional(TextEditingController controller) {
    final text = controller.text.trim();
    return text.isEmpty ? null : text;
  }

  Future<void> _pickStartDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(_startDate ?? '') ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 3),
    );
    if (picked == null) return;
    String two(int v) => v.toString().padLeft(2, '0');
    setState(
      () =>
          _startDate = '${picked.year}-${two(picked.month)}-${two(picked.day)}',
    );
  }

  /// Adds what was pasted in [_PasteAhaDialog]: its steps after the
  /// existing ones (replacing them when they are all still empty), its
  /// lines added to the three lists, and the feature of work / activity
  /// when those are still blank.
  Future<void> _pasteAha() async {
    final parsed = await showDialog<ParsedAha>(
      context: context,
      builder: (_) => const _PasteAhaDialog(),
    );
    if (parsed == null || !mounted) return;
    void addLines(TextEditingController controller, List<String> lines) {
      final existing = splitLines(controller.text);
      final merged = [
        ...existing,
        for (final line in lines)
          if (!existing.contains(line)) line,
      ];
      controller.text = merged.join('\n');
    }

    setState(() {
      if (_steps.every((s) => s.step.text.trim().isEmpty)) {
        for (final step in _steps) {
          step.dispose();
        }
        _steps.clear();
      }
      for (final step in parsed.steps) {
        _steps.add(_StepFields(step));
      }
      addLines(_equipment, parsed.equipment);
      addLines(_inspections, parsed.inspectionRequirements);
      addLines(_training, parsed.trainingRequirements);
      if (_featureOfWork.text.trim().isEmpty && parsed.featureOfWork != null) {
        _featureOfWork.text = parsed.featureOfWork!;
      }
      if (_activity.text.trim().isEmpty && parsed.activity != null) {
        _activity.text = parsed.activity!;
      }
    });
  }

  void _moveStep(int index, int delta) {
    final target = index + delta;
    if (target < 0 || target >= _steps.length) return;
    setState(() {
      final step = _steps.removeAt(index);
      _steps.insert(target, step);
    });
  }

  Future<void> _removeStep(int index) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this step?'),
        content: Text(
          _steps[index].step.text.trim().isEmpty
              ? 'Step ${index + 1}'
              : _steps[index].step.text.trim(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _steps.removeAt(index).dispose());
  }

  Future<void> _save() async {
    final feature = _featureOfWork.text.trim();
    final steps = [
      for (final step in _steps)
        if (step.step.text.trim().isNotEmpty) step.toStep(),
    ];
    final problem = feature.isEmpty
        ? 'Name the phase / feature of work.'
        : _isNew && _siteId == null
        ? 'Choose the site.'
        : steps.isEmpty
        ? 'Add at least one principal step.'
        : null;
    if (problem != null) {
      setState(() => _errorMessage = problem);
      return;
    }
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });
    try {
      final id = await _service.save(
        organizationId: widget.organizationId,
        id: widget.existing?.id,
        siteId: _isNew ? _siteId : null,
        activityIds: _activityIds.toList(),
        content: AhaContent(
          featureOfWork: feature,
          activity: _optional(_activity),
          contractNo: _optional(_contractNo),
          location: _optional(_location),
          estimatedStartDate: _startDate,
          steps: steps,
          equipment: splitLines(_equipment.text),
          inspectionRequirements: splitLines(_inspections.text),
          trainingRequirements: splitLines(_training.text),
        ),
      );
      if (mounted) Navigator.of(context).pop(id);
    } on AppException catch (e) {
      if (mounted) setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Widget _linesField(
    TextEditingController controller,
    String label,
    String hint,
  ) {
    return TextField(
      controller: controller,
      minLines: 3,
      maxLines: null,
      textCapitalization: TextCapitalization.sentences,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: 'One per line',
        alignLabelWithHint: true,
      ),
    );
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
    const color = AppColors.riskAssessments;

    return Scaffold(
      appBar: AppBar(title: const MobileTitle('AHA Editor')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.xl,
        ),
        children: [
          FeatureHeader(
            title: _isNew ? 'Prepare an AHA' : 'Edit draft AHA',
            subtitle:
                'Activity Hazard Analysis: the principal steps of the work, '
                'the hazards of each step and how each is controlled. '
                'Check every line against the actual site.',
            icon: Icons.assignment_late,
            color: color,
            chips: [
              if (!_isNew)
                FeatureChip(
                  icon: Icons.history,
                  label: 'Revision ${widget.existing!.revision}',
                ),
            ],
          ),
          if (_isNew) ...[
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
                if (id != _siteId) _activityIds.clear();
                _siteId = id;
              }),
              siteRepository: widget.siteRepository,
            ),
          ],
          if (_effectiveSiteId != null) ...[
            const SizedBox(height: AppSpacing.md),
            const FeatureSectionTitle(
              title: 'Activities covered',
              icon: Icons.handyman,
              color: AppColors.projects,
            ),
            const SizedBox(height: AppSpacing.xs),
            const Text(
              "The daily meeting shows this AHA when one of these activities "
              'is worked. Choose "Whole site" if it applies to all work here.',
              style: AppTextStyles.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.sm),
            ChoiceTile(
              title: 'Whole site',
              subtitle: 'Every activity at this site',
              icon: Icons.domain,
              color: AppColors.projects,
              selected: _activityIds.isEmpty,
              onTap: () => setState(_activityIds.clear),
            ),
            const SizedBox(height: AppSpacing.sm),
            FutureBuilder<List<Activity>>(
              future: _activitiesFor(_effectiveSiteId!),
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                final activities = [
                  for (final activity in snapshot.data ?? const <Activity>[])
                    if (activity.status.id == 'active' ||
                        _activityIds.contains(activity.id))
                      activity,
                ];
                if (activities.isEmpty) {
                  return const Text(
                    'This site has no activities set up yet, so the AHA '
                    'covers the whole site.',
                    style: AppTextStyles.bodyMedium,
                  );
                }
                return MultiChoiceList<String>(
                  items: [
                    for (final activity in activities)
                      ChoiceItem(
                        value: activity.id,
                        title: activity.name,
                        subtitle: activity.code,
                        icon: Icons.handyman,
                      ),
                  ],
                  selected: _activityIds,
                  onChanged: (value) => setState(() {
                    _activityIds
                      ..clear()
                      ..addAll(value);
                  }),
                );
              },
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          const FeatureSectionTitle(
            title: 'Feature of work',
            icon: Icons.construction,
            color: color,
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: _featureOfWork,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Phase / feature of work (required)',
              hintText: 'e.g. Removals',
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: _activity,
            minLines: 1,
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Activity'),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: _location,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Location',
              hintText: 'e.g. Blocks 1–22',
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: _contractNo,
            decoration: const InputDecoration(labelText: 'Contract No.'),
          ),
          const SizedBox(height: AppSpacing.sm),
          ChoiceTile(
            title: _startDate == null
                ? 'Estimated start date'
                : 'Estimated start: $_startDate',
            subtitle: 'Tap to choose',
            icon: Icons.event,
            color: color,
            selected: _startDate != null,
            onTap: _pickStartDate,
          ),

          const SizedBox(height: AppSpacing.lg),
          FeatureSectionTitle(
            title: 'Principal steps',
            icon: Icons.format_list_numbered,
            color: color,
            count: _steps.length,
          ),
          const SizedBox(height: AppSpacing.xs),
          const Text(
            'In the order the work is done. For each step: what can go '
            'wrong, and what will be done about it.',
            style: AppTextStyles.bodyMedium,
          ),
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _pasteAha,
              icon: const Icon(Icons.content_paste),
              label: const Text('Paste an AHA'),
            ),
          ),
          for (var i = 0; i < _steps.length; i++) ...[
            const SizedBox(height: AppSpacing.md),
            _StepCard(
              key: ObjectKey(_steps[i]),
              number: i + 1,
              fields: _steps[i],
              onUp: i == 0 ? null : () => _moveStep(i, -1),
              onDown: i == _steps.length - 1 ? null : () => _moveStep(i, 1),
              onRemove: () => _removeStep(i),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton.icon(
            onPressed: () => setState(
              () => _steps.add(_StepFields(const AhaStep(step: ''))),
            ),
            icon: const Icon(Icons.add),
            label: const Text('Add a step'),
          ),

          const SizedBox(height: AppSpacing.lg),
          const FeatureSectionTitle(
            title: 'Equipment, inspections and training',
            icon: Icons.handyman,
            color: color,
          ),
          const SizedBox(height: AppSpacing.sm),
          _linesField(
            _equipment,
            'Equipment to be used',
            'e.g. Scaffolding and ladders',
          ),
          const SizedBox(height: AppSpacing.md),
          _linesField(
            _inspections,
            'Inspection requirements',
            'e.g. Scaffold inspected before each shift',
          ),
          const SizedBox(height: AppSpacing.md),
          _linesField(
            _training,
            'Training requirements (include hazard communication)',
            'e.g. Fall protection training',
          ),

          if (_errorMessage != null) ...[
            const SizedBox(height: AppSpacing.md),
            AuthErrorBanner(message: _errorMessage!),
          ],
          const SizedBox(height: AppSpacing.lg),
          SizedBox(
            height: AppSpacing.minTouchTarget,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: color,
                foregroundColor: Colors.white,
              ),
              onPressed: _isSaving ? null : _save,
              icon: const Icon(Icons.save),
              label: const Text('Save draft'),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          const Text(
            'Saved as a draft. Another Site Manager or Admin then reviews and '
            'accepts it before it is used on site.',
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _StepCard extends StatelessWidget {
  const _StepCard({
    super.key,
    required this.number,
    required this.fields,
    required this.onUp,
    required this.onDown,
    required this.onRemove,
  });

  final int number;
  final _StepFields fields;
  final VoidCallback? onUp;
  final VoidCallback? onDown;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    const color = AppColors.riskAssessments;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sm + 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: color,
                  child: Text(
                    '$number',
                    style: AppTextStyles.label.copyWith(color: Colors.white),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'Step $number',
                    style: AppTextStyles.bodyLarge.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Move up',
                  onPressed: onUp,
                  icon: const Icon(Icons.arrow_upward),
                ),
                IconButton(
                  tooltip: 'Move down',
                  onPressed: onDown,
                  icon: const Icon(Icons.arrow_downward),
                ),
                IconButton(
                  tooltip: 'Remove step',
                  onPressed: onRemove,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: fields.step,
              minLines: 1,
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'What is done'),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: fields.hazards,
              minLines: 2,
              maxLines: null,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: 'Hazards',
                helperText: 'One per line',
                alignLabelWithHint: true,
                prefixIcon: Icon(Icons.warning_amber, color: ahaHazardColor),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: fields.controls,
              minLines: 2,
              maxLines: null,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: 'Controls',
                helperText: 'One per line',
                alignLabelWithHint: true,
                prefixIcon: Icon(Icons.shield_outlined, color: ahaControlColor),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Paste an AHA as text (e.g. from a Word or PDF AHA) — see
/// [parseAhaText] for the layout. Shows what was found; pops the
/// [ParsedAha].
class _PasteAhaDialog extends StatefulWidget {
  const _PasteAhaDialog();

  @override
  State<_PasteAhaDialog> createState() => _PasteAhaDialogState();
}

class _PasteAhaDialogState extends State<_PasteAhaDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final parsed = parseAhaText(_text.text);
    String count(int n, String what) => '$n $what${n == 1 ? '' : 's'}';
    return AlertDialog(
      title: const Text('Paste an AHA'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Paste it in the order of the AHA form: each numbered line '
                'is a step, followed by its "Hazards:" and "Controls:". '
                'Then "Equipment:", "Inspection requirements:" and '
                '"Training requirements:". Bullets are removed. You can '
                'adjust everything afterwards.',
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: _text,
                minLines: 10,
                maxLines: 18,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  hintText:
                      '1. Erect scaffold\n'
                      'Hazards:\n'
                      '- Falls from height\n'
                      'Controls:\n'
                      '- Guardrails on open sides\n'
                      '2. Paint walls\n'
                      '...\n'
                      'Equipment:\n'
                      '- Scaffold, rollers\n'
                      'Training requirements:\n'
                      '- Working at height',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                parsed.isEmpty
                    ? 'Nothing found yet.'
                    : '${count(parsed.steps.length, 'step')}, '
                          '${count(parsed.hazardCount, 'hazard')}, '
                          '${count(parsed.controlCount, 'control')}; '
                          '${count(parsed.equipment.length, 'equipment line')}, '
                          '${count(parsed.inspectionRequirements.length, 'inspection line')}, '
                          '${count(parsed.trainingRequirements.length, 'training line')}',
                style: AppTextStyles.bodyMedium,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: parsed.isEmpty
              ? null
              : () => Navigator.of(context).pop(parsed),
          child: const Text('Add to AHA'),
        ),
      ],
    );
  }
}
