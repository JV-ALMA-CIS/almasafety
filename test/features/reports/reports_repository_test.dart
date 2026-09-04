import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/features/authentication/data/account_approval_service.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/organization_user.dart';
import 'package:jva_safety/features/daily_safety_meetings/domain/meeting_attendance_status.dart';
import 'package:jva_safety/features/reports/data/reports_repository.dart';
import 'package:jva_safety/features/safety_alerts/domain/safety_alert_severity.dart';
import 'package:jva_safety/features/safety_alerts/domain/safety_alert_status.dart';

/// Subclasses the real service rather than introducing a mocking package,
/// following the repo's existing pattern — see
/// `test/features/authentication/organization_users_screen_test.dart`.
class _FakeApprovalService extends AccountApprovalService {
  _FakeApprovalService(this.users);

  final List<OrganizationUser> users;

  @override
  Future<List<OrganizationUser>> listUsers({
    AccountStatus status = AccountStatus.active,
  }) async => users;
}

OrganizationUser _worker(String uid) => OrganizationUser(
  uid: uid,
  name: uid,
  email: '$uid@example.com',
  accountStatus: AccountStatus.active,
);

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<void> seedProject(String orgId, String id, {String name = 'P1'}) =>
      firestore.doc('organizations/$orgId/projects/$id').set({
        'organizationId': orgId,
        'name': name,
        'code': id,
        'status': 'active',
      });

  Future<void> seedSite(
    String orgId,
    String id, {
    String projectId = 'project-1',
    String name = 'Site',
  }) =>
      firestore.doc('organizations/$orgId/sites/$id').set({
        'organizationId': orgId,
        'projectId': projectId,
        'name': name,
        'code': id,
        'status': 'active',
      });

  Future<void> seedMeeting(
    String orgId,
    String id, {
    String projectId = 'project-1',
    String siteId = 'site-1',
    String date = '2026-01-15',
    String foremanId = 'foreman-1',
    List<String> activityIds = const ['a1'],
    List<String> meetingPointIds = const ['p1'],
    List<String> correctiveActionIds = const [],
  }) =>
      firestore.doc('organizations/$orgId/daily_safety_meetings/$id').set({
        'organizationId': orgId,
        'projectId': projectId,
        'siteId': siteId,
        'date': date,
        'foremanId': foremanId,
        'activityIds': activityIds,
        'meetingPointIds': meetingPointIds,
        'status': 'completed',
        'concerns': <String>[],
        'correctiveActionIds': correctiveActionIds,
        'createdAt': Timestamp.now(),
      });

  Future<void> seedAttendance(
    String orgId,
    String meetingId,
    String workerId, {
    required MeetingAttendanceStatus status,
  }) =>
      firestore
          .doc(
            'organizations/$orgId/daily_safety_meetings/$meetingId/attendance/'
            '$workerId',
          )
          .set({
        'meetingId': meetingId,
        'organizationId': orgId,
        'siteId': 'site-1',
        'workerId': workerId,
        'status': status.id,
        'recordedAt': Timestamp.now(),
        'recordedBy': 'foreman-1',
      });

  Future<void> seedConcern(String orgId, String meetingId, String id) =>
      firestore
          .doc(
            'organizations/$orgId/daily_safety_meetings/$meetingId/concerns/'
            '$id',
          )
          .set({
        'meetingId': meetingId,
        'organizationId': orgId,
        'siteId': 'site-1',
        'description': 'Concern $id',
        'category': 'safety',
        'reportedBy': 'foreman-1',
        'status': 'open',
        'createdAt': Timestamp.now(),
      });

  Future<void> seedAlert(
    String orgId,
    String id, {
    String siteId = 'site-1',
    String severity = 'high',
    String status = 'active',
    DateTime? createdAt,
    DateTime? resolvedAt,
  }) =>
      firestore.doc('organizations/$orgId/safety_alerts/$id').set({
        'organizationId': orgId,
        'projectId': 'project-1',
        'siteId': siteId,
        'title': 'Alert $id',
        'description': 'Description $id',
        'severity': severity,
        'category': 'safety',
        'status': status,
        'createdBy': 'manager-1',
        'createdAt': Timestamp.fromDate(createdAt ?? DateTime(2026, 1, 10)),
        'resolvedAt': resolvedAt == null ? null : Timestamp.fromDate(resolvedAt),
      });

  Future<void> seedAction(
    String orgId,
    String id, {
    String siteId = 'site-1',
    String status = 'open',
    DateTime? dueDate,
  }) =>
      firestore.doc('organizations/$orgId/corrective_actions/$id').set({
        'organizationId': orgId,
        'projectId': 'project-1',
        'siteId': siteId,
        'meetingId': 'm1',
        'title': 'Action $id',
        'description': 'Description $id',
        'assignedTo': 'worker-1',
        'assignedBy': 'foreman-1',
        'dueDate': Timestamp.fromDate(dueDate ?? DateTime(2026, 1, 20)),
        'status': status,
        'evidenceRequired': false,
        'createdAt': Timestamp.now(),
        'updatedAt': Timestamp.now(),
      });

  Future<void> seedRequirement(String orgId, String id, List<String> learningIds) =>
      firestore.doc('organizations/$orgId/safety_requirements/$id').set({
        'organizationId': orgId,
        'name': 'Requirement $id',
        'category': 'General',
        'risk': 'medium',
        'requiredLearningIds': learningIds,
        'status': 'active',
      });

  Future<void> seedLearning(String orgId, String id) =>
      firestore.doc('organizations/$orgId/safety_learning/$id').set({
        'organizationId': orgId,
        'title': 'Learning $id',
        'type': 'document',
        'contentReference': 'ref',
        'status': 'active',
      });

  Future<void> seedLearningRecord(
    String orgId,
    String workerUid,
    String learningId,
    String status,
  ) =>
      firestore
          .doc(
            'organizations/$orgId/worker_learning_records/'
            '${workerUid}_$learningId',
          )
          .set({
        'workerUid': workerUid,
        'organizationId': orgId,
        'learningId': learningId,
        'status': status,
      });

  ReportsRepository repositoryFor(
    String orgId, {
    List<OrganizationUser> workers = const [],
  }) {
    return ReportsRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: orgId,
      accountApprovalService: _FakeApprovalService(workers),
    );
  }

  group('Daily Safety Meeting report', () {
    test('aggregates attendance and concern counts per meeting', () async {
      await seedProject('org-alpha', 'project-1', name: 'Rosslyn');
      await seedSite('org-alpha', 'site-1', name: 'Tower A');
      await seedMeeting('org-alpha', 'm1');
      await seedAttendance(
        'org-alpha',
        'm1',
        'worker-1',
        status: MeetingAttendanceStatus.present,
      );
      await seedAttendance(
        'org-alpha',
        'm1',
        'worker-2',
        status: MeetingAttendanceStatus.absent,
      );
      await seedConcern('org-alpha', 'm1', 'c1');
      await seedConcern('org-alpha', 'm1', 'c2');

      final rows = await repositoryFor(
        'org-alpha',
      ).buildDailySafetyMeetingReport();

      expect(rows, hasLength(1));
      final row = rows.single;
      expect(row.projectName, 'Rosslyn');
      expect(row.siteName, 'Tower A');
      expect(row.presentCount, 1);
      expect(row.absentCount, 1);
      expect(row.concernCount, 2);
      expect(row.activityCount, 1);
    });

    test('filters by project and site', () async {
      await seedProject('org-alpha', 'project-1');
      await seedProject('org-alpha', 'project-2');
      await seedSite('org-alpha', 'site-1', projectId: 'project-1');
      await seedSite('org-alpha', 'site-2', projectId: 'project-2');
      await seedMeeting('org-alpha', 'm1', projectId: 'project-1', siteId: 'site-1');
      await seedMeeting('org-alpha', 'm2', projectId: 'project-2', siteId: 'site-2');

      final repository = repositoryFor('org-alpha');

      final byProject = await repository.buildDailySafetyMeetingReport(
        projectId: 'project-1',
      );
      expect(byProject.map((r) => r.meetingId).toList(), ['m1']);

      final bySite = await repository.buildDailySafetyMeetingReport(
        siteId: 'site-2',
      );
      expect(bySite.map((r) => r.meetingId).toList(), ['m2']);
    });

    test('filters by inclusive date range', () async {
      await seedProject('org-alpha', 'project-1');
      await seedSite('org-alpha', 'site-1');
      await seedMeeting('org-alpha', 'jan10', date: '2026-01-10');
      await seedMeeting('org-alpha', 'jan15', date: '2026-01-15');
      await seedMeeting('org-alpha', 'jan20', date: '2026-01-20');

      final rows = await repositoryFor('org-alpha').buildDailySafetyMeetingReport(
        from: DateTime(2026, 1, 12),
        to: DateTime(2026, 1, 18),
      );

      expect(rows.map((r) => r.meetingId).toList(), ['jan15']);
    });

    test("excludes another organization's meetings", () async {
      await seedProject('org-alpha', 'project-1');
      await seedSite('org-alpha', 'site-1');
      await seedMeeting('org-alpha', 'm1');
      await seedProject('org-beta', 'project-1');
      await seedSite('org-beta', 'site-1');
      await seedMeeting('org-beta', 'm2');

      final rows = await repositoryFor('org-alpha').buildDailySafetyMeetingReport();

      expect(rows.map((r) => r.meetingId).toList(), ['m1']);
    });

    test('returns an empty list when there are no meetings', () async {
      final rows = await repositoryFor('org-alpha').buildDailySafetyMeetingReport();

      expect(rows, isEmpty);
    });
  });

  group('Safety Alerts report', () {
    test('resolves site name and includes status/severity', () async {
      await seedSite('org-alpha', 'site-1', name: 'Tower A');
      await seedAlert('org-alpha', 'a1', status: 'active', severity: 'critical');
      await seedAlert(
        'org-alpha',
        'a2',
        status: 'resolved',
        resolvedAt: DateTime(2026, 1, 12),
      );

      final rows = await repositoryFor('org-alpha').buildSafetyAlertsReport();

      expect(rows, hasLength(2));
      final active = rows.firstWhere((r) => r.alertId == 'a1');
      expect(active.siteName, 'Tower A');
      expect(active.severity, SafetyAlertSeverity.critical);
      expect(active.status, SafetyAlertStatus.active);
      final resolved = rows.firstWhere((r) => r.alertId == 'a2');
      expect(resolved.resolvedAt, DateTime(2026, 1, 12));
    });

    test('filters by site', () async {
      await seedSite('org-alpha', 'site-1');
      await seedSite('org-alpha', 'site-2');
      await seedAlert('org-alpha', 'a1', siteId: 'site-1');
      await seedAlert('org-alpha', 'a2', siteId: 'site-2');

      final rows = await repositoryFor(
        'org-alpha',
      ).buildSafetyAlertsReport(siteId: 'site-2');

      expect(rows.map((r) => r.alertId).toList(), ['a2']);
    });

    test('filters by created-date range', () async {
      await seedSite('org-alpha', 'site-1');
      await seedAlert('org-alpha', 'early', createdAt: DateTime(2026, 1, 1));
      await seedAlert('org-alpha', 'mid', createdAt: DateTime(2026, 1, 15));
      await seedAlert('org-alpha', 'late', createdAt: DateTime(2026, 1, 30));

      final rows = await repositoryFor('org-alpha').buildSafetyAlertsReport(
        from: DateTime(2026, 1, 5),
        to: DateTime(2026, 1, 20),
      );

      expect(rows.map((r) => r.alertId).toList(), ['mid']);
    });

    test("excludes another organization's alerts", () async {
      await seedSite('org-alpha', 'site-1');
      await seedAlert('org-alpha', 'a1');
      await seedSite('org-beta', 'site-1');
      await seedAlert('org-beta', 'a1');

      final rows = await repositoryFor('org-alpha').buildSafetyAlertsReport();

      expect(rows, hasLength(1));
      expect(rows.single.alertId, 'a1');
    });

    test('returns an empty list when there are no alerts', () async {
      final rows = await repositoryFor('org-alpha').buildSafetyAlertsReport();

      expect(rows, isEmpty);
    });

    group('inclusive end-of-day date range filtering', () {
      // Regression coverage for: showDateRangePicker returns `to` at
      // midnight (00:00:00) of the selected end day. A naive
      // `createdAt.isAfter(to)` check would wrongly exclude an alert
      // created later that same day — the bug this suite pins down as
      // fixed.
      Future<List<String>> alertIdsInRange(DateTime from, DateTime to) async {
        final rows = await repositoryFor('org-alpha').buildSafetyAlertsReport(
          from: from,
          to: to,
        );
        return rows.map((r) => r.alertId).toList();
      }

      test('a record before the range is excluded', () async {
        await seedSite('org-alpha', 'site-1');
        await seedAlert(
          'org-alpha',
          'before',
          createdAt: DateTime(2026, 1, 4, 23, 59),
        );

        final ids = await alertIdsInRange(
          DateTime(2026, 1, 5),
          DateTime(2026, 1, 10),
        );

        expect(ids, isEmpty);
      });

      test('a record exactly on the start date is included', () async {
        await seedSite('org-alpha', 'site-1');
        await seedAlert(
          'org-alpha',
          'on-start',
          createdAt: DateTime(2026, 1, 5, 0, 0),
        );

        final ids = await alertIdsInRange(
          DateTime(2026, 1, 5),
          DateTime(2026, 1, 10),
        );

        expect(ids, ['on-start']);
      });

      test('a record during the range is included', () async {
        await seedSite('org-alpha', 'site-1');
        await seedAlert(
          'org-alpha',
          'during',
          createdAt: DateTime(2026, 1, 7, 13, 45),
        );

        final ids = await alertIdsInRange(
          DateTime(2026, 1, 5),
          DateTime(2026, 1, 10),
        );

        expect(ids, ['during']);
      });

      test('a record later on the end date is included (the bug case)',
          () async {
        await seedSite('org-alpha', 'site-1');
        await seedAlert(
          'org-alpha',
          'late-on-end',
          createdAt: DateTime(2026, 1, 10, 23, 59, 59),
        );

        // `to` mirrors exactly what showDateRangePicker returns: midnight
        // at the START of the selected end day.
        final ids = await alertIdsInRange(
          DateTime(2026, 1, 5),
          DateTime(2026, 1, 10),
        );

        expect(ids, ['late-on-end']);
      });

      test('a record after the range is excluded', () async {
        await seedSite('org-alpha', 'site-1');
        await seedAlert(
          'org-alpha',
          'after',
          createdAt: DateTime(2026, 1, 11, 0, 0, 1),
        );

        final ids = await alertIdsInRange(
          DateTime(2026, 1, 5),
          DateTime(2026, 1, 10),
        );

        expect(ids, isEmpty);
      });

      test('a same-day start/end range includes records any time that day',
          () async {
        await seedSite('org-alpha', 'site-1');
        await seedAlert(
          'org-alpha',
          'morning',
          createdAt: DateTime(2026, 1, 8, 6, 0),
        );
        await seedAlert(
          'org-alpha',
          'evening',
          createdAt: DateTime(2026, 1, 8, 22, 0),
        );
        await seedAlert(
          'org-alpha',
          'next-day',
          createdAt: DateTime(2026, 1, 9, 0, 0, 1),
        );

        final ids = await alertIdsInRange(
          DateTime(2026, 1, 8),
          DateTime(2026, 1, 8),
        );

        expect(ids.toSet(), {'morning', 'evening'});
      });
    });
  });

  group('Corrective Actions report', () {
    test('computes isOverdueAsOf relative to the given time', () async {
      await seedSite('org-alpha', 'site-1');
      await seedAction(
        'org-alpha',
        'overdue',
        status: 'open',
        dueDate: DateTime(2026, 1, 1),
      );
      await seedAction(
        'org-alpha',
        'future',
        status: 'open',
        dueDate: DateTime(2026, 6, 1),
      );
      await seedAction(
        'org-alpha',
        'completed-late',
        status: 'completed',
        dueDate: DateTime(2026, 1, 1),
      );

      final rows = await repositoryFor('org-alpha').buildCorrectiveActionsReport();
      final now = DateTime(2026, 3, 1);
      final overdueCount = rows.where((r) => r.isOverdueAsOf(now)).length;

      expect(overdueCount, 1);
      expect(
        rows.firstWhere((r) => r.actionId == 'overdue').isOverdueAsOf(now),
        isTrue,
      );
      expect(
        rows.firstWhere((r) => r.actionId == 'future').isOverdueAsOf(now),
        isFalse,
      );
      expect(
        rows
            .firstWhere((r) => r.actionId == 'completed-late')
            .isOverdueAsOf(now),
        isFalse,
      );
    });

    test('filters by site and due-date range', () async {
      await seedSite('org-alpha', 'site-1');
      await seedSite('org-alpha', 'site-2');
      await seedAction(
        'org-alpha',
        'ca1',
        siteId: 'site-1',
        dueDate: DateTime(2026, 1, 10),
      );
      await seedAction(
        'org-alpha',
        'ca2',
        siteId: 'site-2',
        dueDate: DateTime(2026, 1, 20),
      );

      final repository = repositoryFor('org-alpha');

      final bySite = await repository.buildCorrectiveActionsReport(
        siteId: 'site-1',
      );
      expect(bySite.map((r) => r.actionId).toList(), ['ca1']);

      final byDate = await repository.buildCorrectiveActionsReport(
        from: DateTime(2026, 1, 15),
        to: DateTime(2026, 1, 25),
      );
      expect(byDate.map((r) => r.actionId).toList(), ['ca2']);
    });

    test("excludes another organization's actions", () async {
      await seedSite('org-alpha', 'site-1');
      await seedAction('org-alpha', 'ca1');
      await seedSite('org-beta', 'site-1');
      await seedAction('org-beta', 'ca1');

      final rows = await repositoryFor('org-alpha').buildCorrectiveActionsReport();

      expect(rows, hasLength(1));
    });

    test('returns an empty list when there are no actions', () async {
      final rows = await repositoryFor('org-alpha').buildCorrectiveActionsReport();

      expect(rows, isEmpty);
    });

    group('inclusive end-of-day date range filtering', () {
      // Regression coverage for the same showDateRangePicker
      // midnight-`to` bug as the Safety Alerts report, applied here to
      // `dueDate` instead of `createdAt`.
      Future<List<String>> actionIdsInRange(DateTime from, DateTime to) async {
        final rows = await repositoryFor(
          'org-alpha',
        ).buildCorrectiveActionsReport(from: from, to: to);
        return rows.map((r) => r.actionId).toList();
      }

      test('a record before the range is excluded', () async {
        await seedSite('org-alpha', 'site-1');
        await seedAction(
          'org-alpha',
          'before',
          dueDate: DateTime(2026, 1, 4, 23, 59),
        );

        final ids = await actionIdsInRange(
          DateTime(2026, 1, 5),
          DateTime(2026, 1, 10),
        );

        expect(ids, isEmpty);
      });

      test('a record exactly on the start date is included', () async {
        await seedSite('org-alpha', 'site-1');
        await seedAction(
          'org-alpha',
          'on-start',
          dueDate: DateTime(2026, 1, 5, 0, 0),
        );

        final ids = await actionIdsInRange(
          DateTime(2026, 1, 5),
          DateTime(2026, 1, 10),
        );

        expect(ids, ['on-start']);
      });

      test('a record during the range is included', () async {
        await seedSite('org-alpha', 'site-1');
        await seedAction(
          'org-alpha',
          'during',
          dueDate: DateTime(2026, 1, 7, 13, 45),
        );

        final ids = await actionIdsInRange(
          DateTime(2026, 1, 5),
          DateTime(2026, 1, 10),
        );

        expect(ids, ['during']);
      });

      test('a record later on the end date is included (the bug case)',
          () async {
        await seedSite('org-alpha', 'site-1');
        await seedAction(
          'org-alpha',
          'late-on-end',
          dueDate: DateTime(2026, 1, 10, 23, 59, 59),
        );

        final ids = await actionIdsInRange(
          DateTime(2026, 1, 5),
          DateTime(2026, 1, 10),
        );

        expect(ids, ['late-on-end']);
      });

      test('a record after the range is excluded', () async {
        await seedSite('org-alpha', 'site-1');
        await seedAction(
          'org-alpha',
          'after',
          dueDate: DateTime(2026, 1, 11, 0, 0, 1),
        );

        final ids = await actionIdsInRange(
          DateTime(2026, 1, 5),
          DateTime(2026, 1, 10),
        );

        expect(ids, isEmpty);
      });

      test('a same-day start/end range includes records any time that day',
          () async {
        await seedSite('org-alpha', 'site-1');
        await seedAction(
          'org-alpha',
          'morning',
          dueDate: DateTime(2026, 1, 8, 6, 0),
        );
        await seedAction(
          'org-alpha',
          'evening',
          dueDate: DateTime(2026, 1, 8, 22, 0),
        );
        await seedAction(
          'org-alpha',
          'next-day',
          dueDate: DateTime(2026, 1, 9, 0, 0, 1),
        );

        final ids = await actionIdsInRange(
          DateTime(2026, 1, 8),
          DateTime(2026, 1, 8),
        );

        expect(ids.toSet(), {'morning', 'evening'});
      });
    });
  });

  group('Safety Learning report', () {
    test('summarizes completed/in-progress/outstanding per worker', () async {
      await seedLearning('org-alpha', 'l1');
      await seedLearning('org-alpha', 'l2');
      await seedRequirement('org-alpha', 'req-1', ['l1', 'l2']);
      await seedLearningRecord('org-alpha', 'worker-1', 'l1', 'completed');
      await seedLearningRecord('org-alpha', 'worker-1', 'l2', 'inProgress');

      final rows = await repositoryFor(
        'org-alpha',
        workers: [_worker('worker-1')],
      ).buildSafetyLearningReport();

      expect(rows, hasLength(1));
      final row = rows.single;
      expect(row.workerUid, 'worker-1');
      expect(row.requiredCount, 2);
      expect(row.completedCount, 1);
      expect(row.inProgressCount, 1);
      expect(row.outstandingCount, 0);
    });

    test('counts required items with no record as outstanding', () async {
      await seedLearning('org-alpha', 'l1');
      await seedRequirement('org-alpha', 'req-1', ['l1']);

      final rows = await repositoryFor(
        'org-alpha',
        workers: [_worker('worker-1')],
      ).buildSafetyLearningReport();

      expect(rows.single.requiredCount, 1);
      expect(rows.single.completedCount, 0);
      expect(rows.single.outstandingCount, 1);
    });

    test('one row per active worker, even with zero required learning',
        () async {
      final rows = await repositoryFor(
        'org-alpha',
        workers: [_worker('worker-1'), _worker('worker-2')],
      ).buildSafetyLearningReport();

      expect(rows.map((r) => r.workerUid).toSet(), {'worker-1', 'worker-2'});
      expect(rows.every((r) => r.requiredCount == 0), isTrue);
    });

    test('returns an empty list when there are no active workers', () async {
      final rows = await repositoryFor('org-alpha').buildSafetyLearningReport();

      expect(rows, isEmpty);
    });
  });

  test('organizationId exposes the scope this repository was built with',
      () {
    final repository = repositoryFor('org-alpha');

    expect(repository.organizationId, 'org-alpha');
  });
}
