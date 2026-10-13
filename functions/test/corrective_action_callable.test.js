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
let submitCorrectiveActionForReview;

beforeAll(() => {
  process.env.GCLOUD_PROJECT = PROJECT_ID;
  if (!process.env.FIRESTORE_EMULATOR_HOST) {
    process.env.FIRESTORE_EMULATOR_HOST = "127.0.0.1:8080";
  }

  app = getApps()[0] ?? initializeApp({projectId: PROJECT_ID});
  db = getFirestore(app);

  // Imported after the emulator env vars are set, so the Admin SDK the
  // callable module resolves via getFirestore() talks to the emulator.
  ({updateCorrectiveActionStatus, submitCorrectiveActionForReview} =
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

async function seedReviewer(
  uid, platformRole = "siteManager", organizationId = ORG_A
) {
  await db.doc(`users/${uid}`).set(profile(uid));
  await seedMembership(uid, organizationId, platformRole, []);
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

async function callSubmitForReview(uid, actionId) {
  return submitCorrectiveActionForReview.run(
    callRequest(uid, {organizationId: ORG_A, actionId})
  );
}

async function getAction(id) {
  const snapshot = await db.doc(
    `organizations/${ORG_A}/corrective_actions/${id}`
  ).get();
  return snapshot.data();
}

async function seedHazard(id, overrides = {}) {
  const now = Timestamp.now();
  await db.doc(`organizations/${ORG_A}/hazards/${id}`).set({
    organizationId: ORG_A,
    projectId: "project-1",
    siteId: "site-1",
    reportedByUid: "worker-1",
    category: "electrical",
    description: "Exposed wiring",
    location: null,
    photoUrl: null,
    status: "correctiveActionCreated",
    correctiveActionId: null,
    acknowledgedBy: null,
    acknowledgedAt: null,
    closedBy: null,
    closedAt: null,
    createdAt: now,
    updatedAt: now,
    createdBy: "worker-1",
    updatedBy: "worker-1",
    ...overrides,
  });
}

async function getHazard(id) {
  const snapshot = await db.doc(`organizations/${ORG_A}/hazards/${id}`).get();
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

  test("2. submittedForReview -> completed succeeds and sets completedAt",
    async () => {
      await seedAction("action-2", {status: "submittedForReview"});

      const result =
        await callUpdateStatus("reviewer-a", "action-2", "completed");

      expect(result.status).toBe("completed");
      const action = await getAction("action-2");
      expect(action.status).toBe("completed");
      expect(action.completedAt).not.toBeNull();
    });

  test("3. open -> completed is rejected: completion must go through " +
    "submittedForReview first", async () => {
    await seedAction("action-3", {status: "open"});

    await expect(
      callUpdateStatus("reviewer-a", "action-3", "completed")
    ).rejects.toThrow(/submitted for review/);

    const action = await getAction("action-3");
    expect(action.status).toBe("open");
    expect(action.completedAt).toBeNull();
  });

  test("3b. inProgress -> completed is rejected for the same reason",
    async () => {
      await seedAction("action-3b", {status: "inProgress"});

      await expect(
        callUpdateStatus("reviewer-a", "action-3b", "completed")
      ).rejects.toThrow(/submitted for review/);

      const action = await getAction("action-3b");
      expect(action.status).toBe("inProgress");
    });

  test("3c. a reviewer may send a submittedForReview action back to " +
    "inProgress instead of completing it — this IS the rejection path",
  async () => {
    await seedAction("action-3c", {status: "submittedForReview"});

    const result =
      await callUpdateStatus("reviewer-a", "action-3c", "inProgress");

    expect(result.status).toBe("inProgress");
    const action = await getAction("action-3c");
    expect(action.status).toBe("inProgress");
    expect(action.completedAt).toBeNull();
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
    await seedReviewer("worker-x", "worker");
    await seedAction("action-8", {status: "open"});

    await expect(
      callUpdateStatus("worker-x", "action-8", "inProgress")
    ).rejects.toThrow();

    const action = await getAction("action-8");
    expect(action.status).toBe("open");
  });

  test("a foreman IS an authorized reviewer and may update status within " +
    "their own organization", async () => {
    await seedReviewer("foreman-a", "foreman");
    await seedAction("action-8b", {status: "open"});

    await callUpdateStatus("foreman-a", "action-8b", "inProgress");

    const action = await getAction("action-8b");
    expect(action.status).toBe("inProgress");
  });

  test("preserves organization isolation: a reviewer from another " +
    "organization is refused", async () => {
    await seedReviewer("reviewer-b", "siteManager", ORG_B);
    await seedAction("action-9", {status: "open"});

    await expect(
      callUpdateStatus("reviewer-b", "action-9", "inProgress")
    ).rejects.toThrow();

    const action = await getAction("action-9");
    expect(action.status).toBe("open");
  });

  describe("completing a hazard-originated action closes the linked hazard",
    () => {
      test("completing the action atomically closes its hazard", async () => {
        await seedHazard("hazard-1", {correctiveActionId: "action-10"});
        await seedAction("action-10", {
          status: "submittedForReview",
          hazardId: "hazard-1",
          meetingId: null,
        });

        await callUpdateStatus("reviewer-a", "action-10", "completed");

        const action = await getAction("action-10");
        expect(action.status).toBe("completed");
        const hazard = await getHazard("hazard-1");
        expect(hazard.status).toBe("closed");
        expect(hazard.closedAt).not.toBeNull();
        expect(hazard.closedBy).toBe("reviewer-a");
      });

      test("completing a meeting-originated action never touches a hazard " +
        "(hazardId is null)", async () => {
        await seedAction("action-11", {status: "submittedForReview"});

        await callUpdateStatus("reviewer-a", "action-11", "completed");

        const action = await getAction("action-11");
        expect(action.status).toBe("completed");
      });

      test("does not fail the action's own completion if the hazard is " +
        "already closed for some other reason", async () => {
        await seedHazard("hazard-2", {
          status: "closed",
          correctiveActionId: "action-12",
        });
        await seedAction("action-12", {
          status: "submittedForReview",
          hazardId: "hazard-2",
          meetingId: null,
        });

        const result =
          await callUpdateStatus("reviewer-a", "action-12", "completed");

        expect(result.status).toBe("completed");
        const action = await getAction("action-12");
        expect(action.status).toBe("completed");
      });
    });
});

describe("submitCorrectiveActionForReview", () => {
  const folder = `organizations/${ORG_A}/corrective_actions/`;
  const photo = (actionId) => ({
    storagePath: `${folder}${actionId}/after.jpg`,
    downloadUrl: "https://example.com/after.jpg",
  });

  function submitWith(actionId, data) {
    return submitCorrectiveActionForReview.run(
      callRequest("worker-1", {organizationId: ORG_A, actionId, ...data})
    );
  }

  test("photo evidence is required when the action asks for a photo",
    async () => {
      await seedAction("ev-1", {
        evidenceRequired: true,
        evidenceKinds: ["photo"],
      });

      await expect(submitWith("ev-1", {completionNote: "Done"}))
        .rejects.toThrow(/at least one photo/);

      await submitWith("ev-1", {evidencePhotos: [photo("ev-1")]});
      const action = await getAction("ev-1");
      expect(action.status).toBe("submittedForReview");
      expect(action.evidencePhotos).toEqual([photo("ev-1")]);
      expect(action.submittedBy).toBe("worker-1");
      expect(action.submittedAt).not.toBeNull();
    });

  test("a written confirmation is required when the action asks for one",
    async () => {
      await seedAction("ev-2", {
        evidenceRequired: true,
        evidenceKinds: ["confirmation"],
      });

      await expect(submitWith("ev-2", {completionNote: "   "}))
        .rejects.toThrow(/written confirmation/);

      await submitWith("ev-2", {
        completionNote: "Guard rail fitted and inspected",
      });
      expect((await getAction("ev-2")).completionNote)
        .toBe("Guard rail fitted and inspected");
    });

  test("an older action with only evidenceRequired: true needs a photo",
    async () => {
      await seedAction("ev-3", {evidenceRequired: true});
      await expect(submitWith("ev-3", {}))
        .rejects.toThrow(/at least one photo/);
    });

  test("a photo outside this action's own folder is refused", async () => {
    await seedAction("ev-4", {evidenceKinds: ["photo"]});
    await expect(
      submitWith("ev-4", {evidencePhotos: [photo("someone-elses-action")]})
    ).rejects.toThrow(/own folder/);
  });

  test("no evidence is needed when none was required", async () => {
    await seedAction("ev-5");
    await submitWith("ev-5", {});
    expect((await getAction("ev-5")).status).toBe("submittedForReview");
  });

  test("sending submitted work back records the reason, and resubmitting " +
    "clears it", async () => {
    await seedAction("ev-6", {status: "submittedForReview"});
    await seedReviewer("reviewer-a");

    await updateCorrectiveActionStatus.run(
      callRequest("reviewer-a", {
        organizationId: ORG_A,
        actionId: "ev-6",
        status: "inProgress",
        reviewFeedback: "Photo is blurry — please retake",
      })
    );
    let action = await getAction("ev-6");
    expect(action.status).toBe("inProgress");
    expect(action.reviewFeedback).toBe("Photo is blurry — please retake");

    await submitWith("ev-6", {});
    action = await getAction("ev-6");
    expect(action.reviewFeedback).toBeNull();
  });

  test("a reviewer cannot approve work assigned to themselves", async () => {
    await seedAction("ev-8", {
      status: "submittedForReview",
      assignedTo: "reviewer-a",
    });
    await seedReviewer("reviewer-a");
    await expect(callUpdateStatus("reviewer-a", "ev-8", "completed"))
      .rejects.toThrow(/another reviewer/);
    expect((await getAction("ev-8")).status).toBe("submittedForReview");
  });

  test("completing records who verified it", async () => {
    await seedAction("ev-7", {status: "submittedForReview"});
    await seedReviewer("reviewer-a");
    await callUpdateStatus("reviewer-a", "ev-7", "completed");
    const action = await getAction("ev-7");
    expect(action.completedBy).toBe("reviewer-a");
    expect(action.completedByName).toBe("Test User");
  });

  test("the assignee may submit their own open work for review",
    async () => {
      await seedAction("action-20", {
        status: "open",
        assignedTo: "worker-1",
      });

      const result =
        await callSubmitForReview("worker-1", "action-20");

      expect(result.status).toBe("submittedForReview");
      const action = await getAction("action-20");
      expect(action.status).toBe("submittedForReview");
    });

  test("the assignee may submit their own inProgress work for review",
    async () => {
      await seedAction("action-21", {
        status: "inProgress",
        assignedTo: "worker-1",
      });

      await callSubmitForReview("worker-1", "action-21");

      const action = await getAction("action-21");
      expect(action.status).toBe("submittedForReview");
    });

  test("a reviewer role (not the assignee) is refused — this is an " +
    "assignee-only callable", async () => {
    await seedAction("action-22", {
      status: "open",
      assignedTo: "worker-1",
    });

    await expect(
      callSubmitForReview("reviewer-a", "action-22")
    ).rejects.toThrow();

    const action = await getAction("action-22");
    expect(action.status).toBe("open");
  });

  test("someone other than the assignee is refused", async () => {
    await seedAction("action-23", {
      status: "open",
      assignedTo: "worker-1",
    });

    await expect(
      callSubmitForReview("worker-2", "action-23")
    ).rejects.toThrow();

    const action = await getAction("action-23");
    expect(action.status).toBe("open");
  });

  test("cannot resubmit work already submittedForReview", async () => {
    await seedAction("action-24", {
      status: "submittedForReview",
      assignedTo: "worker-1",
    });

    await expect(
      callSubmitForReview("worker-1", "action-24")
    ).rejects.toThrow(/open or in progress/);
  });

  test("cannot submit already-completed work", async () => {
    await seedAction("action-25", {
      status: "completed",
      assignedTo: "worker-1",
      completedAt: Timestamp.now(),
    });

    await expect(
      callSubmitForReview("worker-1", "action-25")
    ).rejects.toThrow(/open or in progress/);
  });

  test("cannot submit out of overdue directly — a reviewer must move it " +
    "back to open/inProgress first", async () => {
    await seedAction("action-26", {
      status: "overdue",
      assignedTo: "worker-1",
    });

    await expect(
      callSubmitForReview("worker-1", "action-26")
    ).rejects.toThrow(/open or in progress/);
  });
});
