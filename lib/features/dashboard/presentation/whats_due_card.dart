import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/live_stream_builder.dart';
import '../../../routing/app_routes.dart';
import '../../hazards/data/hazard_repository.dart';
import '../../hazards/domain/hazard.dart';
import '../../incidents/data/incident_repository.dart';
import '../../incidents/domain/incident.dart';
import '../../inspections/data/inspection_repository.dart';
import '../../inspections/domain/inspection.dart';
import '../../organizations/data/site_repository.dart';
import '../../organizations/domain/organization_record_status.dart';
import '../../organizations/domain/site.dart';
import '../../risk_assessments/data/risk_assessment_repository.dart';
import '../../risk_assessments/domain/risk_assessment.dart';
import '../../safety_meetings/data/safety_meeting_repository.dart';
import '../../safety_meetings/domain/safety_meeting.dart';
import '../domain/whats_due.dart';

/// "What's due" on a Site Manager's, Admin's or Foreman's dashboard: the
/// Safety Plan's routine — daily inspections, sign-offs, the weekly and
/// monthly meetings, AHAs to accept, open deficiencies — as a short list
/// of what still needs doing, each opening the page where it is done (see
/// [computeDueItems]). Live: a line disappears as soon as it is done.
///
/// [siteIds] is the scope: null = every open site (Site Manager/Admin), or
/// a Foreman's own sites. If anything cannot be loaded the card shows
/// nothing rather than breaking the dashboard.
class WhatsDueCard extends StatefulWidget {
  const WhatsDueCard({
    super.key,
    required this.organizationId,
    required this.uid,
    required this.isManager,
    this.siteIds,
    this.siteRepository,
    this.inspectionRepository,
    this.safetyMeetingRepository,
    this.riskAssessmentRepository,
    this.hazardRepository,
    this.incidentRepository,
    this.now,
  });

  final String organizationId;
  final String uid;
  final bool isManager;
  final List<String>? siteIds;

  /// Injected in tests.
  final SiteRepository? siteRepository;
  final InspectionRepository? inspectionRepository;
  final SafetyMeetingRepository? safetyMeetingRepository;
  final RiskAssessmentRepository? riskAssessmentRepository;
  final HazardRepository? hazardRepository;
  final IncidentRepository? incidentRepository;
  final DateTime Function()? now;

  @override
  State<WhatsDueCard> createState() => _WhatsDueCardState();
}

/// Everything [computeDueItems] needs, as it arrives.
typedef _DueData = ({
  List<Site> sites,
  List<InspectionTemplate> templates,
  List<Inspection> inspections,
  List<SafetyMeeting> meetings,
  List<RiskAssessment> riskAssessments,
  List<Hazard> hazards,
  List<Incident> incidents,
});

class _WhatsDueCardState extends State<WhatsDueCard> {
  Stream<_DueData> _watch() {
    try {
      final firestore = FirestoreService();
      final org = widget.organizationId;
      final sites =
          widget.siteRepository ??
          SiteRepository(firestoreService: firestore, organizationId: org);
      final inspections =
          widget.inspectionRepository ??
          InspectionRepository(
            firestoreService: firestore,
            organizationId: org,
          );
      final meetings =
          widget.safetyMeetingRepository ??
          SafetyMeetingRepository(
            firestoreService: firestore,
            organizationId: org,
          );
      final ids = widget.siteIds;
      final streams = <Stream<Object?>>[
        ids == null ? sites.watchAll() : sites.watchByIds(ids),
        inspections.watchTemplates(),
        inspections.watchInspections(),
        meetings.watchMeetings(),
        if (widget.isManager) ...[
          (widget.riskAssessmentRepository ??
                  RiskAssessmentRepository(
                    firestoreService: firestore,
                    organizationId: org,
                  ))
              .watchAll(),
          (widget.hazardRepository ??
                  HazardRepository(
                    firestoreService: firestore,
                    organizationId: org,
                  ))
              .watchForOrganization(),
          (widget.incidentRepository ??
                  IncidentRepository(
                    firestoreService: firestore,
                    organizationId: org,
                  ))
              .watchForOrganization(),
        ],
      ];
      return _combineLatest(streams).map(
        (values) => (
          sites: [
            for (final site in values[0] as List<Site>)
              if (site.status == OrganizationRecordStatus.active) site,
          ],
          templates: values[1] as List<InspectionTemplate>,
          inspections: values[2] as List<Inspection>,
          meetings: values[3] as List<SafetyMeeting>,
          riskAssessments: widget.isManager
              ? values[4] as List<RiskAssessment>
              : const <RiskAssessment>[],
          hazards: widget.isManager
              ? values[5] as List<Hazard>
              : const <Hazard>[],
          incidents: widget.isManager
              ? values[6] as List<Incident>
              : const <Incident>[],
        ),
      );
    } on Object catch (e) {
      return Stream.error(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LiveStreamBuilder<_DueData>(
      streamKey: (
        widget.organizationId,
        widget.uid,
        widget.isManager,
        widget.siteIds?.join(','),
      ),
      stream: _watch,
      builder: (context, snapshot) {
        if (snapshot.hasError) return const SizedBox.shrink();
        final data = snapshot.data;
        if (data == null) {
          return const Padding(
            padding: EdgeInsets.all(AppSpacing.md),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final items = computeDueItems(
          uid: widget.uid,
          isManager: widget.isManager,
          sites: data.sites,
          templates: data.templates,
          inspections: data.inspections,
          meetings: data.meetings,
          riskAssessments: data.riskAssessments,
          hazards: data.hazards,
          incidents: data.incidents,
          now: (widget.now ?? DateTime.now)(),
        );
        if (items.isEmpty) {
          return const _DueRow(
            icon: Icons.task_alt,
            color: AppColors.go,
            title: "Nothing due — you're up to date",
          );
        }
        return Column(
          children: [
            for (final item in items) ...[
              _DueRow(
                icon: item.kind.icon,
                color: item.kind.color,
                title: item.title,
                detail: item.detail,
                onTap: () => context.go(item.kind.route),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
          ],
        );
      },
    );
  }
}

extension on DueKind {
  IconData get icon => switch (this) {
    DueKind.incidentReportsOverdue => Icons.error,
    DueKind.incidentReportingNotSet => Icons.priority_high,
    DueKind.incidentReportsDueSoon => Icons.timer_outlined,
    DueKind.inspectionsToSignOff => Icons.verified_outlined,
    DueKind.inspectionsInProgress => Icons.edit_note,
    DueKind.dailyInspectionNotDone => Icons.fact_check_outlined,
    DueKind.weeklyMeetingNotHeld => Icons.groups_outlined,
    DueKind.monthlyMeetingNotHeld => Icons.supervisor_account_outlined,
    DueKind.ahasToAccept => Icons.assignment_late_outlined,
    DueKind.openDeficiencies => Icons.list_alt,
    DueKind.noChecklists => Icons.checklist,
  };

  Color get color => switch (this) {
    DueKind.incidentReportsOverdue => AppColors.stop,
    DueKind.incidentReportingNotSet => AppColors.stop,
    DueKind.incidentReportsDueSoon => AppColors.hazards,
    DueKind.inspectionsToSignOff => AppColors.analytics,
    DueKind.inspectionsInProgress => AppColors.warning,
    DueKind.dailyInspectionNotDone => AppColors.inspections,
    DueKind.weeklyMeetingNotHeld => AppColors.meetings,
    DueKind.monthlyMeetingNotHeld => AppColors.teamMeetings,
    DueKind.ahasToAccept => AppColors.riskAssessments,
    DueKind.openDeficiencies => AppColors.stop,
    DueKind.noChecklists => AppColors.inspections,
  };

  String get route => switch (this) {
    DueKind.incidentReportsOverdue ||
    DueKind.incidentReportingNotSet ||
    DueKind.incidentReportsDueSoon => AppRoutes.incidents,
    DueKind.inspectionsToSignOff ||
    DueKind.inspectionsInProgress ||
    DueKind.dailyInspectionNotDone ||
    DueKind.openDeficiencies ||
    DueKind.noChecklists => AppRoutes.inspections,
    DueKind.weeklyMeetingNotHeld ||
    DueKind.monthlyMeetingNotHeld => AppRoutes.safetyMeetings,
    DueKind.ahasToAccept => AppRoutes.riskAssessments,
  };
}

class _DueRow extends StatelessWidget {
  const _DueRow({
    required this.icon,
    required this.color,
    required this.title,
    this.detail,
    this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String? detail;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Color.alphaBlend(
        color.withValues(alpha: 0.10),
        Theme.of(context).colorScheme.surface,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color.withValues(alpha: 0.45)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.sm + 4),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(AppSpacing.sm),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: AppColors.onColor(color), size: 20),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: AppTextStyles.bodyLarge.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (detail != null) ...[
                      const SizedBox(height: 2),
                      Text(detail!, style: AppTextStyles.bodyMedium),
                    ],
                  ],
                ),
              ),
              if (onTap != null)
                const Icon(Icons.chevron_right, color: AppColors.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}

/// Emits the latest value of every stream in [streams] (as a list, in the
/// same order) once each has emitted, and again whenever any changes. An
/// error from any stream is passed on.
Stream<List<Object?>> _combineLatest(List<Stream<Object?>> streams) {
  late StreamController<List<Object?>> controller;
  final subscriptions = <StreamSubscription<Object?>>[];
  final latest = List<Object?>.filled(streams.length, null);
  final seen = List<bool>.filled(streams.length, false);

  controller = StreamController<List<Object?>>(
    onListen: () {
      for (var i = 0; i < streams.length; i++) {
        subscriptions.add(
          streams[i].listen((value) {
            latest[i] = value;
            seen[i] = true;
            if (seen.every((s) => s)) controller.add(List.of(latest));
          }, onError: controller.addError),
        );
      }
    },
    onCancel: () async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    },
  );
  return controller.stream;
}
