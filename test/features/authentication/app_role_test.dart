import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';

void main() {
  group('AppRole.canReviewPendingAccounts', () {
    test('grants review authority to Admin', () {
      expect(AppRole.admin.canReviewPendingAccounts, isTrue);
    });

    test('grants review authority to Site Manager', () {
      expect(AppRole.siteManager.canReviewPendingAccounts, isTrue);
    });

    test('grants review authority to Foreman, scoped to their own site(s)',
        () {
      // §16 grants Foreman approval authority over Workers on their own
      // assigned site(s) — unlike the old model's excluded siteSupervisor.
      expect(AppRole.foreman.canReviewPendingAccounts, isTrue);
    });

    test('Worker can never review pending accounts', () {
      expect(AppRole.worker.canReviewPendingAccounts, isFalse);
    });

    test('canAssignRole mirrors canReviewPendingAccounts exactly', () {
      for (final role in AppRole.values) {
        expect(role.canAssignRole, role.canReviewPendingAccounts);
      }
    });
  });

  group('AppRole.canReviewDailySafetyMeetings', () {
    test('grants review authority to Admin and Site Manager', () {
      expect(AppRole.admin.canReviewDailySafetyMeetings, isTrue);
      expect(AppRole.siteManager.canReviewDailySafetyMeetings, isTrue);
    });

    test('withholds review authority from Foreman', () {
      // PROJECT_CONTEXT.md §16/§21/§22A: the Foreman's role is to conduct
      // and record Daily Safety Meetings in their own Meeting Workspace, not
      // to review other Foremen's meetings in the read-only Administrator
      // meeting list — that belongs to siteManager/admin only.
      expect(AppRole.foreman.canReviewDailySafetyMeetings, isFalse);
    });

    test('Worker cannot review daily safety meetings organization-wide', () {
      expect(AppRole.worker.canReviewDailySafetyMeetings, isFalse);
    });
  });

  group('AppRole.tryFromId', () {
    test('parses every known role by its stored id', () {
      for (final role in AppRole.values) {
        expect(AppRole.tryFromId(role.id), role);
      }
    });

    test('returns null for an unknown or null id', () {
      expect(AppRole.tryFromId('platformOwner'), isNull);
      expect(AppRole.tryFromId(null), isNull);
      expect(AppRole.tryFromId(''), isNull);
    });
  });

  group('AppRole.label', () {
    test('every role has a distinct, human-readable label', () {
      final labels = AppRole.values.map((r) => r.label).toSet();
      expect(labels, hasLength(AppRole.values.length));
    });
  });

  group('AppRole.isPlatformLevel', () {
    test('is true only for Admin', () {
      for (final role in AppRole.values) {
        expect(
          role.isPlatformLevel,
          role == AppRole.admin,
          reason: '$role isPlatformLevel should be '
              '${role == AppRole.admin}',
        );
      }
    });
  });

  group('AppRole capability getters for the new 4-role model', () {
    test('canCreateOrganization is granted to admin and siteManager only',
        () {
      expect(AppRole.admin.canCreateOrganization, isTrue);
      expect(AppRole.siteManager.canCreateOrganization, isTrue);
      expect(AppRole.foreman.canCreateOrganization, isFalse);
      expect(AppRole.worker.canCreateOrganization, isFalse);
    });

    test('canManageSafetyLearningLibrary is admin-only', () {
      for (final role in AppRole.values) {
        expect(
          role.canManageSafetyLearningLibrary,
          role == AppRole.admin,
        );
      }
    });

    test('canManageSafetyMeetingPointLibrary is admin-only', () {
      for (final role in AppRole.values) {
        expect(
          role.canManageSafetyMeetingPointLibrary,
          role == AppRole.admin,
        );
      }
    });

    test('canApproveForemen is granted to admin and siteManager only', () {
      expect(AppRole.admin.canApproveForemen, isTrue);
      expect(AppRole.siteManager.canApproveForemen, isTrue);
      expect(AppRole.foreman.canApproveForemen, isFalse);
      expect(AppRole.worker.canApproveForemen, isFalse);
    });

    test('canApproveWorkers is granted to admin, siteManager and foreman',
        () {
      expect(AppRole.admin.canApproveWorkers, isTrue);
      expect(AppRole.siteManager.canApproveWorkers, isTrue);
      expect(AppRole.foreman.canApproveWorkers, isTrue);
      expect(AppRole.worker.canApproveWorkers, isFalse);
    });

    test('canManageOrgContent is granted to admin and siteManager only', () {
      expect(AppRole.admin.canManageOrgContent, isTrue);
      expect(AppRole.siteManager.canManageOrgContent, isTrue);
      expect(AppRole.foreman.canManageOrgContent, isFalse);
      expect(AppRole.worker.canManageOrgContent, isFalse);
    });
  });

  test('AppRole has exactly four values', () {
    expect(AppRole.values, hasLength(4));
    expect(
      AppRole.values,
      containsAll(<AppRole>[
        AppRole.admin,
        AppRole.siteManager,
        AppRole.foreman,
        AppRole.worker,
      ]),
    );
  });
}
