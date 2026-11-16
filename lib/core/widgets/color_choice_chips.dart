import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';

/// One option in a [ColorChoiceChips] group.
class ColorChoice<T> {
  const ColorChoice({
    required this.value,
    required this.label,
    required this.color,
    this.icon,
  });

  final T value;
  final String label;
  final Color color;
  final IconData? icon;
}

/// A row of selectable chips where every option carries its own color and
/// icon — solid when selected, a soft tint when not. Used for filters
/// (status, severity) and pickers (severity, category) across feature
/// screens. Built on [ChoiceChip], so it behaves like any other chip.
class ColorChoiceChips<T> extends StatelessWidget {
  const ColorChoiceChips({
    super.key,
    required this.choices,
    required this.selected,
    required this.onSelected,
    this.label,
  });

  final List<ColorChoice<T>> choices;
  final T selected;
  final ValueChanged<T> onSelected;

  /// Optional small heading above the chips, e.g. "Severity".
  final String? label;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null) ...[
          Text(label!, style: AppTextStyles.label),
          const SizedBox(height: AppSpacing.xs),
        ],
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            for (final choice in choices)
              Builder(
                builder: (context) {
                  final isSelected = choice.value == selected;
                  final foreground = isSelected
                      ? AppColors.onColor(choice.color)
                      : AppColors.readable(choice.color, brightness);
                  return ChoiceChip(
                    showCheckmark: false,
                    avatar: choice.icon == null
                        ? null
                        : Icon(choice.icon, size: 18, color: foreground),
                    label: Text(choice.label),
                    labelStyle: TextStyle(
                      color: foreground,
                      fontWeight: FontWeight.w600,
                    ),
                    selected: isSelected,
                    selectedColor: choice.color,
                    backgroundColor: choice.color.withValues(alpha: 0.10),
                    side: BorderSide(
                      color: choice.color.withValues(
                        alpha: isSelected ? 1 : 0.4,
                      ),
                    ),
                    onSelected: (_) => onSelected(choice.value),
                  );
                },
              ),
          ],
        ),
      ],
    );
  }
}

/// A titled, colored group of form fields — e.g. "Where" / "What happened"
/// / "How serious" on a report form — so a long form reads as steps.
class FormSection extends StatelessWidget {
  const FormSection({
    super.key,
    required this.title,
    required this.icon,
    required this.color,
    required this.child,
  });

  final String title;
  final IconData icon;
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // A Material (not a decorated Container) so tick-boxes, switches and
    // list tiles inside it still paint their own ink.
    return Material(
      color: Color.alphaBlend(
        color.withValues(alpha: 0.06),
        Theme.of(context).colorScheme.surface,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: color.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: color),
                const SizedBox(width: AppSpacing.sm),
                Flexible(
                  child: Text(
                    title,
                    style: AppTextStyles.label.copyWith(
                      color: AppColors.readable(
                        color,
                        Theme.of(context).brightness,
                      ),
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            child,
          ],
        ),
      ),
    );
  }
}
