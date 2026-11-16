/**
 * Notification foundation for JVA Safety.
 *
 * Stores one document per notification, FLAT at
 * `organizations/{orgId}/notifications/{id}` — a sibling of `safety_alerts`
 * and `corrective_actions`, matching this codebase's existing "flat under
 * the organization" convention for record-keeping collections.
 * `firestore.rules` denies every client write to that collection outright.
 *
 * THIS IS A FOUNDATION, NOT A FEATURE INTEGRATION
 *
 * `createNotification` below is a plain exported FUNCTION, not an `onCall`
 * callable — it is never in `index.ts`'s export list and so is never
 * reachable from any client at all, by any uid, under any argument. It
 * exists so a FUTURE Cloud Function (e.g. a corrective action's due-date
 * handler, a safety alert's creation path) can call it directly, server-
 * side, to notify a user safely — exactly the "data/service foundation so
 * future features can create notifications safely" this stage asks for.
 * Nothing in this codebase calls it yet: Safety Alerts, Corrective Actions,
 * Daily Safety Meetings and Safety Learning do not automatically generate
 * notifications at this stage. That wiring, and anything resembling push
 * notifications, email or SMS, is out of scope here.
 *
 * WHAT AUTHORIZES A CALLER
 *
 * There is no "authorized creator" role for notifications the way
 * `safety_alert_callable.ts` has for alerts, because there is no
 * client-reachable creation path at all — see above. The two callables that
 * DO exist (`markNotificationRead`/`markAllNotificationsRead`) both derive
 * the acting user from `request.auth.uid` alone and NEVER accept a
 * `recipientUid` argument, mirroring `worker_learning_callable.ts`'s
 * `requireActiveWorker` discipline exactly: that absence is the structural
 * guarantee that a user can only ever mark their OWN notifications read,
 * not a validation rule that could be forgotten.
 *
 * WHAT A CALLER CANNOT DO
 *
 * - Create a notification, for themselves or anyone else, through any
 *   client-reachable callable — there isn't one.
 * - Mark another user's notification as read — every read-state mutation
 *   re-fetches the target notification and confirms
 *   `notification.recipientUid === request.auth.uid` before writing
 *   anything.
 * - Read another user's notifications, or another organization's — see
 *   `firestore.rules`'s narrower-than-usual read grant on this collection,
 *   mirroring `worker_learning_records`.
 * - Change `recipientUid`, `organizationId`, `type`, `title` or `message`
 *   through either callable — both accept only a notification id (and
 *   nothing else) as their mutable target, so there is no argument through
 *   which content could be altered after creation.
 * - Delete a notification — there is no delete callable, and
 *   `firestore.rules` denies every client write including delete.
 * - Learn anything from a refusal: every authorization failure returns the
 *   same opaque `permission-denied`.
 */

import {FieldValue, getFirestore} from "firebase-admin/firestore";
import {CallableRequest, HttpsError, onCall} from "firebase-functions/v2/https";
import {sendPush} from "./push_callable";

const NOTIFICATION_TYPES = [
  "safetyAlert",
  "correctiveAction",
  "safetyMeeting",
  "safetyLearning",
  "hazard",
  "incident",
  "inspection",
  "riskAssessment",
  "system",
] as const;
export type NotificationType = (typeof NOTIFICATION_TYPES)[number];

/**
 * The single refusal returned for every authorization failure. Mirrors
 * `denied()` in `safety_alert_callable.ts`.
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
 * Reads and validates a required non-empty string argument. Duplicated
 * per-file per this codebase's existing convention.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @param {string} field the argument name.
 * @return {string} the validated value.
 */
function requireString(request: CallableRequest, field: string): string {
  const value = (request.data ?? {})[field];
  if (typeof value !== "string" || !value.trim()) {
    throw new HttpsError("invalid-argument", `${field} is required.`);
  }
  return value.trim();
}

/**
 * Creates a notification for [recipientUid] within [organizationId].
 * SERVER-SIDE ONLY: this is a plain function other Cloud Functions call
 * directly, never an `onCall` callable — see this file's header note for
 * why nothing here is reachable from a client. Every argument is trusted
 * completely, exactly like `account_approval.ts`'s own plain functions:
 * the caller of THIS function (another piece of trusted server code) is
 * responsible for having already decided who the recipient is and why.
 *
 * @param {object} params the notification to create.
 * @param {string} params.organizationId the recipient's organization.
 * @param {string} params.recipientUid the notification's own recipient.
 * @param {NotificationType} params.type the notification's type.
 * @param {string} params.title a short title.
 * @param {string} params.message the notification body.
 * @param {string} [params.relatedEntityType] an optional loose pointer to
 * the entity this notification relates to (e.g. `"safetyAlert"`).
 * @param {string} [params.relatedEntityId] the id of that entity.
 * @param {string} [params.id] a fixed id: a notification with this id that
 * already exists is NOT sent again (the daily reminders use this so a
 * reminder is sent at most once per day).
 * @param {boolean} [params.urgent] the push stays on a computer's screen
 * until clicked.
 * @return {Promise<string>} the notification's id.
 */
export async function createNotification(params: {
  organizationId: string;
  recipientUid: string;
  type: NotificationType;
  title: string;
  message: string;
  relatedEntityType?: string;
  relatedEntityId?: string;
  id?: string;
  urgent?: boolean;
}): Promise<string> {
  const collection = getFirestore()
    .collection(`organizations/${params.organizationId}/notifications`);
  const ref = params.id ? collection.doc(params.id) : collection.doc();
  if (params.id && (await ref.get()).exists) return ref.id;
  await ref.set({
    organizationId: params.organizationId,
    recipientUid: params.recipientUid,
    type: params.type,
    title: params.title,
    message: params.message,
    relatedEntityType: params.relatedEntityType ?? null,
    relatedEntityId: params.relatedEntityId ?? null,
    isRead: false,
    createdAt: FieldValue.serverTimestamp(),
    readAt: null,
  });
  // Also to the recipient's phones/browsers — best effort, never throws.
  await sendPush({
    recipientUid: params.recipientUid,
    title: params.title,
    message: params.message,
    relatedEntityType: params.relatedEntityType,
    urgent: params.urgent,
  });
  return ref.id;
}

/**
 * Loads the target notification and confirms it belongs to
 * [organizationId] and to the CALLER — re-fetched fresh, never trusted from
 * the request payload. Mirrors `requireOrganizationAlert` in
 * `safety_alert_callable.ts`, narrowed further to also check
 * `recipientUid`, since a notification (unlike an alert) is personal.
 *
 * @param {string} organizationId the organization the action targets.
 * @param {string} notificationId the notification's id.
 * @param {string} callerUid the caller's own uid.
 * @return {Promise<FirebaseFirestore.DocumentReference>} a reference to the
 * validated notification document.
 */
async function requireOwnNotification(
  organizationId: string,
  notificationId: string,
  callerUid: string
): Promise<FirebaseFirestore.DocumentReference> {
  const ref = getFirestore().doc(
    `organizations/${organizationId}/notifications/${notificationId}`
  );
  const snapshot = await ref.get();
  const data = snapshot.data();
  if (!snapshot.exists || !data) {
    throw new HttpsError("not-found", "That notification no longer exists.");
  }
  if (data.organizationId !== organizationId) {
    throw new HttpsError(
      "failed-precondition",
      "That notification does not belong to the given organization."
    );
  }
  if (data.recipientUid !== callerUid) {
    throw denied();
  }
  return ref;
}

/**
 * Marks the caller's OWN notification as read. Only the notification's own
 * `recipientUid` may call this (see `requireOwnNotification`) — there is no
 * argument through which a caller could name a different notification's
 * recipient, since the recipient is read from the stored document, not the
 * request.
 */
export const markNotificationRead = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const notificationId = requireString(request, "notificationId");

  const uid = request.auth?.uid;
  if (!uid) throw denied();

  const ref = await requireOwnNotification(organizationId, notificationId, uid);

  await ref.update({
    isRead: true,
    readAt: FieldValue.serverTimestamp(),
  });

  return {id: notificationId, organizationId};
});

/**
 * Marks every one of the caller's OWN unread notifications within
 * [organizationId] as read, in a single batched write. Scoped to
 * `recipientUid === request.auth.uid` by construction — the query itself
 * can only ever return the caller's own documents.
 */
export const markAllNotificationsRead = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");

  const uid = request.auth?.uid;
  if (!uid) throw denied();

  const db = getFirestore();
  const unread = await db
    .collection(`organizations/${organizationId}/notifications`)
    .where("recipientUid", "==", uid)
    .where("isRead", "==", false)
    .get();

  if (unread.empty) {
    return {organizationId, updated: 0};
  }

  const batch = db.batch();
  const now = FieldValue.serverTimestamp();
  unread.docs.forEach((doc) => {
    batch.update(doc.ref, {isRead: true, readAt: now});
  });
  await batch.commit();

  return {organizationId, updated: unread.size};
});
