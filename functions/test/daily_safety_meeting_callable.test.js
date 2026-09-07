/**
 * Business-logic tests for `daily_safety_meeting_callable.ts`
 * (`createDailySafetyMeeting`, `recordMeetingAttendance`,
 * `addMeetingConcern`), focused on cross-organization authorization.
 *
 * Mirrors `hazard_callable.test.js`'s shape: these invoke each callable's
 * own exported handler via `.run(request)` — the same code path Cloud
 * Functions itself calls — against a running Firestore emulator, so they
 * exercise the ADMIN-SDK BUSINESS LOGIC that `firestore.rules.test.js`
 * structurally cannot reach (rules are bypassed by the Admin SDK entirely).
 *
 * This suite exists specifically to close the gap identified in the
 * organization-isolation audit: prior to this file, Daily Safety Meetings
 * had zero callable-level tests, so `requireActiveForeman`/
 * `requireSiteMatches`/`requireActivitiesAtSite`/`requireActiveMeetingPoints`
 * and the attendance/concern cross-org checks were verified only by code
 * inspection.
 *
 * Requires the Firestore emulator — see `npm run test:callables`, which
 * wraps this suite in `firebase emulators:exec` exactly like `test:rules`.
 * Requires JDK 21+, per `test/README.md`.
 */

const {initializeApp, getApps, deleteApp} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");

const PROJECT_ID = "jva-safety-rules-test";
const ORG_A = "org-alpha";
const ORG_B = "org-beta";

let app;
let db;
let createDailySafetyMeeting;
let recordMeetingAttendance;
let addMeetingConcern;

beforeAll(() => {
  process.env.GCLOUD_PROJECT = PROJECT_ID;
  if (!process.env.FIRESTORE_EMULATOR_HOST) {
    process.env.FIRESTORE_EMULATOR_HOST = "127.0.0.1:8080";
  }

  app = getApps()[0] ?? initializeApp({projectId: PROJECT_ID});
  db = getFirestore(app);

  ({createDailySafetyMeeting, recordMeetingAttendance, addMeetingConcern} =
    require("../lib/daily_safety_meeting_callable"));
});

afterAll(async () => {
  if (app) await deleteApp(app);
});

async function clearFirestore() {
  const collections = await db.listCollections();
  await Promise.all(collections.map((c) => db.recursiveDelete(c)));
}

function profile(uid, overrides = {}) {
  return {
    uid,
    name: "Test User",
    email: `${uid}@example.com`,
    accountStatus: "active",
    ...overrides,
  };
}

/**
 * Seeds a `users/{uid}/memberships/{organizationId}` document — the source
 * of truth for organization/role/site membership under the multi-org model.
 */
async function seedMembership(
  uid, organizationId, role, siteIds, overrides = {}
) {
  await db.doc(`users/${uid}/memberships/${organizationId}`).set({
    organizationId,
    role,
    workerType: null,
    trade: null,
    siteIds,
    supervisorUid: null,
    status: "active",
    approvedAt: new Date(),
    approvedBy: "approver-a",
    createdAt: new Date(),
    updatedAt: new Date(),
    ...overrides,
  });
}

async function seedForeman(uid, siteId = "site-1", overrides = {}) {
  const {
    organizationId = ORG_A, membershipStatus, ...profileOverrides
  } = overrides;
  await db.doc(`users/${uid}`).set(profile(uid, profileOverrides));
  await seedMembership(uid, organizationId, "foreman", [siteId],
    membershipStatus ? {status: membershipStatus} : {});
}

async function seedWorker(uid, siteId = "site-1", overrides = {}) {
  const {
    organizationId = ORG_A, membershipStatus, ...profileOverrides
  } = overrides;
  await db.doc(`users/${uid}`).set(profile(uid, profileOverrides));
  await seedMembership(uid, organizationId, "worker", [siteId],
    membershipStatus ? {status: membershipStatus} : {});
}

async function seedSite(orgId, id = "site-1", overrides = {}) {
  await db.doc(`organizations/${orgId}/sites/${id}`).set({
    organizationId: orgId,
    projectId: "project-1",
    name: "Test Site",
    status: "active",
    ...overrides,
  });
}

async function seedActivity(orgId, id, overrides = {}) {
  await db.doc(`organizations/${orgId}/activities/${id}`).set({
    organizationId: orgId,
    projectId: "project-1",
    siteId: "site-1",
    name: "Roofing",
    code: `CODE-${id}`,
    status: "active",
    ...overrides,
  });
}

async function seedMeetingPoint(orgId, id, overrides = {}) {
  await db.doc(`organizations/${orgId}/safety_meeting_points/${id}`).set({
    organizationId: orgId,
    title: "Working at Height",
    category: "height",
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
    startTime: new Date(),
    endTime: null,
    foremanId: "foreman-a",
    activityIds: [],
    meetingPointIds: [],
    status: "inProgress",
    concerns: [],
    correctiveActionIds: [],
    createdAt: new Date(),
    completedAt: null,
    ...overrides,
  });
}

function callRequest(uid, data) {
  return {
    auth: {uid, token: {}},
    data,
    rawRequest: {},
  };
}

async function getMeeting(orgId, id) {
  const snapshot = await db.doc(
    `organizations/${orgId}/daily_safety_meetings/${id}`
  ).get();
  return snapshot.data();
}

beforeEach(async () => {
  await clearFirestore();
  await seedSite(ORG_A);
  await seedForeman("foreman-a");
});

describe("createDailySafetyMeeting", () => {
  test("an active foreman with site access can start a meeting",
    async () => {
      const result = await createDailySafetyMeeting.run(
        callRequest("foreman-a", {
          organizationId: ORG_A,
          projectId: "project-1",
          siteId: "site-1",
        })
      );

      expect(result.organizationId).toBe(ORG_A);
      const meeting = await getMeeting(ORG_A, result.id);
      expect(meeting.organizationId).toBe(ORG_A);
      expect(meeting.siteId).toBe("site-1");
      expect(meeting.foremanId).toBe("foreman-a");
    });

  test("a foreman from another organization is refused", async () => {
    await seedForeman("foreman-b", "site-1", {organizationId: ORG_B});

    await expect(
      createDailySafetyMeeting.run(
        callRequest("foreman-b", {
          organizationId: ORG_A,
          projectId: "project-1",
          siteId: "site-1",
        })
      )
    ).rejects.toThrow();
  });

  test("a foreman cannot create a meeting by claiming another " +
    "organization's own site id even though their profile is in Org A",
  async () => {
    // foreman-a is in ORG_A with siteIds: ["site-1"], but ORG_B also has
    // a site literally named "site-1" — the caller must not be able to
    // create a meeting under ORG_B by naming their own site id if their
    // own organizationId doesn't match.
    await seedSite(ORG_B, "site-1");

    await expect(
      createDailySafetyMeeting.run(
        callRequest("foreman-a", {
          organizationId: ORG_B,
          projectId: "project-1",
          siteId: "site-1",
        })
      )
    ).rejects.toThrow();
  });

  test("a site id that only exists in another organization is refused",
    async () => {
      await seedSite(ORG_B, "ambassadors-site");

      await expect(
        createDailySafetyMeeting.run(
          callRequest("foreman-a", {
            organizationId: ORG_A,
            projectId: "project-1",
            siteId: "ambassadors-site",
          })
        )
      ).rejects.toThrow();
    });

  test("a site whose own organizationId does not match the given " +
    "organizationId is refused, even at the same path", async () => {
    // Simulates a corrupted/forged site document rather than a normal
    // cross-org id collision — requireSiteMatches must check the site's
    // OWN organizationId field, not just trust the path.
    await db.doc(`organizations/${ORG_A}/sites/mismatched-site`).set({
      organizationId: ORG_B,
      projectId: "project-1",
      name: "Mismatched",
      status: "active",
    });
    await seedForeman("foreman-a", "mismatched-site");

    await expect(
      createDailySafetyMeeting.run(
        callRequest("foreman-a", {
          organizationId: ORG_A,
          projectId: "project-1",
          siteId: "mismatched-site",
        })
      )
    ).rejects.toThrow();
  });

  test("a site belonging to a different project within the same " +
    "organization is refused", async () => {
    await seedSite(ORG_A, "site-1", {projectId: "project-1"});

    await expect(
      createDailySafetyMeeting.run(
        callRequest("foreman-a", {
          organizationId: ORG_A,
          projectId: "project-2",
          siteId: "site-1",
        })
      )
    ).rejects.toThrow();
  });

  test("an activity id that only exists in another organization is " +
    "refused, even with the same literal id", async () => {
    await seedActivity(ORG_B, "activity-1");

    await expect(
      createDailySafetyMeeting.run(
        callRequest("foreman-a", {
          organizationId: ORG_A,
          projectId: "project-1",
          siteId: "site-1",
          activityIds: ["activity-1"],
        })
      )
    ).rejects.toThrow(/not active at this site/);
  });

  test("an activity id that exists in the right organization but at a " +
    "different site is refused", async () => {
    await seedActivity(ORG_A, "activity-1", {siteId: "site-2"});

    await expect(
      createDailySafetyMeeting.run(
        callRequest("foreman-a", {
          organizationId: ORG_A,
          projectId: "project-1",
          siteId: "site-1",
          activityIds: ["activity-1"],
        })
      )
    ).rejects.toThrow(/not active at this site/);
  });

  test("a valid same-organization, same-site activity id succeeds",
    async () => {
      await seedActivity(ORG_A, "activity-1", {siteId: "site-1"});

      const result = await createDailySafetyMeeting.run(
        callRequest("foreman-a", {
          organizationId: ORG_A,
          projectId: "project-1",
          siteId: "site-1",
          activityIds: ["activity-1"],
        })
      );

      const meeting = await getMeeting(ORG_A, result.id);
      expect(meeting.activityIds).toEqual(["activity-1"]);
    });

  test("a meeting point id that only exists in another organization is " +
    "refused, even with the same literal id", async () => {
    await seedMeetingPoint(ORG_B, "point-1");

    await expect(
      createDailySafetyMeeting.run(
        callRequest("foreman-a", {
          organizationId: ORG_A,
          projectId: "project-1",
          siteId: "site-1",
          meetingPointIds: ["point-1"],
        })
      )
    ).rejects.toThrow(/not active/);
  });

  test("a valid same-organization meeting point id succeeds", async () => {
    await seedMeetingPoint(ORG_A, "point-1");

    const result = await createDailySafetyMeeting.run(
      callRequest("foreman-a", {
        organizationId: ORG_A,
        projectId: "project-1",
        siteId: "site-1",
        meetingPointIds: ["point-1"],
      })
    );

    const meeting = await getMeeting(ORG_A, result.id);
    expect(meeting.meetingPointIds).toEqual(["point-1"]);
  });

  test("a non-foreman role is refused", async () => {
    await seedWorker("worker-a", "site-1");

    await expect(
      createDailySafetyMeeting.run(
        callRequest("worker-a", {
          organizationId: ORG_A,
          projectId: "project-1",
          siteId: "site-1",
        })
      )
    ).rejects.toThrow();
  });

  test("a foreman without access to the given site is refused", async () => {
    await seedForeman("foreman-c", "some-other-site");

    await expect(
      createDailySafetyMeeting.run(
        callRequest("foreman-c", {
          organizationId: ORG_A,
          projectId: "project-1",
          siteId: "site-1",
        })
      )
    ).rejects.toThrow();
  });
});

describe("recordMeetingAttendance", () => {
  test("the meeting's own foreman can record a worker's attendance",
    async () => {
      await seedMeeting(ORG_A, "meeting-1");
      await seedWorker("worker-a", "site-1");

      const result = await recordMeetingAttendance.run(
        callRequest("foreman-a", {
          organizationId: ORG_A,
          meetingId: "meeting-1",
          workerId: "worker-a",
          status: "present",
        })
      );

      expect(result.status).toBe("present");
    });

  test("a worker from another organization cannot be marked attendant, " +
    "even with the same literal uid pattern", async () => {
    await seedMeeting(ORG_A, "meeting-1");
    await seedWorker("worker-b", "site-1", {organizationId: ORG_B});

    await expect(
      recordMeetingAttendance.run(
        callRequest("foreman-a", {
          organizationId: ORG_A,
          meetingId: "meeting-1",
          workerId: "worker-b",
          status: "present",
        })
      )
    ).rejects.toThrow(/does not belong to the given organization/);
  });

  test("a foreman from another organization cannot record attendance on " +
    "an Org A meeting by naming Org A's organizationId", async () => {
    await seedMeeting(ORG_A, "meeting-1");
    await seedForeman("foreman-b", "site-1", {organizationId: ORG_B});
    await seedWorker("worker-a", "site-1");

    await expect(
      recordMeetingAttendance.run(
        callRequest("foreman-b", {
          organizationId: ORG_A,
          meetingId: "meeting-1",
          workerId: "worker-a",
          status: "present",
        })
      )
    ).rejects.toThrow();
  });

  test("a meeting id that only exists in another organization is refused",
    async () => {
      await seedSite(ORG_B, "site-b");
      await seedMeeting(ORG_B, "meeting-1", {siteId: "site-b"});
      await seedWorker("worker-a", "site-1");

      await expect(
        recordMeetingAttendance.run(
          callRequest("foreman-a", {
            organizationId: ORG_A,
            meetingId: "meeting-1",
            workerId: "worker-a",
            status: "present",
          })
        )
      ).rejects.toThrow();
    });
});

describe("addMeetingConcern", () => {
  test("the meeting's own foreman can add a concern", async () => {
    await seedMeeting(ORG_A, "meeting-1");

    const result = await addMeetingConcern.run(
      callRequest("foreman-a", {
        organizationId: ORG_A,
        meetingId: "meeting-1",
        description: "Loose scaffolding",
        category: "safety",
      })
    );

    expect(result.meetingId).toBe("meeting-1");
  });

  test("a foreman from another organization cannot add a concern to an " +
    "Org A meeting", async () => {
    await seedMeeting(ORG_A, "meeting-1");
    await seedForeman("foreman-b", "site-1", {organizationId: ORG_B});

    await expect(
      addMeetingConcern.run(
        callRequest("foreman-b", {
          organizationId: ORG_A,
          meetingId: "meeting-1",
          description: "Should be refused",
          category: "safety",
        })
      )
    ).rejects.toThrow();
  });

  test("a meeting id that only exists in another organization is refused",
    async () => {
      await seedSite(ORG_B, "site-b");
      await seedMeeting(ORG_B, "meeting-1", {siteId: "site-b"});

      await expect(
        addMeetingConcern.run(
          callRequest("foreman-a", {
            organizationId: ORG_A,
            meetingId: "meeting-1",
            description: "Should be refused",
            category: "safety",
          })
        )
      ).rejects.toThrow();
    });
});
