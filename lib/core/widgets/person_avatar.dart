import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// A round, colored initials avatar for a person — the same person always
/// gets the same color, so a crew list is easy to scan.
class PersonAvatar extends StatelessWidget {
  const PersonAvatar({super.key, required this.name, this.radius = 22});

  final String name;
  final double radius;

  static const _palette = [
    AppColors.people,
    AppColors.meetings,
    AppColors.learning,
    AppColors.hazards,
    AppColors.correctiveActions,
    AppColors.safetyAlerts,
    AppColors.projects,
    AppColors.analytics,
  ];

  static String initialsOf(String name) {
    final parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    final first = parts.first[0];
    final last = parts.length > 1 ? parts.last[0] : '';
    return (first + last).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final color = _palette[name.hashCode.abs() % _palette.length];
    return CircleAvatar(
      radius: radius,
      backgroundColor: color,
      child: Text(
        initialsOf(name),
        style: TextStyle(
          color: AppColors.onColor(color),
          fontWeight: FontWeight.w700,
          fontSize: radius * 0.7,
        ),
      ),
    );
  }
}
