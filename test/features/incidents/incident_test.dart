import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/features/corrective_actions/domain/corrective_action.dart';
import 'package:jva_safety/features/incidents/domain/incident.dart';
import 'package:jva_safety/features/incidents/domain/incident_enums.dart';

void main() {
  Map<String, dynamic> minimal([Map<String, dynamic> extra = const {}]) => {
    'organizationId': 'org-alpha',
    'projectId': 'project-1',
    'siteId': 'site-1',
    'reportedByUid': 'worker-1',
    'type': 'injury',
    'description': 'Cut hand on sheet metal',
    'occurredAt': Timestamp.fromDate(DateTime(2026, 10, 9, 8, 30)),
    'status': 'reported',
    ...extra,
  };

  test('parses a newly reported incident', () {
    final incident = Incident.fromMap(
      'incident-1',
      minimal({
        'injuredPersonName': 'John',
        'immediateAction': 'First aid given',
        'severity': null,
        'correctiveActionIds': <String>[],
      }),
    );

    expect(incident.type, IncidentType.injury);
    expect(incident.status, IncidentStatus.reported);
    expect(incident.occurredAt, DateTime(2026, 10, 9, 8, 30));
    expect(incident.injuredPersonName, 'John');
    expect(incident.severity, isNull);
    expect(incident.correctiveActionIds, isEmpty);
    expect(incident.isClosed, isFalse);
  });

  test('parses an investigated, closed incident', () {
    final incident = Incident.fromMap(
      'incident-1',
      minimal({
        'status': 'closed',
        'severity': 'serious',
        'correctiveActionIds': ['ca-1', 'ca-2'],
        'rootCause': 'No edge guards',
      }),
    );

    expect(incident.isClosed, isTrue);
    expect(incident.severity, IncidentSeverity.serious);
    expect(incident.correctiveActionIds, ['ca-1', 'ca-2']);
    expect(incident.rootCause, 'No edge guards');
  });

  test('throws on an unrecognised type, status or severity', () {
    for (final bad in [
      {'type': 'nearMiss'},
      {'status': 'open'},
      {'severity': 'catastrophic'},
    ]) {
      expect(
        () => Incident.fromMap('incident-1', minimal(bad)),
        throwsA(isA<DataException>()),
        reason: '$bad',
      );
    }
  });

  test('throws when occurredAt is missing', () {
    final data = minimal()..remove('occurredAt');
    expect(
      () => Incident.fromMap('incident-1', data),
      throwsA(isA<DataException>()),
    );
  });

  test('a corrective action may originate from an incident', () {
    final action = CorrectiveAction.fromMap('ca-1', {
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': 'site-1',
      'meetingId': null,
      'hazardId': null,
      'incidentId': 'incident-1',
      'title': 'Fit edge guards',
      'description': 'Fit guards to sheet metal edges',
      'assignedTo': 'worker-2',
      'assignedBy': 'reviewer-a',
      'dueDate': Timestamp.now(),
      'status': 'open',
      'evidenceRequired': false,
    });
    expect(action.incidentId, 'incident-1');
    expect(action.hazardId, isNull);
  });

  test('a corrective action naming two origins is refused', () {
    expect(
      () => CorrectiveAction.fromMap('ca-1', {
        'organizationId': 'org-alpha',
        'projectId': 'project-1',
        'siteId': 'site-1',
        'hazardId': 'hazard-1',
        'incidentId': 'incident-1',
        'title': 'x',
        'description': 'x',
        'assignedTo': 'worker-2',
        'assignedBy': 'reviewer-a',
        'dueDate': Timestamp.now(),
        'status': 'open',
        'evidenceRequired': false,
      }),
      throwsA(isA<DataException>()),
    );
  });
}
