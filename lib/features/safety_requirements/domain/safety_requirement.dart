import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/errors/app_exception.dart';
import '../../organizations/domain/organization_record_status.dart';
import 'safety_requirement_risk.dart';

/// A safety requirement, stored at
/// `organizations/{organizationId}/safety_requirements/{id}` — a flat
/// sibling of `safety_learning`, matching [Activity]'s doc comment's shape.
///
/// [requiredLearningIds] names the [SafetyLearning] items this requirement
/// mandates.
///
/// **Required vs. attendance-gating.** [gatesAttendance] (default `true`)
/// distinguishes two related but separate questions: "is this learning
/// required of a worker in this scope" (always yes for an active,
/// applicable requirement — see [requiredLearningIds] above, and
/// `SafetyRequirementRepository.watchResolvedRequiredLearning`, which is
/// UNAFFECTED by this field) versus "does incomplete learning from this
/// requirement block that worker from being marked Present at a Daily
/// Safety Meeting" (only when [gatesAttendance] is `true`). A site's
/// activity can legitimately carry many requirements — PPE, Working at
/// Height, Fall Protection, Ladder Safety, Site Induction, Manual
/// Handling, Confined Space — without every one of them being a hard
/// precondition for that day's toolbox talk; [gatesAttendance] lets an
/// admin mark the ones that genuinely are (e.g. PPE, Site Induction)
/// while the rest remain required and visible on
/// `MySafetyLearningScreen`/the compliance view, just not attendance
/// blockers. See `resolveAttendanceGatingLearningIds` in
/// `functions/src/worker_learning_callable.ts` for the server-side
/// resolver this drives, and its own doc comment for exactly how overlap
/// (a learning id required by both a gating and a non-gating requirement)
/// is resolved.
///
/// **Required before work.** [requiredBeforeWork] (default `false`) is a
/// third, independent question: "must this learning be completed before
/// the worker performs the applicable activity." It drives only the
/// worker-facing "Today's Safety Readiness" view (`getMyTodaysSafetyReadiness`
/// / `resolvePreWorkLearningIds` in `functions/src/worker_learning_callable.ts`)
/// and never blocks attendance on its own — only [gatesAttendance] does.
/// Neither field is ever derived from the other: all four combinations are
/// valid. The default is `false` (unlike [gatesAttendance]) because this
/// concept is new — no existing requirement silently becomes pre-work
/// learning, and no migration is required.
///
/// **Per-lesson settings.** [learningSettings] configures each selected
/// lesson individually WITHIN this requirement — the requirement->learning
/// relationship, stored here rather than on the global [SafetyLearning]
/// document, so the same lesson can behave differently under different
/// requirements. [requiredLearningIds] still decides WHICH lessons belong
/// to the requirement; [learningSettings] only decides how each behaves.
/// A lesson's own entry wins; a lesson with no entry (every lesson on a
/// requirement saved before per-lesson settings existed) falls back to the
/// requirement-level [gatesAttendance]/[requiredBeforeWork] — see
/// [gatesAttendanceFor]/[requiredBeforeWorkFor]. Requirements saved with
/// per-lesson settings always carry an entry for every selected lesson (the
/// server enforces this), so the fallback only ever applies to older data.
///
/// **Scope.** At most one of [projectId]/[siteId]/[activityId] is set:
///  - All null: applies organization-wide (the original, still-default
///    behavior — every existing requirement predates these fields and reads
///    back with all three null, unchanged).
///  - [projectId] set: applies to every worker whose assignments place them
///    at any site or activity under that project — a coarser scope than
///    [siteId]/[activityId], for when a requirement should apply project-wide
///    without enumerating each site/activity under it.
///  - [siteId] set: applies only to workers whose assignments place them at
///    that site.
///  - [activityId] set: applies only to workers assigned to that specific
///    activity. The activity's own site (and project) is looked up
///    server-side from the named [Activity] document when resolving — not
///    duplicated here — so an activity-scoped requirement is implicitly
///    scoped to that activity's site and project too.
///
/// See `SafetyRequirementRepository.watchResolvedRequiredLearning`'s doc
/// comment for the resolution rule this enables.
///
/// Created and edited exclusively through the `createSafetyRequirement`/
/// `updateSafetyRequirement` callables by a System Administrator or an
/// Organization Administrator of the requirement's own organization — see
/// `functions/src/safety_learning_callable.ts`. `updateSafetyRequirement`
/// validates every id in `requiredLearningIds` refers to an existing
/// `SafetyLearning` document in the same organization before writing.
/// Read-only client-side, mirroring [Activity].
class SafetyRequirement {
  const SafetyRequirement({
    required this.id,
    required this.organizationId,
    required this.name,
    required this.category,
    required this.risk,
    required this.status,
    this.description,
    this.requiredLearningIds = const [],
    this.gatesAttendance = true,
    this.requiredBeforeWork = false,
    this.learningSettings = const {},
    this.projectId,
    this.siteId,
    this.activityId,
    this.createdAt,
    this.updatedAt,
    this.createdBy,
    this.updatedBy,
  });

  final String id;
  final String organizationId;
  final String name;
  final String? description;

  /// Free text for now — no enum, per this feature's "do not invent complex
  /// permissions/systems" guidance.
  final String category;
  final SafetyRequirementRisk risk;
  final List<String> requiredLearningIds;

  /// Whether incomplete learning from this requirement blocks a worker
  /// from being marked Present at a Daily Safety Meeting. Defaults to
  /// `true` — see this class's doc comment ("Required vs.
  /// attendance-gating") — so a requirement predating this field, or one
  /// parsed from a document that simply omits it, behaves exactly as it
  /// did before this field existed: no migration required.
  final bool gatesAttendance;

  /// Whether this learning must be completed before the worker performs the
  /// applicable activity. Defaults to `false` — see this class's doc
  /// comment ("Required before work"). Does not block attendance by itself.
  final bool requiredBeforeWork;

  /// Per-lesson settings, keyed by learning id — see this class's doc
  /// comment ("Per-lesson settings"). Empty for a requirement saved before
  /// per-lesson settings existed.
  final Map<String, RequirementLearningSetting> learningSettings;

  /// Whether [learningId], within THIS requirement, blocks Daily Safety
  /// Meeting attendance: its own setting, else the requirement-level
  /// [gatesAttendance] fallback. Mirrors the server resolver exactly.
  bool gatesAttendanceFor(String learningId) =>
      learningSettings[learningId]?.gatesAttendance ?? gatesAttendance;

  /// Whether [learningId], within THIS requirement, must be completed
  /// before work: its own setting, else the requirement-level
  /// [requiredBeforeWork] fallback.
  bool requiredBeforeWorkFor(String learningId) =>
      learningSettings[learningId]?.requiredBeforeWork ?? requiredBeforeWork;

  /// Whether [learningId]'s quiz (if it has one) must be passed under this
  /// requirement — unset means yes (see
  /// [RequirementLearningSetting.quizRequired]).
  bool quizRequiredFor(String learningId) =>
      learningSettings[learningId]?.quizRequired ?? true;
  final OrganizationRecordStatus status;

  /// When set (and [siteId]/[activityId] are null), this requirement applies
  /// to every worker assigned anywhere under this project. Null means "no
  /// project scoping" — see this class's doc comment.
  final String? projectId;

  /// When set (and [activityId] is null), this requirement applies only to
  /// workers assigned to this site. Null means "no site scoping" — see this
  /// class's doc comment.
  final String? siteId;

  /// When set, this requirement applies only to workers assigned to this
  /// specific activity. Null means "no activity scoping" — see this class's
  /// doc comment.
  final String? activityId;

  final DateTime? createdAt;
  final DateTime? updatedAt;
  final String? createdBy;
  final String? updatedBy;

  /// Parses a safety requirement document. Throws [DataException] on a
  /// missing or malformed document — see [Activity.fromFirestore] for why.
  factory SafetyRequirement.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    if (data == null) {
      throw const DataException('That safety requirement could not be loaded.');
    }
    return SafetyRequirement.fromMap(doc.id, data);
  }

  factory SafetyRequirement.fromMap(String id, Map<String, dynamic> data) {
    final status = OrganizationRecordStatus.tryFromId(
      data['status'] as String?,
    );
    if (status == null) {
      throw const DataException(
        'That safety requirement has an unrecognised status.',
      );
    }
    final risk = SafetyRequirementRisk.tryFromId(data['risk'] as String?);
    if (risk == null) {
      throw const DataException(
        'That safety requirement has an unrecognised risk level.',
      );
    }
    final organizationId = data['organizationId'] as String?;
    if (organizationId == null || organizationId.isEmpty) {
      throw const DataException(
        'That safety requirement has no '
        'organization.',
      );
    }
    return SafetyRequirement(
      id: id,
      organizationId: organizationId,
      name: data['name'] as String? ?? '',
      description: data['description'] as String?,
      category: data['category'] as String? ?? '',
      risk: risk,
      requiredLearningIds:
          (data['requiredLearningIds'] as List<dynamic>?)?.cast<String>() ??
          const [],
      status: status,
      // Missing/null means true — see [gatesAttendance]'s own doc comment
      // for why this default must hold at every read site, not just here.
      gatesAttendance: data['gatesAttendance'] as bool? ?? true,
      // Missing/null means false — see [requiredBeforeWork]'s doc comment.
      requiredBeforeWork: data['requiredBeforeWork'] as bool? ?? false,
      learningSettings: RequirementLearningSetting.parseMap(
        data['learningSettings'],
      ),
      projectId: data['projectId'] as String?,
      siteId: data['siteId'] as String?,
      activityId: data['activityId'] as String?,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
      createdBy: data['createdBy'] as String?,
      updatedBy: data['updatedBy'] as String?,
    );
  }
}

/// One selected lesson's behavior within one [SafetyRequirement] — see
/// [SafetyRequirement.learningSettings].
///
/// Each field is nullable only so a malformed stored entry falls back to
/// the requirement-level flag field-by-field, matching the server resolver;
/// the server only ever WRITES entries with both booleans set.
class RequirementLearningSetting {
  const RequirementLearningSetting({
    this.gatesAttendance,
    this.requiredBeforeWork,
    this.quizRequired,
  });

  final bool? gatesAttendance;
  final bool? requiredBeforeWork;

  /// Whether the lesson's quiz (when it has one) must be passed to complete
  /// it under this requirement. Null (unset) means yes — every quiz was
  /// mandatory before this setting existed.
  final bool? quizRequired;

  /// The shape the callables accept: both booleans, [fallback] filling any
  /// unset field.
  Map<String, bool> toMap({
    required bool gatesAttendanceFallback,
    required bool requiredBeforeWorkFallback,
  }) => {
    'gatesAttendance': gatesAttendance ?? gatesAttendanceFallback,
    'requiredBeforeWork': requiredBeforeWork ?? requiredBeforeWorkFallback,
    'quizRequired': ?quizRequired,
  };

  /// Parses a stored `learningSettings` map, ignoring anything malformed —
  /// a non-map value, a non-map entry, or a non-boolean field — rather than
  /// throwing: a bad entry must degrade to the fallback, not make the whole
  /// requirement unreadable.
  static Map<String, RequirementLearningSetting> parseMap(Object? value) {
    if (value is! Map) return const {};
    return {
      for (final entry in value.entries)
        if (entry.key is String && entry.value is Map)
          entry.key as String: RequirementLearningSetting(
            gatesAttendance: _boolOrNull(
              (entry.value as Map)['gatesAttendance'],
            ),
            requiredBeforeWork: _boolOrNull(
              (entry.value as Map)['requiredBeforeWork'],
            ),
            quizRequired: _boolOrNull((entry.value as Map)['quizRequired']),
          ),
    };
  }

  static bool? _boolOrNull(Object? value) => value is bool ? value : null;
}
