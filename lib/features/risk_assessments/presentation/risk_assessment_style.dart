import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../domain/risk_assessment.dart';

/// Hazards in red, controls in green — everywhere an AHA is shown.
const ahaHazardColor = AppColors.stop;
const ahaControlColor = AppColors.go;

extension RiskAssessmentStatusStyle on RiskAssessmentStatus {
  Color get color => switch (this) {
    RiskAssessmentStatus.draft => AppColors.warning,
    RiskAssessmentStatus.accepted => AppColors.go,
    RiskAssessmentStatus.superseded => AppColors.textSecondary,
  };

  IconData get icon => switch (this) {
    RiskAssessmentStatus.draft => Icons.edit_note,
    RiskAssessmentStatus.accepted => Icons.verified,
    RiskAssessmentStatus.superseded => Icons.history,
  };
}

/// e.g. "2026-10-13" for [date].
String formatAhaDate(DateTime? date) {
  if (date == null) return '—';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)}';
}
