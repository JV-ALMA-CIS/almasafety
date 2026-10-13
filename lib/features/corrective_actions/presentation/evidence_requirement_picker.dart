import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/choice_list.dart';
import '../domain/corrective_action_evidence.dart';

/// The "Evidence required to complete" choice on every corrective-action
/// form: tick it, then pick WHAT evidence the assignee must attach — a
/// photo of the finished work, a written confirmation, or both — and
/// optionally say exactly what (e.g. "Photo of the new guard rail").
///
/// Unticking clears the kinds; ticking starts with a photo, the most common
/// proof on site.
class EvidenceRequirementPicker extends StatelessWidget {
  const EvidenceRequirementPicker({
    super.key,
    required this.kinds,
    required this.onKindsChanged,
    required this.instructionsController,
  });

  final Set<CorrectiveActionEvidenceKind> kinds;
  final ValueChanged<Set<CorrectiveActionEvidenceKind>> onKindsChanged;
  final TextEditingController instructionsController;

  @override
  Widget build(BuildContext context) {
    final required = kinds.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ChoiceTile(
          multi: true,
          title: 'Evidence required to complete',
          subtitle: required
              ? 'The assignee must attach it before submitting'
              : 'Tick to ask for photos or a written confirmation',
          icon: Icons.verified,
          color: AppColors.analytics,
          selected: required,
          onTap: () => onKindsChanged(
            required ? const {} : const {CorrectiveActionEvidenceKind.photo},
          ),
        ),
        if (required) ...[
          const SizedBox(height: AppSpacing.sm),
          Padding(
            padding: const EdgeInsets.only(left: AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                MultiChoiceList<CorrectiveActionEvidenceKind>(
                  label: 'What evidence?',
                  items: [
                    for (final kind in CorrectiveActionEvidenceKind.values)
                      ChoiceItem(
                        value: kind,
                        title: kind.label,
                        subtitle: kind.hint,
                        icon: switch (kind) {
                          CorrectiveActionEvidenceKind.photo =>
                            Icons.photo_camera,
                          CorrectiveActionEvidenceKind.confirmation =>
                            Icons.edit_note,
                        },
                        color: switch (kind) {
                          CorrectiveActionEvidenceKind.photo =>
                            AppColors.analytics,
                          CorrectiveActionEvidenceKind.confirmation =>
                            AppColors.meetings,
                        },
                      ),
                  ],
                  selected: kinds,
                  onChanged: onKindsChanged,
                ),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: instructionsController,
                  minLines: 1,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Exactly what? (optional)',
                    hintText: 'e.g. Photo of the new guard rail',
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
