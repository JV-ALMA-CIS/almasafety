import 'package:flutter/material.dart';

/// Base text styles for JVA Safety.
///
/// Field-facing screens (worker/foreman) should prefer the larger sizes here
/// for legibility in outdoor/site conditions; supervisor/admin screens can
/// use the smaller, denser styles for data-rich views.
///
/// **Deliberately no `color` here.** Every one of these is passed straight
/// to a [Text]'s `style` across ~40 call sites, none of which supply a
/// color of their own — [Text] fills any field left `null` on its `style`
/// from the ambient [DefaultTextStyle] (which [MaterialApp]'s `theme`/
/// `darkTheme` already derives correctly per [Brightness]). A hardcoded
/// `AppColors.textPrimary`/`textSecondary` here previously overrode that
/// fallback outright — on a dark-mode system, `darkTheme` correctly swapped
/// the background to a near-black surface while these styles kept forcing
/// near-black TEXT on top of it, rendering nearly everything unreadable.
/// Leaving color unset here is what actually lets [AppTheme]'s light/dark
/// split do its job.
class AppTextStyles {
  AppTextStyles._();

  static const String fontFamily = 'Roboto';

  static const TextStyle headlineLarge = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w700,
    height: 1.2,
  );

  static const TextStyle headlineMedium = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w700,
    height: 1.25,
  );

  static const TextStyle titleLarge = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w600,
  );

  static const TextStyle bodyLarge = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w400,
    height: 1.4,
  );

  static const TextStyle bodyMedium = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.4,
  );

  static const TextStyle label = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.2,
  );
}
