import 'package:flutter/material.dart';
import '../../../core/widgets/choice_list.dart';
import '../domain/project.dart';
import '../domain/site.dart';

/// Picks one site from [sites] — the shared "which site?" choice on every
/// report form (hazard, near-miss, incident, safety alert).
///
/// Built so that many similar sites stay easy to tell apart, which plain
/// chips or a dropdown of names were not: each site is a full-width row with
/// its own colour, a badge carrying its site code, its name, and its code and
/// location underneath. The chosen row turns solid with a tick.
///
/// - Tapping the chosen site again unselects it ([onChanged] with null), so
///   a wrong tap is easy to undo.
/// - With a single site it is simply shown as chosen, with nothing to pick.
/// - With more than [searchThreshold] sites, a search box filters by name,
///   code or location.
class SiteSelectList extends StatelessWidget {
  const SiteSelectList({
    super.key,
    required this.sites,
    required this.selectedSiteId,
    required this.onChanged,
    this.searchThreshold = 6,
  });

  final List<Site> sites;
  final String? selectedSiteId;
  final ValueChanged<String?> onChanged;
  final int searchThreshold;

  @override
  Widget build(BuildContext context) {
    final sorted = [...sites]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return ChoiceList<String>(
      items: [for (final site in sorted) siteChoice(site)],
      selected: selectedSiteId,
      onChanged: onChanged,
      singleLabel: 'Your site',
      searchThreshold: searchThreshold,
      searchHint: 'Search sites by name, code or location',
    );
  }
}

/// A site as a [ChoiceItem]: its code in the badge, and code · location
/// under its name — what tells similar site names apart.
ChoiceItem<String> siteChoice(Site site) {
  final details = [
    if (site.code.isNotEmpty) site.code,
    if (site.location != null && site.location!.isNotEmpty) site.location!,
  ].join(' · ');
  return ChoiceItem(
    value: site.id,
    title: site.name,
    subtitle: details,
    badge: site.code.isNotEmpty ? site.code : null,
  );
}

/// A project as a [ChoiceItem], its code in the badge.
ChoiceItem<String> projectChoice(Project project) => ChoiceItem(
  value: project.id,
  title: project.name,
  badge: project.code.isNotEmpty ? project.code : null,
);
