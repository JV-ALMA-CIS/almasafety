import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/features/organizations/domain/organization_record_status.dart';

void main() {
  group('OrganizationRecordStatus.tryFromId', () {
    test('parses every known status by its stored id', () {
      for (final status in OrganizationRecordStatus.values) {
        expect(OrganizationRecordStatus.tryFromId(status.id), status);
      }
    });

    test('returns null for an unknown or null id', () {
      expect(OrganizationRecordStatus.tryFromId('archived'), isNull);
      expect(OrganizationRecordStatus.tryFromId(null), isNull);
      expect(OrganizationRecordStatus.tryFromId(''), isNull);
    });
  });

  group('OrganizationRecordStatus.label', () {
    test('every status has a distinct, human-readable label', () {
      final labels =
          OrganizationRecordStatus.values.map((s) => s.label).toSet();
      expect(labels, hasLength(OrganizationRecordStatus.values.length));
    });
  });
}
