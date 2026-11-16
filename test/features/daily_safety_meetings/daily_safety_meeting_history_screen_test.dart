import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/daily_safety_meetings/data/daily_safety_meeting_repository.dart';
import 'package:jva_safety/features/daily_safety_meetings/data/meeting_concern_repository.dart';
import 'package:jva_safety/features/daily_safety_meetings/presentation/daily_safety_meeting_history_screen.dart';

class _Session extends SessionController {
  @override
  UserProfile? get profile => const UserProfile(
    uid: 'foreman-1',
    name: 'Fred',
    email: 'fred@example.com',
    accountStatus: AccountStatus.active,
  );
}

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() => firestore = FakeFirebaseFirestore());

  Future<void> seedMeeting(
    String id, {
    required String date,
    String status = 'completed',
    int? concernCount,
  }) {
    return firestore
        .doc('organizations/org-alpha/daily_safety_meetings/$id')
        .set({
          'organizationId': 'org-alpha',
          'projectId': 'project-1',
          'siteId': 'site-1',
          'date': date,
          'foremanId': 'foreman-1',
          'activityIds': ['a1'],
          'meetingPointIds': ['p1'],
          'status': status,
          // The legacy text list: never written any more, always empty.
          'concerns': <String>[],
          'concernCount': ?concernCount,
        });
  }

  Future<void> seedConcern(String meetingId, String id) {
    return firestore
        .doc(
          'organizations/org-alpha/daily_safety_meetings/$meetingId/'
          'concerns/$id',
        )
        .set({
          'meetingId': meetingId,
          'organizationId': 'org-alpha',
          'siteId': 'site-1',
          'description': 'Issue $id',
          'category': 'safety',
          'reportedBy': 'foreman-1',
          'status': 'open',
          'createdAt': Timestamp.now(),
        });
  }

  Widget wrap() => ChangeNotifierProvider<SessionController>(
    create: (_) => _Session(),
    child: MaterialApp(
      home: DailySafetyMeetingHistoryScreen(
        organizationId: 'org-alpha',
        repository: DailySafetyMeetingRepository(
          firestoreService: FirestoreService(firestore: firestore),
          organizationId: 'org-alpha',
        ),
        concernRepositoryBuilder: (meetingId) => MeetingConcernRepository(
          firestoreService: FirestoreService(firestore: firestore),
          organizationId: 'org-alpha',
          meetingId: meetingId,
        ),
      ),
    ),
  );

  testWidgets('shows the stored concern count, and counts an older '
      "meeting's concerns instead of showing 0", (tester) async {
    await seedMeeting('new', date: '2026-10-28', concernCount: 3);
    await seedMeeting('old', date: '2026-09-01');
    await seedConcern('old', 'c1');
    await seedConcern('old', 'c2');

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.textContaining('3 concerns'), findsOneWidget);
    expect(find.textContaining('2 concerns'), findsOneWidget);
    expect(find.textContaining('0 concerns'), findsNothing);
  });

  testWidgets('a completed meeting can be opened to view or print it', (
    tester,
  ) async {
    await seedMeeting('done', date: '2026-10-28');
    await seedMeeting('open', date: '2026-10-27', status: 'inProgress');

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.text('Tap to view or print this meeting.'), findsOneWidget);
    expect(
      find.text('Not yet completed — tap to finish this meeting.'),
      findsOneWidget,
    );
  });
}
