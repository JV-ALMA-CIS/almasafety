import 'worker_compliance_row.dart';

/// The aggregate readiness count for one activity — "Roofing: 18 workers,
/// 15 Ready, 3 Not Ready" on [SafetyLearningComplianceScreen]. Derived
/// purely by counting an existing list of [WorkerComplianceRow]s; not a
/// second source of truth.
class ActivityComplianceSummary {
  const ActivityComplianceSummary({
    required this.activityId,
    required this.activityName,
    required this.rows,
  });

  final String activityId;
  final String activityName;
  final List<WorkerComplianceRow> rows;

  int get workerCount => rows.length;
  int get readyCount => rows.where((r) => r.isReady).length;
  int get notReadyCount => workerCount - readyCount;
}
