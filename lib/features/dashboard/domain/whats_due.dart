import '../../man_hours/domain/man_hours.dart';
import '../../hazards/domain/hazard.dart';
import '../../hazards/domain/hazard_status.dart';
import '../../incidents/domain/incident.dart';
import '../../inspections/domain/inspection.dart';
import '../../organizations/domain/site.dart';
import '../../risk_assessments/domain/risk_assessment.dart';
import '../../safety_meetings/domain/safety_meeting.dart';

/// What a "What's due" line is about — decides its colour, icon and where
/// tapping it goes.
enum DueKind {
  manHoursNotEntered,
  manHoursNotReported,
  incidentReportsOverdue,
  incidentReportingNotSet,
  incidentReportsDueSoon,
  inspectionsToSignOff,
  inspectionsInProgress,
  dailyInspectionNotDone,
  weeklyMeetingNotHeld,
  monthlyMeetingNotHeld,
  ahasToAccept,
  openDeficiencies,
  noChecklists,
}

/// One thing that needs doing, e.g. "Daily inspection not done today" at
/// two sites.
class DueItem {
  const DueItem({required this.kind, required this.title, this.detail});

  final DueKind kind;
  final String title;

  /// e.g. the sites it applies to.
  final String? detail;
}

String _plural(int n, String one, String many) => n == 1 ? one : many;

/// Everything due for one person, worked out from the records they can
/// see — the Safety Plan's routine made visible:
///
/// - Site Managers/Admins ([isManager]): inspections awaiting their
///   sign-off (not their own), AHAs awaiting their acceptance (not their
///   own), open deficiencies, the monthly supervisory meeting.
/// - Everyone who inspects (Site Managers, Admins, Foremen): their own
///   inspections still in progress, today's daily inspection at each of
///   [sites] where a daily checklist is used, and this week's employee
///   safety meeting at each of [sites].
///
/// [sites] is the person's scope — every open site for a Site
/// Manager/Admin, their own sites for a Foreman. [now] is the local time.
List<DueItem> computeDueItems({
  required String uid,
  required bool isManager,
  required List<Site> sites,
  required List<InspectionTemplate> templates,
  required List<Inspection> inspections,
  required List<SafetyMeeting> meetings,
  List<RiskAssessment> riskAssessments = const [],
  List<Hazard> hazards = const [],
  List<Incident> incidents = const [],

  /// Last month's man-hours entries (Safety Plan 8a), and whether that month
  /// was reported to the Safety Office; null skips the man-hours lines.
  List<ManHoursEntry>? manHoursEntries,
  ManHoursReport? manHoursReport,
  required DateTime now,
}) {
  final siteIds = {for (final s in sites) s.id};
  bool sameDay(DateTime? a) =>
      a != null &&
      a.year == now.year &&
      a.month == now.month &&
      a.day == now.day;
  String names(Iterable<Site> list) => list.map((s) => s.name).join(', ');

  final items = <DueItem>[];

  // ---- Incident reporting deadlines (Safety Plan Section 8) — first,
  // ---- because they are legal deadlines.
  if (isManager) {
    final open = incidents.where((i) => !i.isClosed).toList();
    final overdue = [
      for (final i in open) ...i.reportingSteps.where((s) => s.isOverdue(now)),
    ];
    if (overdue.isNotEmpty) {
      items.add(
        DueItem(
          kind: DueKind.incidentReportsOverdue,
          title:
              '${overdue.length} incident reporting '
              '${_plural(overdue.length, 'step', 'steps')} OVERDUE',
          detail: overdue.map((s) => s.label).toSet().join('; '),
        ),
      );
    }
    final notSet = open.where((i) => i.reportingLevel == null).length;
    if (notSet > 0) {
      items.add(
        DueItem(
          kind: DueKind.incidentReportingNotSet,
          title:
              '$notSet ${_plural(notSet, 'incident needs', 'incidents need')} '
              'a reporting level',
          detail: 'Decide who must be told and by when.',
        ),
      );
    }
    final soon = [
      for (final i in open) ...i.reportingSteps.where((s) => s.isDueSoon(now)),
    ];
    if (soon.isNotEmpty) {
      items.add(
        DueItem(
          kind: DueKind.incidentReportsDueSoon,
          title:
              '${soon.length} incident reporting '
              '${_plural(soon.length, 'step', 'steps')} due within 24 hours',
          detail: soon.map((s) => s.label).toSet().join('; '),
        ),
      );
    }
  }

  // ---- Monthly man-hours (Safety Plan 8a): last month, due the 25th ----
  if (manHoursEntries != null && sites.isNotEmpty) {
    final month = reportingMonth(now);
    final due = manHoursDueDate(month);
    final overdue = now.isAfter(due);
    final dueText = overdue
        ? 'OVERDUE - was due ${shortDay(due)}'
        : 'due ${shortDay(due)}';
    final entered = {for (final e in manHoursEntries) e.siteId};
    final missing = [
      for (final site in sites)
        if (!entered.contains(site.id)) site,
    ];
    if (missing.isNotEmpty) {
      items.add(
        DueItem(
          kind: DueKind.manHoursNotEntered,
          title: 'Man-hours for ${monthLabel(month)} not entered',
          detail: '${names(missing)} · $dueText',
        ),
      );
    } else if (isManager && manHoursReport == null) {
      items.add(
        DueItem(
          kind: DueKind.manHoursNotReported,
          title:
              '${monthLabel(month)} man-hours not yet reported to the Safety '
              'Office',
          detail: dueText,
        ),
      );
    }
  }

  // ---- Inspections ----
  final activeTemplates = templates.where((t) => t.isActive).toList();
  if (isManager && activeTemplates.isEmpty) {
    items.add(
      const DueItem(
        kind: DueKind.noChecklists,
        title: 'No inspection checklists set up yet',
        detail: 'Install the standard checklists under Inspections.',
      ),
    );
  }

  if (isManager) {
    final toSignOff = inspections
        .where(
          (i) =>
              i.status == InspectionStatus.submitted &&
              i.inspectorUid != uid &&
              (siteIds.contains(i.siteId)),
        )
        .length;
    if (toSignOff > 0) {
      items.add(
        DueItem(
          kind: DueKind.inspectionsToSignOff,
          title:
              '$toSignOff ${_plural(toSignOff, 'inspection', 'inspections')} '
              'awaiting your sign-off',
        ),
      );
    }
  }

  final mine = inspections
      .where(
        (i) => i.inspectorUid == uid && i.status == InspectionStatus.inProgress,
      )
      .length;
  if (mine > 0) {
    items.add(
      DueItem(
        kind: DueKind.inspectionsInProgress,
        title:
            'You have $mine ${_plural(mine, 'inspection', 'inspections')} '
            'still in progress',
      ),
    );
  }

  final dailyNotDone = [
    for (final site in sites)
      if (activeTemplates.any(
            (t) => t.kind == InspectionKind.daily && t.isUsedAt(site.id),
          ) &&
          !inspections.any(
            (i) =>
                i.siteId == site.id &&
                i.kind == InspectionKind.daily &&
                i.status != InspectionStatus.inProgress &&
                sameDay(i.submittedAt ?? i.startedAt),
          ))
        site,
  ];
  if (dailyNotDone.isNotEmpty) {
    items.add(
      DueItem(
        kind: DueKind.dailyInspectionNotDone,
        title: 'Daily inspection not done today',
        detail: names(dailyNotDone),
      ),
    );
  }

  // ---- Meetings ----
  final weeklyNotHeld = [
    for (final site in sites)
      if (!meetings.any(
        (m) =>
            m.kind == SafetyMeetingKind.weeklyEmployee &&
            m.siteId == site.id &&
            isInCurrentPeriod(m, now),
      ))
        site,
  ];
  if (weeklyNotHeld.isNotEmpty) {
    items.add(
      DueItem(
        kind: DueKind.weeklyMeetingNotHeld,
        title: 'Weekly employee safety meeting not recorded this week',
        detail:
            '${names(weeklyNotHeld)} · '
            '${SafetyMeetingKind.weeklyEmployee.schedule}',
      ),
    );
  }
  if (isManager &&
      sites.isNotEmpty &&
      !meetings.any(
        (m) =>
            m.kind == SafetyMeetingKind.monthlySupervisory &&
            isInCurrentPeriod(m, now),
      )) {
    items.add(
      DueItem(
        kind: DueKind.monthlyMeetingNotHeld,
        title: 'Monthly supervisory meeting not recorded this month',
        detail: SafetyMeetingKind.monthlySupervisory.schedule,
      ),
    );
  }

  // ---- Risk assessments & deficiencies ----
  if (isManager) {
    final toAccept = riskAssessments
        .where(
          (a) =>
              a.status == RiskAssessmentStatus.draft && a.preparedByUid != uid,
        )
        .length;
    if (toAccept > 0) {
      items.add(
        DueItem(
          kind: DueKind.ahasToAccept,
          title:
              '$toAccept risk ${_plural(toAccept, 'assessment', 'assessments')} '
              '(AHA) waiting for your acceptance',
        ),
      );
    }
    final deficiencies = hazards
        .where((h) => h.isDeficiency && h.status != HazardStatus.closed)
        .length;
    if (deficiencies > 0) {
      items.add(
        DueItem(
          kind: DueKind.openDeficiencies,
          title:
              '$deficiencies open inspection '
              '${_plural(deficiencies, 'deficiency', 'deficiencies')}',
          detail: 'Track them in the Deficiency Log.',
        ),
      );
    }
  }

  return items;
}
