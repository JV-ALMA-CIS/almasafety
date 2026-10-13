import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';

/// One option in a [ChoiceList] or [MultiChoiceList].
class ChoiceItem<T> {
  const ChoiceItem({
    required this.value,
    required this.title,
    this.subtitle,
    this.badge,
    this.icon,
    this.color,
  });

  final T value;
  final String title;

  /// A second line that tells similar options apart — a site's code and
  /// location, a role's description, a meeting point's category.
  final String? subtitle;

  /// Short text in the coloured badge (e.g. a site code). Falls back to
  /// [icon], then to the title's initials.
  final String? badge;
  final IconData? icon;

  /// The option's own colour. When null, options are coloured from a
  /// palette in list order so neighbours never look alike.
  final Color? color;
}

/// Distinct, readable accents handed out in list order to options without
/// their own colour.
const _palette = [
  AppColors.projects,
  AppColors.hazards,
  AppColors.correctiveActions,
  AppColors.safetyAlerts,
  AppColors.learning,
  AppColors.analytics,
  AppColors.people,
  AppColors.reports,
  AppColors.meetings,
  AppColors.administration,
];

Color _colorFor<T>(ChoiceItem<T> item, int index) =>
    item.color ?? choicePaletteColor(index);

/// The [index]th colour of the palette options are coloured from — for
/// screens building their own rows with [ChoiceTile].
Color choicePaletteColor(int index) => _palette[index % _palette.length];

/// Pick ONE option — the app's standard replacement for a dropdown or a
/// radio group. Every option is a full-width coloured row (badge, title,
/// detail line); the chosen one turns solid with a tick.
///
/// - Tapping the chosen option again unselects it ([onChanged] with null)
///   unless [allowDeselect] is false (e.g. a filter that must always have a
///   value).
/// - With a single option and [singleLabel] set, that option is shown as
///   already chosen with the label (e.g. "Your site") and nothing to tap.
/// - With more than [searchThreshold] options, a search box filters by
///   title and detail line.
/// - Give a [validator] to take part in a surrounding [Form]'s validation,
///   exactly like the dropdown it replaces.
class ChoiceList<T> extends StatelessWidget {
  const ChoiceList({
    super.key,
    required this.items,
    required this.selected,
    required this.onChanged,
    this.label,
    this.allowDeselect = true,
    this.singleLabel,
    this.searchThreshold = 6,
    this.searchHint = 'Search',
    this.validator,
    this.enabled = true,
    this.noneLabel,
  });

  final List<ChoiceItem<T>> items;
  final T? selected;

  /// When set, an extra first row with this label (e.g. "All sites")
  /// stands for "nothing chosen" — for filters, where null means "all".
  final String? noneLabel;
  final ValueChanged<T?> onChanged;

  /// Optional small heading above the list.
  final String? label;
  final bool allowDeselect;
  final String? singleLabel;
  final int searchThreshold;
  final String searchHint;
  final FormFieldValidator<T>? validator;
  final bool enabled;

  List<ChoiceItem<T?>> get _rows => [
    if (noneLabel != null)
      ChoiceItem<T?>(
        value: null,
        title: noneLabel!,
        icon: Icons.all_inclusive,
        color: AppColors.textSecondary,
      ),
    for (final item in items)
      ChoiceItem<T?>(
        value: item.value,
        title: item.title,
        subtitle: item.subtitle,
        badge: item.badge,
        icon: item.icon,
        color: item.color,
      ),
  ];

  @override
  Widget build(BuildContext context) {
    final validator = this.validator;
    final canDeselect = allowDeselect && noneLabel == null;
    if (validator == null) {
      return _ChoiceRows<T?>(
        items: _rows,
        isSelected: (value) => value == selected,
        onTap: _tap,
        label: label,
        multi: false,
        singleLabel: singleLabel,
        searchThreshold: searchThreshold,
        searchHint: searchHint,
        enabled: enabled,
        hint: canDeselect && selected != null && items.length > 1
            ? 'Tap the chosen one again to unselect it.'
            : null,
      );
    }
    return FormField<T>(
      // Re-created when the selection changes from outside, so validation
      // always sees the current value.
      key: ValueKey(selected),
      initialValue: selected,
      validator: validator,
      builder: (state) => _ChoiceRows<T?>(
        items: _rows,
        isSelected: (value) => value == selected,
        onTap: (value) {
          _tap(value);
          state.didChange(value == selected && canDeselect ? null : value);
        },
        label: label,
        multi: false,
        singleLabel: singleLabel,
        searchThreshold: searchThreshold,
        searchHint: searchHint,
        enabled: enabled,
        errorText: state.errorText,
      ),
    );
  }

  void _tap(T? value) {
    if (value == selected) {
      if (allowDeselect && noneLabel == null) onChanged(null);
    } else {
      onChanged(value);
    }
  }
}

/// Pick ANY NUMBER of options — the app's standard replacement for a list
/// of checkboxes. Same coloured rows as [ChoiceList]; each chosen row turns
/// solid with a ticked box, and tapping it again unticks it.
class MultiChoiceList<T> extends StatelessWidget {
  const MultiChoiceList({
    super.key,
    required this.items,
    required this.selected,
    required this.onChanged,
    this.label,
    this.searchThreshold = 6,
    this.searchHint = 'Search',
    this.enabled = true,
  });

  final List<ChoiceItem<T>> items;
  final Set<T> selected;

  /// Called with the whole new selection after every tap.
  final ValueChanged<Set<T>> onChanged;
  final String? label;
  final int searchThreshold;
  final String searchHint;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return _ChoiceRows<T>(
      items: items,
      isSelected: selected.contains,
      onTap: (value) {
        final next = {...selected};
        if (!next.remove(value)) next.add(value);
        onChanged(next);
      },
      label: label,
      multi: true,
      searchThreshold: searchThreshold,
      searchHint: searchHint,
      enabled: enabled,
    );
  }
}

class _ChoiceRows<T> extends StatefulWidget {
  const _ChoiceRows({
    required this.items,
    required this.isSelected,
    required this.onTap,
    required this.label,
    required this.multi,
    required this.searchThreshold,
    required this.searchHint,
    required this.enabled,
    this.singleLabel,
    this.hint,
    this.errorText,
  });

  final List<ChoiceItem<T>> items;
  final bool Function(T value) isSelected;
  final ValueChanged<T> onTap;
  final String? label;
  final bool multi;
  final int searchThreshold;
  final String searchHint;
  final bool enabled;
  final String? singleLabel;
  final String? hint;
  final String? errorText;

  @override
  State<_ChoiceRows<T>> createState() => _ChoiceRowsState<T>();
}

class _ChoiceRowsState<T> extends State<_ChoiceRows<T>> {
  String _query = '';

  bool _matches(ChoiceItem<T> item) {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return true;
    return item.title.toLowerCase().contains(query) ||
        (item.subtitle?.toLowerCase().contains(query) ?? false) ||
        (item.badge?.toLowerCase().contains(query) ?? false);
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    final onlyOne =
        !widget.multi && widget.singleLabel != null && items.length == 1;
    final showSearch = items.length > widget.searchThreshold;
    final visible = [
      for (final (index, item) in items.indexed)
        if (_matches(item) || widget.isSelected(item.value))
          (item, _colorFor(item, index)),
    ];
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.label != null) ...[
          Text(widget.label!, style: AppTextStyles.label),
          const SizedBox(height: AppSpacing.xs),
        ],
        if (showSearch) ...[
          TextField(
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: widget.searchHint,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (value) => setState(() => _query = value),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        for (final (item, color) in visible) ...[
          ChoiceTile(
            title: item.title,
            subtitle: item.subtitle,
            badge: item.badge,
            icon: item.icon,
            color: color,
            selected: onlyOne || widget.isSelected(item.value),
            multi: widget.multi,
            trailingLabel: onlyOne ? widget.singleLabel : null,
            onTap: onlyOne || !widget.enabled
                ? null
                : () => widget.onTap(item.value),
          ),
          const SizedBox(height: AppSpacing.xs + 2),
        ],
        if (visible.isEmpty && items.isNotEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
            child: Text(
              'Nothing matches your search.',
              style: AppTextStyles.bodyMedium,
            ),
          ),
        if (widget.errorText != null)
          Text(
            widget.errorText!,
            style: AppTextStyles.bodyMedium.copyWith(
              color: Theme.of(context).colorScheme.error,
            ),
          )
        else if (widget.hint != null)
          Text(
            widget.hint!,
            style: AppTextStyles.bodyMedium.copyWith(color: muted),
          ),
      ],
    );
  }
}

/// One coloured selectable row — the building block of [ChoiceList] and
/// [MultiChoiceList], public for screens that need extra content between
/// rows (e.g. per-item settings shown under a ticked item). Use it with
/// [multi] true for tick-box behaviour, false for pick-one.
class ChoiceTile extends StatelessWidget {
  const ChoiceTile({
    super.key,
    required this.title,
    required this.color,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.badge,
    this.icon,
    this.multi = false,
    this.trailingLabel,
  });

  final String title;
  final String? subtitle;
  final String? badge;
  final IconData? icon;
  final Color color;
  final bool selected;
  final bool multi;
  final String? trailingLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final onFill = AppColors.onColor(color);
    final badgeForeground = selected ? onFill : AppColors.onColor(color);

    Widget badgeChild;
    if (badge != null && badge!.isNotEmpty) {
      badgeChild = Text(
        badge!,
        maxLines: 1,
        style: AppTextStyles.label.copyWith(
          color: badgeForeground,
          fontWeight: FontWeight.w800,
        ),
      );
    } else if (icon != null) {
      badgeChild = Icon(icon, color: badgeForeground, size: 22);
    } else {
      badgeChild = Text(
        _initials(title),
        style: AppTextStyles.label.copyWith(
          color: badgeForeground,
          fontWeight: FontWeight.w800,
        ),
      );
    }

    final Widget trailing;
    if (trailingLabel != null) {
      trailing = Text(
        trailingLabel!,
        style: AppTextStyles.label.copyWith(color: selected ? onFill : color),
      );
    } else if (multi) {
      trailing = Icon(
        selected ? Icons.check_box : Icons.check_box_outline_blank,
        color: selected ? onFill : color,
      );
    } else {
      trailing = Icon(
        selected ? Icons.check_circle : Icons.radio_button_unchecked,
        color: selected ? onFill : color,
      );
    }

    return Semantics(
      selected: selected,
      button: onTap != null,
      child: Opacity(
        opacity: onTap == null && trailingLabel == null ? 0.6 : 1,
        child: Material(
          color: selected ? color : color.withValues(alpha: 0.08),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: color.withValues(alpha: selected ? 1 : 0.45),
              width: selected ? 2 : 1,
            ),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm + 2,
                vertical: AppSpacing.sm,
              ),
              child: Row(
                children: [
                  Container(
                    constraints: const BoxConstraints(minWidth: 40),
                    height: 40,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: selected ? onFill.withValues(alpha: 0.2) : color,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: badgeChild,
                  ),
                  const SizedBox(width: AppSpacing.sm + 2),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: AppTextStyles.bodyLarge.copyWith(
                            fontWeight: FontWeight.w700,
                            color: selected
                                ? onFill
                                : AppColors.readable(color, brightness),
                          ),
                        ),
                        if (subtitle != null && subtitle!.isNotEmpty)
                          Text(
                            subtitle!,
                            style: AppTextStyles.bodyMedium.copyWith(
                              color: selected
                                  ? onFill.withValues(alpha: 0.9)
                                  : null,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  trailing,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _initials(String text) {
    final words = text
        .trim()
        .split(RegExp(r'\s+'))
        .where(
          (word) => word.isNotEmpty && RegExp(r'[A-Za-z0-9]').hasMatch(word[0]),
        );
    final initials = words.take(2).map((word) => word[0].toUpperCase()).join();
    return initials.isEmpty ? '•' : initials;
  }
}
