import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';

/// Shown to a signed-in user whose account is still `pending`.
///
/// This is a waiting room, not a dead end: [SessionController] keeps a live
/// snapshot listener on the profile document, so the moment an approver sets
/// the account to `active` the session status changes and the router moves
/// the user into the app without any refresh or re-login.
///
/// The screen offers no action that could advance the user's own account —
/// only signing out. Firestore rules deny a pending user all operational
/// data independently of this screen; this is the explanation, not the
/// enforcement.
class PendingApprovalScreen extends StatelessWidget {
  const PendingApprovalScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final name = session.profile?.name;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.hourglass_top_outlined, size: 56),
                  const SizedBox(height: AppSpacing.md),
                  const Text(
                    'Account Pending Approval',
                    style: AppTextStyles.headlineLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    name == null || name.isEmpty
                        ? 'Your account has been created and is waiting for '
                              'review.'
                        : 'Thanks, $name. Your account has been created and '
                              'is waiting for review.',
                    style: AppTextStyles.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  const Text(
                    'An authorized JVA Safety user will assign your role '
                    'and site access. You will get access automatically '
                    'once that happens — no need to sign in again.',
                    style: AppTextStyles.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: AppSpacing.minTouchTarget,
                    ),
                    child: OutlinedButton(
                      onPressed: () => session.signOut(),
                      child: const Text('Sign out'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
