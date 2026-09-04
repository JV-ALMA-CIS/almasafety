import 'package:flutter/material.dart';

/// Brand and semantic colors for JVA Safety.
///
/// Semantic safety colors (danger/warning/success) are used consistently
/// across hazards, corrective actions, and alerts so severity is always
/// recognizable at a glance regardless of feature.
class AppColors {
  AppColors._();

  // Brand
  static const Color primary = Color(0xFF0B4F6C);
  static const Color primaryDark = Color(0xFF083B52);
  static const Color secondary = Color(0xFFF2A20C);

  // Neutrals
  static const Color background = Color(0xFFF5F7F8);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceDark = Color(0xFF13202B);
  static const Color backgroundDark = Color(0xFF0D171F);

  // Safety semantics
  static const Color danger = Color(0xFFC62828);
  static const Color warning = Color(0xFFF9A825);
  static const Color success = Color(0xFF2E7D32);
  static const Color info = Color(0xFF0277BD);

  // Text
  static const Color textPrimary = Color(0xFF12222E);
  static const Color textSecondary = Color(0xFF51636E);
  static const Color textOnPrimary = Color(0xFFFFFFFF);
}
