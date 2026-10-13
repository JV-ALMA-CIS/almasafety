/**
 * Risk assessments — the Safety Plan's Activity Hazard Analyses (AHA,
 * Section 10 and Appendix X; EM 385-1-1 Figure 1-2): one per phase / feature
 * of work ("Removals", "Roof construction"), each listing the principal
 * steps, the hazards of each step and the controls for each, plus the
 * equipment, inspection requirements and training requirements.
 *
 * `organizations/{orgId}/risk_assessments/{id}`. Lifecycle:
 *
 *   draft ──accept──▶ accepted ──(a revision is accepted)──▶ superseded
 *
 * Each AHA covers chosen ACTIVITIES of its site (`activityIds`), or the whole
 * site when none are chosen — the daily meeting shows the AHAs for the
 * activities being worked that day.
 *
 * - `saveRiskAssessment` creates a draft (revision 1) or edits a draft. A
 *   Site Manager/Admin — the plan's "competent/qualified person"; the last
 *   one to save is recorded as the preparer.
 * - `acceptRiskAssessment`: a Site Manager/Admin OTHER than the preparer
 *   accepts it as part of the plan (optionally noting the COR who reviewed
 *   it). Every step needs at least one hazard and one control, and the
 *   equipment, inspection and training lists must be filled in.
 * - An accepted AHA is never edited: `reviseRiskAssessment` copies it into a
 *   new draft (revision + 1). When that draft is accepted, the earlier
 *   revision becomes `superseded` — the plan's "reviewed and modified as
 *   necessary to address changing site conditions".
 * - `discardRiskAssessmentDraft` deletes a draft that was never accepted.
 *
 * Every member of the organization may read risk assessments (the crew must
 * know the hazards and controls of their work); `firestore.rules`' operational
 * catch-all already allows that and denies every client write.
 */

import {FieldValue, getFirestore} from "firebase-admin/firestore";
import {CallableRequest, HttpsError, onCall} from "firebase-functions/v2/https";

const MAX_STEPS = 40;
const MAX_LINES = 30;
const MAX_LIST = 50;
const MAX_LINE_LENGTH = 400;

/** One principal step of the work, with its hazards and controls. */
interface Step {
  id: string;
  step: string;
  hazards: string[];
  controls: string[];
}

/**
 * The single refusal returned for every authorization failure.
 *
 * @return {HttpsError} the opaque permission-denied error.
 */
function denied(): HttpsError {
  return new HttpsError(
    "permission-denied",
    "You do not have permission to do that."
  );
}

/**
 * Reads and validates a required non-empty string argument.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @param {string} field the argument name.
 * @return {string} the trimmed value.
 */
function requireString(request: CallableRequest, field: string): string {
  const value = (request.data ?? {})[field];
  if (typeof value !== "string" || !value.trim()) {
    throw new HttpsError("invalid-argument", `${field} is required.`);
  }
  return value.trim();
}

/**
 * Reads an optional trimmed string, null when absent or blank.
 *
 * @param {unknown} value the raw value.
 * @param {string} label how the field is named in errors.
 * @param {number} max the longest value allowed.
 * @return {string | null} the value, or null.
 */
function optionalText(
  value: unknown,
  label: string,
  max: number
): string | null {
  if (value === undefined || value === null) return null;
  if (typeof value !== "string") {
    throw new HttpsError("invalid-argument", `${label} must be text.`);
  }
  const text = value.trim();
  if (!text) return null;
  if (text.length > max) {
    throw new HttpsError(
      "invalid-argument",
      `${label} must be ${max} characters or fewer.`
    );
  }
  return text;
}

/**
 * Reads a list of lines: trimmed, blanks dropped, at most [maxCount] of at
 * most [MAX_LINE_LENGTH] characters each.
 *
 * @param {unknown} raw the raw value.
 * @param {string} label how the list is named in errors.
 * @param {number} maxCount the most lines allowed.
 * @return {string[]} the clean lines.
 */
function lines(raw: unknown, label: string, maxCount: number): string[] {
  if (raw === undefined || raw === null) return [];
  if (!Array.isArray(raw)) {
    throw new HttpsError("invalid-argument", `${label} must be a list.`);
  }
  const values: string[] = [];
  for (const entry of raw) {
    if (typeof entry !== "string") {
      throw new HttpsError("invalid-argument", `${label} must be text.`);
    }
    const value = entry.trim();
    if (!value) continue;
    if (value.length > MAX_LINE_LENGTH) {
      throw new HttpsError(
        "invalid-argument",
        `Each line of ${label} must be ${MAX_LINE_LENGTH} characters or ` +
          "fewer."
      );
    }
    values.push(value);
  }
  if (values.length > maxCount) {
    throw new HttpsError(
      "invalid-argument",
      `${label} can have at most ${maxCount} lines.`
    );
  }
  return values;
}

/**
 * Reads the principal steps: 1–40, each with its text, hazards and
 * controls. Steps keep their ids when given, otherwise get fresh ones.
 *
 * @param {unknown} raw the `steps` argument.
 * @return {Step[]} the clean steps.
 */
function readSteps(raw: unknown): Step[] {
  if (!Array.isArray(raw) || raw.length === 0) {
    throw new HttpsError(
      "invalid-argument",
      "Add at least one principal step."
    );
  }
  if (raw.length > MAX_STEPS) {
    throw new HttpsError(
      "invalid-argument",
      `An AHA can have at most ${MAX_STEPS} steps.`
    );
  }
  const used = new Set<string>();
  return raw.map((rawStep, index) => {
    const step = optionalText(rawStep?.step, "A step", MAX_LINE_LENGTH);
    if (!step) {
      throw new HttpsError(
        "invalid-argument",
        `Step ${index + 1} needs a description.`
      );
    }
    let id = typeof rawStep?.id === "string" ? rawStep.id.trim() : "";
    if (!id || used.has(id) || id.length > 40) id = `s${index + 1}`;
    while (used.has(id)) id = `${id}x`;
    used.add(id);
    return {
      id,
      step,
      hazards: lines(rawStep?.hazards, "Hazards", MAX_LINES),
      controls: lines(rawStep?.controls, "Controls", MAX_LINES),
    };
  });
}

/**
 * The caller's uid and name, if they are a Site Manager/Admin of
 * [organizationId] (or the System Administrator); refuses anyone else.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @param {string} organizationId the organization.
 * @return {Promise<object>} the caller's uid and name.
 */
async function requireManager(
  request: CallableRequest,
  organizationId: string
): Promise<{uid: string; name: string | null}> {
  const uid = request.auth?.uid;
  if (!uid) throw denied();
  const db = getFirestore();
  const profile = (await db.doc(`users/${uid}`).get()).data();
  if (!profile || profile.accountStatus !== "active") throw denied();
  const name =
    typeof profile.name === "string" && profile.name.trim() ?
      profile.name.trim() :
      null;
  if (profile.platformRole === "admin") return {uid, name};
  const membership = (
    await db.doc(`users/${uid}/memberships/${organizationId}`).get()
  ).data();
  if (
    !membership || membership.status !== "active" ||
    (membership.role !== "admin" && membership.role !== "siteManager")
  ) {
    throw denied();
  }
  return {uid, name};
}

/**
 * The path of a risk assessment.
 *
 * @param {string} organizationId the organization.
 * @param {string} id the risk assessment.
 * @return {string} its document path.
 */
function path(organizationId: string, id: string): string {
  return `organizations/${organizationId}/risk_assessments/${id}`;
}

/**
 * Validates the activities an AHA covers: each must be an activity of
 * [siteId]. Empty means the AHA covers the whole site.
 *
 * @param {string} organizationId the organization.
 * @param {string} siteId the AHA's site.
 * @param {unknown} raw the `activityIds` argument.
 * @return {Promise<string[]>} the activity ids.
 */
async function readActivityIds(
  organizationId: string,
  siteId: string,
  raw: unknown
): Promise<string[]> {
  if (raw === undefined || raw === null) return [];
  if (!Array.isArray(raw) || raw.some((id) => typeof id !== "string")) {
    throw new HttpsError("invalid-argument", "activityIds must be a list.");
  }
  const ids = [...new Set(raw as string[])].filter((id) => id.trim());
  if (ids.length > 50) {
    throw new HttpsError("invalid-argument", "Too many activities.");
  }
  const db = getFirestore();
  await Promise.all(ids.map(async (id) => {
    const activity = (
      await db.doc(`organizations/${organizationId}/activities/${id}`).get()
    ).data();
    if (!activity || activity.siteId !== siteId) {
      throw new HttpsError(
        "invalid-argument",
        "Each activity must be one of this site's activities."
      );
    }
  }));
  return ids;
}

/**
 * Reads the fields of the AHA form shared by create and edit.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @return {object} the validated fields.
 */
function readForm(request: CallableRequest) {
  const data = request.data ?? {};
  const featureOfWork = optionalText(
    data.featureOfWork, "Feature of work", 120
  );
  if (!featureOfWork) {
    throw new HttpsError(
      "invalid-argument",
      "Name the phase / feature of work."
    );
  }
  const estimatedStartDate = optionalText(
    data.estimatedStartDate, "Estimated start date", 10
  );
  if (
    estimatedStartDate &&
    !/^\d{4}-\d{2}-\d{2}$/.test(estimatedStartDate)
  ) {
    throw new HttpsError(
      "invalid-argument",
      "The estimated start date must be yyyy-MM-dd."
    );
  }
  return {
    featureOfWork,
    activity: optionalText(data.activity, "Activity", 300),
    contractNo: optionalText(data.contractNo, "Contract number", 60),
    location: optionalText(data.location, "Location", 200),
    estimatedStartDate,
    steps: readSteps(data.steps),
    equipment: lines(data.equipment, "Equipment", MAX_LIST),
    inspectionRequirements: lines(
      data.inspectionRequirements, "Inspection requirements", MAX_LIST
    ),
    trainingRequirements: lines(
      data.trainingRequirements, "Training requirements", MAX_LIST
    ),
  };
}

/**
 * Creates a draft AHA (no `id`; needs `siteId`) or edits a draft (`id`).
 * The caller becomes the preparer.
 */
export const saveRiskAssessment = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const caller = await requireManager(request, organizationId);
  const form = readForm(request);
  const db = getFirestore();
  const preparer = {
    preparedByUid: caller.uid,
    preparedByName: caller.name,
    updatedAt: FieldValue.serverTimestamp(),
  };

  const rawId = (request.data ?? {}).id;
  if (typeof rawId === "string" && rawId.trim()) {
    const ref = db.doc(path(organizationId, rawId.trim()));
    const current = (await ref.get()).data();
    if (!current) {
      throw new HttpsError("not-found", "That AHA could not be found.");
    }
    const activityIds = await readActivityIds(
      organizationId,
      current.siteId as string,
      (request.data ?? {}).activityIds
    );
    await db.runTransaction(async (tx) => {
      const existing = (await tx.get(ref)).data();
      if (!existing) {
        throw new HttpsError("not-found", "That AHA could not be found.");
      }
      if (existing.status !== "draft") {
        throw new HttpsError(
          "failed-precondition",
          "Only a draft can be edited. Start a revision instead."
        );
      }
      tx.update(ref, {...form, activityIds, ...preparer});
    });
    return {id: ref.id};
  }

  const siteId = requireString(request, "siteId");
  const site = (
    await db.doc(`organizations/${organizationId}/sites/${siteId}`).get()
  ).data();
  if (!site) throw new HttpsError("not-found", "That site could not be found.");
  const activityIds = await readActivityIds(
    organizationId, siteId, (request.data ?? {}).activityIds
  );
  const ref = db.collection(`organizations/${organizationId}/risk_assessments`)
    .doc();
  await ref.set({
    organizationId,
    siteId,
    siteName: typeof site.name === "string" ? site.name : null,
    projectId: typeof site.projectId === "string" ? site.projectId : null,
    ...form,
    activityIds,
    status: "draft",
    revision: 1,
    previousId: null,
    revisionDraftId: null,
    acceptedByUid: null,
    acceptedByName: null,
    acceptedAt: null,
    corName: null,
    acceptanceNote: null,
    supersededAt: null,
    createdAt: FieldValue.serverTimestamp(),
    ...preparer,
  });
  return {id: ref.id};
});

/**
 * Accepts a draft as part of the Safety Plan. Not by its preparer. A
 * revision's acceptance supersedes the revision before it.
 */
export const acceptRiskAssessment = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const id = requireString(request, "id");
  const caller = await requireManager(request, organizationId);
  const data = request.data ?? {};
  const corName = optionalText(data.corName, "COR name", 120);
  const note = optionalText(data.note, "Note", 1000);
  const db = getFirestore();
  const ref = db.doc(path(organizationId, id));

  await db.runTransaction(async (tx) => {
    const aha = (await tx.get(ref)).data();
    if (!aha) throw new HttpsError("not-found", "That AHA could not be found.");
    if (aha.status !== "draft") {
      throw new HttpsError(
        "failed-precondition",
        "Only a draft can be accepted."
      );
    }
    if (aha.preparedByUid === caller.uid) {
      throw new HttpsError(
        "failed-precondition",
        "Someone other than the person who prepared this AHA must accept it."
      );
    }
    const steps = (aha.steps as Step[] | undefined) ?? [];
    const incomplete = steps.findIndex(
      (s) => s.hazards.length === 0 || s.controls.length === 0
    );
    if (steps.length === 0 || incomplete >= 0) {
      throw new HttpsError(
        "failed-precondition",
        steps.length === 0 ?
          "Add the principal steps first." :
          `Step ${incomplete + 1} needs at least one hazard and one control.`
      );
    }
    for (const [field, label] of [
      ["equipment", "the equipment to be used"],
      ["inspectionRequirements", "the inspection requirements"],
      ["trainingRequirements", "the training requirements"],
    ]) {
      if (((aha[field] as string[] | undefined) ?? []).length === 0) {
        throw new HttpsError(
          "failed-precondition",
          `List ${label} before accepting.`
        );
      }
    }

    const previousId = aha.previousId as string | null;
    const previousRef = previousId ?
      db.doc(path(organizationId, previousId)) :
      null;
    const previous = previousRef ? (await tx.get(previousRef)).data() : null;

    tx.update(ref, {
      status: "accepted",
      acceptedByUid: caller.uid,
      acceptedByName: caller.name,
      acceptedAt: FieldValue.serverTimestamp(),
      corName,
      acceptanceNote: note,
    });
    if (previousRef && previous?.status === "accepted") {
      tx.update(previousRef, {
        status: "superseded",
        supersededAt: FieldValue.serverTimestamp(),
        supersededById: id,
        revisionDraftId: null,
      });
    }
  });
  return {id, status: "accepted"};
});

/**
 * Starts a revision of an accepted AHA: a new draft copy (revision + 1).
 * Refuses while a revision draft already exists.
 */
export const reviseRiskAssessment = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const id = requireString(request, "id");
  const caller = await requireManager(request, organizationId);
  const db = getFirestore();
  const ref = db.doc(path(organizationId, id));
  const draftRef =
    db.collection(`organizations/${organizationId}/risk_assessments`).doc();

  await db.runTransaction(async (tx) => {
    const aha = (await tx.get(ref)).data();
    if (!aha) throw new HttpsError("not-found", "That AHA could not be found.");
    if (aha.status !== "accepted") {
      throw new HttpsError(
        "failed-precondition",
        "Only the accepted AHA can be revised."
      );
    }
    if (aha.revisionDraftId) {
      throw new HttpsError(
        "failed-precondition",
        "A revision of this AHA is already being prepared."
      );
    }
    tx.set(draftRef, {
      organizationId,
      siteId: aha.siteId,
      siteName: aha.siteName ?? null,
      projectId: aha.projectId ?? null,
      featureOfWork: aha.featureOfWork,
      activityIds: aha.activityIds ?? [],
      activity: aha.activity ?? null,
      contractNo: aha.contractNo ?? null,
      location: aha.location ?? null,
      estimatedStartDate: aha.estimatedStartDate ?? null,
      steps: aha.steps ?? [],
      equipment: aha.equipment ?? [],
      inspectionRequirements: aha.inspectionRequirements ?? [],
      trainingRequirements: aha.trainingRequirements ?? [],
      status: "draft",
      revision: ((aha.revision as number | undefined) ?? 1) + 1,
      previousId: id,
      revisionDraftId: null,
      acceptedByUid: null,
      acceptedByName: null,
      acceptedAt: null,
      corName: null,
      acceptanceNote: null,
      supersededAt: null,
      preparedByUid: caller.uid,
      preparedByName: caller.name,
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    tx.update(ref, {revisionDraftId: draftRef.id});
  });
  return {id: draftRef.id};
});

/** Deletes a draft that was never accepted. */
export const discardRiskAssessmentDraft = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const id = requireString(request, "id");
  await requireManager(request, organizationId);
  const db = getFirestore();
  const ref = db.doc(path(organizationId, id));

  await db.runTransaction(async (tx) => {
    const aha = (await tx.get(ref)).data();
    if (!aha) throw new HttpsError("not-found", "That AHA could not be found.");
    if (aha.status !== "draft") {
      throw new HttpsError(
        "failed-precondition",
        "Only a draft can be discarded."
      );
    }
    const previousId = aha.previousId as string | null;
    if (previousId) {
      const previousRef = db.doc(path(organizationId, previousId));
      const previous = (await tx.get(previousRef)).data();
      if (previous?.revisionDraftId === id) {
        tx.update(previousRef, {revisionDraftId: null});
      }
    }
    tx.delete(ref);
  });
  return {id};
});
