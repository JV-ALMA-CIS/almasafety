/// What completing a corrective action can require as evidence — matching
/// `functions/src/corrective_action_callable.ts`'s `EVIDENCE_KINDS`. Chosen
/// by whoever creates the action; enforced server-side when the assignee
/// submits.
enum CorrectiveActionEvidenceKind {
  /// One or more photos of the finished work.
  photo,

  /// A written confirmation of what was done (e.g. "guard rail fitted and
  /// inspected").
  confirmation;

  /// The value stored in Firestore.
  String get id => name;

  String get label => switch (this) {
    CorrectiveActionEvidenceKind.photo => 'Photo of the finished work',
    CorrectiveActionEvidenceKind.confirmation => 'Written confirmation',
  };

  String get hint => switch (this) {
    CorrectiveActionEvidenceKind.photo => 'At least one photo must be attached',
    CorrectiveActionEvidenceKind.confirmation =>
      'e.g. "Guard rail fitted and inspected"',
  };

  static CorrectiveActionEvidenceKind? tryFromId(String? id) {
    for (final kind in values) {
      if (kind.id == id) return kind;
    }
    return null;
  }
}

/// One evidence photo the assignee attached when submitting their work.
class EvidencePhoto {
  const EvidencePhoto({required this.storagePath, required this.downloadUrl});

  final String storagePath;
  final String downloadUrl;

  Map<String, String> toJson() => {
    'storagePath': storagePath,
    'downloadUrl': downloadUrl,
  };

  static EvidencePhoto? tryFromMap(Object? value) {
    if (value is! Map) return null;
    final path = value['storagePath'];
    final url = value['downloadUrl'];
    if (path is! String || url is! String || url.isEmpty) return null;
    return EvidencePhoto(storagePath: path, downloadUrl: url);
  }
}
