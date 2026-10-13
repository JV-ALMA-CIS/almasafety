/**
 * Business-logic tests for `getCrewLearningRecords` in
 * `worker_learning_callable.ts` — the callable that replaced
 * `SafetyComplianceRepository`'s direct `worker_learning_records` read,
 * which `firestore.rules` refuses outright for a Foreman caller (see that
 * callable's own doc comment).
 *
 * Mirrors `worker_learning_callable.test.js`'s shape: invokes the exported
 * handler via `.run(request)` against a running Firestore emulator.
 *
 * Requires the Firestore emulator — see `npm run test:callables`.
 */

const {initializeApp, getApps, deleteApp} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");

const PROJECT_ID = "jva-safety-rules-test";
const ORG_A = "org-alpha";
const ORG_B = "org-beta";

let app;
let db;
let getCrewLearningRecords;

beforeAll(() => {
  process.env.GCLOUD_PROJECT = PROJECT_ID;
  if (!process.env.FIRESTORE_EMULATOR_HOST) {
    process.env.FIRESTORE_EMULATOR_HOST = "127.0.0.1:8080";
  }

  app = getApps()[0] ?? initializeApp({projectId: PROJECT_ID});
  db = getFirestore(app);

  ({getCrewLearningRecords} = require("../lib/worker_learning_callable"));
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

async function seedRecord(
  organizationId, workerUid, learningId, overrides = {}
) {
  await db
    .doc(
      `organizations/${organizationId}/worker_learning_records/` +
        `${workerUid}_${learningId}`
    )
    .set({
      workerUid,
      organizationId,
      learningId,
      status: "completed",
      assignedAt: new Date(),
      completedAt: new Date(),
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

beforeEach(async () => {
  await clearFirestore();
});

describe("getCrewLearningRecords authorization", () => {
  test("an unauthenticated caller is refused", async () => {
    await expect(
      getCrewLearningRecords.run(
        callRequest(null, {organizationId: ORG_A, workerUids: ["worker-1"]})
      )
    ).rejects.toThrow();
  });

  test("a worker (not a reviewer role) is refused", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker");

    await expect(
      getCrewLearningRecords.run(
        callRequest("worker-1", {
          organizationId: ORG_A,
          workerUids: ["worker-1"],
        })
      )
    ).rejects.toThrow();
  });

  test("a siteManager of a DIFFERENT organization is refused", async () => {
    await seedProfile("sm-1");
    await seedMembership("sm-1", ORG_B, "siteManager");

    await expect(
      getCrewLearningRecords.run(
        callRequest("sm-1", {organizationId: ORG_A, workerUids: ["worker-1"]})
      )
    ).rejects.toThrow();
  });

  test("an Admin may request records regardless of organization membership",
    async () => {
      await seedProfile("admin-1", {platformRole: "admin"});
      await seedProfile("worker-1");
      await seedRecord(ORG_A, "worker-1", "l1");

      const result = await getCrewLearningRecords.run(
        callRequest("admin-1", {
          organizationId: ORG_A,
          workerUids: ["worker-1"],
        })
      );

      expect(result.records).toHaveLength(1);
      expect(result.records[0].workerUid).toBe("worker-1");
    });
});

describe("getCrewLearningRecords — siteManager scope", () => {
  test("a siteManager sees every requested worker's records, regardless " +
    "of site", async () => {
    await seedProfile("sm-1");
    await seedMembership("sm-1", ORG_A, "siteManager");
    await seedProfile("worker-1");
    await seedProfile("worker-2");
    await seedRecord(ORG_A, "worker-1", "l1");
    await seedRecord(ORG_A, "worker-2", "l1");

    const result = await getCrewLearningRecords.run(
      callRequest("sm-1", {
        organizationId: ORG_A,
        workerUids: ["worker-1", "worker-2"],
      })
    );

    const uids = result.records.map((r) => r.workerUid).sort();
    expect(uids).toEqual(["worker-1", "worker-2"]);
  });
});

describe("getCrewLearningRecords — foreman scope", () => {
  test("a foreman sees records for a worker who shares one of their own " +
    "sites", async () => {
    await seedProfile("foreman-1");
    await seedMembership("foreman-1", ORG_A, "foreman", ["site-1"]);
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker", ["site-1"]);
    await seedRecord(ORG_A, "worker-1", "l1");

    const result = await getCrewLearningRecords.run(
      callRequest("foreman-1", {
        organizationId: ORG_A,
        workerUids: ["worker-1"],
      })
    );

    expect(result.records).toHaveLength(1);
    expect(result.records[0].workerUid).toBe("worker-1");
  });

  test("a foreman's request for a worker OUTSIDE their own sites returns " +
    "that worker silently omitted, not an error", async () => {
    await seedProfile("foreman-1");
    await seedMembership("foreman-1", ORG_A, "foreman", ["site-1"]);
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker", ["site-1"]);
    await seedProfile("worker-2");
    await seedMembership("worker-2", ORG_A, "worker", ["site-2"]);
    await seedRecord(ORG_A, "worker-1", "l1");
    await seedRecord(ORG_A, "worker-2", "l1");

    const result = await getCrewLearningRecords.run(
      callRequest("foreman-1", {
        organizationId: ORG_A,
        workerUids: ["worker-1", "worker-2"],
      })
    );

    const uids = result.records.map((r) => r.workerUid);
    expect(uids).toEqual(["worker-1"]);
  });

  test("a foreman requesting only out-of-crew workers gets an empty " +
    "result, not a thrown error", async () => {
    await seedProfile("foreman-1");
    await seedMembership("foreman-1", ORG_A, "foreman", ["site-1"]);
    await seedProfile("worker-2");
    await seedMembership("worker-2", ORG_A, "worker", ["site-2"]);
    await seedRecord(ORG_A, "worker-2", "l1");

    const result = await getCrewLearningRecords.run(
      callRequest("foreman-1", {
        organizationId: ORG_A,
        workerUids: ["worker-2"],
      })
    );

    expect(result.records).toEqual([]);
  });
});

describe("getCrewLearningRecords argument validation", () => {
  test("an empty workerUids array is refused", async () => {
    await seedProfile("sm-1");
    await seedMembership("sm-1", ORG_A, "siteManager");

    await expect(
      getCrewLearningRecords.run(
        callRequest("sm-1", {organizationId: ORG_A, workerUids: []})
      )
    ).rejects.toThrow();
  });

  test("a missing organizationId is refused", async () => {
    await seedProfile("sm-1");
    await seedMembership("sm-1", ORG_A, "siteManager");

    await expect(
      getCrewLearningRecords.run(
        callRequest("sm-1", {workerUids: ["worker-1"]})
      )
    ).rejects.toThrow();
  });
});
