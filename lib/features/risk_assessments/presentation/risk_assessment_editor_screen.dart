import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/choice_list.dart';
import '../../../core/widgets/feature_header.dart';
import '../../authentication/presentation/auth_error_banner.dart';
import '../../organizations/data/site_repository.dart';
import '../../organizations/presentation/report_site_picker.dart';
import '../data/risk_assessment_service.dart';
import '../domain/risk_assessment.dart';
import 'risk_assessment_style.dart';

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
  }) : assert(existing != null || initial != null);

  final String organizationId;
  final RiskAssessment? existing;
  final AhaContent? initial;

  /// Injected in tests.
  final RiskAssessmentService? service;
  final SiteRepository? siteRepository;

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
      appBar: AppBar(),
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
              onChanged: (id) => setState(() => _siteId = id),
              siteRepository: widget.siteRepository,
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
