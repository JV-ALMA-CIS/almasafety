import 'dart:async';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/membership.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/organizations/domain/organization_record_status.dart';
import 'package:jva_safety/features/safety_learning/data/safety_learning_admin_service.dart';
import 'package:jva_safety/features/safety_learning/data/safety_learning_repository.dart';
import 'package:jva_safety/features/safety_learning/domain/safety_learning.dart';
import 'package:jva_safety/features/safety_learning/domain/safety_learning_type.dart';
import 'package:jva_safety/features/safety_learning/presentation/safety_learning_library_screen.dart';

const _org = 'org-alpha';
const _bucket = 'jva-test.firebasestorage.app';
const _jvaUrl =
    'https://firebasestorage.googleapis.com/v0/b/$_bucket/o/'
    'organizations%2Forg-alpha%2Fsafety_learning%2F1%2Fclip.mp4'
    '?alt=media&token=t';

/// A platform Admin (no membership), or a member of [_org] with [role].
class _Session extends SessionController {
  _Session(this.role);

  final AppRole role;

  @override
  UserProfile? get profile => UserProfile(
    uid: 'user-1',
    name: 'Test User',
    email: 'user@example.com',
    accountStatus: AccountStatus.active,
    platformRole: role == AppRole.admin ? AppRole.admin : null,
  );

  @override
  String? get activeOrganizationId => role == AppRole.admin ? null : _org;

  @override
  Membership? get activeMembership => role == AppRole.admin
      ? null
      : Membership(
          organizationId: _org,
          role: role,
          status: MembershipStatus.active,
        );
}

class _FakeAdminService extends SafetyLearningAdminService {
  final List<Map<String, Object?>> created = [];
  final List<Map<String, Object?>> updated = [];
  int createCalls = 0;

  /// Thrown by the next save, then cleared.
  Object? nextError;

  /// When set, a save waits for it.
  Completer<void>? pending;

  Future<void> _maybeFail() async {
    final wait = pending;
    if (wait != null) await wait.future;
    final error = nextError;
    nextError = null;
    if (error != null) throw error;
  }

  @override
  Future<String> createSafetyLearning({
    required String organizationId,
    required String title,
    required SafetyLearningType type,
    required String contentReference,
    String? description,
    OrganizationRecordStatus status = OrganizationRecordStatus.active,
    int? minimumWatchSeconds,
    int? passingScorePercent,
  }) async {
    createCalls++;
    await _maybeFail();
    created.add({
      'title': title,
      'type': type,
      'contentReference': contentReference,
    });
    return 'new-id';
  }

  @override
  Future<void> updateSafetyLearning(
    String organizationId,
    String id, {
    String? title,
    SafetyLearningType? type,
    String? contentReference,
    String? description,
    OrganizationRecordStatus? status,
    int? minimumWatchSeconds,
    int? passingScorePercent,
  }) async {
    await _maybeFail();
    updated.add({
      'id': id,
      'title': title,
      'contentReference': contentReference,
      'status': status,
    });
  }
}

void main() {
  late FakeFirebaseFirestore firestore;
  late _FakeAdminService adminService;

  setUp(() {
    firestore = FakeFirebaseFirestore();
    adminService = _FakeAdminService();
  });

  Future<void> seed(
    String id, {
    String type = 'video',
    String contentReference = 'https://cdn.example.org/clip.mp4',
  }) => firestore.doc('organizations/$_org/safety_learning/$id').set({
    'organizationId': _org,
    'title': 'Item $id',
    'type': type,
    'status': 'active',
    'contentReference': contentReference,
  });

  Future<void> pumpLibrary(
    WidgetTester tester, {
    AppRole role = AppRole.admin,
    SafetyLearningRepository? repository,
  }) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<SessionController>(
        create: (_) => _Session(role),
        child: MaterialApp(
          home: Scaffold(
            body: SafetyLearningLibraryScreen(
              organizationId: _org,
              repository:
                  repository ??
                  SafetyLearningRepository(
                    firestoreService: FirestoreService(firestore: firestore),
                    organizationId: _org,
                  ),
              adminService: adminService,
              storageBucket: _bucket,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> enterField(WidgetTester tester, String label, String text) =>
      tester.enterText(find.widgetWithText(TextFormField, label), text);

  /// Opens the library's own create form and chooses the Video type.
  Future<void> openNewVideoForm(WidgetTester tester) async {
    await pumpLibrary(tester);
    await tester.tap(find.text('New Learning Item'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Video'));
    await tester.pumpAndSettle();
  }

  group('creating', () {
    testWidgets('the create form defaults to Document, as before', (
      tester,
    ) async {
      await pumpLibrary(tester);
      await tester.tap(find.text('New Learning Item'));
      await tester.pumpAndSettle();
      expect(find.text('NEW LEARNING ITEM'), findsOneWidget);
      expect(find.text('Where is the video?'), findsNothing);
      expect(find.text('Content reference'), findsOneWidget);
    });

    testWidgets('choosing Video offers upload or external link', (
      tester,
    ) async {
      await openNewVideoForm(tester);
      expect(find.text('Upload a JVA video'), findsOneWidget);
      expect(find.text('Link to an external video'), findsOneWidget);
    });
  });

  group('external video links', () {
    Future<void> openLinkForm(WidgetTester tester) async {
      await openNewVideoForm(tester);
      await tester.tap(find.text('Link to an external video'));
      await tester.pumpAndSettle();
      await enterField(tester, 'Title', 'Ladder Safety');
    }

    testWidgets('rejects an ordinary web page', (tester) async {
      await openLinkForm(tester);
      await enterField(tester, 'Video link', 'https://example.org/ladders');
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Only YouTube, Vimeo'), findsOneWidget);
      expect(adminService.created, isEmpty);
    });

    testWidgets('rejects a non-https link', (tester) async {
      await openLinkForm(tester);
      await enterField(
        tester,
        'Video link',
        'http://www.youtube.com/watch?v=dQw4w9WgXcQ',
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(
        find.text('Enter a full link starting with https://'),
        findsOneWidget,
      );
      expect(adminService.created, isEmpty);
    });

    testWidgets('accepts YouTube, shows the source and the external warning', (
      tester,
    ) async {
      await openLinkForm(tester);
      await enterField(tester, 'Video link', 'https://youtu.be/dQw4w9WgXcQ');
      await tester.pumpAndSettle();
      expect(find.text('External · YouTube'), findsOneWidget);
      expect(find.text(externalVideoWarning), findsOneWidget);

      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(adminService.created, [
        {
          'title': 'Ladder Safety',
          'type': SafetyLearningType.video,
          'contentReference': 'https://youtu.be/dQw4w9WgXcQ',
        },
      ]);
    });

    testWidgets('accepts Vimeo and direct video files', (tester) async {
      await openLinkForm(tester);
      await enterField(tester, 'Video link', 'https://vimeo.com/76979871');
      await tester.pumpAndSettle();
      expect(find.text('External · Vimeo'), findsOneWidget);
      await enterField(
        tester,
        'Video link',
        'https://cdn.example.org/ladder.webm',
      );
      await tester.pumpAndSettle();
      expect(find.text('External · cdn.example.org'), findsOneWidget);
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(
        adminService.created.single['contentReference'],
        'https://cdn.example.org/ladder.webm',
      );
    });
  });

  group('JVA uploads', () {
    testWidgets('Create is refused until a video is uploaded', (tester) async {
      await openNewVideoForm(tester);
      await enterField(tester, 'Title', 'Ladder Safety');
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(find.text('Upload a video first.'), findsOneWidget);
      expect(
        find.text('Up to 25 MB. MP4 (H.264) plays on every phone.'),
        findsOneWidget,
      );
      expect(adminService.created, isEmpty);
    });

    testWidgets('editing a JVA video opens on Upload and shows its source', (
      tester,
    ) async {
      await seed('v1', contentReference: _jvaUrl);
      await pumpLibrary(tester);
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(find.text('Uploaded video'), findsOneWidget);
      expect(find.text('JVA video'), findsWidgets);
      expect(find.text(externalVideoWarning), findsNothing);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(adminService.updated.single['contentReference'], _jvaUrl);
    });

    testWidgets('editing an external video opens on Link', (tester) async {
      await seed('v1', contentReference: 'https://vimeo.com/76979871');
      await pumpLibrary(tester);
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(find.text('Video link'), findsOneWidget);
    });
  });

  group('older videos whose saved link no longer passes', () {
    const legacyLink = 'https://example.org/old-training-page';

    testWidgets('can be renamed and made inactive with the link unchanged', (
      tester,
    ) async {
      await seed('v1', contentReference: legacyLink);
      await pumpLibrary(tester);
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      // The admin can see why workers get "Video unavailable".
      expect(find.text('Link problem'), findsWidgets);

      await enterField(tester, 'Title', 'Old training (retired)');
      await tester.tap(find.text('Inactive'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(adminService.updated, hasLength(1));
      expect(adminService.updated.single['title'], 'Old training (retired)');
      expect(
        adminService.updated.single['status'],
        OrganizationRecordStatus.inactive,
      );
      expect(adminService.updated.single['contentReference'], legacyLink);
    });

    testWidgets('a NEW invalid link is still refused', (tester) async {
      await seed('v1', contentReference: legacyLink);
      await pumpLibrary(tester);
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await enterField(tester, 'Video link', 'https://example.org/other-page');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Only YouTube, Vimeo'), findsOneWidget);
      expect(adminService.updated, isEmpty);
    });

    testWidgets('changing a document to a video still checks its link', (
      tester,
    ) async {
      await seed('d1', type: 'document', contentReference: legacyLink);
      await pumpLibrary(tester);
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Video'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Only YouTube, Vimeo'), findsOneWidget);
      expect(adminService.updated, isEmpty);
    });
  });

  group('Site Manager', () {
    testWidgets('cannot open the full library (all learning types)', (
      tester,
    ) async {
      await seed('v1');
      await pumpLibrary(tester, role: AppRole.siteManager);
      expect(
        find.text('You do not have permission to manage safety learning.'),
        findsOneWidget,
      );
      expect(find.text('NEW LEARNING ITEM'), findsNothing);
      expect(find.text('Upload a JVA video'), findsNothing);
      expect(find.text('Edit'), findsNothing);
      expect(adminService.created, isEmpty);
    });
  });

  group('library cards', () {
    testWidgets('show each video\'s source, or Link problem', (tester) async {
      await seed('a', contentReference: _jvaUrl);
      await seed('b', contentReference: 'https://youtu.be/dQw4w9WgXcQ');
      await seed('c', contentReference: 'https://example.org/page');
      await seed(
        'd',
        type: 'document',
        contentReference: 'https://example.org/page',
      );
      await pumpLibrary(tester);
      expect(find.text('JVA video'), findsOneWidget);
      expect(find.text('External · YouTube'), findsOneWidget);
      expect(find.text('Link problem'), findsOneWidget);
      expect(find.textContaining('Only YouTube, Vimeo'), findsOneWidget);
    });
  });

  group('other learning types are unchanged', () {
    testWidgets('a document still accepts any content reference', (
      tester,
    ) async {
      await pumpLibrary(tester);
      await tester.tap(find.text('New Learning Item'));
      await tester.pumpAndSettle();
      await enterField(tester, 'Title', 'PPE Handbook');
      await enterField(
        tester,
        'Content reference',
        'https://example.org/handbook',
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(adminService.created.single['type'], SafetyLearningType.document);
    });
  });

  group('saving', () {
    Future<void> fillDocument(WidgetTester tester) async {
      await pumpLibrary(tester);
      await tester.tap(find.text('New Learning Item'));
      await tester.pumpAndSettle();
      await enterField(tester, 'Title', 'PPE Handbook');
      await enterField(tester, 'Content reference', 'https://example.org/h');
    }

    testWidgets('a failed save keeps the form open with its input and the '
        'reason; a retry then saves and closes it', (tester) async {
      await fillDocument(tester);
      adminService.nextError = const NetworkException(
        'No connection. Please try again.',
      );

      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(find.text('No connection. Please try again.'), findsOneWidget);
      expect(find.text('NEW LEARNING ITEM'), findsOneWidget);
      expect(find.text('PPE Handbook'), findsWidgets);
      expect(adminService.created, isEmpty);

      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(adminService.created, hasLength(1));
      expect(find.text('NEW LEARNING ITEM'), findsNothing);
    });

    testWidgets('an unexpected error is shown too, not swallowed', (
      tester,
    ) async {
      await fillDocument(tester);
      adminService.nextError = Exception('boom');
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not save'), findsOneWidget);
      expect(find.text('NEW LEARNING ITEM'), findsOneWidget);
    });

    testWidgets('tapping Create repeatedly while saving submits once, and '
        'back is blocked until the save finishes', (tester) async {
      await fillDocument(tester);
      adminService.pending = Completer<void>();

      await tester.tap(find.text('Create'));
      await tester.pump();
      // The button now shows progress and is disabled.
      expect(find.text('Create'), findsNothing);
      await tester.tap(find.byType(ElevatedButton).last, warnIfMissed: false);
      await tester.pump();
      final popped = await tester.binding.handlePopRoute();
      await tester.pump();
      expect(popped, isTrue);
      expect(find.text('NEW LEARNING ITEM'), findsOneWidget);

      adminService.pending!.complete();
      adminService.pending = null;
      await tester.pumpAndSettle();
      expect(adminService.createCalls, 1);
      expect(find.text('NEW LEARNING ITEM'), findsNothing);
    });

    testWidgets('Cancel with unsaved changes asks first; Keep editing keeps '
        'everything, Discard closes without saving', (tester) async {
      await fillDocument(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsOneWidget);

      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.text('NEW LEARNING ITEM'), findsOneWidget);
      expect(find.text('PPE Handbook'), findsWidgets);

      // The form's close (X) button goes through the same check.
      await tester.tap(find.byType(CloseButton));
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsOneWidget);
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(find.text('NEW LEARNING ITEM'), findsNothing);
      expect(adminService.createCalls, 0);
    });

    testWidgets('Cancel with no changes closes straight away', (tester) async {
      await pumpLibrary(tester);
      await tester.tap(find.text('New Learning Item'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsNothing);
      expect(find.text('NEW LEARNING ITEM'), findsNothing);
    });

    testWidgets('tapping New Learning Item twice opens one form', (
      tester,
    ) async {
      await pumpLibrary(tester);
      await tester.tap(find.text('New Learning Item'));
      await tester.tap(find.text('New Learning Item'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('NEW LEARNING ITEM'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('NEW LEARNING ITEM'), findsNothing);
      expect(find.text('New Learning Item'), findsOneWidget);
    });
  });

  group('loading', () {
    testWidgets('a failed load says so (not "no items") and Try again '
        'reloads', (tester) async {
      final repository = _FlakyRepository(
        FirestoreService(firestore: firestore),
      );
      await pumpLibrary(tester, repository: repository);
      expect(
        find.text('Could not load safety learning. Please try again.'),
        findsOneWidget,
      );
      expect(find.text('No safety learning items yet.'), findsNothing);

      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(repository.attempts, 2);
      expect(find.text('No safety learning items yet.'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
    });
  });
}

/// Fails the first load, then returns an empty library.
class _FlakyRepository extends SafetyLearningRepository {
  _FlakyRepository(FirestoreService service)
    : super(firestoreService: service, organizationId: _org);

  int attempts = 0;

  @override
  Stream<List<SafetyLearning>> watchAll() {
    attempts++;
    return attempts == 1
        ? Stream.error(Exception('offline'))
        : Stream.value(const []);
  }
}
