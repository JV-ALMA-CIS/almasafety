/**
 * "Needed today" — the smallest set of safety learning a worker or Foreman
 * must complete before today's Daily Safety Meeting.
 *
 * WHY THIS EXISTS
 *
 * A Site Manager may tick "Before meeting" on dozens of lessons across many
 * requirements. Requiring ALL of them before anyone can attend would block
 * the whole crew on day one, and workers do not all have the same time
 * before the meeting. So instead of "every Before-meeting lesson", each
 * person gets a small plan per day:
 *
 *  - ONE lesson per activity they are doing today — the highest-risk
 *    incomplete "Before meeting" lesson from requirements scoped to that
 *    activity; and
 *  - ONE "general" lesson — the highest-risk incomplete "Before meeting"
 *    lesson from requirements NOT scoped to an activity (site-, project- or
 *    organization-wide).
 *
 * Everything else stays required ("When you can") and is picked up one a
 * day on later days, so the backlog drains steadily without ever blocking a
 * morning. Only the plan blocks attendance — see `outstandingNeededToday`.
 *
 * WHY THE PLAN IS STORED
 *
 * At `organizations/{orgId}/daily_learning_plans/{uid}_{date}`, so it stays
 * fixed for the day: completing today's lesson does not pull the next one
 * into today, and a worker who does TOMORROW's lesson the evening before
 * (see `neededTomorrow`) finds it already done in the morning. Activities
 * added to someone's work after the plan was made are filled in on the
 * next read rather than ignored. Clients never read these documents — the
 * callables are the only path.
 */

import {FieldValue, getFirestore} from "firebase-admin/firestore";
import {
  classifyRequirementLessons,
  findTodaysMeeting,
  readMembership,
  requirementApplies,
  resolveLearningItemsById,
  scopeOfAssignments,
  workerAssignments,
} from "./worker_learning_callable";

const RISK_RANK: Record<string, number> = {high: 0, medium: 1, low: 2};

/** Where and on what a person works today. */
export interface TodaysContext {
  role: "worker" | "foreman" | null;
  siteId: string | null;
  projectId: string | null;
  activityIds: string[];
  meetingId: string | null;
}

/**
 * A specific meeting someone is being checked against — e.g. the meeting a
 * Foreman is marking attendance on, which may be an older in-progress
 * meeting rather than today's. `id` is null for a meeting about to be
 * created.
 */
export interface MeetingHint {
  id: string | null;
  siteId: string;
  activityIds: string[];
}

/** One lesson in a plan, with its title for display. */
export interface PlannedLesson {
  learningId: string;
  title: string;
  activityId: string | null;
}

/**
 * The calendar day after [date] (`YYYY-MM-DD`).
 *
 * @param {string} date a `YYYY-MM-DD` day.
 * @return {string} the next day.
 */
export function nextDate(date: string): string {
  const next = new Date(`${date}T00:00:00Z`);
  next.setUTCDate(next.getUTCDate() + 1);
  return next.toISOString().slice(0, 10);
}

/**
 * Today's site, project and activities for [uid].
 *
 * - A WORKER works at today's meeting site among their membership sites if
 *   a meeting has started, otherwise the first of their sites they hold an
 *   activity assignment at, otherwise their first site; their activities
 *   are their own assignments at that site — or, with none there, today's
 *   meeting's activities.
 * - A FOREMAN works at the site of their own meeting today, if started
 *   (with that meeting's activities), otherwise their first site (with all
 *   of its active activities — they lead every activity there).
 * - Anyone else has no daily plan.
 *
 * When [meetingHint] is given, that meeting stands in for "today's
 * meeting" in both cases.
 *
 * @param {string} organizationId the organization.
 * @param {string} uid the person.
 * @param {string} date today.
 * @param {MeetingHint} [meetingHint] the meeting being checked against.
 * @return {Promise<TodaysContext>} today's context.
 */
export async function resolveTodaysContext(
  organizationId: string,
  uid: string,
  date: string,
  meetingHint?: MeetingHint
): Promise<TodaysContext> {
  const db = getFirestore();
  const membership = await readMembership(organizationId, uid);
  const empty: TodaysContext = {
    role: null,
    siteId: null,
    projectId: null,
    activityIds: [],
    meetingId: null,
  };
  if (membership.role !== "worker" && membership.role !== "foreman") {
    return empty;
  }
  const role = membership.role;
  if (membership.siteIds.length === 0) return {...empty, role};

  const sorted = [...membership.siteIds].sort();
  let siteId: string;
  let activityIds: string[];
  const meeting = meetingHint ?? toHint(await findTodaysMeeting(
    organizationId,
    membership.siteIds,
    date,
    role === "foreman" ? uid : null
  ));
  const meetingId = meeting?.id ?? null;

  if (role === "foreman") {
    if (meeting) {
      siteId = meeting.siteId;
      activityIds = meeting.activityIds;
    } else {
      siteId = sorted[0];
      const active = await db
        .collection(`organizations/${organizationId}/activities`)
        .where("siteId", "==", siteId)
        .where("status", "==", "active")
        .get();
      activityIds = active.docs.map((doc) => doc.id);
    }
  } else {
    const assignments = await workerAssignments(organizationId, uid);
    if (meeting) {
      siteId = meeting.siteId;
    } else {
      siteId = sorted.find((id) =>
        assignments.some((a) => a.siteId === id)
      ) ?? sorted[0];
    }
    activityIds = [
      ...scopeOfAssignments(
        assignments.filter((a) => a.siteId === siteId)
      ).activityIds,
    ];
    // A worker with no activity assignment at the site still attends its
    // meeting: when we don't know what they do today, assume the
    // meeting's work rather than none.
    if (activityIds.length === 0 && meeting) {
      activityIds = meeting.activityIds;
    }
  }

  const site = (
    await db.doc(`organizations/${organizationId}/sites/${siteId}`).get()
  ).data();
  const projectId = typeof site?.projectId === "string" && site.projectId ?
    site.projectId :
    null;
  return {
    role,
    siteId,
    projectId,
    activityIds: [...new Set(activityIds)].sort(),
    meetingId,
  };
}

/**
 * A stored meeting as a [MeetingHint].
 *
 * @param {FirebaseFirestore.DocumentSnapshot | null} doc the meeting.
 * @return {MeetingHint | null} the hint, or null without a meeting.
 */
export function toHint(
  doc: FirebaseFirestore.DocumentSnapshot | null
): MeetingHint | null {
  const data = doc?.data();
  if (!doc || !data || typeof data.siteId !== "string") return null;
  const ids = data.activityIds;
  return {
    id: doc.id,
    siteId: data.siteId,
    activityIds: Array.isArray(ids) ?
      ids.filter((id: unknown): id is string => typeof id === "string") :
      [],
  };
}

/** One "Before meeting" lesson candidate, in priority order. */
interface Candidate {
  learningId: string;
  activityId: string | null;
  rank: number;
  requirementName: string;
  position: number;
}

/**
 * Every "Before meeting" lesson that applies to [context], ranked: highest
 * requirement risk first, then requirement name, then the lesson's position
 * on its requirement.
 *
 * @param {string} organizationId the organization.
 * @param {TodaysContext} context today's context.
 * @return {Promise<Candidate[]>} the ranked candidates.
 */
async function rankedCandidates(
  organizationId: string,
  context: TodaysContext
): Promise<Candidate[]> {
  if (!context.siteId) return [];
  const requirements = await getFirestore()
    .collection(`organizations/${organizationId}/safety_requirements`)
    .where("status", "==", "active")
    .get();
  const scope = {
    siteIds: new Set([context.siteId]),
    activityIds: new Set(context.activityIds),
    projectIds: new Set(context.projectId ? [context.projectId] : []),
  };

  const candidates: Candidate[] = [];
  for (const doc of requirements.docs) {
    const data = doc.data();
    if (!requirementApplies(data, scope)) continue;
    const activityId =
      typeof data.activityId === "string" && data.activityId ?
        data.activityId :
        null;
    const rank = RISK_RANK[typeof data.risk === "string" ? data.risk : ""] ??
      3;
    const requirementName = typeof data.name === "string" ? data.name : "";
    classifyRequirementLessons(data)
      .filter((lesson) => lesson.gates)
      .forEach((lesson, position) => candidates.push({
        learningId: lesson.id,
        activityId,
        rank,
        requirementName,
        position,
      }));
  }
  candidates.sort((a, b) =>
    a.rank - b.rank ||
    a.requirementName.localeCompare(b.requirementName) ||
    a.position - b.position ||
    a.learningId.localeCompare(b.learningId)
  );
  return candidates;
}

/**
 * Which of [ids] [uid] has completed.
 *
 * @param {string} organizationId the organization.
 * @param {string} uid the person.
 * @param {string[]} ids learning ids.
 * @return {Promise<Set<string>>} the completed ones.
 */
async function completedOf(
  organizationId: string,
  uid: string,
  ids: string[]
): Promise<Set<string>> {
  const db = getFirestore();
  const unique = [...new Set(ids)];
  const records = await Promise.all(unique.map((id) =>
    db.doc(
      `organizations/${organizationId}/worker_learning_records/${uid}_${id}`
    ).get()
  ));
  const completed = new Set<string>();
  records.forEach((snapshot, index) => {
    if (snapshot.data()?.status === "completed") completed.add(unique[index]);
  });
  return completed;
}

/** A stored plan's picks. */
interface PlanPicks {
  byActivity: Record<string, string | null>;
  general: string | null;
}

/**
 * Loads [uid]'s plan for [date], creating it — or filling in activities it
 * does not cover yet, and replacing picks that no longer qualify — from
 * [context]. A lesson already completed, inactive, or in [exclude] (e.g.
 * today's plan, when building tomorrow's) is never picked.
 *
 * @param {string} organizationId the organization.
 * @param {string} uid the person.
 * @param {string} date the plan's day.
 * @param {TodaysContext} context the person's context.
 * @param {Set<string>} exclude lessons not to pick.
 * @return {Promise<PlanPicks>} the plan's picks.
 */
async function ensurePlan(
  organizationId: string,
  uid: string,
  date: string,
  context: TodaysContext,
  exclude: Set<string> = new Set()
): Promise<PlanPicks> {
  const ref = getFirestore().doc(
    `organizations/${organizationId}/daily_learning_plans/${uid}_${date}`
  );
  const stored = (await ref.get()).data();
  const byActivity: Record<string, string | null> =
    stored && typeof stored.byActivity === "object" && stored.byActivity ?
      {...stored.byActivity} :
      {};
  const hasGeneral = stored !== undefined && "general" in stored;
  let general: string | null = hasGeneral ? stored.general ?? null : null;

  // Re-checked on every read, not only when the plan is first made: if a
  // Site Manager turns "Before meeting" off on a planned lesson (or
  // deactivates it) during the day, that pick no longer counts and its
  // slot is planned again. A completed pick stays — it is today's lesson,
  // done.
  const candidates = await rankedCandidates(organizationId, context);
  const active = await resolveLearningItemsById(
    organizationId,
    new Set(candidates.map((c) => c.learningId))
  );
  const stillValid = (activityId: string | null, id: string | null) =>
    id === null || (active.has(id) && candidates.some((c) =>
      c.activityId === activityId && c.learningId === id
    ));

  const toPick = context.activityIds.filter((activityId) =>
    !(activityId in byActivity) ||
    !stillValid(activityId, byActivity[activityId])
  );
  const pickGeneral = !hasGeneral || !stillValid(null, general);
  if (stored && toPick.length === 0 && !pickGeneral) {
    return {byActivity, general};
  }

  for (const activityId of toPick) delete byActivity[activityId];
  if (pickGeneral) general = null;

  const completed = await completedOf(
    organizationId,
    uid,
    candidates.map((c) => c.learningId)
  );
  const taken = new Set<string>([
    ...exclude,
    ...Object.values(byActivity).filter((id): id is string => id !== null),
    ...(general ? [general] : []),
  ]);
  const pick = (activityId: string | null): string | null => {
    const found = candidates.find((c) =>
      c.activityId === activityId &&
      active.has(c.learningId) &&
      !completed.has(c.learningId) &&
      !taken.has(c.learningId)
    );
    if (!found) return null;
    taken.add(found.learningId);
    return found.learningId;
  };

  for (const activityId of toPick) byActivity[activityId] = pick(activityId);
  if (pickGeneral) general = pick(null);

  await ref.set({
    organizationId,
    uid,
    date,
    siteId: context.siteId,
    byActivity,
    general,
    updatedAt: FieldValue.serverTimestamp(),
  });
  return {byActivity, general};
}

/**
 * The lessons [picks] holds for [context]'s activities (plus the general
 * one), resolved to active items with titles.
 *
 * @param {string} organizationId the organization.
 * @param {PlanPicks} picks a plan.
 * @param {TodaysContext} context today's context.
 * @return {Promise<PlannedLesson[]>} the planned lessons.
 */
async function plannedLessons(
  organizationId: string,
  picks: PlanPicks,
  context: TodaysContext
): Promise<PlannedLesson[]> {
  const entries: {learningId: string; activityId: string | null}[] = [];
  for (const activityId of context.activityIds) {
    const id = picks.byActivity[activityId];
    if (id) entries.push({learningId: id, activityId});
  }
  if (picks.general) {
    entries.push({learningId: picks.general, activityId: null});
  }
  const items = await resolveLearningItemsById(
    organizationId,
    new Set(entries.map((e) => e.learningId))
  );
  return entries
    .filter((e) => items.has(e.learningId))
    .map((e) => ({
      ...e,
      title: typeof items.get(e.learningId)?.title === "string" ?
        items.get(e.learningId)?.title :
        e.learningId,
    }));
}

/**
 * [uid]'s "Needed today" lessons (completed or not), and the context they
 * were resolved for.
 *
 * @param {string} organizationId the organization.
 * @param {string} uid the person.
 * @param {string} date today.
 * @param {MeetingHint} [meetingHint] the meeting being checked against.
 * @return {Promise<{context: TodaysContext, lessons: PlannedLesson[]}>} the
 * plan.
 */
export async function neededToday(
  organizationId: string,
  uid: string,
  date: string,
  meetingHint?: MeetingHint
): Promise<{context: TodaysContext; lessons: PlannedLesson[]}> {
  const context = await resolveTodaysContext(
    organizationId,
    uid,
    date,
    meetingHint
  );
  if (!context.role || !context.siteId) return {context, lessons: []};
  const picks = await ensurePlan(organizationId, uid, date, context);
  return {
    context,
    lessons: await plannedLessons(organizationId, picks, context),
  };
}

/**
 * The "Needed today" lessons [uid] has NOT completed yet — the only
 * learning that blocks them at today's meeting.
 *
 * @param {string} organizationId the organization.
 * @param {string} uid the person.
 * @param {string} date today.
 * @param {MeetingHint} [meetingHint] the meeting being checked against.
 * @return {Promise<PlannedLesson[]>} the outstanding lessons.
 */
export async function outstandingNeededToday(
  organizationId: string,
  uid: string,
  date: string,
  meetingHint?: MeetingHint
): Promise<PlannedLesson[]> {
  const {lessons} = await neededToday(organizationId, uid, date, meetingHint);
  const completed = await completedOf(
    organizationId,
    uid,
    lessons.map((l) => l.learningId)
  );
  return lessons.filter((l) => !completed.has(l.learningId));
}

/**
 * Tomorrow's plan, built now (and stored) so a worker can get ahead the
 * evening before: same context as today, never repeating today's lessons.
 *
 * @param {string} organizationId the organization.
 * @param {string} uid the person.
 * @param {string} date today.
 * @return {Promise<PlannedLesson[]>} tomorrow's planned lessons.
 */
export async function neededTomorrow(
  organizationId: string,
  uid: string,
  date: string
): Promise<PlannedLesson[]> {
  const today = await neededToday(organizationId, uid, date);
  if (!today.context.role || !today.context.siteId) return [];
  const picks = await ensurePlan(
    organizationId,
    uid,
    nextDate(date),
    today.context,
    new Set(today.lessons.map((l) => l.learningId))
  );
  return plannedLessons(organizationId, picks, today.context);
}
