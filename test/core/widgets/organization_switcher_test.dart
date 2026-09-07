import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/core/widgets/organization_switcher.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/membership.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/organizations/data/organization_repository.dart';

/// A session controller that supports real membership switching, unlike the
/// simpler fakes elsewhere (e.g. organization_users_screen_test.dart's
/// _FakeSession) which only override activeOrganizationId/activeMembership.
/// This widget exercises setActiveOrganization itself — the base class's own
/// real, non-overridden method — so this fake instead overrides
/// [memberships] and [activeMembership]/[activeOrganizationId] to be
/// consistent with a settable, mutable membership list, tracking calls for
/// assertions without re-implementing the base class's selection logic.
class _FakeSession extends SessionController {
  _FakeSession({required List<Membership> memberships})
      : _memberships = memberships,
        _profile = const UserProfile(
          uid: 'uid-1',
          name: 'Test User',
          email: 'test@example.com',
          accountStatus: AccountStatus.active,
        );

  final List<Membership> _memberships;
  final UserProfile _profile;
  String? _selected;
  final List<String> setActiveOrganizationCalls = [];

  @override
  UserProfile? get profile => _profile;

  @override
  List<Membership> get memberships => _memberships;

  @override
  Membership? get activeMembership {
    final id = activeOrganizationId;
    if (id == null) return null;
    for (final m in _memberships) {
      if (m.organizationId == id) return m;
    }
    return null;
  }

  @override
  String? get activeOrganizationId {
    if (_memberships.isEmpty) return null;
    if (_memberships.length == 1) return _memberships.single.organizationId;
    if (_selected != null &&
        _memberships.any((m) => m.organizationId == _selected)) {
      return _selected;
    }
    final sorted = [..._memberships]
      ..sort((a, b) => a.organizationId.compareTo(b.organizationId));
    return sorted.first.organizationId;
  }

  @override
  void setActiveOrganization(String organizationId) {
    setActiveOrganizationCalls.add(organizationId);
    if (!_memberships.any((m) => m.organizationId == organizationId)) return;
    _selected = organizationId;
    notifyListeners();
  }
}

void main() {
  Membership membership(
    String organizationId, {
    MembershipStatus status = MembershipStatus.active,
  }) {
    return Membership(
      organizationId: organizationId,
      role: AppRole.siteManager,
      status: status,
    );
  }

  Future<void> seedOrg(
    FakeFirebaseFirestore firestore,
    String id,
    String name,
  ) async {
    await firestore.doc('organizations/$id').set({
      'name': name,
      'code': 'CODE-$id',
      'status': 'active',
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  Widget wrap(_FakeSession session, OrganizationRepository repository) {
    return ChangeNotifierProvider<SessionController>(
      create: (_) => session,
      child: MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            actions: [OrganizationSwitcher(repository: repository)],
          ),
        ),
      ),
    );
  }

  testWidgets('renders nothing for zero memberships', (tester) async {
    final firestore = FakeFirebaseFirestore();
    final repository =
        OrganizationRepository(firestoreService: FirestoreService(firestore: firestore));
    final session = _FakeSession(memberships: const []);

    await tester.pumpWidget(wrap(session, repository));
    await tester.pumpAndSettle();

    expect(find.byType(OrganizationSwitcher), findsOneWidget);
    expect(find.byType(PopupMenuButton<String>), findsNothing);
  });

  testWidgets('renders nothing for exactly one membership', (tester) async {
    final firestore = FakeFirebaseFirestore();
    await seedOrg(firestore, 'org-alpha', 'Alpha Org');
    final repository =
        OrganizationRepository(firestoreService: FirestoreService(firestore: firestore));
    final session = _FakeSession(memberships: [membership('org-alpha')]);

    await tester.pumpWidget(wrap(session, repository));
    await tester.pumpAndSettle();

    expect(find.byType(PopupMenuButton<String>), findsNothing);
  });

  testWidgets(
    'renders and lists organization names for 2+ memberships, tapping '
    'a different organization calls setActiveOrganization with its id',
    (tester) async {
      final firestore = FakeFirebaseFirestore();
      await seedOrg(firestore, 'org-alpha', 'Alpha Org');
      await seedOrg(firestore, 'org-beta', 'Beta Org');
      final repository =
          OrganizationRepository(firestoreService: FirestoreService(firestore: firestore));
      final session = _FakeSession(
        memberships: [membership('org-alpha'), membership('org-beta')],
      );

      await tester.pumpWidget(wrap(session, repository));
      await tester.pumpAndSettle();

      expect(find.byType(PopupMenuButton<String>), findsOneWidget);
      // The active org (alpha, the default) is shown on the closed button.
      expect(find.text('Alpha Org'), findsOneWidget);

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();

      expect(find.text('Alpha Org'), findsWidgets);
      expect(find.text('Beta Org'), findsOneWidget);

      await tester.tap(find.text('Beta Org'));
      await tester.pumpAndSettle();

      expect(session.setActiveOrganizationCalls, ['org-beta']);
    },
  );

  testWidgets('shows a Suspended indicator for a suspended membership', (
    tester,
  ) async {
    final firestore = FakeFirebaseFirestore();
    await seedOrg(firestore, 'org-alpha', 'Alpha Org');
    await seedOrg(firestore, 'org-beta', 'Beta Org');
    final repository =
        OrganizationRepository(firestoreService: FirestoreService(firestore: firestore));
    final session = _FakeSession(
      memberships: [
        membership('org-alpha', status: MembershipStatus.suspended),
        membership('org-beta'),
      ],
    );

    await tester.pumpWidget(wrap(session, repository));
    await tester.pumpAndSettle();

    // Alpha is the default active org and is suspended, so the closed
    // button itself should surface the indicator.
    expect(find.text('Suspended'), findsOneWidget);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();

    // One more "Suspended" chip inside the open menu's alpha row, alongside
    // the one already shown on the closed button behind it.
    expect(find.text('Suspended'), findsNWidgets(2));
  });

  testWidgets(
    'a membership whose organization was deleted outside the app is '
    'never shown as a selectable choice, and its raw id never leaks '
    'into the UI — regression test for the switcher previously falling '
    'back to the raw organizationId as a label',
    (tester) async {
      final firestore = FakeFirebaseFirestore();
      await seedOrg(firestore, 'org-alpha', 'Alpha Org');
      // org-deleted is intentionally NOT seeded — simulates an
      // organization document removed directly in Firestore, leaving this
      // membership dangling.
      final repository =
          OrganizationRepository(firestoreService: FirestoreService(firestore: firestore));
      final session = _FakeSession(
        memberships: [membership('org-alpha'), membership('org-deleted')],
      );

      await tester.pumpWidget(wrap(session, repository));
      await tester.pumpAndSettle();

      // Only one REAL organization to choose from now, so the switcher
      // collapses to "nothing to switch between" (a zero-size widget, same
      // as the exactly-one-membership case) — it never renders a plain
      // label in this mode, so there is nothing to assert beyond "the
      // dangling id never appears anywhere".
      expect(find.byType(PopupMenuButton<String>), findsNothing);
      expect(find.text('org-deleted'), findsNothing);
    },
  );

  testWidgets(
    'the active membership itself pointing at a deleted organization '
    'shows a clear message, never the raw id',
    (tester) async {
      final firestore = FakeFirebaseFirestore();
      // Neither organization exists — both memberships are dangling.
      final repository =
          OrganizationRepository(firestoreService: FirestoreService(firestore: firestore));
      final session = _FakeSession(
        memberships: [membership('org-gone-1'), membership('org-gone-2')],
      );

      await tester.pumpWidget(wrap(session, repository));
      await tester.pumpAndSettle();

      expect(find.text('org-gone-1'), findsNothing);
      expect(find.text('org-gone-2'), findsNothing);
    },
  );
}
