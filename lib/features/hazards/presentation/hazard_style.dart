import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../domain/hazard_category.dart';
import '../domain/hazard_kind.dart';
import '../domain/hazard_status.dart';

/// How each hazard category and status looks everywhere — the report form,
/// a worker's own reports, the reviewer's list and the detail screen — so a
/// fire hazard is always 🔥 red and a closed one always green.
extension HazardCategoryStyle on HazardCategory {
  Color get color => switch (this) {
    HazardCategory.workingAtHeight => AppColors.hazards,
    HazardCategory.electrical => AppColors.warning,
    HazardCategory.equipment => AppColors.projects,
    HazardCategory.ppe => AppColors.meetings,
    HazardCategory.housekeeping => AppColors.correctiveActions,
    HazardCategory.environment => AppColors.people,
    HazardCategory.chemical => AppColors.learning,
    HazardCategory.fire => AppColors.stop,
    HazardCategory.other => AppColors.textSecondary,
  };

  String get emoji => switch (this) {
    HazardCategory.workingAtHeight => '🪜',
    HazardCategory.electrical => '⚡',
    HazardCategory.equipment => '🔧',
    HazardCategory.ppe => '🦺',
    HazardCategory.housekeeping => '🧹',
    HazardCategory.environment => '🌿',
    HazardCategory.chemical => '☣️',
    HazardCategory.fire => '🔥',
    HazardCategory.other => '⚠️',
  };

  IconData get icon => switch (this) {
    HazardCategory.workingAtHeight => Icons.stairs,
    HazardCategory.electrical => Icons.bolt,
    HazardCategory.equipment => Icons.construction,
    HazardCategory.ppe => Icons.health_and_safety,
    HazardCategory.housekeeping => Icons.cleaning_services,
    HazardCategory.environment => Icons.eco,
    HazardCategory.chemical => Icons.science,
    HazardCategory.fire => Icons.local_fire_department,
    HazardCategory.other => Icons.warning_amber,
  };
}

extension HazardStatusStyle on HazardStatus {
  Color get color => switch (this) {
    HazardStatus.reported => AppColors.hazards,
    HazardStatus.acknowledged => AppColors.meetings,
    HazardStatus.correctiveActionCreated => AppColors.warning,
    HazardStatus.closed => AppColors.success,
  };

  IconData get icon => switch (this) {
    HazardStatus.reported => Icons.report,
    HazardStatus.acknowledged => Icons.visibility,
    HazardStatus.correctiveActionCreated => Icons.build_circle,
    HazardStatus.closed => Icons.check_circle,
  };
}

extension HazardKindStyle on HazardKind {
  Color get color => switch (this) {
    HazardKind.hazard => AppColors.hazards,
    HazardKind.nearMiss => AppColors.learning,
  };

  String get emoji => switch (this) {
    HazardKind.hazard => '⚠️',
    HazardKind.nearMiss => '😮',
  };

  IconData get icon => switch (this) {
    HazardKind.hazard => Icons.warning_amber,
    HazardKind.nearMiss => Icons.flash_on,
  };

  /// The plain-language question a worker answers on the report form.
  String get prompt => switch (this) {
    HazardKind.hazard => 'Something could happen',
    HazardKind.nearMiss => 'Something nearly happened',
  };
}
