import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/features/organizations/data/organization_repository.dart';

void main() {
  late FakeFirebaseFirestore firestore;
  late OrganizationRepository repository;

  setUp(() {
    firestore = FakeFirebaseFirestore();
    repository = OrganizationRepository(
      firestoreService: FirestoreService(firestore: firestore),
    );
  });

  Future<void> seedOrg(String id, {String status = 'active'}) async {
    await firestore.doc('organizations/$id').set({
      'name': 'Org $id',
      'code': 'CODE-$id',
      'status': status,
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  group('watchByIds', () {
    test('emits an empty list immediately for an empty id list', () async {
      final result = await repository.watchByIds(const []).first;
      expect(result, isEmpty);
    });

    test(
      'resolves every named organization, ignoring ones not requested',
      () async {
        await seedOrg('alpha');
        await seedOrg('beta');
        await seedOrg('gamma');

        final result = await repository.watchByIds(['alpha', 'beta']).first;
        final names = result.map((o) => o.name).toSet();

        expect(names, {'Org alpha', 'Org beta'});
      },
    );

    test('re-emits when one of the watched organizations changes', () async {
      await seedOrg('alpha');
      final stream = repository.watchByIds(['alpha']);

      final emissions = <List<String>>[];
      final subscription = stream.listen(
        (orgs) => emissions.add(orgs.map((o) => o.name).toList()),
      );

      await pumpEventQueue();
      await firestore.doc('organizations/alpha').update({'name': 'Renamed'});
      await pumpEventQueue();

      await subscription.cancel();

      expect(emissions.last, ['Renamed']);
    });

    test(
      'a document that does not exist is simply omitted, not an error',
      () async {
        await seedOrg('alpha');

        final result = await repository.watchByIds(['alpha', 'missing']).first;

        expect(result.map((o) => o.id), ['alpha']);
      },
    );
  });
}
