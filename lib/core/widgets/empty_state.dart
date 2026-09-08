import 'package:flutter/material.dart';
import '../theme/app_text_styles.dart';

/// Standard empty-state placeholder for lists/screens with no data yet.
///
/// [action], when given, renders a primary button directly beneath the
/// message — the empty state itself is the natural place to offer the one
/// thing that would fix it (e.g. "Add Project"), rather than leaving a
/// first-time user to notice a small toolbar icon elsewhere on the screen.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;

  /// A call-to-action shown below the message, e.g.
  /// `ElevatedButton.icon(onPressed: ..., icon: ..., label: Text('Add X'))`.
  /// Omit when there is nothing the viewer of this empty state is
  /// authorized to do about it (e.g. a read-only viewer).
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(title, style: AppTextStyles.titleLarge),
            if (message != null) ...[
              const SizedBox(height: 4),
              Text(
                message!,
                style: AppTextStyles.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ],
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}
