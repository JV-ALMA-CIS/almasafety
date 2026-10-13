/**
 * Business-logic tests for `safety_alert_callable.ts`, focused on who may
 * raise, acknowledge and resolve alerts: a Foreman at their OWN sites only,
 * a Site Manager anywhere in their organization, a Worker never.
 *
 * Run with `npm run test:callables` (Firestore emulator).
 */

const {initializeApp, getApps, deleteApp} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");

const PROJECT_ID = "jva-safety-rules-test";
const ORG = "org-alpha";

let app;
let db;
let createSafetyAlert;
let acknowledgeSafetyAlert;
let resolveSafetyAlert;

beforeAll(() => {
  process.env.GCLOUD_PROJECT = PROJECT_ID;
  if (!process.env.FIRESTORE_EMULATOR_HOST) {
    process.env.FIRESTORE_EMULATOR_HOST = "127.0.0.1:8080";
  }
  app = getApps()[0] ?? initializeApp({projectId: PROJECT_ID});
  db = getFirestore(app);
  ({
    createSafetyAlert,
    acknowledgeSafetyAlert,
    resolveSafetyAlert,
  } = require("../lib/safety_alert_callable"));
});

afterAll(async () => {
  if (app) await deleteApp(app);
});

async function clearFirestore() {
  const collections = await db.listCollections();
  await Promise.all(collections.map((c) => db.recursiveDelete(c)));
}

async function seedUser(uid, role, siteIds) {
  await db.doc(`users/${uid}`).set({uid, name: uid, accountStatus: "active"});
  await db.doc(`users/${uid}/memberships/${ORG}`).set({
    organizationId: ORG,
    role,
    siteIds,
    status: "active",
  });
}

async function seedAlert(id, siteId) {
  await db.doc(`organizations/${ORG}/safety_alerts/${id}`).set({
    organizationId: ORG,
    projectId: "project-1",
    siteId,
    title: "Strong winds",
    description: "Stop crane lifts",
    severity: "high",
    category: "weather",
    status: "active",
  });
}

function call(uid, data) {
  return {auth: {uid, token: {}}, data, rawRequest: {}};
}

function alertAt(siteId) {
  return {
    organizationId: ORG,
    projectId: "project-1",
    siteId,
    title: "Strong winds",
    description: "Stop crane lifts",
    severity: "high",
    category: "weather",
  };
}

beforeEach(async () => {
  await clearFirestore();
  for (const id of ["site-1", "site-2"]) {
    await db.doc(`organizations/${ORG}/sites/${id}`).set({
      organizationId: ORG,
      projectId: "project-1",
      name: id,
      status: "active",
    });
  }
  await seedUser("foreman-1", "foreman", ["site-1"]);
  await seedUser("manager-1", "siteManager", []);
  await seedUser("worker-1", "worker", ["site-1"]);
});

describe("createSafetyAlert", () => {
  test("a Foreman can raise an alert at their own site", async () => {
    const result = await createSafetyAlert.run(
      call("foreman-1", alertAt("site-1"))
    );
    const stored = (await db
      .doc(`organizations/${ORG}/safety_alerts/${result.id}`).get()).data();
    expect(stored.siteId).toBe("site-1");
    expect(stored.createdBy).toBe("foreman-1");
  });

  test("a Foreman with several sites can raise one at any of them",
    async () => {
      await seedUser("foreman-2", "foreman", ["site-1", "site-2"]);
      await expect(createSafetyAlert.run(call("foreman-2", alertAt("site-2"))))
        .resolves.toEqual(expect.objectContaining({organizationId: ORG}));
    });

  test("a Foreman cannot raise an alert at a site that is not theirs",
    async () => {
      await expect(createSafetyAlert.run(call("foreman-1", alertAt("site-2"))))
        .rejects.toThrow(/permission/);
    });

  test("a Site Manager can raise an alert at any site", async () => {
    await expect(createSafetyAlert.run(call("manager-1", alertAt("site-2"))))
      .resolves.toEqual(expect.objectContaining({organizationId: ORG}));
  });

  test("a Worker cannot raise an alert", async () => {
    await expect(createSafetyAlert.run(call("worker-1", alertAt("site-1"))))
      .rejects.toThrow(/permission/);
  });
});

describe("acknowledgeSafetyAlert / resolveSafetyAlert", () => {
  test("a Foreman can acknowledge and resolve an alert at their own site",
    async () => {
      await seedAlert("a-1", "site-1");
      const req = call("foreman-1", {organizationId: ORG, alertId: "a-1"});
      expect((await acknowledgeSafetyAlert.run(req)).status)
        .toBe("acknowledged");
      expect((await resolveSafetyAlert.run(req)).status).toBe("resolved");
    });

  test("a Foreman cannot acknowledge or resolve another site's alert",
    async () => {
      await seedAlert("a-2", "site-2");
      const req = call("foreman-1", {organizationId: ORG, alertId: "a-2"});
      await expect(acknowledgeSafetyAlert.run(req))
        .rejects.toThrow(/permission/);
      await expect(resolveSafetyAlert.run(req)).rejects.toThrow(/permission/);
    });

  test("a Site Manager can resolve any site's alert", async () => {
    await seedAlert("a-2", "site-2");
    const result = await resolveSafetyAlert.run(
      call("manager-1", {organizationId: ORG, alertId: "a-2"})
    );
    expect(result.status).toBe("resolved");
  });
});
