import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/routing/app_router.dart';
import 'package:jva_safety/routing/app_routes.dart';

/// Every operational route: requires a Firebase user AND an approved
/// (`accountStatus == active`) profile. Excludes the two additionally
/// role-gated routes ([AppRoutes.pendingApprovals],
/// [AppRoutes.administration]), which are covered in their own groups below
/// since an authenticated user needs more than [AuthStatus.authenticated] to
/// reach them.
const _protectedRoutes = [
  AppRoutes.dashboard,
  AppRoutes.workers,
  AppRoutes.projects,
  AppRoutes.sites,
  AppRoutes.activities,
  AppRoutes.safetyLearning,
  AppRoutes.safetyMeetingPoints,
  AppRoutes.dailySafetyMeetings,
  AppRoutes.hazards,
  AppRoutes.correctiveActions,
  AppRoutes.safetyAlerts,
  AppRoutes.notifications,
  AppRoutes.reports,
  AppRoutes.analytics,
];

/// Every route gated on [AuthStatus.authenticated] alone or on top of a
/// further role check — used by tests that assert over "every route this
/// status must never reach," where the additional role gates only make the
/// denial stronger.
const _allOperationalRoutes = [
  ..._protectedRoutes,
  AppRoutes.pendingApprovals,
  AppRoutes.activeUsers,
  AppRoutes.suspendedUsers,
  AppRoutes.administration,
  AppRoutes.manageOrganizations,
  AppRoutes.manageProjects,
  AppRoutes.manageSites,
  AppRoutes.manageSiteWorkers,
  AppRoutes.manageSafetyMeetingPoints,
  AppRoutes.manageDailySafetyMeetings,
  AppRoutes.manageActivities,
  AppRoutes.manageActivityWorkers,
];

/// The three routes gated on [canReviewPendingAccounts] rather than
/// [isPlatformAdministrator] — reviewing pending accounts and managing
/// already-reviewed ones share one authority boundary.
const _reviewRoutes = [
  AppRoutes.pendingApprovals,
  AppRoutes.activeUsers,
  AppRoutes.suspendedUsers,
];

/// The routes gated on [isPlatformAdministrator] alone, with no
/// [canManageOrgContent] exception — the company-wide Safety Learning and
/// Safety Meeting Point libraries are platform-level, `admin`-only
/// responsibilities, deliberately NOT delegated to `siteManager`
/// (PROJECT_CONTEXT.md §4, §12).
const _administrationRoutes = [
  AppRoutes.manageSafetyLearning,
  AppRoutes.manageSafetyMeetingPoints,
];

/// The routes gated on [isPlatformAdministrator] OR [canManageOrgContent] —
/// the administration hub, the Organization/Project/Site/Activity chain,
/// Site/Activity Workers, and the read-only Daily Safety Meetings review
/// screen, all reachable by an `admin` (any organization) or a
/// [AppRole.siteManager] (their own organization(s) only, enforced by the
/// screens/callables themselves rather than this router-level flag, which
/// only says "this role may enter the chain at all").
const _orgContentRoutes = [
  AppRoutes.administration,
  AppRoutes.manageOrganizations,
  AppRoutes.manageProjects,
  AppRoutes.manageSites,
  AppRoutes.manageSiteWorkers,
  AppRoutes.manageActivities,
  AppRoutes.manageActivityWorkers,
  AppRoutes.manageDailySafetyMeetings,
];

/// Statuses that must never reach an operational route.
const _deniedStatuses = [
  AuthStatus.unauthenticated,
  AuthStatus.authenticating,
  AuthStatus.pending,
  AuthStatus.suspended,
  AuthStatus.rejected,
  AuthStatus.profileMissing,
  AuthStatus.error,
  AuthStatus.loading,
  AuthStatus.loadingProfile,
];

void main() {
  group('authRedirect (unauthenticated user)', () {
    test('every operational route redirects to /login', () {
      for (final route in _allOperationalRoutes) {
        expect(
          authRedirect(AuthStatus.unauthenticated, route),
          AppRoutes.login,
          reason: '$route must not be reachable while signed out',
        );
      }
    });

    test('stays on /login without a redirect loop', () {
      expect(authRedirect(AuthStatus.unauthenticated, AppRoutes.login), isNull);
    });

    test('may reach /register', () {
      expect(
        authRedirect(AuthStatus.unauthenticated, AppRoutes.register),
        isNull,
      );
    });

    test('cannot reach /pending-approval without an account', () {
      expect(
        authRedirect(AuthStatus.unauthenticated, AppRoutes.pendingApproval),
        AppRoutes.login,
      );
    });
  });

  group('authRedirect (sign-in / registration in flight or failed)', () {
    test('authenticating stays on whichever public screen is showing', () {
      expect(authRedirect(AuthStatus.authenticating, AppRoutes.login), isNull);
      expect(
        authRedirect(AuthStatus.authenticating, AppRoutes.register),
        isNull,
      );
      expect(
        authRedirect(AuthStatus.authenticating, AppRoutes.dashboard),
        AppRoutes.login,
      );
    });

    test('an auth error returns the user to a public screen, not the app', () {
      expect(authRedirect(AuthStatus.error, AppRoutes.login), isNull);
      expect(authRedirect(AuthStatus.error, AppRoutes.register), isNull);
      expect(
        authRedirect(AuthStatus.error, AppRoutes.dashboard),
        AppRoutes.login,
      );
    });
  });

  group('authRedirect (pending user)', () {
    test('every operational route redirects to /pending-approval', () {
      for (final route in _allOperationalRoutes) {
        expect(
          authRedirect(AuthStatus.pending, route),
          AppRoutes.pendingApproval,
          reason: '$route must not be reachable while awaiting approval',
        );
      }
    });

    test('stays on /pending-approval without a redirect loop', () {
      expect(
        authRedirect(AuthStatus.pending, AppRoutes.pendingApproval),
        isNull,
      );
    });

    test('cannot slip back to /login or /register while pending', () {
      expect(
        authRedirect(AuthStatus.pending, AppRoutes.login),
        AppRoutes.pendingApproval,
      );
      expect(
        authRedirect(AuthStatus.pending, AppRoutes.register),
        AppRoutes.pendingApproval,
      );
    });

    test('is not sent to /access-denied — pending is not a refusal', () {
      expect(
        authRedirect(AuthStatus.pending, AppRoutes.accessDenied),
        AppRoutes.pendingApproval,
      );
    });
  });

  group('authRedirect (suspended user)', () {
    test('every operational route redirects to /access-denied', () {
      for (final route in _allOperationalRoutes) {
        expect(
          authRedirect(AuthStatus.suspended, route),
          AppRoutes.accessDenied,
          reason: '$route must not be reachable by a suspended user',
        );
      }
    });

    test('cannot slip back to /login or the pending screen', () {
      expect(
        authRedirect(AuthStatus.suspended, AppRoutes.login),
        AppRoutes.accessDenied,
      );
      expect(
        authRedirect(AuthStatus.suspended, AppRoutes.pendingApproval),
        AppRoutes.accessDenied,
      );
    });

    test('stays on /access-denied without a redirect loop', () {
      expect(
        authRedirect(AuthStatus.suspended, AppRoutes.accessDenied),
        isNull,
      );
    });
  });

  group('authRedirect (rejected user)', () {
    test('every operational route redirects to /access-denied', () {
      for (final route in _allOperationalRoutes) {
        expect(
          authRedirect(AuthStatus.rejected, route),
          AppRoutes.accessDenied,
          reason: '$route must not be reachable by a rejected user',
        );
      }
    });

    test('cannot re-register their way in from the rejected state', () {
      expect(
        authRedirect(AuthStatus.rejected, AppRoutes.register),
        AppRoutes.accessDenied,
      );
    });

    test('stays on /access-denied without a redirect loop', () {
      expect(
        authRedirect(AuthStatus.rejected, AppRoutes.accessDenied),
        isNull,
      );
    });
  });

  group('authRedirect (signed in but no profile)', () {
    test('every operational route redirects to /access-denied', () {
      for (final route in _allOperationalRoutes) {
        expect(
          authRedirect(AuthStatus.profileMissing, route),
          AppRoutes.accessDenied,
          reason: '$route must not be reachable without a profile',
        );
      }
    });
  });

  group('authRedirect (approved + active user)', () {
    test('is allowed onto every route ungated by an additional role', () {
      for (final route in _protectedRoutes) {
        expect(
          authRedirect(AuthStatus.authenticated, route),
          isNull,
          reason: '$route should be reachable by an approved user',
        );
      }
    });

    test('without an authorizing role, is turned away from the review '
        'routes and the administration routes', () {
      for (final route in _reviewRoutes) {
        expect(
          authRedirect(AuthStatus.authenticated, route),
          AppRoutes.dashboard,
          reason: '$route requires canReviewPendingAccounts',
        );
      }
      for (final route in _administrationRoutes) {
        expect(
          authRedirect(AuthStatus.authenticated, route),
          AppRoutes.dashboard,
          reason: '$route requires isPlatformAdministrator',
        );
      }
      for (final route in _orgContentRoutes) {
        expect(
          authRedirect(AuthStatus.authenticated, route),
          AppRoutes.dashboard,
          reason: '$route requires isPlatformAdministrator or '
              'canManageOrgContent',
        );
      }
    });

    test('is redirected away from every gate screen to the dashboard', () {
      for (final route in [
        AppRoutes.login,
        AppRoutes.register,
        AppRoutes.pendingApproval,
        AppRoutes.accessDenied,
        AppRoutes.sessionLoading,
      ]) {
        expect(
          authRedirect(AuthStatus.authenticated, route),
          AppRoutes.dashboard,
          reason: 'an approved user should not linger on $route',
        );
      }
    });
  });

  group('authRedirect (session still resolving)', () {
    test('redirects any route to the loading screen', () {
      expect(
        authRedirect(AuthStatus.loading, AppRoutes.dashboard),
        AppRoutes.sessionLoading,
      );
      expect(
        authRedirect(AuthStatus.loadingProfile, AppRoutes.login),
        AppRoutes.sessionLoading,
      );
    });

    test('stays on the loading screen without a redirect loop', () {
      expect(
        authRedirect(AuthStatus.loading, AppRoutes.sessionLoading),
        isNull,
      );
      expect(
        authRedirect(AuthStatus.loadingProfile, AppRoutes.sessionLoading),
        isNull,
      );
    });
  });

  group('route protection is exhaustive', () {
    test('only AuthStatus.authenticated may render an operational route', () {
      for (final status in _deniedStatuses) {
        for (final route in _protectedRoutes) {
          expect(
            authRedirect(status, route),
            isNotNull,
            reason: '$status must be redirected away from $route',
          );
        }
      }
    });

    test('every AuthStatus is classified — none falls through by accident',
        () {
      // If a status is added and left unhandled, it would either fail to
      // compile (the switch is exhaustive) or show up here as an
      // unclassified status that reaches the dashboard.
      for (final status in AuthStatus.values) {
        final reachesApp =
            authRedirect(status, AppRoutes.dashboard) == null;
        expect(
          reachesApp,
          status == AuthStatus.authenticated,
          reason: '$status reaching the dashboard is ${!reachesApp}',
        );
      }
    });
  });

  group('authRedirect (review routes are capability-gated)', () {
    test('an active non-approver is redirected to the dashboard', () {
      for (final route in _reviewRoutes) {
        expect(
          authRedirect(AuthStatus.authenticated, route),
          AppRoutes.dashboard,
        );
        expect(
          authRedirect(
            AuthStatus.authenticated,
            route,
            canReviewPendingAccounts: false,
          ),
          AppRoutes.dashboard,
        );
      }
    });

    test('an active approver may reach all three', () {
      for (final route in _reviewRoutes) {
        expect(
          authRedirect(
            AuthStatus.authenticated,
            route,
            canReviewPendingAccounts: true,
          ),
          isNull,
          reason: '$route should be reachable with canReviewPendingAccounts',
        );
      }
    });

    test('the capability never substitutes for an active account', () {
      // The flag is additive to accountStatus, never a bypass of it: a
      // suspended or pending approver reaches nothing, exactly as before.
      for (final status in _deniedStatuses) {
        for (final route in _reviewRoutes) {
          expect(
            authRedirect(status, route, canReviewPendingAccounts: true),
            isNotNull,
            reason: '$status must not reach $route even as an approver',
          );
        }
      }
    });

    test('the capability grants no other route', () {
      // canReviewPendingAccounts is scoped to exactly these three screens.
      // It must not widen access to anything else, in any session state.
      for (final status in AuthStatus.values) {
        for (final route in _protectedRoutes) {
          expect(
            authRedirect(status, route, canReviewPendingAccounts: true),
            authRedirect(status, route, canReviewPendingAccounts: false),
            reason: 'the reviewer role changed access to $route under $status',
          );
        }
      }
    });

    test('an approver is still redirected away from the gate screens', () {
      for (final route in [
        AppRoutes.login,
        AppRoutes.register,
        AppRoutes.pendingApproval,
        AppRoutes.accessDenied,
        AppRoutes.sessionLoading,
      ]) {
        expect(
          authRedirect(
            AuthStatus.authenticated,
            route,
            canReviewPendingAccounts: true,
          ),
          AppRoutes.dashboard,
        );
      }
    });

    test('redirecting a non-approver away lands somewhere stable', () {
      for (final route in _reviewRoutes) {
        final target = authRedirect(AuthStatus.authenticated, route);

        expect(target, isNotNull);
        expect(authRedirect(AuthStatus.authenticated, target!), isNull);
      }
    });
  });

  group('authRedirect (administration routes are platform-administrator-gated)',
      () {
    test('an active non-administrator is redirected to the dashboard', () {
      for (final route in _administrationRoutes) {
        expect(
          authRedirect(AuthStatus.authenticated, route),
          AppRoutes.dashboard,
        );
        expect(
          authRedirect(
            AuthStatus.authenticated,
            route,
            isPlatformAdministrator: false,
          ),
          AppRoutes.dashboard,
        );
      }
    });

    test('an active Admin may reach both', () {
      for (final route in _administrationRoutes) {
        expect(
          authRedirect(
            AuthStatus.authenticated,
            route,
            isPlatformAdministrator: true,
          ),
          isNull,
          reason: '$route should be reachable with isPlatformAdministrator',
        );
      }
    });

    test('platform authority never substitutes for an active account', () {
      // isPlatformAdministrator is additive to accountStatus, never a
      // bypass of it: a suspended or pending Admin reaches
      // nothing.
      for (final status in _deniedStatuses) {
        for (final route in _administrationRoutes) {
          expect(
            authRedirect(status, route, isPlatformAdministrator: true),
            isNotNull,
            reason: '$status must not reach $route even as a System '
                'Administrator',
          );
        }
      }
    });

    test('platform authority grants no other route on its own', () {
      // isPlatformAdministrator (as tested here) is scoped to exactly the
      // library screens in _administrationRoutes; the
      // pending-approvals inbox still requires canReviewPendingAccounts
      // separately (which SessionController derives from the same role, but
      // the redirect function itself treats the two flags independently).
      for (final status in AuthStatus.values) {
        for (final route in _protectedRoutes) {
          expect(
            authRedirect(status, route, isPlatformAdministrator: true),
            authRedirect(status, route, isPlatformAdministrator: false),
            reason: 'platform authority changed access to $route under '
                '$status',
          );
        }
      }
    });

    test('an Admin is still redirected away from the gate '
        'screens', () {
      for (final route in [
        AppRoutes.login,
        AppRoutes.register,
        AppRoutes.pendingApproval,
        AppRoutes.accessDenied,
        AppRoutes.sessionLoading,
      ]) {
        expect(
          authRedirect(
            AuthStatus.authenticated,
            route,
            isPlatformAdministrator: true,
          ),
          AppRoutes.dashboard,
        );
      }
    });

    test('redirecting a non-administrator away lands somewhere stable', () {
      for (final route in _administrationRoutes) {
        final target = authRedirect(AuthStatus.authenticated, route);

        expect(target, isNotNull);
        expect(authRedirect(AuthStatus.authenticated, target!), isNull);
      }
    });
  });

  group(
    'authRedirect (org-content routes are platform-administrator-or-'
    'org-content-manager-gated)',
    () {
      test('an active user with neither flag is redirected to the dashboard',
          () {
        for (final route in _orgContentRoutes) {
          expect(
            authRedirect(AuthStatus.authenticated, route),
            AppRoutes.dashboard,
          );
          expect(
            authRedirect(
              AuthStatus.authenticated,
              route,
              isPlatformAdministrator: false,
              canManageOrgContent: false,
            ),
            AppRoutes.dashboard,
          );
        }
      });

      test('an active Admin may reach every org-content route', () {
        for (final route in _orgContentRoutes) {
          expect(
            authRedirect(
              AuthStatus.authenticated,
              route,
              isPlatformAdministrator: true,
            ),
            isNull,
            reason: '$route should be reachable with isPlatformAdministrator',
          );
        }
      });

      test('an active Site Manager may reach every org-content route', () {
        // canManageOrgContent alone (no isPlatformAdministrator) is enough —
        // the screens themselves narrow further to the caller's own
        // organization; this router-level flag only says "may enter the
        // chain at all," matching how canReviewPendingAccounts is tested
        // above.
        for (final route in _orgContentRoutes) {
          expect(
            authRedirect(
              AuthStatus.authenticated,
              route,
              canManageOrgContent: true,
            ),
            isNull,
            reason: '$route should be reachable with canManageOrgContent',
          );
        }
      });

      test('neither flag substitutes for an active account', () {
        for (final status in _deniedStatuses) {
          for (final route in _orgContentRoutes) {
            expect(
              authRedirect(
                status,
                route,
                isPlatformAdministrator: true,
                canManageOrgContent: true,
              ),
              isNotNull,
              reason: '$status must not reach $route regardless of role',
            );
          }
        }
      });

      test('canManageOrgContent grants no other route on its own', () {
        for (final status in AuthStatus.values) {
          for (final route in _protectedRoutes) {
            expect(
              authRedirect(status, route, canManageOrgContent: true),
              authRedirect(status, route, canManageOrgContent: false),
              reason: 'canManageOrgContent changed access to $route under '
                  '$status',
            );
          }
        }
      });

      test('a Site Manager is still redirected away from the '
          'gate screens', () {
        for (final route in [
          AppRoutes.login,
          AppRoutes.register,
          AppRoutes.pendingApproval,
          AppRoutes.accessDenied,
          AppRoutes.sessionLoading,
        ]) {
          expect(
            authRedirect(
              AuthStatus.authenticated,
              route,
              canManageOrgContent: true,
            ),
            AppRoutes.dashboard,
          );
        }
      });

      test('redirecting an unauthorized user away lands somewhere stable',
          () {
        for (final route in _orgContentRoutes) {
          final target = authRedirect(AuthStatus.authenticated, route);

          expect(target, isNotNull);
          expect(authRedirect(AuthStatus.authenticated, target!), isNull);
        }
      });
    },
  );

  group('authRedirect (no redirect loops anywhere)', () {
    test('the redirect target of any status is itself stable', () {
      // Applying the redirect twice must reach a fixed point, otherwise the
      // router would bounce between two locations forever.
      for (final status in AuthStatus.values) {
        for (final route in [
          ..._protectedRoutes,
          AppRoutes.login,
          AppRoutes.register,
          AppRoutes.pendingApproval,
          AppRoutes.accessDenied,
          AppRoutes.sessionLoading,
        ]) {
          final first = authRedirect(status, route);
          if (first == null) continue;
          expect(
            authRedirect(status, first),
            isNull,
            reason: '$status redirected $route -> $first, which redirects again',
          );
        }
      }
    });
  });
}
