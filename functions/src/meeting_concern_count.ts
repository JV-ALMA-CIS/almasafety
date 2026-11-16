/**
 * Keeps a Daily Safety Meeting's `concernCount` in step with its
 * `concerns` subcollection.
 *
 * Every write that adds or removes a concern — the meeting concern
 * callables and a worker's Pre-Start STOP becoming a concern — goes
 * through [changeConcerns], which writes the concern and the new count in
 * ONE transaction that also reads the meeting document. Two concerns added
 * at the same moment therefore serialize on the meeting and can never both
 * write the same count.
 *
 * Meetings started before `concernCount` existed have no such field. The
 * first concern change on one of those counts the subcollection inside the
 * same transaction and stores the true total, so an old meeting heals the
 * first time it is touched instead of starting from zero. Meetings that are
 * never touched again keep no count at all; the app counts their concerns
 * directly instead (see `DailySafetyMeeting.concernCount`).
 */

import {getFirestore} from "firebase-admin/firestore";

/**
 * Applies [write] (which adds or deletes one concern) and moves the
 * meeting's `concernCount` by [delta], atomically.
 *
 * @param {string} organizationId the meeting's organization.
 * @param {string} meetingId the meeting.
 * @param {number} delta +1 for an added concern, -1 for a removed one.
 * @param {Function} write adds the concern change (and anything else that
 * must land with it, such as an audit entry) to the transaction.
 * @return {Promise<number>} the meeting's new concern count.
 */
export async function changeConcerns(
  organizationId: string,
  meetingId: string,
  delta: 1 | -1,
  write: (transaction: FirebaseFirestore.Transaction) => void
): Promise<number> {
  const db = getFirestore();
  const meetingRef = db.doc(
    `organizations/${organizationId}/daily_safety_meetings/${meetingId}`
  );
  return db.runTransaction(async (transaction) => {
    const meeting = await transaction.get(meetingRef);
    const stored = meeting.data()?.concernCount;
    let before: number;
    if (typeof stored === "number") {
      before = stored;
    } else {
      const counted = await transaction.get(
        meetingRef.collection("concerns").count()
      );
      before = counted.data().count;
    }
    const after = Math.max(0, before + delta);
    write(transaction);
    transaction.update(meetingRef, {concernCount: after});
    return after;
  });
}
