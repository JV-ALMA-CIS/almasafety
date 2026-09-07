import 'package:flutter/material.dart';
import '../utils/responsive.dart';

/// A single destination in the app's primary navigation.
class NavDestinationItem {
  const NavDestinationItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

/// One navigable item within a [NavSection] — carries its own route so a
/// [ResponsiveScaffold] built from [sections] can dispatch a tap without the
/// caller maintaining a parallel index-to-route lookup (the failure mode
/// [AppDestinationItem]/`_shellRoutes` had before: two lists that must stay
/// in lockstep by position).
class NavSectionEntry {
  const NavSectionEntry({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.route,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;

  /// The route this entry navigates to when tapped. Compared against the
  /// current location (not a positional index) to decide which entry is
  /// selected, so entries can be added, removed or reordered per signed-in
  /// role without breaking selection tracking.
  final String route;
}

/// A titled group of [NavSectionEntry] items, e.g. "Safety" containing
/// Hazards/Corrective Actions/Safety Alerts. [title] is null for a group
/// that should render without a heading (e.g. a lone "Dashboard" entry at
/// the top of the list).
class NavSection {
  const NavSection({this.title, required this.entries});

  final String? title;
  final List<NavSectionEntry> entries;
}

/// A scaffold that adapts primary navigation to the available width.
///
/// Two ways to supply navigation, mutually exclusive:
///
///  - [destinations]/[selectedIndex]/[onDestinationSelected]: a flat,
///    unsectioned list — bottom navigation on mobile, a nav rail on
///    tablet/desktop. The original shape, kept for any caller that has no
///    need for groups.
///  - [sections]: a grouped, titled list of [NavSectionEntry] — a
///    responsive nav drawer (temporary on mobile/tablet, persistent on
///    desktop) with section headings, and [currentRoute] (not a numeric
///    index) drives which entry is highlighted. Use this for navigation
///    with more items than fit comfortably in a flat rail, or that benefits
///    from visual grouping (see [AppShell]).
///
/// [header] renders above the navigation items in the drawer/rail — e.g. app
/// branding plus an organization switcher — and is ignored in the flat
/// [destinations] mode, matching how that mode never had a header slot.
class ResponsiveScaffold extends StatelessWidget {
  const ResponsiveScaffold({
    super.key,
    required this.body,
    this.destinations,
    this.selectedIndex,
    this.onDestinationSelected,
    this.sections,
    this.currentRoute,
    this.onNavSelected,
    this.header,
    this.title,
    this.actions,
    this.floatingActionButton,
  }) : assert(
         (destinations != null &&
                 selectedIndex != null &&
                 onDestinationSelected != null &&
                 sections == null) ||
             (sections != null &&
                 currentRoute != null &&
                 onNavSelected != null &&
                 destinations == null),
         'Supply either the flat destinations/selectedIndex/'
         'onDestinationSelected trio, or sections/currentRoute/'
         'onNavSelected — not a mix of both.',
       );

  final Widget body;

  // ---- flat mode ----
  final List<NavDestinationItem>? destinations;
  final int? selectedIndex;
  final ValueChanged<int>? onDestinationSelected;

  // ---- sectioned mode ----
  final List<NavSection>? sections;
  final String? currentRoute;
  final ValueChanged<String>? onNavSelected;
  final Widget? header;

  final String? title;
  final List<Widget>? actions;
  final Widget? floatingActionButton;

  @override
  Widget build(BuildContext context) {
    final screenSize = Responsive.screenSizeOf(context);

    if (sections != null) {
      return _buildSectioned(context, screenSize);
    }
    return _buildFlat(context, screenSize);
  }

  // ---- flat mode (unchanged behavior) ----

  Widget _buildFlat(BuildContext context, ScreenSize screenSize) {
    final appBar = AppBar(
      title: title != null ? Text(title!) : null,
      actions: actions,
    );

    if (screenSize == ScreenSize.mobile) {
      return Scaffold(
        appBar: appBar,
        body: body,
        floatingActionButton: floatingActionButton,
        bottomNavigationBar: NavigationBar(
          selectedIndex: selectedIndex!,
          onDestinationSelected: onDestinationSelected,
          destinations: [
            for (final d in destinations!)
              NavigationDestination(
                icon: Icon(d.icon),
                selectedIcon: Icon(d.selectedIcon),
                label: d.label,
              ),
          ],
        ),
      );
    }

    final railExtended = screenSize == ScreenSize.desktop;

    return Scaffold(
      appBar: appBar,
      body: Row(
        children: [
          NavigationRail(
            extended: railExtended,
            selectedIndex: selectedIndex,
            onDestinationSelected: onDestinationSelected,
            labelType: railExtended
                ? NavigationRailLabelType.none
                : NavigationRailLabelType.all,
            destinations: [
              for (final d in destinations!)
                NavigationRailDestination(
                  icon: Icon(d.icon),
                  selectedIcon: Icon(d.selectedIcon),
                  label: Text(d.label),
                ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: body),
        ],
      ),
      floatingActionButton: floatingActionButton,
    );
  }

  // ---- sectioned mode ----

  Widget _buildSectioned(BuildContext context, ScreenSize screenSize) {
    final isDesktop = screenSize == ScreenSize.desktop;

    // A Builder gives the callback a context that is actually BELOW the
    // Scaffold this method creates (mobile/tablet: inside its `drawer:`;
    // desktop: inside the persistent rail, where Scaffold.of would find
    // isDrawerOpen == false and simply no-op) — calling Scaffold.of with
    // the outer `context` parameter instead throws, since that context
    // sits ABOVE the Scaffold being built.
    final drawerContent = Builder(
      builder: (drawerContext) => _NavDrawerContent(
        header: header,
        sections: sections!,
        currentRoute: currentRoute!,
        onNavSelected: (route) {
          onNavSelected!(route);
          // A temporary drawer (mobile/tablet) closes itself after a
          // selection; a persistent desktop rail has no drawer to close.
          if (!isDesktop && Scaffold.of(drawerContext).isDrawerOpen) {
            Navigator.of(drawerContext).pop();
          }
        },
      ),
    );

    final appBar = AppBar(
      title: title != null ? Text(title!) : null,
      actions: actions,
      // The drawer icon is supplied automatically by Scaffold whenever a
      // `drawer` is set and the layout isn't already showing it persistently
      // — explicit here only for isDesktop, where there is no drawer to
      // toggle at all.
      automaticallyImplyLeading: !isDesktop,
    );

    if (isDesktop) {
      return Scaffold(
        appBar: appBar,
        body: Row(
          children: [
            SizedBox(
              width: 280,
              child: Material(
                elevation: 1,
                child: drawerContent,
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(child: body),
          ],
        ),
        floatingActionButton: floatingActionButton,
      );
    }

    return Scaffold(
      appBar: appBar,
      drawer: Drawer(child: drawerContent),
      body: body,
      floatingActionButton: floatingActionButton,
    );
  }
}

class _NavDrawerContent extends StatelessWidget {
  const _NavDrawerContent({
    required this.header,
    required this.sections,
    required this.currentRoute,
    required this.onNavSelected,
  });

  final Widget? header;
  final List<NavSection> sections;
  final String currentRoute;
  final ValueChanged<String> onNavSelected;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          ?header,
          for (final section in sections) ...[
            if (section.title != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                child: Text(
                  section.title!.toUpperCase(),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        letterSpacing: 0.8,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
            for (final entry in section.entries)
              _NavEntryTile(
                entry: entry,
                selected: entry.route == currentRoute,
                onTap: () => onNavSelected(entry.route),
              ),
          ],
        ],
      ),
    );
  }
}

class _NavEntryTile extends StatelessWidget {
  const _NavEntryTile({
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  final NavSectionEntry entry;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: selected ? colorScheme.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: ListTile(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          leading: Icon(
            selected ? entry.selectedIcon : entry.icon,
            color: selected ? colorScheme.onSecondaryContainer : null,
          ),
          title: Text(
            entry.label,
            style: TextStyle(
              color: selected ? colorScheme.onSecondaryContainer : null,
              fontWeight: selected ? FontWeight.w600 : null,
            ),
          ),
          onTap: onTap,
        ),
      ),
    );
  }
}
