import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/dashboard_grid.dart';
import '../../../core/widgets/kpi_card.dart';
import '../../../routing/app_routes.dart';
import '../../hazards/domain/hazard.dart';
import '../../hazards/domain/hazard_kind.dart';
import '../../hazards/domain/hazard_status.dart';
import '../../incidents/domain/incident.dart';
import '../../incidents/domain/incident_enums.dart';

/// The "Safety Reports" counts on a supervisor's dashboard — everything
/// workers report through **Report a Safety Issue**, side by side:
/// open hazards, open near-misses, open incidents, and (for whoever
/// investigates) incidents nobody has picked up yet. Each count opens the
/// list it comes from (Hazards or Incidents).
class SafetyReportsCard extends StatelessWidget {
  const SafetyReportsCard({
    super.key,
    required this.hazards,
    required this.incidents,
    this.showToInvestigate = false,
  });

  /// Hazard reports, near-misses included (they are a hazard kind).
  final List<Hazard> hazards;
  final List<Incident> incidents;

  /// Adds the "to investigate" count — for Site Managers/Admins, who start
  /// incident investigations.
  final bool showToInvestigate;

  @override
  Widget build(BuildContext context) {
    final openHazards = hazards
        .where(
          (h) => h.kind == HazardKind.hazard && h.status != HazardStatus.closed,
        )
        .length;
    final openNearMisses = hazards
        .where(
          (h) =>
              h.kind == HazardKind.nearMiss && h.status != HazardStatus.closed,
        )
        .length;
    final openIncidents = incidents.where((i) => !i.isClosed).length;
    final toInvestigate = incidents
        .where((i) => i.status == IncidentStatus.reported)
        .length;

    return DashboardGrid(
      children: [
        KpiCard(
          value: '$openHazards',
          label: openHazards == 1 ? 'open hazard' : 'open hazards',
          icon: Icons.warning_amber_outlined,
          color: openHazards > 0 ? AppColors.hazards : AppColors.success,
          onTap: () => context.go(AppRoutes.hazards),
        ),
        KpiCard(
          value: '$openNearMisses',
          label: openNearMisses == 1 ? 'open near-miss' : 'open near-misses',
          icon: Icons.flash_on,
          color: openNearMisses > 0 ? AppColors.learning : AppColors.success,
          onTap: () => context.go(AppRoutes.hazards),
        ),
        KpiCard(
          value: '$openIncidents',
          label: openIncidents == 1 ? 'open incident' : 'open incidents',
          icon: Icons.personal_injury_outlined,
          color: openIncidents > 0 ? AppColors.stop : AppColors.success,
          onTap: () => context.go(AppRoutes.incidents),
        ),
        if (showToInvestigate)
          KpiCard(
            value: '$toInvestigate',
            label: 'to investigate',
            icon: Icons.manage_search,
            color: toInvestigate > 0 ? AppColors.stop : AppColors.success,
            onTap: () => context.go(AppRoutes.incidents),
          ),
      ],
    );
  }
}
