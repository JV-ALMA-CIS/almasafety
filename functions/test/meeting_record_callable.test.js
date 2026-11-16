/**
 * Daily Safety Meetings — Milestone 1 ("a meeting record you can trust"):
 *
 * - the suggested-points snapshot (`suggestedPointIds`/`suggestionReasons`)
 *   stored at creation and never overwritten by later edits;
 * - `getMeetingPointSuggestions` and the suggestion rules (activities,
 *   activity-scoped Safety Requirements, accepted risk assessments);
 * - the `audit_logs` trail for meeting events;
 * - `concernCount`, including meetings started before it existed;
 * - corrective actions raised from a concern added after completion, and
 *   the meeting <-> corrective action link in both directions;
 * - the Africa/Nairobi meeting date.
 *
 * Runs each callable's handler via `.run(request)` against the Firestore
 * emulator, like `daily_safety_meeting_callable.test.js`. Requires JDK 21+
 * (see `test/README.md`).
 */

const {initializeApp, getApps, deleteApp} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");

const PROJECT_ID = "jva-safety-rules-test";
const ORG_A = "org-alpha";
const ORG_B = "org-beta";

let app;
let db;
let meetings;
let createCorrectiveAction;
let todaysMeetingDate;
let rankSuggestions;
let riskMatches;
let submitPreStartCheck;

beforeAll(() => {
  process.env.GCLOUD_PROJECT = PROJECT_ID;
  if (!process.env.FIRESTORE_EMULATOR_HOST) {
    process.env.FIRESTORE_EMULATOR_HOST = "127.0.0.1:8080";
  }
  app = getApps()[0] ?? initializeApp({projectId: PROJECT_ID});
  db = getFirestore(app);

  meetings = require("../lib/daily_safety_meeting_callable");
  ({createCorrectiveAction} = require("../lib/corrective_action_callable"));
  ({todaysMeetingDate} = require("../lib/worker_learning_callable"));
  ({rankSuggestions, riskMatches} =
    require("../lib/meeting_point_suggestions"));
  ({submitPreStartCheck} = require("../lib/pre_start_check_callable"));
});

afterAll(async () => {
  if (app) await deleteApp(app);
});

beforeEach(async () => {
  const collections = await db.listCollections();
  await Promise.all(collections.map((c) => db.recursiveDelete(c)));
});

function callRequest(uid, data) {
  return {auth: uid ? {uid, token: {}} : undefined, data, rawRequest: {}};
}

async function seedUser(uid, organizationId, role, siteIds, name = uid) {
  await db.doc(`users/${uid}`).set({
    uid,
    name,
    email: `${uid}@example.com`,
    accountStatus: "active",
  });
  await db.doc(`users/${uid}/memberships/${organizationId}`).set({
    organizationId,
    role,
    siteIds,
    status: "active",
    createdAt: new Date(),
  });
}

async function seedSite(orgId, id = "site-1") {
  await db.doc(`organizations/${orgId}/sites/${id}`).set({
    organizationId: orgId,
    projectId: "project-1",
    name: `Site ${id}`,
    status: "active",
  });
}

async function seedActivity(orgId, id, name, siteId = "site-1") {
  await db.doc(`organizations/${orgId}/activities/${id}`).set({
    organizationId: orgId,
    projectId: "project-1",
    siteId,
    name,
    code: id,
    status: "active",
  });
}

async function seedPoint(orgId, id, overrides = {}) {
  await db.doc(`organizations/${orgId}/safety_meeting_points/${id}`).set({
    organizationId: orgId,
    title: id,
    category: "general",
    applicableActivities: [],
    applicableRisks: [],
    status: "active",
    ...overrides,
  });
}

async function seedMeeting(orgId, id, overrides = {}) {
  await db.doc(`organizations/${orgId}/daily_safety_meetings/${id}`).set({
    organizationId: orgId,
    projectId: "project-1",
    siteId: "site-1",
    date: "2026-09-01",
    foremanId: "foreman-a",
    activityIds: ["act-roof"],
    meetingPointIds: ["point-height"],
    status: "inProgress",
    concerns: [],
    correctiveActionIds: [],
    createdAt: new Date(),
    ...overrides,
  });
}

async function seedConcern(orgId, meetingId, id) {
  await db
    .doc(
      `organizations/${orgId}/daily_safety_meetings/${meetingId}` +
        `/concerns/${id}`
    )
    .set({
      meetingId,
      organizationId: orgId,
      siteId: "site-1",
      description: "Loose ladder",
      category: "equipment",
      reportedBy: "foreman-a",
      status: "open",
      createdAt: new Date(),
    });
}

async function meeting(orgId, id) {
  return (
    await db.doc(`organizations/${orgId}/daily_safety_meetings/${id}`).get()
  ).data();
}

async function auditEntries(meetingId) {
  const snapshot = await db
    .collection("audit_logs")
    .where("targetDocId", "==", meetingId)
    .get();
  return snapshot.docs.map((doc) => doc.data());
}

/** A foreman at site-1 with a roofing day ready to start. */
async function seedRoofingDay() {
  await seedSite(ORG_A);
  await seedUser("foreman-a", ORG_A, "foreman", ["site-1"]);
  await seedActivity(ORG_A, "act-roof", "Roofing");
  await seedActivity(ORG_A, "act-paint", "Painting");
  await seedPoint(ORG_A, "point-height", {
    title: "Working at Height",
    applicableActivities: ["act-roof"],
  });
  await seedPoint(ORG_A, "point-electric", {
    title: "Live cables",
    applicableActivities: ["act-wiring"],
    applicableRisks: ["Electrocution"],
  });
  await seedPoint(ORG_A, "point-falls", {
    title: "Fall arrest",
    applicableActivities: ["act-other"],
    applicableRisks: ["Falls"],
  });
  await seedPoint(ORG_A, "point-ppe", {title: "PPE"});
  await seedPoint(ORG_A, "point-unrelated", {
    title: "Excavation",
    applicableActivities: ["act-dig"],
  });
}

describe("meeting date (Africa/Nairobi)", () => {
  test("rolls over at 21:00 UTC — midnight in Nairobi", () => {
    expect(todaysMeetingDate(new Date("2026-10-27T20:59:59Z")))
      .toBe("2026-10-27");
    expect(todaysMeetingDate(new Date("2026-10-27T21:00:00Z")))
      .toBe("2026-10-28");
  });

  test("an early-morning meeting gets the Nairobi day, not the UTC day",
    () => {
      // 01:30 in Nairobi on 1 Nov is still 31 Oct in UTC.
      expect(todaysMeetingDate(new Date("2026-10-31T22:30:00Z")))
        .toBe("2026-11-01");
    });

  test("crosses a year boundary correctly", () => {
    expect(todaysMeetingDate(new Date("2026-12-31T21:00:00Z")))
      .toBe("2027-01-01");
  });

  test("createDailySafetyMeeting stores the Nairobi date", async () => {
    await seedRoofingDay();
    const result = await meetings.createDailySafetyMeeting.run(callRequest(
      "foreman-a",
      {organizationId: ORG_A, projectId: "project-1", siteId: "site-1",
        activityIds: ["act-roof"]}
    ));
    expect((await meeting(ORG_A, result.id)).date).toBe(todaysMeetingDate());
  });
});

describe("suggestion rules", () => {
  test("riskMatches ignores case, punctuation and plural s", () => {
    expect(riskMatches("Falls", "fall")).toBe(true);
    expect(riskMatches("fall", "Falls from height!")).toBe(true);
    expect(riskMatches("Electrocution", "Working at height")).toBe(false);
    expect(riskMatches("", "anything")).toBe(false);
  });

  test("ranks activity + high-risk requirement matches above general " +
    "points, with reasons for each", () => {
    const result = rankSuggestions({
      points: [
        {id: "general", title: "PPE", applicableActivities: [],
          applicableRisks: []},
        {id: "activity", title: "Height", applicableActivities: ["roof"],
          applicableRisks: []},
        {id: "risk", title: "Fall arrest",
          applicableActivities: ["other"], applicableRisks: ["Falls"]},
        {id: "none", title: "Digging", applicableActivities: ["dig"],
          applicableRisks: ["Collapse"]},
      ],
      activities: [{id: "roof", name: "Roofing"}],
      requirements: [{name: "Working at height", category: "Falls",
        risk: "high"}],
      ahas: [],
    });
    expect(result.map((s) => s.pointId)).toEqual(
      ["activity", "risk", "general"]
    );
    expect(result[0].reasons).toEqual(["Today's work: Roofing"]);
    expect(result[1].reasons[0]).toContain("Working at height");
    expect(result[1].reasons[0]).toContain("high risk");
    expect(result[2].reasons).toEqual(["General safety point for any work"]);
  });

  test("a risk matching an accepted risk assessment's hazard is " +
    "suggested", () => {
    const result = rankSuggestions({
      points: [{id: "p", title: "Cables", applicableActivities: ["x"],
        applicableRisks: ["Electrocution"]}],
      activities: [{id: "wire", name: "Wiring"}],
      requirements: [],
      ahas: [{featureOfWork: "Wiring", hazards: ["Electrocution", "Burns"]}],
    });
    expect(result).toEqual([{pointId: "p",
      reasons: ["Risk \"Electrocution\" — risk assessment \"Wiring\""]}]);
  });
});

describe("getMeetingPointSuggestions", () => {
  test("uses activities, activity-scoped requirements and the site's " +
    "accepted risk assessments", async () => {
    await seedRoofingDay();
    // Activity-scoped requirement for today's roofing -> "Falls" matches.
    await db.doc(`organizations/${ORG_A}/safety_requirements/req-1`).set({
      organizationId: ORG_A, name: "Falls from height", category: "Height",
      risk: "high", activityId: "act-roof", requiredLearningIds: [],
      status: "active",
    });
    // A requirement for another activity never contributes.
    await db.doc(`organizations/${ORG_A}/safety_requirements/req-2`).set({
      organizationId: ORG_A, name: "Electrocution", category: "Electrical",
      risk: "high", activityId: "act-dig", requiredLearningIds: [],
      status: "active",
    });
    // A rejected AHA never contributes.
    await db.doc(`organizations/${ORG_A}/risk_assessments/aha-1`).set({
      organizationId: ORG_A, siteId: "site-1", status: "draft",
      featureOfWork: "Wiring", activityIds: [],
      steps: [{text: "Pull cable", hazards: ["Electrocution"],
        controls: ["Isolate"]}],
    });

    const result = await meetings.getMeetingPointSuggestions.run(callRequest(
      "foreman-a",
      {organizationId: ORG_A, siteId: "site-1", activityIds: ["act-roof"]}
    ));
    const ids = result.suggestions.map((s) => s.pointId);
    expect(ids).toEqual(["point-height", "point-falls", "point-ppe"]);
    expect(result.suggestions[1].reasons).toEqual([
      "Risk \"Falls\" — safety requirement \"Falls from height\" (high risk)",
    ]);
    expect(ids).not.toContain("point-electric");
    expect(ids).not.toContain("point-unrelated");
  });

  test("an accepted AHA covering the whole site makes a matching risk " +
    "relevant", async () => {
    await seedRoofingDay();
    await db.doc(`organizations/${ORG_A}/risk_assessments/aha-1`).set({
      organizationId: ORG_A, siteId: "site-1", status: "accepted",
      featureOfWork: "Site works", activityIds: [],
      steps: [{text: "Temporary power", hazards: ["Electrocution"],
        controls: ["RCD"]}],
    });
    const result = await meetings.getMeetingPointSuggestions.run(callRequest(
      "foreman-a",
      {organizationId: ORG_A, siteId: "site-1", activityIds: ["act-roof"]}
    ));
    const electric = result.suggestions.find(
      (s) => s.pointId === "point-electric"
    );
    expect(electric.reasons).toEqual(
      ["Risk \"Electrocution\" — risk assessment \"Site works\""]
    );
  });

  test("refuses an unauthenticated caller", async () => {
    await seedRoofingDay();
    await expect(meetings.getMeetingPointSuggestions.run(callRequest(
      null, {organizationId: ORG_A, siteId: "site-1", activityIds: []}
    ))).rejects.toMatchObject({code: "permission-denied"});
  });

  test("refuses a worker, and a foreman of another site or organization",
    async () => {
      await seedRoofingDay();
      await seedUser("worker-a", ORG_A, "worker", ["site-1"]);
      await seedUser("foreman-2", ORG_A, "foreman", ["site-2"]);
      await seedUser("foreman-b", ORG_B, "foreman", ["site-1"]);
      for (const uid of ["worker-a", "foreman-2", "foreman-b"]) {
        await expect(meetings.getMeetingPointSuggestions.run(callRequest(
          uid, {organizationId: ORG_A, siteId: "site-1", activityIds: []}
        ))).rejects.toMatchObject({code: "permission-denied"});
      }
    });

  test("refuses an activity from another site", async () => {
    await seedRoofingDay();
    await seedActivity(ORG_A, "act-far", "Far", "site-2");
    await expect(meetings.getMeetingPointSuggestions.run(callRequest(
      "foreman-a",
      {organizationId: ORG_A, siteId: "site-1", activityIds: ["act-far"]}
    ))).rejects.toMatchObject({code: "failed-precondition"});
  });
});

describe("suggestion snapshot on the meeting", () => {
  test("is stored at creation with reasons, and survives edits to " +
    "meetingPointIds", async () => {
    await seedRoofingDay();
    const {id} = await meetings.createDailySafetyMeeting.run(callRequest(
      "foreman-a",
      {organizationId: ORG_A, projectId: "project-1", siteId: "site-1",
        activityIds: ["act-roof"], meetingPointIds: ["point-height"]}
    ));
    const created = await meeting(ORG_A, id);
    expect(created.suggestedPointIds).toEqual(["point-height", "point-ppe"]);
    expect(created.suggestionReasons["point-height"])
      .toEqual(["Today's work: Roofing"]);
    expect(created.meetingPointIds).toEqual(["point-height"]);
    expect(created.concernCount).toBe(0);

    // Foreman removes the suggested point and adds one from the library,
    // and changes the activities.
    await meetings.updateDailySafetyMeeting.run(callRequest("foreman-a", {
      organizationId: ORG_A, id,
      meetingPointIds: ["point-unrelated"],
      activityIds: ["act-paint"],
    }));
    const edited = await meeting(ORG_A, id);
    expect(edited.meetingPointIds).toEqual(["point-unrelated"]);
    expect(edited.suggestedPointIds).toEqual(["point-height", "point-ppe"]);
    expect(edited.suggestionReasons).toEqual(created.suggestionReasons);
  });

  test("an update cannot write the snapshot fields", async () => {
    await seedRoofingDay();
    const {id} = await meetings.createDailySafetyMeeting.run(callRequest(
      "foreman-a",
      {organizationId: ORG_A, projectId: "project-1", siteId: "site-1",
        activityIds: ["act-roof"]}
    ));
    await meetings.updateDailySafetyMeeting.run(callRequest("foreman-a", {
      organizationId: ORG_A, id,
      suggestedPointIds: ["forged"],
      suggestionReasons: {forged: ["forged"]},
      concernCount: 99,
    }));
    const after = await meeting(ORG_A, id);
    expect(after.suggestedPointIds).toEqual(["point-height", "point-ppe"]);
    expect(after.suggestionReasons.forged).toBeUndefined();
    expect(after.concernCount).toBe(0);
  });
});

describe("audit trail", () => {
  test("records create, update (before/after), attendance, concerns and " +
    "completion — with the actor and meeting", async () => {
    await seedRoofingDay();
    await seedUser("worker-a", ORG_A, "worker", ["site-1"]);
    const {id} = await meetings.createDailySafetyMeeting.run(callRequest(
      "foreman-a",
      {organizationId: ORG_A, projectId: "project-1", siteId: "site-1",
        activityIds: ["act-roof"], meetingPointIds: ["point-height"]}
    ));
    await meetings.updateDailySafetyMeeting.run(callRequest("foreman-a", {
      organizationId: ORG_A, id, meetingPointIds: ["point-height", "point-ppe"],
    }));
    await meetings.recordMeetingAttendance.run(callRequest("foreman-a", {
      organizationId: ORG_A, meetingId: id, workerId: "worker-a",
      status: "absent",
    }));
    await meetings.recordMeetingAttendance.run(callRequest("foreman-a", {
      organizationId: ORG_A, meetingId: id, workerId: "worker-a",
      status: "present",
    }));
    const concern = await meetings.addMeetingConcern.run(callRequest(
      "foreman-a",
      {organizationId: ORG_A, meetingId: id,
        description: "Mzee Juma's ladder is broken", category: "equipment"}
    ));
    await meetings.removeMeetingConcern.run(callRequest("foreman-a", {
      organizationId: ORG_A, meetingId: id, concernId: concern.id,
    }));
    await meetings.completeDailySafetyMeeting.run(callRequest("foreman-a", {
      organizationId: ORG_A, id, crewOutcome: "go",
    }));

    const entries = await auditEntries(id);
    const actions = entries.map((e) => e.action).sort();
    expect(actions).toEqual([
      "meeting.attendanceRecorded",
      "meeting.attendanceRecorded",
      "meeting.completed",
      "meeting.concernAdded",
      "meeting.concernRemoved",
      "meeting.created",
      "meeting.updated",
    ]);
    for (const entry of entries) {
      expect(entry.organizationId).toBe(ORG_A);
      expect(entry.actorUid).toBe("foreman-a");
      expect(entry.targetCollection).toBe("daily_safety_meetings");
      expect(entry.targetDocId).toBe(id);
      expect(entry.createdAt).toBeDefined();
    }

    const updated = entries.find((e) => e.action === "meeting.updated");
    expect(updated.metadata).toEqual({
      before: {meetingPointIds: ["point-height"]},
      after: {meetingPointIds: ["point-height", "point-ppe"]},
    });

    const attendance = entries
      .filter((e) => e.action === "meeting.attendanceRecorded")
      .map((e) => e.metadata);
    expect(attendance).toContainEqual({
      workerId: "worker-a",
      before: {status: "absent", briefedInPerson: false},
      after: {status: "present", briefedInPerson: false},
    });

    // Free text a Foreman typed is never copied into the audit trail.
    expect(JSON.stringify(entries)).not.toContain("ladder");
  });

  test("an update that changes nothing writes no entry", async () => {
    await seedRoofingDay();
    await seedMeeting(ORG_A, "m1");
    await meetings.updateDailySafetyMeeting.run(callRequest("foreman-a", {
      organizationId: ORG_A, id: "m1", meetingPointIds: ["point-height"],
    }));
    expect(await auditEntries("m1")).toEqual([]);
  });

  test("a refused call writes nothing", async () => {
    await seedRoofingDay();
    await seedUser("foreman-2", ORG_A, "foreman", ["site-1"]);
    await seedMeeting(ORG_A, "m1");
    await expect(meetings.updateDailySafetyMeeting.run(callRequest(
      "foreman-2",
      {organizationId: ORG_A, id: "m1", meetingPointIds: ["point-ppe"]}
    ))).rejects.toMatchObject({code: "permission-denied"});
    await expect(meetings.addMeetingConcern.run(callRequest(
      "foreman-b",
      {organizationId: ORG_A, meetingId: "m1", description: "x",
        category: "other"}
    ))).rejects.toMatchObject({code: "permission-denied"});
    expect(await auditEntries("m1")).toEqual([]);
    expect((await meeting(ORG_A, "m1")).concernCount).toBeUndefined();
  });
});

describe("concernCount", () => {
  test("follows add and remove", async () => {
    await seedRoofingDay();
    await seedMeeting(ORG_A, "m1", {concernCount: 0});
    const first = await meetings.addMeetingConcern.run(callRequest(
      "foreman-a",
      {organizationId: ORG_A, meetingId: "m1", description: "a",
        category: "safety"}
    ));
    await meetings.addMeetingConcern.run(callRequest("foreman-a", {
      organizationId: ORG_A, meetingId: "m1", description: "b",
      category: "safety",
    }));
    expect((await meeting(ORG_A, "m1")).concernCount).toBe(2);
    await meetings.removeMeetingConcern.run(callRequest("foreman-a", {
      organizationId: ORG_A, meetingId: "m1", concernId: first.id,
    }));
    expect((await meeting(ORG_A, "m1")).concernCount).toBe(1);
  });

  test("a meeting from before concernCount counts its existing concerns " +
    "the first time one is added", async () => {
    await seedRoofingDay();
    await seedMeeting(ORG_A, "old", {status: "completed"});
    await seedConcern(ORG_A, "old", "c1");
    await seedConcern(ORG_A, "old", "c2");
    await meetings.addMeetingConcern.run(callRequest("foreman-a", {
      organizationId: ORG_A, meetingId: "old", description: "late",
      category: "safety",
    }));
    expect((await meeting(ORG_A, "old")).concernCount).toBe(3);
  });

  test("concurrent adds never lose a count", async () => {
    await seedRoofingDay();
    await seedMeeting(ORG_A, "m1", {concernCount: 0});
    await Promise.all([1, 2, 3, 4, 5].map((n) =>
      meetings.addMeetingConcern.run(callRequest("foreman-a", {
        organizationId: ORG_A, meetingId: "m1", description: `c${n}`,
        category: "safety",
      }))
    ));
    expect((await meeting(ORG_A, "m1")).concernCount).toBe(5);
  });

  test("a worker's Pre-Start STOP becoming a concern counts too",
    async () => {
      await seedRoofingDay();
      await seedUser("worker-a", ORG_A, "worker", ["site-1"], "Wanjiru");
      // Today's meeting already exists, so the STOP attaches straight to it.
      const {id} = await meetings.createDailySafetyMeeting.run(callRequest(
        "foreman-a",
        {organizationId: ORG_A, projectId: "project-1", siteId: "site-1",
          activityIds: ["act-roof"]}
      ));
      const questions = (await require("../lib/pre_start_check_callable")
        .getMyPreStartCheck.run(callRequest(
          "worker-a", {organizationId: ORG_A}
        ))).questions;
      await submitPreStartCheck.run(callRequest("worker-a", {
        organizationId: ORG_A,
        answers: questions.map((q, i) => ({
          questionId: q.id,
          answer: i === 0 ? "cannotFix" : "yes",
          ...(i === 0 ? {note: "No harness"} : {}),
        })),
      }));
      expect((await meeting(ORG_A, id)).concernCount).toBe(1);
      const added = (await auditEntries(id))
        .filter((e) => e.action === "meeting.concernAdded");
      expect(added).toHaveLength(1);
      expect(added[0].actorUid).toBe("worker-a");
      expect(added[0].metadata.source).toBe("preStartCheck");
    });
});

describe("corrective actions from a meeting", () => {
  async function seedLateConcernDay() {
    await seedRoofingDay();
    await seedUser("worker-a", ORG_A, "worker", ["site-1"], "Otieno");
    await seedMeeting(ORG_A, "m1", {status: "completed"});
    await seedConcern(ORG_A, "m1", "c1");
  }

  function actionRequest(uid, overrides = {}) {
    return callRequest(uid, {
      organizationId: ORG_A,
      meetingId: "m1",
      title: "Replace ladder",
      description: "Take the broken ladder out of use",
      assignedTo: "worker-a",
      dueDate: "2026-11-05T09:00:00.000Z",
      ...overrides,
    });
  }

  test("a completed meeting accepts one raised from its own concern, and " +
    "links it both ways", async () => {
    await seedLateConcernDay();
    const result = await createCorrectiveAction.run(
      actionRequest("foreman-a", {concernId: "c1"})
    );
    const action = (await db
      .doc(`organizations/${ORG_A}/corrective_actions/${result.id}`)
      .get()).data();
    expect(action.meetingId).toBe("m1");
    expect(action.concernId).toBe("c1");
    expect((await meeting(ORG_A, "m1")).correctiveActionIds)
      .toEqual([result.id]);

    const audit = (await auditEntries("m1"))
      .find((e) => e.action === "meeting.correctiveActionRaised");
    expect(audit.actorUid).toBe("foreman-a");
    expect(audit.metadata).toEqual({
      correctiveActionId: result.id,
      concernId: "c1",
      assignedTo: "worker-a",
      afterCompletion: true,
    });
  });

  test("a second action keeps the first in correctiveActionIds", async () => {
    await seedLateConcernDay();
    const first = await createCorrectiveAction.run(
      actionRequest("foreman-a", {concernId: "c1"})
    );
    const second = await createCorrectiveAction.run(
      actionRequest("foreman-a", {concernId: "c1", title: "Train crew"})
    );
    expect((await meeting(ORG_A, "m1")).correctiveActionIds.sort())
      .toEqual([first.id, second.id].sort());
  });

  test("an in-progress meeting still accepts one without a concern, and " +
    "links it", async () => {
    await seedRoofingDay();
    await seedUser("worker-a", ORG_A, "worker", ["site-1"]);
    await seedMeeting(ORG_A, "m1");
    const result = await createCorrectiveAction.run(actionRequest("foreman-a"));
    expect((await meeting(ORG_A, "m1")).correctiveActionIds)
      .toEqual([result.id]);
    const audit = (await auditEntries("m1"))
      .find((e) => e.action === "meeting.correctiveActionRaised");
    expect(audit.metadata.afterCompletion).toBe(false);
    expect(audit.metadata.concernId).toBeNull();
  });

  test("a completed meeting refuses one with no concern", async () => {
    await seedLateConcernDay();
    await expect(createCorrectiveAction.run(actionRequest("foreman-a")))
      .rejects.toMatchObject({code: "failed-precondition"});
    expect((await meeting(ORG_A, "m1")).correctiveActionIds).toEqual([]);
    expect(await auditEntries("m1")).toEqual([]);
  });

  test("a completed meeting refuses a concern from another meeting",
    async () => {
      await seedLateConcernDay();
      await seedMeeting(ORG_A, "m2", {status: "completed"});
      await seedConcern(ORG_A, "m2", "c-other");
      await expect(createCorrectiveAction.run(
        actionRequest("foreman-a", {concernId: "c-other"})
      )).rejects.toBeDefined();
      await expect(createCorrectiveAction.run(
        actionRequest("foreman-a", {concernId: "missing"})
      )).rejects.toBeDefined();
      expect((await meeting(ORG_A, "m1")).correctiveActionIds).toEqual([]);
    });

  test("another foreman, a worker, or another organization's foreman is " +
    "refused", async () => {
    await seedLateConcernDay();
    await seedUser("foreman-2", ORG_A, "foreman", ["site-1"]);
    await seedUser("foreman-b", ORG_B, "foreman", ["site-1"]);
    await seedUser("worker-b", ORG_A, "worker", ["site-1"]);
    for (const uid of ["foreman-2", "worker-b", "foreman-b"]) {
      await expect(createCorrectiveAction.run(
        actionRequest(uid, {concernId: "c1"})
      )).rejects.toMatchObject({code: "permission-denied"});
    }
    await expect(createCorrectiveAction.run(
      actionRequest(null, {concernId: "c1"})
    )).rejects.toMatchObject({code: "permission-denied"});
    expect((await meeting(ORG_A, "m1")).correctiveActionIds).toEqual([]);
  });

  test("a meeting in another organization cannot be named through this " +
    "one", async () => {
    await seedLateConcernDay();
    await seedMeeting(ORG_B, "m1", {
      status: "completed",
      foremanId: "foreman-b",
    });
    await seedConcern(ORG_B, "m1", "c1");
    await seedUser("foreman-b", ORG_B, "foreman", ["site-1"]);
    // foreman-a names ORG_B's meeting: not their meeting.
    await expect(createCorrectiveAction.run(
      actionRequest("foreman-a", {organizationId: ORG_B, concernId: "c1"})
    )).rejects.toMatchObject({code: "permission-denied"});
    // foreman-b cannot reach ORG_A's meeting by naming ORG_A either.
    await expect(createCorrectiveAction.run(
      actionRequest("foreman-b", {concernId: "c1"})
    )).rejects.toMatchObject({code: "permission-denied"});
    expect((await meeting(ORG_B, "m1")).correctiveActionIds).toEqual([]);
  });
});
