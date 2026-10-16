/**
 * Business-logic tests for `pre_start_check_callable.ts`
 * (`getMyPreStartCheck`, `submitPreStartCheck`, `getSiteCrewPreStartChecks`)
 * and the two hooks it adds to `daily_safety_meeting_callable.ts`
 * (STOP checks attached when a meeting starts; the crew result recorded
 * when a meeting completes).
 *
 * Same shape as `daily_safety_meeting_callable.test.js`: each callable's own
 * handler is invoked via `.run(request)` against the Firestore emulator.
 * Run with `npm run test:callables`.
 */

const {initializeApp, getApps, deleteApp} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");

const PROJECT_ID = "jva-safety-rules-test";
const ORG_A = "org-alpha";
const ORG_B = "org-beta";
const TODAY = new Date().toISOString().slice(0, 10);

let app;
let db;
let getMyPreStartCheck;
let submitPreStartCheck;
let getSiteCrewPreStartChecks;
let createDailySafetyMeeting;
let completeDailySafetyMeeting;
let STANDARD_QUESTIONS;

beforeAll(() => {
  process.env.GCLOUD_PROJECT = PROJECT_ID;
  if (!process.env.FIRESTORE_EMULATOR_HOST) {
    process.env.FIRESTORE_EMULATOR_HOST = "127.0.0.1:8080";
  }
  app = getApps()[0] ?? initializeApp({projectId: PROJECT_ID});
  db = getFirestore(app);

  ({
    getMyPreStartCheck,
    submitPreStartCheck,
    getSiteCrewPreStartChecks,
    STANDARD_QUESTIONS,
  } = require("../lib/pre_start_check_callable"));
  ({
    createDailySafetyMeeting,
    completeDailySafetyMeeting,
  } = require("../lib/daily_safety_meeting_callable"));
});

afterAll(async () => {
  if (app) await deleteApp(app);
});

async function clearFirestore() {
  const collections = await db.listCollections();
  await Promise.all(collections.map((c) => db.recursiveDelete(c)));
}

async function seedUser(uid, role, siteIds, overrides = {}) {
  const {organizationId = ORG_A, membershipStatus = "active", name} =
    overrides;
  await db.doc(`users/${uid}`).set({
    uid,
    name: name ?? `Name ${uid}`,
    email: `${uid}@example.com`,
    accountStatus: "active",
  });
  await db.doc(`users/${uid}/memberships/${organizationId}`).set({
    organizationId,
    role,
    workerType: null,
    trade: null,
    siteIds,
    supervisorUid: null,
    status: membershipStatus,
    createdAt: new Date(),
    updatedAt: new Date(),
  });
}

async function seedSite(orgId, id = "site-1") {
  await db.doc(`organizations/${orgId}/sites/${id}`).set({
    organizationId: orgId,
    projectId: "project-1",
    name: "Test Site",
    status: "active",
  });
}

async function seedActivity(orgId, id, siteId = "site-1") {
  await db.doc(`organizations/${orgId}/activities/${id}`).set({
    organizationId: orgId,
    projectId: "project-1",
    siteId,
    name: "Roofing",
    code: `CODE-${id}`,
    status: "active",
  });
}

async function seedAssignment(orgId, activityId, uid, siteId = "site-1") {
  await db
    .doc(`organizations/${orgId}/activities/${activityId}/assignments/${uid}`)
    .set({
      uid,
      organizationId: orgId,
      siteId,
      activityId,
      assignedAt: new Date(),
      assignedBy: "assigner-1",
    });
}

async function seedRequirement(orgId, id, overrides = {}) {
  await db.doc(`organizations/${orgId}/safety_requirements/${id}`).set({
    organizationId: orgId,
    name: `Requirement ${id}`,
    category: "General",
    risk: "medium",
    requiredLearningIds: [],
    status: "active",
    ...overrides,
  });
}

function callRequest(uid, data) {
  return {auth: {uid, token: {}}, data, rawRequest: {}};
}

/** Answers every question "yes", except the given overrides. */
function answersFor(questions, overrides = {}) {
  return questions.map((q) => ({
    questionId: q.id,
    answer: overrides[q.id]?.answer ?? "yes",
    note: overrides[q.id]?.note ?? null,
  }));
}

async function check(uid) {
  const snapshot = await db
    .doc(`organizations/${ORG_A}/pre_start_checks/${uid}_${TODAY}`)
    .get();
  return snapshot.exists ? snapshot.data() : null;
}

async function notificationsFor(uid) {
  const snapshot = await db
    .collection(`organizations/${ORG_A}/notifications`)
    .where("recipientUid", "==", uid)
    .get();
  return snapshot.docs.map((doc) => doc.data());
}

beforeEach(async () => {
  await clearFirestore();
  await seedSite(ORG_A);
  await seedActivity(ORG_A, "act-roof");
  await seedUser("worker-1", "worker", ["site-1"]);
  await seedAssignment(ORG_A, "act-roof", "worker-1");
  await seedUser("foreman-a", "foreman", ["site-1"]);
});

describe("getMyPreStartCheck", () => {
  test("asks only what today's work needs: the five standard questions, " +
    "one line per activity with high-risk requirements, and one for " +
    "site-wide high-risk requirements", async () => {
    await seedRequirement(ORG_A, "req-org", {name: "Site Induction",
      risk: "low"});
    await seedRequirement(ORG_A, "req-roof", {name: "Working at Height",
      risk: "high", activityId: "act-roof"});
    await seedRequirement(ORG_A, "req-fall", {name: "Fall Protection",
      risk: "high", activityId: "act-roof"});
    await seedRequirement(ORG_A, "req-ladder", {name: "Ladder Use",
      risk: "medium", activityId: "act-roof"});
    await seedRequirement(ORG_A, "req-fire", {name: "Fire Safety",
      risk: "high", siteId: "site-1"});
    await seedRequirement(ORG_A, "req-other", {name: "Confined Space",
      risk: "high", activityId: "act-elsewhere"});
    await seedRequirement(ORG_A, "req-inactive", {risk: "high",
      status: "inactive"});

    const result = await getMyPreStartCheck.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );

    expect(result.submission).toBeNull();
    expect(result.site).toEqual({id: "site-1", name: "Test Site"});
    const ids = result.questions.map((q) => q.id);
    expect(ids.slice(0, 5)).toEqual(STANDARD_QUESTIONS.map((q) => q.id));
    expect(ids.slice(5)).toEqual(["act-act-roof", "site-high-risk"]);
    expect(result.questions[5].prompt).toBe(
      "Roofing: the controls for \"Fall Protection\" and \"Working at " +
        "Height\" are in place and I will follow them today."
    );
    expect(result.questions[6].prompt).toContain("\"Fire Safety\"");
  });

  test("a worker with no high-risk work today answers just the five " +
    "standard questions", async () => {
    await seedRequirement(ORG_A, "req-ladder", {name: "Ladder Use",
      risk: "medium", activityId: "act-roof"});

    const result = await getMyPreStartCheck.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );

    expect(result.questions.map((q) => q.id))
      .toEqual(STANDARD_QUESTIONS.map((q) => q.id));
  });

  test("a Foreman is told the check is for workers", async () => {
    await expect(getMyPreStartCheck.run(
      callRequest("foreman-a", {organizationId: ORG_A})
    )).rejects.toThrow(/completed by workers/);
  });

  test("a worker from another organization is refused", async () => {
    await seedUser("worker-b", "worker", ["site-1"],
      {organizationId: ORG_B});
    await expect(getMyPreStartCheck.run(
      callRequest("worker-b", {organizationId: ORG_A})
    )).rejects.toThrow();
  });
});

describe("submitPreStartCheck", () => {
  test("all yes is GO, with no concern and no notification", async () => {
    const {questions} = await getMyPreStartCheck.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );
    const result = await submitPreStartCheck.run(callRequest("worker-1", {
      organizationId: ORG_A,
      answers: answersFor(questions),
    }));

    expect(result.outcome).toBe("go");
    const stored = await check("worker-1");
    expect(stored.outcome).toBe("go");
    expect(stored.siteId).toBe("site-1");
    expect(stored.activityIds).toEqual(["act-roof"]);
    expect(await notificationsFor("foreman-a")).toEqual([]);
  });

  test("a fixed answer is GO corrected", async () => {
    const {questions} = await getMyPreStartCheck.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );
    const result = await submitPreStartCheck.run(callRequest("worker-1", {
      organizationId: ORG_A,
      answers: answersFor(questions, {
        "std-ppe": {answer: "fixed", note: "Collected a new helmet"},
      }),
    }));
    expect(result.outcome).toBe("goCorrected");
    expect(result.issueCount).toBe(1);
  });

  test("a cannot-fix answer is STOP: it notifies the site's Foreman and " +
    "raises a concern on today's meeting", async () => {
    await db.doc(`organizations/${ORG_A}/daily_safety_meetings/m-1`).set({
      organizationId: ORG_A,
      projectId: "project-1",
      siteId: "site-1",
      date: TODAY,
      startTime: new Date(),
      foremanId: "foreman-a",
      activityIds: ["act-roof"],
      meetingPointIds: [],
      status: "inProgress",
    });
    const {questions} = await getMyPreStartCheck.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );
    const result = await submitPreStartCheck.run(callRequest("worker-1", {
      organizationId: ORG_A,
      answers: answersFor(questions, {
        "std-tools": {answer: "cannotFix", note: "Grinder guard is broken"},
      }),
    }));

    expect(result.outcome).toBe("stop");
    const stored = await check("worker-1");
    expect(stored.meetingId).toBe("m-1");
    const concern = (await db.doc(
      `organizations/${ORG_A}/daily_safety_meetings/m-1/concerns/` +
        stored.concernId
    ).get()).data();
    expect(concern.source).toBe("preStartCheck");
    expect(concern.status).toBe("open");
    expect(concern.description).toContain("Grinder guard is broken");
    const notes = await notificationsFor("foreman-a");
    expect(notes).toHaveLength(1);
    expect(notes[0].title).toContain("Pre-Start STOP");
  });

  test("a STOP before the meeting exists is attached when the Foreman " +
    "starts it", async () => {
    const {questions} = await getMyPreStartCheck.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );
    await submitPreStartCheck.run(callRequest("worker-1", {
      organizationId: ORG_A,
      answers: answersFor(questions, {
        "std-fit": {answer: "cannotFix", note: "Feeling dizzy"},
      }),
    }));
    expect((await check("worker-1")).concernId).toBeNull();

    const meeting = await createDailySafetyMeeting.run(
      callRequest("foreman-a", {
        organizationId: ORG_A,
        projectId: "project-1",
        siteId: "site-1",
      })
    );

    const stored = await check("worker-1");
    expect(stored.meetingId).toBe(meeting.id);
    expect(stored.concernId).toEqual(expect.any(String));
  });

  test("a note is required for any No answer", async () => {
    const {questions} = await getMyPreStartCheck.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );
    await expect(submitPreStartCheck.run(callRequest("worker-1", {
      organizationId: ORG_A,
      answers: answersFor(questions, {"std-area": {answer: "fixed"}}),
    }))).rejects.toThrow(/say what you fixed/);
  });

  test("skipping a question is refused", async () => {
    const {questions} = await getMyPreStartCheck.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );
    await expect(submitPreStartCheck.run(callRequest("worker-1", {
      organizationId: ORG_A,
      answers: answersFor(questions).slice(1),
    }))).rejects.toThrow(/questions have changed/);
  });

  test("a second check the same day is refused, and the first is kept",
    async () => {
      const {questions} = await getMyPreStartCheck.run(
        callRequest("worker-1", {organizationId: ORG_A})
      );
      await submitPreStartCheck.run(callRequest("worker-1", {
        organizationId: ORG_A,
        answers: answersFor(questions),
      }));
      await expect(submitPreStartCheck.run(callRequest("worker-1", {
        organizationId: ORG_A,
        answers: answersFor(questions, {
          "std-ppe": {answer: "cannotFix", note: "x"},
        }),
      }))).rejects.toThrow(/already completed/);
      expect((await check("worker-1")).outcome).toBe("go");

      const again = await getMyPreStartCheck.run(
        callRequest("worker-1", {organizationId: ORG_A})
      );
      expect(again.submission.outcome).toBe("go");
      expect(again.questions).toEqual([]);
    });

  test("a check saved offline is accepted on its own day, but not counted " +
    "for a later day", async () => {
    const {date, questions} = await getMyPreStartCheck.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );
    await expect(submitPreStartCheck.run(callRequest("worker-1", {
      organizationId: ORG_A,
      forDate: "2020-01-01",
      answers: answersFor(questions),
    }))).rejects.toThrow(/was for 2020-01-01/);
    expect(await check("worker-1")).toBeNull();

    const result = await submitPreStartCheck.run(callRequest("worker-1", {
      organizationId: ORG_A,
      forDate: date,
      answers: answersFor(questions),
    }));
    expect(result.outcome).toBe("go");
  });
});

describe("getSiteCrewPreStartChecks", () => {
  test("lists every crew member, with null for one not done yet",
    async () => {
      await seedUser("worker-2", "worker", ["site-1"]);
      await seedAssignment(ORG_A, "act-roof", "worker-2");
      const {questions} = await getMyPreStartCheck.run(
        callRequest("worker-1", {organizationId: ORG_A})
      );
      await submitPreStartCheck.run(callRequest("worker-1", {
        organizationId: ORG_A,
        answers: answersFor(questions, {
          "std-ppe": {answer: "fixed", note: "Swapped gloves"},
        }),
      }));

      const result = await getSiteCrewPreStartChecks.run(
        callRequest("foreman-a", {organizationId: ORG_A, siteId: "site-1"})
      );

      expect(result.workers).toEqual([
        {
          workerId: "worker-1",
          workerName: "Name worker-1",
          outcome: "goCorrected",
          issues: [{
            prompt: STANDARD_QUESTIONS[0].prompt,
            answer: "fixed",
            note: "Swapped gloves",
          }],
        },
        {
          workerId: "worker-2",
          workerName: "Name worker-2",
          outcome: null,
          issues: [],
        },
      ]);
    });

  test("a Foreman of another site, and a worker, are refused", async () => {
    await seedUser("foreman-x", "foreman", ["site-9"]);
    await expect(getSiteCrewPreStartChecks.run(
      callRequest("foreman-x", {organizationId: ORG_A, siteId: "site-1"})
    )).rejects.toThrow();
    await expect(getSiteCrewPreStartChecks.run(
      callRequest("worker-1", {organizationId: ORG_A, siteId: "site-1"})
    )).rejects.toThrow();
  });

  test("a Site Manager may view any site", async () => {
    await seedUser("manager-1", "siteManager", []);
    const result = await getSiteCrewPreStartChecks.run(
      callRequest("manager-1", {organizationId: ORG_A, siteId: "site-1"})
    );
    expect(result.workers.map((w) => w.workerId)).toEqual(["worker-1"]);
  });
});

describe("completeDailySafetyMeeting (crew result)", () => {
  async function seedCompletableMeeting() {
    await db.doc(`organizations/${ORG_A}/daily_safety_meetings/m-1`).set({
      organizationId: ORG_A,
      projectId: "project-1",
      siteId: "site-1",
      date: TODAY,
      startTime: new Date(),
      foremanId: "foreman-a",
      activityIds: ["act-roof"],
      meetingPointIds: ["point-1"],
      status: "inProgress",
    });
  }

  test("records the crew result and note", async () => {
    await seedCompletableMeeting();
    await completeDailySafetyMeeting.run(callRequest("foreman-a", {
      organizationId: ORG_A,
      id: "m-1",
      crewOutcome: "goCorrected",
      crewOutcomeNote: "Barricade moved before work",
    }));
    const meeting = (await db
      .doc(`organizations/${ORG_A}/daily_safety_meetings/m-1`).get()).data();
    expect(meeting.status).toBe("completed");
    expect(meeting.crewOutcome).toBe("goCorrected");
    expect(meeting.crewOutcomeNote).toBe("Barricade moved before work");
  });

  test("a crew STOP notifies every Site Manager", async () => {
    await seedCompletableMeeting();
    await seedUser("manager-1", "siteManager", []);
    await completeDailySafetyMeeting.run(callRequest("foreman-a", {
      organizationId: ORG_A,
      id: "m-1",
      crewOutcome: "stop",
      crewOutcomeNote: "Scaffold failed inspection",
    }));
    const notes = await notificationsFor("manager-1");
    expect(notes).toHaveLength(1);
    expect(notes[0].message).toContain("Scaffold failed inspection");
  });

  test("a non-GO result without a note is refused", async () => {
    await seedCompletableMeeting();
    await expect(completeDailySafetyMeeting.run(callRequest("foreman-a", {
      organizationId: ORG_A,
      id: "m-1",
      crewOutcome: "stop",
    }))).rejects.toThrow(/add a note/);
  });

  test("an unknown result is refused", async () => {
    await seedCompletableMeeting();
    await expect(completeDailySafetyMeeting.run(callRequest("foreman-a", {
      organizationId: ORG_A,
      id: "m-1",
      crewOutcome: "maybe",
    }))).rejects.toThrow(/crewOutcome must be/);
  });
});

describe("the Safety Plan's daily worker checks", () => {
  test("the tools question covers cords, hand/power tools and machinery",
    () => {
      const tools = STANDARD_QUESTIONS.find((q) => q.id === "std-tools");
      expect(tools.prompt).toMatch(/electrical cords/);
      expect(tools.prompt).toMatch(/hand and power tools/);
      expect(tools.prompt).toMatch(/machinery/);
    });

  test("still only five standard questions", () => {
    expect(STANDARD_QUESTIONS).toHaveLength(5);
  });
});
