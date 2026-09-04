import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';

UserProfile _profile({
  AccountStatus accountStatus = AccountStatus.active,
  String? organizationId = 'org-1',
}) {
  final now = DateTime(2026, 1, 1);
  return UserProfile(
    uid: 'uid-1',
    organizationId: organizationId,
    name: 'Test User',
    email: 'test@example.com',
    phone: '+254700000000',
    accountStatus: accountStatus,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  group('SessionController.deriveStatus (missing profile)', () {
    test('no profile document -> profileMissing, never authenticated', () {
      final status = SessionController.deriveStatus(null);

      expect(status, AuthStatus.profileMissing);
      expect(status, isNot(AuthStatus.authenticated));
    });
  });

  group('SessionController.deriveStatus (approved user)', () {
    test('active profile -> authenticated', () {
      expect(
        SessionController.deriveStatus(
          _profile(accountStatus: AccountStatus.active),
        ),
        AuthStatus.authenticated,
      );
    });
  });

  group('SessionController.deriveStatus (unapproved users)', () {
    test('pending profile -> pending, not authenticated', () {
      final status = SessionController.deriveStatus(
        _profile(accountStatus: AccountStatus.pending, organizationId: null),
      );

      expect(status, AuthStatus.pending);
      expect(status, isNot(AuthStatus.authenticated));
    });

    test('suspended profile -> suspended, not authenticated', () {
      final status = SessionController.deriveStatus(
        _profile(accountStatus: AccountStatus.suspended),
      );

      expect(status, AuthStatus.suspended);
      expect(status, isNot(AuthStatus.authenticated));
    });

    test('rejected profile -> rejected, not authenticated', () {
      final status = SessionController.deriveStatus(
        _profile(accountStatus: AccountStatus.rejected, organizationId: null),
      );

      expect(status, AuthStatus.rejected);
      expect(status, isNot(AuthStatus.authenticated));
    });

    test('exactly one account status reaches authenticated', () {
      final authenticated = AccountStatus.values
          .where(
            (status) =>
                SessionController.deriveStatus(
                  _profile(accountStatus: status),
                ) ==
                AuthStatus.authenticated,
          )
          .toList();

      expect(authenticated, [AccountStatus.active]);
    });

    test('a pending user with no organization is still merely pending', () {
      // The absence of an organizationId must not be misread as a data
      // error — it is the expected shape of a freshly registered account.
      final status = SessionController.deriveStatus(
        _profile(accountStatus: AccountStatus.pending, organizationId: null),
      );

      expect(status, AuthStatus.pending);
      expect(status, isNot(AuthStatus.error));
      expect(status, isNot(AuthStatus.profileMissing));
    });
  });
}
