/**
 * Daily Pre-Start Check callables for JVA Safety — a worker's short
 * "safe to start?" checklist, done every day before work (a "Take 5" / Safety
 * Green Light). Each check ends in one of three outcomes:
 *
 *  - `go`          — every answer was "yes".
 *  - `goCorrected` — at least one "no" that the worker fixed on the spot
 *                    (with a note saying what they did), and none they
 *                    could not fix.
 *  - `stop`        — at least one "no" the worker could NOT fix. A STOP
 *                    raises a concern on today's Daily Safety Meeting at the
 *                    worker's site and notifies that site's Foremen.
 *
 * WHERE THE QUESTIONS COME FROM
 *
 * No admin-authored question list exists. The questions are re-derived on
 * the server on every call from two sources:
 *  1. [STANDARD_QUESTIONS] — the same five every worker answers every day.
 *  2. One question per ACTIVE `SafetyRequirement` that applies to the
 *     worker's own work today (organization-wide, or matching their site,
 *     its project, or one of their activities there) — the exact
 *     applicability rule `requirementApplies` in
 *     `worker_learning_callable.ts` already uses for required learning.
 *
 * WHAT THIS DOES NOT DO (deliberately, for the first field release)
 *
 * The check WARNS; it never blocks. `recordMeetingAttendance` does not read
 * it, so a worker who has not done it — or who answered STOP — can still be
 * marked present. The Foreman sees every worker's result on the crew card
 * and decides.
 *
 * ONE CHECK PER WORKER PER DAY
 *
 * Stored at `organizations/{orgId}/pre_start_checks/{uid}_{date}` (date is
 * the server's UTC `YYYY-MM-DD`, the same day boundary Daily Safety
 * Meetings use — see `todaysMeetingDate`). Once submitted it is a permanent
 * safety record: a second submission the same day is refused, and
 * `firestore.rules` denies every client write. Like every worker callable
 * in this codebase there is no `workerUid` argument — the caller only ever
 * acts on their own check.
 */

import {FieldValue, getFirestore} from "firebase-admin/firestore";
import {CallableRequest, HttpsError, onCall} from "firebase-functions/v2/https";
import {createNotification} from "./notification_callable";
import {resolveTodaysContext} from "./daily_learning_plan";
import {
  readMembership,
  requirementApplies,
  todaysMeetingDate,
} from "./worker_learning_callable";

/** The three possible results of a check — and of a crew's meeting. */
export const PRE_START_OUTCOMES = ["go", "goCorrected", "stop"] as const;
export type PreStartOutcome = (typeof PRE_START_OUTCOMES)[number];

/** A worker's answer to one question. */
const ANSWERS = ["yes", "fixed", "cannotFix"] as const;
type Answer = (typeof ANSWERS)[number];

/** Longest note accepted on a "fixed"/"cannot fix" answer. */
const MAX_NOTE_LENGTH = 500;

interface PreStartQuestion {
  id: string;
  prompt: string;
  kind: "standard" | "requirement";
  risk: string | null;
}

/** The five questions every worker answers every day. */
export const STANDARD_QUESTIONS: PreStartQuestion[] = [
  {
    id: "std-ppe",
    prompt: "I am wearing the right PPE for today's work.",
    kind: "standard",
    risk: null,
  },
  {
    id: "std-tools",
    // Safety Plan Section 7: every worker checks their own electrical
    // cords, hand and power tools, and machinery each day before use.
    prompt: "I checked my electrical cords, hand and power tools, and any " +
      "machinery I will use today — undamaged, guards fitted.",
    kind: "standard",
    risk: null,
  },
  {
    id: "std-area",
    prompt: "I have checked my work area for hazards.",
    kind: "standard",
    risk: null,
  },
  {
    id: "std-emergency",
    prompt: "I know the assembly point and who to call in an emergency " +
      "(shown on my dashboard).",
    kind: "standard",
    risk: null,
  },
  {
    id: "std-fit",
    prompt: "I am fit for work today (not unwell, tired or impaired).",
    kind: "standard",
    risk: null,
  },
];

/**
 * The standard opaque permission-denied error — duplicated per-file per
 * this codebase's existing convention.
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
 * The deterministic id of one worker's check for one day — at most one can
 * ever exist per worker per day.
 *
 * @param {string} workerUid the worker.
 * @param {string} date the `YYYY-MM-DD` day.
 * @return {string} the document id.
 */
export function preStartCheckId(workerUid: string, date: string): string {
  return `${workerUid}_${date}`;
}

/**
 * Authorizes the caller as an ACTIVE `worker` of [organizationId] acting on
 * their own behalf, and returns their uid, name and membership sites.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @param {string} organizationId the organization the action targets.
 * @return {Promise<{uid: string, name: string, siteIds: string[]}>} the
 * caller.
 */
async function requireActiveWorkerRole(
  request: CallableRequest,
  organizationId: string
): Promise<{uid: string; name: string; siteIds: string[]}> {
  const uid = request.auth?.uid;
  if (!uid) throw denied();
  const db = getFirestore();
  const profile = (await db.doc(`users/${uid}`).get()).data();
  if (!profile || profile.accountStatus !== "active") throw denied();
  const membershipData = (
    await db.doc(`users/${uid}/memberships/${organizationId}`).get()
  ).data();
  if (!membershipData || membershipData.status !== "active") throw denied();
  if (membershipData.role !== "worker") {
    throw new HttpsError(
      "failed-precondition",
      "The Daily Pre-Start Check is completed by workers."
    );
  }
  const membership = await readMembership(organizationId, uid);
  return {
    uid,
    name: typeof profile.name === "string" ? profile.name : "",
    siteIds: membership.siteIds,
  };
}

/**
 * The site, project and activities the caller's check is for today —
 * exactly the context their "Needed today" learning resolves from (see
 * `resolveTodaysContext` in `daily_learning_plan.ts`), so the two never
 * disagree about what the worker is doing today.
 *
 * @param {string} organizationId the organization.
 * @param {string} workerUid the worker.
 * @param {string[]} siteIds the worker's membership sites.
 * @param {string} date today.
 * @return {Promise<object>} the site, its project, the worker's activities
 * there, and today's meeting id (or null).
 */
async function workerContext(
  organizationId: string,
  workerUid: string,
  siteIds: string[],
  date: string
): Promise<{
  siteId: string;
  projectId: string | null;
  activityIds: string[];
  meetingId: string | null;
}> {
  const context = await resolveTodaysContext(organizationId, workerUid, date);
  if (siteIds.length === 0 || !context.siteId) {
    throw new HttpsError(
      "failed-precondition",
      "You have not been assigned to a site yet."
    );
  }
  return {
    siteId: context.siteId,
    projectId: context.projectId,
    activityIds: context.activityIds,
    meetingId: context.meetingId,
  };
}

/**
 * The names of every requirement in [names], as "A", "A and B" or
 * "A, B and C".
 *
 * @param {string[]} names requirement names.
 * @return {string} the joined names.
 */
function joinNames(names: string[]): string {
  const quoted = names.map((name) => `"${name}"`);
  if (quoted.length <= 1) return quoted.join("");
  return `${quoted.slice(0, -1).join(", ")} and ${quoted[quoted.length - 1]}`;
}

/**
 * Today's questions for one worker — only what today's work needs:
 *
 *  1. the five standard questions;
 *  2. ONE question per activity the worker is doing today that has at
 *     least one HIGH-risk requirement, naming all of them in one line
 *     ("Roofing: the controls for "Working at Height" and "Fall
 *     Protection" are in place.");
 *  3. ONE question for HIGH-risk requirements that are not tied to an
 *     activity (site-, project- or organization-wide), if there are any.
 *
 * Medium- and low-risk requirements are left to learning and the meeting.
 * Most workers do one activity, so the check is six or seven questions.
 *
 * @param {string} organizationId the organization.
 * @param {object} context see `workerContext`.
 * @return {Promise<PreStartQuestion[]>} the questions, in display order.
 */
async function resolveQuestions(
  organizationId: string,
  context: {siteId: string; projectId: string | null; activityIds: string[]}
): Promise<PreStartQuestion[]> {
  const db = getFirestore();
  const requirements = await db
    .collection(`organizations/${organizationId}/safety_requirements`)
    .where("status", "==", "active")
    .get();
  const scope = {
    siteIds: new Set([context.siteId]),
    activityIds: new Set(context.activityIds),
    projectIds: new Set(context.projectId ? [context.projectId] : []),
  };

  const byActivity = new Map<string, string[]>();
  const general: string[] = [];
  for (const doc of requirements.docs) {
    const data = doc.data();
    if (data.risk !== "high" || !requirementApplies(data, scope)) continue;
    const name = typeof data.name === "string" && data.name.trim() ?
      data.name.trim() :
      "Unnamed requirement";
    const activityId =
      typeof data.activityId === "string" && data.activityId ?
        data.activityId :
        null;
    if (activityId === null) {
      general.push(name);
    } else {
      byActivity.set(activityId, [...(byActivity.get(activityId) ?? []), name]);
    }
  }

  const questions: PreStartQuestion[] = [...STANDARD_QUESTIONS];
  const activityIds = context.activityIds.filter((id) => byActivity.has(id));
  const activityDocs = await Promise.all(activityIds.map((id) =>
    db.doc(`organizations/${organizationId}/activities/${id}`).get()
  ));
  activityIds.forEach((activityId, index) => {
    const activityName = activityDocs[index].data()?.name;
    const label = typeof activityName === "string" && activityName ?
      activityName :
      "Your work";
    const names = [...(byActivity.get(activityId) ?? [])].sort();
    questions.push({
      id: `act-${activityId}`,
      prompt: `${label}: the controls for ${joinNames(names)} are in ` +
        "place and I will follow them today.",
      kind: "requirement",
      risk: "high",
    });
  });
  if (general.length > 0) {
    questions.push({
      id: "site-high-risk",
      prompt: `Site: the controls for ${joinNames(general.sort())} are in ` +
        "place and I will follow them today.",
      kind: "requirement",
      risk: "high",
    });
  }
  return questions;
}

/**
 * A stored check, shaped for the client (Timestamps as ISO strings).
 *
 * @param {string} id the document id.
 * @param {FirebaseFirestore.DocumentData} data the stored check.
 * @return {object} the client-facing submission.
 */
function submissionView(id: string, data: FirebaseFirestore.DocumentData) {
  const submittedAt = data.submittedAt;
  return {
    id,
    outcome: data.outcome,
    siteId: data.siteId,
    date: data.date,
    answers: Array.isArray(data.answers) ? data.answers : [],
    submittedAt: submittedAt && typeof submittedAt.toDate === "function" ?
      submittedAt.toDate().toISOString() :
      null,
  };
}

/**
 * Every active Foreman whose membership includes [siteId].
 *
 * @param {string} organizationId the organization.
 * @param {string} siteId the site.
 * @return {Promise<string[]>} the Foremen's uids.
 */
async function foremenAtSite(
  organizationId: string,
  siteId: string
): Promise<string[]> {
  const memberships = await getFirestore()
    .collectionGroup("memberships")
    .where("organizationId", "==", organizationId)
    .get();
  const uids: string[] = [];
  for (const doc of memberships.docs) {
    const data = doc.data();
    const uid = doc.ref.parent.parent?.id;
    if (!uid) continue;
    if (data.role !== "foreman" || data.status !== "active") continue;
    if (!Array.isArray(data.siteIds) || !data.siteIds.includes(siteId)) {
      continue;
    }
    uids.push(uid);
  }
  return uids;
}

/**
 * Every active Site Manager of [organizationId].
 *
 * @param {string} organizationId the organization.
 * @return {Promise<string[]>} the Site Managers' uids.
 */
export async function siteManagersOf(
  organizationId: string
): Promise<string[]> {
  const memberships = await getFirestore()
    .collectionGroup("memberships")
    .where("organizationId", "==", organizationId)
    .get();
  return memberships.docs
    .filter((doc) => {
      const data = doc.data();
      return data.role === "siteManager" && data.status === "active";
    })
    .map((doc) => doc.ref.parent.parent?.id)
    .filter((uid): uid is string => typeof uid === "string");
}

/**
 * The concern text for a STOP check — names the worker and every answer
 * they could not fix, with their notes.
 *
 * @param {string} workerName the worker's name.
 * @param {Array<object>} stops the "cannot fix" answers.
 * @return {string} the concern description.
 */
function stopConcernText(
  workerName: string,
  stops: {prompt: string; note: string | null}[]
): string {
  const lines = stops.map((stop) =>
    `- ${stop.prompt}${stop.note ? ` — ${stop.note}` : ""}`
  );
  return `Pre-Start Check STOP by ${workerName || "a worker"}:\n` +
    lines.join("\n");
}

/**
 * Creates the meeting concern for one STOP check and links it back to the
 * check. Shared by `submitPreStartCheck` (a meeting already exists) and
 * `attachPendingPreStartStops` (the meeting is started afterwards).
 *
 * @param {string} organizationId the organization.
 * @param {string} meetingId the meeting to attach to.
 * @param {FirebaseFirestore.DocumentReference} checkRef the check.
 * @param {FirebaseFirestore.DocumentData} check the check's data.
 * @return {Promise<string>} the new concern's id.
 */
async function createStopConcern(
  organizationId: string,
  meetingId: string,
  checkRef: FirebaseFirestore.DocumentReference,
  check: FirebaseFirestore.DocumentData
): Promise<string> {
  const answers: Array<Record<string, unknown>> =
    Array.isArray(check.answers) ? check.answers : [];
  const stops = answers
    .filter((a) => a.answer === "cannotFix")
    .map((a) => ({
      prompt: String(a.prompt ?? ""),
      note: typeof a.note === "string" ? a.note : null,
    }));
  const concernRef = getFirestore()
    .collection(
      `organizations/${organizationId}/daily_safety_meetings/${meetingId}` +
        "/concerns"
    )
    .doc();
  await concernRef.set({
    meetingId,
    organizationId,
    siteId: check.siteId,
    description: stopConcernText(String(check.workerName ?? ""), stops),
    category: "safety",
    reportedBy: check.workerUid,
    status: "open",
    source: "preStartCheck",
    preStartCheckId: checkRef.id,
    createdAt: FieldValue.serverTimestamp(),
  });
  await checkRef.update({meetingId, concernId: concernRef.id});
  return concernRef.id;
}

/**
 * Attaches every STOP check submitted at [siteId] on [date] BEFORE that
 * day's meeting existed to the newly started meeting, as concerns — so a
 * worker's STOP is never lost just because they did their check before the
 * Foreman started the meeting. Called by `createDailySafetyMeeting`.
 *
 * @param {string} organizationId the organization.
 * @param {string} siteId the meeting's site.
 * @param {string} date the meeting's date.
 * @param {string} meetingId the new meeting.
 * @return {Promise<number>} how many concerns were created.
 */
export async function attachPendingPreStartStops(
  organizationId: string,
  siteId: string,
  date: string,
  meetingId: string
): Promise<number> {
  const checks = await getFirestore()
    .collection(`organizations/${organizationId}/pre_start_checks`)
    .where("siteId", "==", siteId)
    .where("date", "==", date)
    .get();
  let created = 0;
  for (const doc of checks.docs) {
    const data = doc.data();
    if (data.outcome !== "stop" || data.concernId) continue;
    await createStopConcern(organizationId, meetingId, doc.ref, data);
    created++;
  }
  return created;
}

/**
 * The caller's own check for today: the questions they must answer (always
 * re-derived server-side) and, if they have already submitted today, that
 * submission.
 */
export const getMyPreStartCheck = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const worker = await requireActiveWorkerRole(request, organizationId);
  const date = todaysMeetingDate();

  const existing = await getFirestore()
    .doc(
      `organizations/${organizationId}/pre_start_checks/` +
        preStartCheckId(worker.uid, date)
    )
    .get();

  const context = await workerContext(
    organizationId,
    worker.uid,
    worker.siteIds,
    date
  );
  const site = (
    await getFirestore()
      .doc(`organizations/${organizationId}/sites/${context.siteId}`)
      .get()
  ).data();

  return {
    organizationId,
    date,
    site: {
      id: context.siteId,
      name: typeof site?.name === "string" ? site.name : "",
    },
    questions: existing.exists ?
      [] :
      await resolveQuestions(organizationId, context),
    submission: existing.exists ?
      submissionView(existing.id, existing.data() ?? {}) :
      null,
  };
});

/**
 * Submits the caller's check for today. `answers` must contain exactly one
 * entry per question `getMyPreStartCheck` returns — the server re-derives
 * that list, so a client can neither skip a question nor invent one — each
 * `{questionId, answer: "yes" | "fixed" | "cannotFix", note?}`, with a note
 * required for any answer other than "yes". The outcome is computed here,
 * never accepted from the client.
 */
export const submitPreStartCheck = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const worker = await requireActiveWorkerRole(request, organizationId);
  const date = todaysMeetingDate();
  // A check saved on the phone with no signal says which day its questions
  // were for; if the signal only came back the next day, it must not count
  // as that day's check.
  const forDate = (request.data ?? {}).forDate;
  if (typeof forDate === "string" && forDate && forDate !== date) {
    throw new HttpsError(
      "failed-precondition",
      `This Pre-Start Check was for ${forDate} and could not be sent that ` +
        "day. Please do today's check."
    );
  }
  const db = getFirestore();
  const checkRef = db.doc(
    `organizations/${organizationId}/pre_start_checks/` +
      preStartCheckId(worker.uid, date)
  );
  if ((await checkRef.get()).exists) {
    throw new HttpsError(
      "already-exists",
      "You have already completed today's Pre-Start Check."
    );
  }

  const context = await workerContext(
    organizationId,
    worker.uid,
    worker.siteIds,
    date
  );
  const questions = await resolveQuestions(organizationId, context);

  const rawAnswers = (request.data ?? {}).answers;
  if (!Array.isArray(rawAnswers)) {
    throw new HttpsError("invalid-argument", "answers is required.");
  }
  const byQuestion = new Map<string, {answer: Answer; note: string | null}>();
  for (const raw of rawAnswers) {
    if (typeof raw !== "object" || raw === null) {
      throw new HttpsError(
        "invalid-argument",
        "Each answer must be an object."
      );
    }
    const {questionId, answer, note} = raw as Record<string, unknown>;
    if (typeof questionId !== "string" || !questionId) {
      throw new HttpsError("invalid-argument", "questionId is required.");
    }
    if (!(ANSWERS as readonly unknown[]).includes(answer)) {
      throw new HttpsError(
        "invalid-argument",
        "answer must be one of: " + ANSWERS.join(", ")
      );
    }
    const trimmedNote = typeof note === "string" ? note.trim() : "";
    if (answer !== "yes" && !trimmedNote) {
      throw new HttpsError(
        "invalid-argument",
        "Please say what you fixed, or what is wrong, for every \"No\" answer."
      );
    }
    if (trimmedNote.length > MAX_NOTE_LENGTH) {
      throw new HttpsError(
        "invalid-argument",
        `Notes must be ${MAX_NOTE_LENGTH} characters or fewer.`
      );
    }
    if (byQuestion.has(questionId)) {
      throw new HttpsError(
        "invalid-argument",
        "Each question is answered once."
      );
    }
    byQuestion.set(questionId, {
      answer: answer as Answer,
      note: trimmedNote || null,
    });
  }
  const questionIds = new Set(questions.map((q) => q.id));
  if (
    byQuestion.size !== questions.length ||
    [...byQuestion.keys()].some((id) => !questionIds.has(id))
  ) {
    throw new HttpsError(
      "failed-precondition",
      "Today's questions have changed. Please reopen the check and try again."
    );
  }

  const answers = questions.map((question) => {
    const given = byQuestion.get(question.id);
    return {
      questionId: question.id,
      prompt: question.prompt,
      kind: question.kind,
      risk: question.risk,
      answer: given?.answer ?? "yes",
      note: given?.note ?? null,
    };
  });
  const outcome: PreStartOutcome =
    answers.some((a) => a.answer === "cannotFix") ? "stop" :
      answers.some((a) => a.answer === "fixed") ? "goCorrected" :
        "go";

  const check = {
    organizationId,
    workerUid: worker.uid,
    workerName: worker.name,
    siteId: context.siteId,
    projectId: context.projectId,
    activityIds: context.activityIds,
    date,
    outcome,
    answers,
    issueCount: answers.filter((a) => a.answer !== "yes").length,
    meetingId: null as string | null,
    concernId: null as string | null,
    submittedAt: FieldValue.serverTimestamp(),
    createdAt: FieldValue.serverTimestamp(),
  };
  // `create` (not `set`) so two simultaneous submissions cannot both land.
  await checkRef.create(check);

  if (outcome === "stop") {
    if (context.meetingId) {
      await createStopConcern(
        organizationId,
        context.meetingId,
        checkRef,
        check
      );
    }
    const foremen = await foremenAtSite(organizationId, context.siteId);
    await Promise.all(foremen.map((recipientUid) => createNotification({
      organizationId,
      recipientUid,
      type: "safetyMeeting",
      title: `Pre-Start STOP: ${worker.name || "a worker"}`,
      message: `${worker.name || "A worker"} could not safely start work ` +
        "today. Check their Pre-Start answers before work begins.",
      relatedEntityType: "preStartCheck",
      relatedEntityId: checkRef.id,
    })));
  }

  return {
    id: checkRef.id,
    organizationId,
    outcome,
    issueCount: check.issueCount,
  };
});

/**
 * Today's Pre-Start results for every worker assigned to an ACTIVE activity
 * at [siteId] — the same crew `getSiteCrewReadiness` lists — with `outcome`
 * null for a worker who has not done their check yet. Callable by a Foreman
 * of that site, any Site Manager of the organization, or an Admin.
 */
export const getSiteCrewPreStartChecks = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const siteId = requireString(request, "siteId");
  const uid = request.auth?.uid;
  if (!uid) throw denied();

  const db = getFirestore();
  const profile = (await db.doc(`users/${uid}`).get()).data();
  if (!profile || profile.accountStatus !== "active") throw denied();
  if (profile.platformRole !== "admin") {
    const membership = (
      await db.doc(`users/${uid}/memberships/${organizationId}`).get()
    ).data();
    if (!membership || membership.status !== "active") throw denied();
    const isSiteManager = membership.role === "siteManager";
    const isSiteForeman = membership.role === "foreman" &&
      Array.isArray(membership.siteIds) &&
      membership.siteIds.includes(siteId);
    if (!isSiteManager && !isSiteForeman) throw denied();
  }

  const site = (
    await db.doc(`organizations/${organizationId}/sites/${siteId}`).get()
  ).data();
  if (!site || site.organizationId !== organizationId) {
    throw new HttpsError("failed-precondition", "That site does not exist.");
  }

  const activities = await db
    .collection(`organizations/${organizationId}/activities`)
    .where("siteId", "==", siteId)
    .where("status", "==", "active")
    .get();
  const assignmentSnapshots = await Promise.all(
    activities.docs.map((activity) =>
      activity.ref.collection("assignments").get()
    )
  );
  const workerIds = new Set<string>();
  for (const snapshot of assignmentSnapshots) {
    for (const doc of snapshot.docs) {
      const workerUid = doc.data().uid;
      if (typeof workerUid === "string" && workerUid && workerUid !== uid) {
        workerIds.add(workerUid);
      }
    }
  }

  const date = todaysMeetingDate();
  const workers = await Promise.all([...workerIds].sort().map(async (id) => {
    const [user, checkSnapshot] = await Promise.all([
      db.doc(`users/${id}`).get(),
      db.doc(
        `organizations/${organizationId}/pre_start_checks/` +
          preStartCheckId(id, date)
      ).get(),
    ]);
    const check = checkSnapshot.data();
    const answers: Array<Record<string, unknown>> =
      check && Array.isArray(check.answers) ? check.answers : [];
    return {
      workerId: id,
      workerName: typeof user.data()?.name === "string" ?
        user.data()?.name :
        "",
      outcome: check?.outcome ?? null,
      // Only the "no" answers — what the Foreman needs to act on.
      issues: answers
        .filter((a) => a.answer !== "yes")
        .map((a) => ({
          prompt: a.prompt ?? "",
          answer: a.answer,
          note: a.note ?? null,
        })),
    };
  }));

  return {organizationId, siteId, date, workers};
});
