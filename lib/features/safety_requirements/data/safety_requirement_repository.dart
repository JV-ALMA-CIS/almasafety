import '../../../core/constants/firestore_paths.dart';
import '../../../core/services/firestore_repository.dart';
import '../../../core/services/firestore_service.dart';
import '../../activities/data/activity_assignment_repository.dart';
import '../../organizations/domain/organization_record_status.dart';
import '../../safety_learning/data/safety_learning_repository.dart';
import '../../safety_learning/domain/safety_learning.dart';
import '../domain/safety_requirement.dart';

/// Reads safety requirements from
/// `organizations/{organizationId}/safety_requirements`, and resolves the
/// required-learning set they imply.
///
/// Read-only — see [ActivityRepository]'s doc comment for why creating and
/// editing a safety requirement goes through a callable instead. Scoped to
/// one organization at a time by construction, matching [ActivityRepository].
///
/// **Required-learning resolution — Worker -> Project/Site/Activity ->
/// Requirement.** A [SafetyRequirement] applies to a worker when it is
/// organization-wide (no `projectId`/`siteId`/`activityId` — the original,
/// still-default behavior), or its `projectId`/`siteId`/`activityId` matches
/// one of the worker's own [ActivityAssignment]s (an assignment's `projectId`
/// is denormalized from its activity, see [ActivityAssignment]'s doc
/// comment). A worker's required learning is the union of
/// `requiredLearningIds` across every ACTIVE, applicable
/// [SafetyRequirement], resolved to ACTIVE [SafetyLearning] items only (an
/// inactive learning item does not drive a new obligation, even if a
/// requirement still lists its id — mirroring how inactive Sites/Activities
/// still exist but don't drive new obligations).
///
/// Deliberately kept in this ONE method — every caller (the worker's own
/// view and the admin compliance view) goes through
/// `watchResolvedRequiredLearning`, on the client, and through the
/// equivalent server-side logic in `getMyRequiredLearning`
/// (`functions/src/worker_learning_callable.ts`), which re-derives this same
/// set — never trusting a client-supplied "this is required" claim.
class SafetyRequirementRepository {
  SafetyRequirementRepository({
    required FirestoreService firestoreService,
    required String organizationId,
    SafetyLearningRepository? safetyLearningRepository,
    ActivityAssignmentRepository? activityAssignmentRepository,
  }) : _organizationId = organizationId,
       _repository = FirestoreRepository<SafetyRequirement>(
         firestoreService: firestoreService,
         collectionPath: FirestorePaths.safetyRequirementsCollection(
           organizationId,
         ),
         fromFirestore: SafetyRequirement.fromFirestore,
         toFirestore: (_) => throw UnsupportedError(
           'Safety requirements are written server-side.',
         ),
       ),
       _safetyLearningRepository =
           safetyLearningRepository ??
           SafetyLearningRepository(
             firestoreService: firestoreService,
             organizationId: organizationId,
           ),
       _activityAssignmentRepository =
           activityAssignmentRepository ??
           ActivityAssignmentRepository(
             firestoreService: firestoreService,
             organizationId: organizationId,
           );

  final String _organizationId;
  final FirestoreRepository<SafetyRequirement> _repository;
  final SafetyLearningRepository _safetyLearningRepository;
  final ActivityAssignmentRepository _activityAssignmentRepository;

  Future<SafetyRequirement?> getById(String id) => _repository.getById(id);

  Stream<SafetyRequirement?> watchById(String id) => _repository.watchById(id);

  /// Streams every safety requirement in this organization.
  Stream<List<SafetyRequirement>> watchAll() => _repository.watchCollection();

  /// The de-duplicated, ACTIVE [SafetyLearning] items required of [workerUid]
  /// across every ACTIVE, applicable [SafetyRequirement] in this
  /// organization.
  ///
  /// See this class's doc comment for the resolution rule. Resolved from
  /// [workerUid]'s own [ActivityAssignment]s — see
  /// [watchResolvedRequiredLearningForScope] for the alternative used when
  /// no such assignment exists to resolve from (e.g. a Foreman, who is never
  /// assigned to an activity that way).
  Stream<List<SafetyLearning>> watchResolvedRequiredLearning(String workerUid) {
    return watchAll().asyncMap((requirements) async {
      final assignments = await _activityAssignmentRepository
          .watchAssignmentsForWorker(_organizationId, workerUid)
          .first;
      final workerSiteIds = {
        for (final assignment in assignments) assignment.siteId,
      };
      final workerActivityIds = {
        for (final assignment in assignments) assignment.activityId,
      };
      final workerProjectIds = {
        for (final assignment in assignments)
          if (assignment.projectId != null) assignment.projectId!,
      };
      return _resolveLearningIds(
        _applicableLearningIds(
          requirements,
          projectIds: workerProjectIds,
          siteIds: workerSiteIds,
          activityIds: workerActivityIds,
        ),
      );
    });
  }

  /// The de-duplicated, ACTIVE [SafetyLearning] items required across every
  /// ACTIVE [SafetyRequirement] applicable to the given [siteId]/
  /// [activityIds] scope directly — NOT resolved from any worker's own
  /// [ActivityAssignment]s.
  ///
  /// Mirrors `resolveRequiredLearningForScope` in
  /// `worker_learning_callable.ts`, used there for the exact same reason:
  /// a Daily Safety Meeting's Foreman holds no [ActivityAssignment] of their
  /// own (that mechanism is worker-role only), so "what learning does this
  /// meeting require of its Foreman" must resolve from the MEETING's own
  /// site/activities, not from any assignment lookup. Used by
  /// `DailySafetyMeetingScreen`'s pre-completion learning check — purely a
  /// client-side preview; `completeDailySafetyMeeting` re-derives and
  /// enforces this same rule server-side regardless.
  Stream<List<SafetyLearning>> watchResolvedRequiredLearningForScope({
    String? projectId,
    required String siteId,
    required List<String> activityIds,
  }) {
    return watchAll().asyncMap(
      (requirements) => _resolveLearningIds(
        _applicableLearningIds(
          requirements,
          projectIds: projectId != null ? {projectId} : const {},
          siteIds: {siteId},
          activityIds: activityIds.toSet(),
        ),
      ),
    );
  }

  /// The ATTENDANCE-GATING subset of [watchResolvedRequiredLearningForScope]
  /// for the given scope: only learning ids contributed by at least one
  /// ACTIVE [SafetyRequirement] whose own [SafetyRequirement.gatesAttendance]
  /// is `true` — see that field's doc comment for the product rule, and
  /// `resolveAttendanceGatingLearningIds` in
  /// `functions/src/worker_learning_callable.ts` for the server-side
  /// resolver this mirrors (client-side preview only; the server callables
  /// remain authoritative regardless of what this stream emits).
  ///
  /// Used by [_LearningGateBanner]/[_ForemanReadinessBanner] in
  /// `daily_safety_meeting_screen.dart` INSTEAD OF
  /// [watchResolvedRequiredLearningForScope], so the pre-meeting UI can
  /// never disagree with what `requireForemanLearningComplete` will
  /// actually enforce server-side.
  Stream<List<SafetyLearning>> watchAttendanceGatingLearningForScope({
    String? projectId,
    required String siteId,
    required List<String> activityIds,
  }) {
    return watchAll().asyncMap(
      (requirements) => _resolveLearningIds(
        _gatingLearningIds(
          requirements,
          projectIds: projectId != null ? {projectId} : const {},
          siteIds: {siteId},
          activityIds: activityIds.toSet(),
        ),
      ),
    );
  }

  /// De-duplicated `requiredLearningIds` across every ACTIVE [requirements]
  /// entry whose own `siteId`/`activityId` is organization-wide or matches
  /// [siteIds]/[activityIds] — the shared applicability rule behind both
  /// [_applicableLearningIds] and [_gatingLearningIds].
  Set<String> _applicableLearningIds(
    List<SafetyRequirement> requirements, {
    required Set<String> projectIds,
    required Set<String> siteIds,
    required Set<String> activityIds,
  }) {
    return {
      for (final requirement in requirements)
        if (requirement.status == OrganizationRecordStatus.active &&
            _appliesToScope(requirement, projectIds, siteIds, activityIds))
          ...requirement.requiredLearningIds,
    };
  }

  /// The subset of [_applicableLearningIds] that blocks attendance: a
  /// learning id is included when at least one applicable requirement marks
  /// THAT LESSON as gating ([SafetyRequirement.gatesAttendanceFor] — its
  /// own per-lesson setting, else the requirement-level fallback). Decided
  /// per requirement before ids are aggregated, so a lesson gating under
  /// one requirement and not another is still gating. Mirrors
  /// `resolveApplicableRequirementLearningIds`
  /// (`functions/src/worker_learning_callable.ts`) exactly.
  Set<String> _gatingLearningIds(
    List<SafetyRequirement> requirements, {
    required Set<String> projectIds,
    required Set<String> siteIds,
    required Set<String> activityIds,
  }) {
    return {
      for (final requirement in requirements)
        if (requirement.status == OrganizationRecordStatus.active &&
            _appliesToScope(requirement, projectIds, siteIds, activityIds))
          for (final learningId in requirement.requiredLearningIds)
            if (requirement.gatesAttendanceFor(learningId)) learningId,
    };
  }

  /// Resolves [ids] to their ACTIVE [SafetyLearning] items — the shared
  /// tail of every resolution method on this class.
  Future<List<SafetyLearning>> _resolveLearningIds(Set<String> ids) async {
    final learningItems = await _safetyLearningRepository.watchAll().first;
    final learningById = {for (final item in learningItems) item.id: item};
    return [
      for (final id in ids)
        if (learningById[id] != null &&
            learningById[id]!.status == OrganizationRecordStatus.active)
          learningById[id]!,
    ];
  }

  /// Whether [requirement] applies given [projectIds]/[siteIds]/
  /// [activityIds] — see this class's doc comment for the rule.
  bool _appliesToScope(
    SafetyRequirement requirement,
    Set<String> projectIds,
    Set<String> siteIds,
    Set<String> activityIds,
  ) {
    final projectId = requirement.projectId;
    final siteId = requirement.siteId;
    final activityId = requirement.activityId;
    if (projectId == null && siteId == null && activityId == null) {
      return true;
    }
    if (projectId != null && projectIds.contains(projectId)) return true;
    if (siteId != null && siteIds.contains(siteId)) return true;
    if (activityId != null && activityIds.contains(activityId)) {
      return true;
    }
    return false;
  }

  /// The organization this repository is scoped to.
  String get organizationId => _organizationId;
}
