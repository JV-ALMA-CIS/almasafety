import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../data/safety_meeting_point_repository.dart';
import '../domain/safety_meeting_point.dart';

/// The signed-in worker's/foreman's view of active safety meeting points for
/// their own organization — read-only, matching [MySafetyLearningScreen]'s
/// simplicity for a first worker-facing surface over this data.
///
/// Streams [SafetyMeetingPointRepository.watchActive] only: an inactive
/// meeting point is retained for administrators but never shown here. This
/// is also the retrieval a future Daily Safety Meeting screen will reuse,
/// narrowed further by `activityId`/`riskId`.
class MySafetyMeetingPointsScreen extends StatefulWidget {
  const MySafetyMeetingPointsScreen({super.key, this.repository});

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real repository scoped to the signed-in user's
  /// organization.
  final SafetyMeetingPointRepository? repository;

  @override
  State<MySafetyMeetingPointsScreen> createState() =>
      _MySafetyMeetingPointsScreenState();
}

class _MySafetyMeetingPointsScreenState
    extends State<MySafetyMeetingPointsScreen> {
  SafetyMeetingPointRepository? _repository;

  SafetyMeetingPointRepository _repositoryFor(String organizationId) {
    final existing = _repository;
    if (existing != null && existing.organizationId == organizationId) {
      return existing;
    }
    final created = widget.repository ??
        SafetyMeetingPointRepository(
          firestoreService: FirestoreService(),
          organizationId: organizationId,
        );
    _repository = created;
    return created;
  }

  @override
  Widget build(BuildContext context) {
    final profile = context.watch<SessionController>().profile;
    final organizationId = profile?.organizationId;

    if (organizationId == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: Text(
            'Your account has no organization yet.',
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return StreamBuilder<List<SafetyMeetingPoint>>(
      stream: _repositoryFor(organizationId).watchActive(),
      builder: (context, snapshot) {
        final items = snapshot.data ?? const <SafetyMeetingPoint>[];
        final isLoading = snapshot.connectionState == ConnectionState.waiting;

        if (isLoading && items.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.lg),
              child: Text(
                'Could not load safety meeting points. Please try again.',
                style: AppTextStyles.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        if (items.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.lg),
              child: Text(
                'No safety meeting points are available yet.',
                style: AppTextStyles.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        return ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            Text('Safety Meeting Points', style: AppTextStyles.headlineMedium),
            const SizedBox(height: AppSpacing.md),
            for (final point in items) ...[
              _MeetingPointCard(point: point),
              const SizedBox(height: AppSpacing.sm),
            ],
          ],
        );
      },
    );
  }
}

class _MeetingPointCard extends StatelessWidget {
  const _MeetingPointCard({required this.point});

  final SafetyMeetingPoint point;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(point.title, style: AppTextStyles.titleLarge),
            const SizedBox(height: AppSpacing.xs),
            Row(
              children: [
                const Icon(
                  Icons.category_outlined,
                  size: 16,
                  color: AppColors.textSecondary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(point.category, style: AppTextStyles.bodyMedium),
              ],
            ),
            if (point.description != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(point.description!, style: AppTextStyles.bodyMedium),
            ],
          ],
        ),
      ),
    );
  }
}
