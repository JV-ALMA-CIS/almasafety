import 'package:flutter/material.dart';
import '../theme/app_spacing.dart';
import '../utils/responsive.dart';

/// A responsive N-column grid for KPI/summary cards — mobile shows 2
/// columns, tablet 3, desktop 4, matching [Responsive.screenSizeOf]'s
/// existing breakpoints (the same ones [ResponsiveScaffold] already uses
/// for nav chrome; this is the content-grid counterpart it doesn't
/// provide).
///
/// A plain [Wrap] of fixed-width columns, sized from [MediaQuery] directly
/// rather than a [LayoutBuilder] (whose child-width computation, when this
/// grid sits inside an outer scrollable, previously raced with the first
/// hit-test pass and threw "Cannot hit test a render box with no size" on
/// some roles' dashboards) and rather than `GridView.count` (whose own
/// nested-scrollable semantics inside an outer [ListView] produced its own
/// layout errors and hid later content from the widget tree in tests). Each
/// child sizes its own height — [KpiCard] already does via
/// `mainAxisSize: MainAxisSize.min` — so only a fixed width is computed
/// here, up front, with no dependency on a constraints callback.
class DashboardGrid extends StatelessWidget {
  const DashboardGrid({super.key, required this.children});

  final List<Widget> children;

  int _columnsFor(BuildContext context) =>
      switch (Responsive.screenSizeOf(context)) {
        ScreenSize.mobile => 2,
        ScreenSize.tablet => 3,
        ScreenSize.desktop => 4,
      };

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    final columns = _columnsFor(context);
    // Matches this grid's expected container: an outer screen's
    // `ListView`/`Padding` with AppSpacing.md on both sides — see every
    // dashboard body screen, which all wrap their content the same way.
    final availableWidth = MediaQuery.sizeOf(context).width - AppSpacing.md * 2;
    const spacing = AppSpacing.sm;
    final width = (availableWidth - spacing * (columns - 1)) / columns;

    return Wrap(
      spacing: spacing,
      runSpacing: spacing,
      children: [
        for (final child in children) SizedBox(width: width, child: child),
      ],
    );
  }
}
