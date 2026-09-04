/**
 * Business-logic tests for `updateCorrectiveActionStatus`
 * (`src/corrective_action_callable.ts`).
 *
 * Unlike `firestore.rules.test.js` (which proves clients cannot write these
 * collections directly), these tests invoke the callable's own exported
 * handler via its `.run(request)` method — the same code path Cloud
 * Functions itself calls — against a running Firestore emulator, so they
 * exercise the ADMIN-SDK BUSINESS LOGIC that rules tests structurally
 * cannot reach (rules are bypassed by the Admin SDK entirely).
 *
 * This is the regression suite for the "completed corrective action can be
 * reopened" bug: `completed` must be a terminal status, and `completedAt`
 * must never be cleared or overwritten once set.
 *
 * Requires the Firestore emulator — see `npm run test:callables`, which
 * wraps this suite in `firebase emulators:exec` exactly like
 * `test:rules`. Requires JDK 21+, per `test/README.md`.
 */

const {initializeApp, getApps, deleteApp} = require("firebase-admin/app");
const {getFirestore, Timestamp} = require("firebase-admin/firestore");

const PROJECT_ID = "jva-safety-rules-test";
const ORG_A = "org-alpha";
const ORG_B = "org-beta";

let app;
let db;
let updateCorrectiveActionStatus;

beforeAll(() => {
  process.env.GCLOUD_PROJECT = PROJECT_ID;
  if (!process.env.FIRESTORE_EMULATOR_HOST) {
    process.env.FIRESTORE_EMULATOR_HOST = "127.0.0.1:8080";
  }

  app = getApps()[0] ?? initializeApp({projectId: PROJECT_ID});
  db = getFirestore(app);

  // Imported after the emulator env vars are set, so the Admin SDK the
  // callable module resolves via getFirestore() talks to the emulator.
  ({updateCorrectiveActionStatus} =
    require("../lib/corrective_action_callable"));
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
    organizationId: ORG_A,
    name: "Test User",
    email: `${uid}@example.com`,
    accountStatus: "active",
    ...overrides,
  };
}

async function seedReviewer(uid, platformRole = "siteManager") {
  await db.doc(`users/${uid}`).set(profile(uid, {platformRole}));
}

async function seedAction(id, overrides = {}) {
  const now = Timestamp.now();
  await db.doc(`organizations/${ORG_A}/corrective_actions/${id}`).set({
    organizationId: ORG_A,
    projectId: "project-1",
    siteId: "site-1",
    meetingId: "meeting-1",
    concernId: null,
    title: "Fix loose scaffolding",
    description: "Level 3 scaffolding needs tightening",
    assignedTo: "worker-1",
    assignedBy: "foreman-1",
    dueDate: now,
    status: "open",
    evidenceRequired: false,
    createdAt: now,
    updatedAt: now,
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

async function callUpdateStatus(uid, actionId, status) {
  return updateCorrectiveActionStatus.run(
    callRequest(uid, {organizationId: ORG_A, actionId, status})
  );
}

async function getAction(id) {
  const snapshot = await db.doc(
    `organizations/${ORG_A}/corrective_actions/${id}`
  ).get();
  return snapshot.data();
}

beforeEach(async () => {
  await clearFirestore();
  await seedReviewer("reviewer-a");
});

describe("updateCorrectiveActionStatus", () => {
  test("1. open -> inProgress succeeds", async () => {
    await seedAction("action-1", {status: "open"});

    const result =
      await callUpdateStatus("reviewer-a", "action-1", "inProgress");

    expect(result.status).toBe("inProgress");
    const action = await getAction("action-1");
    expect(action.status).toBe("inProgress");
    expect(action.completedAt).toBeNull();
  });

  test("2. open -> completed succeeds and sets completedAt", async () => {
    await seedAction("action-2", {status: "open"});

    const result =
      await callUpdateStatus("reviewer-a", "action-2", "completed");

    expect(result.status).toBe("completed");
    const action = await getAction("action-2");
    expect(action.status).toBe("completed");
    expect(action.completedAt).not.toBeNull();
  });

  test("3. inProgress -> completed succeeds and sets completedAt", async () => {
    await seedAction("action-3", {status: "inProgress"});

    const result =
      await callUpdateStatus("reviewer-a", "action-3", "completed");

    expect(result.status).toBe("completed");
    const action = await getAction("action-3");
    expect(action.status).toBe("completed");
    expect(action.completedAt).not.toBeNull();
  });

  test("4. completed -> open is rejected", async () => {
    await seedAction("action-4", {
      status: "completed",
      completedAt: Timestamp.now(),
    });

    await expect(
      callUpdateStatus("reviewer-a", "action-4", "open")
    ).rejects.toThrow(/already been completed/);

    const action = await getAction("action-4");
    expect(action.status).toBe("completed");
  });

  test("5. completed -> inProgress is rejected", async () => {
    await seedAction("action-5", {
      status: "completed",
      completedAt: Timestamp.now(),
    });

    await expect(
      callUpdateStatus("reviewer-a", "action-5", "inProgress")
    ).rejects.toThrow(/already been completed/);

    const action = await getAction("action-5");
    expect(action.status).toBe("completed");
  });

  test("6. completed -> completed is rejected, matching the callable's " +
    "existing refusal semantics", async () => {
    await seedAction("action-6", {
      status: "completed",
      completedAt: Timestamp.now(),
    });

    await expect(
      callUpdateStatus("reviewer-a", "action-6", "completed")
    ).rejects.toThrow(/already been completed/);
  });

  test("7. completedAt is unchanged after every rejected transition",
    async () => {
      const originalCompletedAt = Timestamp.fromDate(new Date("2026-01-01"));
      await seedAction("action-7", {
        status: "completed",
        completedAt: originalCompletedAt,
      });

      for (const status of ["open", "inProgress", "completed"]) {
        await expect(
          callUpdateStatus("reviewer-a", "action-7", status)
        ).rejects.toThrow();
      }

      const action = await getAction("action-7");
      expect(action.completedAt.isEqual(originalCompletedAt)).toBe(true);
    });

  // A foreman IS an authorized reviewer for status updates under the new
  // model (corrective_action_callable.ts's own doc comment: "A foreman may
  // update the status of a corrective action on their own site"), unlike
  // the old model where only org-scoped roles above foreman could review.
  // `worker` is the real non-reviewer case now.
  test("preserves authorization: a non-reviewer role is refused", async () => {
    await db.doc("users/worker-x").set(
      profile("worker-x", {platformRole: "worker"})
    );
    await seedAction("action-8", {status: "open"});

    await expect(
      callUpdateStatus("worker-x", "action-8", "inProgress")
    ).rejects.toThrow();

    const action = await getAction("action-8");
    expect(action.status).toBe("open");
  });

  test("a foreman IS an authorized reviewer and may update status within " +
    "their own organization", async () => {
    await db.doc("users/foreman-a").set(
      profile("foreman-a", {platformRole: "foreman"})
    );
    await seedAction("action-8b", {status: "open"});

    await callUpdateStatus("foreman-a", "action-8b", "inProgress");

    const action = await getAction("action-8b");
    expect(action.status).toBe("inProgress");
  });

  test("preserves organization isolation: a reviewer from another " +
    "organization is refused", async () => {
    await db.doc("users/reviewer-b").set(
      profile("reviewer-b", {
        organizationId: ORG_B,
        platformRole: "siteManager",
      })
    );
    await seedAction("action-9", {status: "open"});

    await expect(
      callUpdateStatus("reviewer-b", "action-9", "inProgress")
    ).rejects.toThrow();

    const action = await getAction("action-9");
    expect(action.status).toBe("open");
  });
});
