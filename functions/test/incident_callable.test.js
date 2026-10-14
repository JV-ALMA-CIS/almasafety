/**
 * Business-logic tests for `incident_callable.ts` (`createIncident`,
 * `startIncidentInvestigation`, `linkIncidentCorrectiveAction`,
 * `closeIncident`), plus the incident branch of `createCorrectiveAction`.
 *
 * Mirrors `hazard_callable.test.js`: invokes each callable's exported
 * handler via `.run(request)` against a running Firestore emulator. See
 * `npm run test:callables` and `test/README.md`.
 */

const {initializeApp, getApps, deleteApp} = require("firebase-admin/app");
const {getFirestore, Timestamp} = require("firebase-admin/firestore");

const PROJECT_ID = "jva-safety-rules-test";
const ORG_A = "org-alpha";

let app;
let db;
let createIncident;
let startIncidentInvestigation;
let linkIncidentCorrectiveAction;
let closeIncident;
let createCorrectiveAction;

beforeAll(() => {
  process.env.GCLOUD_PROJECT = PROJECT_ID;
  if (!process.env.FIRESTORE_EMULATOR_HOST) {
    process.env.FIRESTORE_EMULATOR_HOST = "127.0.0.1:8080";
  }

  app = getApps()[0] ?? initializeApp({projectId: PROJECT_ID});
  db = getFirestore(app);

  ({
    createIncident,
    startIncidentInvestigation,
    linkIncidentCorrectiveAction,
    closeIncident,
  } = require("../lib/incident_callable"));
  ({createCorrectiveAction} = require("../lib/corrective_action_callable"));
});

afterAll(async () => {
  if (app) await deleteApp(app);
});

async function clearFirestore() {
  const collections = await db.listCollections();
  await Promise.all(collections.map((c) => db.recursiveDelete(c)));
}

function profile(uid) {
  return {
    uid,
    name: "Test User",
    email: `${uid}@example.com`,
    accountStatus: "active",
  };
}

async function seedMembership(uid, role, siteIds) {
  await db.doc(`users/${uid}/memberships/${ORG_A}`).set({
    organizationId: ORG_A,
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
  });
}

async function seedWorkerAtSite(uid, siteId = "site-1") {
  await db.doc(`users/${uid}`).set(profile(uid));
  await seedMembership(uid, "worker", [siteId]);
}

async function seedReviewer(uid, role = "siteManager") {
  await db.doc(`users/${uid}`).set(profile(uid));
  await seedMembership(uid, role, []);
}

async function seedSite(id = "site-1") {
  await db.doc(`organizations/${ORG_A}/sites/${id}`).set({
    organizationId: ORG_A,
    projectId: "project-1",
    name: "Test Site",
  });
}

async function seedIncident(id, overrides = {}) {
  const now = Timestamp.now();
  await db.doc(`organizations/${ORG_A}/incidents/${id}`).set({
    organizationId: ORG_A,
    projectId: "project-1",
    siteId: "site-1",
    reportedByUid: "worker-1",
    type: "injury",
    description: "Cut hand on sheet metal",
    occurredAt: now,
    location: null,
    injuredPersonName: "John",
    immediateAction: "First aid given",
    photoUrl: null,
    status: "reported",
    severity: null,
    investigationStartedBy: null,
    investigationStartedAt: null,
    correctiveActionIds: [],
    rootCause: null,
    closingNotes: null,
    closedBy: null,
    closedAt: null,
    createdAt: now,
    createdBy: "worker-1",
    updatedAt: now,
    updatedBy: "worker-1",
    // Reporting already finished, so closing tests are about closing.
    reportingLevel: "firstAid",
    reportingSteps: [{
      id: "notifyCor", label: "Tell the COR", dueAt: now,
      doneAt: now, doneByUid: "manager-1", doneByName: "M", note: null,
    }],
    ...overrides,
  });
}

function callRequest(uid, data) {
  return {auth: {uid, token: {}}, data, rawRequest: {}};
}

async function getIncident(id) {
  const snapshot = await db.doc(
    `organizations/${ORG_A}/incidents/${id}`
  ).get();
  return snapshot.data();
}

async function getAction(id) {
  const snapshot = await db.doc(
    `organizations/${ORG_A}/corrective_actions/${id}`
  ).get();
  return snapshot.data();
}

function report(overrides = {}) {
  return {
    organizationId: ORG_A,
    siteId: "site-1",
    incidentId: "incident-1",
    type: "injury",
    description: "Cut hand on sheet metal",
    occurredAt: new Date(Date.now() - 60 * 60 * 1000).toISOString(),
    injuredPersonName: "John",
    immediateAction: "First aid given",
    ...overrides,
  };
}

function actionRequest(overrides = {}) {
  return {
    organizationId: ORG_A,
    incidentId: "incident-1",
    title: "Fit edge guards",
    description: "Fit guards to sheet metal edges in the store",
    assignedTo: "worker-2",
    dueDate: new Date(Date.now() + 86400000).toISOString(),
    ...overrides,
  };
}

beforeEach(async () => {
  await clearFirestore();
  await seedSite();
  await seedReviewer("reviewer-a");
  await seedWorkerAtSite("worker-1");
  await seedWorkerAtSite("worker-2");
});

describe("createIncident", () => {
  test("an active worker with site access can report an incident",
    async () => {
      const result = await createIncident.run(
        callRequest("worker-1", report())
      );

      expect(result.status).toBe("reported");
      const incident = await getIncident("incident-1");
      expect(incident.status).toBe("reported");
      expect(incident.type).toBe("injury");
      expect(incident.reportedByUid).toBe("worker-1");
      expect(incident.projectId).toBe("project-1");
      expect(incident.injuredPersonName).toBe("John");
      expect(incident.immediateAction).toBe("First aid given");
      expect(incident.occurredAt).toBeInstanceOf(Timestamp);
      expect(incident.severity).toBeNull();
      expect(incident.correctiveActionIds).toEqual([]);
    });

  test("injuredPersonName is dropped for a non-injury incident", async () => {
    await createIncident.run(
      callRequest("worker-1", report({type: "propertyDamage"}))
    );

    expect((await getIncident("incident-1")).injuredPersonName).toBeNull();
  });

  test("accepts \"other\" for anything the list doesn't cover", async () => {
    await createIncident.run(
      callRequest("worker-1", report({type: "other"}))
    );
    const incident = await getIncident("incident-1");
    expect(incident.type).toBe("other");
    expect(incident.injuredPersonName).toBeNull();
  });

  test("rejects an invalid type", async () => {
    await expect(
      createIncident.run(callRequest("worker-1", report({type: "nearMiss"})))
    ).rejects.toThrow(/type must be one of/);
  });

  test("rejects an incident in the future", async () => {
    const tomorrow = new Date(Date.now() + 86400000).toISOString();
    await expect(
      createIncident.run(
        callRequest("worker-1", report({occurredAt: tomorrow}))
      )
    ).rejects.toThrow(/cannot be in the future/);
  });

  test("a worker without access to the site is refused", async () => {
    await seedWorkerAtSite("worker-3", "site-other");
    await expect(
      createIncident.run(callRequest("worker-3", report()))
    ).rejects.toThrow();
    expect(await getIncident("incident-1")).toBeUndefined();
  });

  test("a Site Manager with no assigned site can report at any site of " +
    "their organization", async () => {
    await seedSite("site-2");
    await createIncident.run(
      callRequest("reviewer-a", report({siteId: "site-2"}))
    );
    const incident = await getIncident("incident-1");
    expect(incident.siteId).toBe("site-2");
    expect(incident.reportedByUid).toBe("reviewer-a");
  });

  test("a Foreman can only report at their own assigned sites", async () => {
    await seedSite("site-2");
    await seedReviewer("foreman-a", "foreman");
    await db.doc(`users/foreman-a/memberships/${ORG_A}`)
      .update({siteIds: ["site-1"]});

    await expect(
      createIncident.run(callRequest("foreman-a", report({siteId: "site-2"})))
    ).rejects.toThrow();
    await createIncident.run(callRequest("foreman-a", report()));
    expect((await getIncident("incident-1")).siteId).toBe("site-1");
  });

  test("a Site Manager cannot report at a site that does not exist",
    async () => {
      await expect(
        createIncident.run(
          callRequest("reviewer-a", report({siteId: "no-such-site"}))
        )
      ).rejects.toThrow(/does not exist/);
    });

  test("cannot report as someone else", async () => {
    await createIncident.run(
      callRequest("worker-1", report({reportedByUid: "someone-else"}))
    );
    expect((await getIncident("incident-1")).reportedByUid).toBe("worker-1");
  });

  test("creating with an id that already exists is refused", async () => {
    await seedIncident("incident-1");
    await expect(
      createIncident.run(callRequest("worker-1", report()))
    ).rejects.toThrow(/already exists/);
  });
});

describe("startIncidentInvestigation", () => {
  test("a reviewer can start an investigation, setting severity",
    async () => {
      await seedIncident("incident-1");

      const result = await startIncidentInvestigation.run(
        callRequest("reviewer-a", {
          organizationId: ORG_A,
          incidentId: "incident-1",
          severity: "moderate",
        })
      );

      expect(result.status).toBe("underInvestigation");
      const incident = await getIncident("incident-1");
      expect(incident.status).toBe("underInvestigation");
      expect(incident.severity).toBe("moderate");
      expect(incident.investigationStartedBy).toBe("reviewer-a");
    });

  test("a Foreman is refused — the Site Manager investigates", async () => {
    await seedIncident("incident-1");
    await seedReviewer("foreman-a", "foreman");
    await expect(
      startIncidentInvestigation.run(
        callRequest("foreman-a", {
          organizationId: ORG_A,
          incidentId: "incident-1",
          severity: "minor",
        })
      )
    ).rejects.toThrow();
    expect((await getIncident("incident-1")).status).toBe("reported");
  });

  test("a worker is refused", async () => {
    await seedIncident("incident-1");
    await expect(
      startIncidentInvestigation.run(
        callRequest("worker-1", {
          organizationId: ORG_A,
          incidentId: "incident-1",
          severity: "minor",
        })
      )
    ).rejects.toThrow();
    expect((await getIncident("incident-1")).status).toBe("reported");
  });

  test("rejects an invalid severity", async () => {
    await seedIncident("incident-1");
    await expect(
      startIncidentInvestigation.run(
        callRequest("reviewer-a", {
          organizationId: ORG_A,
          incidentId: "incident-1",
          severity: "catastrophic",
        })
      )
    ).rejects.toThrow(/severity must be one of/);
  });

  test("cannot restart an investigation already under way", async () => {
    await seedIncident("incident-1", {status: "underInvestigation"});
    await expect(
      startIncidentInvestigation.run(
        callRequest("reviewer-a", {
          organizationId: ORG_A,
          incidentId: "incident-1",
          severity: "minor",
        })
      )
    ).rejects.toThrow(/newly reported/);
  });
});

describe("linkIncidentCorrectiveAction", () => {
  test("a reviewer can raise several actions from one incident", async () => {
    await seedIncident("incident-1", {status: "underInvestigation"});

    const first = await linkIncidentCorrectiveAction.run(
      callRequest("reviewer-a", actionRequest())
    );
    const second = await linkIncidentCorrectiveAction.run(
      callRequest("reviewer-a", actionRequest({title: "Issue cut gloves"}))
    );

    const action = await getAction(first.id);
    expect(action.incidentId).toBe("incident-1");
    expect(action.hazardId).toBeNull();
    expect(action.meetingId).toBeNull();
    expect(action.siteId).toBe("site-1");
    expect(action.status).toBe("open");
    const incident = await getIncident("incident-1");
    expect(incident.correctiveActionIds).toEqual([first.id, second.id]);
  });

  test("stores the people's names and the evidence asked for", async () => {
    await seedIncident("incident-1", {status: "underInvestigation"});
    await db.doc("users/worker-2").update({name: "Mary Wanjiku"});

    const {id} = await linkIncidentCorrectiveAction.run(
      callRequest("reviewer-a", actionRequest({
        evidenceKinds: ["photo", "confirmation"],
        evidenceInstructions: "Photo of the fitted guards",
      }))
    );

    const action = await getAction(id);
    expect(action.assignedToName).toBe("Mary Wanjiku");
    expect(action.assignedByName).toBe("Test User");
    expect(action.evidenceRequired).toBe(true);
    expect(action.evidenceKinds).toEqual(["photo", "confirmation"]);
    expect(action.evidenceInstructions).toBe("Photo of the fitted guards");
    expect(action.evidencePhotos).toEqual([]);
  });

  test("rejects an unknown evidence kind", async () => {
    await seedIncident("incident-1", {status: "underInvestigation"});
    await expect(
      linkIncidentCorrectiveAction.run(
        callRequest("reviewer-a", actionRequest({evidenceKinds: ["video"]}))
      )
    ).rejects.toThrow(/evidenceKinds must be/);
  });

  test("refused before the investigation has started", async () => {
    await seedIncident("incident-1");
    await expect(
      linkIncidentCorrectiveAction.run(
        callRequest("reviewer-a", actionRequest())
      )
    ).rejects.toThrow(/under investigation/);
  });

  test("a worker is refused", async () => {
    await seedIncident("incident-1", {status: "underInvestigation"});
    await expect(
      linkIncidentCorrectiveAction.run(
        callRequest("worker-1", actionRequest())
      )
    ).rejects.toThrow();
  });

  test("createCorrectiveAction reaches the same path via incidentId",
    async () => {
      await seedIncident("incident-1", {status: "underInvestigation"});
      const result = await createCorrectiveAction.run(
        callRequest("reviewer-a", actionRequest())
      );
      expect((await getAction(result.id)).incidentId).toBe("incident-1");
    });

  test("createCorrectiveAction refuses incidentId together with hazardId",
    async () => {
      await seedIncident("incident-1", {status: "underInvestigation"});
      await expect(
        createCorrectiveAction.run(
          callRequest("reviewer-a", actionRequest({hazardId: "hazard-1"}))
        )
      ).rejects.toThrow(/Exactly one of meetingId, hazardId or incidentId/);
    });
});

describe("closeIncident", () => {
  test("a reviewer can close with a root cause", async () => {
    await seedIncident("incident-1", {status: "underInvestigation"});

    const result = await closeIncident.run(
      callRequest("reviewer-a", {
        organizationId: ORG_A,
        incidentId: "incident-1",
        rootCause: "No edge guards on stored sheet metal",
        closingNotes: "Guards fitted, toolbox talk held",
      })
    );

    expect(result.status).toBe("closed");
    const incident = await getIncident("incident-1");
    expect(incident.status).toBe("closed");
    expect(incident.rootCause).toBe("No edge guards on stored sheet metal");
    expect(incident.closingNotes).toBe("Guards fitted, toolbox talk held");
    expect(incident.closedBy).toBe("reviewer-a");
  });

  test("a root cause is required", async () => {
    await seedIncident("incident-1", {status: "underInvestigation"});
    await expect(
      closeIncident.run(
        callRequest("reviewer-a", {
          organizationId: ORG_A,
          incidentId: "incident-1",
        })
      )
    ).rejects.toThrow(/rootCause is required/);
  });

  test("refused before the investigation has started", async () => {
    await seedIncident("incident-1");
    await expect(
      closeIncident.run(
        callRequest("reviewer-a", {
          organizationId: ORG_A,
          incidentId: "incident-1",
          rootCause: "Unknown",
        })
      )
    ).rejects.toThrow(/must be investigated/);
  });

  test("refused while a corrective action is incomplete, allowed once done",
    async () => {
      await seedIncident("incident-1", {status: "underInvestigation"});
      const {id} = await linkIncidentCorrectiveAction.run(
        callRequest("reviewer-a", actionRequest())
      );
      const closeRequest = callRequest("reviewer-a", {
        organizationId: ORG_A,
        incidentId: "incident-1",
        rootCause: "No edge guards",
      });

      await expect(closeIncident.run(closeRequest))
        .rejects.toThrow(/not yet completed/);

      await db.doc(`organizations/${ORG_A}/corrective_actions/${id}`)
        .update({status: "completed"});
      await closeIncident.run(closeRequest);
      expect((await getIncident("incident-1")).status).toBe("closed");
    });

  test("cannot close twice", async () => {
    await seedIncident("incident-1", {status: "closed"});
    await expect(
      closeIncident.run(
        callRequest("reviewer-a", {
          organizationId: ORG_A,
          incidentId: "incident-1",
          rootCause: "Again",
        })
      )
    ).rejects.toThrow(/already been closed/);
  });

  test("a worker is refused", async () => {
    await seedIncident("incident-1", {status: "underInvestigation"});
    await expect(
      closeIncident.run(
        callRequest("worker-1", {
          organizationId: ORG_A,
          incidentId: "incident-1",
          rootCause: "x",
        })
      )
    ).rejects.toThrow();
  });
});
