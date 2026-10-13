import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../hazards/domain/hazard.dart';
import '../../hazards/domain/hazard_status.dart';
import '../../incidents/domain/incident.dart';
import '../../incidents/domain/incident_enums.dart';
import '../domain/corrective_action.dart';
import '../domain/corrective_action_status.dart';

/// Where a reported hazard or incident really is — worked out from its own
/// status AND its corrective actions, so the tag moves on by itself as the
/// fix is done: "Actions in progress (1/2 done)" → "Awaiting review" →
/// "Ready to close". The stored status alone can't say this (an incident
/// stays "under investigation" from the moment it is picked up until it is
/// closed). Nothing extra is stored; every screen computes the same thing.
class ReportProgress {
  const ReportProgress(this.label, this.color, this.icon);

  final String label;
  final Color color;
  final IconData icon;

  static const _closed = ReportProgress(
    'Closed',
    AppColors.success,
    Icons.check_circle,
  );
  static const _awaitingReview = ReportProgress(
    'Awaiting review',
    AppColors.analytics,
    Icons.fact_check,
  );

  /// The progress of [incident], given the corrective actions raised from
  /// it.
  factory ReportProgress.forIncident(
    Incident incident,
    List<CorrectiveAction> actions,
  ) {
    if (incident.isClosed) return _closed;
    if (incident.status == IncidentStatus.reported) {
      return const ReportProgress(
        'Waiting for investigation',
        AppColors.stop,
        Icons.hourglass_top,
      );
    }
    if (actions.isEmpty) {
      return const ReportProgress(
        'Under investigation',
        AppColors.meetings,
        Icons.manage_search,
      );
    }
    if (actions.any(
      (a) => a.status == CorrectiveActionStatus.submittedForReview,
    )) {
      return _awaitingReview;
    }
    final done = actions.where((a) => a.isCompleted).length;
    if (done == actions.length) {
      return const ReportProgress(
        'Ready to close',
        AppColors.go,
        Icons.task_alt,
      );
    }
    return ReportProgress(
      'Actions in progress ($done/${actions.length} done)',
      AppColors.correctiveActions,
      Icons.build_circle,
    );
  }

  /// The progress of [hazard], given its linked corrective action (if
  /// loaded).
  factory ReportProgress.forHazard(Hazard hazard, CorrectiveAction? action) {
    if (hazard.status == HazardStatus.closed) return _closed;
    if (action != null) {
      if (action.status == CorrectiveActionStatus.submittedForReview) {
        return _awaitingReview;
      }
      if (!action.isCompleted) {
        return const ReportProgress(
          'Being fixed',
          AppColors.correctiveActions,
          Icons.build_circle,
        );
      }
    }
    return switch (hazard.status) {
      HazardStatus.reported => const ReportProgress(
        'Reported',
        AppColors.hazards,
        Icons.report,
      ),
      HazardStatus.acknowledged => const ReportProgress(
        'Acknowledged',
        AppColors.meetings,
        Icons.visibility,
      ),
      _ => const ReportProgress(
        'Being fixed',
        AppColors.correctiveActions,
        Icons.build_circle,
      ),
    };
  }
}

/// Groups [actions] by the incident they were raised from.
Map<String, List<CorrectiveAction>> actionsByIncident(
  List<CorrectiveAction> actions,
) {
  final grouped = <String, List<CorrectiveAction>>{};
  for (final action in actions) {
    final incidentId = action.incidentId;
    if (incidentId != null) (grouped[incidentId] ??= []).add(action);
  }
  return grouped;
}
