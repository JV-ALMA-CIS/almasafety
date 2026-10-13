import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../domain/incident_enums.dart';

/// How each incident type, severity and status looks everywhere — the
/// report form, the lists and the detail screen.
extension IncidentTypeStyle on IncidentType {
  Color get color => switch (this) {
    IncidentType.injury => AppColors.stop,
    IncidentType.propertyDamage => AppColors.projects,
    IncidentType.environmental => AppColors.people,
    IncidentType.dangerousOccurrence => AppColors.safetyAlerts,
    IncidentType.other => AppColors.reports,
  };

  String get emoji => switch (this) {
    IncidentType.injury => '🤕',
    IncidentType.propertyDamage => '💥',
    IncidentType.environmental => '🛢️',
    IncidentType.dangerousOccurrence => '🚨',
    IncidentType.other => '📝',
  };

  IconData get icon => switch (this) {
    IncidentType.injury => Icons.personal_injury,
    IncidentType.propertyDamage => Icons.broken_image,
    IncidentType.environmental => Icons.water_drop,
    IncidentType.dangerousOccurrence => Icons.crisis_alert,
    IncidentType.other => Icons.help_outline,
  };
}

extension IncidentSeverityStyle on IncidentSeverity {
  Color get color => switch (this) {
    IncidentSeverity.minor => AppColors.warning,
    IncidentSeverity.moderate => AppColors.hazards,
    IncidentSeverity.serious => AppColors.stop,
  };
}

extension IncidentStatusStyle on IncidentStatus {
  Color get color => switch (this) {
    IncidentStatus.reported => AppColors.stop,
    IncidentStatus.underInvestigation => AppColors.meetings,
    IncidentStatus.closed => AppColors.success,
  };

  IconData get icon => switch (this) {
    IncidentStatus.reported => Icons.report,
    IncidentStatus.underInvestigation => Icons.manage_search,
    IncidentStatus.closed => Icons.check_circle,
  };
}
