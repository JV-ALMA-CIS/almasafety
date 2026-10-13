import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../domain/safety_meeting.dart';

/// How each meeting type looks everywhere.
extension SafetyMeetingKindStyle on SafetyMeetingKind {
  Color get color => switch (this) {
    SafetyMeetingKind.weeklyEmployee => AppColors.meetings,
    SafetyMeetingKind.monthlySupervisory => AppColors.teamMeetings,
  };

  IconData get icon => switch (this) {
    SafetyMeetingKind.weeklyEmployee => Icons.groups,
    SafetyMeetingKind.monthlySupervisory => Icons.supervisor_account,
  };
}

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// e.g. "Thu 8 Oct 2026".
String formatMeetingDay(DateTime day) =>
    '${_weekdays[day.weekday - 1]} ${day.day} ${_months[day.month - 1]} '
    '${day.year}';
