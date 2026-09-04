import 'package:flutter/widgets.dart';
import '../constants/app_constants.dart';

enum ScreenSize { mobile, tablet, desktop }

/// Breakpoint helpers used by responsive layouts across the app.
class Responsive {
  Responsive._();

  static ScreenSize screenSizeOf(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width >= AppConstants.tabletBreakpoint) return ScreenSize.desktop;
    if (width >= AppConstants.mobileBreakpoint) return ScreenSize.tablet;
    return ScreenSize.mobile;
  }

  static bool isMobile(BuildContext context) =>
      screenSizeOf(context) == ScreenSize.mobile;

  static bool isTablet(BuildContext context) =>
      screenSizeOf(context) == ScreenSize.tablet;

  static bool isDesktop(BuildContext context) =>
      screenSizeOf(context) == ScreenSize.desktop;
}
