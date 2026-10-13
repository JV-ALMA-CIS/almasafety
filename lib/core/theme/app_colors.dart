import 'package:flutter/material.dart';

/// Brand and semantic colors for JVA Safety.
///
/// Semantic safety colors (danger/warning/success) are used consistently
/// across hazards, corrective actions, and alerts so severity is always
/// recognizable at a glance regardless of feature.
///
/// Each feature also carries its own bright accent color (see "Feature
/// accents" below) so a field user can recognise a screen, a nav entry or a
/// dashboard tile by color alone — the same tile is always the same color
/// wherever it appears.
class AppColors {
  AppColors._();

  // Brand
  static const Color primary = Color(0xFF0B4F6C);
  static const Color primaryDark = Color(0xFF083B52);
  static const Color primaryBright = Color(0xFF1287A8);
  static const Color secondary = Color(0xFFF2A20C);

  /// The brand banner gradient — dashboard headers and the sidebar header.
  static const LinearGradient brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [primary, primaryBright],
  );

  // Neutrals
  static const Color background = Color(0xFFF2F6F9);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceDark = Color(0xFF13202B);
  static const Color backgroundDark = Color(0xFF0D171F);

  // Safety semantics
  static const Color danger = Color(0xFFC62828);
  static const Color warning = Color(0xFFF9A825);
  static const Color success = Color(0xFF2E7D32);
  static const Color info = Color(0xFF0277BD);

  // Go / no-go outcomes. Two greens because both mean work started; they
  // stay distinguishable under red-green color blindness by lightness, and
  // every use pairs the color with a text label.
  static const Color go = Color(0xFF0E7C5A);
  static const Color goCorrected = Color(0xFF6AA22B);
  static const Color stop = Color(0xFFC81E1E);

  // Feature accents
  static const Color dashboard = Color(0xFF1287A8);
  static const Color projects = Color(0xFF3949AB);
  static const Color hazards = Color(0xFFEF6C00);
  static const Color correctiveActions = Color(0xFF00897B);
  static const Color safetyAlerts = Color(0xFFD81B60);
  static const Color meetings = Color(0xFF1E6FD9);
  static const Color learning = Color(0xFF7B3FE4);
  static const Color videos = Color(0xFFE53935);
  static const Color compliance = Color(0xFF2E7D32);
  static const Color analytics = Color(0xFF0097A7);
  static const Color reports = Color(0xFF6D4C41);
  static const Color people = Color(0xFF43A047);
  static const Color administration = Color(0xFF5E35B1);
  static const Color requirements = Color(0xFFC0CA33);
  static const Color inspections = Color(0xFF00838F);

  // Text
  static const Color textPrimary = Color(0xFF12222E);
  static const Color textSecondary = Color(0xFF51636E);
  static const Color textOnPrimary = Color(0xFFFFFFFF);

  /// A stable accent for any free-text label (e.g. a meeting point
  /// category): the same label always gets the same color.
  static Color forLabel(String label) {
    const palette = [
      meetings,
      learning,
      hazards,
      correctiveActions,
      projects,
      analytics,
      safetyAlerts,
      people,
    ];
    var hash = 0;
    for (final unit in label.toLowerCase().codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return palette[hash % palette.length];
  }

  /// Text/icon color to draw ON a solid [background] of this color —
  /// white on dark fills, near-black on light ones (e.g. [warning] yellow).
  static Color onColor(Color background) =>
      ThemeData.estimateBrightnessForColor(background) == Brightness.dark
      ? Colors.white
      : textPrimary;

  /// [color] adjusted so it stays readable as TEXT on the current surface:
  /// light fills (yellow, lime) are darkened on a light surface, and every
  /// accent is lifted on a dark surface where the deep brand tones would
  /// otherwise disappear.
  static Color readable(Color color, Brightness brightness) {
    if (brightness == Brightness.dark) {
      return Color.lerp(color, Colors.white, 0.3)!;
    }
    return color.computeLuminance() > 0.35
        ? Color.lerp(color, Colors.black, 0.35)!
        : color;
  }
}
