/**
 * Business-logic tests for `safety_meeting_point_callable.ts` —
 * `createSafetyMeetingPoint`/`updateSafetyMeetingPoint`/
 * `activateSafetyMeetingPoint`/`deactivateSafetyMeetingPoint`.
 *
 * This is the callable-level coverage the rules suite structurally cannot
 * reach (rules only prove client writes are denied outright; the Admin-SDK
 * business logic behind the callables is a separate authorization surface).
 * There was previously NO test file for this callable at all — the gap
 * that let a real authorization regression (this callable briefly using
 * `requireAdmin` instead of `requireOrganizationScopedManager`, wrongly
 * excluding a Site Manager from managing their own organization's meeting
 * points) ship undetected. See PROJECT_CONTEXT.md §12/§16: Safety Meeting
 * Points are field-level content a Site Manager prepares for their own
 * Foremen, NOT the same admin-only company-wide library shape as Safety
 * Learning.
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
const ORG_B = "org-beta";

let app;
let db;
let createSafetyMeetingPoint;
let updateSafetyMeetingPoint;
let activateSafetyMeetingPoint;
let deactivateSafetyMeetingPoint;

beforeAll(() => {
  process.env.GCLOUD_PROJECT = PROJECT_ID;
  if (!process.env.FIRESTORE_EMULATOR_HOST) {
    process.env.FIRESTORE_EMULATOR_HOST = "127.0.0.1:8080";
  }

  app = getApps()[0] ?? initializeApp({projectId: PROJECT_ID});
  db = getFirestore(app);

  ({
    createSafetyMeetingPoint,
    updateSafetyMeetingPoint,
    activateSafetyMeetingPoint,
    deactivateSafetyMeetingPoint,
  } = require("../lib/safety_meeting_point_callable"));
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

async function seedOrg(id, managedBy = []) {
  await db.doc(`organizations/${id}`).set({
    name: `Org ${id}`,
    code: `CODE-${id}`,
    status: "active",
    managedBy,
    createdAt: new Date(),
    updatedAt: new Date(),
  });
}

function callRequest(uid, data) {
  return {
    auth: {uid, token: {}},
    data,
    rawRequest: {},
  };
}

async function getPoint(organizationId, id) {
  const snapshot = await db.doc(
    `organizations/${organizationId}/safety_meeting_points/${id}`
  ).get();
  return snapshot.data();
}

beforeEach(async () => {
  await clearFirestore();
});

describe("createSafetyMeetingPoint", () => {
  test("a siteManager creates a meeting point in an organization they " +
    "manage (via managedBy)", async () => {
    await seedProfile("sm-1", {platformRole: "siteManager"});
    await seedOrg(ORG_A, ["sm-1"]);

    const result = await createSafetyMeetingPoint.run(
      callRequest("sm-1", {
        organizationId: ORG_A,
        title: "Working at Height",
        category: "height",
      })
    );

    expect(result.organizationId).toBe(ORG_A);
    const point = await getPoint(ORG_A, result.id);
    expect(point.title).toBe("Working at Height");
    expect(point.category).toBe("height");
    expect(point.status).toBe("active");
  });

  test("a siteManager creates a meeting point via an active siteManager " +
    "membership, not just managedBy", async () => {
    await seedProfile("sm-1", {platformRole: "siteManager"});
    await seedOrg(ORG_A);
    await seedMembership("sm-1", ORG_A, "siteManager");

    const result = await createSafetyMeetingPoint.run(
      callRequest("sm-1", {
        organizationId: ORG_A,
        title: "Fire Safety",
        category: "fire",
      })
    );

    expect(result.organizationId).toBe(ORG_A);
  });

  test("a siteManager cannot create a meeting point in an organization " +
    "they do not manage", async () => {
    await seedProfile("sm-1", {platformRole: "siteManager"});
    await seedOrg(ORG_A, ["sm-1"]);
    await seedOrg(ORG_B, ["someone-else"]);

    await expect(
      createSafetyMeetingPoint.run(
        callRequest("sm-1", {
          organizationId: ORG_B,
          title: "Nope",
          category: "fire",
        })
      )
    ).rejects.toThrow();
  });

  test("admin creates a meeting point in any organization, managed or " +
    "not", async () => {
    await seedProfile("admin-1", {platformRole: "admin"});
    await seedOrg(ORG_A, ["someone-else"]);

    const result = await createSafetyMeetingPoint.run(
      callRequest("admin-1", {
        organizationId: ORG_A,
        title: "Admin-created point",
        category: "chemical",
      })
    );

    expect(result.organizationId).toBe(ORG_A);
  });

  test("a foreman is refused", async () => {
    await seedProfile("fm-1");
    await seedOrg(ORG_A);
    await seedMembership("fm-1", ORG_A, "foreman", ["site-1"]);

    await expect(
      createSafetyMeetingPoint.run(
        callRequest("fm-1", {
          organizationId: ORG_A,
          title: "Nope",
          category: "fire",
        })
      )
    ).rejects.toThrow();
  });

  test("a worker is refused", async () => {
    await seedProfile("worker-1");
    await seedOrg(ORG_A);
    await seedMembership("worker-1", ORG_A, "worker", ["site-1"]);

    await expect(
      createSafetyMeetingPoint.run(
        callRequest("worker-1", {
          organizationId: ORG_A,
          title: "Nope",
          category: "fire",
        })
      )
    ).rejects.toThrow();
  });
});

describe("updateSafetyMeetingPoint", () => {
  test("a siteManager of the organization can update a meeting point's " +
    "editable fields", async () => {
    await seedProfile("sm-1", {platformRole: "siteManager"});
    await seedOrg(ORG_A, ["sm-1"]);
    const created = await createSafetyMeetingPoint.run(
      callRequest("sm-1", {
        organizationId: ORG_A,
        title: "Original",
        category: "fire",
      })
    );

    await updateSafetyMeetingPoint.run(
      callRequest("sm-1", {
        organizationId: ORG_A,
        id: created.id,
        title: "Renamed",
      })
    );

    const point = await getPoint(ORG_A, created.id);
    expect(point.title).toBe("Renamed");
  });

  test("a siteManager of a DIFFERENT organization cannot update it",
    async () => {
      await seedProfile("sm-1", {platformRole: "siteManager"});
      await seedProfile("sm-2", {platformRole: "siteManager"});
      await seedOrg(ORG_A, ["sm-1"]);
      await seedOrg(ORG_B, ["sm-2"]);
      const created = await createSafetyMeetingPoint.run(
        callRequest("sm-1", {
          organizationId: ORG_A,
          title: "Original",
          category: "fire",
        })
      );

      await expect(
        updateSafetyMeetingPoint.run(
          callRequest("sm-2", {
            organizationId: ORG_A,
            id: created.id,
            title: "Hijacked",
          })
        )
      ).rejects.toThrow();

      const point = await getPoint(ORG_A, created.id);
      expect(point.title).toBe("Original");
    });
});

describe("activateSafetyMeetingPoint / deactivateSafetyMeetingPoint", () => {
  test("a siteManager can deactivate then reactivate a meeting point in " +
    "their own organization", async () => {
    await seedProfile("sm-1", {platformRole: "siteManager"});
    await seedOrg(ORG_A, ["sm-1"]);
    const created = await createSafetyMeetingPoint.run(
      callRequest("sm-1", {
        organizationId: ORG_A,
        title: "Point",
        category: "fire",
      })
    );

    await deactivateSafetyMeetingPoint.run(
      callRequest("sm-1", {organizationId: ORG_A, id: created.id})
    );
    expect((await getPoint(ORG_A, created.id)).status).toBe("inactive");

    await activateSafetyMeetingPoint.run(
      callRequest("sm-1", {organizationId: ORG_A, id: created.id})
    );
    expect((await getPoint(ORG_A, created.id)).status).toBe("active");
  });

  test("a worker cannot deactivate a meeting point", async () => {
    await seedProfile("sm-1", {platformRole: "siteManager"});
    await seedProfile("worker-1");
    await seedOrg(ORG_A, ["sm-1"]);
    await seedMembership("worker-1", ORG_A, "worker", ["site-1"]);
    const created = await createSafetyMeetingPoint.run(
      callRequest("sm-1", {
        organizationId: ORG_A,
        title: "Point",
        category: "fire",
      })
    );

    await expect(
      deactivateSafetyMeetingPoint.run(
        callRequest("worker-1", {organizationId: ORG_A, id: created.id})
      )
    ).rejects.toThrow();

    expect((await getPoint(ORG_A, created.id)).status).toBe("active");
  });
});
