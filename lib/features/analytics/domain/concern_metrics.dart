import '../../daily_safety_meetings/domain/meeting_concern_category.dart';

/// Concern metrics for the Analytics dashboard — a pure aggregation over
/// every meeting's concerns within the filtered meeting set, computed by
/// `AnalyticsRepository`. See `SafetyMeetingMetrics`'s doc comment for why
/// this is a view model, not a Firestore-backed type.
class ConcernMetrics {
  const ConcernMetrics({
    required this.totalCount,
    required this.openCount,
    required this.byCategory,
  });

  final int totalCount;
  final int openCount;

  /// Concern count keyed by [MeetingConcernCategory] — every category
  /// present, including zero-count ones, so the UI can render a
  /// consistent set of bars/rows without checking for missing keys.
  final Map<MeetingConcernCategory, int> byCategory;
}
