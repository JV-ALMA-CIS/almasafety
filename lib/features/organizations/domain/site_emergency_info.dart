import 'package:cloud_firestore/cloud_firestore.dart';

/// One labelled emergency number, e.g. "Fire brigade: 999".
class EmergencyNumber {
  const EmergencyNumber({required this.label, required this.number});

  final String label;
  final String number;

  Map<String, Object?> toJson() => {'label': label, 'number': number};
}

/// A site's emergency contacts — the Safety Plan's Section 9: the medical
/// facility's name, address and numbers, an ambulance and other emergency
/// numbers, where the first-aid kit is, who the first-aiders are, and the
/// assembly point. Stored on the site (`emergency`) by
/// `functions/src/site_emergency_callable.ts`; different for every site.
class SiteEmergencyInfo {
  const SiteEmergencyInfo({
    this.clinicName,
    this.clinicAddress,
    this.clinicPhones = const [],
    this.ambulancePhone,
    this.otherNumbers = const [],
    this.assemblyPoint,
    this.firstAidKitLocation,
    this.firstAiders = const [],
    this.notes,
    this.updatedAt,
    this.updatedByName,
  });

  final String? clinicName;
  final String? clinicAddress;
  final List<String> clinicPhones;
  final String? ambulancePhone;
  final List<EmergencyNumber> otherNumbers;
  final String? assemblyPoint;
  final String? firstAidKitLocation;
  final List<String> firstAiders;
  final String? notes;
  final DateTime? updatedAt;
  final String? updatedByName;

  /// Nothing has been filled in.
  bool get isEmpty =>
      clinicName == null &&
      clinicAddress == null &&
      clinicPhones.isEmpty &&
      ambulancePhone == null &&
      otherNumbers.isEmpty &&
      assemblyPoint == null &&
      firstAidKitLocation == null &&
      firstAiders.isEmpty &&
      notes == null;

  /// Every number to call, most urgent first.
  List<EmergencyNumber> get callList => [
    if (ambulancePhone != null)
      EmergencyNumber(label: 'Ambulance', number: ambulancePhone!),
    for (final phone in clinicPhones)
      EmergencyNumber(label: clinicName ?? 'Clinic', number: phone),
    ...otherNumbers,
  ];

  Map<String, Object?> toJson() => {
    'clinicName': clinicName,
    'clinicAddress': clinicAddress,
    'clinicPhones': clinicPhones,
    'ambulancePhone': ambulancePhone,
    'otherNumbers': [for (final n in otherNumbers) n.toJson()],
    'assemblyPoint': assemblyPoint,
    'firstAidKitLocation': firstAidKitLocation,
    'firstAiders': firstAiders,
    'notes': notes,
  };

  static SiteEmergencyInfo? fromMap(Object? raw) {
    if (raw is! Map) return null;
    List<String> strings(Object? value) =>
        (value as List?)?.whereType<String>().toList() ?? const [];
    final info = SiteEmergencyInfo(
      clinicName: raw['clinicName'] as String?,
      clinicAddress: raw['clinicAddress'] as String?,
      clinicPhones: strings(raw['clinicPhones']),
      ambulancePhone: raw['ambulancePhone'] as String?,
      otherNumbers: [
        for (final n in (raw['otherNumbers'] as List?) ?? const [])
          if (n is Map && n['number'] is String)
            EmergencyNumber(
              label: n['label'] as String? ?? 'Emergency',
              number: n['number'] as String,
            ),
      ],
      assemblyPoint: raw['assemblyPoint'] as String?,
      firstAidKitLocation: raw['firstAidKitLocation'] as String?,
      firstAiders: strings(raw['firstAiders']),
      notes: raw['notes'] as String?,
      updatedAt: (raw['updatedAt'] as Timestamp?)?.toDate(),
      updatedByName: raw['updatedByName'] as String?,
    );
    return info.isEmpty ? null : info;
  }
}
