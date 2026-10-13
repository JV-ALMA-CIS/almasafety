import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../domain/corrective_action_status.dart';

/// The color a [CorrectiveActionStatus] renders as — shared between
/// [CorrectiveActionsScreen] and [MyCorrectiveActionsScreen] so both status
/// badges agree, rather than each screen keeping its own copy of this
/// mapping.
Color correctiveActionStatusColor(CorrectiveActionStatus status) =>
    switch (status) {
      CorrectiveActionStatus.open => AppColors.meetings,
      CorrectiveActionStatus.inProgress => AppColors.analytics,
      CorrectiveActionStatus.submittedForReview => AppColors.warning,
      CorrectiveActionStatus.completed => AppColors.success,
      CorrectiveActionStatus.overdue => AppColors.danger,
    };

/// Each corrective action status's icon, used with its color.
IconData correctiveActionStatusIcon(CorrectiveActionStatus status) =>
    switch (status) {
      CorrectiveActionStatus.open => Icons.radio_button_unchecked,
      CorrectiveActionStatus.inProgress => Icons.autorenew,
      CorrectiveActionStatus.submittedForReview => Icons.rate_review,
      CorrectiveActionStatus.completed => Icons.task_alt,
      CorrectiveActionStatus.overdue => Icons.schedule,
    };
