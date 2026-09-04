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

/// A scaffold that adapts primary navigation to the available width:
/// bottom navigation on mobile, a nav rail on tablet, and a full
/// nav drawer on desktop. Feature screens pass in their destinations and
/// render the current body; this widget only owns the navigation chrome.
class ResponsiveScaffold extends StatelessWidget {
  const ResponsiveScaffold({
    super.key,
    required this.body,
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
    this.title,
    this.actions,
    this.floatingActionButton,
  });

  final Widget body;
  final List<NavDestinationItem> destinations;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final String? title;
  final List<Widget>? actions;
  final Widget? floatingActionButton;

  @override
  Widget build(BuildContext context) {
    final screenSize = Responsive.screenSizeOf(context);

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
          selectedIndex: selectedIndex,
          onDestinationSelected: onDestinationSelected,
          destinations: [
            for (final d in destinations)
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
              for (final d in destinations)
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
}
