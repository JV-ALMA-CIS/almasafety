import 'package:flutter/material.dart';
import '../../features/authentication/domain/organization_user.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';
import 'dashboard_header.dart';
import 'person_avatar.dart';
import 'status_badge.dart';

/// Choose one person — e.g. who a corrective action is assigned to — from a
/// list of tappable rows showing each person's avatar, name, role badge and
/// trade, instead of a dropdown of account ids. The chosen row is tinted and
/// ticked. A search box appears once the list is long.
///
/// A uid in [uids] with no matching entry in [people] (e.g. the people list
/// failed to load) is still offered, labelled "Unknown person", so a
/// choice is never impossible.
class PersonPicker extends StatefulWidget {
  const PersonPicker({
    super.key,
    required this.uids,
    required this.people,
    required this.selected,
    required this.onChanged,
    this.color = AppColors.people,
  });

  final List<String> uids;
  final List<OrganizationUser> people;
  final String? selected;
  final ValueChanged<String> onChanged;
  final Color color;

  @override
  State<PersonPicker> createState() => _PersonPickerState();
}

class _PersonPickerState extends State<PersonPicker> {
  String _query = '';

  static const _searchThreshold = 8;

  @override
  Widget build(BuildContext context) {
    final byUid = {for (final person in widget.people) person.uid: person};
    String nameOf(String uid) {
      final name = byUid[uid]?.name.trim() ?? '';
      return name.isEmpty ? 'Unknown person' : name;
    }

    final sorted = [...widget.uids]
      ..sort((a, b) => nameOf(a).compareTo(nameOf(b)));
    final query = _query.trim().toLowerCase();
    final shown = query.isEmpty
        ? sorted
        : sorted
              .where((uid) => nameOf(uid).toLowerCase().contains(query))
              .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.uids.length > _searchThreshold) ...[
          TextField(
            decoration: const InputDecoration(
              hintText: 'Search by name',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (value) => setState(() => _query = value),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        if (shown.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
            child: Text('No one matches that name.'),
          ),
        for (final uid in shown)
          _PersonRow(
            name: nameOf(uid),
            person: byUid[uid],
            selected: uid == widget.selected,
            color: widget.color,
            onTap: () => widget.onChanged(uid),
          ),
      ],
    );
  }
}

class _PersonRow extends StatelessWidget {
  const _PersonRow({
    required this.name,
    required this.person,
    required this.selected,
    required this.color,
    required this.onTap,
  });

  final String name;
  final OrganizationUser? person;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final role = person?.role;
    final details = [
      if (person?.trade != null) person!.trade!,
      if (person?.workerType != null) person!.workerType!.label,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Material(
        color: selected
            ? Color.alphaBlend(
                color.withValues(alpha: 0.12),
                Theme.of(context).colorScheme.surface,
              )
            : Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: selected ? color : color.withValues(alpha: 0.3),
            width: selected ? 2 : 1,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.sm + 2),
            child: Row(
              children: [
                PersonAvatar(name: name),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: AppTextStyles.bodyLarge.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (role != null || details.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: AppSpacing.xs,
                          runSpacing: AppSpacing.xs,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (role != null)
                              StatusBadge(
                                label: role.label,
                                color: DashboardHeader.roleColor(role),
                              ),
                            if (details.isNotEmpty)
                              Text(details, style: AppTextStyles.bodyMedium),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                Icon(
                  selected ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: selected ? color : AppColors.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
