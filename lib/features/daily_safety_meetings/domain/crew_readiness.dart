/// A Foreman's view of which crew members are ready for today's Daily
/// Safety Meeting — built from either `getSiteCrewReadiness` (before the
/// meeting has been started) or `getMeetingAttendeeLearningStatus` (once
/// it has). Both use the server's attendance-gating resolver, so
/// [outstandingByWorker] only ever names learning that would actually block
/// a worker from being marked Present — never unrelated required learning.
class CrewReadiness {
  const CrewReadiness({
    required this.outstandingByWorker,
    this.activityNames = const [],
  });

  /// Outstanding attendance-gating learning TITLES per worker uid. An empty
  /// list means that worker is ready.
  final Map<String, List<String>> outstandingByWorker;

  /// The activities the readiness was resolved for (pre-meeting only).
  final List<String> activityNames;

  int get workerCount => outstandingByWorker.length;

  int get readyCount =>
      outstandingByWorker.values.where((titles) => titles.isEmpty).length;

  int get needAttentionCount => workerCount - readyCount;

  /// Workers with outstanding gating learning, in a stable order.
  List<MapEntry<String, List<String>>> get needingAttention => [
    for (final entry in outstandingByWorker.entries)
      if (entry.value.isNotEmpty) entry,
  ];
}
