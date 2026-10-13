import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/features/safety_requirements/domain/safety_requirement.dart';
import 'package:jva_safety/features/safety_requirements/domain/safety_requirement_risk.dart';

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<DocumentSnapshot<Map<String, dynamic>>> seed(
    Map<String, dynamic> data,
  ) async {
    final ref = firestore.doc('organizations/org-alpha/safety_requirements/r1');
    await ref.set(data);
    return ref.get();
  }

  test('fromFirestore parses every field', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'name': 'Working at Height',
      'description': 'Applies to any work above 1.8m.',
      'category': 'Fall Protection',
      'risk': 'high',
      'requiredLearningIds': ['l1', 'l2'],
      'status': 'active',
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
      'createdBy': 'admin-1',
      'updatedBy': 'admin-1',
    });

    final requirement = SafetyRequirement.fromFirestore(doc);

    expect(requirement.id, 'r1');
    expect(requirement.organizationId, 'org-alpha');
    expect(requirement.name, 'Working at Height');
    expect(requirement.description, 'Applies to any work above 1.8m.');
    expect(requirement.category, 'Fall Protection');
    expect(requirement.risk, SafetyRequirementRisk.high);
    expect(requirement.requiredLearningIds, ['l1', 'l2']);
    expect(requirement.status.id, 'active');
  });

  test('fromFirestore defaults gatesAttendance to true when absent '
      '(legacy document, written before this field existed)', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'name': 'Working at Height',
      'category': 'Fall Protection',
      'risk': 'high',
      'status': 'active',
      // No gatesAttendance key at all.
    });

    final requirement = SafetyRequirement.fromFirestore(doc);

    expect(requirement.gatesAttendance, isTrue);
  });

  test('fromFirestore parses gatesAttendance: false', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'name': 'Working at Height',
      'category': 'Fall Protection',
      'risk': 'high',
      'status': 'active',
      'gatesAttendance': false,
    });

    final requirement = SafetyRequirement.fromFirestore(doc);

    expect(requirement.gatesAttendance, isFalse);
  });

  test('fromFirestore parses gatesAttendance: true explicitly', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'name': 'Working at Height',
      'category': 'Fall Protection',
      'risk': 'high',
      'status': 'active',
      'gatesAttendance': true,
    });

    final requirement = SafetyRequirement.fromFirestore(doc);

    expect(requirement.gatesAttendance, isTrue);
  });

  test('fromFirestore defaults requiredBeforeWork to false when absent '
      '(legacy document), independently of gatesAttendance', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'name': 'Working at Height',
      'category': 'Fall Protection',
      'risk': 'high',
      'status': 'active',
      // Neither flag present.
    });

    final requirement = SafetyRequirement.fromFirestore(doc);

    expect(requirement.requiredBeforeWork, isFalse);
    expect(requirement.gatesAttendance, isTrue);
  });

  test('fromFirestore parses requiredBeforeWork: true without affecting '
      'gatesAttendance', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'name': 'Working at Height',
      'category': 'Fall Protection',
      'risk': 'high',
      'status': 'active',
      'requiredBeforeWork': true,
      'gatesAttendance': false,
    });

    final requirement = SafetyRequirement.fromFirestore(doc);

    expect(requirement.requiredBeforeWork, isTrue);
    expect(requirement.gatesAttendance, isFalse);
  });

  test('fromFirestore parses requiredBeforeWork: false explicitly', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'name': 'Working at Height',
      'category': 'Fall Protection',
      'risk': 'high',
      'status': 'active',
      'requiredBeforeWork': false,
    });

    final requirement = SafetyRequirement.fromFirestore(doc);

    expect(requirement.requiredBeforeWork, isFalse);
  });

  test('fromFirestore parses a project scope', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'name': 'Working at Height',
      'category': 'Fall Protection',
      'risk': 'high',
      'status': 'active',
      'projectId': 'project-1',
    });

    final requirement = SafetyRequirement.fromFirestore(doc);

    expect(requirement.projectId, 'project-1');
    expect(requirement.siteId, isNull);
    expect(requirement.activityId, isNull);
  });

  test('requiredLearningIds defaults to empty when absent', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'name': 'Basic Housekeeping',
      'category': 'General',
      'risk': 'low',
      'status': 'active',
    });

    final requirement = SafetyRequirement.fromFirestore(doc);

    expect(requirement.requiredLearningIds, isEmpty);
  });

  test('throws when organizationId is missing', () async {
    final doc = await seed({
      'name': 'Working at Height',
      'category': 'Fall Protection',
      'risk': 'high',
      'status': 'active',
    });

    expect(
      () => SafetyRequirement.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('throws on an unrecognised status', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'name': 'Working at Height',
      'category': 'Fall Protection',
      'risk': 'high',
      'status': 'archived',
    });

    expect(
      () => SafetyRequirement.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('throws on an unrecognised risk level', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'name': 'Working at Height',
      'category': 'Fall Protection',
      'risk': 'extreme',
      'status': 'active',
    });

    expect(
      () => SafetyRequirement.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('every SafetyRequirementRisk round-trips through its stored id', () {
    for (final risk in SafetyRequirementRisk.values) {
      expect(SafetyRequirementRisk.tryFromId(risk.id), risk);
    }
    expect(SafetyRequirementRisk.tryFromId('unknown'), isNull);
    expect(SafetyRequirementRisk.tryFromId(null), isNull);
  });

  group('learningSettings (per-lesson)', () {
    Map<String, dynamic> base(Map<String, dynamic> extra) => {
      'organizationId': 'org-alpha',
      'name': 'Working at Height',
      'category': 'Height',
      'risk': 'high',
      'status': 'active',
      'requiredLearningIds': ['l1', 'l2', 'l3'],
      ...extra,
    };

    test('an older requirement has no map and every lesson inherits the '
        'requirement-level flags', () async {
      final requirement = SafetyRequirement.fromFirestore(
        await seed(base({'requiredBeforeWork': true})),
      );

      expect(requirement.learningSettings, isEmpty);
      expect(requirement.gatesAttendanceFor('l1'), isTrue);
      expect(requirement.requiredBeforeWorkFor('l2'), isTrue);
    });

    test('parses per-lesson entries, which win over the requirement-level '
        'flags', () async {
      final requirement = SafetyRequirement.fromFirestore(
        await seed(
          base({
            'gatesAttendance': true,
            'requiredBeforeWork': true,
            'learningSettings': {
              'l1': {'gatesAttendance': true, 'requiredBeforeWork': false},
              'l2': {'gatesAttendance': false, 'requiredBeforeWork': true},
              'l3': {'gatesAttendance': false, 'requiredBeforeWork': false},
            },
          }),
        ),
      );

      expect(requirement.learningSettings.keys, ['l1', 'l2', 'l3']);
      expect(
        [
          for (final id in ['l1', 'l2', 'l3'])
            requirement.gatesAttendanceFor(id),
        ],
        [true, false, false],
      );
      expect(
        [
          for (final id in ['l1', 'l2', 'l3'])
            requirement.requiredBeforeWorkFor(id),
        ],
        [false, true, false],
      );
    });

    test(
      'a missing lesson or malformed entry falls back per field; a '
      'malformed map is ignored rather than failing the requirement',
      () async {
        final partial = SafetyRequirement.fromFirestore(
          await seed(
            base({
              'gatesAttendance': true,
              'learningSettings': {
                'l1': {'gatesAttendance': false, 'requiredBeforeWork': 'yes'},
                'l2': 'not a map',
              },
            }),
          ),
        );
        expect(partial.gatesAttendanceFor('l1'), isFalse);
        expect(partial.requiredBeforeWorkFor('l1'), isFalse);
        expect(partial.gatesAttendanceFor('l2'), isTrue);
        expect(partial.gatesAttendanceFor('l3'), isTrue);

        final malformed = SafetyRequirement.fromFirestore(
          await seed(
            base({
              'learningSettings': ['l1'],
            }),
          ),
        );
        expect(malformed.learningSettings, isEmpty);
      },
    );

    test('toMap serializes both flags, filling unset ones', () {
      const setting = RequirementLearningSetting(gatesAttendance: true);

      expect(
        setting.toMap(
          gatesAttendanceFallback: false,
          requiredBeforeWorkFallback: false,
        ),
        {'gatesAttendance': true, 'requiredBeforeWork': false},
      );
    });
  });
}
