import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/features/safety_alerts/domain/safety_alert.dart';
import 'package:jva_safety/features/safety_alerts/domain/safety_alert_category.dart';
import 'package:jva_safety/features/safety_alerts/domain/safety_alert_severity.dart';
import 'package:jva_safety/features/safety_alerts/domain/safety_alert_status.dart';

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<DocumentSnapshot<Map<String, dynamic>>> seed(
    Map<String, dynamic> data,
  ) async {
    final ref = firestore.doc('organizations/org-alpha/safety_alerts/a1');
    await ref.set(data);
    return ref.get();
  }

  test('fromFirestore parses every field', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': 'site-1',
      'title': 'Crane inspection overdue',
      'description': 'Crane 3 has not been inspected this week',
      'severity': 'high',
      'category': 'equipment',
      'status': 'active',
      'createdBy': 'manager-1',
      'createdAt': Timestamp.now(),
      'acknowledgedAt': Timestamp.now(),
      'acknowledgedBy': 'supervisor-1',
      'resolvedAt': Timestamp.now(),
      'resolvedBy': 'supervisor-1',
    });

    final alert = SafetyAlert.fromFirestore(doc);

    expect(alert.id, 'a1');
    expect(alert.organizationId, 'org-alpha');
    expect(alert.projectId, 'project-1');
    expect(alert.siteId, 'site-1');
    expect(alert.title, 'Crane inspection overdue');
    expect(alert.description, 'Crane 3 has not been inspected this week');
    expect(alert.severity, SafetyAlertSeverity.high);
    expect(alert.category, SafetyAlertCategory.equipment);
    expect(alert.status, SafetyAlertStatus.active);
    expect(alert.createdBy, 'manager-1');
    expect(alert.acknowledgedBy, 'supervisor-1');
    expect(alert.resolvedBy, 'supervisor-1');
  });

  test('isActive and isResolved reflect status correctly', () async {
    for (final status in SafetyAlertStatus.values) {
      final doc = await seed({
        'organizationId': 'org-alpha',
        'projectId': 'project-1',
        'siteId': 'site-1',
        'title': 'x',
        'description': 'x',
        'severity': 'low',
        'category': 'other',
        'status': status.id,
        'createdBy': 'manager-1',
      });
      final alert = SafetyAlert.fromFirestore(doc);
      expect(
        alert.isActive,
        status == SafetyAlertStatus.active,
        reason: 'status ${status.id}',
      );
      expect(
        alert.isResolved,
        status == SafetyAlertStatus.resolved,
        reason: 'status ${status.id}',
      );
    }
  });

  test('optional acknowledgement/resolution fields default to null', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': 'site-1',
      'title': 'x',
      'description': 'x',
      'severity': 'low',
      'category': 'other',
      'status': 'active',
      'createdBy': 'manager-1',
    });

    final alert = SafetyAlert.fromFirestore(doc);

    expect(alert.acknowledgedAt, isNull);
    expect(alert.acknowledgedBy, isNull);
    expect(alert.resolvedAt, isNull);
    expect(alert.resolvedBy, isNull);
  });

  test('throws when organizationId is missing', () async {
    final doc = await seed({
      'projectId': 'project-1',
      'siteId': 'site-1',
      'title': 'x',
      'description': 'x',
      'severity': 'low',
      'category': 'other',
      'status': 'active',
      'createdBy': 'manager-1',
    });

    expect(() => SafetyAlert.fromFirestore(doc), throwsA(isA<DataException>()));
  });

  test('throws when projectId is missing', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'siteId': 'site-1',
      'title': 'x',
      'description': 'x',
      'severity': 'low',
      'category': 'other',
      'status': 'active',
      'createdBy': 'manager-1',
    });

    expect(() => SafetyAlert.fromFirestore(doc), throwsA(isA<DataException>()));
  });

  test('throws when siteId is missing', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'title': 'x',
      'description': 'x',
      'severity': 'low',
      'category': 'other',
      'status': 'active',
      'createdBy': 'manager-1',
    });

    expect(() => SafetyAlert.fromFirestore(doc), throwsA(isA<DataException>()));
  });

  test('throws when title is missing', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': 'site-1',
      'description': 'x',
      'severity': 'low',
      'category': 'other',
      'status': 'active',
      'createdBy': 'manager-1',
    });

    expect(() => SafetyAlert.fromFirestore(doc), throwsA(isA<DataException>()));
  });

  test('throws when description is missing', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': 'site-1',
      'title': 'x',
      'severity': 'low',
      'category': 'other',
      'status': 'active',
      'createdBy': 'manager-1',
    });

    expect(() => SafetyAlert.fromFirestore(doc), throwsA(isA<DataException>()));
  });

  test('throws when createdBy is missing', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': 'site-1',
      'title': 'x',
      'description': 'x',
      'severity': 'low',
      'category': 'other',
      'status': 'active',
    });

    expect(() => SafetyAlert.fromFirestore(doc), throwsA(isA<DataException>()));
  });

  test('throws on an unrecognised status', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': 'site-1',
      'title': 'x',
      'description': 'x',
      'severity': 'low',
      'category': 'other',
      'status': 'closed',
      'createdBy': 'manager-1',
    });

    expect(() => SafetyAlert.fromFirestore(doc), throwsA(isA<DataException>()));
  });

  test('throws on an unrecognised severity', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': 'site-1',
      'title': 'x',
      'description': 'x',
      'severity': 'extreme',
      'category': 'other',
      'status': 'active',
      'createdBy': 'manager-1',
    });

    expect(() => SafetyAlert.fromFirestore(doc), throwsA(isA<DataException>()));
  });

  test('throws on an unrecognised category', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': 'site-1',
      'title': 'x',
      'description': 'x',
      'severity': 'low',
      'category': 'noise',
      'status': 'active',
      'createdBy': 'manager-1',
    });

    expect(() => SafetyAlert.fromFirestore(doc), throwsA(isA<DataException>()));
  });

  test('every SafetyAlertStatus round-trips through its stored id', () {
    for (final status in SafetyAlertStatus.values) {
      expect(SafetyAlertStatus.tryFromId(status.id), status);
    }
    expect(SafetyAlertStatus.tryFromId('unknown'), isNull);
    expect(SafetyAlertStatus.tryFromId(null), isNull);
  });

  test('every SafetyAlertSeverity round-trips through its stored id', () {
    for (final severity in SafetyAlertSeverity.values) {
      expect(SafetyAlertSeverity.tryFromId(severity.id), severity);
    }
    expect(SafetyAlertSeverity.tryFromId('unknown'), isNull);
    expect(SafetyAlertSeverity.tryFromId(null), isNull);
  });

  test('every SafetyAlertCategory round-trips through its stored id', () {
    for (final category in SafetyAlertCategory.values) {
      expect(SafetyAlertCategory.tryFromId(category.id), category);
    }
    expect(SafetyAlertCategory.tryFromId('unknown'), isNull);
    expect(SafetyAlertCategory.tryFromId(null), isNull);
  });

  test('the four expected statuses exist', () {
    expect(SafetyAlertStatus.values.map((s) => s.id).toSet(), {
      'active',
      'acknowledged',
      'resolved',
    });
  });

  test('the four expected severities exist', () {
    expect(SafetyAlertSeverity.values.map((s) => s.id).toSet(), {
      'low',
      'medium',
      'high',
      'critical',
    });
  });

  test('the six expected categories exist', () {
    expect(SafetyAlertCategory.values.map((c) => c.id).toSet(), {
      'safety',
      'equipment',
      'environment',
      'weather',
      'site',
      'other',
    });
  });
}
