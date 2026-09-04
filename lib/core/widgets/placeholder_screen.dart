import 'package:flutter/material.dart';
import '../theme/app_text_styles.dart';

/// Temporary placeholder for features not yet implemented.
///
/// Every route in [AppRoutes] resolves to a real screen backed by this
/// widget so navigation and the responsive shell can be exercised end to end
/// before each feature is built out.
class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({super.key, required this.featureName, this.icon});

  final String featureName;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon ?? Icons.construction,
            size: 48,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text(featureName, style: AppTextStyles.titleLarge),
          const SizedBox(height: 4),
          const Text('Coming soon', style: AppTextStyles.bodyMedium),
        ],
      ),
    );
  }
}
