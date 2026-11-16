import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';

/// Shown when a Firebase-authenticated user's account is suspended, rejected,
/// or has no profile document at all.
///
/// Pending accounts do NOT land here — they get [PendingApprovalScreen],
/// because "waiting for review" is a normal, temporary state rather than a
/// denial, and conflating the two would tell a brand-new user their account
/// was refused.
///
/// The user is signed in as far as Firebase Auth is concerned, but is not
/// authorized for app access. Firestore rules deny their data access
/// independently of this screen — this is the explanation, not the
/// enforcement.
class AccessDeniedScreen extends StatelessWidget {
  const AccessDeniedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final (icon, title, message) = _contentFor(session);

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
                  Icon(icon, size: 56),
                  const SizedBox(height: AppSpacing.md),
                  Text(title, style: AppTextStyles.headlineLarge),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    message,
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

  /// Distinguishes the reasons access is denied so the user knows whether to
  /// wait, contact an administrator, or retry — without exposing internal
  /// Firebase error details.
  (IconData, String, String) _contentFor(SessionController session) {
    switch (session.status) {
      case AuthStatus.suspended:
        return (
          Icons.lock_outline,
          'Account Suspended',
          'Your account access has been suspended. Contact your Site '
              'Manager to restore it.',
        );
      case AuthStatus.rejected:
        return (
          Icons.person_off_outlined,
          'Account Not Approved',
          'Your registration was reviewed and not approved. Contact your '
              'Site Manager if you believe this is a mistake.',
        );
      case AuthStatus.profileMissing:
        return (
          Icons.person_off_outlined,
          'Profile Not Found',
          'Your sign-in worked, but no ALMASAFETY profile is linked to this '
              'account. Contact your Site Manager.',
        );
      case AuthStatus.error:
        return (
          Icons.error_outline,
          'Access Unavailable',
          session.lastError?.message ??
              'We could not verify your access. Please try again.',
        );
      case AuthStatus.loading:
      case AuthStatus.unauthenticated:
      case AuthStatus.authenticating:
      case AuthStatus.loadingProfile:
      case AuthStatus.pending:
      case AuthStatus.authenticated:
        return (
          Icons.lock_outline,
          'Access Denied',
          'Your account is not active. Contact your Site Manager for '
              'access.',
        );
    }
  }
}
