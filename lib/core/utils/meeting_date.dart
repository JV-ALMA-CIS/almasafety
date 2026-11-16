/// The calendar day a Daily Safety Meeting (and a Pre-Start Check) belongs
/// to, as a `yyyy-MM-dd` string in Africa/Nairobi time — the same day the
/// server's `todaysMeetingDate()` (`functions/src/worker_learning_callable.ts`)
/// stores, whatever time zone the phone itself is set to.
///
/// Nairobi is UTC+3 all year (no daylight saving), so a fixed offset is
/// exact and needs no time-zone database.
String meetingDate([DateTime? now]) {
  final nairobi = (now ?? DateTime.now()).toUtc().add(_nairobiOffset);
  final month = nairobi.month.toString().padLeft(2, '0');
  final day = nairobi.day.toString().padLeft(2, '0');
  return '${nairobi.year.toString().padLeft(4, '0')}-$month-$day';
}

/// [time] as a Nairobi clock time, e.g. "06:45" — how a meeting's start
/// and end are printed, whatever time zone the phone is set to.
String meetingClock(DateTime time) {
  final nairobi = time.toUtc().add(_nairobiOffset);
  final hour = nairobi.hour.toString().padLeft(2, '0');
  final minute = nairobi.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

const _nairobiOffset = Duration(hours: 3);
