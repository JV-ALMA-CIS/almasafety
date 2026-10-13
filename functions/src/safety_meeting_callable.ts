/**
 * Weekly employee and monthly supervisory safety meetings for JV ALMA
 * C.I.S. — the Safety Plan's Sections 4 and 6: a weekly employee safety
 * meeting (Thursday 08:00) and a monthly supervisory safety meeting
 * (Thursday 08:30), each documented with the facilitator, the attendees,
 * the date and the subjects covered.
 *
 * Deliberately SEPARATE from the Foreman's daily safety meeting
 * (`daily_safety_meeting_callable.ts`): that one is one Foreman, one site,
 * one day, with the learning gate, the crew GO/STOP result and "today's
 * meeting" for workers. These are recorded once, after the meeting, as a
 * single closed record.
 *
 * `organizations/{orgId}/safety_meetings/{id}`, written only by
 * `recordSafetyMeeting`:
 *
 * - `weeklyEmployee`: for one site. A Foreman at one of their own sites,
 *   or a Site Manager/Admin at any site of the organization.
 * - `monthlySupervisory`: Site Manager/Admin only; for one site, or for
 *   every site (`siteId` null).
 *
 * A record is permanent: there is no update or delete callable, and
 * `firestore.rules` denies every client write. Reads are for the same
 * roles that run meetings (Admin/Site Manager/Foreman).
 */

import {FieldValue, getFirestore} from "firebase-admin/firestore";
import {CallableRequest, HttpsError, onCall} from "firebase-functions/v2/https";

export const SAFETY_MEETING_KINDS = [
  "weeklyEmployee",
  "monthlySupervisory",
] as const;
type SafetyMeetingKind = typeof SAFETY_MEETING_KINDS[number];

const MAX_TOPICS = 40;
const MAX_TOPIC_LENGTH = 200;
const MAX_ATTENDEES = 300;
const MAX_OTHER_ATTENDEES = 50;
const MAX_CONCERNS = 20;
const MAX_CONCERN_LENGTH = 500;
const MAX_NOTES_LENGTH = 2000;

/** How far back a meeting may be recorded, in days. */
const MAX_DAYS_BACK = 31;

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
 * Reads an optional list of short strings: trimmed, blanks dropped,
 * duplicates removed, at most [maxCount] entries of at most [maxLength]
 * characters each.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @param {string} field the argument name.
 * @param {number} maxCount the most entries allowed.
 * @param {number} maxLength the longest entry allowed.
 * @param {string} what how an entry is named in error messages.
 * @return {string[]} the clean list.
 */
function stringList(
  request: CallableRequest,
  field: string,
  maxCount: number,
  maxLength: number,
  what: string
): string[] {
  const raw = (request.data ?? {})[field];
  if (raw === undefined || raw === null) return [];
  if (!Array.isArray(raw)) {
    throw new HttpsError("invalid-argument", `${field} must be a list.`);
  }
  const values: string[] = [];
  for (const entry of raw) {
    if (typeof entry !== "string") {
      throw new HttpsError("invalid-argument", `${field} must be text.`);
    }
    const value = entry.trim();
    if (!value || values.includes(value)) continue;
    if (value.length > maxLength) {
      throw new HttpsError(
        "invalid-argument",
        `Each ${what} must be ${maxLength} characters or fewer.`
      );
    }
    values.push(value);
  }
  if (values.length > maxCount) {
    throw new HttpsError(
      "invalid-argument",
      `A meeting can have at most ${maxCount} ${what}s.`
    );
  }
  return values;
}

/**
 * Validates the meeting date: `yyyy-MM-dd`, a real calendar date, not in
 * the future (one day of slack for time zones — the app sends the
 * facilitator's local date) and at most [MAX_DAYS_BACK] days ago.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @return {string} the date.
 */
function requireMeetingDate(request: CallableRequest): string {
  const date = requireString(request, "date");
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(date);
  const parsed = match ?
    new Date(Date.UTC(+match[1], +match[2] - 1, +match[3])) :
    null;
  if (!parsed || parsed.toISOString().slice(0, 10) !== date) {
    throw new HttpsError("invalid-argument", "date must be yyyy-MM-dd.");
  }
  const dayMs = 24 * 60 * 60 * 1000;
  const now = Date.now();
  if (parsed.getTime() > now + dayMs) {
    throw new HttpsError(
      "invalid-argument",
      "A meeting cannot be recorded for a future date."
    );
  }
  if (parsed.getTime() < now - (MAX_DAYS_BACK + 1) * dayMs) {
    throw new HttpsError(
      "invalid-argument",
      `A meeting can be recorded up to ${MAX_DAYS_BACK} days afterwards.`
    );
  }
  return date;
}

/**
 * The caller's uid, name, role in [organizationId] and assigned sites.
 * Refuses inactive callers and non-members. The System Administrator acts
 * as an Admin.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @param {string} organizationId the organization.
 * @return {Promise<object>} the caller.
 */
async function requireCaller(
  request: CallableRequest,
  organizationId: string
): Promise<{
  uid: string;
  role: string | null;
  siteIds: string[];
  name: string | null;
}> {
  const uid = request.auth?.uid;
  if (!uid) throw denied();
  const profile = (await getFirestore().doc(`users/${uid}`).get()).data();
  if (!profile || profile.accountStatus !== "active") throw denied();
  const name =
    typeof profile.name === "string" && profile.name.trim() ?
      profile.name.trim() :
      null;
  if (profile.platformRole === "admin") {
    return {uid, role: "admin", siteIds: [], name};
  }
  const membership = (
    await getFirestore().doc(`users/${uid}/memberships/${organizationId}`).get()
  ).data();
  if (!membership || membership.status !== "active") throw denied();
  const siteIds = Array.isArray(membership.siteIds) ?
    (membership.siteIds as unknown[]).filter(
      (id): id is string => typeof id === "string"
    ) :
    [];
  return {
    uid,
    role: typeof membership.role === "string" ? membership.role : null,
    siteIds,
    name,
  };
}

/**
 * Names of the organization's ACTIVE members among [uids]. Refuses the
 * whole request if any uid is not one — an attendance record must only
 * name real people of this organization.
 *
 * @param {string} organizationId the organization.
 * @param {string[]} uids the attendees' uids.
 * @return {Promise<Record<string, string>>} uid → name (blank names are
 * left out).
 */
async function requireAttendees(
  organizationId: string,
  uids: string[]
): Promise<Record<string, string>> {
  const db = getFirestore();
  const names: Record<string, string> = {};
  await Promise.all(uids.map(async (uid) => {
    const [profileSnap, membershipSnap] = await Promise.all([
      db.doc(`users/${uid}`).get(),
      db.doc(`users/${uid}/memberships/${organizationId}`).get(),
    ]);
    const profile = profileSnap.data();
    const membership = membershipSnap.data();
    if (
      !profile || profile.accountStatus !== "active" ||
      !membership || membership.status !== "active"
    ) {
      throw new HttpsError(
        "invalid-argument",
        "One of the attendees is not an active member of this organization."
      );
    }
    if (typeof profile.name === "string" && profile.name.trim()) {
      names[uid] = profile.name.trim();
    }
  }));
  return names;
}

/**
 * Records a weekly employee or monthly supervisory safety meeting that has
 * taken place: the date, site (or every site, for a monthly supervisory
 * meeting), the subjects covered, who attended (members picked from the
 * organization, plus anyone without an account by name), notes and any
 * concerns raised. The caller is the facilitator.
 */
export const recordSafetyMeeting = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const kindRaw = (request.data ?? {}).kind;
  if (!(SAFETY_MEETING_KINDS as readonly unknown[]).includes(kindRaw)) {
    throw new HttpsError(
      "invalid-argument",
      "kind must be one of: " + SAFETY_MEETING_KINDS.join(", ")
    );
  }
  const kind = kindRaw as SafetyMeetingKind;
  const rawSiteId = (request.data ?? {}).siteId;
  const siteId =
    typeof rawSiteId === "string" && rawSiteId.trim() ?
      rawSiteId.trim() :
      null;

  const caller = await requireCaller(request, organizationId);
  const isManager = caller.role === "admin" || caller.role === "siteManager";
  if (kind === "monthlySupervisory") {
    if (!isManager) throw denied();
  } else {
    if (!siteId) {
      throw new HttpsError(
        "invalid-argument",
        "Choose the site the weekly meeting was held for."
      );
    }
    const isForemanHere =
      caller.role === "foreman" && caller.siteIds.includes(siteId);
    if (!isManager && !isForemanHere) throw denied();
  }

  const date = requireMeetingDate(request);
  const topics = stringList(
    request, "topics", MAX_TOPICS, MAX_TOPIC_LENGTH, "subject"
  );
  if (topics.length === 0) {
    throw new HttpsError(
      "invalid-argument",
      "Tick at least one subject that was covered."
    );
  }
  const attendeeUids = stringList(
    request, "attendeeUids", MAX_ATTENDEES, 128, "attendee"
  );
  const otherAttendees = stringList(
    request, "otherAttendees", MAX_OTHER_ATTENDEES, 100, "other attendee"
  );
  if (attendeeUids.length + otherAttendees.length === 0) {
    throw new HttpsError(
      "invalid-argument",
      "Record at least one person who attended."
    );
  }
  const concerns = stringList(
    request, "concerns", MAX_CONCERNS, MAX_CONCERN_LENGTH, "concern"
  );
  const notesRaw = (request.data ?? {}).notes;
  const notes =
    typeof notesRaw === "string" && notesRaw.trim() ? notesRaw.trim() : null;
  if (notes && notes.length > MAX_NOTES_LENGTH) {
    throw new HttpsError(
      "invalid-argument",
      `Notes must be ${MAX_NOTES_LENGTH} characters or fewer.`
    );
  }

  const db = getFirestore();
  let siteName: string | null = null;
  if (siteId) {
    const site = (
      await db.doc(`organizations/${organizationId}/sites/${siteId}`).get()
    ).data();
    if (!site) {
      throw new HttpsError("not-found", "That site could not be found.");
    }
    siteName = typeof site.name === "string" ? site.name : null;
  }
  const attendeeNames = await requireAttendees(organizationId, attendeeUids);

  const ref = db.collection(`organizations/${organizationId}/safety_meetings`)
    .doc();
  await ref.set({
    organizationId,
    kind,
    siteId,
    siteName,
    date,
    topics,
    attendeeUids,
    attendeeNames,
    otherAttendees,
    attendeeCount: attendeeUids.length + otherAttendees.length,
    concerns,
    notes,
    facilitatorUid: caller.uid,
    facilitatorName: caller.name,
    createdAt: FieldValue.serverTimestamp(),
  });

  return {id: ref.id};
});
