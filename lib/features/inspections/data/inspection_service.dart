import 'dart:typed_data';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/storage_service.dart';
import '../../organizations/data/organization_admin_service.dart';
import '../domain/inspection.dart';

/// Client for `functions/src/inspection_callable.ts`, plus the photo upload
/// for a "Not OK" item (to the inspection's own Storage folder).
class InspectionService {
  InspectionService({
    FirebaseFunctions? functions,
    StorageService? storageService,
  }) : _injected = functions,
       _storageService = storageService ?? StorageService();

  final FirebaseFunctions? _injected;
  final StorageService _storageService;

  FirebaseFunctions _require() {
    final injected = _injected;
    if (injected != null) return injected;
    if (Firebase.apps.isEmpty) {
      throw const DataException(
        'Cannot reach the safety service right now. Please try again.',
      );
    }
    return FirebaseFunctions.instance;
  }

  /// Installs the standard templates (daily inspection, weekly walk-down);
  /// returns how many were added (0 when already installed).
  Future<int> installDefaultTemplates(String organizationId) async {
    final result = await _call<Map<Object?, Object?>>(
      'installDefaultInspectionTemplates',
      {'organizationId': organizationId},
    );
    return (result['added'] as num?)?.toInt() ?? 0;
  }

  /// Creates (no [templateId]) or updates a template; returns its id.
  Future<String> saveTemplate({
    required String organizationId,
    String? templateId,
    required String name,
    required InspectionKind kind,
    String? description,
    required List<TemplateSection> sections,
    bool active = true,
  }) async {
    final result = await _call<Map<Object?, Object?>>(
      'saveInspectionTemplate',
      {
        'organizationId': organizationId,
        'templateId': ?templateId,
        'name': name,
        'kind': kind.id,
        'description': ?description,
        'sections': [for (final section in sections) section.toJson()],
        'status': active ? 'active' : 'inactive',
      },
    );
    return result['id'] as String? ?? templateId ?? '';
  }

  /// Starts an inspection of [siteId] from [templateId]; returns its id.
  Future<String> start({
    required String organizationId,
    required String siteId,
    required String templateId,
  }) async {
    final result = await _call<Map<Object?, Object?>>('startInspection', {
      'organizationId': organizationId,
      'siteId': siteId,
      'templateId': templateId,
    });
    return result['id'] as String? ?? '';
  }

  /// Saves the answer to one item (null clears it).
  Future<void> recordItem({
    required String organizationId,
    required String inspectionId,
    required String itemId,
    required InspectionResult? result,
    String? note,
    String? photoUrl,
  }) => _call<Object?>('recordInspectionItem', {
    'organizationId': organizationId,
    'inspectionId': inspectionId,
    'itemId': itemId,
    'result': result?.id,
    'note': ?note,
    'photoUrl': ?photoUrl,
  });

  /// Submits the inspection; returns how many deficiencies were raised.
  Future<int> submit({
    required String organizationId,
    required String inspectionId,
  }) async {
    final result = await _call<Map<Object?, Object?>>('submitInspection', {
      'organizationId': organizationId,
      'inspectionId': inspectionId,
    });
    return (result['deficiencies'] as num?)?.toInt() ?? 0;
  }

  /// Signs off a submitted inspection (another Site Manager/Admin).
  Future<void> signOff({
    required String organizationId,
    required String inspectionId,
    String? note,
  }) => _call<Object?>('signOffInspection', {
    'organizationId': organizationId,
    'inspectionId': inspectionId,
    'note': ?note,
  });

  /// Uploads a photo for an item; returns its download URL.
  Future<String> uploadPhoto({
    required String organizationId,
    required String inspectionId,
    required String fileName,
    required Uint8List bytes,
  }) async {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    try {
      final ref = _storageService
          .orgRef(organizationId)
          .child('inspections/$inspectionId/${stamp}_$fileName');
      await ref.putData(bytes);
      return await ref.getDownloadURL();
    } on FirebaseException catch (e) {
      throw DataException(e.message ?? 'Failed to upload the photo.', cause: e);
    }
  }

  Future<T> _call<T>(String name, Map<String, Object?> data) async {
    try {
      final result = await _require().httpsCallable(name).call<T>(data);
      return result.data;
    } on FirebaseFunctionsException catch (e) {
      throw OrganizationAdminService.mapCallableError(e);
    }
  }
}
