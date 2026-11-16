import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/utils/meeting_date.dart';

void main() {
  group('meetingDate (Africa/Nairobi)', () {
    test('rolls over at 21:00 UTC — midnight in Nairobi', () {
      expect(meetingDate(DateTime.utc(2026, 10, 27, 20, 59, 59)), '2026-10-27');
      expect(meetingDate(DateTime.utc(2026, 10, 27, 21)), '2026-10-28');
    });

    test('an early-morning meeting is on the Nairobi day, not the UTC day', () {
      // 01:30 in Nairobi on 1 November is still 31 October in UTC.
      expect(meetingDate(DateTime.utc(2026, 10, 31, 22, 30)), '2026-11-01');
    });

    test('crosses a year boundary', () {
      expect(meetingDate(DateTime.utc(2026, 12, 31, 21)), '2027-01-01');
    });

    test('agrees with the server for the same instant whatever the phone '
        'zone is', () {
      // The same instant written in two different local offsets.
      final instant = DateTime.utc(2026, 10, 28, 4, 15);
      expect(meetingDate(instant), '2026-10-28');
      expect(meetingDate(instant.toLocal()), '2026-10-28');
    });
  });

  group('meetingClock', () {
    test('prints Nairobi clock time', () {
      expect(meetingClock(DateTime.utc(2026, 10, 28, 3, 45)), '06:45');
      expect(meetingClock(DateTime.utc(2026, 10, 28, 21, 5)), '00:05');
    });
  });
}
