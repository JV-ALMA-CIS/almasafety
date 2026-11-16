/**
 * Audit trail for Daily Safety Meetings.
 *
 * Every write that changes what a meeting records — starting it, editing
 * its activities/points/risk assessments, completing it, recording
 * attendance, adding/editing/removing a concern, raising a corrective
 * action from it — appends one entry to the top-level `audit_logs`
 * collection, the same append-only collection account approvals already
 * use (see `approval_callable.ts`). `firestore.rules` denies every client
 * read and write there, so only these Admin-SDK writes ever reach it.
 *
 * Entries are written in the SAME batch or transaction as the change they
 * describe, so a change can never be saved without its entry (or the other
 * way round).
 *
 * WHAT IS (AND IS NOT) RECORDED
 *
 * Ids, statuses and the before/after values of the fields that changed —
 * enough to reconstruct who changed what, and when. Free text a Foreman
 * typed (concern descriptions, crew notes, point notes, the Foreman's own
 * points) is deliberately
 * NOT copied here: it already lives on the meeting record itself, and
 * duplicating it would spread personal or sensitive wording into a second
 * place with its own retention.
 */

import {FieldValue, getFirestore} from "firebase-admin/firestore";

/** The meeting events this trail records. */
export type MeetingAuditAction =
  | "meeting.created"
  | "meeting.updated"
  | "meeting.completed"
  | "meeting.attendanceRecorded"
  | "meeting.concernAdded"
  | "meeting.concernUpdated"
  | "meeting.concernRemoved"
  | "meeting.foremanPointAdded"
  | "meeting.foremanPointUpdated"
  | "meeting.foremanPointRemoved"
  | "meeting.correctiveActionRaised";

/** What one audit entry says. */
export interface MeetingAuditEvent {
  organizationId: string;
  meetingId: string;
  actorUid: string;
  action: MeetingAuditAction;
  metadata: Record<string, unknown>;
}

/**
 * A new `audit_logs` document reference and the entry to write there for
 * [event]. The caller adds both to its own batch or transaction.
 *
 * @param {MeetingAuditEvent} event what happened.
 * @return {object} the reference and the data to write.
 */
export function meetingAuditEntry(event: MeetingAuditEvent): {
  ref: FirebaseFirestore.DocumentReference;
  data: FirebaseFirestore.DocumentData;
} {
  return {
    ref: getFirestore().collection("audit_logs").doc(),
    data: {
      organizationId: event.organizationId,
      actorUid: event.actorUid,
      action: event.action,
      targetCollection: "daily_safety_meetings",
      targetDocId: event.meetingId,
      metadata: event.metadata,
      createdAt: FieldValue.serverTimestamp(),
    },
  };
}

/**
 * The before/after values of each field in [after] that differs from
 * [before] — what a `meeting.updated` entry records. Fields that did not
 * change are left out.
 *
 * @param {Record<string, unknown>} before the stored values.
 * @param {Record<string, unknown>} after the new values.
 * @return {object} the changed fields' old and new values.
 */
export function changedFields(
  before: Record<string, unknown>,
  after: Record<string, unknown>
): {before: Record<string, unknown>; after: Record<string, unknown>} {
  const changedBefore: Record<string, unknown> = {};
  const changedAfter: Record<string, unknown> = {};
  for (const [field, value] of Object.entries(after)) {
    const old = before[field] ?? null;
    if (JSON.stringify(old) === JSON.stringify(value)) continue;
    changedBefore[field] = old;
    changedAfter[field] = value;
  }
  return {before: changedBefore, after: changedAfter};
}
