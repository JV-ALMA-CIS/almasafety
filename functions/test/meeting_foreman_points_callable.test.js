/**
 * Daily Safety Meetings — the Foreman's own points:
 * `saveMeetingForemanPoint` / `removeMeetingForemanPoint`, and
 * `completeDailySafetyMeeting` counting them the same as library points.
 *
 * Runs each callable's handler via `.run(request)` against the Firestore
 * emulator, like `meeting_record_callable.test.js`. Requires JDK 21+ (see
 * `test/README.md`).
 */

const {initializeApp, getApps, deleteApp} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");

const PROJECT_ID = "jva-safety-rules-test";
const ORG_A = "org-alpha";
const ORG_B = "org-beta";
const POINT_ID = "pointAbc12345";

let app;
let db;
let meetings;

beforeAll(() => {
  process.env.GCLOUD_PROJECT = PROJECT_ID;
  if (!process.env.FIRESTORE_EMULATOR_HOST) {
    process.env.FIRESTORE_EMULATOR_HOST = "127.0.0.1:8080";
  }
  app = getApps()[0] ?? initializeApp({projectId: PROJECT_ID});
  db = getFirestore(app);
  meetings = require("../lib/daily_safety_meeting_callable");
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

async function seedUser(uid, organizationId, role, siteIds) {
  await db.doc(`users/${uid}`).set({
    uid,
    name: uid,
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

async function seedMeeting(orgId, id, overrides = {}) {
  await db.doc(`organizations/${orgId}/daily_safety_meetings/${id}`).set({
    organizationId: orgId,
    projectId: "project-1",
    siteId: "site-1",
    date: "2026-10-29",
    foremanId: "foreman-a",
    activityIds: ["act-roof"],
    meetingPointIds: [],
    status: "inProgress",
    concerns: [],
    correctiveActionIds: [],
    createdAt: new Date(),
    ...overrides,
  });
}

/** A Foreman at site-1 with an in-progress roofing meeting, no points. */
async function seedRoofingMeeting(overrides = {}) {
  await seedUser("foreman-a", ORG_A, "foreman", ["site-1"]);
  await db.doc(`organizations/${ORG_A}/sites/site-1`).set({
    organizationId: ORG_A,
    projectId: "project-1",
    name: "Site 1",
    status: "active",
  });
  await db.doc(`organizations/${ORG_A}/activities/act-roof`).set({
    organizationId: ORG_A,
    projectId: "project-1",
    siteId: "site-1",
    name: "Roofing",
    code: "ROOF",
    status: "active",
  });
  await seedMeeting(ORG_A, "meeting-1", overrides);
}

function save(uid, data) {
  return meetings.saveMeetingForemanPoint.run(callRequest(uid, {
    organizationId: ORG_A,
    meetingId: "meeting-1",
    pointId: POINT_ID,
    title: "Wet roof sheets after rain",
    ...data,
  }));
}

function remove(uid, data = {}) {
  return meetings.removeMeetingForemanPoint.run(callRequest(uid, {
    organizationId: ORG_A,
    meetingId: "meeting-1",
    pointId: POINT_ID,
    ...data,
  }));
}

function complete(uid = "foreman-a") {
  return meetings.completeDailySafetyMeeting.run(callRequest(uid, {
    organizationId: ORG_A,
    id: "meeting-1",
    crewOutcome: "go",
  }));
}

async function storedPoint(id = POINT_ID) {
  return (await db.doc(
    `organizations/${ORG_A}/daily_safety_meetings/meeting-1` +
      `/foreman_points/${id}`
  ).get()).data();
}

async function auditActions() {
  const snapshot = await db
    .collection("audit_logs")
    .where("targetDocId", "==", "meeting-1")
    .get();
  return snapshot.docs.map((doc) => doc.data());
}

describe("saveMeetingForemanPoint", () => {
  test("stores the Foreman's point on the meeting only — never the library",
    async () => {
      await seedRoofingMeeting();
      const result = await save("foreman-a", {
        note: "Crew to wait for sheets to dry; no walking on wet sheets.",
        activityId: "act-roof",
      });

      expect(result).toEqual(
        {id: POINT_ID, organizationId: ORG_A, meetingId: "meeting-1"}
      );
      const point = await storedPoint();
      expect(point).toMatchObject({
        meetingId: "meeting-1",
        organizationId: ORG_A,
        siteId: "site-1",
        title: "Wet roof sheets after rain",
        note: "Crew to wait for sheets to dry; no walking on wet sheets.",
        activityId: "act-roof",
        recordedBy: "foreman-a",
      });
      expect(point.createdAt).toBeDefined();
      const library = await db
        .collection(`organizations/${ORG_A}/safety_meeting_points`)
        .get();
      expect(library.empty).toBe(true);
    });

  test("the note and activity are optional", async () => {
    await seedRoofingMeeting();
    await save("foreman-a", {});
    expect(await storedPoint()).toMatchObject({note: null, activityId: null});
  });

  test("keeps the meeting's foremanPointCount in step — re-sends and edits " +
    "do not count twice", async () => {
    await seedRoofingMeeting();
    const count = async () => (await db
      .doc(`organizations/${ORG_A}/daily_safety_meetings/meeting-1`)
      .get()).data().foremanPointCount;

    await save("foreman-a", {});
    await save("foreman-a", {});
    await save("foreman-a", {note: "Edited"});
    expect(await count()).toBe(1);
    await save("foreman-a", {pointId: "secondPoint12"});
    expect(await count()).toBe(2);
    await remove("foreman-a");
    await remove("foreman-a");
    expect(await count()).toBe(1);
  });

  test("sending the same point twice (no signal, then signal) stores it " +
    "once and writes one audit entry", async () => {
    await seedRoofingMeeting();
    await save("foreman-a", {note: "Same words"});
    await save("foreman-a", {note: "Same words"});

    const points = await db
      .collection(
        `organizations/${ORG_A}/daily_safety_meetings/meeting-1/foreman_points`
      )
      .get();
    expect(points.size).toBe(1);
    const entries = await auditActions();
    expect(entries.map((e) => e.action)).toEqual(["meeting.foremanPointAdded"]);
  });

  test("edits the point while the meeting is in progress", async () => {
    await seedRoofingMeeting();
    await save("foreman-a", {note: "First"});
    await save("foreman-a", {title: "Wet sheets", note: "Second"});

    expect(await storedPoint()).toMatchObject({
      title: "Wet sheets",
      note: "Second",
    });
  });

  test("can ADD a point after completion, but not edit one", async () => {
    await seedRoofingMeeting({meetingPointIds: ["point-height"]});
    await save("foreman-a", {note: "Before completion"});
    await complete();

    await meetings.saveMeetingForemanPoint.run(callRequest("foreman-a", {
      organizationId: ORG_A,
      meetingId: "meeting-1",
      pointId: "laterPoint123",
      title: "Remembered back at the office",
    }));
    expect(await storedPoint("laterPoint123")).toMatchObject({
      title: "Remembered back at the office",
    });

    await expect(save("foreman-a", {note: "Changed afterwards"}))
      .rejects.toMatchObject({code: "failed-precondition"});
    expect((await storedPoint()).note).toBe("Before completion");

    // The same point re-sent unchanged after completion is still fine.
    await save("foreman-a", {note: "Before completion"});

    const added = (await auditActions())
      .filter((e) => e.action === "meeting.foremanPointAdded")
      .map((e) => e.metadata.afterCompletion)
      .sort();
    expect(added).toEqual([false, true]);
  });

  test("refuses an activity that is not on the meeting", async () => {
    await seedRoofingMeeting();
    await expect(save("foreman-a", {activityId: "act-paint"}))
      .rejects.toMatchObject({code: "failed-precondition"});
    expect(await storedPoint()).toBeUndefined();
  });

  test("keeps an edit working after its activity was taken off the meeting",
    async () => {
      await seedRoofingMeeting();
      await save("foreman-a", {activityId: "act-roof"});
      await db.doc(`organizations/${ORG_A}/daily_safety_meetings/meeting-1`)
        .update({activityIds: []});
      await save("foreman-a", {activityId: "act-roof", note: "Added later"});
      expect((await storedPoint()).note).toBe("Added later");
    });

  test("refuses a title or note that is too long", async () => {
    await seedRoofingMeeting();
    await expect(save("foreman-a", {title: "x".repeat(121)}))
      .rejects.toMatchObject({code: "invalid-argument"});
    await expect(save("foreman-a", {note: "x".repeat(501)}))
      .rejects.toMatchObject({code: "invalid-argument"});
    await save("foreman-a", {title: "x".repeat(120), note: "y".repeat(500)});
    expect((await storedPoint()).title).toHaveLength(120);
  });

  test("refuses a missing title and a pointId that could name another path",
    async () => {
      await seedRoofingMeeting();
      await expect(save("foreman-a", {title: "   "}))
        .rejects.toMatchObject({code: "invalid-argument"});
      for (const pointId of ["../concerns/x", "short", "a/b/c/d/e/f/g/h"]) {
        await expect(save("foreman-a", {pointId}))
          .rejects.toMatchObject({code: "invalid-argument"});
      }
    });

  test("refuses another Foreman, a worker, another organization and a " +
    "signed-out caller with the same opaque refusal", async () => {
    await seedRoofingMeeting();
    await seedUser("foreman-b", ORG_A, "foreman", ["site-1"]);
    await seedUser("worker-a", ORG_A, "worker", ["site-1"]);
    await seedUser("foreman-x", ORG_B, "foreman", ["site-1"]);
    await seedMeeting(ORG_B, "meeting-1", {foremanId: "foreman-x"});

    for (const uid of ["foreman-b", "worker-a"]) {
      await expect(save(uid, {}))
        .rejects.toMatchObject({code: "permission-denied"});
    }
    // ORG_B's own Foreman cannot reach ORG_A's meeting of the same id.
    await expect(save("foreman-x", {}))
      .rejects.toMatchObject({code: "permission-denied"});
    await expect(save(null, {}))
      .rejects.toMatchObject({code: "permission-denied"});
    expect(await storedPoint()).toBeUndefined();
  });

  test("the audit entry records what changed, never the typed words",
    async () => {
      await seedRoofingMeeting();
      await save("foreman-a", {note: "Secret-ish words"});
      await save("foreman-a", {
        title: "New title",
        note: "Other words",
        activityId: "act-roof",
      });

      const entries = await auditActions();
      const updated = entries.find(
        (e) => e.action === "meeting.foremanPointUpdated"
      );
      expect(updated.actorUid).toBe("foreman-a");
      expect(updated.metadata).toEqual({
        pointId: POINT_ID,
        titleChanged: true,
        noteChanged: true,
        before: {activityId: null},
        after: {activityId: "act-roof"},
      });
      const text = JSON.stringify(entries);
      expect(text).not.toContain("Secret-ish");
      expect(text).not.toContain("Other words");
      expect(text).not.toContain("New title");
    });
});

describe("removeMeetingForemanPoint", () => {
  test("removes the point and records it", async () => {
    await seedRoofingMeeting();
    await save("foreman-a", {});
    await remove("foreman-a");

    expect(await storedPoint()).toBeUndefined();
    expect((await auditActions()).map((e) => e.action).sort())
      .toEqual(["meeting.foremanPointAdded", "meeting.foremanPointRemoved"]);
  });

  test("removing an already-removed point succeeds without a second entry",
    async () => {
      await seedRoofingMeeting();
      await save("foreman-a", {});
      await remove("foreman-a");
      await remove("foreman-a");
      const removed = (await auditActions())
        .filter((e) => e.action === "meeting.foremanPointRemoved");
      expect(removed).toHaveLength(1);
    });

  test("refuses once the meeting is completed, and for another Foreman",
    async () => {
      await seedRoofingMeeting();
      await seedUser("foreman-b", ORG_A, "foreman", ["site-1"]);
      await save("foreman-a", {});

      await expect(remove("foreman-b"))
        .rejects.toMatchObject({code: "permission-denied"});
      await complete();
      await expect(remove("foreman-a"))
        .rejects.toMatchObject({code: "failed-precondition"});
      expect(await storedPoint()).toBeDefined();
    });
});

describe("completing a meeting with the Foreman's own points", () => {
  test("completes with only the Foreman's own points and no library point",
    async () => {
      await seedRoofingMeeting();
      await save("foreman-a", {});

      const result = await complete();
      expect(result.status).toBe("completed");
      const completed = (await auditActions())
        .find((e) => e.action === "meeting.completed");
      expect(completed.metadata).toMatchObject({
        meetingPointIds: [],
        foremanPointCount: 1,
      });
    });

  test("still refuses with no point of either kind", async () => {
    await seedRoofingMeeting();
    await expect(complete()).rejects.toMatchObject({
      code: "failed-precondition",
      message: expect.stringContaining("one meeting point"),
    });
  });

  test("still refuses with points but no activity", async () => {
    await seedRoofingMeeting();
    await save("foreman-a", {});
    await db.doc(`organizations/${ORG_A}/daily_safety_meetings/meeting-1`)
      .update({activityIds: []});
    await expect(complete())
      .rejects.toMatchObject({code: "failed-precondition"});
  });
});
