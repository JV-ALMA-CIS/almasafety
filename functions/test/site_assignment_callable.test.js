/**
 * Business-logic tests for `site_assignment_callable.ts` —
 * `assignWorkerToSite`/`removeWorkerFromSite`.
 *
 * PHASE 3 (authorization matrix): covers both the pre-existing Admin/Site
 * Manager unrestricted authority (any membership, any site in the
 * organization) and the new Foreman-scoped authority (Worker-role targets
 * only, confined to the Foreman's own siteIds).
 *
 * Mirrors `organization_callable.test.js`'s shape: invokes each callable's
 * own exported handler via `.run(request)` against a running Firestore
 * emulator.
 *
 * Requires the Firestore emulator — see `npm run test:callables`.
 */

const {initializeApp, getApps, deleteApp} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");

const PROJECT_ID = "jva-safety-rules-test";
const ORG_A = "org-alpha";

let app;
let db;
let assignWorkerToSite;
let removeWorkerFromSite;

beforeAll(() => {
  process.env.GCLOUD_PROJECT = PROJECT_ID;
  if (!process.env.FIRESTORE_EMULATOR_HOST) {
    process.env.FIRESTORE_EMULATOR_HOST = "127.0.0.1:8080";
  }

  app = getApps()[0] ?? initializeApp({projectId: PROJECT_ID});
  db = getFirestore(app);

  ({assignWorkerToSite, removeWorkerFromSite} =
    require("../lib/site_assignment_callable"));
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

async function seedSite(organizationId, id, overrides = {}) {
  await db.doc(`organizations/${organizationId}/sites/${id}`).set({
    organizationId,
    projectId: "project-1",
    name: `Site ${id}`,
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

async function getMembership(uid, organizationId) {
  const snapshot = await db.doc(
    `users/${uid}/memberships/${organizationId}`
  ).get();
  return snapshot.data();
}

beforeEach(async () => {
  await clearFirestore();
});

describe("assignWorkerToSite (Admin/Site Manager — unrestricted)", () => {
  test("a Site Manager assigns a Worker to a site in their organization",
    async () => {
      await seedProfile("sm-1");
      await seedMembership("sm-1", ORG_A, "siteManager");
      await seedProfile("worker-1");
      await seedMembership("worker-1", ORG_A, "worker");
      await seedSite(ORG_A, "site-1");

      await assignWorkerToSite.run(
        callRequest("sm-1", {
          organizationId: ORG_A, uid: "worker-1", siteId: "site-1",
        })
      );

      const membership = await getMembership("worker-1", ORG_A);
      expect(membership.siteIds).toContain("site-1");
    });

  test("a Site Manager assigns a FOREMAN to a site — this is how a " +
    "Foreman is placed; there is no separate callable for it",
  async () => {
    await seedProfile("sm-1");
    await seedMembership("sm-1", ORG_A, "siteManager");
    await seedProfile("foreman-1");
    await seedMembership("foreman-1", ORG_A, "foreman");
    await seedSite(ORG_A, "site-1");

    await assignWorkerToSite.run(
      callRequest("sm-1", {
        organizationId: ORG_A, uid: "foreman-1", siteId: "site-1",
      })
    );

    const membership = await getMembership("foreman-1", ORG_A);
    expect(membership.siteIds).toContain("site-1");
  });

  test("an Admin assigns a Worker to a site in any organization",
    async () => {
      await seedProfile("admin-1", {platformRole: "admin"});
      await seedProfile("worker-1");
      await seedMembership("worker-1", ORG_A, "worker");
      await seedSite(ORG_A, "site-1");

      await assignWorkerToSite.run(
        callRequest("admin-1", {
          organizationId: ORG_A, uid: "worker-1", siteId: "site-1",
        })
      );

      const membership = await getMembership("worker-1", ORG_A);
      expect(membership.siteIds).toContain("site-1");
    });
});

describe("assignWorkerToSite (Foreman — scoped)", () => {
  test("a Foreman assigns a Worker to the Foreman's OWN site", async () => {
    await seedProfile("foreman-1");
    await seedMembership("foreman-1", ORG_A, "foreman", ["site-1"]);
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker");
    await seedSite(ORG_A, "site-1");

    await assignWorkerToSite.run(
      callRequest("foreman-1", {
        organizationId: ORG_A, uid: "worker-1", siteId: "site-1",
      })
    );

    const membership = await getMembership("worker-1", ORG_A);
    expect(membership.siteIds).toContain("site-1");
  });

  test("a Foreman is refused when assigning a Worker to a DIFFERENT site " +
    "than their own", async () => {
    await seedProfile("foreman-1");
    await seedMembership("foreman-1", ORG_A, "foreman", ["site-1"]);
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker");
    await seedSite(ORG_A, "site-2");

    await expect(
      assignWorkerToSite.run(
        callRequest("foreman-1", {
          organizationId: ORG_A, uid: "worker-1", siteId: "site-2",
        })
      )
    ).rejects.toThrow(/permission/);
  });

  test("a Foreman is refused when assigning a FOREMAN-role target — only " +
    "Worker-role targets are within a Foreman's authority", async () => {
    await seedProfile("foreman-1");
    await seedMembership("foreman-1", ORG_A, "foreman", ["site-1"]);
    await seedProfile("foreman-2");
    await seedMembership("foreman-2", ORG_A, "foreman");
    await seedSite(ORG_A, "site-1");

    await expect(
      assignWorkerToSite.run(
        callRequest("foreman-1", {
          organizationId: ORG_A, uid: "foreman-2", siteId: "site-1",
        })
      )
    ).rejects.toThrow(/permission/);
  });

  test("a Foreman with no siteIds at all is refused", async () => {
    await seedProfile("foreman-1");
    await seedMembership("foreman-1", ORG_A, "foreman", []);
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker");
    await seedSite(ORG_A, "site-1");

    await expect(
      assignWorkerToSite.run(
        callRequest("foreman-1", {
          organizationId: ORG_A, uid: "worker-1", siteId: "site-1",
        })
      )
    ).rejects.toThrow(/permission/);
  });
});

describe("assignWorkerToSite (Worker — no authority)", () => {
  test("a Worker cannot call this at all", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker", ["site-1"]);
    await seedProfile("worker-2");
    await seedMembership("worker-2", ORG_A, "worker");
    await seedSite(ORG_A, "site-1");

    await expect(
      assignWorkerToSite.run(
        callRequest("worker-1", {
          organizationId: ORG_A, uid: "worker-2", siteId: "site-1",
        })
      )
    ).rejects.toThrow(/permission/);
  });
});

describe("removeWorkerFromSite (Foreman — scoped)", () => {
  test("a Foreman removes a Worker from the Foreman's own site",
    async () => {
      await seedProfile("foreman-1");
      await seedMembership("foreman-1", ORG_A, "foreman", ["site-1"]);
      await seedProfile("worker-1");
      await seedMembership("worker-1", ORG_A, "worker", ["site-1"]);

      await removeWorkerFromSite.run(
        callRequest("foreman-1", {
          organizationId: ORG_A, uid: "worker-1", siteId: "site-1",
        })
      );

      const membership = await getMembership("worker-1", ORG_A);
      expect(membership.siteIds).not.toContain("site-1");
    });

  test("a Foreman is refused when removing a Worker from a site that is " +
    "not their own", async () => {
    await seedProfile("foreman-1");
    await seedMembership("foreman-1", ORG_A, "foreman", ["site-1"]);
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker", ["site-2"]);

    await expect(
      removeWorkerFromSite.run(
        callRequest("foreman-1", {
          organizationId: ORG_A, uid: "worker-1", siteId: "site-2",
        })
      )
    ).rejects.toThrow(/permission/);
  });

  test("a Foreman is refused when removing a SITE MANAGER-role target",
    async () => {
      await seedProfile("foreman-1");
      await seedMembership("foreman-1", ORG_A, "foreman", ["site-1"]);
      await seedProfile("sm-2");
      await seedMembership("sm-2", ORG_A, "siteManager", ["site-1"]);

      await expect(
        removeWorkerFromSite.run(
          callRequest("foreman-1", {
            organizationId: ORG_A, uid: "sm-2", siteId: "site-1",
          })
        )
      ).rejects.toThrow(/permission/);
    });

  test("a Site Manager still removes any membership at any site — this " +
    "is additive for Foreman, not a narrowing of Site Manager's authority",
  async () => {
    await seedProfile("sm-1");
    await seedMembership("sm-1", ORG_A, "siteManager");
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker", ["site-1"]);

    await removeWorkerFromSite.run(
      callRequest("sm-1", {
        organizationId: ORG_A, uid: "worker-1", siteId: "site-1",
      })
    );

    const membership = await getMembership("worker-1", ORG_A);
    expect(membership.siteIds).not.toContain("site-1");
  });
});
