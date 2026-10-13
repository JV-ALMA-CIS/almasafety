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
let completeDailySafetyMeeting;
let recordMeetingAttendance;
let getMeetingAttendeeLearningStatus;
let getSiteCrewReadiness;
let addMeetingConcern;
let updateMeetingConcern;
let removeMeetingConcern;
let setMeetingPointNote;
let removeMeetingPointNote;
let addMeetingEvidence;
let removeMeetingEvidence;

beforeAll(() => {
  process.env.GCLOUD_PROJECT = PROJECT_ID;
  if (!process.env.FIRESTORE_EMULATOR_HOST) {
    process.env.FIRESTORE_EMULATOR_HOST = "127.0.0.1:8080";
  }

  app = getApps()[0] ?? initializeApp({projectId: PROJECT_ID});
  db = getFirestore(app);

  ({
    createDailySafetyMeeting,
    completeDailySafetyMeeting,
    recordMeetingAttendance,
    getMeetingAttendeeLearningStatus,
    getSiteCrewReadiness,
    addMeetingConcern,
    updateMeetingConcern,
    removeMeetingConcern,
    setMeetingPointNote,
    removeMeetingPointNote,
    addMeetingEvidence,
    removeMeetingEvidence,
  } = require("../lib/daily_safety_meeting_callable"));
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

async function seedSafetyLearning(orgId, id, overrides = {}) {
  await db.doc(`organizations/${orgId}/safety_learning/${id}`).set({
    organizationId: orgId,
    title: `Learning ${id}`,
    type: "document",
    contentReference: `ref-${id}`,
    status: "active",
    createdAt: new Date(),
    updatedAt: new Date(),
    ...overrides,
  });
}

async function seedSafetyRequirement(orgId, id, overrides = {}) {
  await db.doc(`organizations/${orgId}/safety_requirements/${id}`).set({
    organizationId: orgId,
    name: `Requirement ${id}`,
    category: "General",
    risk: "medium",
    requiredLearningIds: [],
    status: "active",
    createdAt: new Date(),
    updatedAt: new Date(),
    ...overrides,
  });
}

async function seedWorkerLearningRecord(orgId, workerUid, learningId, status) {
  await db
    .doc(
      `organizations/${orgId}/worker_learning_records/` +
        `${workerUid}_${learningId}`
    )
    .set({
      workerUid,
      organizationId: orgId,
      learningId,
      status,
      assignedAt: new Date(),
      ...(status === "completed" ? {completedAt: new Date()} : {}),
    });
}

async function seedAssignment(orgId, activityId, uid, siteId) {
  await db
    .doc(
      `organizations/${orgId}/activities/${activityId}/assignments/${uid}`
    )
    .set({
      uid,
      organizationId: orgId,
      siteId,
      activityId,
      assignedAt: new Date(),
      assignedBy: "assigner-1",
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

async function getPointNote(orgId, meetingId, meetingPointId) {
  const snapshot = await db.doc(
    `organizations/${orgId}/daily_safety_meetings/${meetingId}` +
      `/point_notes/${meetingPointId}`
  ).get();
  return snapshot.exists ? snapshot.data() : null;
}

async function getEvidence(orgId, meetingId, evidenceId) {
  const snapshot = await db.doc(
    `organizations/${orgId}/daily_safety_meetings/${meetingId}` +
      `/evidence/${evidenceId}`
  ).get();
  return snapshot.exists ? snapshot.data() : null;
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

describe("createDailySafetyMeeting (safety learning gate)", () => {
  test("is refused when the foreman has outstanding required learning " +
    "for this site", async () => {
    await seedSafetyLearning(ORG_A, "l1");
    await seedSafetyRequirement(ORG_A, "r1", {
      requiredLearningIds: ["l1"],
      siteId: "site-1",
    });

    await expect(
      createDailySafetyMeeting.run(
        callRequest("foreman-a", {
          organizationId: ORG_A,
          projectId: "project-1",
          siteId: "site-1",
        })
      )
    ).rejects.toThrow(/must complete the following safety learning/);
  });

  test("is refused when the foreman has outstanding required learning " +
    "for one of the activities passed at creation time", async () => {
    await seedActivity(ORG_A, "activity-1", {siteId: "site-1"});
    await seedSafetyLearning(ORG_A, "l1");
    await seedSafetyRequirement(ORG_A, "r1", {
      requiredLearningIds: ["l1"],
      activityId: "activity-1",
    });

    await expect(
      createDailySafetyMeeting.run(
        callRequest("foreman-a", {
          organizationId: ORG_A,
          projectId: "project-1",
          siteId: "site-1",
          activityIds: ["activity-1"],
        })
      )
    ).rejects.toThrow(/must complete the following safety learning/);
  });

  test("succeeds once the foreman has completed the required learning",
    async () => {
      await seedSafetyLearning(ORG_A, "l1");
      await seedSafetyRequirement(ORG_A, "r1", {
        requiredLearningIds: ["l1"],
        siteId: "site-1",
      });
      await seedWorkerLearningRecord(ORG_A, "foreman-a", "l1", "completed");

      const result = await createDailySafetyMeeting.run(
        callRequest("foreman-a", {
          organizationId: ORG_A,
          projectId: "project-1",
          siteId: "site-1",
        })
      );

      expect(result.organizationId).toBe(ORG_A);
    });

  test("no meeting document is written when the gate refuses", async () => {
    await seedSafetyLearning(ORG_A, "l1");
    await seedSafetyRequirement(ORG_A, "r1", {
      requiredLearningIds: ["l1"],
      siteId: "site-1",
    });

    await expect(
      createDailySafetyMeeting.run(
        callRequest("foreman-a", {
          organizationId: ORG_A,
          projectId: "project-1",
          siteId: "site-1",
        })
      )
    ).rejects.toThrow();

    const collection = await db
      .collection(`organizations/${ORG_A}/daily_safety_meetings`)
      .get();
    expect(collection.empty).toBe(true);
  });
});

describe("gatesAttendance semantics (foreman gate, via " +
  "createDailySafetyMeeting)", () => {
  test("a legacy requirement with no gatesAttendance field blocks " +
    "attendance (missing/null defaults to true)", async () => {
    await seedSafetyLearning(ORG_A, "l1");
    // No gatesAttendance key at all in the write — mirrors a document
    // written before this field existed.
    await seedSafetyRequirement(ORG_A, "r1", {
      requiredLearningIds: ["l1"],
      siteId: "site-1",
    });

    await expect(
      createDailySafetyMeeting.run(
        callRequest("foreman-a", {
          organizationId: ORG_A,
          projectId: "project-1",
          siteId: "site-1",
        })
      )
    ).rejects.toThrow(/must complete the following safety learning/);
  });

  test("gatesAttendance: true blocks attendance when learning is " +
    "incomplete", async () => {
    await seedSafetyLearning(ORG_A, "l1");
    await seedSafetyRequirement(ORG_A, "r1", {
      requiredLearningIds: ["l1"],
      siteId: "site-1",
      gatesAttendance: true,
    });

    await expect(
      createDailySafetyMeeting.run(
        callRequest("foreman-a", {
          organizationId: ORG_A,
          projectId: "project-1",
          siteId: "site-1",
        })
      )
    ).rejects.toThrow(/must complete the following safety learning/);
  });

  test("gatesAttendance: false allows starting the meeting even with " +
    "incomplete learning", async () => {
    await seedSafetyLearning(ORG_A, "l1");
    await seedSafetyRequirement(ORG_A, "r1", {
      requiredLearningIds: ["l1"],
      siteId: "site-1",
      gatesAttendance: false,
    });

    const result = await createDailySafetyMeeting.run(
      callRequest("foreman-a", {
        organizationId: ORG_A,
        projectId: "project-1",
        siteId: "site-1",
      })
    );

    expect(result.organizationId).toBe(ORG_A);
  });

  test("when every applicable requirement is non-gating, incomplete " +
    "learning never blocks the meeting", async () => {
    await seedSafetyLearning(ORG_A, "l1");
    await seedSafetyLearning(ORG_A, "l2");
    await seedSafetyRequirement(ORG_A, "r1", {
      requiredLearningIds: ["l1"],
      siteId: "site-1",
      gatesAttendance: false,
    });
    await seedSafetyRequirement(ORG_A, "r2", {
      requiredLearningIds: ["l2"],
      siteId: "site-1",
      gatesAttendance: false,
    });

    const result = await createDailySafetyMeeting.run(
      callRequest("foreman-a", {
        organizationId: ORG_A,
        projectId: "project-1",
        siteId: "site-1",
      })
    );

    expect(result.organizationId).toBe(ORG_A);
  });

  test("a mix of gating and non-gating requirements: only the gating " +
    "one's incomplete learning blocks the meeting", async () => {
    await seedSafetyLearning(ORG_A, "gating-learning");
    await seedSafetyLearning(ORG_A, "non-gating-learning");
    await seedSafetyRequirement(ORG_A, "r-gating", {
      requiredLearningIds: ["gating-learning"],
      siteId: "site-1",
      gatesAttendance: true,
    });
    await seedSafetyRequirement(ORG_A, "r-non-gating", {
      requiredLearningIds: ["non-gating-learning"],
      siteId: "site-1",
      gatesAttendance: false,
    });
    // Complete only the non-gating item — the gating one is still
    // outstanding and must still block.
    await seedWorkerLearningRecord(
      ORG_A, "foreman-a", "non-gating-learning", "completed"
    );

    await expect(
      createDailySafetyMeeting.run(
        callRequest("foreman-a", {
          organizationId: ORG_A,
          projectId: "project-1",
          siteId: "site-1",
        })
      )
    ).rejects.toThrow(/must complete the following safety learning/);
  });

  test("LEARNING-ID OVERLAP: a learning id required by both a gating and " +
    "a non-gating requirement still blocks attendance while incomplete",
  async () => {
    await seedSafetyLearning(ORG_A, "L1");
    await seedSafetyLearning(ORG_A, "L2");
    await seedSafetyLearning(ORG_A, "L3");
    // Requirement A: gating, requires L1 and L2.
    await seedSafetyRequirement(ORG_A, "requirement-a", {
      requiredLearningIds: ["L1", "L2"],
      siteId: "site-1",
      gatesAttendance: true,
    });
    // Requirement B: non-gating, requires L2 and L3. L2 overlaps with A.
    await seedSafetyRequirement(ORG_A, "requirement-b", {
      requiredLearningIds: ["L2", "L3"],
      siteId: "site-1",
      gatesAttendance: false,
    });
    // Complete L1 and L3, leave L2 (the overlapping id) incomplete.
    await seedWorkerLearningRecord(ORG_A, "foreman-a", "L1", "completed");
    await seedWorkerLearningRecord(ORG_A, "foreman-a", "L3", "completed");

    await expect(
      createDailySafetyMeeting.run(
        callRequest("foreman-a", {
          organizationId: ORG_A,
          projectId: "project-1",
          siteId: "site-1",
        })
      )
    ).rejects.toThrow(/must complete the following safety learning/);
  });

  test("LEARNING-ID OVERLAP (reverse): a learning id required by a " +
    "non-gating requirement FIRST and a gating requirement SECOND still " +
    "blocks attendance while incomplete", async () => {
    await seedSafetyLearning(ORG_A, "L1");
    // Requirement A: non-gating, requires L1.
    await seedSafetyRequirement(ORG_A, "requirement-a", {
      requiredLearningIds: ["L1"],
      siteId: "site-1",
      gatesAttendance: false,
    });
    // Requirement B: gating, ALSO requires L1.
    await seedSafetyRequirement(ORG_A, "requirement-b", {
      requiredLearningIds: ["L1"],
      siteId: "site-1",
      gatesAttendance: true,
    });

    await expect(
      createDailySafetyMeeting.run(
        callRequest("foreman-a", {
          organizationId: ORG_A,
          projectId: "project-1",
          siteId: "site-1",
        })
      )
    ).rejects.toThrow(/must complete the following safety learning/);
  });

  test("LEARNING-ID OVERLAP: once the shared id is completed, the meeting " +
    "may start (non-gating requirement's contribution never blocked it " +
    "independently)", async () => {
    await seedSafetyLearning(ORG_A, "L1");
    await seedSafetyLearning(ORG_A, "L2");
    await seedSafetyRequirement(ORG_A, "requirement-a", {
      requiredLearningIds: ["L1", "L2"],
      siteId: "site-1",
      gatesAttendance: true,
    });
    await seedSafetyRequirement(ORG_A, "requirement-b", {
      requiredLearningIds: ["L2"],
      siteId: "site-1",
      gatesAttendance: false,
    });
    await seedWorkerLearningRecord(ORG_A, "foreman-a", "L1", "completed");
    await seedWorkerLearningRecord(ORG_A, "foreman-a", "L2", "completed");

    const result = await createDailySafetyMeeting.run(
      callRequest("foreman-a", {
        organizationId: ORG_A,
        projectId: "project-1",
        siteId: "site-1",
      })
    );

    expect(result.organizationId).toBe(ORG_A);
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

describe("recordMeetingAttendance (safety learning gate)", () => {
  test("is refused when marking a worker present who has outstanding " +
    "required learning for this meeting's scope", async () => {
    await seedActivity(ORG_A, "activity-1", {siteId: "site-1"});
    await seedSafetyLearning(ORG_A, "l1", {title: "Working at Height"});
    await seedSafetyRequirement(ORG_A, "r1", {
      requiredLearningIds: ["l1"],
      activityId: "activity-1",
    });
    await seedMeeting(ORG_A, "meeting-1", {activityIds: ["activity-1"]});
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
    ).rejects.toThrow(/must complete the following safety learning/);
  });

  test("still allows marking that same worker absent", async () => {
    await seedActivity(ORG_A, "activity-1", {siteId: "site-1"});
    await seedSafetyLearning(ORG_A, "l1");
    await seedSafetyRequirement(ORG_A, "r1", {
      requiredLearningIds: ["l1"],
      activityId: "activity-1",
    });
    await seedMeeting(ORG_A, "meeting-1", {activityIds: ["activity-1"]});
    await seedWorker("worker-a", "site-1");

    const result = await recordMeetingAttendance.run(
      callRequest("foreman-a", {
        organizationId: ORG_A,
        meetingId: "meeting-1",
        workerId: "worker-a",
        status: "absent",
      })
    );

    expect(result.status).toBe("absent");
  });

  test("succeeds marking present once the worker has completed the " +
    "required learning", async () => {
    await seedActivity(ORG_A, "activity-1", {siteId: "site-1"});
    await seedSafetyLearning(ORG_A, "l1");
    await seedSafetyRequirement(ORG_A, "r1", {
      requiredLearningIds: ["l1"],
      activityId: "activity-1",
    });
    await seedWorkerLearningRecord(ORG_A, "worker-a", "l1", "completed");
    await seedMeeting(ORG_A, "meeting-1", {activityIds: ["activity-1"]});
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

  test("another worker's own completion does not satisfy this worker's " +
    "requirement", async () => {
    await seedActivity(ORG_A, "activity-1", {siteId: "site-1"});
    await seedSafetyLearning(ORG_A, "l1");
    await seedSafetyRequirement(ORG_A, "r1", {
      requiredLearningIds: ["l1"],
      activityId: "activity-1",
    });
    await seedWorker("worker-b", "site-1");
    await seedWorkerLearningRecord(ORG_A, "worker-b", "l1", "completed");
    await seedMeeting(ORG_A, "meeting-1", {activityIds: ["activity-1"]});
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
    ).rejects.toThrow(/must complete the following safety learning/);
  });
});

describe("gatesAttendance semantics (worker Present gate, via " +
  "recordMeetingAttendance)", () => {
  test("a legacy requirement with no gatesAttendance field blocks " +
    "Present (missing/null defaults to true)", async () => {
    await seedActivity(ORG_A, "activity-1", {siteId: "site-1"});
    await seedSafetyLearning(ORG_A, "l1");
    // No gatesAttendance key at all.
    await seedSafetyRequirement(ORG_A, "r1", {
      requiredLearningIds: ["l1"],
      activityId: "activity-1",
    });
    await seedMeeting(ORG_A, "meeting-1", {activityIds: ["activity-1"]});
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
    ).rejects.toThrow(/must complete the following safety learning/);
  });

  test("gatesAttendance: false allows marking Present even with " +
    "incomplete learning", async () => {
    await seedActivity(ORG_A, "activity-1", {siteId: "site-1"});
    await seedSafetyLearning(ORG_A, "l1");
    await seedSafetyRequirement(ORG_A, "r1", {
      requiredLearningIds: ["l1"],
      activityId: "activity-1",
      gatesAttendance: false,
    });
    await seedMeeting(ORG_A, "meeting-1", {activityIds: ["activity-1"]});
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

  test("gatesAttendance: false still allows marking Absent (unaffected — " +
    "Absent was never gated by either kind of requirement)", async () => {
    await seedActivity(ORG_A, "activity-1", {siteId: "site-1"});
    await seedSafetyLearning(ORG_A, "l1");
    await seedSafetyRequirement(ORG_A, "r1", {
      requiredLearningIds: ["l1"],
      activityId: "activity-1",
      gatesAttendance: true,
    });
    await seedMeeting(ORG_A, "meeting-1", {activityIds: ["activity-1"]});
    await seedWorker("worker-a", "site-1");

    const result = await recordMeetingAttendance.run(
      callRequest("foreman-a", {
        organizationId: ORG_A,
        meetingId: "meeting-1",
        workerId: "worker-a",
        status: "absent",
      })
    );

    expect(result.status).toBe("absent");
  });

  test("when every applicable requirement is non-gating, incomplete " +
    "learning never blocks Present", async () => {
    await seedActivity(ORG_A, "activity-1", {siteId: "site-1"});
    await seedSafetyLearning(ORG_A, "l1");
    await seedSafetyLearning(ORG_A, "l2");
    await seedSafetyRequirement(ORG_A, "r1", {
      requiredLearningIds: ["l1"],
      activityId: "activity-1",
      gatesAttendance: false,
    });
    await seedSafetyRequirement(ORG_A, "r2", {
      requiredLearningIds: ["l2"],
      activityId: "activity-1",
      gatesAttendance: false,
    });
    await seedMeeting(ORG_A, "meeting-1", {activityIds: ["activity-1"]});
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

  test("a mix of gating and non-gating requirements: only the gating " +
    "one's incomplete learning blocks Present", async () => {
    await seedActivity(ORG_A, "activity-1", {siteId: "site-1"});
    await seedSafetyLearning(ORG_A, "gating-learning");
    await seedSafetyLearning(ORG_A, "non-gating-learning");
    await seedSafetyRequirement(ORG_A, "r-gating", {
      requiredLearningIds: ["gating-learning"],
      activityId: "activity-1",
      gatesAttendance: true,
    });
    await seedSafetyRequirement(ORG_A, "r-non-gating", {
      requiredLearningIds: ["non-gating-learning"],
      activityId: "activity-1",
      gatesAttendance: false,
    });
    await seedWorkerLearningRecord(
      ORG_A, "worker-a", "non-gating-learning", "completed"
    );
    await seedMeeting(ORG_A, "meeting-1", {activityIds: ["activity-1"]});
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
    ).rejects.toThrow(/must complete the following safety learning/);
  });

  test("LEARNING-ID OVERLAP: a learning id required by both a gating and " +
    "a non-gating requirement still blocks Present while incomplete",
  async () => {
    await seedActivity(ORG_A, "activity-1", {siteId: "site-1"});
    await seedSafetyLearning(ORG_A, "L1");
    await seedSafetyLearning(ORG_A, "L2");
    await seedSafetyLearning(ORG_A, "L3");
    await seedSafetyRequirement(ORG_A, "requirement-a", {
      requiredLearningIds: ["L1", "L2"],
      activityId: "activity-1",
      gatesAttendance: true,
    });
    await seedSafetyRequirement(ORG_A, "requirement-b", {
      requiredLearningIds: ["L2", "L3"],
      activityId: "activity-1",
      gatesAttendance: false,
    });
    await seedWorkerLearningRecord(ORG_A, "worker-a", "L1", "completed");
    await seedWorkerLearningRecord(ORG_A, "worker-a", "L3", "completed");
    await seedMeeting(ORG_A, "meeting-1", {activityIds: ["activity-1"]});
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
    ).rejects.toThrow(/must complete the following safety learning/);
  });

  test("LEARNING-ID OVERLAP (reverse): a learning id required by a " +
    "non-gating requirement FIRST and a gating requirement SECOND still " +
    "blocks Present while incomplete", async () => {
    await seedActivity(ORG_A, "activity-1", {siteId: "site-1"});
    await seedSafetyLearning(ORG_A, "L1");
    await seedSafetyRequirement(ORG_A, "requirement-a", {
      requiredLearningIds: ["L1"],
      activityId: "activity-1",
      gatesAttendance: false,
    });
    await seedSafetyRequirement(ORG_A, "requirement-b", {
      requiredLearningIds: ["L1"],
      activityId: "activity-1",
      gatesAttendance: true,
    });
    await seedMeeting(ORG_A, "meeting-1", {activityIds: ["activity-1"]});
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
    ).rejects.toThrow(/must complete the following safety learning/);
  });

  test("COMPLETION RECHECK: Present is rejected while gating learning is " +
    "incomplete, then allowed once it's completed, for the same worker " +
    "and meeting", async () => {
    await seedActivity(ORG_A, "activity-1", {siteId: "site-1"});
    await seedSafetyLearning(ORG_A, "l1");
    await seedSafetyRequirement(ORG_A, "r1", {
      requiredLearningIds: ["l1"],
      activityId: "activity-1",
      gatesAttendance: true,
    });
    await seedMeeting(ORG_A, "meeting-1", {activityIds: ["activity-1"]});
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
    ).rejects.toThrow(/must complete the following safety learning/);

    await seedWorkerLearningRecord(ORG_A, "worker-a", "l1", "completed");

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

  test("MULTI-ACTIVITY WORKER: gating requirements from every one of the " +
    "meeting's activities contribute to the Present gate", async () => {
    await seedActivity(ORG_A, "activity-1", {siteId: "site-1"});
    await seedActivity(ORG_A, "activity-2", {siteId: "site-1"});
    await seedSafetyLearning(ORG_A, "l1");
    await seedSafetyLearning(ORG_A, "l2");
    await seedSafetyRequirement(ORG_A, "r1", {
      requiredLearningIds: ["l1"],
      activityId: "activity-1",
      gatesAttendance: true,
    });
    await seedSafetyRequirement(ORG_A, "r2", {
      requiredLearningIds: ["l2"],
      activityId: "activity-2",
      gatesAttendance: true,
    });
    // Meeting covers BOTH activities.
    await seedMeeting(ORG_A, "meeting-1", {
      activityIds: ["activity-1", "activity-2"],
    });
    await seedWorker("worker-a", "site-1");
    // Only l1 completed — l2 (from activity-2's requirement) still blocks.
    await seedWorkerLearningRecord(ORG_A, "worker-a", "l1", "completed");

    await expect(
      recordMeetingAttendance.run(
        callRequest("foreman-a", {
          organizationId: ORG_A,
          meetingId: "meeting-1",
          workerId: "worker-a",
          status: "present",
        })
      )
    ).rejects.toThrow(/must complete the following safety learning/);
  });

  test("PROJECT SCOPE: a project-scoped gating requirement blocks " +
    "Present, and gatesAttendance: false on it lifts the block",
  async () => {
    await seedSite(ORG_A, "site-1", {projectId: "project-1"});
    await seedActivity(ORG_A, "activity-1", {siteId: "site-1"});
    await seedSafetyLearning(ORG_A, "l1");
    await seedSafetyRequirement(ORG_A, "r1", {
      requiredLearningIds: ["l1"],
      projectId: "project-1",
      gatesAttendance: true,
    });
    await seedMeeting(ORG_A, "meeting-1", {
      activityIds: ["activity-1"],
      projectId: "project-1",
    });
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
    ).rejects.toThrow(/must complete the following safety learning/);

    await db
      .doc(`organizations/${ORG_A}/safety_requirements/r1`)
      .update({gatesAttendance: false});

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

  test("SITE SCOPE: a site-scoped non-gating requirement does not block " +
    "Present", async () => {
    await seedActivity(ORG_A, "activity-1", {siteId: "site-1"});
    await seedSafetyLearning(ORG_A, "l1");
    await seedSafetyRequirement(ORG_A, "r1", {
      requiredLearningIds: ["l1"],
      siteId: "site-1",
      gatesAttendance: false,
    });
    await seedMeeting(ORG_A, "meeting-1", {activityIds: ["activity-1"]});
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
});

describe("getMeetingAttendeeLearningStatus", () => {
  test("reports an assigned worker's outstanding required learning",
    async () => {
      await seedWorker("worker-a", "site-1");
      await seedActivity(ORG_A, "activity-1", {siteId: "site-1"});
      await seedAssignment(ORG_A, "activity-1", "worker-a", "site-1");
      await seedSafetyLearning(ORG_A, "l1", {title: "Working at Height"});
      await seedSafetyRequirement(ORG_A, "r1", {
        requiredLearningIds: ["l1"],
      });
      await seedMeeting(ORG_A, "meeting-1", {activityIds: ["activity-1"]});

      const result = await getMeetingAttendeeLearningStatus.run(
        callRequest("foreman-a", {
          organizationId: ORG_A,
          meetingId: "meeting-1",
        })
      );

      expect(result.workers).toEqual([
        {workerId: "worker-a", outstanding: ["Working at Height"]},
      ]);
    });

  test("reports an empty outstanding list once the worker completes it",
    async () => {
      await seedActivity(ORG_A, "activity-1", {siteId: "site-1"});
      await seedAssignment(ORG_A, "activity-1", "worker-a", "site-1");
      await seedSafetyLearning(ORG_A, "l1");
      await seedSafetyRequirement(ORG_A, "r1", {
        requiredLearningIds: ["l1"],
      });
      await seedWorkerLearningRecord(ORG_A, "worker-a", "l1", "completed");
      await seedMeeting(ORG_A, "meeting-1", {activityIds: ["activity-1"]});

      const result = await getMeetingAttendeeLearningStatus.run(
        callRequest("foreman-a", {
          organizationId: ORG_A,
          meetingId: "meeting-1",
        })
      );

      expect(result.workers).toEqual([
        {workerId: "worker-a", outstanding: []},
      ]);
    });

  test("lists the crew with nothing outstanding when nothing is needed " +
    "today", async () => {
    await seedWorker("worker-a", "site-1");
    await seedActivity(ORG_A, "activity-1", {siteId: "site-1"});
    await seedAssignment(ORG_A, "activity-1", "worker-a", "site-1");
    await seedMeeting(ORG_A, "meeting-1", {activityIds: ["activity-1"]});

    const result = await getMeetingAttendeeLearningStatus.run(
      callRequest("foreman-a", {
        organizationId: ORG_A,
        meetingId: "meeting-1",
      })
    );

    expect(result.workers).toEqual([
      {workerId: "worker-a", outstanding: []},
    ]);
  });

  test("never includes a worker assigned to a DIFFERENT activity, not on " +
    "this meeting", async () => {
    await seedActivity(ORG_A, "activity-1", {siteId: "site-1"});
    await seedActivity(ORG_A, "activity-2", {siteId: "site-1"});
    await seedAssignment(ORG_A, "activity-1", "worker-a", "site-1");
    await seedAssignment(ORG_A, "activity-2", "worker-b", "site-1");
    await seedSafetyLearning(ORG_A, "l1");
    await seedSafetyRequirement(ORG_A, "r1", {requiredLearningIds: ["l1"]});
    // The meeting only covers activity-1 — worker-b (activity-2) must not
    // appear, even though they share the site.
    await seedMeeting(ORG_A, "meeting-1", {activityIds: ["activity-1"]});

    const result = await getMeetingAttendeeLearningStatus.run(
      callRequest("foreman-a", {
        organizationId: ORG_A,
        meetingId: "meeting-1",
      })
    );

    expect(result.workers.map((w) => w.workerId)).toEqual(["worker-a"]);
  });

  test("excludes the foreman themself from the worker list even if " +
    "self-assigned", async () => {
    await seedActivity(ORG_A, "activity-1", {siteId: "site-1"});
    await seedAssignment(ORG_A, "activity-1", "foreman-a", "site-1");
    await seedSafetyLearning(ORG_A, "l1");
    await seedSafetyRequirement(ORG_A, "r1", {requiredLearningIds: ["l1"]});
    await seedMeeting(ORG_A, "meeting-1", {activityIds: ["activity-1"]});

    const result = await getMeetingAttendeeLearningStatus.run(
      callRequest("foreman-a", {
        organizationId: ORG_A,
        meetingId: "meeting-1",
      })
    );

    expect(result.workers).toEqual([]);
  });

  test("a foreman cannot query a meeting they do not own", async () => {
    await seedForeman("foreman-b");
    await seedMeeting(ORG_A, "meeting-1");

    await expect(
      getMeetingAttendeeLearningStatus.run(
        callRequest("foreman-b", {
          organizationId: ORG_A,
          meetingId: "meeting-1",
        })
      )
    ).rejects.toThrow(/permission/);
  });

  test("a meeting id that only exists in another organization is refused",
    async () => {
      await seedSite(ORG_B, "site-b");
      await seedMeeting(ORG_B, "meeting-1", {siteId: "site-b"});

      await expect(
        getMeetingAttendeeLearningStatus.run(
          callRequest("foreman-a", {
            organizationId: ORG_A,
            meetingId: "meeting-1",
          })
        )
      ).rejects.toThrow();
    });

  test("an unauthenticated caller is refused", async () => {
    await seedMeeting(ORG_A, "meeting-1");

    await expect(
      getMeetingAttendeeLearningStatus.run(
        callRequest(undefined, {
          organizationId: ORG_A,
          meetingId: "meeting-1",
        })
      )
    ).rejects.toThrow();
  });
});

describe("requiredBeforeWork never changes attendance enforcement", () => {
  test("pre-work-only (non-gating) learning does NOT block Present",
    async () => {
      await seedWorker("worker-a");
      await seedActivity(ORG_A, "activity-1");
      await seedSafetyLearning(ORG_A, "l1");
      await seedSafetyRequirement(ORG_A, "r1", {
        requiredLearningIds: ["l1"],
        requiredBeforeWork: true,
        gatesAttendance: false,
      });
      await seedMeeting(ORG_A, "meeting-1", {activityIds: ["activity-1"]});

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

  test("learning that is both pre-work and gating still blocks Present",
    async () => {
      await seedWorker("worker-a");
      await seedActivity(ORG_A, "activity-1");
      await seedSafetyLearning(ORG_A, "l1", {title: "Fall Protection"});
      await seedSafetyRequirement(ORG_A, "r1", {
        requiredLearningIds: ["l1"],
        requiredBeforeWork: true,
        gatesAttendance: true,
      });
      await seedMeeting(ORG_A, "meeting-1", {activityIds: ["activity-1"]});

      await expect(
        recordMeetingAttendance.run(
          callRequest("foreman-a", {
            organizationId: ORG_A,
            meetingId: "meeting-1",
            workerId: "worker-a",
            status: "present",
          })
        )
      ).rejects.toThrow(/Fall Protection/);
    });
});

describe("per-lesson learningSettings in meeting enforcement", () => {
  const GATE = {gatesAttendance: true, requiredBeforeWork: false};
  const PRE = {gatesAttendance: false, requiredBeforeWork: true};
  const OFF = {gatesAttendance: false, requiredBeforeWork: false};

  async function seedMixedRequirement() {
    await seedActivity(ORG_A, "activity-1");
    await seedSafetyLearning(ORG_A, "l1", {title: "Harness Inspection"});
    await seedSafetyLearning(ORG_A, "l2", {title: "Ladder Safety"});
    await seedSafetyLearning(ORG_A, "l3", {title: "Rescue Procedures"});
    await seedSafetyRequirement(ORG_A, "height", {
      requiredLearningIds: ["l1", "l2", "l3"],
      // Would gate everything if used; the per-lesson settings must win.
      gatesAttendance: true,
      learningSettings: {l1: GATE, l2: PRE, l3: OFF},
    });
  }

  test("Present is refused only for the gating lesson", async () => {
    await seedWorker("worker-a");
    await seedMixedRequirement();
    await seedMeeting(ORG_A, "meeting-1", {activityIds: ["activity-1"]});

    await expect(
      recordMeetingAttendance.run(
        callRequest("foreman-a", {
          organizationId: ORG_A,
          meetingId: "meeting-1",
          workerId: "worker-a",
          status: "present",
        })
      )
    ).rejects.toThrow(/: Harness Inspection\. If you have briefed them/);

    await seedWorkerLearningRecord(ORG_A, "worker-a", "l1", "completed");
    const result = await recordMeetingAttendance.run(
      callRequest("foreman-a", {
        organizationId: ORG_A,
        meetingId: "meeting-1",
        workerId: "worker-a",
        status: "present",
      })
    );
    // l2 (pre-work only) and l3 (neither) are still incomplete.
    expect(result.status).toBe("present");
  });

  test("the Foreman's own start gate uses per-lesson settings too",
    async () => {
      await seedMixedRequirement();
      await seedMeetingPoint(ORG_A, "point-1");

      await expect(
        createDailySafetyMeeting.run(
          callRequest("foreman-a", {
            organizationId: ORG_A,
            projectId: "project-1",
            siteId: "site-1",
            activityIds: ["activity-1"],
            meetingPointIds: ["point-1"],
          })
        )
      ).rejects.toThrow(/: Harness Inspection$/);
    });

  test("crew readiness lists only the gating lesson as a blocker",
    async () => {
      await seedMixedRequirement();
      await seedWorker("worker-a", "site-1");
      await seedAssignment(ORG_A, "activity-1", "worker-a", "site-1");

      const pre = await getSiteCrewReadiness.run(
        callRequest("foreman-a", {organizationId: ORG_A, siteId: "site-1"})
      );
      expect(pre.workers).toEqual([
        {workerId: "worker-a", outstanding: ["Harness Inspection"]},
      ]);

      await seedMeeting(ORG_A, "meeting-1", {activityIds: ["activity-1"]});
      const during = await getMeetingAttendeeLearningStatus.run(
        callRequest("foreman-a", {
          organizationId: ORG_A,
          meetingId: "meeting-1",
        })
      );
      expect(during.workers).toEqual([
        {workerId: "worker-a", outstanding: ["Harness Inspection"]},
      ]);
    });
});

describe("getSiteCrewReadiness (pre-meeting)", () => {
  test("reports every rostered worker, with only attendance-gating " +
    "learning as outstanding", async () => {
    await seedActivity(ORG_A, "activity-1");
    await seedWorker("worker-a", "site-1");
    await seedWorker("worker-b", "site-1");
    await seedAssignment(ORG_A, "activity-1", "worker-a", "site-1");
    await seedAssignment(ORG_A, "activity-1", "worker-b", "site-1");
    await seedSafetyLearning(ORG_A, "gate", {title: "Site Induction"});
    await seedSafetyLearning(ORG_A, "pre", {title: "Ladder Safety"});
    await seedSafetyRequirement(ORG_A, "r-gate", {
      requiredLearningIds: ["gate"],
    });
    await seedSafetyRequirement(ORG_A, "r-pre", {
      requiredLearningIds: ["pre"],
      requiredBeforeWork: true,
      gatesAttendance: false,
    });
    await seedWorkerLearningRecord(ORG_A, "worker-b", "gate", "completed");

    const result = await getSiteCrewReadiness.run(
      callRequest("foreman-a", {organizationId: ORG_A, siteId: "site-1"})
    );

    expect(result.activities).toEqual([{id: "activity-1", name: "Roofing"}]);
    expect(result.workers).toEqual([
      {workerId: "worker-a", outstanding: ["Site Induction"]},
      {workerId: "worker-b", outstanding: []},
    ]);
  });

  test("returns every worker as ready when nothing gates attendance",
    async () => {
      await seedActivity(ORG_A, "activity-1");
      await seedAssignment(ORG_A, "activity-1", "worker-a", "site-1");

      const result = await getSiteCrewReadiness.run(
        callRequest("foreman-a", {organizationId: ORG_A, siteId: "site-1"})
      );

      expect(result.workers).toEqual([{workerId: "worker-a", outstanding: []}]);
    });

  test("ignores inactive activities and activities at other sites",
    async () => {
      await seedSite(ORG_A, "site-2");
      await seedActivity(ORG_A, "inactive", {status: "inactive"});
      await seedActivity(ORG_A, "elsewhere", {siteId: "site-2"});
      await seedAssignment(ORG_A, "inactive", "worker-a", "site-1");
      await seedAssignment(ORG_A, "elsewhere", "worker-b", "site-2");

      const result = await getSiteCrewReadiness.run(
        callRequest("foreman-a", {organizationId: ORG_A, siteId: "site-1"})
      );

      expect(result.activities).toEqual([]);
      expect(result.workers).toEqual([]);
    });

  test("excludes the foreman themself", async () => {
    await seedActivity(ORG_A, "activity-1");
    await seedAssignment(ORG_A, "activity-1", "foreman-a", "site-1");

    const result = await getSiteCrewReadiness.run(
      callRequest("foreman-a", {organizationId: ORG_A, siteId: "site-1"})
    );

    expect(result.workers).toEqual([]);
  });

  test("a foreman cannot query a site they are not assigned to",
    async () => {
      await seedSite(ORG_A, "site-2");

      await expect(
        getSiteCrewReadiness.run(
          callRequest("foreman-a", {organizationId: ORG_A, siteId: "site-2"})
        )
      ).rejects.toThrow(/permission/);
    });

  test("a worker cannot call it", async () => {
    await seedWorker("worker-a");

    await expect(
      getSiteCrewReadiness.run(
        callRequest("worker-a", {organizationId: ORG_A, siteId: "site-1"})
      )
    ).rejects.toThrow(/permission/);
  });

  test("a foreman of another organization is refused", async () => {
    await seedForeman("foreman-b", "site-1", {organizationId: ORG_B});

    await expect(
      getSiteCrewReadiness.run(
        callRequest("foreman-b", {organizationId: ORG_A, siteId: "site-1"})
      )
    ).rejects.toThrow(/permission/);
  });

  test("does not change getMeetingAttendeeLearningStatus's existing " +
    "empty-list result once a meeting exists", async () => {
    await seedWorker("worker-a", "site-1");
    await seedActivity(ORG_A, "activity-1");
    await seedAssignment(ORG_A, "activity-1", "worker-a", "site-1");
    await seedMeeting(ORG_A, "meeting-1", {activityIds: ["activity-1"]});

    const result = await getMeetingAttendeeLearningStatus.run(
      callRequest("foreman-a", {organizationId: ORG_A, meetingId: "meeting-1"})
    );

    // Every rostered worker is listed, ready or not.
    expect(result.workers).toEqual([
      {workerId: "worker-a", outstanding: []},
    ]);
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

  test("a concern CAN still be added once the meeting is completed — " +
    "deliberate exception, unlike update/remove", async () => {
    await seedMeeting(ORG_A, "meeting-1", {status: "completed"});

    const result = await addMeetingConcern.run(
      callRequest("foreman-a", {
        organizationId: ORG_A,
        meetingId: "meeting-1",
        description: "Remembered this the next day",
        category: "safety",
      })
    );

    expect(result.meetingId).toBe("meeting-1");
  });

  test("updateMeetingConcern still refuses once the meeting is completed",
    async () => {
      await seedMeeting(ORG_A, "meeting-1");
      const added = await addMeetingConcern.run(
        callRequest("foreman-a", {
          organizationId: ORG_A,
          meetingId: "meeting-1",
          description: "Original",
          category: "safety",
        })
      );
      await db.doc(`organizations/${ORG_A}/daily_safety_meetings/meeting-1`)
        .update({status: "completed"});

      await expect(
        updateMeetingConcern.run(
          callRequest("foreman-a", {
            organizationId: ORG_A,
            meetingId: "meeting-1",
            concernId: added.id,
            description: "Edited after completion",
          })
        )
      ).rejects.toThrow();
    });

  test("removeMeetingConcern still refuses once the meeting is completed",
    async () => {
      await seedMeeting(ORG_A, "meeting-1");
      const added = await addMeetingConcern.run(
        callRequest("foreman-a", {
          organizationId: ORG_A,
          meetingId: "meeting-1",
          description: "Original",
          category: "safety",
        })
      );
      await db.doc(`organizations/${ORG_A}/daily_safety_meetings/meeting-1`)
        .update({status: "completed"});

      await expect(
        removeMeetingConcern.run(
          callRequest("foreman-a", {
            organizationId: ORG_A,
            meetingId: "meeting-1",
            concernId: added.id,
          })
        )
      ).rejects.toThrow();
    });
});

describe("setMeetingPointNote", () => {
  test("the meeting's own foreman can set a note on a covered point",
    async () => {
      await seedMeetingPoint(ORG_A, "point-1");
      await seedMeeting(ORG_A, "meeting-1", {meetingPointIds: ["point-1"]});

      await setMeetingPointNote.run(
        callRequest("foreman-a", {
          organizationId: ORG_A,
          meetingId: "meeting-1",
          meetingPointId: "point-1",
          note: "Reminded workers to maintain three points of contact.",
        })
      );

      const note = await getPointNote(ORG_A, "meeting-1", "point-1");
      expect(note).not.toBeNull();
      expect(note.note).toBe(
        "Reminded workers to maintain three points of contact."
      );
      expect(note.recordedBy).toBe("foreman-a");
    });

  test("setting a note again overwrites the previous one (deterministic " +
    "id, one note per point)", async () => {
    await seedMeetingPoint(ORG_A, "point-1");
    await seedMeeting(ORG_A, "meeting-1", {meetingPointIds: ["point-1"]});

    await setMeetingPointNote.run(
      callRequest("foreman-a", {
        organizationId: ORG_A,
        meetingId: "meeting-1",
        meetingPointId: "point-1",
        note: "First note.",
      })
    );
    await setMeetingPointNote.run(
      callRequest("foreman-a", {
        organizationId: ORG_A,
        meetingId: "meeting-1",
        meetingPointId: "point-1",
        note: "Corrected note.",
      })
    );

    const note = await getPointNote(ORG_A, "meeting-1", "point-1");
    expect(note.note).toBe("Corrected note.");
  });

  test("a note is refused for a point NOT currently on the meeting",
    async () => {
      await seedMeetingPoint(ORG_A, "point-1");
      await seedMeeting(ORG_A, "meeting-1", {meetingPointIds: []});

      await expect(
        setMeetingPointNote.run(
          callRequest("foreman-a", {
            organizationId: ORG_A,
            meetingId: "meeting-1",
            meetingPointId: "point-1",
            note: "Should be refused.",
          })
        )
      ).rejects.toThrow();
    });

  test("a foreman from another organization cannot set a note on an " +
    "Org A meeting", async () => {
    await seedMeetingPoint(ORG_A, "point-1");
    await seedMeeting(ORG_A, "meeting-1", {meetingPointIds: ["point-1"]});
    await seedForeman("foreman-b", "site-1", {organizationId: ORG_B});

    await expect(
      setMeetingPointNote.run(
        callRequest("foreman-b", {
          organizationId: ORG_A,
          meetingId: "meeting-1",
          meetingPointId: "point-1",
          note: "Should be refused.",
        })
      )
    ).rejects.toThrow();
  });

  test("a note CAN still be set once the meeting is completed — " +
    "deliberate exception, matching addMeetingConcern/addMeetingEvidence",
  async () => {
    await seedMeetingPoint(ORG_A, "point-1");
    await seedMeeting(ORG_A, "meeting-1", {
      meetingPointIds: ["point-1"],
      status: "completed",
    });

    await setMeetingPointNote.run(
      callRequest("foreman-a", {
        organizationId: ORG_A,
        meetingId: "meeting-1",
        meetingPointId: "point-1",
        note: "Remembered this detail afterward.",
      })
    );

    const note = await getPointNote(ORG_A, "meeting-1", "point-1");
    expect(note.note).toBe("Remembered this detail afterward.");
  });
});

describe("removeMeetingPointNote", () => {
  test("the meeting's own foreman can remove a previously set note",
    async () => {
      await seedMeetingPoint(ORG_A, "point-1");
      await seedMeeting(ORG_A, "meeting-1", {meetingPointIds: ["point-1"]});
      await setMeetingPointNote.run(
        callRequest("foreman-a", {
          organizationId: ORG_A,
          meetingId: "meeting-1",
          meetingPointId: "point-1",
          note: "Will be removed.",
        })
      );

      await removeMeetingPointNote.run(
        callRequest("foreman-a", {
          organizationId: ORG_A,
          meetingId: "meeting-1",
          meetingPointId: "point-1",
        })
      );

      const note = await getPointNote(ORG_A, "meeting-1", "point-1");
      expect(note).toBeNull();
    });

  test("removing a note succeeds even if the point is no longer on " +
    "meetingPointIds — this is how the client cleans up a note when the " +
    "point itself is removed from the meeting", async () => {
    await seedMeetingPoint(ORG_A, "point-1");
    await seedMeeting(ORG_A, "meeting-1", {meetingPointIds: ["point-1"]});
    await setMeetingPointNote.run(
      callRequest("foreman-a", {
        organizationId: ORG_A,
        meetingId: "meeting-1",
        meetingPointId: "point-1",
        note: "Will be removed.",
      })
    );

    // Simulates updateDailySafetyMeeting removing the point from the
    // meeting's own meetingPointIds, as the client does before/alongside
    // calling removeMeetingPointNote.
    await db.doc(`organizations/${ORG_A}/daily_safety_meetings/meeting-1`)
      .update({meetingPointIds: []});

    await removeMeetingPointNote.run(
      callRequest("foreman-a", {
        organizationId: ORG_A,
        meetingId: "meeting-1",
        meetingPointId: "point-1",
      })
    );

    const note = await getPointNote(ORG_A, "meeting-1", "point-1");
    expect(note).toBeNull();
  });

  test("a foreman from another organization cannot remove a note from " +
    "an Org A meeting", async () => {
    await seedMeetingPoint(ORG_A, "point-1");
    await seedMeeting(ORG_A, "meeting-1", {meetingPointIds: ["point-1"]});
    await setMeetingPointNote.run(
      callRequest("foreman-a", {
        organizationId: ORG_A,
        meetingId: "meeting-1",
        meetingPointId: "point-1",
        note: "Should survive.",
      })
    );
    await seedForeman("foreman-b", "site-1", {organizationId: ORG_B});

    await expect(
      removeMeetingPointNote.run(
        callRequest("foreman-b", {
          organizationId: ORG_A,
          meetingId: "meeting-1",
          meetingPointId: "point-1",
        })
      )
    ).rejects.toThrow();

    const note = await getPointNote(ORG_A, "meeting-1", "point-1");
    expect(note).not.toBeNull();
  });

  test("removal is refused once the meeting is completed", async () => {
    await seedMeetingPoint(ORG_A, "point-1");
    await seedMeeting(ORG_A, "meeting-1", {meetingPointIds: ["point-1"]});
    await setMeetingPointNote.run(
      callRequest("foreman-a", {
        organizationId: ORG_A,
        meetingId: "meeting-1",
        meetingPointId: "point-1",
        note: "Frozen once completed.",
      })
    );
    await db.doc(`organizations/${ORG_A}/daily_safety_meetings/meeting-1`)
      .update({status: "completed"});

    await expect(
      removeMeetingPointNote.run(
        callRequest("foreman-a", {
          organizationId: ORG_A,
          meetingId: "meeting-1",
          meetingPointId: "point-1",
        })
      )
    ).rejects.toThrow();
  });
});

function evidencePath(orgId, meetingId, evidenceId) {
  return `organizations/${orgId}/daily_safety_meetings/${meetingId}` +
    `/evidence/${evidenceId}`;
}

describe("addMeetingEvidence", () => {
  test("the meeting's own foreman can add evidence to an in-progress " +
    "meeting", async () => {
    await seedMeeting(ORG_A, "meeting-1");

    await addMeetingEvidence.run(
      callRequest("foreman-a", {
        organizationId: ORG_A,
        meetingId: "meeting-1",
        evidenceId: "evidence-1",
        storagePath: evidencePath(ORG_A, "meeting-1", "evidence-1"),
        downloadUrl: "https://example.com/evidence-1.jpg",
        fileType: "image/jpeg",
        evidenceType: "handwrittenNotes",
        description: "Page 14 of the site safety book",
      })
    );

    const evidence = await getEvidence(ORG_A, "meeting-1", "evidence-1");
    expect(evidence).not.toBeNull();
    expect(evidence.evidenceType).toBe("handwrittenNotes");
    expect(evidence.description).toBe("Page 14 of the site safety book");
    expect(evidence.uploadedBy).toBe("foreman-a");
  });

  test("evidence is accepted even on a COMPLETED meeting — deliberate " +
    "exception, unlike every other write on this meeting", async () => {
    await seedMeeting(ORG_A, "meeting-1", {status: "completed"});

    await addMeetingEvidence.run(
      callRequest("foreman-a", {
        organizationId: ORG_A,
        meetingId: "meeting-1",
        evidenceId: "evidence-1",
        storagePath: evidencePath(ORG_A, "meeting-1", "evidence-1"),
        downloadUrl: "https://example.com/evidence-1.jpg",
        fileType: "image/jpeg",
        evidenceType: "signInSheet",
      })
    );

    const evidence = await getEvidence(ORG_A, "meeting-1", "evidence-1");
    expect(evidence).not.toBeNull();
  });

  test("an invalid evidenceType is refused", async () => {
    await seedMeeting(ORG_A, "meeting-1");

    await expect(
      addMeetingEvidence.run(
        callRequest("foreman-a", {
          organizationId: ORG_A,
          meetingId: "meeting-1",
          evidenceId: "evidence-1",
          storagePath: evidencePath(ORG_A, "meeting-1", "evidence-1"),
          downloadUrl: "https://example.com/evidence-1.jpg",
          fileType: "image/jpeg",
          evidenceType: "not-a-real-type",
        })
      )
    ).rejects.toThrow();
  });

  test("a storagePath outside this meeting's own path is refused",
    async () => {
      await seedMeeting(ORG_A, "meeting-1");

      await expect(
        addMeetingEvidence.run(
          callRequest("foreman-a", {
            organizationId: ORG_A,
            meetingId: "meeting-1",
            evidenceId: "evidence-1",
            storagePath: evidencePath(ORG_A, "meeting-2", "evidence-1"),
            downloadUrl: "https://example.com/evidence-1.jpg",
            fileType: "image/jpeg",
            evidenceType: "document",
          })
        )
      ).rejects.toThrow();
    });

  test("reusing an evidenceId that already has metadata is refused",
    async () => {
      await seedMeeting(ORG_A, "meeting-1");
      await addMeetingEvidence.run(
        callRequest("foreman-a", {
          organizationId: ORG_A,
          meetingId: "meeting-1",
          evidenceId: "evidence-1",
          storagePath: evidencePath(ORG_A, "meeting-1", "evidence-1"),
          downloadUrl: "https://example.com/evidence-1.jpg",
          fileType: "image/jpeg",
          evidenceType: "document",
        })
      );

      await expect(
        addMeetingEvidence.run(
          callRequest("foreman-a", {
            organizationId: ORG_A,
            meetingId: "meeting-1",
            evidenceId: "evidence-1",
            storagePath: evidencePath(ORG_A, "meeting-1", "evidence-1"),
            downloadUrl: "https://example.com/other.jpg",
            fileType: "image/jpeg",
            evidenceType: "other",
          })
        )
      ).rejects.toThrow();
    });

  test("a foreman from another organization cannot add evidence to an " +
    "Org A meeting", async () => {
    await seedMeeting(ORG_A, "meeting-1");
    await seedForeman("foreman-b", "site-1", {organizationId: ORG_B});

    await expect(
      addMeetingEvidence.run(
        callRequest("foreman-b", {
          organizationId: ORG_A,
          meetingId: "meeting-1",
          evidenceId: "evidence-1",
          storagePath: evidencePath(ORG_A, "meeting-1", "evidence-1"),
          downloadUrl: "https://example.com/evidence-1.jpg",
          fileType: "image/jpeg",
          evidenceType: "document",
        })
      )
    ).rejects.toThrow();
  });
});

describe("removeMeetingEvidence", () => {
  test("the meeting's own foreman can remove evidence from an " +
    "in-progress meeting", async () => {
    await seedMeeting(ORG_A, "meeting-1");
    await addMeetingEvidence.run(
      callRequest("foreman-a", {
        organizationId: ORG_A,
        meetingId: "meeting-1",
        evidenceId: "evidence-1",
        storagePath: evidencePath(ORG_A, "meeting-1", "evidence-1"),
        downloadUrl: "https://example.com/evidence-1.jpg",
        fileType: "image/jpeg",
        evidenceType: "document",
      })
    );

    await removeMeetingEvidence.run(
      callRequest("foreman-a", {
        organizationId: ORG_A,
        meetingId: "meeting-1",
        evidenceId: "evidence-1",
      })
    );

    const evidence = await getEvidence(ORG_A, "meeting-1", "evidence-1");
    expect(evidence).toBeNull();
  });

  test("removal is refused once the meeting is completed — evidence may " +
    "be added afterward but never removed", async () => {
    await seedMeeting(ORG_A, "meeting-1");
    await addMeetingEvidence.run(
      callRequest("foreman-a", {
        organizationId: ORG_A,
        meetingId: "meeting-1",
        evidenceId: "evidence-1",
        storagePath: evidencePath(ORG_A, "meeting-1", "evidence-1"),
        downloadUrl: "https://example.com/evidence-1.jpg",
        fileType: "image/jpeg",
        evidenceType: "document",
      })
    );
    await db.doc(`organizations/${ORG_A}/daily_safety_meetings/meeting-1`)
      .update({status: "completed"});

    await expect(
      removeMeetingEvidence.run(
        callRequest("foreman-a", {
          organizationId: ORG_A,
          meetingId: "meeting-1",
          evidenceId: "evidence-1",
        })
      )
    ).rejects.toThrow();

    const evidence = await getEvidence(ORG_A, "meeting-1", "evidence-1");
    expect(evidence).not.toBeNull();
  });

  test("removing an evidence id that does not exist is refused",
    async () => {
      await seedMeeting(ORG_A, "meeting-1");

      await expect(
        removeMeetingEvidence.run(
          callRequest("foreman-a", {
            organizationId: ORG_A,
            meetingId: "meeting-1",
            evidenceId: "nonexistent",
          })
        )
      ).rejects.toThrow();
    });

  test("a foreman from another organization cannot remove evidence from " +
    "an Org A meeting", async () => {
    await seedMeeting(ORG_A, "meeting-1");
    await addMeetingEvidence.run(
      callRequest("foreman-a", {
        organizationId: ORG_A,
        meetingId: "meeting-1",
        evidenceId: "evidence-1",
        storagePath: evidencePath(ORG_A, "meeting-1", "evidence-1"),
        downloadUrl: "https://example.com/evidence-1.jpg",
        fileType: "image/jpeg",
        evidenceType: "document",
      })
    );
    await seedForeman("foreman-b", "site-1", {organizationId: ORG_B});

    await expect(
      removeMeetingEvidence.run(
        callRequest("foreman-b", {
          organizationId: ORG_A,
          meetingId: "meeting-1",
          evidenceId: "evidence-1",
        })
      )
    ).rejects.toThrow();

    const evidence = await getEvidence(ORG_A, "meeting-1", "evidence-1");
    expect(evidence).not.toBeNull();
  });
});

describe("completeDailySafetyMeeting (safety learning gate)", () => {
  async function readyMeeting(orgId, id, activityIds = ["activity-default"]) {
    await seedMeetingPoint(orgId, "point-1");
    await seedMeeting(orgId, id, {
      activityIds,
      meetingPointIds: ["point-1"],
    });
  }

  test("completes normally when nothing is required of the foreman",
    async () => {
      await readyMeeting(ORG_A, "meeting-1");

      const result = await completeDailySafetyMeeting.run(
        callRequest("foreman-a", {organizationId: ORG_A, id: "meeting-1"})
      );

      expect(result.status).toBe("completed");
    });

  test("is refused when an organization-wide required item is not " +
    "completed by the foreman", async () => {
    await seedSafetyLearning(ORG_A, "l1");
    await seedSafetyRequirement(ORG_A, "r1", {requiredLearningIds: ["l1"]});
    await readyMeeting(ORG_A, "meeting-1");

    await expect(
      completeDailySafetyMeeting.run(
        callRequest("foreman-a", {organizationId: ORG_A, id: "meeting-1"})
      )
    ).rejects.toThrow(/must complete the following safety learning/);

    const meeting = await getMeeting(ORG_A, "meeting-1");
    expect(meeting.status).toBe("inProgress");
  });

  test("completes once the foreman has completed the organization-wide " +
    "required item", async () => {
    await seedSafetyLearning(ORG_A, "l1");
    await seedSafetyRequirement(ORG_A, "r1", {requiredLearningIds: ["l1"]});
    await seedWorkerLearningRecord(ORG_A, "foreman-a", "l1", "completed");
    await readyMeeting(ORG_A, "meeting-1");

    const result = await completeDailySafetyMeeting.run(
      callRequest("foreman-a", {organizationId: ORG_A, id: "meeting-1"})
    );

    expect(result.status).toBe("completed");
  });

  test("is refused when a site-scoped requirement for the meeting's own " +
    "site is not completed", async () => {
    await seedSafetyLearning(ORG_A, "l1");
    await seedSafetyRequirement(ORG_A, "r1", {
      requiredLearningIds: ["l1"],
      siteId: "site-1",
    });
    await readyMeeting(ORG_A, "meeting-1");

    await expect(
      completeDailySafetyMeeting.run(
        callRequest("foreman-a", {organizationId: ORG_A, id: "meeting-1"})
      )
    ).rejects.toThrow(/must complete the following safety learning/);
  });

  test("a site-scoped requirement for a DIFFERENT site does not block " +
    "this meeting", async () => {
    await seedSafetyLearning(ORG_A, "l1");
    await seedSafetyRequirement(ORG_A, "r1", {
      requiredLearningIds: ["l1"],
      siteId: "site-2",
    });
    await readyMeeting(ORG_A, "meeting-1");

    const result = await completeDailySafetyMeeting.run(
      callRequest("foreman-a", {organizationId: ORG_A, id: "meeting-1"})
    );

    expect(result.status).toBe("completed");
  });

  test("is refused when an activity-scoped requirement for one of the " +
    "meeting's own activities is not completed", async () => {
    await seedActivity(ORG_A, "activity-1");
    await seedSafetyLearning(ORG_A, "l1");
    await seedSafetyRequirement(ORG_A, "r1", {
      requiredLearningIds: ["l1"],
      activityId: "activity-1",
    });
    await readyMeeting(ORG_A, "meeting-1", ["activity-1"]);

    await expect(
      completeDailySafetyMeeting.run(
        callRequest("foreman-a", {organizationId: ORG_A, id: "meeting-1"})
      )
    ).rejects.toThrow(/must complete the following safety learning/);
  });

  test("an activity-scoped requirement for an activity NOT on this " +
    "meeting does not block it", async () => {
    await seedActivity(ORG_A, "activity-1");
    await seedActivity(ORG_A, "activity-2");
    await seedSafetyLearning(ORG_A, "l1");
    await seedSafetyRequirement(ORG_A, "r1", {
      requiredLearningIds: ["l1"],
      activityId: "activity-2",
    });
    // The meeting only covers activity-1 — activity-2's requirement must
    // not leak into it.
    await readyMeeting(ORG_A, "meeting-1", ["activity-1"]);

    const result = await completeDailySafetyMeeting.run(
      callRequest("foreman-a", {organizationId: ORG_A, id: "meeting-1"})
    );

    expect(result.status).toBe("completed");
  });

  test("an inProgress (not completed) worker_learning_record still blocks " +
    "completion", async () => {
    await seedSafetyLearning(ORG_A, "l1");
    await seedSafetyRequirement(ORG_A, "r1", {requiredLearningIds: ["l1"]});
    await seedWorkerLearningRecord(ORG_A, "foreman-a", "l1", "inProgress");
    await readyMeeting(ORG_A, "meeting-1");

    await expect(
      completeDailySafetyMeeting.run(
        callRequest("foreman-a", {organizationId: ORG_A, id: "meeting-1"})
      )
    ).rejects.toThrow(/must complete the following safety learning/);
  });

  test("another foreman's own completion does not satisfy this foreman's " +
    "requirement", async () => {
    await seedForeman("foreman-b");
    await seedSafetyLearning(ORG_A, "l1");
    await seedSafetyRequirement(ORG_A, "r1", {requiredLearningIds: ["l1"]});
    await seedWorkerLearningRecord(ORG_A, "foreman-b", "l1", "completed");
    await readyMeeting(ORG_A, "meeting-1");

    await expect(
      completeDailySafetyMeeting.run(
        callRequest("foreman-a", {organizationId: ORG_A, id: "meeting-1"})
      )
    ).rejects.toThrow(/must complete the following safety learning/);
  });
});
