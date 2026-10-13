import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/features/corrective_actions/domain/corrective_action.dart';
import 'package:jva_safety/features/corrective_actions/domain/corrective_action_status.dart';
import 'package:jva_safety/features/corrective_actions/presentation/report_progress.dart';
import 'package:jva_safety/features/hazards/domain/hazard.dart';
import 'package:jva_safety/features/hazards/domain/hazard_category.dart';
import 'package:jva_safety/features/hazards/domain/hazard_status.dart';
import 'package:jva_safety/features/incidents/domain/incident.dart';
import 'package:jva_safety/features/incidents/domain/incident_enums.dart';

Incident _incident(IncidentStatus status) => Incident(
  id: 'i1',
  organizationId: 'org',
  projectId: 'p',
  siteId: 's',
  reportedByUid: 'w',
  type: IncidentType.injury,
  description: 'Cut hand',
  occurredAt: DateTime(2026, 10, 12),
  status: status,
);

CorrectiveAction _action(CorrectiveActionStatus status, {String id = 'a'}) =>
    CorrectiveAction(
      id: id,
      organizationId: 'org',
      projectId: 'p',
      siteId: 's',
      title: 'Fix',
      description: 'Fix it',
      assignedTo: 'f',
      assignedBy: 'm',
      dueDate: DateTime(2026, 10, 20),
      status: status,
      evidenceRequired: false,
      incidentId: 'i1',
    );

Hazard _hazard(HazardStatus status) => Hazard(
  id: 'h1',
  organizationId: 'org',
  projectId: 'p',
  siteId: 's',
  reportedByUid: 'w',
  category: HazardCategory.electrical,
  description: 'Exposed wire',
  status: status,
  correctiveActionId: 'a',
);

void main() {
  group('incident tag follows its corrective actions', () {
    String tag(IncidentStatus status, List<CorrectiveAction> actions) =>
        ReportProgress.forIncident(_incident(status), actions).label;

    test('reported → waiting for investigation', () {
      expect(tag(IncidentStatus.reported, []), 'Waiting for investigation');
    });

    test('investigating with no actions yet', () {
      expect(tag(IncidentStatus.underInvestigation, []), 'Under investigation');
    });

    test('actions being worked on show how many are done', () {
      expect(
        tag(IncidentStatus.underInvestigation, [
          _action(CorrectiveActionStatus.completed),
          _action(CorrectiveActionStatus.inProgress, id: 'b'),
        ]),
        'Actions in progress (1/2 done)',
      );
    });

    test('evidence submitted → awaiting review — the case reported in the '
        'field, where the tag stayed "Under Investigation"', () {
      expect(
        tag(IncidentStatus.underInvestigation, [
          _action(CorrectiveActionStatus.submittedForReview),
        ]),
        'Awaiting review',
      );
    });

    test('every action approved → ready to close', () {
      expect(
        tag(IncidentStatus.underInvestigation, [
          _action(CorrectiveActionStatus.completed),
        ]),
        'Ready to close',
      );
    });

    test('closed', () {
      expect(tag(IncidentStatus.closed, []), 'Closed');
    });
  });

  group('hazard tag follows its corrective action', () {
    String tag(HazardStatus status, CorrectiveActionStatus? actionStatus) =>
        ReportProgress.forHazard(
          _hazard(status),
          actionStatus == null ? null : _action(actionStatus),
        ).label;

    test('being fixed, then awaiting review, then closed', () {
      expect(
        tag(HazardStatus.correctiveActionCreated, CorrectiveActionStatus.open),
        'Being fixed',
      );
      expect(
        tag(
          HazardStatus.correctiveActionCreated,
          CorrectiveActionStatus.submittedForReview,
        ),
        'Awaiting review',
      );
      expect(
        tag(HazardStatus.closed, CorrectiveActionStatus.completed),
        'Closed',
      );
    });

    test('no action yet keeps the hazard status', () {
      expect(tag(HazardStatus.reported, null), 'Reported');
      expect(tag(HazardStatus.acknowledged, null), 'Acknowledged');
    });
  });
}
