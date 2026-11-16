/**
 * Business-logic tests for `worker_learning_callable.ts` —
 * `getMyRequiredLearning`/`startLearning`/`completeLearning`, focused on
 * Phase 1's site/activity-scoped required-learning resolution
 * (`resolveRequiredLearning`/`workerWorkContext`).
 *
 * Mirrors `activity_assignment_callable.test.js`'s shape: invokes each
 * callable's own exported handler via `.run(request)` against a running
 * Firestore emulator.
 *
 * Requires the Firestore emulator — see `npm run test:callables`.
 */

const {initializeApp, getApps, deleteApp} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");

const PROJECT_ID = "jva-safety-rules-test";
const ORG_A = "org-alpha";

let app;
let db;
let getMyRequiredLearning;
let startLearning;
let completeLearning;
let getKnowledgeCheckQuestions;
let practiceKnowledgeCheck;
let getCrewLearningRecords;
let getMyTodaysSafetyReadiness;
let resolveRequiredLearningForScope;
let resolveAttendanceGatingLearningIds;
let resolvePreWorkLearningIds;

beforeAll(() => {
  process.env.GCLOUD_PROJECT = PROJECT_ID;
  if (!process.env.FIRESTORE_EMULATOR_HOST) {
    process.env.FIRESTORE_EMULATOR_HOST = "127.0.0.1:8080";
  }

  app = getApps()[0] ?? initializeApp({projectId: PROJECT_ID});
  db = getFirestore(app);

  ({
    getMyRequiredLearning,
    startLearning,
    completeLearning,
    getKnowledgeCheckQuestions,
    practiceKnowledgeCheck,
    getCrewLearningRecords,
    getMyTodaysSafetyReadiness,
    resolveRequiredLearningForScope,
    resolveAttendanceGatingLearningIds,
    resolvePreWorkLearningIds,
  } = require("../lib/worker_learning_callable"));
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

async function seedProfile(uid, overrides = {}) {
  await db.doc(`users/${uid}`).set(profile(uid, overrides));
}

async function seedMembership(uid, organizationId, role, siteIds = []) {
  await db.doc(`users/${uid}/memberships/${organizationId}`).set({
    organizationId,
    role,
    workerType: null,
    trade: null,
    siteIds,
    status: "active",
    approvedAt: new Date(),
    approvedBy: "approver-a",
    createdAt: new Date(),
    updatedAt: new Date(),
  });
}

async function seedLearning(organizationId, id, overrides = {}) {
  await db.doc(`organizations/${organizationId}/safety_learning/${id}`).set({
    organizationId,
    title: `Learning ${id}`,
    type: "document",
    contentReference: `ref-${id}`,
    status: "active",
    createdAt: new Date(),
    updatedAt: new Date(),
    ...overrides,
  });
}

async function seedRequirement(organizationId, id, overrides = {}) {
  await db
    .doc(`organizations/${organizationId}/safety_requirements/${id}`)
    .set({
      organizationId,
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

async function seedActivity(organizationId, id, siteId, overrides = {}) {
  await db.doc(`organizations/${organizationId}/activities/${id}`).set({
    organizationId,
    projectId: "project-1",
    siteId,
    name: `Activity ${id}`,
    code: `CODE-${id}`,
    status: "active",
    createdAt: new Date(),
    updatedAt: new Date(),
    ...overrides,
  });
}

async function seedAssignment(
  organizationId, activityId, uid, siteId, projectId
) {
  await db
    .doc(`organizations/${organizationId}/activities/${activityId}` +
      `/assignments/${uid}`)
    .set({
      uid,
      organizationId,
      siteId,
      activityId,
      ...(projectId ? {projectId} : {}),
      assignedAt: new Date(),
      assignedBy: "assigner-1",
    });
}

async function seedQuestion(organizationId, learningId, id, overrides = {}) {
  await db
    .doc(
      `organizations/${organizationId}/safety_learning/${learningId}` +
        `/knowledge_check_questions/${id}`
    )
    .set({
      prompt: `Question ${id}`,
      options: [
        {id: "a", text: "Option A"},
        {id: "b", text: "Option B"},
      ],
      correctOptionId: "a",
      order: 0,
      createdAt: new Date(),
      updatedAt: new Date(),
      ...overrides,
    });
}

function callRequest(uid, data) {
  return {
    auth: uid ? {uid, token: {}} : undefined,
    data,
    rawRequest: {},
  };
}

async function getRecord(organizationId, workerUid, learningId) {
  const path = `organizations/${organizationId}/worker_learning_records/` +
    `${workerUid}_${learningId}`;
  const snapshot = await db.doc(path).get();
  return snapshot.exists ? snapshot.data() : null;
}

beforeEach(async () => {
  await clearFirestore();
});

describe("getMyRequiredLearning resolution", () => {
  test("an organization-wide requirement still resolves for any active worker",
    async () => {
      await seedProfile("worker-1");
      await seedMembership("worker-1", ORG_A, "worker");
      await seedLearning(ORG_A, "l1");
      await seedRequirement(ORG_A, "r1", {requiredLearningIds: ["l1"]});

      const result = await getMyRequiredLearning.run(
        callRequest("worker-1", {organizationId: ORG_A})
      );

      expect(result.total).toBe(1);
      const record = await getRecord(ORG_A, "worker-1", "l1");
      expect(record).not.toBeNull();
      expect(record.status).toBe("assigned");
    });

  test("a requirement with gatesAttendance: false is STILL fully " +
    "required — this field only narrows the Daily Safety Meeting " +
    "attendance gate, not the worker's overall required-learning set",
  async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker");
    await seedLearning(ORG_A, "l1");
    await seedRequirement(ORG_A, "r1", {
      requiredLearningIds: ["l1"],
      gatesAttendance: false,
    });

    const result = await getMyRequiredLearning.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );

    expect(result.total).toBe(1);
    const record = await getRecord(ORG_A, "worker-1", "l1");
    expect(record).not.toBeNull();
    expect(record.status).toBe("assigned");
  });

  test("a site-scoped requirement resolves only for a worker assigned to " +
    "that site", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker", ["site-1"]);
    await seedProfile("worker-2");
    await seedMembership("worker-2", ORG_A, "worker", ["site-2"]);
    await seedLearning(ORG_A, "l1");
    await seedRequirement(ORG_A, "r1", {
      requiredLearningIds: ["l1"],
      siteId: "site-1",
    });
    await seedActivity(ORG_A, "activity-1", "site-1");
    await seedAssignment(ORG_A, "activity-1", "worker-1", "site-1");
    await seedActivity(ORG_A, "activity-2", "site-2");
    await seedAssignment(ORG_A, "activity-2", "worker-2", "site-2");

    const resultForAssignedWorker = await getMyRequiredLearning.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );
    const resultForUnrelatedSiteWorker = await getMyRequiredLearning.run(
      callRequest("worker-2", {organizationId: ORG_A})
    );

    expect(resultForAssignedWorker.total).toBe(1);
    expect(resultForUnrelatedSiteWorker.total).toBe(0);
    expect(await getRecord(ORG_A, "worker-1", "l1")).not.toBeNull();
    expect(await getRecord(ORG_A, "worker-2", "l1")).toBeNull();
  });

  test("an activity-scoped requirement resolves only for a worker assigned " +
    "to that activity", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker", ["site-1"]);
    await seedProfile("worker-2");
    await seedMembership("worker-2", ORG_A, "worker", ["site-1"]);
    await seedLearning(ORG_A, "l1");
    await seedRequirement(ORG_A, "r1", {
      requiredLearningIds: ["l1"],
      activityId: "activity-1",
    });
    await seedActivity(ORG_A, "activity-1", "site-1");
    await seedAssignment(ORG_A, "activity-1", "worker-1", "site-1");
    // worker-2 shares the SAME SITE but a DIFFERENT activity — an
    // activity-scoped requirement must not leak to it.
    await seedActivity(ORG_A, "activity-2", "site-1");
    await seedAssignment(ORG_A, "activity-2", "worker-2", "site-1");

    const resultForAssignedWorker = await getMyRequiredLearning.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );
    const resultForUnrelatedActivityWorker = await getMyRequiredLearning.run(
      callRequest("worker-2", {organizationId: ORG_A})
    );

    expect(resultForAssignedWorker.total).toBe(1);
    expect(resultForUnrelatedActivityWorker.total).toBe(0);
    expect(await getRecord(ORG_A, "worker-1", "l1")).not.toBeNull();
    expect(await getRecord(ORG_A, "worker-2", "l1")).toBeNull();
  });

  test("an unassigned worker sees no site/activity-scoped requirement",
    async () => {
      await seedProfile("worker-1");
      await seedMembership("worker-1", ORG_A, "worker");
      await seedLearning(ORG_A, "l1");
      await seedRequirement(ORG_A, "r1", {
        requiredLearningIds: ["l1"],
        siteId: "site-1",
      });

      const result = await getMyRequiredLearning.run(
        callRequest("worker-1", {organizationId: ORG_A})
      );

      expect(result.total).toBe(0);
    });

  test("a project-scoped requirement resolves only for a worker assigned " +
    "anywhere under that project", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker", ["site-1"]);
    await seedProfile("worker-2");
    await seedMembership("worker-2", ORG_A, "worker", ["site-2"]);
    await seedLearning(ORG_A, "l1");
    await seedRequirement(ORG_A, "r1", {
      requiredLearningIds: ["l1"],
      projectId: "project-1",
    });
    await seedActivity(ORG_A, "activity-1", "site-1", {
      projectId: "project-1",
    });
    await seedAssignment(
      ORG_A, "activity-1", "worker-1", "site-1", "project-1"
    );
    // worker-2 is assigned under a DIFFERENT project — must not see it.
    await seedActivity(ORG_A, "activity-2", "site-2", {
      projectId: "project-2",
    });
    await seedAssignment(
      ORG_A, "activity-2", "worker-2", "site-2", "project-2"
    );

    const resultForProjectWorker = await getMyRequiredLearning.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );
    const resultForOtherProjectWorker = await getMyRequiredLearning.run(
      callRequest("worker-2", {organizationId: ORG_A})
    );

    expect(resultForProjectWorker.total).toBe(1);
    expect(resultForOtherProjectWorker.total).toBe(0);
  });

  test("a legacy assignment with no denormalized projectId does not match " +
    "a project-scoped requirement", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker", ["site-1"]);
    await seedLearning(ORG_A, "l1");
    await seedRequirement(ORG_A, "r1", {
      requiredLearningIds: ["l1"],
      projectId: "project-1",
    });
    await seedActivity(ORG_A, "activity-1", "site-1", {
      projectId: "project-1",
    });
    // No projectId passed — mirrors an assignment written before this
    // field existed.
    await seedAssignment(ORG_A, "activity-1", "worker-1", "site-1");

    const result = await getMyRequiredLearning.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );

    expect(result.total).toBe(0);
  });

  test("a worker assigned to two activities sees the union of both " +
    "activities' requirements, without duplicates", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker", ["site-1"]);
    await seedLearning(ORG_A, "ppe");
    await seedLearning(ORG_A, "height");
    await seedLearning(ORG_A, "electrical");
    await seedRequirement(ORG_A, "r-ppe-a", {
      requiredLearningIds: ["ppe"],
      activityId: "activity-a",
    });
    await seedRequirement(ORG_A, "r-height-a", {
      requiredLearningIds: ["height"],
      activityId: "activity-a",
    });
    await seedRequirement(ORG_A, "r-ppe-b", {
      requiredLearningIds: ["ppe"],
      activityId: "activity-b",
    });
    await seedRequirement(ORG_A, "r-electrical-b", {
      requiredLearningIds: ["electrical"],
      activityId: "activity-b",
    });
    await seedActivity(ORG_A, "activity-a", "site-1");
    await seedActivity(ORG_A, "activity-b", "site-1");
    await seedAssignment(ORG_A, "activity-a", "worker-1", "site-1");
    await seedAssignment(ORG_A, "activity-b", "worker-1", "site-1");

    const result = await getMyRequiredLearning.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );

    // ppe is required by both activities but must count once.
    expect(result.total).toBe(3);
  });
});

describe("startLearning / completeLearning — self-only", () => {
  test("a worker cannot manipulate another worker's learning record by " +
    "passing their own uid but acting on data materialized for someone else",
  async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker");
    await seedProfile("worker-2");
    await seedMembership("worker-2", ORG_A, "worker");
    await seedLearning(ORG_A, "l1");
    await seedRequirement(ORG_A, "r1", {requiredLearningIds: ["l1"]});

    await getMyRequiredLearning.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );
    await getMyRequiredLearning.run(
      callRequest("worker-2", {organizationId: ORG_A})
    );

    // startLearning/completeLearning accept no workerUid argument at all —
    // the acting worker is always the caller's own auth uid. Calling as
    // worker-2 can only ever touch worker-2's own record.
    await startLearning.run(
      callRequest("worker-2", {organizationId: ORG_A, learningId: "l1"})
    );

    const worker1Record = await getRecord(ORG_A, "worker-1", "l1");
    const worker2Record = await getRecord(ORG_A, "worker-2", "l1");
    expect(worker1Record.status).toBe("assigned");
    expect(worker2Record.status).toBe("inProgress");
  });

  test("a worker cannot start/complete learning outside their resolved " +
    "required set", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker");
    await seedLearning(ORG_A, "l1");
    // Not referenced by any requirement — never required of anyone.

    await expect(
      startLearning.run(
        callRequest("worker-1", {organizationId: ORG_A, learningId: "l1"})
      )
    ).rejects.toThrow(/not currently required/);
  });

  test("an unauthenticated caller cannot start learning", async () => {
    await expect(
      startLearning.run(
        callRequest(null, {organizationId: ORG_A, learningId: "l1"})
      )
    ).rejects.toThrow(/permission/);
  });

  test("a worker can complete their own currently-required learning",
    async () => {
      await seedProfile("worker-1");
      await seedMembership("worker-1", ORG_A, "worker");
      await seedLearning(ORG_A, "l1");
      await seedRequirement(ORG_A, "r1", {requiredLearningIds: ["l1"]});
      await getMyRequiredLearning.run(
        callRequest("worker-1", {organizationId: ORG_A})
      );

      await completeLearning.run(
        callRequest("worker-1", {organizationId: ORG_A, learningId: "l1"})
      );

      const record = await getRecord(ORG_A, "worker-1", "l1");
      expect(record.status).toBe("completed");
    });
});

describe("completeLearning (video minimum-watch-time gate)", () => {
  async function recordPath(workerUid, learningId) {
    return `organizations/${ORG_A}/worker_learning_records/` +
      `${workerUid}_${learningId}`;
  }

  test("is refused before the minimum watch time has elapsed", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker");
    await seedLearning(ORG_A, "l1", {
      type: "video",
      minimumWatchSeconds: 120,
    });
    await seedRequirement(ORG_A, "r1", {requiredLearningIds: ["l1"]});
    await getMyRequiredLearning.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );
    await startLearning.run(
      callRequest("worker-1", {organizationId: ORG_A, learningId: "l1"})
    );
    // startLearning just wrote a real server timestamp a moment ago — far
    // less than the 120s minimum has elapsed.

    await expect(
      completeLearning.run(
        callRequest("worker-1", {organizationId: ORG_A, learningId: "l1"})
      )
    ).rejects.toThrow(/Keep this item open/);

    const record = await getRecord(ORG_A, "worker-1", "l1");
    expect(record.status).toBe("inProgress");
  });

  test("succeeds once the minimum watch time has genuinely elapsed",
    async () => {
      await seedProfile("worker-1");
      await seedMembership("worker-1", ORG_A, "worker");
      await seedLearning(ORG_A, "l1", {
        type: "video",
        minimumWatchSeconds: 30,
      });
      await seedRequirement(ORG_A, "r1", {requiredLearningIds: ["l1"]});
      await getMyRequiredLearning.run(
        callRequest("worker-1", {organizationId: ORG_A})
      );
      // Directly seeding startedAt 60s in the past simulates genuine
      // elapsed time without the test actually sleeping 30s — the
      // callable itself only ever reads this field, never trusts a
      // client-supplied duration/position.
      await db.doc(await recordPath("worker-1", "l1")).update({
        status: "inProgress",
        startedAt: new Date(Date.now() - 60000),
      });

      await completeLearning.run(
        callRequest("worker-1", {organizationId: ORG_A, learningId: "l1"})
      );

      const record = await getRecord(ORG_A, "worker-1", "l1");
      expect(record.status).toBe("completed");
    });

  test("a forged/absent startedAt (never called startLearning) is refused",
    async () => {
      await seedProfile("worker-1");
      await seedMembership("worker-1", ORG_A, "worker");
      await seedLearning(ORG_A, "l1", {
        type: "video",
        minimumWatchSeconds: 30,
      });
      await seedRequirement(ORG_A, "r1", {requiredLearningIds: ["l1"]});
      await getMyRequiredLearning.run(
        callRequest("worker-1", {organizationId: ORG_A})
      );
      // Still "assigned" — startLearning was never called, so there is no
      // real startedAt server timestamp to measure elapsed time from.

      await expect(
        completeLearning.run(
          callRequest("worker-1", {organizationId: ORG_A, learningId: "l1"})
        )
      ).rejects.toThrow(/must start this learning item/);
    });

  test("exactly the minimum elapsed time (boundary) is accepted", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker");
    await seedLearning(ORG_A, "l1", {
      type: "video",
      minimumWatchSeconds: 30,
    });
    await seedRequirement(ORG_A, "r1", {requiredLearningIds: ["l1"]});
    await getMyRequiredLearning.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );
    // A little over 30s in the past so the boundary is unambiguously
    // crossed despite the small amount of wall-clock time this test itself
    // takes to run — the gate is `elapsedSeconds < minimumWatchSeconds`, so
    // exactly-equal-or-past is accepted, never rejected.
    await db.doc(await recordPath("worker-1", "l1")).update({
      status: "inProgress",
      startedAt: new Date(Date.now() - 30500),
    });

    await completeLearning.run(
      callRequest("worker-1", {organizationId: ORG_A, learningId: "l1"})
    );

    const record = await getRecord(ORG_A, "worker-1", "l1");
    expect(record.status).toBe("completed");
  });

  test("a client cannot bypass the gate by submitting arbitrary " +
    "progress/duration/timestamp arguments — completeLearning accepts no " +
    "such fields at all", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker");
    await seedLearning(ORG_A, "l1", {
      type: "video",
      minimumWatchSeconds: 120,
    });
    await seedRequirement(ORG_A, "r1", {requiredLearningIds: ["l1"]});
    await getMyRequiredLearning.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );
    await startLearning.run(
      callRequest("worker-1", {organizationId: ORG_A, learningId: "l1"})
    );

    // A modified client (or a raw call bypassing the UI) tries to forge
    // "fully watched" via every plausible field name — none of them are
    // ever read by the callable, so none can affect the outcome.
    await expect(
      completeLearning.run(
        callRequest("worker-1", {
          organizationId: ORG_A,
          learningId: "l1",
          watched: true,
          watchedPercent: 100,
          progress: 1,
          watchedSeconds: 999999,
          completedAt: new Date("2000-01-01"),
        })
      )
    ).rejects.toThrow(/Keep this item open/);

    const record = await getRecord(ORG_A, "worker-1", "l1");
    expect(record.status).toBe("inProgress");
  });

  test("a video item with no minimumWatchSeconds set behaves exactly as " +
    "before (no gate)", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker");
    await seedLearning(ORG_A, "l1", {type: "video"});
    await seedRequirement(ORG_A, "r1", {requiredLearningIds: ["l1"]});
    await getMyRequiredLearning.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );
    await startLearning.run(
      callRequest("worker-1", {organizationId: ORG_A, learningId: "l1"})
    );

    await completeLearning.run(
      callRequest("worker-1", {organizationId: ORG_A, learningId: "l1"})
    );

    const record = await getRecord(ORG_A, "worker-1", "l1");
    expect(record.status).toBe("completed");
  });

  test("a document with a configured minimumWatchSeconds IS subject to " +
    "the same engagement-time gate as video — refused before it elapses",
  async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker");
    await seedLearning(ORG_A, "l1", {
      type: "document",
      minimumWatchSeconds: 999,
    });
    await seedRequirement(ORG_A, "r1", {requiredLearningIds: ["l1"]});
    await getMyRequiredLearning.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );
    await startLearning.run(
      callRequest("worker-1", {organizationId: ORG_A, learningId: "l1"})
    );

    await expect(
      completeLearning.run(
        callRequest("worker-1", {organizationId: ORG_A, learningId: "l1"})
      )
    ).rejects.toThrow(/Keep this item open/);

    const record = await getRecord(ORG_A, "worker-1", "l1");
    expect(record.status).toBe("inProgress");
  });

  test("a document's engagement-time gate is satisfied once enough time " +
    "has genuinely elapsed", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker");
    await seedLearning(ORG_A, "l1", {
      type: "document",
      minimumWatchSeconds: 30,
    });
    await seedRequirement(ORG_A, "r1", {requiredLearningIds: ["l1"]});
    await getMyRequiredLearning.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );
    await db.doc(await recordPath("worker-1", "l1")).update({
      status: "inProgress",
      startedAt: new Date(Date.now() - 60000),
    });

    await completeLearning.run(
      callRequest("worker-1", {organizationId: ORG_A, learningId: "l1"})
    );

    const record = await getRecord(ORG_A, "worker-1", "l1");
    expect(record.status).toBe("completed");
  });

  test("a course/guide item with a configured minimumWatchSeconds is " +
    "subject to the same gate", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker");
    await seedLearning(ORG_A, "l1", {
      type: "course",
      minimumWatchSeconds: 999,
    });
    await seedRequirement(ORG_A, "r1", {requiredLearningIds: ["l1"]});
    await getMyRequiredLearning.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );
    await startLearning.run(
      callRequest("worker-1", {organizationId: ORG_A, learningId: "l1"})
    );

    await expect(
      completeLearning.run(
        callRequest("worker-1", {organizationId: ORG_A, learningId: "l1"})
      )
    ).rejects.toThrow(/Keep this item open/);
  });

  test("a worker cannot satisfy another worker's watch-time gate by " +
    "targeting their own call at someone else's record", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker");
    await seedProfile("worker-2");
    await seedMembership("worker-2", ORG_A, "worker");
    await seedLearning(ORG_A, "l1", {
      type: "video",
      minimumWatchSeconds: 120,
    });
    await seedRequirement(ORG_A, "r1", {requiredLearningIds: ["l1"]});
    await getMyRequiredLearning.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );
    await getMyRequiredLearning.run(
      callRequest("worker-2", {organizationId: ORG_A})
    );
    // worker-2 genuinely waited the full minimum; worker-1 did not.
    await db.doc(await recordPath("worker-2", "l1")).update({
      status: "inProgress",
      startedAt: new Date(Date.now() - 200000),
    });
    await startLearning.run(
      callRequest("worker-1", {organizationId: ORG_A, learningId: "l1"})
    );

    // completeLearning accepts no workerUid argument — worker-1 calling it
    // can only ever act on worker-1's own record, never worker-2's, no
    // matter what is in the request payload.
    await expect(
      completeLearning.run(
        callRequest("worker-1", {organizationId: ORG_A, learningId: "l1"})
      )
    ).rejects.toThrow(/Keep this item open/);

    const worker1Record = await getRecord(ORG_A, "worker-1", "l1");
    const worker2Record = await getRecord(ORG_A, "worker-2", "l1");
    expect(worker1Record.status).toBe("inProgress");
    expect(worker2Record.status).toBe("inProgress");
  });
});

describe("completeLearning (knowledge check grading)", () => {
  async function setUpWorkerWithLearning(learningOverrides = {}) {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker");
    await seedLearning(ORG_A, "l1", learningOverrides);
    await seedRequirement(ORG_A, "r1", {requiredLearningIds: ["l1"]});
    await getMyRequiredLearning.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );
    await startLearning.run(
      callRequest("worker-1", {organizationId: ORG_A, learningId: "l1"})
    );
  }

  test("all-correct answers pass with a full score", async () => {
    await setUpWorkerWithLearning({passingScorePercent: 100});
    await seedQuestion(ORG_A, "l1", "q1", {correctOptionId: "a"});
    await seedQuestion(ORG_A, "l1", "q2", {correctOptionId: "b", order: 1});

    const result = await completeLearning.run(
      callRequest("worker-1", {
        organizationId: ORG_A,
        learningId: "l1",
        selectedAnswers: [
          {questionId: "q1", optionId: "a"},
          {questionId: "q2", optionId: "b"},
        ],
      })
    );

    expect(result.status).toBe("completed");
    expect(result.knowledgeCheckResult).toEqual({
      passed: true,
      score: 2,
      totalQuestions: 2,
    });
    const record = await getRecord(ORG_A, "worker-1", "l1");
    expect(record.status).toBe("completed");
    expect(record.knowledgeCheckResult).toEqual({
      passed: true,
      score: 2,
      totalQuestions: 2,
    });
  });

  test("partial-correct answers below the threshold fail, leaving the " +
    "record inProgress", async () => {
    await setUpWorkerWithLearning({passingScorePercent: 100});
    await seedQuestion(ORG_A, "l1", "q1", {correctOptionId: "a"});
    await seedQuestion(ORG_A, "l1", "q2", {correctOptionId: "b", order: 1});

    const result = await completeLearning.run(
      callRequest("worker-1", {
        organizationId: ORG_A,
        learningId: "l1",
        selectedAnswers: [
          {questionId: "q1", optionId: "a"},
          {questionId: "q2", optionId: "a"},
        ],
      })
    );

    expect(result.status).toBe("inProgress");
    expect(result.knowledgeCheckResult).toEqual({
      passed: false,
      score: 1,
      totalQuestions: 2,
    });
    const record = await getRecord(ORG_A, "worker-1", "l1");
    expect(record.status).toBe("inProgress");
    expect(record.knowledgeCheckResult).toBeUndefined();
  });

  test("zero-correct answers fail with a score of 0", async () => {
    await setUpWorkerWithLearning({passingScorePercent: 50});
    await seedQuestion(ORG_A, "l1", "q1", {correctOptionId: "a"});

    const result = await completeLearning.run(
      callRequest("worker-1", {
        organizationId: ORG_A,
        learningId: "l1",
        selectedAnswers: [{questionId: "q1", optionId: "b"}],
      })
    );

    expect(result.status).toBe("inProgress");
    expect(result.knowledgeCheckResult).toEqual({
      passed: false,
      score: 0,
      totalQuestions: 1,
    });
  });

  test("passes exactly at the configured passing-score boundary", async () => {
    await setUpWorkerWithLearning({passingScorePercent: 50});
    await seedQuestion(ORG_A, "l1", "q1", {correctOptionId: "a"});
    await seedQuestion(ORG_A, "l1", "q2", {correctOptionId: "a", order: 1});

    // 1/2 = 50% — exactly at the threshold, must pass ("passed: percent >=
    // passingScorePercent", not strictly greater-than).
    const result = await completeLearning.run(
      callRequest("worker-1", {
        organizationId: ORG_A,
        learningId: "l1",
        selectedAnswers: [
          {questionId: "q1", optionId: "a"},
          {questionId: "q2", optionId: "b"},
        ],
      })
    );

    expect(result.knowledgeCheckResult.passed).toBe(true);
    expect(result.status).toBe("completed");
  });

  test("fails one point below the configured passing-score boundary",
    async () => {
      await setUpWorkerWithLearning({passingScorePercent: 51});
      await seedQuestion(ORG_A, "l1", "q1", {correctOptionId: "a"});
      await seedQuestion(ORG_A, "l1", "q2", {correctOptionId: "a", order: 1});

      // 1/2 = 50%, below a 51% threshold.
      const result = await completeLearning.run(
        callRequest("worker-1", {
          organizationId: ORG_A,
          learningId: "l1",
          selectedAnswers: [
            {questionId: "q1", optionId: "a"},
            {questionId: "q2", optionId: "b"},
          ],
        })
      );

      expect(result.knowledgeCheckResult.passed).toBe(false);
      expect(result.status).toBe("inProgress");
    });

  test("a failed attempt can be retried and succeeds once the worker " +
    "answers correctly", async () => {
    await setUpWorkerWithLearning({passingScorePercent: 100});
    await seedQuestion(ORG_A, "l1", "q1", {correctOptionId: "a"});

    const failed = await completeLearning.run(
      callRequest("worker-1", {
        organizationId: ORG_A,
        learningId: "l1",
        selectedAnswers: [{questionId: "q1", optionId: "b"}],
      })
    );
    expect(failed.status).toBe("inProgress");

    const retried = await completeLearning.run(
      callRequest("worker-1", {
        organizationId: ORG_A,
        learningId: "l1",
        selectedAnswers: [{questionId: "q1", optionId: "a"}],
      })
    );

    expect(retried.status).toBe("completed");
    expect(retried.knowledgeCheckResult.passed).toBe(true);
    const record = await getRecord(ORG_A, "worker-1", "l1");
    expect(record.status).toBe("completed");
  });

  test("a forged passed/score/percent payload has no effect — grading is " +
    "entirely server-side from selectedAnswers alone", async () => {
    await setUpWorkerWithLearning({passingScorePercent: 100});
    await seedQuestion(ORG_A, "l1", "q1", {correctOptionId: "a"});

    const result = await completeLearning.run(
      callRequest("worker-1", {
        organizationId: ORG_A,
        learningId: "l1",
        // A wrong answer, but a request that ALSO claims a perfect score —
        // none of these extra fields are ever read.
        selectedAnswers: [{questionId: "q1", optionId: "b"}],
        passed: true,
        score: 100,
        percent: 100,
        knowledgeCheckResult: {passed: true, score: 999, totalQuestions: 1},
      })
    );

    expect(result.status).toBe("inProgress");
    expect(result.knowledgeCheckResult.passed).toBe(false);
    expect(result.knowledgeCheckResult.score).toBe(0);
  });

  test("an out-of-set questionId cannot inflate the score or the " +
    "denominator", async () => {
    await setUpWorkerWithLearning({passingScorePercent: 100});
    await seedQuestion(ORG_A, "l1", "q1", {correctOptionId: "a"});

    const result = await completeLearning.run(
      callRequest("worker-1", {
        organizationId: ORG_A,
        learningId: "l1",
        selectedAnswers: [
          {questionId: "q1", optionId: "a"},
          // Neither a real question nor counted — the denominator stays 1,
          // the numerator stays 1, so this is a pass, not a coincidental
          // one caused by the forged entry.
          {questionId: "not-a-real-question", optionId: "a"},
        ],
      })
    );

    expect(result.status).toBe("completed");
    expect(result.knowledgeCheckResult).toEqual({
      passed: true,
      score: 1,
      totalQuestions: 1,
    });
  });

  test("a real question id belonging to a DIFFERENT learning item cannot " +
    "be used to answer this one", async () => {
    await setUpWorkerWithLearning({passingScorePercent: 100});
    await seedQuestion(ORG_A, "l1", "q1", {correctOptionId: "a"});
    // A second, unrelated learning item with its own genuinely-correct
    // question — never assigned to worker-1, never part of l1's set.
    await seedLearning(ORG_A, "l2", {passingScorePercent: 100});
    await seedQuestion(ORG_A, "l2", "q-other", {correctOptionId: "z"});

    const result = await completeLearning.run(
      callRequest("worker-1", {
        organizationId: ORG_A,
        learningId: "l1",
        selectedAnswers: [
          {questionId: "q1", optionId: "a"},
          // A real question id, but scoped to l2, not l1 — fetchStoredQuestions
          // only ever reads l1's own subcollection, so this can never match
          // and never counts toward either the numerator or denominator.
          {questionId: "q-other", optionId: "z"},
        ],
      })
    );

    expect(result.status).toBe("completed");
    expect(result.knowledgeCheckResult).toEqual({
      passed: true,
      score: 1,
      totalQuestions: 1,
    });
  });

  // Changed deliberately: a call without answers used to be refused; it
  // now records the content step (video watched) and leaves the mandatory
  // quiz outstanding — it still never completes the item.
  test("without selectedAnswers, a mandatory quiz keeps the item open and " +
    "only the content step is recorded", async () => {
    await setUpWorkerWithLearning({passingScorePercent: 100});
    await seedQuestion(ORG_A, "l1", "q1", {correctOptionId: "a"});

    const result = await completeLearning.run(
      callRequest("worker-1", {organizationId: ORG_A, learningId: "l1"})
    );
    expect(result.status).toBe("inProgress");
    expect(result.quizOutstanding).toBe(true);

    const record = await getRecord(ORG_A, "worker-1", "l1");
    expect(record.status).toBe("inProgress");
    expect(record.contentCompletedAt).toBeDefined();
    expect(record.completedAt).toBeUndefined();
  });

  test("a knowledgeCheck-type item with ZERO configured questions has no " +
    "gate at all — completes exactly as before this phase", async () => {
    await setUpWorkerWithLearning({
      type: "knowledgeCheck",
      passingScorePercent: 100,
    });
    // No questions seeded at all.

    const result = await completeLearning.run(
      callRequest("worker-1", {organizationId: ORG_A, learningId: "l1"})
    );

    expect(result.status).toBe("completed");
    expect(result.knowledgeCheckResult).toBeUndefined();
  });

  test("a video item can require BOTH minimumWatchSeconds AND a passing " +
    "knowledge check — both gates enforced independently", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker");
    await seedLearning(ORG_A, "l1", {
      type: "video",
      minimumWatchSeconds: 999,
      passingScorePercent: 100,
    });
    await seedRequirement(ORG_A, "r1", {requiredLearningIds: ["l1"]});
    await seedQuestion(ORG_A, "l1", "q1", {correctOptionId: "a"});
    await getMyRequiredLearning.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );
    await startLearning.run(
      callRequest("worker-1", {organizationId: ORG_A, learningId: "l1"})
    );

    // The video gate alone is already unmet (999s minimum, just started) —
    // refused before grading is even attempted, regardless of the answer.
    await expect(
      completeLearning.run(
        callRequest("worker-1", {
          organizationId: ORG_A,
          learningId: "l1",
          selectedAnswers: [{questionId: "q1", optionId: "a"}],
        })
      )
    ).rejects.toThrow(/Keep this item open/);

    // Once the video gate is satisfied (simulated via a past startedAt) but
    // the quiz answer is wrong, the knowledge-check gate alone blocks it.
    await db
      .doc(
        `organizations/${ORG_A}/worker_learning_records/worker-1_l1`
      )
      .update({startedAt: new Date(Date.now() - 1000000)});

    const wrongAnswer = await completeLearning.run(
      callRequest("worker-1", {
        organizationId: ORG_A,
        learningId: "l1",
        selectedAnswers: [{questionId: "q1", optionId: "b"}],
      })
    );
    expect(wrongAnswer.status).toBe("inProgress");
    expect(wrongAnswer.knowledgeCheckResult.passed).toBe(false);

    // Both gates satisfied -> completes.
    const bothPass = await completeLearning.run(
      callRequest("worker-1", {
        organizationId: ORG_A,
        learningId: "l1",
        selectedAnswers: [{questionId: "q1", optionId: "a"}],
      })
    );
    expect(bothPass.status).toBe("completed");
  });

  test("non-video/non-knowledge-check completion (e.g. a document) is " +
    "unaffected when it has no questions configured", async () => {
    await setUpWorkerWithLearning({type: "document"});

    const result = await completeLearning.run(
      callRequest("worker-1", {organizationId: ORG_A, learningId: "l1"})
    );

    expect(result.status).toBe("completed");
    expect(result.knowledgeCheckResult).toBeUndefined();
  });

  test("a document can require BOTH a minimum engagement time AND a " +
    "passing knowledge check — both gates enforced independently, " +
    "mirroring the video combination", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker");
    await seedLearning(ORG_A, "l1", {
      type: "document",
      minimumWatchSeconds: 999,
      passingScorePercent: 100,
    });
    await seedRequirement(ORG_A, "r1", {requiredLearningIds: ["l1"]});
    await seedQuestion(ORG_A, "l1", "q1", {correctOptionId: "a"});
    await getMyRequiredLearning.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );
    await startLearning.run(
      callRequest("worker-1", {organizationId: ORG_A, learningId: "l1"})
    );

    // Engagement-time gate alone is unmet — refused before grading even
    // runs, regardless of whether the answer would have been correct.
    await expect(
      completeLearning.run(
        callRequest("worker-1", {
          organizationId: ORG_A,
          learningId: "l1",
          selectedAnswers: [{questionId: "q1", optionId: "a"}],
        })
      )
    ).rejects.toThrow(/Keep this item open/);

    // Engagement satisfied, but the answer is wrong — knowledge-check gate
    // alone blocks it, record stays inProgress.
    await db
      .doc(`organizations/${ORG_A}/worker_learning_records/worker-1_l1`)
      .update({startedAt: new Date(Date.now() - 1000000)});
    const wrongAnswer = await completeLearning.run(
      callRequest("worker-1", {
        organizationId: ORG_A,
        learningId: "l1",
        selectedAnswers: [{questionId: "q1", optionId: "b"}],
      })
    );
    expect(wrongAnswer.status).toBe("inProgress");
    expect(wrongAnswer.knowledgeCheckResult.passed).toBe(false);

    // Both satisfied -> completes.
    const bothPass = await completeLearning.run(
      callRequest("worker-1", {
        organizationId: ORG_A,
        learningId: "l1",
        selectedAnswers: [{questionId: "q1", optionId: "a"}],
      })
    );
    expect(bothPass.status).toBe("completed");
  });

  test("an already-completed record cannot be reset or re-processed by a " +
    "further completeLearning call", async () => {
    await setUpWorkerWithLearning({passingScorePercent: 100});
    await seedQuestion(ORG_A, "l1", "q1", {correctOptionId: "a"});

    const firstAttempt = await completeLearning.run(
      callRequest("worker-1", {
        organizationId: ORG_A,
        learningId: "l1",
        selectedAnswers: [{questionId: "q1", optionId: "a"}],
      })
    );
    expect(firstAttempt.status).toBe("completed");

    // A further call — whether re-submitting the same answer, a different
    // (even wrong) one, or none at all — must be refused outright rather
    // than silently re-grading or leaving the record open to a downgrade.
    await expect(
      completeLearning.run(
        callRequest("worker-1", {
          organizationId: ORG_A,
          learningId: "l1",
          selectedAnswers: [{questionId: "q1", optionId: "b"}],
        })
      )
    ).rejects.toThrow(/cannot be completed from its current state/);

    const record = await getRecord(ORG_A, "worker-1", "l1");
    expect(record.status).toBe("completed");
    expect(record.knowledgeCheckResult).toEqual({
      passed: true,
      score: 1,
      totalQuestions: 1,
    });
  });
});

describe("getKnowledgeCheckQuestions", () => {
  test("returns the worker-safe view — correctOptionId is never present " +
    "anywhere in the response", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker");
    await seedLearning(ORG_A, "l1");
    await seedRequirement(ORG_A, "r1", {requiredLearningIds: ["l1"]});
    await seedQuestion(ORG_A, "l1", "q1", {
      prompt: "What must you wear at height?",
      options: [
        {id: "a", text: "A harness"},
        {id: "b", text: "Sunglasses"},
      ],
      correctOptionId: "a",
    });

    const result = await getKnowledgeCheckQuestions.run(
      callRequest("worker-1", {organizationId: ORG_A, learningId: "l1"})
    );

    expect(result.questions).toHaveLength(1);
    expect(result.questions[0]).toEqual({
      id: "q1",
      prompt: "What must you wear at height?",
      options: [
        {id: "a", text: "A harness"},
        {id: "b", text: "Sunglasses"},
      ],
      order: 0,
    });
    // Belt-and-suspenders: assert the raw serialized response never
    // contains the string "correctOptionId" anywhere, not just that the
    // parsed object lacks the field.
    expect(JSON.stringify(result)).not.toContain("correctOptionId");
  });

  test("returns an empty list, not an error, when no questions are " +
    "configured", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker");
    await seedLearning(ORG_A, "l1");
    await seedRequirement(ORG_A, "r1", {requiredLearningIds: ["l1"]});

    const result = await getKnowledgeCheckQuestions.run(
      callRequest("worker-1", {organizationId: ORG_A, learningId: "l1"})
    );

    expect(result.questions).toEqual([]);
  });

  // Changed deliberately: an OPTIONAL (not required) active item's quiz is
  // now available for practice — still without any answer key.
  test("an active item not required of the caller returns its questions, " +
    "flagged not required", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker");
    await seedLearning(ORG_A, "l1");
    await seedQuestion(ORG_A, "l1", "q1", {correctOptionId: "a"});
    // Not referenced by any requirement.

    const result = await getKnowledgeCheckQuestions.run(
      callRequest("worker-1", {organizationId: ORG_A, learningId: "l1"})
    );
    expect(result.required).toBe(false);
    expect(result.quizRequired).toBe(false);
    expect(result.questions).toHaveLength(1);
    expect(JSON.stringify(result)).not.toContain("correctOptionId");
  });

  test("is refused for an inactive or missing item", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker");
    await seedLearning(ORG_A, "l1", {status: "inactive"});

    for (const learningId of ["l1", "missing"]) {
      await expect(
        getKnowledgeCheckQuestions.run(
          callRequest("worker-1", {organizationId: ORG_A, learningId})
        )
      ).rejects.toThrow(/not available/);
    }
  });

  test("an unauthenticated caller is refused", async () => {
    await expect(
      getKnowledgeCheckQuestions.run(
        callRequest(null, {organizationId: ORG_A, learningId: "l1"})
      )
    ).rejects.toThrow(/permission/);
  });
});

// ---------------------------------------------------------------------------
// requiredBeforeWork — resolver-level semantics.
// ---------------------------------------------------------------------------

const ORG_B = "org-beta";

function meetingToday() {
  return require("../lib/worker_learning_callable").todaysMeetingDate();
}

async function seedMeeting(organizationId, id, overrides = {}) {
  await db
    .doc(`organizations/${organizationId}/daily_safety_meetings/${id}`)
    .set({
      organizationId,
      projectId: "project-1",
      siteId: "site-1",
      date: meetingToday(),
      startTime: new Date(),
      endTime: null,
      foremanId: "foreman-1",
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

async function seedCompleted(organizationId, workerUid, learningId) {
  await db
    .doc(`organizations/${organizationId}/worker_learning_records/` +
      `${workerUid}_${learningId}`)
    .set({
      workerUid,
      organizationId,
      learningId,
      status: "completed",
      assignedAt: new Date(),
      completedAt: new Date(),
    });
}

/** A worker on site-1, assigned to activity-1 (project-1). */
async function seedSiteWorker(uid = "worker-1") {
  await seedProfile(uid);
  await seedMembership(uid, ORG_A, "worker", ["site-1"]);
  await seedActivity(ORG_A, "activity-1", "site-1");
  await seedAssignment(ORG_A, "activity-1", uid, "site-1", "project-1");
}

const SCOPE = {
  siteIds: new Set(["site-1"]),
  activityIds: new Set(["activity-1"]),
  projectIds: new Set(["project-1"]),
};

function ids(map) {
  return [...map.keys()].sort();
}

function readinessIds(result) {
  return {
    beforeMeeting: result.beforeMeeting.map((i) => i.learningId).sort(),
    beforeWork: result.beforeWork.map((i) => i.learningId).sort(),
    additional: result.additional.map((i) => i.learningId).sort(),
  };
}

describe("resolvePreWorkLearningIds / requiredBeforeWork semantics", () => {
  test("legacy requirement missing requiredBeforeWork is NOT pre-work, " +
    "but stays required and gating (gatesAttendance default unchanged)",
  async () => {
    await seedLearning(ORG_A, "l1");
    await seedRequirement(ORG_A, "r1", {requiredLearningIds: ["l1"]});

    expect(ids(await resolvePreWorkLearningIds(ORG_A, SCOPE))).toEqual([]);
    expect(ids(await resolveRequiredLearningForScope(ORG_A, SCOPE)))
      .toEqual(["l1"]);
    expect(ids(await resolveAttendanceGatingLearningIds(ORG_A, SCOPE)))
      .toEqual(["l1"]);
  });

  test("all four gatesAttendance x requiredBeforeWork combinations " +
    "classify independently", async () => {
    await seedLearning(ORG_A, "ff");
    await seedLearning(ORG_A, "tf");
    await seedLearning(ORG_A, "ft");
    await seedLearning(ORG_A, "tt");
    // Naming: <requiredBeforeWork><gatesAttendance>.
    await seedRequirement(ORG_A, "r-ff", {
      requiredLearningIds: ["ff"],
      requiredBeforeWork: false,
      gatesAttendance: false,
    });
    await seedRequirement(ORG_A, "r-tf", {
      requiredLearningIds: ["tf"],
      requiredBeforeWork: true,
      gatesAttendance: false,
    });
    await seedRequirement(ORG_A, "r-ft", {
      requiredLearningIds: ["ft"],
      requiredBeforeWork: false,
      gatesAttendance: true,
    });
    await seedRequirement(ORG_A, "r-tt", {
      requiredLearningIds: ["tt"],
      requiredBeforeWork: true,
      gatesAttendance: true,
    });

    expect(ids(await resolveRequiredLearningForScope(ORG_A, SCOPE)))
      .toEqual(["ff", "ft", "tf", "tt"]);
    expect(ids(await resolveAttendanceGatingLearningIds(ORG_A, SCOPE)))
      .toEqual(["ft", "tt"]);
    expect(ids(await resolvePreWorkLearningIds(ORG_A, SCOPE)))
      .toEqual(["tf", "tt"]);
  });

  test("overlap is resolved per requirement, not from a flattened list",
    async () => {
      for (const id of ["l1", "l2", "l3"]) await seedLearning(ORG_A, id);
      // Requirement A: gating, [L1, L2]. Requirement B: non-gating
      // pre-work, [L2, L3].
      await seedRequirement(ORG_A, "rA", {
        requiredLearningIds: ["l1", "l2"],
        gatesAttendance: true,
      });
      await seedRequirement(ORG_A, "rB", {
        requiredLearningIds: ["l2", "l3"],
        gatesAttendance: false,
        requiredBeforeWork: true,
      });

      expect(ids(await resolveAttendanceGatingLearningIds(ORG_A, SCOPE)))
        .toEqual(["l1", "l2"]);
      expect(ids(await resolvePreWorkLearningIds(ORG_A, SCOPE)))
        .toEqual(["l2", "l3"]);
    });

  test("a learning id in both a pre-work and a non-pre-work requirement " +
    "is pre-work", async () => {
    await seedLearning(ORG_A, "l1");
    await seedRequirement(ORG_A, "r1", {requiredLearningIds: ["l1"]});
    await seedRequirement(ORG_A, "r2", {
      requiredLearningIds: ["l1"],
      requiredBeforeWork: true,
    });

    expect(ids(await resolvePreWorkLearningIds(ORG_A, SCOPE)))
      .toEqual(["l1"]);
  });

  test("respects scope: an out-of-scope pre-work requirement is excluded",
    async () => {
      await seedLearning(ORG_A, "l1");
      await seedRequirement(ORG_A, "r1", {
        requiredLearningIds: ["l1"],
        requiredBeforeWork: true,
        activityId: "activity-other",
      });

      expect(ids(await resolvePreWorkLearningIds(ORG_A, SCOPE))).toEqual([]);
    });

  test("requiredBeforeWork does not change getMyRequiredLearning's total",
    async () => {
      await seedSiteWorker();
      await seedLearning(ORG_A, "l1");
      await seedLearning(ORG_A, "l2");
      await seedRequirement(ORG_A, "r1", {
        requiredLearningIds: ["l1"],
        requiredBeforeWork: true,
      });
      await seedRequirement(ORG_A, "r2", {requiredLearningIds: ["l2"]});

      const result = await getMyRequiredLearning.run(
        callRequest("worker-1", {organizationId: ORG_A})
      );
      expect(result.total).toBe(2);
    });
});

describe("getMyTodaysSafetyReadiness", () => {
  test("separates attendance-gating, pre-work and additional learning " +
    "(no meeting yet: resolved from the worker's own assignments)",
  async () => {
    await seedSiteWorker();
    for (const id of ["gate", "pre", "other"]) await seedLearning(ORG_A, id);
    await seedRequirement(ORG_A, "r-gate", {
      requiredLearningIds: ["gate"],
      gatesAttendance: true,
    });
    await seedRequirement(ORG_A, "r-pre", {
      requiredLearningIds: ["pre"],
      gatesAttendance: false,
      requiredBeforeWork: true,
    });
    await seedRequirement(ORG_A, "r-other", {
      requiredLearningIds: ["other"],
      gatesAttendance: false,
    });

    const result = await getMyTodaysSafetyReadiness.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );

    expect(result.gatingSource).toBe("assignments");
    expect(result.meeting).toBeNull();
    expect(readinessIds(result)).toEqual({
      beforeMeeting: ["gate"],
      beforeWork: ["pre"],
      additional: ["other"],
    });
    expect(result.beforeMeeting[0].status).toBe("notStarted");
    expect(result.beforeMeeting[0].canStart).toBe(true);
  });

  test("an item that is both gating and pre-work appears once, in " +
    "beforeMeeting", async () => {
    await seedSiteWorker();
    await seedLearning(ORG_A, "both");
    await seedRequirement(ORG_A, "r1", {
      requiredLearningIds: ["both"],
      gatesAttendance: true,
      requiredBeforeWork: true,
    });

    const result = await getMyTodaysSafetyReadiness.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );

    expect(readinessIds(result)).toEqual({
      beforeMeeting: ["both"],
      beforeWork: [],
      additional: [],
    });
  });

  test("overlap across requirements: L2 stays in beforeMeeting", async () => {
    await seedSiteWorker();
    for (const id of ["l1", "l2", "l3"]) await seedLearning(ORG_A, id);
    await seedRequirement(ORG_A, "rA", {
      requiredLearningIds: ["l1", "l2"],
      gatesAttendance: true,
    });
    await seedRequirement(ORG_A, "rB", {
      requiredLearningIds: ["l2", "l3"],
      gatesAttendance: false,
      requiredBeforeWork: true,
    });

    const result = await getMyTodaysSafetyReadiness.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );

    // Only ONE general "Before meeting" lesson is needed today (l1, first
    // on the requirement); l2 is pre-work too, so it is listed there.
    expect(readinessIds(result)).toEqual({
      beforeMeeting: ["l1"],
      beforeWork: ["l2", "l3"],
      additional: [],
    });
  });

  test("completed learning never appears", async () => {
    await seedSiteWorker();
    await seedLearning(ORG_A, "l1");
    await seedLearning(ORG_A, "l2");
    await seedRequirement(ORG_A, "r1", {
      requiredLearningIds: ["l1", "l2"],
      requiredBeforeWork: true,
    });
    await seedCompleted(ORG_A, "worker-1", "l1");

    const result = await getMyTodaysSafetyReadiness.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );

    expect(readinessIds(result).beforeMeeting).toEqual(["l2"]);
  });

  test("returns empty sections when everything is complete", async () => {
    await seedSiteWorker();
    await seedLearning(ORG_A, "l1");
    await seedRequirement(ORG_A, "r1", {requiredLearningIds: ["l1"]});
    await seedCompleted(ORG_A, "worker-1", "l1");

    const result = await getMyTodaysSafetyReadiness.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );

    expect(readinessIds(result)).toEqual({
      beforeMeeting: [],
      beforeWork: [],
      additional: [],
    });
  });

  test("project, site and activity scopes each apply", async () => {
    await seedSiteWorker();
    for (const id of ["p", "s", "a", "x"]) await seedLearning(ORG_A, id);
    await seedRequirement(ORG_A, "rp", {
      requiredLearningIds: ["p"],
      projectId: "project-1",
      requiredBeforeWork: true,
      gatesAttendance: false,
    });
    await seedRequirement(ORG_A, "rs", {
      requiredLearningIds: ["s"],
      siteId: "site-1",
      requiredBeforeWork: true,
      gatesAttendance: false,
    });
    await seedRequirement(ORG_A, "ra", {
      requiredLearningIds: ["a"],
      activityId: "activity-1",
      requiredBeforeWork: true,
      gatesAttendance: false,
    });
    await seedRequirement(ORG_A, "rx", {
      requiredLearningIds: ["x"],
      activityId: "activity-elsewhere",
      requiredBeforeWork: true,
    });

    const result = await getMyTodaysSafetyReadiness.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );

    expect(readinessIds(result).beforeWork).toEqual(["a", "p", "s"]);
  });

  test("a multi-activity worker gets pre-work from every assigned activity",
    async () => {
      await seedSiteWorker();
      await seedActivity(ORG_A, "activity-2", "site-1");
      await seedAssignment(
        ORG_A, "activity-2", "worker-1", "site-1", "project-1"
      );
      await seedLearning(ORG_A, "l1");
      await seedLearning(ORG_A, "l2");
      await seedRequirement(ORG_A, "r1", {
        requiredLearningIds: ["l1"],
        activityId: "activity-1",
        requiredBeforeWork: true,
        gatesAttendance: false,
      });
      await seedRequirement(ORG_A, "r2", {
        requiredLearningIds: ["l2"],
        activityId: "activity-2",
        requiredBeforeWork: true,
        gatesAttendance: false,
      });

      const result = await getMyTodaysSafetyReadiness.run(
        callRequest("worker-1", {organizationId: ORG_A})
      );

      expect(readinessIds(result).beforeWork).toEqual(["l1", "l2"]);
      expect(result.scope.activities.map((a) => a.id).sort())
        .toEqual(["activity-1", "activity-2"]);
    });

  test("once today's meeting exists, beforeMeeting uses the MEETING's " +
    "scope — the same scope recordMeetingAttendance enforces", async () => {
    await seedSiteWorker();
    await seedActivity(ORG_A, "activity-2", "site-1");
    await seedLearning(ORG_A, "l1");
    await seedLearning(ORG_A, "l2");
    await seedRequirement(ORG_A, "r1", {
      requiredLearningIds: ["l1"],
      activityId: "activity-1",
    });
    await seedRequirement(ORG_A, "r2", {
      requiredLearningIds: ["l2"],
      activityId: "activity-2",
    });
    // The meeting covers activity-2 only.
    await seedMeeting(ORG_A, "meeting-1", {activityIds: ["activity-2"]});

    const result = await getMyTodaysSafetyReadiness.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );

    expect(result.gatingSource).toBe("meeting");
    expect(result.meeting.id).toBe("meeting-1");
    expect(result.meeting.status).toBe("inProgress");
    // "Needed today" follows the worker's OWN work (activity-1), not every
    // activity on the meeting — so it is l1, which they can start; l2 is
    // for work they are not doing.
    expect(readinessIds(result).beforeMeeting).toEqual(["l1"]);
    expect(result.beforeMeeting[0].canStart).toBe(true);
    expect(readinessIds(result).additional).toEqual([]);
  });

  test("ignores a meeting at a site the worker does not belong to, and a " +
    "meeting from another day", async () => {
    await seedSiteWorker();
    await seedMeeting(ORG_A, "elsewhere", {siteId: "site-2"});
    await seedMeeting(ORG_A, "yesterday", {date: "2000-01-01"});

    const result = await getMyTodaysSafetyReadiness.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );

    expect(result.meeting).toBeNull();
  });

  test("never returns another worker's progress or another organization's " +
    "learning", async () => {
    await seedSiteWorker("worker-1");
    await seedSiteWorker("worker-2");
    await seedLearning(ORG_A, "l1");
    await seedRequirement(ORG_A, "r1", {requiredLearningIds: ["l1"]});
    await seedCompleted(ORG_A, "worker-2", "l1");
    await seedLearning(ORG_B, "b1");
    await seedRequirement(ORG_B, "rb", {requiredLearningIds: ["b1"]});

    const result = await getMyTodaysSafetyReadiness.run(
      // Any workerUid argument is ignored — there is no such parameter.
      callRequest("worker-1", {organizationId: ORG_A, workerUid: "worker-2"})
    );

    expect(readinessIds(result).beforeMeeting).toEqual(["l1"]);
  });

  test("refuses a caller with no membership in the organization", async () => {
    await seedSiteWorker();

    await expect(
      getMyTodaysSafetyReadiness.run(
        callRequest("worker-1", {organizationId: ORG_B})
      )
    ).rejects.toThrow(/permission/);
  });

  test("refuses an unauthenticated caller", async () => {
    await expect(
      getMyTodaysSafetyReadiness.run(
        callRequest(null, {organizationId: ORG_A})
      )
    ).rejects.toThrow(/permission/);
  });
});

// ---------------------------------------------------------------------------
// Foreman learning scope: the sites they lead (they hold no assignments).
// ---------------------------------------------------------------------------

async function seedSiteDoc(organizationId, id, projectId = "project-1") {
  await db.doc(`organizations/${organizationId}/sites/${id}`).set({
    organizationId,
    projectId,
    name: `Site ${id}`,
    status: "active",
  });
}

async function seedForemanAt(uid, siteIds) {
  await seedProfile(uid);
  await seedMembership(uid, ORG_A, "foreman", siteIds);
}

describe("Foreman learning scope", () => {
  test("a foreman's required learning covers their site, its project and " +
    "its active activities — but not other sites or inactive activities",
  async () => {
    await seedSiteDoc(ORG_A, "site-1");
    await seedSiteDoc(ORG_A, "site-2", "project-2");
    await seedForemanAt("foreman-1", ["site-1"]);
    await seedActivity(ORG_A, "roofing", "site-1");
    await seedActivity(ORG_A, "retired", "site-1", {status: "inactive"});
    await seedActivity(ORG_A, "elsewhere", "site-2");
    for (const id of ["s", "p", "a", "inactive", "other"]) {
      await seedLearning(ORG_A, id);
    }
    await seedRequirement(ORG_A, "rs", {
      requiredLearningIds: ["s"], siteId: "site-1",
    });
    await seedRequirement(ORG_A, "rp", {
      requiredLearningIds: ["p"], projectId: "project-1",
    });
    await seedRequirement(ORG_A, "ra", {
      requiredLearningIds: ["a"], activityId: "roofing",
    });
    await seedRequirement(ORG_A, "ri", {
      requiredLearningIds: ["inactive"], activityId: "retired",
    });
    await seedRequirement(ORG_A, "ro", {
      requiredLearningIds: ["other"], activityId: "elsewhere",
    });

    const result = await getMyRequiredLearning.run(
      callRequest("foreman-1", {organizationId: ORG_A})
    );

    expect(result.total).toBe(3);
    for (const id of ["s", "p", "a"]) {
      expect(await getRecord(ORG_A, "foreman-1", id)).not.toBeNull();
    }
    expect(await getRecord(ORG_A, "foreman-1", "inactive")).toBeNull();
    expect(await getRecord(ORG_A, "foreman-1", "other")).toBeNull();
  });

  test("a foreman can now start site-scoped learning that gates their " +
    "meeting (previously refused as 'not currently required')", async () => {
    await seedSiteDoc(ORG_A, "site-1");
    await seedForemanAt("foreman-1", ["site-1"]);
    await seedLearning(ORG_A, "l1");
    await seedRequirement(ORG_A, "r1", {
      requiredLearningIds: ["l1"], siteId: "site-1",
    });

    const result = await startLearning.run(
      callRequest("foreman-1", {organizationId: ORG_A, learningId: "l1"})
    );

    expect(result.status).toBe("inProgress");
  });

  test("a worker's scope is unchanged: site membership alone, without an " +
    "assignment, still does not pull in site-scoped learning", async () => {
    await seedSiteDoc(ORG_A, "site-1");
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker", ["site-1"]);
    await seedLearning(ORG_A, "l1");
    await seedRequirement(ORG_A, "r1", {
      requiredLearningIds: ["l1"], siteId: "site-1",
    });

    const result = await getMyRequiredLearning.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );

    expect(result.total).toBe(0);
  });

  test("getMyTodaysSafetyReadiness for a foreman before their meeting: " +
    "the gating learning needed to START it", async () => {
    await seedSiteDoc(ORG_A, "site-1");
    await seedForemanAt("foreman-1", ["site-1"]);
    await seedActivity(ORG_A, "roofing", "site-1");
    for (const id of ["gate", "pre", "other"]) await seedLearning(ORG_A, id);
    await seedRequirement(ORG_A, "r-gate", {
      requiredLearningIds: ["gate"], activityId: "roofing",
    });
    await seedRequirement(ORG_A, "r-pre", {
      requiredLearningIds: ["pre"],
      siteId: "site-1",
      gatesAttendance: false,
      requiredBeforeWork: true,
    });
    await seedRequirement(ORG_A, "r-other", {
      requiredLearningIds: ["other"], gatesAttendance: false,
    });
    // Another foreman's meeting at the same site must not count.
    await seedMeeting(ORG_A, "someone-else", {foremanId: "foreman-2"});

    const result = await getMyTodaysSafetyReadiness.run(
      callRequest("foreman-1", {organizationId: ORG_A})
    );

    expect(result.role).toBe("foreman");
    expect(result.meeting).toBeNull();
    expect(readinessIds(result)).toEqual({
      beforeMeeting: ["gate"],
      beforeWork: ["pre"],
      additional: ["other"],
    });
    expect(result.beforeMeeting[0].canStart).toBe(true);
    expect(result.scope.activities.map((a) => a.id)).toEqual(["roofing"]);
  });

  test("once the foreman's own meeting exists, gating follows the " +
    "meeting's activities", async () => {
    await seedSiteDoc(ORG_A, "site-1");
    await seedForemanAt("foreman-1", ["site-1"]);
    await seedActivity(ORG_A, "roofing", "site-1");
    await seedActivity(ORG_A, "scaffold", "site-1");
    await seedLearning(ORG_A, "l-roof");
    await seedLearning(ORG_A, "l-scaffold");
    await seedRequirement(ORG_A, "r1", {
      requiredLearningIds: ["l-roof"], activityId: "roofing",
    });
    await seedRequirement(ORG_A, "r2", {
      requiredLearningIds: ["l-scaffold"], activityId: "scaffold",
    });
    await seedMeeting(ORG_A, "mine", {
      foremanId: "foreman-1",
      activityIds: ["roofing"],
    });

    const result = await getMyTodaysSafetyReadiness.run(
      callRequest("foreman-1", {organizationId: ORG_A})
    );

    expect(result.gatingSource).toBe("meeting");
    expect(result.meeting.id).toBe("mine");
    expect(readinessIds(result).beforeMeeting).toEqual(["l-roof"]);
    expect(readinessIds(result).additional).toEqual(["l-scaffold"]);
  });

  test("a worker's readiness reports role worker", async () => {
    await seedSiteWorker();

    const result = await getMyTodaysSafetyReadiness.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );

    expect(result.role).toBe("worker");
  });
});

// ---------------------------------------------------------------------------
// Per-lesson learningSettings (requirement -> learning relationship).
// ---------------------------------------------------------------------------

const S_ON = {gatesAttendance: true, requiredBeforeWork: true};
const S_GATE = {gatesAttendance: true, requiredBeforeWork: false};
const S_PRE = {gatesAttendance: false, requiredBeforeWork: true};
const S_OFF = {gatesAttendance: false, requiredBeforeWork: false};

describe("per-lesson learningSettings: resolver", () => {
  test("L1 gating, L2 not, L3 pre-work, L4 both off — within ONE " +
    "requirement", async () => {
    for (const id of ["l1", "l2", "l3", "l4"]) await seedLearning(ORG_A, id);
    await seedRequirement(ORG_A, "r1", {
      requiredLearningIds: ["l1", "l2", "l3", "l4"],
      // Requirement-level flags that would make everything gating/pre-work
      // if they were used — per-lesson settings must win.
      gatesAttendance: true,
      requiredBeforeWork: true,
      learningSettings: {l1: S_GATE, l2: S_OFF, l3: S_PRE, l4: S_OFF},
    });

    expect(ids(await resolveRequiredLearningForScope(ORG_A, SCOPE)))
      .toEqual(["l1", "l2", "l3", "l4"]);
    expect(ids(await resolveAttendanceGatingLearningIds(ORG_A, SCOPE)))
      .toEqual(["l1"]);
    expect(ids(await resolvePreWorkLearningIds(ORG_A, SCOPE)))
      .toEqual(["l3"]);
  });

  test("overlap: gating under A, not under B -> still gating (and the " +
    "reverse order)", async () => {
    await seedLearning(ORG_A, "l1");
    await seedRequirement(ORG_A, "rA", {
      requiredLearningIds: ["l1"], learningSettings: {l1: S_GATE},
    });
    await seedRequirement(ORG_A, "rB", {
      requiredLearningIds: ["l1"], learningSettings: {l1: S_OFF},
    });
    expect(ids(await resolveAttendanceGatingLearningIds(ORG_A, SCOPE)))
      .toEqual(["l1"]);

    await seedRequirement(ORG_A, "rA", {
      requiredLearningIds: ["l1"], learningSettings: {l1: S_OFF},
    });
    await seedRequirement(ORG_A, "rB", {
      requiredLearningIds: ["l1"], learningSettings: {l1: S_GATE},
    });
    expect(ids(await resolveAttendanceGatingLearningIds(ORG_A, SCOPE)))
      .toEqual(["l1"]);
  });

  test("overlap: pre-work under A, not under B -> still pre-work",
    async () => {
      await seedLearning(ORG_A, "l1");
      await seedRequirement(ORG_A, "rA", {
        requiredLearningIds: ["l1"], learningSettings: {l1: S_PRE},
      });
      await seedRequirement(ORG_A, "rB", {
        requiredLearningIds: ["l1"], learningSettings: {l1: S_OFF},
      });

      expect(ids(await resolvePreWorkLearningIds(ORG_A, SCOPE)))
        .toEqual(["l1"]);
    });

  test("the same lesson behaves differently per requirement, and only " +
    "APPLICABLE requirements count", async () => {
    await seedLearning(ORG_A, "harness");
    // Gating only under a requirement for an activity the scope does not
    // include.
    await seedRequirement(ORG_A, "scaffold", {
      requiredLearningIds: ["harness"],
      activityId: "activity-elsewhere",
      learningSettings: {harness: S_GATE},
    });
    await seedRequirement(ORG_A, "height", {
      requiredLearningIds: ["harness"],
      activityId: "activity-1",
      learningSettings: {harness: S_OFF},
    });

    expect(ids(await resolveRequiredLearningForScope(ORG_A, SCOPE)))
      .toEqual(["harness"]);
    expect(ids(await resolveAttendanceGatingLearningIds(ORG_A, SCOPE)))
      .toEqual([]);
  });

  test("legacy requirement (no map) keeps its requirement-level " +
    "behavior", async () => {
    await seedLearning(ORG_A, "l1");
    await seedLearning(ORG_A, "l2");
    await seedRequirement(ORG_A, "legacy", {
      requiredLearningIds: ["l1", "l2"],
      requiredBeforeWork: true,
    });

    expect(ids(await resolveAttendanceGatingLearningIds(ORG_A, SCOPE)))
      .toEqual(["l1", "l2"]);
    expect(ids(await resolvePreWorkLearningIds(ORG_A, SCOPE)))
      .toEqual(["l1", "l2"]);
  });

  test("a lesson missing from the map, or a malformed entry, falls back to " +
    "the requirement-level flag", async () => {
    for (const id of ["l1", "l2", "l3"]) await seedLearning(ORG_A, id);
    await seedRequirement(ORG_A, "r1", {
      requiredLearningIds: ["l1", "l2", "l3"],
      gatesAttendance: true,
      learningSettings: {
        l1: S_OFF,
        l2: {gatesAttendance: "yes"},
        // l3 absent
      },
    });

    expect(ids(await resolveAttendanceGatingLearningIds(ORG_A, SCOPE)))
      .toEqual(["l2", "l3"]);
  });

  test("project, site and activity scoped requirements each apply their " +
    "own per-lesson settings", async () => {
    for (const id of ["p", "s", "a"]) await seedLearning(ORG_A, id);
    await seedRequirement(ORG_A, "rp", {
      requiredLearningIds: ["p"], projectId: "project-1",
      learningSettings: {p: S_GATE},
    });
    await seedRequirement(ORG_A, "rs", {
      requiredLearningIds: ["s"], siteId: "site-1",
      learningSettings: {s: S_PRE},
    });
    await seedRequirement(ORG_A, "ra", {
      requiredLearningIds: ["a"], activityId: "activity-1",
      learningSettings: {a: S_ON},
    });

    expect(ids(await resolveAttendanceGatingLearningIds(ORG_A, SCOPE)))
      .toEqual(["a", "p"]);
    expect(ids(await resolvePreWorkLearningIds(ORG_A, SCOPE)))
      .toEqual(["a", "s"]);
  });
});

describe("per-lesson learningSettings: Today's Safety Readiness", () => {
  test("Working at Height with 7 lessons: 1 needed today, the rest pre-work " +
    "or when you can", async () => {
    await seedSiteWorker();
    const lessons = ["basics", "harness", "fall", "ladder", "scaffold",
      "anchor", "rescue"];
    for (const id of lessons) await seedLearning(ORG_A, id);
    await seedRequirement(ORG_A, "height", {
      requiredLearningIds: lessons,
      activityId: "activity-1",
      learningSettings: {
        basics: S_ON,
        harness: S_ON,
        fall: S_PRE,
        ladder: S_PRE,
        scaffold: S_OFF,
        anchor: S_OFF,
        rescue: S_OFF,
      },
    });

    const result = await getMyTodaysSafetyReadiness.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );

    // Two lessons are "Before meeting", but only the first is needed today;
    // harness (also pre-work) is listed under pre-work, and comes up as a
    // later day's lesson.
    expect(readinessIds(result)).toEqual({
      beforeMeeting: ["basics"],
      beforeWork: ["fall", "harness", "ladder"],
      additional: ["anchor", "rescue", "scaffold"],
    });

    // All seven remain required of the worker.
    const required = await getMyRequiredLearning.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );
    expect(required.total).toBe(7);
  });

  test("completed lessons disappear; unrelated lessons never appear",
    async () => {
      await seedSiteWorker();
      for (const id of ["g1", "g2", "other"]) await seedLearning(ORG_A, id);
      await seedRequirement(ORG_A, "r1", {
        requiredLearningIds: ["g1", "g2"],
        activityId: "activity-1",
        learningSettings: {g1: S_GATE, g2: S_GATE},
      });
      await seedRequirement(ORG_A, "unrelated", {
        requiredLearningIds: ["other"],
        activityId: "activity-elsewhere",
        learningSettings: {other: S_ON},
      });
      await seedCompleted(ORG_A, "worker-1", "g1");

      const result = await getMyTodaysSafetyReadiness.run(
        callRequest("worker-1", {organizationId: ORG_A})
      );

      expect(readinessIds(result)).toEqual({
        beforeMeeting: ["g2"],
        beforeWork: [],
        additional: [],
      });
    });
});

describe("required video and quiz components (scenarios A-E)", () => {
  const PASS = [{questionId: "q1", optionId: "a"}];
  const FAIL = [{questionId: "q1", optionId: "b"}];

  /**
   * A worker, a required video `v1` (optionally with a quiz question and a
   * minimum watch time) and a started record.
   */
  async function setUp({
    withQuiz = true,
    setting = undefined,
    minimumWatchSeconds = undefined,
  } = {}) {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker");
    await seedLearning(ORG_A, "v1", {
      type: "video",
      contentReference: "https://www.youtube.com/watch?v=jfKfPfyJRdk",
      ...(minimumWatchSeconds !== undefined ? {minimumWatchSeconds} : {}),
    });
    await seedRequirement(ORG_A, "r1", {
      requiredLearningIds: ["v1"],
      ...(setting !== undefined ? {learningSettings: {v1: setting}} : {}),
    });
    if (withQuiz) await seedQuestion(ORG_A, "v1", "q1");
    await getMyRequiredLearning.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );
    await startLearning.run(
      callRequest("worker-1", {organizationId: ORG_A, learningId: "v1"})
    );
  }

  const complete = (data = {}) => completeLearning.run(
    callRequest("worker-1", {organizationId: ORG_A, learningId: "v1", ...data})
  );

  test("A: a required video without a quiz completes in one step", async () => {
    await setUp({withQuiz: false});
    const result = await complete();
    expect(result.status).toBe("completed");
    const record = await getRecord(ORG_A, "worker-1", "v1");
    expect(record.status).toBe("completed");
    expect(record.contentCompletedAt).toBeDefined();
    expect(record.completedAt).toBeDefined();
  });

  test("B: watching the video alone does not complete a required quiz " +
    "item; passing the quiz afterwards does", async () => {
    await setUp();
    const watched = await complete();
    expect(watched.status).toBe("inProgress");
    expect(watched.contentCompleted).toBe(true);
    expect(watched.quizOutstanding).toBe(true);
    let record = await getRecord(ORG_A, "worker-1", "v1");
    expect(record.status).toBe("inProgress");
    const watchedAt = record.contentCompletedAt;

    const failed = await complete({selectedAnswers: FAIL});
    expect(failed.status).toBe("inProgress");
    expect(failed.knowledgeCheckResult.passed).toBe(false);
    record = await getRecord(ORG_A, "worker-1", "v1");
    expect(record.status).toBe("inProgress");
    expect(record.knowledgeCheckResult).toBeUndefined();

    const passed = await complete({selectedAnswers: PASS});
    expect(passed.status).toBe("completed");
    record = await getRecord(ORG_A, "worker-1", "v1");
    expect(record.status).toBe("completed");
    expect(record.knowledgeCheckResult.passed).toBe(true);
    // The video step keeps its original time.
    expect(record.contentCompletedAt.isEqual(watchedAt)).toBe(true);
  });

  test("B: the quiz alone cannot complete it — the video's watch time " +
    "still applies", async () => {
    await setUp({minimumWatchSeconds: 600});
    await expect(complete({selectedAnswers: PASS}))
      .rejects.toThrow(/Keep this item open/);
    const record = await getRecord(ORG_A, "worker-1", "v1");
    expect(record.status).toBe("inProgress");
    expect(record.contentCompletedAt).toBeUndefined();
    expect(record.knowledgeCheckResult).toBeUndefined();
  });

  test("B: an explicit quizRequired:true setting behaves the same",
    async () => {
      await setUp({
        setting: {gatesAttendance: false, requiredBeforeWork: false,
          quizRequired: true},
      });
      expect((await complete()).status).toBe("inProgress");
    });

  test("C: with an optional quiz, the required video completes without " +
    "it, and the quiz can still be taken afterwards", async () => {
    await setUp({
      setting: {gatesAttendance: false, requiredBeforeWork: false,
        quizRequired: false},
    });
    const done = await complete();
    expect(done.status).toBe("completed");
    let record = await getRecord(ORG_A, "worker-1", "v1");
    const completedAt = record.completedAt;

    const quiz = await complete({selectedAnswers: FAIL});
    expect(quiz.status).toBe("completed");
    expect(quiz.knowledgeCheckResult.passed).toBe(false);
    record = await getRecord(ORG_A, "worker-1", "v1");
    expect(record.status).toBe("completed");
    expect(record.completedAt.isEqual(completedAt)).toBe(true);
    expect(record.knowledgeCheckResult.passed).toBe(false);

    // A completed item with an optional quiz still can't be "completed"
    // again without answers.
    await expect(complete()).rejects.toThrow(/current state/);
  });

  test("C: a failed optional quiz submitted with the video still " +
    "completes the video requirement", async () => {
    await setUp({
      setting: {gatesAttendance: false, requiredBeforeWork: false,
        quizRequired: false},
    });
    const result = await complete({selectedAnswers: FAIL});
    expect(result.status).toBe("completed");
  });

  test("the quiz stays mandatory while ANY applicable requirement needs " +
    "it", async () => {
    await setUp({
      setting: {gatesAttendance: false, requiredBeforeWork: false,
        quizRequired: false},
    });
    await seedRequirement(ORG_A, "r2", {requiredLearningIds: ["v1"]});
    expect((await complete()).status).toBe("inProgress");
  });

  test("a mandatory quiz cannot be re-taken once completed", async () => {
    await setUp();
    await complete({selectedAnswers: PASS});
    await expect(complete({selectedAnswers: FAIL}))
      .rejects.toThrow(/current state/);
  });

  test("repeated calls never create a second record", async () => {
    await setUp({withQuiz: false});
    await complete();
    await expect(complete()).rejects.toThrow(/current state/);
    const records = await db
      .collection(`organizations/${ORG_A}/worker_learning_records`)
      .where("learningId", "==", "v1")
      .get();
    expect(records.size).toBe(1);
  });

  test("D: an optional video (no requirement) cannot be completed, but " +
    "its quiz can be practised without recording anything", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker");
    await seedLearning(ORG_A, "v1", {type: "video"});
    await seedQuestion(ORG_A, "v1", "q1");

    await expect(complete()).rejects.toThrow(/not currently required/);
    const result = await practiceKnowledgeCheck.run(
      callRequest("worker-1", {organizationId: ORG_A, learningId: "v1",
        selectedAnswers: PASS})
    );
    expect(result.knowledgeCheckResult).toEqual({
      passed: true, score: 1, totalQuestions: 1,
    });
    expect(JSON.stringify(result)).not.toContain("correctOptionId");
    expect(await getRecord(ORG_A, "worker-1", "v1")).toBeNull();
  });

  test("a practice attempt is refused for required training", async () => {
    await setUp();
    await expect(
      practiceKnowledgeCheck.run(
        callRequest("worker-1", {organizationId: ORG_A, learningId: "v1",
          selectedAnswers: PASS})
      )
    ).rejects.toThrow(/required training/);
  });

  test("E: deactivating a video removes the obligation but keeps the " +
    "completion record", async () => {
    await setUp({withQuiz: false});
    await complete();
    await db.doc(`organizations/${ORG_A}/safety_learning/v1`)
      .update({status: "inactive"});

    const required = await resolveRequiredLearningForScope(ORG_A, SCOPE);
    expect(ids(required)).not.toContain("v1");
    await expect(complete()).rejects.toThrow(/not currently required/);
    const record = await getRecord(ORG_A, "worker-1", "v1");
    expect(record.status).toBe("completed");
  });

  test("readiness reports each item's quiz and video progress", async () => {
    await setUp();
    await complete();
    const readiness = await getMyTodaysSafetyReadiness.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );
    const item = [
      ...readiness.beforeMeeting,
      ...readiness.beforeWork,
      ...readiness.additional,
    ].find((i) => i.learningId === "v1");
    expect(item).toMatchObject({
      questionCount: 1,
      quizRequired: true,
      contentCompleted: true,
      status: "inProgress",
    });
  });

  test("a supervising Foreman sees video progress, never quiz results",
    async () => {
      await setUp();
      await db.doc(`users/worker-1/memberships/${ORG_A}`)
        .update({siteIds: ["site-1"]});
      await complete();
      await seedProfile("foreman-1");
      await seedMembership("foreman-1", ORG_A, "foreman", ["site-1"]);

      const result = await getCrewLearningRecords.run(
        callRequest("foreman-1", {organizationId: ORG_A,
          workerUids: ["worker-1"]})
      );
      expect(result.records).toHaveLength(1);
      expect(result.records[0].contentCompleted).toBe(true);
      expect(result.records[0].status).toBe("inProgress");
      expect(JSON.stringify(result)).not.toContain("knowledgeCheckResult");
    });
});

describe("general learning — quizzes of lessons not required of the " +
  "caller", () => {
  const PASS = [{questionId: "q1", optionId: "a"}];

  /** Every learning record in [organizationId], by document id. */
  async function allRecords(organizationId) {
    const snapshot = await db
      .collection(`organizations/${organizationId}/worker_learning_records`)
      .get();
    return Object.fromEntries(snapshot.docs.map((d) => [d.id, d.data()]));
  }

  const practise = (uid, learningId, organizationId = ORG_A) =>
    practiceKnowledgeCheck.run(
      callRequest(uid, {organizationId, learningId, selectedAnswers: PASS})
    );

  for (const role of ["worker", "foreman"]) {
    test(`a ${role} with no applicable requirement can open and practise ` +
      "an active video's quiz; nothing is written", async () => {
      await seedProfile("learner-1");
      await seedMembership("learner-1", ORG_A, role, ["site-1"]);
      await seedLearning(ORG_A, "v1", {type: "video"});
      await seedQuestion(ORG_A, "v1", "q1");

      const quiz = await getKnowledgeCheckQuestions.run(
        callRequest("learner-1", {organizationId: ORG_A, learningId: "v1"})
      );
      expect(quiz.required).toBe(false);
      expect(quiz.quizRequired).toBe(false);
      expect(quiz.questions).toHaveLength(1);
      expect(JSON.stringify(quiz)).not.toContain("correctOptionId");

      const result = await practise("learner-1", "v1");
      expect(result.knowledgeCheckResult.passed).toBe(true);
      expect(JSON.stringify(result)).not.toContain("correctOptionId");
      expect(await allRecords(ORG_A)).toEqual({});
    });
  }

  test("a stale record (requirement deactivated) reads as not required; " +
    "practising changes neither it nor readiness, and it still cannot be " +
    "completed", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker");
    await seedLearning(ORG_A, "v1", {type: "video"});
    await seedQuestion(ORG_A, "v1", "q1");
    await seedRequirement(ORG_A, "r1", {requiredLearningIds: ["v1"]});
    await getMyRequiredLearning.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );
    await startLearning.run(
      callRequest("worker-1", {organizationId: ORG_A, learningId: "v1"})
    );
    await db.doc(`organizations/${ORG_A}/safety_requirements/r1`)
      .update({status: "inactive"});
    const before = await allRecords(ORG_A);

    const quiz = await getKnowledgeCheckQuestions.run(
      callRequest("worker-1", {organizationId: ORG_A, learningId: "v1"})
    );
    expect(quiz.required).toBe(false);
    await practise("worker-1", "v1");

    expect(await allRecords(ORG_A)).toEqual(before);
    const readiness = await getMyTodaysSafetyReadiness.run(
      callRequest("worker-1", {organizationId: ORG_A})
    );
    const listed = [
      ...readiness.beforeMeeting,
      ...readiness.beforeWork,
      ...readiness.additional,
    ].map((item) => item.learningId);
    expect(listed).not.toContain("v1");
    await expect(
      completeLearning.run(callRequest("worker-1", {
        organizationId: ORG_A, learningId: "v1", selectedAnswers: PASS,
      }))
    ).rejects.toThrow(/not currently required/);
    expect(await allRecords(ORG_A)).toEqual(before);
  });

  test("practising after a completed, no-longer-required lesson leaves " +
    "the completion evidence untouched", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker");
    await seedLearning(ORG_A, "v1", {type: "video"});
    await seedQuestion(ORG_A, "v1", "q1");
    await seedCompleted(ORG_A, "worker-1", "v1");
    const before = await allRecords(ORG_A);

    await practise("worker-1", "v1");
    expect(await allRecords(ORG_A)).toEqual(before);
  });

  test("another organization's lesson cannot be reached by guessing its " +
    "id", async () => {
    await seedProfile("outsider");
    await seedMembership("outsider", ORG_B, "worker");
    await seedLearning(ORG_A, "v1", {type: "video"});
    await seedQuestion(ORG_A, "v1", "q1");

    // Naming the other organization: not a member there.
    await expect(
      getKnowledgeCheckQuestions.run(
        callRequest("outsider", {organizationId: ORG_A, learningId: "v1"})
      )
    ).rejects.toThrow(/permission/);
    await expect(practise("outsider", "v1")).rejects.toThrow(/permission/);
    // Naming their own organization: the id does not exist there.
    await expect(
      getKnowledgeCheckQuestions.run(
        callRequest("outsider", {organizationId: ORG_B, learningId: "v1"})
      )
    ).rejects.toThrow(/not available/);
    await expect(practise("outsider", "v1", ORG_B))
      .rejects.toThrow(/not available/);
  });

  test("a video required only for a project the worker is not on is " +
    "general learning for them: its quiz opens and practises", async () => {
    await seedSiteWorker("worker-1");
    await seedLearning(ORG_A, "v1", {type: "video"});
    await seedQuestion(ORG_A, "v1", "q1");
    await seedRequirement(ORG_A, "r-future", {
      requiredLearningIds: ["v1"],
      projectId: "project-future",
    });

    const quiz = await getKnowledgeCheckQuestions.run(
      callRequest("worker-1", {organizationId: ORG_A, learningId: "v1"})
    );
    expect(quiz.required).toBe(false);
    expect(quiz.questions).toHaveLength(1);
    const result = await practise("worker-1", "v1");
    expect(result.knowledgeCheckResult.passed).toBe(true);
    expect(await allRecords(ORG_A)).toEqual({});
  });

  test("an inactive video's quiz cannot be opened or practised", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker");
    await seedLearning(ORG_A, "v1", {type: "video", status: "inactive"});
    await seedQuestion(ORG_A, "v1", "q1");

    await expect(
      getKnowledgeCheckQuestions.run(
        callRequest("worker-1", {organizationId: ORG_A, learningId: "v1"})
      )
    ).rejects.toThrow(/not available/);
    await expect(practise("worker-1", "v1")).rejects.toThrow(/not available/);
  });

  test("a suspended learner is refused", async () => {
    await seedProfile("worker-1", {accountStatus: "suspended"});
    await seedMembership("worker-1", ORG_A, "worker");
    await seedLearning(ORG_A, "v1", {type: "video"});
    await seedQuestion(ORG_A, "v1", "q1");

    await expect(practise("worker-1", "v1")).rejects.toThrow(/permission/);
  });

  test("practising a lesson with no quiz is refused, not graded", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker");
    await seedLearning(ORG_A, "v1", {type: "video"});

    await expect(practise("worker-1", "v1")).rejects.toThrow(/has no quiz/);
  });
});
