/**
 * Business-logic tests for `hazard_callable.ts`
 * (`createHazard`, `acknowledgeHazard`, `linkHazardCorrectiveAction`,
 * `closeHazard`), plus the hazard-linking branch of
 * `createCorrectiveAction` (`corrective_action_callable.ts`).
 *
 * Mirrors `corrective_action_callable.test.js`'s shape: these invoke each
 * callable's own exported handler via `.run(request)` — the same code path
 * Cloud Functions itself calls — against a running Firestore emulator, so
 * they exercise the ADMIN-SDK BUSINESS LOGIC that `firestore.rules.test.js`
 * structurally cannot reach.
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
let createHazard;
let acknowledgeHazard;
let linkHazardCorrectiveAction;
let closeHazard;
let createCorrectiveAction;

beforeAll(() => {
  process.env.GCLOUD_PROJECT = PROJECT_ID;
  if (!process.env.FIRESTORE_EMULATOR_HOST) {
    process.env.FIRESTORE_EMULATOR_HOST = "127.0.0.1:8080";
  }

  app = getApps()[0] ?? initializeApp({projectId: PROJECT_ID});
  db = getFirestore(app);

  ({createHazard, acknowledgeHazard, linkHazardCorrectiveAction, closeHazard} =
    require("../lib/hazard_callable"));
  ({createCorrectiveAction} = require("../lib/corrective_action_callable"));
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

async function seedWorkerAtSite(uid, siteId = "site-1", overrides = {}) {
  const {
    organizationId = ORG_A, ...profileOverrides
  } = overrides;
  await db.doc(`users/${uid}`).set(profile(uid, profileOverrides));
  await seedMembership(uid, organizationId, "worker", [siteId]);
}

async function seedReviewer(
  uid, platformRole = "siteManager", organizationId = ORG_A
) {
  await db.doc(`users/${uid}`).set(profile(uid));
  await seedMembership(uid, organizationId, platformRole, []);
}

async function seedSite(id = "site-1", overrides = {}) {
  await db.doc(`organizations/${ORG_A}/sites/${id}`).set({
    organizationId: ORG_A,
    projectId: "project-1",
    name: "Test Site",
    ...overrides,
  });
}

async function seedHazard(id, overrides = {}) {
  const now = Timestamp.now();
  await db.doc(`organizations/${ORG_A}/hazards/${id}`).set({
    organizationId: ORG_A,
    projectId: "project-1",
    siteId: "site-1",
    reportedByUid: "worker-1",
    category: "electrical",
    description: "Exposed wiring near the water tank",
    location: null,
    photoUrl: null,
    status: "reported",
    correctiveActionId: null,
    acknowledgedBy: null,
    acknowledgedAt: null,
    closedBy: null,
    closedAt: null,
    createdAt: now,
    createdBy: "worker-1",
    updatedAt: now,
    updatedBy: "worker-1",
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

async function getHazard(id) {
  const snapshot = await db.doc(`organizations/${ORG_A}/hazards/${id}`).get();
  return snapshot.data();
}

async function getAction(id) {
  const snapshot = await db.doc(
    `organizations/${ORG_A}/corrective_actions/${id}`
  ).get();
  return snapshot.data();
}

beforeEach(async () => {
  await clearFirestore();
  await seedSite();
  await seedReviewer("reviewer-a");
  await seedWorkerAtSite("worker-1");
});

describe("createHazard", () => {
  test("an active worker with site access can report a hazard", async () => {
    const result = await createHazard.run(
      callRequest("worker-1", {
        organizationId: ORG_A,
        siteId: "site-1",
        hazardId: "hazard-1",
        category: "electrical",
        description: "Exposed wiring near the water tank",
      })
    );

    expect(result.status).toBe("reported");
    const hazard = await getHazard("hazard-1");
    expect(hazard.status).toBe("reported");
    expect(hazard.reportedByUid).toBe("worker-1");
    expect(hazard.projectId).toBe("project-1");
    expect(hazard.siteId).toBe("site-1");
    expect(hazard.organizationId).toBe(ORG_A);
    expect(hazard.photoUrl).toBeNull();
    expect(hazard.correctiveActionId).toBeNull();
  });

  test("photo and location are optional but stored when given", async () => {
    await createHazard.run(
      callRequest("worker-1", {
        organizationId: ORG_A,
        siteId: "site-1",
        hazardId: "hazard-1",
        category: "ppe",
        description: "Worker without hard hat",
        location: "East wing, 3rd floor",
        photoUrl: `organizations/${ORG_A}/hazards/hazard-1/photo.jpg`,
      })
    );

    const hazard = await getHazard("hazard-1");
    expect(hazard.location).toBe("East wing, 3rd floor");
    expect(hazard.photoUrl).toBe(
      `organizations/${ORG_A}/hazards/hazard-1/photo.jpg`
    );
  });

  test("rejects an invalid category", async () => {
    await expect(
      createHazard.run(
        callRequest("worker-1", {
          organizationId: ORG_A,
          siteId: "site-1",
          hazardId: "hazard-1",
          category: "notARealCategory",
          description: "Something",
        })
      )
    ).rejects.toThrow(/category must be one of/);
  });

  test("a worker without site access is refused", async () => {
    await seedWorkerAtSite("worker-2", "some-other-site");

    await expect(
      createHazard.run(
        callRequest("worker-2", {
          organizationId: ORG_A,
          siteId: "site-1",
          hazardId: "hazard-2",
          category: "fire",
          description: "Smoke near storage",
        })
      )
    ).rejects.toThrow();
  });

  test("a worker from another organization is refused", async () => {
    await seedWorkerAtSite("worker-b", "site-1", {organizationId: ORG_B});

    await expect(
      createHazard.run(
        callRequest("worker-b", {
          organizationId: ORG_A,
          siteId: "site-1",
          hazardId: "hazard-3",
          category: "fire",
          description: "Smoke near storage",
        })
      )
    ).rejects.toThrow();
  });

  test("cannot report as someone else — reportedByUid is always the caller",
    async () => {
      await createHazard.run(
        callRequest("worker-1", {
          organizationId: ORG_A,
          siteId: "site-1",
          hazardId: "hazard-4",
          category: "other",
          description: "Test",
          reportedByUid: "someone-else",
        })
      );

      const hazard = await getHazard("hazard-4");
      expect(hazard.reportedByUid).toBe("worker-1");
    });

  test("creating with an id that already exists is refused", async () => {
    await seedHazard("hazard-5");

    await expect(
      createHazard.run(
        callRequest("worker-1", {
          organizationId: ORG_A,
          siteId: "site-1",
          hazardId: "hazard-5",
          category: "fire",
          description: "Duplicate attempt",
        })
      )
    ).rejects.toThrow(/already exists/);
  });
});

describe("acknowledgeHazard", () => {
  test("an authorized reviewer can acknowledge a reported hazard", async () => {
    await seedHazard("hazard-1", {status: "reported"});

    const result = await acknowledgeHazard.run(
      callRequest("reviewer-a", {organizationId: ORG_A, hazardId: "hazard-1"})
    );

    expect(result.status).toBe("acknowledged");
    const hazard = await getHazard("hazard-1");
    expect(hazard.status).toBe("acknowledged");
    expect(hazard.acknowledgedBy).toBe("reviewer-a");
    expect(hazard.acknowledgedAt).not.toBeNull();
  });

  test("a non-reviewer role is refused", async () => {
    await seedHazard("hazard-1", {status: "reported"});

    await expect(
      acknowledgeHazard.run(
        callRequest("worker-1", {organizationId: ORG_A, hazardId: "hazard-1"})
      )
    ).rejects.toThrow();

    const hazard = await getHazard("hazard-1");
    expect(hazard.status).toBe("reported");
  });

  test("an already-acknowledged hazard cannot be re-acknowledged", async () => {
    await seedHazard("hazard-1", {
      status: "acknowledged",
      acknowledgedBy: "reviewer-a",
      acknowledgedAt: Timestamp.now(),
    });

    await expect(
      acknowledgeHazard.run(
        callRequest("reviewer-a", {organizationId: ORG_A, hazardId: "hazard-1"})
      )
    ).rejects.toThrow(/newly reported/);
  });

  test("a closed hazard cannot be acknowledged", async () => {
    await seedHazard("hazard-1", {status: "closed"});

    await expect(
      acknowledgeHazard.run(
        callRequest("reviewer-a", {organizationId: ORG_A, hazardId: "hazard-1"})
      )
    ).rejects.toThrow(/newly reported/);
  });

  test("a reviewer from another organization is refused", async () => {
    await seedReviewer("reviewer-b", "siteManager", ORG_B);
    await seedHazard("hazard-1", {status: "reported"});

    await expect(
      acknowledgeHazard.run(
        callRequest("reviewer-b", {organizationId: ORG_A, hazardId: "hazard-1"})
      )
    ).rejects.toThrow();
  });
});

describe("closeHazard", () => {
  test("an authorized reviewer can close a reported hazard directly",
    async () => {
      await seedHazard("hazard-1", {status: "reported"});

      const result = await closeHazard.run(
        callRequest("reviewer-a", {organizationId: ORG_A, hazardId: "hazard-1"})
      );

      expect(result.status).toBe("closed");
      const hazard = await getHazard("hazard-1");
      expect(hazard.status).toBe("closed");
      expect(hazard.closedBy).toBe("reviewer-a");
      expect(hazard.closedAt).not.toBeNull();
    });

  test("an authorized reviewer can close an acknowledged hazard", async () => {
    await seedHazard("hazard-1", {status: "acknowledged"});

    const result = await closeHazard.run(
      callRequest("reviewer-a", {organizationId: ORG_A, hazardId: "hazard-1"})
    );

    expect(result.status).toBe("closed");
  });

  test("an already-closed hazard cannot be closed again", async () => {
    await seedHazard("hazard-1", {
      status: "closed",
      closedBy: "reviewer-a",
      closedAt: Timestamp.now(),
    });

    await expect(
      closeHazard.run(
        callRequest("reviewer-a", {organizationId: ORG_A, hazardId: "hazard-1"})
      )
    ).rejects.toThrow(/already been closed/);
  });

  test("a hazard with a linked corrective action cannot be closed directly",
    async () => {
      await seedHazard("hazard-1", {
        status: "correctiveActionCreated",
        correctiveActionId: "action-1",
      });

      await expect(
        closeHazard.run(
          callRequest("reviewer-a", {
            organizationId: ORG_A,
            hazardId: "hazard-1",
          })
        )
      ).rejects.toThrow(/corrective action in progress/);
    });

  test("a non-reviewer role is refused", async () => {
    await seedHazard("hazard-1", {status: "reported"});

    await expect(
      closeHazard.run(
        callRequest("worker-1", {organizationId: ORG_A, hazardId: "hazard-1"})
      )
    ).rejects.toThrow();

    const hazard = await getHazard("hazard-1");
    expect(hazard.status).toBe("reported");
  });

  test("a reviewer from another organization is refused", async () => {
    await seedReviewer("reviewer-b", "siteManager", ORG_B);
    await seedHazard("hazard-1", {status: "reported"});

    await expect(
      closeHazard.run(
        callRequest("reviewer-b", {organizationId: ORG_A, hazardId: "hazard-1"})
      )
    ).rejects.toThrow();

    const hazard = await getHazard("hazard-1");
    expect(hazard.status).toBe("reported");
  });
});

describe("linkHazardCorrectiveAction", () => {
  async function seedAssignee(uid = "assignee-1") {
    await db.doc(`users/${uid}`).set(profile(uid));
    await seedMembership(uid, ORG_A, "worker", []);
  }

  test("an authorized reviewer can link a corrective action to a hazard",
    async () => {
      await seedHazard("hazard-1", {status: "reported"});
      await seedAssignee();

      const result = await linkHazardCorrectiveAction.run(
        callRequest("reviewer-a", {
          organizationId: ORG_A,
          hazardId: "hazard-1",
          title: "Isolate exposed wiring",
          description: "De-energize and re-insulate before re-use",
          assignedTo: "assignee-1",
          dueDate: new Date("2026-09-05").toISOString(),
        })
      );

      const action = await getAction(result.id);
      expect(action.hazardId).toBe("hazard-1");
      expect(action.meetingId).toBeNull();
      expect(action.concernId).toBeNull();
      expect(action.organizationId).toBe(ORG_A);
      expect(action.projectId).toBe("project-1");
      expect(action.siteId).toBe("site-1");
      expect(action.status).toBe("open");

      const hazard = await getHazard("hazard-1");
      expect(hazard.status).toBe("correctiveActionCreated");
      expect(hazard.correctiveActionId).toBe(result.id);
    });

  test("cannot assign the corrective action to yourself", async () => {
    await seedHazard("hazard-1", {status: "reported"});

    await expect(
      linkHazardCorrectiveAction.run(
        callRequest("reviewer-a", {
          organizationId: ORG_A,
          hazardId: "hazard-1",
          title: "Fix it",
          description: "Fix it",
          assignedTo: "reviewer-a",
          dueDate: new Date("2026-09-05").toISOString(),
        })
      )
    ).rejects.toThrow(/cannot assign/);
  });

  test("cannot link a second corrective action to an already-linked hazard",
    async () => {
      await seedHazard("hazard-1", {
        status: "correctiveActionCreated",
        correctiveActionId: "action-existing",
      });
      await seedAssignee();

      await expect(
        linkHazardCorrectiveAction.run(
          callRequest("reviewer-a", {
            organizationId: ORG_A,
            hazardId: "hazard-1",
            title: "Second action",
            description: "Should be refused",
            assignedTo: "assignee-1",
            dueDate: new Date("2026-09-05").toISOString(),
          })
        )
      ).rejects.toThrow(/already has a corrective action/);
    });

  test("cannot link a corrective action to a closed hazard", async () => {
    await seedHazard("hazard-1", {status: "closed"});
    await seedAssignee();

    await expect(
      linkHazardCorrectiveAction.run(
        callRequest("reviewer-a", {
          organizationId: ORG_A,
          hazardId: "hazard-1",
          title: "Too late",
          description: "Should be refused",
          assignedTo: "assignee-1",
          dueDate: new Date("2026-09-05").toISOString(),
        })
      )
    ).rejects.toThrow(/already been closed/);
  });

  test("a non-reviewer role is refused", async () => {
    await seedHazard("hazard-1", {status: "reported"});
    await seedAssignee();

    await expect(
      linkHazardCorrectiveAction.run(
        callRequest("worker-1", {
          organizationId: ORG_A,
          hazardId: "hazard-1",
          title: "Fix it",
          description: "Fix it",
          assignedTo: "assignee-1",
          dueDate: new Date("2026-09-05").toISOString(),
        })
      )
    ).rejects.toThrow();
  });

  test("a reviewer from another organization is refused", async () => {
    await seedReviewer("reviewer-b", "siteManager", ORG_B);
    await seedHazard("hazard-1", {status: "reported"});
    await seedAssignee();

    await expect(
      linkHazardCorrectiveAction.run(
        callRequest("reviewer-b", {
          organizationId: ORG_A,
          hazardId: "hazard-1",
          title: "Fix it",
          description: "Fix it",
          assignedTo: "assignee-1",
          dueDate: new Date("2026-09-05").toISOString(),
        })
      )
    ).rejects.toThrow();

    const hazard = await getHazard("hazard-1");
    expect(hazard.status).toBe("reported");
  });
});

describe("createCorrectiveAction hazard branch (mutual exclusivity)", () => {
  async function seedAssignee(uid = "assignee-1") {
    await db.doc(`users/${uid}`).set(profile(uid));
    await seedMembership(uid, ORG_A, "worker", []);
  }

  test("createCorrectiveAction with hazardId behaves identically to " +
    "linkHazardCorrectiveAction", async () => {
    await seedHazard("hazard-1", {status: "reported"});
    await seedAssignee();

    const result = await createCorrectiveAction.run(
      callRequest("reviewer-a", {
        organizationId: ORG_A,
        hazardId: "hazard-1",
        title: "Isolate exposed wiring",
        description: "De-energize and re-insulate before re-use",
        assignedTo: "assignee-1",
        dueDate: new Date("2026-09-05").toISOString(),
      })
    );

    const action = await getAction(result.id);
    expect(action.hazardId).toBe("hazard-1");

    const hazard = await getHazard("hazard-1");
    expect(hazard.status).toBe("correctiveActionCreated");
  });

  test("rejects both meetingId and hazardId given together", async () => {
    await seedHazard("hazard-1", {status: "reported"});
    await seedAssignee();

    await expect(
      createCorrectiveAction.run(
        callRequest("reviewer-a", {
          organizationId: ORG_A,
          hazardId: "hazard-1",
          meetingId: "meeting-1",
          title: "Ambiguous origin",
          description: "Should be refused",
          assignedTo: "assignee-1",
          dueDate: new Date("2026-09-05").toISOString(),
        })
      )
    ).rejects.toThrow(/Exactly one of meetingId or hazardId/);
  });

  test("rejects neither meetingId nor hazardId given", async () => {
    await seedAssignee();

    await expect(
      createCorrectiveAction.run(
        callRequest("reviewer-a", {
          organizationId: ORG_A,
          title: "No origin",
          description: "Should be refused",
          assignedTo: "assignee-1",
          dueDate: new Date("2026-09-05").toISOString(),
        })
      )
    ).rejects.toThrow(/Exactly one of meetingId or hazardId/);
  });

  test("rejects concernId given together with hazardId", async () => {
    await seedHazard("hazard-1", {status: "reported"});
    await seedAssignee();

    await expect(
      createCorrectiveAction.run(
        callRequest("reviewer-a", {
          organizationId: ORG_A,
          hazardId: "hazard-1",
          concernId: "concern-1",
          title: "Ambiguous origin",
          description: "Should be refused",
          assignedTo: "assignee-1",
          dueDate: new Date("2026-09-05").toISOString(),
        })
      )
    ).rejects.toThrow(/concernId cannot be given together with hazardId/);
  });

  test("an Org B reviewer cannot create/link an action for an Org A hazard",
    async () => {
      await seedReviewer("reviewer-b", "siteManager", ORG_B);
      await seedHazard("hazard-1", {status: "reported"});
      await seedAssignee();

      await expect(
        createCorrectiveAction.run(
          callRequest("reviewer-b", {
            organizationId: ORG_A,
            hazardId: "hazard-1",
            title: "Cross-org attempt",
            description: "Should be refused",
            assignedTo: "assignee-1",
            dueDate: new Date("2026-09-05").toISOString(),
          })
        )
      ).rejects.toThrow();

      const hazard = await getHazard("hazard-1");
      expect(hazard.status).toBe("reported");
      expect(hazard.correctiveActionId).toBeNull();
    });

  test("an Org A reviewer cannot assign the action to an Org B worker",
    async () => {
      await seedHazard("hazard-1", {status: "reported"});
      await seedWorkerAtSite("worker-b", "site-1", {organizationId: ORG_B});

      await expect(
        createCorrectiveAction.run(
          callRequest("reviewer-a", {
            organizationId: ORG_A,
            hazardId: "hazard-1",
            title: "Cross-org assignment attempt",
            description: "Should be refused",
            assignedTo: "worker-b",
            dueDate: new Date("2026-09-05").toISOString(),
          })
        )
      ).rejects.toThrow();

      const hazard = await getHazard("hazard-1");
      expect(hazard.status).toBe("reported");
      expect(hazard.correctiveActionId).toBeNull();
    });
});
