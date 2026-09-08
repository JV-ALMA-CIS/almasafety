/**
 * Business-logic tests for `activity_assignment_callable.ts` —
 * `assignWorkerToActivity`/`removeWorkerFromActivity`.
 *
 * PHASE 3 (authorization matrix): covers both the pre-existing Admin/Site
 * Manager unrestricted authority and the new Foreman-scoped authority
 * (Worker-role targets only, confined to the Foreman's own siteIds).
 *
 * Mirrors `site_assignment_callable.test.js`'s shape. Requires the
 * Firestore emulator — see `npm run test:callables`.
 */

const {initializeApp, getApps, deleteApp} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");

const PROJECT_ID = "jva-safety-rules-test";
const ORG_A = "org-alpha";

let app;
let db;
let assignWorkerToActivity;
let removeWorkerFromActivity;

beforeAll(() => {
  process.env.GCLOUD_PROJECT = PROJECT_ID;
  if (!process.env.FIRESTORE_EMULATOR_HOST) {
    process.env.FIRESTORE_EMULATOR_HOST = "127.0.0.1:8080";
  }

  app = getApps()[0] ?? initializeApp({projectId: PROJECT_ID});
  db = getFirestore(app);

  ({assignWorkerToActivity, removeWorkerFromActivity} =
    require("../lib/activity_assignment_callable"));
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

async function seedMembership(
  uid, organizationId, role, siteIds = [], overrides = {}
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

function callRequest(uid, data) {
  return {
    auth: {uid, token: {}},
    data,
    rawRequest: {},
  };
}

async function getAssignment(organizationId, activityId, uid) {
  const path = `organizations/${organizationId}/activities/` +
    `${activityId}/assignments/${uid}`;
  const snapshot = await db.doc(path).get();
  return snapshot.exists ? snapshot.data() : null;
}

beforeEach(async () => {
  await clearFirestore();
});

describe("assignWorkerToActivity (Admin/Site Manager — unrestricted)", () => {
  test("a Site Manager assigns a Worker to an activity in their organization",
    async () => {
      await seedProfile("sm-1");
      await seedMembership("sm-1", ORG_A, "siteManager");
      await seedProfile("worker-1");
      await seedMembership("worker-1", ORG_A, "worker", ["site-1"]);
      await seedActivity(ORG_A, "activity-1", "site-1");

      await assignWorkerToActivity.run(
        callRequest("sm-1", {
          organizationId: ORG_A, uid: "worker-1", activityId: "activity-1",
        })
      );

      const assignment = await getAssignment(ORG_A, "activity-1", "worker-1");
      expect(assignment).not.toBeNull();
    });
});

describe("assignWorkerToActivity (Foreman — scoped)", () => {
  test("a Foreman assigns a Worker to an activity at the Foreman's own site",
    async () => {
      await seedProfile("foreman-1");
      await seedMembership("foreman-1", ORG_A, "foreman", ["site-1"]);
      await seedProfile("worker-1");
      await seedMembership("worker-1", ORG_A, "worker", ["site-1"]);
      await seedActivity(ORG_A, "activity-1", "site-1");

      await assignWorkerToActivity.run(
        callRequest("foreman-1", {
          organizationId: ORG_A, uid: "worker-1", activityId: "activity-1",
        })
      );

      const assignment = await getAssignment(ORG_A, "activity-1", "worker-1");
      expect(assignment).not.toBeNull();
      expect(assignment.assignedBy).toBe("foreman-1");
    });

  test("a Foreman is refused when the activity's site is not their own",
    async () => {
      await seedProfile("foreman-1");
      await seedMembership("foreman-1", ORG_A, "foreman", ["site-1"]);
      await seedProfile("worker-1");
      await seedMembership("worker-1", ORG_A, "worker", ["site-2"]);
      await seedActivity(ORG_A, "activity-1", "site-2");

      await expect(
        assignWorkerToActivity.run(
          callRequest("foreman-1", {
            organizationId: ORG_A, uid: "worker-1", activityId: "activity-1",
          })
        )
      ).rejects.toThrow(/permission/);
    });

  test("a Foreman is refused when assigning a non-Worker (Foreman) target",
    async () => {
      await seedProfile("foreman-1");
      await seedMembership("foreman-1", ORG_A, "foreman", ["site-1"]);
      await seedProfile("foreman-2");
      await seedMembership("foreman-2", ORG_A, "foreman", ["site-1"]);
      await seedActivity(ORG_A, "activity-1", "site-1");

      await expect(
        assignWorkerToActivity.run(
          callRequest("foreman-1", {
            organizationId: ORG_A, uid: "foreman-2", activityId: "activity-1",
          })
        )
      ).rejects.toThrow(/permission/);
    });

  test("a Foreman cannot assign themselves", async () => {
    await seedProfile("foreman-1");
    await seedMembership("foreman-1", ORG_A, "foreman", ["site-1"]);
    await seedActivity(ORG_A, "activity-1", "site-1");

    await expect(
      assignWorkerToActivity.run(
        callRequest("foreman-1", {
          organizationId: ORG_A, uid: "foreman-1", activityId: "activity-1",
        })
      )
    ).rejects.toThrow(/cannot assign yourself/);
  });
});

describe("assignWorkerToActivity (Worker — no authority)", () => {
  test("a Worker cannot call this at all", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker", ["site-1"]);
    await seedProfile("worker-2");
    await seedMembership("worker-2", ORG_A, "worker", ["site-1"]);
    await seedActivity(ORG_A, "activity-1", "site-1");

    await expect(
      assignWorkerToActivity.run(
        callRequest("worker-1", {
          organizationId: ORG_A, uid: "worker-2", activityId: "activity-1",
        })
      )
    ).rejects.toThrow(/permission/);
  });
});

describe("removeWorkerFromActivity (Foreman — scoped)", () => {
  test("a Foreman removes a Worker from an activity at their own site",
    async () => {
      await seedProfile("foreman-1");
      await seedMembership("foreman-1", ORG_A, "foreman", ["site-1"]);
      await seedProfile("worker-1");
      await seedMembership("worker-1", ORG_A, "worker", ["site-1"]);
      await seedActivity(ORG_A, "activity-1", "site-1");
      await assignWorkerToActivity.run(
        callRequest("foreman-1", {
          organizationId: ORG_A, uid: "worker-1", activityId: "activity-1",
        })
      );

      await removeWorkerFromActivity.run(
        callRequest("foreman-1", {
          organizationId: ORG_A, uid: "worker-1", activityId: "activity-1",
        })
      );

      const assignment = await getAssignment(ORG_A, "activity-1", "worker-1");
      expect(assignment).toBeNull();
    });

  test("a Foreman is refused when removing from an activity at a site " +
    "that is not their own", async () => {
    await seedProfile("foreman-1");
    await seedMembership("foreman-1", ORG_A, "foreman", ["site-1"]);
    await seedProfile("sm-1");
    await seedMembership("sm-1", ORG_A, "siteManager");
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker", ["site-2"]);
    await seedActivity(ORG_A, "activity-1", "site-2");
    await assignWorkerToActivity.run(
      callRequest("sm-1", {
        organizationId: ORG_A, uid: "worker-1", activityId: "activity-1",
      })
    );

    await expect(
      removeWorkerFromActivity.run(
        callRequest("foreman-1", {
          organizationId: ORG_A, uid: "worker-1", activityId: "activity-1",
        })
      )
    ).rejects.toThrow(/permission/);
  });
});
