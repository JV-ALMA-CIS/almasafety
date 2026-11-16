/**
 * Tests for `daily_learning_plan.ts` — each person's small "Needed today"
 * learning plan — and the "Briefed in person" attendance path in
 * `recordMeetingAttendance` that it enables.
 *
 * Same shape as the other `*_callable.test.js` suites: real handlers against
 * the Firestore emulator. Run with `npm run test:callables`.
 */

const {initializeApp, getApps, deleteApp} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");

const PROJECT_ID = "jva-safety-rules-test";
const ORG = "org-alpha";
const DAY = "2026-10-08";
const NEXT_DAY = "2026-10-09";

let app;
let db;
let neededToday;
let neededTomorrow;
let outstandingNeededToday;
let recordMeetingAttendance;

beforeAll(() => {
  process.env.GCLOUD_PROJECT = PROJECT_ID;
  if (!process.env.FIRESTORE_EMULATOR_HOST) {
    process.env.FIRESTORE_EMULATOR_HOST = "127.0.0.1:8080";
  }
  app = getApps()[0] ?? initializeApp({projectId: PROJECT_ID});
  db = getFirestore(app);
  ({
    neededToday,
    neededTomorrow,
    outstandingNeededToday,
  } = require("../lib/daily_learning_plan"));
  ({recordMeetingAttendance} = require("../lib/daily_safety_meeting_callable"));
});

afterAll(async () => {
  if (app) await deleteApp(app);
});

async function clearFirestore() {
  const collections = await db.listCollections();
  await Promise.all(collections.map((c) => db.recursiveDelete(c)));
}

async function seedUser(uid, role, siteIds = ["site-1"]) {
  await db.doc(`users/${uid}`).set({
    uid,
    name: `Name ${uid}`,
    email: `${uid}@example.com`,
    accountStatus: "active",
  });
  await db.doc(`users/${uid}/memberships/${ORG}`).set({
    organizationId: ORG,
    role,
    siteIds,
    status: "active",
  });
}

async function seedActivity(id) {
  await db.doc(`organizations/${ORG}/activities/${id}`).set({
    organizationId: ORG,
    projectId: "project-1",
    siteId: "site-1",
    name: id,
    status: "active",
  });
}

async function assign(uid, activityId) {
  await db
    .doc(`organizations/${ORG}/activities/${activityId}/assignments/${uid}`)
    .set({uid, organizationId: ORG, siteId: "site-1", activityId});
}

async function seedLessons(...ids) {
  for (const id of ids) {
    await db.doc(`organizations/${ORG}/safety_learning/${id}`).set({
      organizationId: ORG,
      title: `Lesson ${id}`,
      type: "document",
      contentReference: id,
      status: "active",
    });
  }
}

async function seedRequirement(id, overrides = {}) {
  await db.doc(`organizations/${ORG}/safety_requirements/${id}`).set({
    organizationId: ORG,
    name: id,
    category: "General",
    risk: "medium",
    requiredLearningIds: [],
    gatesAttendance: true,
    status: "active",
    ...overrides,
  });
}

async function complete(uid, learningId) {
  await db
    .doc(`organizations/${ORG}/worker_learning_records/${uid}_${learningId}`)
    .set({workerUid: uid, learningId, status: "completed"});
}

const ids = (lessons) => lessons.map((l) => l.learningId);

beforeEach(async () => {
  await clearFirestore();
  await db.doc(`organizations/${ORG}/sites/site-1`).set({
    organizationId: ORG,
    projectId: "project-1",
    name: "Site One",
  });
  await seedActivity("roofing");
  await seedActivity("electrical");
  await seedUser("worker-1", "worker");
  await assign("worker-1", "roofing");
});

describe("neededToday", () => {
  test("20 site-wide requirements still mean ONE general lesson today",
    async () => {
      for (let i = 0; i < 20; i++) {
        const lesson = `site-${String(i).padStart(2, "0")}`;
        await seedLessons(lesson);
        await seedRequirement(`req-${i}`, {
          siteId: "site-1",
          requiredLearningIds: [lesson],
        });
      }

      const {lessons} = await neededToday(ORG, "worker-1", DAY);

      expect(ids(lessons)).toEqual(["site-00"]);
    });

  test("one lesson per activity the worker does today, highest risk first " +
    "— never another activity's", async () => {
    await seedLessons("roof-low", "roof-high", "elec-high");
    await seedRequirement("roof-a", {
      activityId: "roofing", risk: "low", requiredLearningIds: ["roof-low"],
    });
    await seedRequirement("roof-b", {
      activityId: "roofing", risk: "high", requiredLearningIds: ["roof-high"],
    });
    await seedRequirement("elec", {
      activityId: "electrical",
      risk: "high",
      requiredLearningIds: ["elec-high"],
    });

    const {lessons} = await neededToday(ORG, "worker-1", DAY);

    expect(ids(lessons)).toEqual(["roof-high"]);
    expect(lessons[0].activityId).toBe("roofing");
  });

  test("a worker on two activities gets one lesson for each", async () => {
    await assign("worker-1", "electrical");
    await seedLessons("roof", "elec");
    await seedRequirement("r1", {
      activityId: "roofing", requiredLearningIds: ["roof"],
    });
    await seedRequirement("r2", {
      activityId: "electrical", requiredLearningIds: ["elec"],
    });

    const {lessons} = await neededToday(ORG, "worker-1", DAY);

    expect(ids(lessons).sort()).toEqual(["elec", "roof"]);
  });

  test("lessons not marked Before meeting are never needed today",
    async () => {
      await seedLessons("info");
      await seedRequirement("r1", {
        activityId: "roofing",
        gatesAttendance: false,
        requiredLearningIds: ["info"],
      });

      expect(await neededToday(ORG, "worker-1", DAY))
        .toEqual(expect.objectContaining({lessons: []}));
    });

  test("finishing today's lesson does not pull the next one into today; " +
    "it comes the next day", async () => {
    await seedLessons("first", "second");
    await seedRequirement("r1", {
      activityId: "roofing", requiredLearningIds: ["first", "second"],
    });

    expect(ids(await outstandingNeededToday(ORG, "worker-1", DAY)))
      .toEqual(["first"]);
    await complete("worker-1", "first");

    expect(await outstandingNeededToday(ORG, "worker-1", DAY)).toEqual([]);
    expect(ids(await outstandingNeededToday(ORG, "worker-1", NEXT_DAY)))
      .toEqual(["second"]);
  });

  test("anyone other than a worker or Foreman has no plan", async () => {
    await seedUser("manager-1", "siteManager");
    await seedLessons("l1");
    await seedRequirement("r1", {requiredLearningIds: ["l1"]});

    expect((await neededToday(ORG, "manager-1", DAY)).lessons).toEqual([]);
  });
});

describe("neededTomorrow", () => {
  test("shows tomorrow's lesson today, and doing it the evening before " +
    "leaves nothing needed in the morning", async () => {
    await seedLessons("first", "second");
    await seedRequirement("r1", {
      activityId: "roofing", requiredLearningIds: ["first", "second"],
    });

    expect(ids(await neededTomorrow(ORG, "worker-1", DAY)))
      .toEqual(["second"]);
    await complete("worker-1", "first");
    await complete("worker-1", "second");

    expect(await outstandingNeededToday(ORG, "worker-1", NEXT_DAY))
      .toEqual([]);
  });
});

describe("recordMeetingAttendance — Briefed in person", () => {
  beforeEach(async () => {
    await seedUser("foreman-1", "foreman");
    await seedLessons("roof");
    await seedRequirement("r1", {
      activityId: "roofing", requiredLearningIds: ["roof"],
    });
    await db.doc(`organizations/${ORG}/daily_safety_meetings/m-1`).set({
      organizationId: ORG,
      projectId: "project-1",
      siteId: "site-1",
      date: require("../lib/worker_learning_callable").todaysMeetingDate(),
      foremanId: "foreman-1",
      activityIds: ["roofing"],
      meetingPointIds: [],
      status: "inProgress",
    });
  });

  const mark = (extra = {}) => recordMeetingAttendance.run({
    auth: {uid: "foreman-1", token: {}},
    rawRequest: {},
    data: {
      organizationId: ORG,
      meetingId: "m-1",
      workerId: "worker-1",
      status: "present",
      ...extra,
    },
  });

  const attendance = async () => (await db.doc(
    `organizations/${ORG}/daily_safety_meetings/m-1/attendance/worker-1`
  ).get()).data();

  test("without it, a worker with today's lesson outstanding is refused, " +
    "and told about the option", async () => {
    await expect(mark()).rejects.toThrow(/Briefed in person/);
  });

  test("with it, they attend, and the record names what was briefed",
    async () => {
      const result = await mark({briefedInPerson: true});

      expect(result.briefedInPerson).toBe(true);
      const record = await attendance();
      expect(record.status).toBe("present");
      expect(record.briefedInPerson).toBe(true);
      expect(record.briefedLearningTitles).toEqual(["Lesson roof"]);
      // The lesson itself is still due.
      expect(ids(await outstandingNeededToday(
        ORG,
        "worker-1",
        require("../lib/worker_learning_callable").todaysMeetingDate()
      ))).toEqual(["roof"]);
    });

  test("a worker with nothing outstanding is never recorded as briefed",
    async () => {
      await complete("worker-1", "roof");

      await mark({briefedInPerson: true});

      const record = await attendance();
      expect(record.briefedInPerson).toBe(false);
      expect(record.briefedLearningTitles).toEqual([]);
    });
});
