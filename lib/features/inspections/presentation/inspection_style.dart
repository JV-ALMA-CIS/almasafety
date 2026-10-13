import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../domain/inspection.dart';

/// How inspection kinds, answers and statuses look everywhere.
extension InspectionKindStyle on InspectionKind {
  IconData get icon => switch (this) {
    InspectionKind.daily => Icons.today,
    InspectionKind.weekly => Icons.fact_check,
    InspectionKind.environmental => Icons.eco,
    InspectionKind.welfare => Icons.volunteer_activism,
    InspectionKind.other => Icons.checklist,
  };

  Color get color => switch (this) {
    InspectionKind.daily => AppColors.inspections,
    InspectionKind.weekly => AppColors.meetings,
    InspectionKind.environmental => AppColors.people,
    InspectionKind.welfare => AppColors.learning,
    InspectionKind.other => AppColors.reports,
  };
}

extension InspectionResultStyle on InspectionResult {
  Color get color => switch (this) {
    InspectionResult.ok => AppColors.success,
    InspectionResult.notOk => AppColors.stop,
    InspectionResult.na => AppColors.textSecondary,
  };

  String get emoji => switch (this) {
    InspectionResult.ok => '✅',
    InspectionResult.notOk => '❌',
    InspectionResult.na => '➖',
  };
}

extension InspectionStatusStyle on InspectionStatus {
  Color get color => switch (this) {
    InspectionStatus.inProgress => AppColors.warning,
    InspectionStatus.submitted => AppColors.analytics,
    InspectionStatus.signedOff => AppColors.success,
  };

  IconData get icon => switch (this) {
    InspectionStatus.inProgress => Icons.edit_note,
    InspectionStatus.submitted => Icons.hourglass_top,
    InspectionStatus.signedOff => Icons.verified,
  };
}
