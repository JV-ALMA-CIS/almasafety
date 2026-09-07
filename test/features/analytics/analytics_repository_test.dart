import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/features/analytics/data/analytics_repository.dart';
import 'package:jva_safety/features/authentication/data/account_approval_service.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/organization_user.dart';

/// Subclasses the real service rather than introducing a mocking package,
/// following the repo's existing pattern — see
/// `test/features/reports/reports_repository_test.dart`.
class _FakeApprovalService extends AccountApprovalService {
  _FakeApprovalService(this.users);

  final List<OrganizationUser> users;

  @override
  Future<List<OrganizationUser>> listUsers({
    AccountStatus status = AccountStatus.active,
    String? organizationId,
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
    String status = 'completed',
  }) =>
      firestore.doc('organizations/$orgId/daily_safety_meetings/$id').set({
        'organizationId': orgId,
        'projectId': projectId,
        'siteId': siteId,
        'date': date,
        'foremanId': 'foreman-1',
        'activityIds': ['a1'],
        'meetingPointIds': ['p1'],
        'status': status,
        'concerns': <String>[],
        'correctiveActionIds': <String>[],
        'createdAt': Timestamp.now(),
      });

  Future<void> seedAttendance(
    String orgId,
    String meetingId,
    String workerId, {
    required String status,
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
        'status': status,
        'recordedAt': Timestamp.now(),
        'recordedBy': 'foreman-1',
      });

  Future<void> seedConcern(
    String orgId,
    String meetingId,
    String id, {
    String category = 'safety',
    String status = 'open',
  }) =>
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
        'category': category,
        'reportedBy': 'foreman-1',
        'status': status,
        'createdAt': Timestamp.now(),
      });

  Future<void> seedAlert(
    String orgId,
    String id, {
    String siteId = 'site-1',
    String severity = 'high',
    String category = 'safety',
    String status = 'active',
    DateTime? createdAt,
  }) =>
      firestore.doc('organizations/$orgId/safety_alerts/$id').set({
        'organizationId': orgId,
        'projectId': 'project-1',
        'siteId': siteId,
        'title': 'Alert $id',
        'description': 'Description $id',
        'severity': severity,
        'category': category,
        'status': status,
        'createdBy': 'manager-1',
        'createdAt': Timestamp.fromDate(createdAt ?? DateTime(2026, 1, 10)),
        'resolvedAt': null,
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

  AnalyticsRepository repositoryFor(
    String orgId, {
    List<OrganizationUser> workers = const [],
  }) {
    return AnalyticsRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: orgId,
      accountApprovalService: _FakeApprovalService(workers),
    );
  }

  group('Safety Meeting metrics', () {
    test('counts completed vs in-progress and breaks down by site/date',
        () async {
      await seedProject('org-alpha', 'project-1');
      await seedSite('org-alpha', 'site-1', name: 'Tower A');
      await seedSite('org-alpha', 'site-2', name: 'Tower B');
      await seedMeeting(
        'org-alpha',
        'm1',
        siteId: 'site-1',
        date: '2026-01-10',
        status: 'completed',
      );
      await seedMeeting(
        'org-alpha',
        'm2',
        siteId: 'site-1',
        date: '2026-01-10',
        status: 'inProgress',
      );
      await seedMeeting(
        'org-alpha',
        'm3',
        siteId: 'site-2',
        date: '2026-01-11',
        status: 'completed',
      );

      final dashboard = await repositoryFor('org-alpha').build();

      expect(dashboard.meetings.completedCount, 2);
      expect(dashboard.meetings.inProgressCount, 1);
      expect(dashboard.meetings.totalCount, 3);
      expect(dashboard.meetings.bySite['Tower A'], 2);
      expect(dashboard.meetings.bySite['Tower B'], 1);
      expect(dashboard.meetings.byDate['2026-01-10'], 2);
      expect(dashboard.meetings.byDate['2026-01-11'], 1);
    });

    test('returns zero metrics for an organization with no meetings',
        () async {
      final dashboard = await repositoryFor('org-alpha').build();

      expect(dashboard.meetings.completedCount, 0);
      expect(dashboard.meetings.inProgressCount, 0);
      expect(dashboard.meetings.bySite, isEmpty);
      expect(dashboard.meetings.byDate, isEmpty);
    });
  });

  group('Attendance metrics', () {
    test('computes present/absent counts and percentage', () async {
      await seedProject('org-alpha', 'project-1');
      await seedSite('org-alpha', 'site-1');
      await seedMeeting('org-alpha', 'm1');
      await seedAttendance('org-alpha', 'm1', 'w1', status: 'present');
      await seedAttendance('org-alpha', 'm1', 'w2', status: 'present');
      await seedAttendance('org-alpha', 'm1', 'w3', status: 'absent');

      final dashboard = await repositoryFor('org-alpha').build();

      expect(dashboard.attendance.presentCount, 2);
      expect(dashboard.attendance.absentCount, 1);
      expect(dashboard.attendance.totalCount, 3);
      expect(
        dashboard.attendance.attendancePercentage,
        closeTo(66.67, 0.1),
      );
    });

    test('attendancePercentage is 0 (not NaN/error) with no attendance',
        () async {
      final dashboard = await repositoryFor('org-alpha').build();

      expect(dashboard.attendance.totalCount, 0);
      expect(dashboard.attendance.attendancePercentage, 0);
    });
  });

  group('Concern metrics', () {
    test('counts total/open and breaks down by category', () async {
      await seedProject('org-alpha', 'project-1');
      await seedSite('org-alpha', 'site-1');
      await seedMeeting('org-alpha', 'm1');
      await seedConcern('org-alpha', 'm1', 'c1', category: 'safety', status: 'open');
      await seedConcern('org-alpha', 'm1', 'c2', category: 'safety', status: 'resolved');
      await seedConcern(
        'org-alpha',
        'm1',
        'c3',
        category: 'equipment',
        status: 'open',
      );

      final dashboard = await repositoryFor('org-alpha').build();

      expect(dashboard.concerns.totalCount, 3);
      expect(dashboard.concerns.openCount, 2);
      expect(dashboard.concerns.byCategory.length, 5); // every category present
      expect(
        dashboard.concerns.byCategory.entries
            .firstWhere((e) => e.key.id == 'safety')
            .value,
        2,
      );
      expect(
        dashboard.concerns.byCategory.entries
            .firstWhere((e) => e.key.id == 'equipment')
            .value,
        1,
      );
    });

    test('empty when there are no meetings/concerns', () async {
      final dashboard = await repositoryFor('org-alpha').build();

      expect(dashboard.concerns.totalCount, 0);
      expect(dashboard.concerns.openCount, 0);
    });
  });

  group('Corrective Action metrics', () {
    test('counts by status, computes overdue and completion rate', () async {
      await seedSite('org-alpha', 'site-1');
      await seedAction('org-alpha', 'a1', status: 'open', dueDate: DateTime(2020, 1, 1));
      await seedAction('org-alpha', 'a2', status: 'inProgress', dueDate: DateTime(2099, 1, 1));
      await seedAction('org-alpha', 'a3', status: 'completed', dueDate: DateTime(2020, 1, 1));

      final dashboard = await repositoryFor('org-alpha').build();

      expect(dashboard.correctiveActions.totalCount, 3);
      expect(dashboard.correctiveActions.openCount, 1);
      expect(dashboard.correctiveActions.inProgressCount, 1);
      expect(dashboard.correctiveActions.completedCount, 1);
      expect(dashboard.correctiveActions.overdueCount, 1); // only a1
      expect(
        dashboard.correctiveActions.completionRate,
        closeTo(33.33, 0.1),
      );
    });

    test('completionRate is 0 (not NaN/error) with no actions', () async {
      final dashboard = await repositoryFor('org-alpha').build();

      expect(dashboard.correctiveActions.totalCount, 0);
      expect(dashboard.correctiveActions.completionRate, 0);
    });
  });

  group('Safety Alert metrics', () {
    test('counts by status and breaks down by severity/category', () async {
      await seedSite('org-alpha', 'site-1');
      await seedAlert('org-alpha', 'a1', status: 'active', severity: 'critical', category: 'equipment');
      await seedAlert('org-alpha', 'a2', status: 'acknowledged', severity: 'low', category: 'weather');
      await seedAlert('org-alpha', 'a3', status: 'resolved', severity: 'critical', category: 'equipment');

      final dashboard = await repositoryFor('org-alpha').build();

      expect(dashboard.safetyAlerts.activeCount, 1);
      expect(dashboard.safetyAlerts.acknowledgedCount, 1);
      expect(dashboard.safetyAlerts.resolvedCount, 1);
      expect(dashboard.safetyAlerts.totalCount, 3);
      expect(
        dashboard.safetyAlerts.bySeverity.entries
            .firstWhere((e) => e.key.id == 'critical')
            .value,
        2,
      );
      expect(
        dashboard.safetyAlerts.byCategory.entries
            .firstWhere((e) => e.key.id == 'equipment')
            .value,
        2,
      );
    });

    test('empty when there are no alerts', () async {
      final dashboard = await repositoryFor('org-alpha').build();

      expect(dashboard.safetyAlerts.totalCount, 0);
    });
  });

  group('Safety Learning metrics', () {
    test('aggregates assigned/completed/in-progress/outstanding across '
        'workers', () async {
      await seedLearning('org-alpha', 'l1');
      await seedLearning('org-alpha', 'l2');
      await seedRequirement('org-alpha', 'req-1', ['l1', 'l2']);
      await seedLearningRecord('org-alpha', 'worker-1', 'l1', 'completed');
      await seedLearningRecord('org-alpha', 'worker-2', 'l1', 'inProgress');

      final dashboard = await repositoryFor(
        'org-alpha',
        workers: [_worker('worker-1'), _worker('worker-2')],
      ).build();

      expect(dashboard.safetyLearning.assignedCount, 4); // 2 workers x 2 required
      expect(dashboard.safetyLearning.completedCount, 1);
      expect(dashboard.safetyLearning.inProgressCount, 1);
      expect(dashboard.safetyLearning.outstandingCount, 2);
      expect(
        dashboard.safetyLearning.completionPercentage,
        closeTo(25, 0.1),
      );
    });

    test('completionPercentage is 0 (not NaN/error) with nothing assigned',
        () async {
      final dashboard = await repositoryFor('org-alpha').build();

      expect(dashboard.safetyLearning.assignedCount, 0);
      expect(dashboard.safetyLearning.completionPercentage, 0);
    });
  });

  group('filtering', () {
    test('date range filters meetings, attendance and concerns together',
        () async {
      await seedProject('org-alpha', 'project-1');
      await seedSite('org-alpha', 'site-1');
      await seedMeeting('org-alpha', 'in-range', date: '2026-01-15');
      await seedAttendance('org-alpha', 'in-range', 'w1', status: 'present');
      await seedConcern('org-alpha', 'in-range', 'c1');
      await seedMeeting('org-alpha', 'out-of-range', date: '2026-03-01');
      await seedAttendance(
        'org-alpha',
        'out-of-range',
        'w2',
        status: 'absent',
      );

      final dashboard = await repositoryFor('org-alpha').build(
        from: DateTime(2026, 1, 1),
        to: DateTime(2026, 1, 31),
      );

      expect(dashboard.meetings.totalCount, 1);
      expect(dashboard.attendance.totalCount, 1);
      expect(dashboard.attendance.presentCount, 1);
      expect(dashboard.concerns.totalCount, 1);
    });

    test('project/site filters narrow meetings and alerts/actions '
        'consistently', () async {
      await seedProject('org-alpha', 'project-1');
      await seedProject('org-alpha', 'project-2');
      await seedSite('org-alpha', 'site-1', projectId: 'project-1');
      await seedSite('org-alpha', 'site-2', projectId: 'project-2');
      await seedMeeting(
        'org-alpha',
        'm1',
        projectId: 'project-1',
        siteId: 'site-1',
      );
      await seedMeeting(
        'org-alpha',
        'm2',
        projectId: 'project-2',
        siteId: 'site-2',
      );
      await seedAlert('org-alpha', 'a1', siteId: 'site-1');
      await seedAlert('org-alpha', 'a2', siteId: 'site-2');

      final dashboard = await repositoryFor(
        'org-alpha',
      ).build(siteId: 'site-1');

      expect(dashboard.meetings.totalCount, 1);
      expect(dashboard.safetyAlerts.totalCount, 1);
    });
  });

  test("excludes another organization's data entirely", () async {
    await seedProject('org-alpha', 'project-1');
    await seedSite('org-alpha', 'site-1');
    await seedMeeting('org-alpha', 'm1');
    await seedAlert('org-alpha', 'a1');
    await seedAction('org-alpha', 'ca1');

    await seedProject('org-beta', 'project-1');
    await seedSite('org-beta', 'site-1');
    await seedMeeting('org-beta', 'm1');
    await seedAlert('org-beta', 'a1');
    await seedAction('org-beta', 'ca1');

    final dashboard = await repositoryFor('org-alpha').build();

    expect(dashboard.meetings.totalCount, 1);
    expect(dashboard.safetyAlerts.totalCount, 1);
    expect(dashboard.correctiveActions.totalCount, 1);
  });

  test('organizationId exposes the scope this repository was built with',
      () {
    final repository = repositoryFor('org-alpha');

    expect(repository.organizationId, 'org-alpha');
  });
}
