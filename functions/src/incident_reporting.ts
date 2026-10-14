/**
 * Incident REPORTING DEADLINES — the Safety Plan's Section 8 (Accident
 * Reporting): every accident or incident is reported to the client's
 * representative (COR) as soon as it happens; then, by how serious it is,
 * an immediate phone notification (and the site sealed off), a 24-hour
 * notification, an email record within 24 hours, and/or the formal
 * ENG Form 3394 accident investigation report within five days.
 *
 * A Site Manager/Admin (`requireIncidentInvestigator`) sets the incident's
 * REPORTING LEVEL (`setIncidentReportingLevel`); the steps that level
 * requires are stored on the incident (`reportingSteps`), each with its
 * deadline counted from `occurredAt`. Each step is ticked off with who did
 * it, when, and an optional note such as a reference number
 * (`recordIncidentReportingStep`). An incident cannot be closed until its
 * level is set and every step is done (`closeIncident`).
 *
 * The rules live in [REPORTING_LEVELS] only, so a project whose client
 * sets different deadlines can be given its own set later.
 */

import {FieldValue, Timestamp, getFirestore} from "firebase-admin/firestore";
import {HttpsError, onCall} from "firebase-functions/v2/https";
import {requireIncidentInvestigator} from "./corrective_action_callable";

/** One reporting step a level requires, `hours` after the incident. */
interface StepRule {
  id: string;
  label: string;
  hours: number;
}

const NOTIFY_COR: StepRule = {
  id: "notifyCor",
  label: "Tell the client's representative (COR)",
  hours: 0,
};
const IMMEDIATE_PHONE: StepRule = {
  id: "immediatePhone",
  label: "Immediate phone notification to the Safety Office (via the COR)",
  hours: 0,
};
const SEAL_SITE: StepRule = {
  id: "sealSite",
  label: "Seal off the site and wait for the board of investigation",
  hours: 0,
};
const NOTIFY_24H: StepRule = {
  id: "notify24h",
  label: "24-hour notification (phone and/or email)",
  hours: 24,
};
const EMAIL_24H: StepRule = {
  id: "email24h",
  label: "Documented by email to the Safety Office",
  hours: 24,
};
const FORM_3394: StepRule = {
  id: "form3394",
  label: "ENG Form 3394 accident investigation report submitted",
  hours: 5 * 24,
};

/**
 * The Safety Plan's reporting levels and the steps each requires.
 */
export const REPORTING_LEVELS: Record<string, StepRule[]> = {
  // Fatality, permanent total or partial disability, three or more people
  // admitted to hospital, or property damage of $200,000 or more.
  immediate: [NOTIFY_COR, IMMEDIATE_PHONE, SEAL_SITE, FORM_3394],
  // Lost time beyond the day/shift, or damage of $2,000 – $200,000.
  lostTime: [NOTIFY_COR, NOTIFY_24H, FORM_3394],
  // Medical treatment without lost time.
  medical: [NOTIFY_COR, NOTIFY_24H, EMAIL_24H],
  // Property damage under $2,000.
  minorDamage: [NOTIFY_COR, EMAIL_24H],
  // First aid only / nobody hurt and nothing damaged.
  firstAid: [NOTIFY_COR],
};

/**
 * The incident, checked to belong to [organizationId] and not be closed.
 *
 * @param {string} organizationId the organization.
 * @param {string} incidentId the incident.
 * @return {Promise<object>} its reference and data.
 */
async function requireOpenIncident(
  organizationId: string,
  incidentId: string
): Promise<{
  ref: FirebaseFirestore.DocumentReference;
  data: FirebaseFirestore.DocumentData;
}> {
  const ref = getFirestore().doc(
    `organizations/${organizationId}/incidents/${incidentId}`
  );
  const data = (await ref.get()).data();
  if (!data || data.organizationId !== organizationId) {
    throw new HttpsError("not-found", "That incident no longer exists.");
  }
  if (data.status === "closed") {
    throw new HttpsError(
      "failed-precondition",
      "That incident has already been closed."
    );
  }
  return {ref, data};
}

/**
 * Reads a required string argument.
 *
 * @param {unknown} data the request data.
 * @param {string} field the argument.
 * @return {string} the trimmed value.
 */
function requireField(data: unknown, field: string): string {
  const value = (data as Record<string, unknown> | undefined)?.[field];
  if (typeof value !== "string" || !value.trim()) {
    throw new HttpsError("invalid-argument", `${field} is required.`);
  }
  return value.trim();
}

/**
 * The display name of [uid], or null.
 *
 * @param {string} uid the user.
 * @return {Promise<string | null>} their name.
 */
async function nameOf(uid: string): Promise<string | null> {
  const profile = (await getFirestore().doc(`users/${uid}`).get()).data();
  return typeof profile?.name === "string" && profile.name.trim() ?
    profile.name.trim() :
    null;
}

/**
 * Sets (or changes) an open incident's reporting level, storing the steps
 * it requires with their deadlines. Steps already done that the new level
 * still requires keep their record.
 */
export const setIncidentReportingLevel = onCall(async (request) => {
  const organizationId = requireField(request.data, "organizationId");
  const incidentId = requireField(request.data, "incidentId");
  const level = requireField(request.data, "level");
  const rules = REPORTING_LEVELS[level];
  if (!rules) {
    throw new HttpsError(
      "invalid-argument",
      "level must be one of: " + Object.keys(REPORTING_LEVELS).join(", ")
    );
  }
  const uid = await requireIncidentInvestigator(request, organizationId);
  const {ref, data} = await requireOpenIncident(organizationId, incidentId);

  const occurredAt = (data.occurredAt as Timestamp).toMillis();
  const previous = new Map<string, Record<string, unknown>>(
    ((data.reportingSteps as Record<string, unknown>[] | undefined) ?? [])
      .map((step) => [step.id as string, step])
  );
  const steps = rules.map((rule) => {
    const done = previous.get(rule.id);
    return {
      id: rule.id,
      label: rule.label,
      dueAt: Timestamp.fromMillis(occurredAt + rule.hours * 60 * 60 * 1000),
      doneAt: done?.doneAt ?? null,
      doneByUid: done?.doneByUid ?? null,
      doneByName: done?.doneByName ?? null,
      note: done?.note ?? null,
    };
  });

  await ref.update({
    reportingLevel: level,
    reportingSteps: steps,
    reportingLevelSetBy: uid,
    reportingLevelSetAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
    updatedBy: uid,
  });
  return {id: incidentId, level};
});

/**
 * Ticks a reporting step done (with an optional note, e.g. a reference
 * number) or un-ticks it, on an open incident.
 */
export const recordIncidentReportingStep = onCall(async (request) => {
  const organizationId = requireField(request.data, "organizationId");
  const incidentId = requireField(request.data, "incidentId");
  const stepId = requireField(request.data, "stepId");
  const done = (request.data ?? {}).done !== false;
  const rawNote = (request.data ?? {}).note;
  const note =
    typeof rawNote === "string" && rawNote.trim() ?
      rawNote.trim().slice(0, 500) :
      null;
  const uid = await requireIncidentInvestigator(request, organizationId);
  const name = await nameOf(uid);
  const db = getFirestore();
  const ref = db.doc(`organizations/${organizationId}/incidents/${incidentId}`);

  await db.runTransaction(async (tx) => {
    const data = (await tx.get(ref)).data();
    if (!data || data.organizationId !== organizationId) {
      throw new HttpsError("not-found", "That incident no longer exists.");
    }
    if (data.status === "closed") {
      throw new HttpsError(
        "failed-precondition",
        "That incident has already been closed."
      );
    }
    const steps =
      (data.reportingSteps as Record<string, unknown>[] | undefined) ?? [];
    if (!steps.some((s) => s.id === stepId)) {
      throw new HttpsError(
        "failed-precondition",
        "That reporting step is not required for this incident."
      );
    }
    tx.update(ref, {
      reportingSteps: steps.map((s) => s.id !== stepId ? s : {
        ...s,
        doneAt: done ? Timestamp.now() : null,
        doneByUid: done ? uid : null,
        doneByName: done ? name : null,
        note: done ? note : null,
      }),
      updatedAt: FieldValue.serverTimestamp(),
      updatedBy: uid,
    });
  });
  return {id: incidentId, stepId, done};
});

/**
 * Refuses to close an incident whose reporting is not finished: the level
 * must be set and every step done.
 *
 * @param {FirebaseFirestore.DocumentData} incident the incident's data.
 */
export function requireReportingComplete(
  incident: FirebaseFirestore.DocumentData
): void {
  if (!incident.reportingLevel) {
    throw new HttpsError(
      "failed-precondition",
      "Set the incident's reporting level before closing it."
    );
  }
  const open = ((incident.reportingSteps as
    Record<string, unknown>[] | undefined) ?? [])
    .filter((s) => !s.doneAt);
  if (open.length > 0) {
    throw new HttpsError(
      "failed-precondition",
      "These reporting steps are not done yet: " +
        open.map((s) => s.label).join("; ") + "."
    );
  }
}
