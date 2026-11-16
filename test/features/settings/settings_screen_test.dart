import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/core/offline/outbox.dart';
import 'package:jva_safety/core/services/auth_service.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/core/services/push_notification_service.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/core/services/theme_controller.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/membership.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/authentication/domain/worker_type.dart';
import 'package:jva_safety/features/organizations/data/site_repository.dart';
import 'package:jva_safety/features/settings/presentation/settings_screen.dart';

class _FakeSession extends SessionController {
  bool signOutCalled = false;

  @override
  UserProfile? get profile => const UserProfile(
    uid: 'uid-1',
    name: 'Amina Otieno',
    email: 'amina@example.com',
    accountStatus: AccountStatus.active,
  );

  @override
  Membership? get activeMembership => const Membership(
    organizationId: 'org-a',
    role: AppRole.foreman,
    status: MembershipStatus.active,
    workerType: WorkerType.jvaEmployee,
    trade: 'Scaffolding',
    siteIds: ['s1', 's2'],
  );

  @override
  String? get activeOrganizationId => 'org-a';

  @override
  Future<void> signOut() async => signOutCalled = true;
}

class _FakePush extends PushNotificationService {
  _FakePush(this.current);

  PushPermission current;
  int enables = 0;

  @override
  Future<PushPermission> permission() async => current;

  @override
  Future<PushPermission> enable() async {
    enables++;
    return current = PushPermission.allowed;
  }
}

class _FakeAuth extends AuthService {
  final List<String> resets = [];
  AppException? error;

  @override
  Future<void> sendPasswordResetEmail(String email) async {
    final failure = error;
    if (failure != null) throw failure;
    resets.add(email);
  }
}

class _FakeOutbox extends Outbox {
  _FakeOutbox({this.waitingCount = 0, this.failedCount = 0, this.online = true})
    : super(isOnline: () => true);

  int waitingCount;
  int failedCount;
  bool online;
  int flushes = 0;

  static final _entry = OutboxEntry(
    id: 'e1',
    uid: 'uid-1',
    callable: 'createHazard',
    data: const {},
    label: 'Hazard',
    createdAt: DateTime(2026, 10, 24),
  );

  @override
  List<OutboxEntry> get waiting => List.filled(waitingCount, _entry);

  @override
  List<OutboxEntry> get failed => List.filled(failedCount, _entry);

  @override
  bool get isOnline => online;

  @override
  Future<void> flush() async {
    flushes++;
    waitingCount = 0;
    notifyListeners();
  }
}

void main() {
  late _FakeSession session;
  late ThemeController theme;
  late _FakeAuth auth;

  Future<void> pump(
    WidgetTester tester, {
    PushPermission permission = PushPermission.allowed,
    _FakePush? push,
    bool isIosBrowser = false,
    double width = 400,
    _FakeOutbox? outbox,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = Size(width, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    session = _FakeSession();
    theme = ThemeController();
    auth = _FakeAuth();
    final firestore = FakeFirebaseFirestore();
    for (final (id, name) in [('s1', 'Rosslyn North'), ('s2', 'Gigiri')]) {
      await firestore.doc('organizations/org-a/sites/$id').set({
        'organizationId': 'org-a',
        'projectId': 'p1',
        'name': name,
        'code': id,
        'status': 'active',
      });
    }
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SessionController>.value(value: session),
          ChangeNotifierProvider<ThemeController>.value(value: theme),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(
            body: SettingsScreen(
              pushService: push ?? _FakePush(permission),
              isIosBrowser: isIosBrowser,
              authService: auth,
              outbox: outbox ?? _FakeOutbox(),
              siteRepository: SiteRepository(
                firestoreService: FirestoreService(firestore: firestore),
                organizationId: 'org-a',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows the account: name, email, role, work and sites', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Amina Otieno'), findsOneWidget);
    expect(find.text('amina@example.com'), findsOneWidget);
    expect(find.text(AppRole.foreman.label), findsOneWidget);
    expect(find.textContaining('Scaffolding'), findsOneWidget);
    expect(find.textContaining('Rosslyn North'), findsOneWidget);
    expect(find.textContaining('Gigiri'), findsOneWidget);
  });

  group('change password', () {
    testWidgets('asks first, then emails a link to the signed-in address', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.text('Change password'));
      await tester.pumpAndSettle();
      expect(find.textContaining('amina@example.com'), findsWidgets);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(auth.resets, isEmpty);

      await tester.tap(find.text('Change password'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send link'));
      await tester.pumpAndSettle();
      expect(auth.resets, ['amina@example.com']);
      expect(find.textContaining('Link sent to'), findsOneWidget);
    });

    testWidgets('a failure is shown, not hidden', (tester) async {
      await pump(tester);
      auth.error = const NetworkException('No connection.');
      await tester.tap(find.text('Change password'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send link'));
      await tester.pumpAndSettle();
      expect(find.text('No connection.'), findsOneWidget);
    });
  });

  testWidgets('appearance: choosing Dark changes the app theme', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(theme.mode, ThemeMode.dark);
  });

  testWidgets('text size: Large is remembered for this device', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Large'));
    await tester.pumpAndSettle();
    expect(theme.textSize, AppTextSize.large);
  });

  group('notifications', () {
    testWidgets('on: says so, no button', (tester) async {
      await pump(tester);
      expect(find.text('On for this device'), findsOneWidget);
      expect(find.text('Turn on notifications'), findsNothing);
    });

    testWidgets('off: Turn on asks the device and shows the answer', (
      tester,
    ) async {
      final push = _FakePush(PushPermission.notAsked);
      await pump(tester, push: push);
      expect(find.text('Off for this device'), findsOneWidget);
      await tester.tap(find.text('Turn on notifications'));
      await tester.pumpAndSettle();
      expect(push.enables, 1);
      expect(find.text('On for this device'), findsOneWidget);
    });

    testWidgets('blocked: explains how to allow them', (tester) async {
      await pump(tester, permission: PushPermission.blocked);
      expect(find.text('Blocked for this device'), findsOneWidget);
      expect(find.text('Turn on notifications'), findsNothing);
    });

    testWidgets('iPhone browser: the Home Screen tip', (tester) async {
      await pump(
        tester,
        permission: PushPermission.unsupported,
        isIosBrowser: true,
      );
      expect(find.textContaining('Add to Home Screen'), findsOneWidget);
    });
  });

  group('saved on this phone', () {
    testWidgets('nothing waiting: everything is sent', (tester) async {
      await pump(tester);
      expect(find.text('Everything is sent'), findsOneWidget);
      expect(find.text('Send now'), findsNothing);
    });

    testWidgets('waiting with signal: Send now sends them', (tester) async {
      final outbox = _FakeOutbox(waitingCount: 2);
      await pump(tester, outbox: outbox);
      expect(find.text('2 entries waiting to send'), findsOneWidget);
      await tester.tap(find.text('Send now'));
      await tester.pumpAndSettle();
      expect(outbox.flushes, 1);
      expect(find.text('Everything is sent'), findsOneWidget);
    });

    testWidgets('no signal: no button, they send by themselves later', (
      tester,
    ) async {
      await pump(tester, outbox: _FakeOutbox(waitingCount: 1, online: false));
      expect(find.text('1 entry waiting to send'), findsOneWidget);
      expect(find.text('Send now'), findsNothing);
      expect(find.textContaining('when the signal comes back'), findsOneWidget);
    });

    testWidgets('failed entries point to the strip that explains why', (
      tester,
    ) async {
      await pump(tester, outbox: _FakeOutbox(failedCount: 1));
      expect(find.text('1 entry could not be sent'), findsOneWidget);
      expect(find.textContaining('red strip'), findsOneWidget);
    });
  });

  testWidgets('Sign Out asks first; Cancel keeps the session', (tester) async {
    await pump(tester);
    final button = find.widgetWithText(OutlinedButton, 'Sign Out');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('Sign out?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(session.signOutCalled, isFalse);

    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Sign Out'));
    await tester.pumpAndSettle();
    expect(session.signOutCalled, isTrue);
  });

  for (final width in [320.0, 360.0]) {
    for (final size in AppTextSize.values) {
      testWidgets('fits a ${width.toInt()}px phone with ${size.label} text', (
        tester,
      ) async {
        await pump(
          tester,
          width: width,
          permission: PushPermission.notAsked,
          outbox: _FakeOutbox(waitingCount: 3, failedCount: 1),
          textScale: size.factor,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
}
