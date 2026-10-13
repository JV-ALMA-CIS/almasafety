/**
 * Business-logic tests for `safety_meeting_callable.ts` — recording the
 * weekly employee and monthly supervisory safety meetings. Run against the
 * Firestore emulator via `npm run test:callables`.
 */

const {initializeApp, getApps, deleteApp} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");

const PROJECT_ID = "jva-safety-rules-test";
const ORG_A = "org-alpha";

let app;
let db;
let fns;

beforeAll(() => {
  process.env.GCLOUD_PROJECT = PROJECT_ID;
  if (!process.env.FIRESTORE_EMULATOR_HOST) {
    process.env.FIRESTORE_EMULATOR_HOST = "127.0.0.1:8080";
  }
  app = getApps()[0] ?? initializeApp({projectId: PROJECT_ID});
  db = getFirestore(app);
  fns = require("../lib/safety_meeting_callable");
});

afterAll(async () => {
  if (app) await deleteApp(app);
});

async function clearFirestore() {
  const collections = await db.listCollections();
  await Promise.all(collections.map((c) => db.recursiveDelete(c)));
}

async function seedPerson(uid, role, siteIds = [], name = "Test User",
  {membershipStatus = "active", organizationId = ORG_A} = {}) {
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
    status: membershipStatus,
  });
}

function today() {
  return new Date().toISOString().slice(0, 10);
}

function daysAgo(days) {
  return new Date(Date.now() - days * 24 * 60 * 60 * 1000)
    .toISOString().slice(0, 10);
}

function call(uid, data) {
  return {auth: {uid, token: {}}, data: {organizationId: ORG_A, ...data},
    rawRequest: {}};
}

function weekly(overrides = {}) {
  return {
    kind: "weeklyEmployee",
    siteId: "site-1",
    date: today(),
    topics: ["PPE", "Emergency numbers"],
    attendeeUids: ["worker-a"],
    ...overrides,
  };
}

async function getMeeting(id) {
  return (await db.doc(`organizations/${ORG_A}/safety_meetings/${id}`).get())
    .data();
}

beforeEach(async () => {
  await clearFirestore();
  await db.doc(`organizations/${ORG_A}/sites/site-1`).set({
    organizationId: ORG_A, projectId: "project-1", name: "Rosslyn Ridge",
  });
  await db.doc(`organizations/${ORG_A}/sites/site-2`).set({
    organizationId: ORG_A, projectId: "project-1", name: "Other site",
  });
  await seedPerson("manager-a", "siteManager", [], "Eston Gikonyo");
  await seedPerson("foreman-a", "foreman", ["site-1"], "Fred Foreman");
  await seedPerson("worker-a", "worker", ["site-1"], "Wanjiru Worker");
  await seedPerson("worker-b", "worker", ["site-1"], "Suspended Sam",
    {membershipStatus: "suspended"});
  await seedPerson("outsider", "worker", [], "Other Org",
    {organizationId: "org-beta"});
});

describe("weekly employee meeting", () => {
  test("a Foreman records one for their own site", async () => {
    const {id} = await fns.recordSafetyMeeting.run(call("foreman-a", weekly({
      attendeeUids: ["worker-a", "manager-a"],
      otherAttendees: ["  Visiting electrician  ", ""],
      concerns: ["Extinguisher at gate missing"],
      notes: "Good turnout",
    })));
    const meeting = await getMeeting(id);
    expect(meeting).toMatchObject({
      kind: "weeklyEmployee",
      siteId: "site-1",
      siteName: "Rosslyn Ridge",
      date: today(),
      topics: ["PPE", "Emergency numbers"],
      attendeeUids: ["worker-a", "manager-a"],
      attendeeNames: {"worker-a": "Wanjiru Worker",
        "manager-a": "Eston Gikonyo"},
      otherAttendees: ["Visiting electrician"],
      attendeeCount: 3,
      concerns: ["Extinguisher at gate missing"],
      notes: "Good turnout",
      facilitatorUid: "foreman-a",
      facilitatorName: "Fred Foreman",
    });
    expect(meeting.createdAt).toBeDefined();
  });

  test("a Foreman cannot record one for another site", async () => {
    await expect(fns.recordSafetyMeeting.run(
      call("foreman-a", weekly({siteId: "site-2"}))
    )).rejects.toThrow(/permission/);
  });

  test("a Site Manager can record one for any site", async () => {
    const {id} = await fns.recordSafetyMeeting.run(
      call("manager-a", weekly({siteId: "site-2"}))
    );
    expect((await getMeeting(id)).siteName).toBe("Other site");
  });

  test("needs a site", async () => {
    await expect(fns.recordSafetyMeeting.run(
      call("manager-a", weekly({siteId: null}))
    )).rejects.toThrow(/site/);
  });

  test("a Worker cannot record a meeting", async () => {
    await expect(fns.recordSafetyMeeting.run(call("worker-a", weekly())))
      .rejects.toThrow(/permission/);
  });
});

describe("monthly supervisory meeting", () => {
  test("a Site Manager records one for every site", async () => {
    const {id} = await fns.recordSafetyMeeting.run(call("manager-a", {
      kind: "monthlySupervisory",
      date: today(),
      topics: ["Open deficiencies"],
      attendeeUids: ["foreman-a"],
    }));
    const meeting = await getMeeting(id);
    expect(meeting.siteId).toBeNull();
    expect(meeting.siteName).toBeNull();
    expect(meeting.kind).toBe("monthlySupervisory");
  });

  test("a Foreman cannot record one", async () => {
    await expect(fns.recordSafetyMeeting.run(call("foreman-a", {
      kind: "monthlySupervisory",
      siteId: "site-1",
      date: today(),
      topics: ["Open deficiencies"],
      attendeeUids: ["worker-a"],
    }))).rejects.toThrow(/permission/);
  });
});

describe("validation", () => {
  test("needs at least one subject", async () => {
    await expect(fns.recordSafetyMeeting.run(
      call("manager-a", weekly({topics: ["  "]}))
    )).rejects.toThrow(/subject/);
  });

  test("needs at least one attendee", async () => {
    await expect(fns.recordSafetyMeeting.run(
      call("manager-a", weekly({attendeeUids: [], otherAttendees: []}))
    )).rejects.toThrow(/attended/);
  });

  test("someone without an account alone is enough", async () => {
    const {id} = await fns.recordSafetyMeeting.run(call("manager-a",
      weekly({attendeeUids: [], otherAttendees: ["Site visitor"]})));
    expect((await getMeeting(id)).attendeeCount).toBe(1);
  });

  test("attendees must be active members of the organization", async () => {
    for (const uid of ["worker-b", "outsider", "nobody"]) {
      await expect(fns.recordSafetyMeeting.run(
        call("manager-a", weekly({attendeeUids: [uid]}))
      )).rejects.toThrow(/attendees/);
    }
  });

  test("rejects an unknown kind", async () => {
    await expect(fns.recordSafetyMeeting.run(
      call("manager-a", weekly({kind: "daily"}))
    )).rejects.toThrow(/kind/);
  });

  test("dates: not in the future, not too old, real dates only", async () => {
    const future = new Date(Date.now() + 3 * 24 * 60 * 60 * 1000)
      .toISOString().slice(0, 10);
    for (const date of [future, daysAgo(40), "2026-02-30", "13/10/2026"]) {
      await expect(fns.recordSafetyMeeting.run(
        call("manager-a", weekly({date}))
      )).rejects.toThrow();
    }
    const {id} = await fns.recordSafetyMeeting.run(
      call("manager-a", weekly({date: daysAgo(6)}))
    );
    expect((await getMeeting(id)).date).toBe(daysAgo(6));
  });

  test("an unknown site is refused", async () => {
    await expect(fns.recordSafetyMeeting.run(
      call("manager-a", weekly({siteId: "site-x"}))
    )).rejects.toThrow(/site/);
  });
});
