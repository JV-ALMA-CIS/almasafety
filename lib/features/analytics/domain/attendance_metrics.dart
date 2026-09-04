/// Attendance metrics for the Analytics dashboard — a pure aggregation over
/// every meeting's attendance records within the filtered meeting set,
/// computed by `AnalyticsRepository`. See `SafetyMeetingMetrics`'s doc
/// comment for why this is a view model, not a Firestore-backed type.
class AttendanceMetrics {
  const AttendanceMetrics({
    required this.presentCount,
    required this.absentCount,
  });

  final int presentCount;
  final int absentCount;

  int get totalCount => presentCount + absentCount;

  /// Present as a percentage of total attendance, `0` when there is no
  /// attendance recorded at all (never divides by zero).
  double get attendancePercentage {
    if (totalCount == 0) return 0;
    return presentCount / totalCount * 100;
  }
}
