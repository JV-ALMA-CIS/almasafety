import 'package:flutter/material.dart';
import 'evidence_requirement_picker.dart';
import '../domain/corrective_action_evidence.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/color_choice_chips.dart';
import '../../../core/widgets/feature_header.dart';
import '../../../core/widgets/person_picker.dart';
import '../../authentication/domain/organization_user.dart';
import '../../../core/widgets/mobile_title.dart';

class CorrectiveActionFormResult {
  const CorrectiveActionFormResult({
    required this.title,
    required this.description,
    required this.assignedTo,
    required this.dueDate,
    required this.evidenceRequired,
    this.evidenceKinds = const [],
    this.evidenceInstructions,
  });

  final String title;
  final String description;
  final String assignedTo;
  final DateTime dueDate;
  final bool evidenceRequired;

  /// What evidence completing it needs — see [EvidenceRequirementPicker].
  final List<CorrectiveActionEvidenceKind> evidenceKinds;
  final String? evidenceInstructions;
}

/// The full-screen "Create Corrective Action" form, shared by every origin
/// that raises one outside a meeting — a reported hazard and an incident
/// under investigation. Pops a [CorrectiveActionFormResult]; the caller
/// sends it to the right callable (`linkHazardCorrectiveAction`/
/// `linkIncidentCorrectiveAction`). Mirrors [_ConcernsSection]'s own
/// corrective-action dialog in `daily_safety_meeting_screen.dart`.
class CorrectiveActionFormScreen extends StatefulWidget {
  const CorrectiveActionFormScreen({
    super.key,
    required this.eyebrow,
    required this.candidateAssignees,
    this.people = const [],
  });

  /// Where the action comes from, shown above the title — e.g. "From a
  /// reported hazard".
  final String eyebrow;

  final List<String> candidateAssignees;

  /// Who [candidateAssignees] are — their names, roles and trades — so the
  /// assignee is chosen by person, not by account id.
  final List<OrganizationUser> people;

  @override
  State<CorrectiveActionFormScreen> createState() =>
      _CorrectiveActionFormScreenState();
}

class _CorrectiveActionFormScreenState
    extends State<CorrectiveActionFormScreen> {
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _evidenceInstructionsController = TextEditingController();
  String? _assignedTo;
  DateTime? _dueDate;
  Set<CorrectiveActionEvidenceKind> _evidenceKinds = {};

  String? get _evidenceInstructions {
    final text = _evidenceInstructionsController.text.trim();
    return _evidenceKinds.isEmpty || text.isEmpty ? null : text;
  }

  @override
  void initState() {
    super.initState();
    _assignedTo = widget.candidateAssignees.firstOrNull;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _evidenceInstructionsController.dispose();
    super.dispose();
  }

  Future<void> _pickDueDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueDate ?? now,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (picked != null) setState(() => _dueDate = picked);
  }

  @override
  Widget build(BuildContext context) {
    final assignedTo = _assignedTo;
    final dueDate = _dueDate;
    final canSubmit =
        _titleController.text.trim().isNotEmpty &&
        _descriptionController.text.trim().isNotEmpty &&
        assignedTo != null &&
        dueDate != null;

    final actions = <Widget>[
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: canSubmit
            ? () => Navigator.of(context).pop(
                CorrectiveActionFormResult(
                  title: _titleController.text.trim(),
                  description: _descriptionController.text.trim(),
                  assignedTo: assignedTo,
                  dueDate: dueDate,
                  evidenceRequired: _evidenceKinds.isNotEmpty,
                  evidenceKinds: _evidenceKinds.toList(),
                  evidenceInstructions: _evidenceInstructions,
                ),
              )
            : null,
        child: const Text('Create'),
      ),
    ];
    return Scaffold(
      appBar: AppBar(title: const MobileTitle('Corrective Action')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FeatureHeader(
                    eyebrow: widget.eyebrow,
                    title: _titleController.text.trim().isEmpty
                        ? 'New Corrective Action'
                        : _titleController.text.trim(),
                    icon: Icons.build_circle,
                    color: AppColors.correctiveActions,
                    chips: [
                      FeatureChip(
                        icon: Icons.event,
                        label: _dueDate == null
                            ? 'No due date yet'
                            : 'Due ${_formatDate(_dueDate!)}',
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  FormSection(
                    title: 'What needs doing',
                    icon: Icons.edit_note,
                    color: AppColors.correctiveActions,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          controller: _titleController,
                          decoration: const InputDecoration(labelText: 'Title'),
                          onChanged: (_) => setState(() {}),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        TextField(
                          controller: _descriptionController,
                          decoration: const InputDecoration(
                            labelText: 'Description',
                          ),
                          minLines: 2,
                          maxLines: 4,
                          onChanged: (_) => setState(() {}),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  const SizedBox(height: AppSpacing.sm),
                  FormSection(
                    title: 'Who and when',
                    icon: Icons.event,
                    color: AppColors.meetings,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (widget.candidateAssignees.isEmpty)
                          const Text(
                            'No eligible worker is assigned to this site yet.',
                            style: AppTextStyles.bodyMedium,
                          )
                        else
                          PersonPicker(
                            uids: widget.candidateAssignees,
                            people: widget.people,
                            selected: _assignedTo,
                            color: AppColors.correctiveActions,
                            onChanged: (uid) =>
                                setState(() => _assignedTo = uid),
                          ),
                        const SizedBox(height: AppSpacing.sm),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            dueDate == null
                                ? 'Choose a due date'
                                : 'Due: ${_formatDate(dueDate)}',
                          ),
                          trailing: const Icon(Icons.calendar_today_outlined),
                          onTap: _pickDueDate,
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        EvidenceRequirementPicker(
                          kinds: _evidenceKinds,
                          onKindsChanged: (kinds) =>
                              setState(() => _evidenceKinds = kinds),
                          instructionsController:
                              _evidenceInstructionsController,
                        ),
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

String _formatDate(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}
