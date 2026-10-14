/**
 * IN-APP NOTIFICATIONS for the events someone has to act on, sent by
 * watching the records themselves (Firestore triggers) rather than from
 * inside each callable — so the callables stay as they are, and a failure
 * here can never stop the action that caused it.
 *
 * Instant:
 * - a corrective action assigned to you → the assignee;
 * - evidence submitted for review → whoever assigned it;
 * - your corrective action approved or sent back → the assignee;
 * - a hazard / near-miss reported → Site Managers/Admins and the site's
 *   Foremen;
 * - an incident reported → Site Managers/Admins and the site's Foremen
 *   (set its reporting level);
 * - an inspection submitted → Site Managers/Admins (not the inspector);
 * - a new AHA draft → the other Site Managers/Admins (to accept).
 *
 * Daily at 06:00 (Nairobi) — `sendDailyReminders`, each at most once a day:
 * - a corrective action due tomorrow or overdue → the assignee;
 * - an incident reporting step overdue → Site Managers/Admins.
 *
 * Nobody is notified about their own action. The handlers are exported
 * separately from the triggers so they can be tested directly.
 */

import {Timestamp, getFirestore} from "firebase-admin/firestore";
import {onDocumentCreated, onDocumentUpdated} from
  "firebase-functions/v2/firestore";
import {onSchedule} from "firebase-functions/v2/scheduler";
import * as logger from "firebase-functions/logger";
import {NotificationType, createNotification} from "./notification_callable";

type Data = FirebaseFirestore.DocumentData;

/**
 * Active Site Managers and Admins of [organizationId].
 *
 * @param {string} organizationId the organization.
 * @return {Promise<string[]>} their uids.
 */
export async function managersOf(organizationId: string): Promise<string[]> {
  const memberships = await getFirestore()
    .collectionGroup("memberships")
    .where("organizationId", "==", organizationId)
    .get();
  return memberships.docs
    .filter((doc) => {
      const data = doc.data();
      return data.status === "active" &&
        (data.role === "siteManager" || data.role === "admin");
    })
    .map((doc) => doc.ref.parent.parent?.id)
    .filter((uid): uid is string => typeof uid === "string");
}

/**
 * Active Foremen of [organizationId] assigned to [siteId].
 *
 * @param {string} organizationId the organization.
 * @param {string} siteId the site.
 * @return {Promise<string[]>} their uids.
 */
async function foremenAt(
  organizationId: string,
  siteId: string
): Promise<string[]> {
  const memberships = await getFirestore()
    .collectionGroup("memberships")
    .where("organizationId", "==", organizationId)
    .get();
  return memberships.docs
    .filter((doc) => {
      const data = doc.data();
      return data.status === "active" && data.role === "foreman" &&
        Array.isArray(data.siteIds) && data.siteIds.includes(siteId);
    })
    .map((doc) => doc.ref.parent.parent?.id)
    .filter((uid): uid is string => typeof uid === "string");
}

/**
 * Sends one notification to each of [recipients] (duplicates and
 * [exclude] — the person who caused it — left out). Never throws: a
 * notification problem is logged, not passed on.
 *
 * @param {string[]} recipients who to notify.
 * @param {string | null | undefined} exclude who not to notify.
 * @param {object} message the notification.
 * @return {Promise<number>} how many were sent.
 */
async function notify(
  recipients: string[],
  exclude: string | null | undefined,
  message: {
    organizationId: string;
    type: NotificationType;
    title: string;
    message: string;
    relatedEntityType: string;
    relatedEntityId: string;
    idPrefix?: string;
  }
): Promise<number> {
  const uids = [...new Set(recipients)].filter((uid) => uid && uid !== exclude);
  let sent = 0;
  for (const recipientUid of uids) {
    try {
      await createNotification({
        organizationId: message.organizationId,
        recipientUid,
        type: message.type,
        title: message.title,
        message: message.message,
        relatedEntityType: message.relatedEntityType,
        relatedEntityId: message.relatedEntityId,
        id: message.idPrefix ?
          `${message.idPrefix}-${recipientUid}` :
          undefined,
      });
      sent++;
    } catch (e) {
      logger.error("Could not send a notification", e);
    }
  }
  return sent;
}

/**
 * [value] (a Firestore Timestamp or Date) as a Date, or null.
 *
 * @param {unknown} value the value.
 * @return {Date | null} the date.
 */
function asDate(value: unknown): Date | null {
  if (value instanceof Timestamp) return value.toDate();
  if (value instanceof Date) return value;
  return null;
}

/**
 * "Fri 16 Oct" for [date] in Nairobi time.
 *
 * @param {Date} date the date.
 * @return {string} the label.
 */
function dayLabel(date: Date): string {
  return date.toLocaleDateString("en-GB", {
    weekday: "short",
    day: "numeric",
    month: "short",
    timeZone: "Africa/Nairobi",
  });
}

/**
 * The site's name, or "a site".
 *
 * @param {string} organizationId the organization.
 * @param {string} siteId the site.
 * @return {Promise<string>} its name.
 */
async function siteName(
  organizationId: string,
  siteId: string
): Promise<string> {
  const site = (
    await getFirestore().doc(`organizations/${organizationId}/sites/${siteId}`)
      .get()
  ).data();
  return typeof site?.name === "string" ? site.name : "a site";
}

// ---------------------------------------------------------------------------
// Handlers (exported for tests)
// ---------------------------------------------------------------------------

/**
 * A corrective action was created or changed.
 *
 * @param {string} organizationId the organization.
 * @param {string} actionId the corrective action.
 * @param {Data | undefined} before its data before (undefined = created).
 * @param {Data} after its data now.
 * @return {Promise<number>} notifications sent.
 */
export async function correctiveActionChanged(
  organizationId: string,
  actionId: string,
  before: Data | undefined,
  after: Data
): Promise<number> {
  const base = {
    organizationId,
    type: "correctiveAction" as const,
    relatedEntityType: "correctiveAction",
    relatedEntityId: actionId,
  };
  const title = String(after.title ?? "Corrective action");
  if (!before) {
    const due = asDate(after.dueDate);
    return notify([after.assignedTo], after.assignedBy, {
      ...base,
      title: "New corrective action for you",
      message: `${title}${due ? ` — due ${dayLabel(due)}` : ""}.`,
    });
  }
  if (before.status === after.status) return 0;
  if (after.status === "submittedForReview") {
    return notify([after.assignedBy], after.assignedTo, {
      ...base,
      title: "Evidence submitted for your review",
      message:
        `${after.assignedToName ?? "The assignee"} finished "${title}". ` +
        "Check the evidence and approve it or send it back.",
    });
  }
  if (after.status === "completed") {
    return notify([after.assignedTo], after.completedBy, {
      ...base,
      title: "Corrective action approved",
      message: `"${title}" was checked and closed. Thank you.`,
    });
  }
  if (
    before.status === "submittedForReview" &&
    (after.status === "open" || after.status === "inProgress")
  ) {
    return notify([after.assignedTo], null, {
      ...base,
      title: "Corrective action sent back",
      message: `"${title}" needs more work` +
        (after.reviewFeedback ? `: ${after.reviewFeedback}` : "."),
    });
  }
  return 0;
}

/**
 * A hazard or near-miss was reported.
 *
 * @param {string} organizationId the organization.
 * @param {string} hazardId the hazard.
 * @param {Data} hazard its data.
 * @return {Promise<number>} notifications sent.
 */
export async function hazardReported(
  organizationId: string,
  hazardId: string,
  hazard: Data
): Promise<number> {
  const siteId = String(hazard.siteId ?? "");
  const where = await siteName(organizationId, siteId);
  const nearMiss = hazard.kind === "nearMiss";
  const fromInspection = typeof hazard.inspectionId === "string";
  return notify(
    [...await managersOf(organizationId), ...await foremenAt(organizationId,
      siteId)],
    hazard.reportedByUid,
    {
      organizationId,
      type: "hazard",
      relatedEntityType: "hazard",
      relatedEntityId: hazardId,
      title: fromInspection ?
        `Inspection deficiency at ${where}` :
        nearMiss ? `Near-miss reported at ${where}` :
          `Hazard reported at ${where}`,
      message: String(hazard.description ?? "").slice(0, 200),
    }
  );
}

/**
 * An incident was reported.
 *
 * @param {string} organizationId the organization.
 * @param {string} incidentId the incident.
 * @param {Data} incident its data.
 * @return {Promise<number>} notifications sent.
 */
export async function incidentReported(
  organizationId: string,
  incidentId: string,
  incident: Data
): Promise<number> {
  const siteId = String(incident.siteId ?? "");
  const where = await siteName(organizationId, siteId);
  return notify(
    [...await managersOf(organizationId), ...await foremenAt(organizationId,
      siteId)],
    incident.reportedByUid,
    {
      organizationId,
      type: "incident",
      relatedEntityType: "incident",
      relatedEntityId: incidentId,
      title: `INCIDENT reported at ${where}`,
      message:
        `${String(incident.description ?? "").slice(0, 160)} — tell the ` +
        "COR now and set the reporting level.",
    }
  );
}

/**
 * An inspection changed — notifies when it is submitted for sign-off.
 *
 * @param {string} organizationId the organization.
 * @param {string} inspectionId the inspection.
 * @param {Data} before its data before.
 * @param {Data} after its data now.
 * @return {Promise<number>} notifications sent.
 */
export async function inspectionChanged(
  organizationId: string,
  inspectionId: string,
  before: Data,
  after: Data
): Promise<number> {
  if (before.status === after.status || after.status !== "submitted") {
    return 0;
  }
  const notOk = Number(after.notOkCount ?? 0);
  return notify(await managersOf(organizationId), after.inspectorUid, {
    organizationId,
    type: "inspection",
    relatedEntityType: "inspection",
    relatedEntityId: inspectionId,
    title: "Inspection awaiting your sign-off",
    message:
      `${after.templateName ?? "Inspection"} at ${after.siteName ?? "a site"}` +
      ` by ${after.inspectorName ?? "the inspector"}` +
      (notOk > 0 ? ` — ${notOk} deficienc${notOk === 1 ? "y" : "ies"}.` : "."),
  });
}

/**
 * A new AHA (or AHA revision) draft was prepared.
 *
 * @param {string} organizationId the organization.
 * @param {string} ahaId the AHA.
 * @param {Data} aha its data.
 * @return {Promise<number>} notifications sent.
 */
export async function riskAssessmentCreated(
  organizationId: string,
  ahaId: string,
  aha: Data
): Promise<number> {
  if (aha.status !== "draft") return 0;
  return notify(await managersOf(organizationId), aha.preparedByUid, {
    organizationId,
    type: "riskAssessment",
    relatedEntityType: "riskAssessment",
    relatedEntityId: ahaId,
    title: "AHA waiting for acceptance",
    message:
      `${aha.featureOfWork ?? "An AHA"} (${aha.siteName ?? "a site"}, ` +
      `revision ${aha.revision ?? 1}) prepared by ` +
      `${aha.preparedByName ?? "a Site Manager"}.`,
  });
}

/**
 * The daily reminders for one organization at [now].
 *
 * @param {string} organizationId the organization.
 * @param {Date} now the current time.
 * @return {Promise<number>} notifications sent.
 */
export async function remindOrganization(
  organizationId: string,
  now: Date
): Promise<number> {
  const db = getFirestore();
  const today = now.toISOString().slice(0, 10);
  const tomorrowEnd = new Date(now.getTime() + 48 * 60 * 60 * 1000);
  let sent = 0;

  const actions = await db
    .collection(`organizations/${organizationId}/corrective_actions`)
    .where("status", "in", ["open", "inProgress", "overdue"])
    .get();
  for (const doc of actions.docs) {
    const action = doc.data();
    const due = asDate(action.dueDate);
    if (!due || due > tomorrowEnd || !action.assignedTo) continue;
    const overdue = due < now;
    sent += await notify([action.assignedTo], null, {
      organizationId,
      type: "correctiveAction",
      relatedEntityType: "correctiveAction",
      relatedEntityId: doc.id,
      title: overdue ?
        "Corrective action OVERDUE" :
        "Corrective action due soon",
      message: `"${action.title}" ${overdue ? "was" : "is"} due ` +
        `${dayLabel(due)}.`,
      idPrefix: `due-${doc.id}-${today}`,
    });
  }

  const incidents = await db
    .collection(`organizations/${organizationId}/incidents`)
    .where("status", "in", ["reported", "underInvestigation"])
    .get();
  const overdueIncidents = incidents.docs.filter((doc) => {
    const steps = (doc.data().reportingSteps as Data[] | undefined) ?? [];
    return doc.data().reportingLevel == null ||
      steps.some((s) => !s.doneAt && (asDate(s.dueAt)?.getTime() ?? 0) <
        now.getTime());
  });
  if (overdueIncidents.length > 0) {
    const managers = await managersOf(organizationId);
    for (const doc of overdueIncidents) {
      const incident = doc.data();
      sent += await notify(managers, null, {
        organizationId,
        type: "incident",
        relatedEntityType: "incident",
        relatedEntityId: doc.id,
        title: incident.reportingLevel == null ?
          "Incident still has no reporting level" :
          "Incident reporting OVERDUE",
        message:
          `${String(incident.description ?? "").slice(0, 120)} — open it ` +
          "to see what must still be reported.",
        idPrefix: `report-${doc.id}-${today}`,
      });
    }
  }
  return sent;
}

// ---------------------------------------------------------------------------
// Triggers
// ---------------------------------------------------------------------------

export const onCorrectiveActionWritten = onDocumentCreated(
  "organizations/{orgId}/corrective_actions/{id}",
  async (event) => {
    const data = event.data?.data();
    if (!data) return;
    await correctiveActionChanged(
      event.params.orgId, event.params.id, undefined, data
    );
  }
);

export const onCorrectiveActionUpdated = onDocumentUpdated(
  "organizations/{orgId}/corrective_actions/{id}",
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!before || !after) return;
    await correctiveActionChanged(
      event.params.orgId, event.params.id, before, after
    );
  }
);

export const onHazardReported = onDocumentCreated(
  "organizations/{orgId}/hazards/{id}",
  async (event) => {
    const data = event.data?.data();
    if (data) await hazardReported(event.params.orgId, event.params.id, data);
  }
);

export const onIncidentReported = onDocumentCreated(
  "organizations/{orgId}/incidents/{id}",
  async (event) => {
    const data = event.data?.data();
    if (data) await incidentReported(event.params.orgId, event.params.id, data);
  }
);

export const onInspectionUpdated = onDocumentUpdated(
  "organizations/{orgId}/inspections/{id}",
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (before && after) {
      await inspectionChanged(
        event.params.orgId, event.params.id, before, after
      );
    }
  }
);

export const onRiskAssessmentCreated = onDocumentCreated(
  "organizations/{orgId}/risk_assessments/{id}",
  async (event) => {
    const data = event.data?.data();
    if (data) {
      await riskAssessmentCreated(event.params.orgId, event.params.id, data);
    }
  }
);

export const sendDailyReminders = onSchedule(
  {schedule: "0 6 * * *", timeZone: "Africa/Nairobi"},
  async () => {
    const organizations = await getFirestore().collection("organizations")
      .get();
    const now = new Date();
    for (const org of organizations.docs) {
      try {
        await remindOrganization(org.id, now);
      } catch (e) {
        logger.error(`Daily reminders failed for ${org.id}`, e);
      }
    }
  }
);
