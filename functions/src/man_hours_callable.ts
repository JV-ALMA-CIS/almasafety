/**
 * MONTHLY MAN-HOURS — the Safety Plan's Section 8a: man-hours worked are
 * reported to the Safety Office by the 25th of every month (taken as the
 * previous month's hours, due by the 25th of the following month).
 *
 * - `man_hours/{siteId}_{yyyy-MM}`: one site's month — total man-hours and
 *   number of workers, written by `saveManHours` (a Foreman for one of their
 *   own sites, or a Site Manager/Admin for any site).
 * - `man_hours_reports/{yyyy-MM}`: the month as reported to the Safety
 *   Office, written by `markManHoursReported` (Site Manager/Admin) — who
 *   reported it and when.
 *
 * `getManHoursSuggestion` counts the worker-days present at the site's
 * daily safety meetings that month, so the app can suggest a figure
 * (worker-days x hours per day) instead of it being added up by hand.
 *
 * Readable by every member of the organization (operational catch-all);
 * `firestore.rules` denies every client write.
 */

import {FieldValue, getFirestore} from "firebase-admin/firestore";
import {CallableRequest, HttpsError, onCall} from "firebase-functions/v2/https";

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
 * A required non-empty string argument.
 *
 * @param {CallableRequest} request the incoming request.
 * @param {string} field the argument.
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
 * The `month` argument: `yyyy-MM`, a real month, not in the future.
 *
 * @param {CallableRequest} request the incoming request.
 * @return {string} the month.
 */
function requireMonth(request: CallableRequest): string {
  const month = requireString(request, "month");
  const match = /^(\d{4})-(\d{2})$/.exec(month);
  const m = match ? Number(match[2]) : 0;
  if (!match || m < 1 || m > 12) {
    throw new HttpsError("invalid-argument", "month must be yyyy-MM.");
  }
  const thisMonth = new Date().toISOString().slice(0, 7);
  if (month > thisMonth) {
    throw new HttpsError(
      "invalid-argument",
      "Man-hours cannot be entered for a future month."
    );
  }
  return month;
}

/**
 * The caller's uid, name, role and sites in [organizationId]; the System
 * Administrator acts as an Admin.
 *
 * @param {CallableRequest} request the incoming request.
 * @param {string} organizationId the organization.
 * @return {Promise<object>} the caller.
 */
async function requireCaller(
  request: CallableRequest,
  organizationId: string
): Promise<{uid: string; name: string | null; role: string | null;
  siteIds: string[]}> {
  const uid = request.auth?.uid;
  if (!uid) throw denied();
  const db = getFirestore();
  const profile = (await db.doc(`users/${uid}`).get()).data();
  if (!profile || profile.accountStatus !== "active") throw denied();
  const name = typeof profile.name === "string" && profile.name.trim() ?
    profile.name.trim() :
    null;
  if (profile.platformRole === "admin") {
    return {uid, name, role: "admin", siteIds: []};
  }
  const membership = (
    await db.doc(`users/${uid}/memberships/${organizationId}`).get()
  ).data();
  if (!membership || membership.status !== "active") throw denied();
  return {
    uid,
    name,
    role: typeof membership.role === "string" ? membership.role : null,
    siteIds: Array.isArray(membership.siteIds) ?
      membership.siteIds.filter((id: unknown) => typeof id === "string") :
      [],
  };
}

/**
 * A whole number argument between [min] and [max].
 *
 * @param {CallableRequest} request the incoming request.
 * @param {string} field the argument.
 * @param {number} max the largest value.
 * @param {boolean} wholeNumber whether decimals are refused.
 * @return {number} the value.
 */
function requireNumber(
  request: CallableRequest,
  field: string,
  max: number,
  wholeNumber: boolean
): number {
  const value = (request.data ?? {})[field];
  if (
    typeof value !== "number" || !Number.isFinite(value) || value < 0 ||
    value > max || (wholeNumber && !Number.isInteger(value))
  ) {
    throw new HttpsError(
      "invalid-argument",
      `${field} must be a number from 0 to ${max}.`
    );
  }
  return wholeNumber ? value : Math.round(value * 10) / 10;
}

/** Saves one site's man-hours for a month (replacing what was there). */
export const saveManHours = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const siteId = requireString(request, "siteId");
  const month = requireMonth(request);
  const hours = requireNumber(request, "hours", 10000000, false);
  const workers = requireNumber(request, "workers", 100000, true);
  const rawNotes = (request.data ?? {}).notes;
  const notes = typeof rawNotes === "string" && rawNotes.trim() ?
    rawNotes.trim().slice(0, 500) :
    null;

  const caller = await requireCaller(request, organizationId);
  const isManager = caller.role === "admin" || caller.role === "siteManager";
  const isForemanHere =
    caller.role === "foreman" && caller.siteIds.includes(siteId);
  if (!isManager && !isForemanHere) throw denied();

  const db = getFirestore();
  const site = (
    await db.doc(`organizations/${organizationId}/sites/${siteId}`).get()
  ).data();
  if (!site) throw new HttpsError("not-found", "That site could not be found.");

  await db.doc(`organizations/${organizationId}/man_hours/${siteId}_${month}`)
    .set({
      organizationId,
      siteId,
      siteName: typeof site.name === "string" ? site.name : null,
      month,
      hours,
      workers,
      notes,
      enteredBy: caller.uid,
      enteredByName: caller.name,
      updatedAt: FieldValue.serverTimestamp(),
    });
  return {id: `${siteId}_${month}`};
});

/** Records that a month's man-hours were reported to the Safety Office. */
export const markManHoursReported = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const month = requireMonth(request);
  const caller = await requireCaller(request, organizationId);
  if (caller.role !== "admin" && caller.role !== "siteManager") {
    throw denied();
  }
  const db = getFirestore();
  const entries = await db
    .collection(`organizations/${organizationId}/man_hours`)
    .where("month", "==", month)
    .get();
  if (entries.empty) {
    throw new HttpsError(
      "failed-precondition",
      "Enter the man-hours for this month before marking it reported."
    );
  }
  const totalHours = entries.docs.reduce(
    (sum, doc) => sum + Number(doc.data().hours ?? 0), 0
  );
  await db.doc(`organizations/${organizationId}/man_hours_reports/${month}`)
    .set({
      organizationId,
      month,
      sites: entries.size,
      totalHours,
      reportedAt: FieldValue.serverTimestamp(),
      reportedBy: caller.uid,
      reportedByName: caller.name,
    });
  return {month, sites: entries.size, totalHours};
});

/**
 * Worker-days present at [siteId]'s daily safety meetings in [month] — the
 * basis of the suggested man-hours (worker-days x hours per day). Same
 * access as `saveManHours`.
 */
export const getManHoursSuggestion = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const siteId = requireString(request, "siteId");
  const month = requireMonth(request);
  const caller = await requireCaller(request, organizationId);
  const isManager = caller.role === "admin" || caller.role === "siteManager";
  if (!isManager &&
    !(caller.role === "foreman" && caller.siteIds.includes(siteId))) {
    throw denied();
  }
  const db = getFirestore();
  const meetings = await db
    .collection(`organizations/${organizationId}/daily_safety_meetings`)
    .where("siteId", "==", siteId)
    .get();
  const inMonth = meetings.docs.filter(
    (doc) => String(doc.data().date ?? "").startsWith(month)
  );
  const days = new Set<string>();
  let workerDays = 0;
  for (const meeting of inMonth) {
    const attendance = await meeting.ref.collection("attendance")
      .where("status", "==", "present")
      .get();
    if (attendance.size > 0) days.add(String(meeting.data().date));
    workerDays += attendance.size;
  }
  return {workerDays, meetingDays: days.size, meetings: inMonth.length};
});
