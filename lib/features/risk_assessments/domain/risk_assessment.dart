import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/errors/app_exception.dart';

/// `draft → accepted → superseded` — see
/// `functions/src/risk_assessment_callable.ts`.
enum RiskAssessmentStatus {
  draft,
  accepted,
  superseded;

  String get id => name;

  String get label => switch (this) {
    RiskAssessmentStatus.draft => 'Draft — not yet accepted',
    RiskAssessmentStatus.accepted => 'Accepted — in use',
    RiskAssessmentStatus.superseded => 'Replaced by a newer revision',
  };

  static RiskAssessmentStatus? tryFromId(String? id) {
    for (final value in values) {
      if (value.id == id) return value;
    }
    return null;
  }
}

/// One principal step of the work, with its hazards and the controls for
/// them.
class AhaStep {
  const AhaStep({
    this.id,
    required this.step,
    this.hazards = const [],
    this.controls = const [],
  });

  /// Null for a step not yet saved.
  final String? id;
  final String step;
  final List<String> hazards;
  final List<String> controls;

  bool get isComplete => hazards.isNotEmpty && controls.isNotEmpty;

  Map<String, Object?> toJson() => {
    'id': ?id,
    'step': step,
    'hazards': hazards,
    'controls': controls,
  };

  factory AhaStep.fromMap(Map<String, dynamic> data) => AhaStep(
    id: data['id'] as String?,
    step: data['step'] as String? ?? '',
    hazards: _strings(data['hazards']),
    controls: _strings(data['controls']),
  );
}

List<String> _strings(Object? raw) =>
    (raw as List<dynamic>?)?.whereType<String>().toList() ?? const [];

/// The editable content of an AHA form — what [RiskAssessment] holds apart
/// from its site, status and sign-offs. Also the shape of the standard
/// drafts (`standard_ahas.dart`).
class AhaContent {
  const AhaContent({
    required this.featureOfWork,
    this.activity,
    this.contractNo,
    this.location,
    this.estimatedStartDate,
    this.steps = const [],
    this.equipment = const [],
    this.inspectionRequirements = const [],
    this.trainingRequirements = const [],
  });

  final String featureOfWork;
  final String? activity;
  final String? contractNo;
  final String? location;

  /// `yyyy-MM-dd`.
  final String? estimatedStartDate;
  final List<AhaStep> steps;
  final List<String> equipment;
  final List<String> inspectionRequirements;
  final List<String> trainingRequirements;

  int get hazardCount =>
      steps.fold(0, (total, step) => total + step.hazards.length);

  /// What is still missing before it can be accepted (the server checks the
  /// same).
  List<String> get missingForAcceptance => [
    if (steps.isEmpty) 'the principal steps',
    for (var i = 0; i < steps.length; i++)
      if (!steps[i].isComplete) 'a hazard and a control for step ${i + 1}',
    if (equipment.isEmpty) 'the equipment',
    if (inspectionRequirements.isEmpty) 'the inspection requirements',
    if (trainingRequirements.isEmpty) 'the training requirements',
  ];
}

/// An Activity Hazard Analysis (the Safety Plan's risk assessment for one
/// phase / feature of work), stored at
/// `organizations/{organizationId}/risk_assessments/{id}`. Read-only
/// client-side; written by the `risk_assessment_callable.ts` callables.
class RiskAssessment extends AhaContent {
  const RiskAssessment({
    required this.id,
    required this.organizationId,
    required this.siteId,
    required this.status,
    required super.featureOfWork,
    super.activity,
    super.contractNo,
    super.location,
    super.estimatedStartDate,
    super.steps,
    super.equipment,
    super.inspectionRequirements,
    super.trainingRequirements,
    this.siteName,
    this.revision = 1,
    this.previousId,
    this.revisionDraftId,
    this.preparedByUid,
    this.preparedByName,
    this.acceptedByUid,
    this.acceptedByName,
    this.acceptedAt,
    this.corName,
    this.acceptanceNote,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String organizationId;
  final String siteId;
  final String? siteName;
  final RiskAssessmentStatus status;
  final int revision;

  /// The revision this one replaces, if any.
  final String? previousId;

  /// The draft revision being prepared from this accepted AHA, if any.
  final String? revisionDraftId;
  final String? preparedByUid;
  final String? preparedByName;
  final String? acceptedByUid;
  final String? acceptedByName;
  final DateTime? acceptedAt;

  /// The client's Contracting Officer's Representative who reviewed it,
  /// if noted.
  final String? corName;
  final String? acceptanceNote;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory RiskAssessment.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    if (data == null) {
      throw const DataException('That risk assessment could not be loaded.');
    }
    return RiskAssessment.fromMap(doc.id, data);
  }

  factory RiskAssessment.fromMap(String id, Map<String, dynamic> data) {
    final status = RiskAssessmentStatus.tryFromId(data['status'] as String?);
    if (status == null) {
      throw const DataException(
        'That risk assessment has an unrecognised status.',
      );
    }
    return RiskAssessment(
      id: id,
      organizationId: data['organizationId'] as String? ?? '',
      siteId: data['siteId'] as String? ?? '',
      siteName: data['siteName'] as String?,
      status: status,
      featureOfWork: data['featureOfWork'] as String? ?? '',
      activity: data['activity'] as String?,
      contractNo: data['contractNo'] as String?,
      location: data['location'] as String?,
      estimatedStartDate: data['estimatedStartDate'] as String?,
      steps: [
        for (final raw in (data['steps'] as List<dynamic>?) ?? const [])
          if (raw is Map) AhaStep.fromMap(Map<String, dynamic>.from(raw)),
      ],
      equipment: _strings(data['equipment']),
      inspectionRequirements: _strings(data['inspectionRequirements']),
      trainingRequirements: _strings(data['trainingRequirements']),
      revision: (data['revision'] as num?)?.toInt() ?? 1,
      previousId: data['previousId'] as String?,
      revisionDraftId: data['revisionDraftId'] as String?,
      preparedByUid: data['preparedByUid'] as String?,
      preparedByName: data['preparedByName'] as String?,
      acceptedByUid: data['acceptedByUid'] as String?,
      acceptedByName: data['acceptedByName'] as String?,
      acceptedAt: (data['acceptedAt'] as Timestamp?)?.toDate(),
      corName: data['corName'] as String?,
      acceptanceNote: data['acceptanceNote'] as String?,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
    );
  }
}
