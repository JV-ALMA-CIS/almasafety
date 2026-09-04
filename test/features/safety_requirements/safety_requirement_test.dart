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
    final ref =
        firestore.doc('organizations/org-alpha/safety_requirements/r1');
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
}
