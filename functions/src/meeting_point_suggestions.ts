/**
 * Which Safety Meeting Points to suggest for a Daily Safety Meeting, and
 * why.
 *
 * Used both by `getMeetingPointSuggestions` (what the Foreman sees before
 * starting the meeting) and by `createDailySafetyMeeting` (the snapshot
 * stored on the meeting as `suggestedPointIds`/`suggestionReasons`), so
 * the list shown and the list recorded always come from the same rules.
 *
 * WHAT A SUGGESTION IS BASED ON
 *
 * Only data that already exists — there is no daily work schedule, so
 * "today's activities" are the activities the meeting covers (before the
 * meeting: every active activity at the site, the same set the start
 * screen shows).
 *
 * 1. ACTIVITY — the point lists one of today's activities in
 *    `applicableActivities`.
 * 2. SAFETY REQUIREMENT — one of the point's `applicableRisks` matches the
 *    name or category of an active Safety Requirement scoped to one of
 *    today's activities.
 * 3. RISK ASSESSMENT — one of the point's `applicableRisks` matches a
 *    hazard, or the feature of work, of an accepted risk assessment (AHA)
 *    of the site that covers one of today's activities (or the whole site).
 * 4. GENERAL — a point tied to no activity at all, with no matched risk,
 *    is still suggested as general guidance (this was the only rule
 *    before activity matching, so nothing previously suggested drops out).
 *
 * `applicableRisks` is free text an administrator typed (e.g. "Falls,
 * Electrocution"), so matching ignores case, punctuation and plural "s",
 * and accepts one phrase containing the other ("fall" matches "Falls from
 * height").
 *
 * A point whose `applicableActivities` names only OTHER activities, and
 * whose risks match nothing, is not suggested — exactly as before. The
 * Foreman can still add any active point from the library.
 */

import {getFirestore} from "firebase-admin/firestore";

/** One suggested point and the reasons it was suggested. */
export interface PointSuggestion {
  pointId: string;
  reasons: string[];
}

/** The point fields suggestion reads. */
export interface SuggestionPoint {
  id: string;
  title: string;
  applicableActivities: string[];
  applicableRisks: string[];
}

/** An activity-scoped Safety Requirement, as suggestion reads it. */
export interface SuggestionRequirement {
  name: string;
  category: string;
  risk: string;
}

/** An accepted risk assessment (AHA), as suggestion reads it. */
export interface SuggestionAha {
  featureOfWork: string;
  hazards: string[];
}

/** Everything a suggestion is computed from. */
export interface SuggestionInput {
  points: SuggestionPoint[];
  activities: {id: string; name: string}[];
  requirements: SuggestionRequirement[];
  ahas: SuggestionAha[];
}

const RISK_WEIGHT: Record<string, number> = {high: 3, medium: 2, low: 1};

/**
 * Lower-cases [text], drops punctuation and a trailing plural "s" from each
 * word, so "Falls!" and "fall" compare equal.
 *
 * @param {string} text the text to normalize.
 * @return {string} the normalized phrase.
 */
function normalize(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9\s]/g, " ")
    .split(/\s+/)
    .filter((word) => word.length > 0)
    .map((word) => word.length > 3 && word.endsWith("s") ?
      word.slice(0, -1) :
      word)
    .join(" ");
}

/**
 * Whether a point's risk phrase [risk] matches [text] — equal, or one
 * contained in the other as whole words.
 *
 * @param {string} risk one of the point's `applicableRisks`.
 * @param {string} text a requirement name/category, hazard or feature of
 * work.
 * @return {boolean} whether they match.
 */
export function riskMatches(risk: string, text: string): boolean {
  const a = normalize(risk);
  const b = normalize(text);
  if (!a || !b) return false;
  return ` ${b} `.includes(` ${a} `) || ` ${a} `.includes(` ${b} `);
}

/**
 * Ranks the points worth suggesting for [input], strongest first, each
 * with plain-language reasons. Pure — no Firestore access — so the rules
 * can be tested directly.
 *
 * @param {SuggestionInput} input the points and today's context.
 * @return {PointSuggestion[]} the suggested points, best first.
 */
export function rankSuggestions(input: SuggestionInput): PointSuggestion[] {
  const activityNames = new Map(input.activities.map((a) => [a.id, a.name]));
  const scored: {pointId: string; title: string; score: number;
    reasons: string[];}[] = [];

  for (const point of input.points) {
    const reasons: string[] = [];
    let score = 0;

    const matchedActivities = point.applicableActivities
      .filter((id) => activityNames.has(id))
      .map((id) => activityNames.get(id) as string);
    if (matchedActivities.length > 0) {
      // Named for today's work directly — the strongest evidence.
      reasons.push(`Today's work: ${matchedActivities.join(", ")}`);
      score += 4;
    }

    for (const risk of point.applicableRisks) {
      const requirement = input.requirements.find((r) =>
        riskMatches(risk, r.name) || riskMatches(risk, r.category)
      );
      if (requirement) {
        const level = requirement.risk ? ` (${requirement.risk} risk)` : "";
        reasons.push(
          `Risk "${risk}" — safety requirement ` +
            `"${requirement.name}"${level}`
        );
        score += RISK_WEIGHT[requirement.risk] ?? 1;
      }
      const aha = input.ahas.find((a) =>
        riskMatches(risk, a.featureOfWork) ||
        a.hazards.some((hazard) => riskMatches(risk, hazard))
      );
      if (aha) {
        reasons.push(
          `Risk "${risk}" — risk assessment "${aha.featureOfWork}"`
        );
        score += 2;
      }
    }

    if (reasons.length === 0 && point.applicableActivities.length === 0) {
      reasons.push("General safety point for any work");
    }
    if (reasons.length === 0) continue;
    scored.push({pointId: point.id, title: point.title, score, reasons});
  }

  scored.sort((a, b) =>
    b.score - a.score || a.title.localeCompare(b.title)
  );
  return scored.map(({pointId, reasons}) => ({pointId, reasons}));
}

/**
 * Strings in [value], or an empty list when it is not a list.
 *
 * @param {unknown} value a stored field.
 * @return {string[]} its string entries.
 */
function strings(value: unknown): string[] {
  return Array.isArray(value) ?
    value.filter((item): item is string => typeof item === "string") :
    [];
}

/**
 * Loads today's context for a meeting at [siteId] covering [activityIds]
 * and ranks the organization's active meeting points for it.
 *
 * @param {string} organizationId the organization.
 * @param {string} siteId the meeting's site.
 * @param {string[]} activityIds the activities the meeting covers.
 * @return {Promise<PointSuggestion[]>} the suggested points, best first.
 */
export async function suggestMeetingPoints(
  organizationId: string,
  siteId: string,
  activityIds: string[]
): Promise<PointSuggestion[]> {
  const db = getFirestore();
  const org = `organizations/${organizationId}`;
  const activityIdSet = new Set(activityIds);

  const [pointDocs, activityDocs, requirementDocs, ahaDocs] =
    await Promise.all([
      db.collection(`${org}/safety_meeting_points`)
        .where("status", "==", "active")
        .get(),
      Promise.all(activityIds.map((id) =>
        db.doc(`${org}/activities/${id}`).get()
      )),
      db.collection(`${org}/safety_requirements`)
        .where("status", "==", "active")
        .get(),
      db.collection(`${org}/risk_assessments`)
        .where("siteId", "==", siteId)
        .where("status", "==", "accepted")
        .get(),
    ]);

  return rankSuggestions({
    points: pointDocs.docs.map((doc) => ({
      id: doc.id,
      title: typeof doc.data().title === "string" ? doc.data().title : "",
      applicableActivities: strings(doc.data().applicableActivities),
      applicableRisks: strings(doc.data().applicableRisks),
    })),
    activities: activityDocs
      .filter((doc) => doc.exists)
      .map((doc) => ({
        id: doc.id,
        name: typeof doc.data()?.name === "string" ? doc.data()?.name : doc.id,
      })),
    requirements: requirementDocs.docs
      .map((doc) => doc.data())
      .filter((data) =>
        typeof data.activityId === "string" &&
        activityIdSet.has(data.activityId)
      )
      .map((data) => ({
        name: typeof data.name === "string" ? data.name : "",
        category: typeof data.category === "string" ? data.category : "",
        risk: typeof data.risk === "string" ? data.risk : "",
      })),
    ahas: ahaDocs.docs
      .map((doc) => doc.data())
      .filter((data) => {
        const covered = strings(data.activityIds);
        return covered.length === 0 ||
          covered.some((id) => activityIdSet.has(id));
      })
      .map((data) => ({
        featureOfWork:
          typeof data.featureOfWork === "string" ? data.featureOfWork : "",
        hazards: (Array.isArray(data.steps) ? data.steps : [])
          .flatMap((step: {hazards?: unknown}) => strings(step?.hazards)),
      })),
  });
}
