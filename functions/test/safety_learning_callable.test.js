/**
 * Business-logic tests for `safety_learning_callable.ts` —
 * `createSafetyLearning`/`updateSafetyLearning` and
 * `createSafetyRequirement`/`updateSafetyRequirement`, including the Phase 1
 * `siteId`/`activityId` scoping added to safety requirements.
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
let createSafetyLearning;
let updateSafetyLearning;
let createSafetyRequirement;
let updateSafetyRequirement;
let addKnowledgeCheckQuestion;
let updateKnowledgeCheckQuestion;
let removeKnowledgeCheckQuestion;
let listKnowledgeCheckQuestions;

beforeAll(() => {
  process.env.GCLOUD_PROJECT = PROJECT_ID;
  if (!process.env.FIRESTORE_EMULATOR_HOST) {
    process.env.FIRESTORE_EMULATOR_HOST = "127.0.0.1:8080";
  }

  app = getApps()[0] ?? initializeApp({projectId: PROJECT_ID});
  db = getFirestore(app);

  ({
    createSafetyLearning,
    updateSafetyLearning,
    createSafetyRequirement,
    updateSafetyRequirement,
    addKnowledgeCheckQuestion,
    updateKnowledgeCheckQuestion,
    removeKnowledgeCheckQuestion,
    listKnowledgeCheckQuestions,
  } = require("../lib/safety_learning_callable"));
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

async function seedAdmin(uid) {
  await seedProfile(uid, {platformRole: "admin"});
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

async function seedProject(organizationId, id, overrides = {}) {
  await db.doc(`organizations/${organizationId}/projects/${id}`).set({
    organizationId,
    name: `Project ${id}`,
    code: `CODE-${id}`,
    status: "active",
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
    auth: uid ? {uid, token: {}} : undefined,
    data,
    rawRequest: {},
  };
}

async function getRequirement(organizationId, id) {
  const snapshot = await db
    .doc(`organizations/${organizationId}/safety_requirements/${id}`)
    .get();
  return snapshot.exists ? snapshot.data() : null;
}

async function getLearning(organizationId, id) {
  const snapshot = await db
    .doc(`organizations/${organizationId}/safety_learning/${id}`)
    .get();
  return snapshot.exists ? snapshot.data() : null;
}

beforeEach(async () => {
  await clearFirestore();
});

describe("createSafetyRequirement (Admin, or Site Manager of the org)", () => {
  test("an Admin creates an organization-wide requirement (no site/activity " +
    "scope)", async () => {
    await seedAdmin("admin-1");

    const result = await createSafetyRequirement.run(
      callRequest("admin-1", {
        organizationId: ORG_A,
        name: "General Induction",
        category: "Induction",
        risk: "medium",
      })
    );

    const requirement = await getRequirement(ORG_A, result.id);
    expect(requirement.siteId).toBeUndefined();
    expect(requirement.activityId).toBeUndefined();
  });

  test("gatesAttendance defaults to true when omitted at creation",
    async () => {
      await seedAdmin("admin-1");

      const result = await createSafetyRequirement.run(
        callRequest("admin-1", {
          organizationId: ORG_A,
          name: "General Induction",
          category: "Induction",
          risk: "medium",
        })
      );

      const requirement = await getRequirement(ORG_A, result.id);
      expect(requirement.gatesAttendance).toBe(true);
    });

  test("an Admin can explicitly create a non-gating requirement",
    async () => {
      await seedAdmin("admin-1");

      const result = await createSafetyRequirement.run(
        callRequest("admin-1", {
          organizationId: ORG_A,
          name: "General Induction",
          category: "Induction",
          risk: "medium",
          gatesAttendance: false,
        })
      );

      const requirement = await getRequirement(ORG_A, result.id);
      expect(requirement.gatesAttendance).toBe(false);
    });

  test("is refused when gatesAttendance is not a boolean", async () => {
    await seedAdmin("admin-1");

    await expect(
      createSafetyRequirement.run(
        callRequest("admin-1", {
          organizationId: ORG_A,
          name: "General Induction",
          category: "Induction",
          risk: "medium",
          gatesAttendance: "yes",
        })
      )
    ).rejects.toThrow(/gatesAttendance must be a boolean/);
  });

  test("an Admin creates a site-scoped requirement", async () => {
    await seedAdmin("admin-1");
    await seedSite(ORG_A, "site-1");

    const result = await createSafetyRequirement.run(
      callRequest("admin-1", {
        organizationId: ORG_A,
        name: "Site Induction",
        category: "Induction",
        risk: "medium",
        siteId: "site-1",
      })
    );

    const requirement = await getRequirement(ORG_A, result.id);
    expect(requirement.siteId).toBe("site-1");
    expect(requirement.activityId).toBeUndefined();
  });

  test("an Admin creates an activity-scoped requirement", async () => {
    await seedAdmin("admin-1");
    await seedSite(ORG_A, "site-1");
    await seedActivity(ORG_A, "activity-1", "site-1");

    const result = await createSafetyRequirement.run(
      callRequest("admin-1", {
        organizationId: ORG_A,
        name: "Activity Briefing",
        category: "Briefing",
        risk: "high",
        activityId: "activity-1",
      })
    );

    const requirement = await getRequirement(ORG_A, result.id);
    expect(requirement.activityId).toBe("activity-1");
    expect(requirement.siteId).toBeUndefined();
  });

  test("an Admin creates a project-scoped requirement", async () => {
    await seedAdmin("admin-1");
    await seedProject(ORG_A, "project-1");

    const result = await createSafetyRequirement.run(
      callRequest("admin-1", {
        organizationId: ORG_A,
        name: "Project Induction",
        category: "Induction",
        risk: "medium",
        projectId: "project-1",
      })
    );

    const requirement = await getRequirement(ORG_A, result.id);
    expect(requirement.projectId).toBe("project-1");
    expect(requirement.siteId).toBeUndefined();
    expect(requirement.activityId).toBeUndefined();
  });

  test("is refused when projectId and siteId are both given", async () => {
    await seedAdmin("admin-1");
    await seedProject(ORG_A, "project-1");
    await seedSite(ORG_A, "site-1");

    await expect(
      createSafetyRequirement.run(
        callRequest("admin-1", {
          organizationId: ORG_A,
          name: "Bad Requirement",
          category: "General",
          risk: "low",
          projectId: "project-1",
          siteId: "site-1",
        })
      )
    ).rejects.toThrow(/not more than one/);
  });

  test("is refused when both siteId and activityId are given", async () => {
    await seedAdmin("admin-1");
    await seedSite(ORG_A, "site-1");
    await seedActivity(ORG_A, "activity-1", "site-1");

    await expect(
      createSafetyRequirement.run(
        callRequest("admin-1", {
          organizationId: ORG_A,
          name: "Bad Requirement",
          category: "General",
          risk: "low",
          siteId: "site-1",
          activityId: "activity-1",
        })
      )
    ).rejects.toThrow(/not more than one/);
  });

  test("is refused when projectId does not exist", async () => {
    await seedAdmin("admin-1");

    await expect(
      createSafetyRequirement.run(
        callRequest("admin-1", {
          organizationId: ORG_A,
          name: "Bad Requirement",
          category: "General",
          risk: "low",
          projectId: "no-such-project",
        })
      )
    ).rejects.toThrow(/project does not exist/);
  });

  test("is refused when siteId does not exist", async () => {
    await seedAdmin("admin-1");

    await expect(
      createSafetyRequirement.run(
        callRequest("admin-1", {
          organizationId: ORG_A,
          name: "Bad Requirement",
          category: "General",
          risk: "low",
          siteId: "no-such-site",
        })
      )
    ).rejects.toThrow(/site does not exist/);
  });

  test("is refused when activityId does not exist", async () => {
    await seedAdmin("admin-1");

    await expect(
      createSafetyRequirement.run(
        callRequest("admin-1", {
          organizationId: ORG_A,
          name: "Bad Requirement",
          category: "General",
          risk: "low",
          activityId: "no-such-activity",
        })
      )
    ).rejects.toThrow(/activity does not exist/);
  });

  test("a Site Manager of this organization creates a safety requirement",
    async () => {
      await seedProfile("sm-1");
      await seedMembership("sm-1", ORG_A, "siteManager");

      const result = await createSafetyRequirement.run(
        callRequest("sm-1", {
          organizationId: ORG_A,
          name: "General Induction",
          category: "Induction",
          risk: "medium",
        })
      );

      const requirement = await getRequirement(ORG_A, result.id);
      expect(requirement.name).toBe("General Induction");
      expect(requirement.createdBy).toBe("sm-1");
    });

  test("a Site Manager of a DIFFERENT organization cannot create a safety " +
    "requirement in this one", async () => {
    await seedProfile("sm-2");
    await seedMembership("sm-2", "org-beta", "siteManager");

    await expect(
      createSafetyRequirement.run(
        callRequest("sm-2", {
          organizationId: ORG_A,
          name: "General Induction",
          category: "Induction",
          risk: "medium",
        })
      )
    ).rejects.toThrow(/permission/);
  });

  test("a Worker cannot create a safety requirement", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker");

    await expect(
      createSafetyRequirement.run(
        callRequest("worker-1", {
          organizationId: ORG_A,
          name: "General Induction",
          category: "Induction",
          risk: "medium",
        })
      )
    ).rejects.toThrow(/permission/);
  });

  test("an unauthenticated caller cannot create a safety requirement",
    async () => {
      await expect(
        createSafetyRequirement.run(
          callRequest(null, {
            organizationId: ORG_A,
            name: "General Induction",
            category: "Induction",
            risk: "medium",
          })
        )
      ).rejects.toThrow(/permission/);
    });
});

describe("updateSafetyRequirement scope changes (Admin, or Site Manager " +
  "of the org)", () => {
  test("an Admin can move a requirement from organization-wide to site-scoped",
    async () => {
      await seedAdmin("admin-1");
      await seedSite(ORG_A, "site-1");
      const created = await createSafetyRequirement.run(
        callRequest("admin-1", {
          organizationId: ORG_A,
          name: "Requirement",
          category: "General",
          risk: "low",
        })
      );

      await updateSafetyRequirement.run(
        callRequest("admin-1", {
          organizationId: ORG_A,
          id: created.id,
          siteId: "site-1",
        })
      );

      const requirement = await getRequirement(ORG_A, created.id);
      expect(requirement.siteId).toBe("site-1");
    });

  test("an Admin can clear a site scope back to organization-wide with an " +
    "empty string", async () => {
    await seedAdmin("admin-1");
    await seedSite(ORG_A, "site-1");
    const created = await createSafetyRequirement.run(
      callRequest("admin-1", {
        organizationId: ORG_A,
        name: "Requirement",
        category: "General",
        risk: "low",
        siteId: "site-1",
      })
    );

    await updateSafetyRequirement.run(
      callRequest("admin-1", {
        organizationId: ORG_A,
        id: created.id,
        siteId: "",
      })
    );

    const requirement = await getRequirement(ORG_A, created.id);
    expect(requirement.siteId).toBeUndefined();
  });

  test("an Admin can move a requirement from organization-wide to " +
    "project-scoped", async () => {
    await seedAdmin("admin-1");
    await seedProject(ORG_A, "project-1");
    const created = await createSafetyRequirement.run(
      callRequest("admin-1", {
        organizationId: ORG_A,
        name: "Requirement",
        category: "General",
        risk: "low",
      })
    );

    await updateSafetyRequirement.run(
      callRequest("admin-1", {
        organizationId: ORG_A,
        id: created.id,
        projectId: "project-1",
      })
    );

    const requirement = await getRequirement(ORG_A, created.id);
    expect(requirement.projectId).toBe("project-1");
  });

  test("an Admin can turn off gatesAttendance on an existing requirement",
    async () => {
      await seedAdmin("admin-1");
      const created = await createSafetyRequirement.run(
        callRequest("admin-1", {
          organizationId: ORG_A,
          name: "Requirement",
          category: "General",
          risk: "low",
        })
      );
      expect((await getRequirement(ORG_A, created.id)).gatesAttendance)
        .toBe(true);

      await updateSafetyRequirement.run(
        callRequest("admin-1", {
          organizationId: ORG_A,
          id: created.id,
          gatesAttendance: false,
        })
      );

      const requirement = await getRequirement(ORG_A, created.id);
      expect(requirement.gatesAttendance).toBe(false);
    });

  test("an Admin can turn gatesAttendance back on", async () => {
    await seedAdmin("admin-1");
    const created = await createSafetyRequirement.run(
      callRequest("admin-1", {
        organizationId: ORG_A,
        name: "Requirement",
        category: "General",
        risk: "low",
        gatesAttendance: false,
      })
    );

    await updateSafetyRequirement.run(
      callRequest("admin-1", {
        organizationId: ORG_A,
        id: created.id,
        gatesAttendance: true,
      })
    );

    const requirement = await getRequirement(ORG_A, created.id);
    expect(requirement.gatesAttendance).toBe(true);
  });

  test("updating unrelated fields does not change gatesAttendance",
    async () => {
      await seedAdmin("admin-1");
      const created = await createSafetyRequirement.run(
        callRequest("admin-1", {
          organizationId: ORG_A,
          name: "Requirement",
          category: "General",
          risk: "low",
          gatesAttendance: false,
        })
      );

      await updateSafetyRequirement.run(
        callRequest("admin-1", {
          organizationId: ORG_A,
          id: created.id,
          name: "Renamed Requirement",
        })
      );

      const requirement = await getRequirement(ORG_A, created.id);
      expect(requirement.name).toBe("Renamed Requirement");
      expect(requirement.gatesAttendance).toBe(false);
    });

  test("an Admin can clear a project scope back to organization-wide with " +
    "an empty string", async () => {
    await seedAdmin("admin-1");
    await seedProject(ORG_A, "project-1");
    const created = await createSafetyRequirement.run(
      callRequest("admin-1", {
        organizationId: ORG_A,
        name: "Requirement",
        category: "General",
        risk: "low",
        projectId: "project-1",
      })
    );

    await updateSafetyRequirement.run(
      callRequest("admin-1", {
        organizationId: ORG_A,
        id: created.id,
        projectId: "",
      })
    );

    const requirement = await getRequirement(ORG_A, created.id);
    expect(requirement.projectId).toBeUndefined();
  });

  test("a non-Admin cannot update a safety requirement", async () => {
    await seedAdmin("admin-1");
    const created = await createSafetyRequirement.run(
      callRequest("admin-1", {
        organizationId: ORG_A,
        name: "Requirement",
        category: "General",
        risk: "low",
      })
    );
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker");

    await expect(
      updateSafetyRequirement.run(
        callRequest("worker-1", {
          organizationId: ORG_A,
          id: created.id,
          name: "Hijacked",
        })
      )
    ).rejects.toThrow(/permission/);
  });
});

describe("requiredBeforeWork on create/update", () => {
  const base = {
    organizationId: ORG_A,
    name: "Requirement",
    category: "General",
    risk: "low",
  };

  test("defaults to false when omitted at creation, independently of " +
    "gatesAttendance's own true default", async () => {
    await seedAdmin("admin-1");
    const created = await createSafetyRequirement.run(
      callRequest("admin-1", base)
    );

    const requirement = await getRequirement(ORG_A, created.id);
    expect(requirement.requiredBeforeWork).toBe(false);
    expect(requirement.gatesAttendance).toBe(true);
  });

  test("create with true stores true without changing gatesAttendance",
    async () => {
      await seedAdmin("admin-1");
      const created = await createSafetyRequirement.run(
        callRequest("admin-1", {
          ...base,
          requiredBeforeWork: true,
          gatesAttendance: false,
        })
      );

      const requirement = await getRequirement(ORG_A, created.id);
      expect(requirement.requiredBeforeWork).toBe(true);
      expect(requirement.gatesAttendance).toBe(false);
    });

  test("create with explicit false stores false", async () => {
    await seedAdmin("admin-1");
    const created = await createSafetyRequirement.run(
      callRequest("admin-1", {...base, requiredBeforeWork: false})
    );

    expect((await getRequirement(ORG_A, created.id)).requiredBeforeWork)
      .toBe(false);
  });

  test("is refused when requiredBeforeWork is not a boolean", async () => {
    await seedAdmin("admin-1");

    await expect(
      createSafetyRequirement.run(
        callRequest("admin-1", {...base, requiredBeforeWork: "yes"})
      )
    ).rejects.toThrow(/requiredBeforeWork must be a boolean/);
  });

  test("update true -> false", async () => {
    await seedAdmin("admin-1");
    const created = await createSafetyRequirement.run(
      callRequest("admin-1", {...base, requiredBeforeWork: true})
    );

    await updateSafetyRequirement.run(
      callRequest("admin-1", {
        organizationId: ORG_A,
        id: created.id,
        requiredBeforeWork: false,
      })
    );

    expect((await getRequirement(ORG_A, created.id)).requiredBeforeWork)
      .toBe(false);
  });

  test("update false -> true leaves gatesAttendance untouched", async () => {
    await seedAdmin("admin-1");
    const created = await createSafetyRequirement.run(
      callRequest("admin-1", {...base, gatesAttendance: false})
    );

    await updateSafetyRequirement.run(
      callRequest("admin-1", {
        organizationId: ORG_A,
        id: created.id,
        requiredBeforeWork: true,
      })
    );

    const requirement = await getRequirement(ORG_A, created.id);
    expect(requirement.requiredBeforeWork).toBe(true);
    expect(requirement.gatesAttendance).toBe(false);
  });

  test("updating unrelated fields does not change requiredBeforeWork",
    async () => {
      await seedAdmin("admin-1");
      const created = await createSafetyRequirement.run(
        callRequest("admin-1", {...base, requiredBeforeWork: true})
      );

      await updateSafetyRequirement.run(
        callRequest("admin-1", {
          organizationId: ORG_A,
          id: created.id,
          name: "Renamed",
          gatesAttendance: false,
        })
      );

      const requirement = await getRequirement(ORG_A, created.id);
      expect(requirement.name).toBe("Renamed");
      expect(requirement.requiredBeforeWork).toBe(true);
    });

  test("update refuses a non-boolean requiredBeforeWork", async () => {
    await seedAdmin("admin-1");
    const created = await createSafetyRequirement.run(
      callRequest("admin-1", base)
    );

    await expect(
      updateSafetyRequirement.run(
        callRequest("admin-1", {
          organizationId: ORG_A,
          id: created.id,
          requiredBeforeWork: 1,
        })
      )
    ).rejects.toThrow(/requiredBeforeWork must be a boolean/);
  });
});

describe("learningSettings (per-lesson configuration) on create/update", () => {
  const base = {
    organizationId: ORG_A,
    name: "Working at Height",
    category: "Height",
    risk: "high",
  };

  async function seedLessons(...ids) {
    for (const id of ids) {
      await db.doc(`organizations/${ORG_A}/safety_learning/${id}`).set({
        organizationId: ORG_A,
        title: `Lesson ${id}`,
        type: "document",
        contentReference: `ref-${id}`,
        status: "active",
        createdAt: new Date(),
        updatedAt: new Date(),
      });
    }
  }

  const on = {gatesAttendance: true, requiredBeforeWork: true};
  const gateOnly = {gatesAttendance: true, requiredBeforeWork: false};
  const preOnly = {gatesAttendance: false, requiredBeforeWork: true};
  const off = {gatesAttendance: false, requiredBeforeWork: false};

  async function createWith(learningSettings, ids = ["l1", "l2", "l3", "l4"]) {
    return createSafetyRequirement.run(
      callRequest("admin-1", {
        ...base,
        requiredLearningIds: ids,
        learningSettings,
      })
    );
  }

  test("create stores all four flag combinations, one per lesson",
    async () => {
      await seedAdmin("admin-1");
      await seedLessons("l1", "l2", "l3", "l4");

      const created = await createWith({
        l1: on, l2: gateOnly, l3: preOnly, l4: off,
      });

      const requirement = await getRequirement(ORG_A, created.id);
      expect(requirement.requiredLearningIds).toEqual(["l1", "l2", "l3", "l4"]);
      expect(requirement.learningSettings).toEqual({
        l1: on, l2: gateOnly, l3: preOnly, l4: off,
      });
    });

  test("create without learningSettings writes no map (legacy fallback)",
    async () => {
      await seedAdmin("admin-1");
      await seedLessons("l1");

      const created = await createSafetyRequirement.run(
        callRequest("admin-1", {...base, requiredLearningIds: ["l1"]})
      );

      expect((await getRequirement(ORG_A, created.id)).learningSettings)
        .toBeUndefined();
    });

  test("rejects a setting for a lesson that is not selected", async () => {
    await seedAdmin("admin-1");
    await seedLessons("l1");

    await expect(
      createWith({l1: off, l9: on}, ["l1"])
    ).rejects.toThrow(/l9 is not a selected learning item/);
  });

  test("rejects settings that miss a selected lesson", async () => {
    await seedAdmin("admin-1");
    await seedLessons("l1", "l2");

    await expect(
      createWith({l1: off}, ["l1", "l2"])
    ).rejects.toThrow(/missing: l2/);
  });

  test("rejects a non-object, a partial entry, a non-boolean and an " +
    "unknown field", async () => {
    await seedAdmin("admin-1");
    await seedLessons("l1");

    await expect(createWith(["l1"], ["l1"]))
      .rejects.toThrow(/must be an object keyed by learning id/);
    await expect(createWith({l1: {gatesAttendance: true}}, ["l1"]))
      .rejects.toThrow(/must set gatesAttendance and requiredBeforeWork/);
    await expect(
      createWith({l1: {gatesAttendance: "yes", requiredBeforeWork: false}},
        ["l1"])
    ).rejects.toThrow(/must set gatesAttendance and requiredBeforeWork/);
    await expect(
      createWith({l1: {...off, expiresAt: 1}}, ["l1"])
    ).rejects.toThrow(/expiresAt is not a recognised setting/);
  });

  test("update changes one lesson's configuration", async () => {
    await seedAdmin("admin-1");
    await seedLessons("l1", "l2");
    const created = await createWith({l1: off, l2: off}, ["l1", "l2"]);

    await updateSafetyRequirement.run(
      callRequest("admin-1", {
        organizationId: ORG_A,
        id: created.id,
        learningSettings: {l1: gateOnly, l2: off},
      })
    );

    expect((await getRequirement(ORG_A, created.id)).learningSettings)
      .toEqual({l1: gateOnly, l2: off});
  });

  test("update settings are validated against the STORED lessons when " +
    "requiredLearningIds is not being changed", async () => {
    await seedAdmin("admin-1");
    await seedLessons("l1", "l2");
    const created = await createWith({l1: off, l2: off}, ["l1", "l2"]);

    await expect(
      updateSafetyRequirement.run(
        callRequest("admin-1", {
          organizationId: ORG_A,
          id: created.id,
          learningSettings: {l1: on},
        })
      )
    ).rejects.toThrow(/missing: l2/);
  });

  test("removing a lesson drops its settings; adding one defaults it to " +
    "both off", async () => {
    await seedAdmin("admin-1");
    await seedLessons("l1", "l2", "l3");
    const created = await createWith({l1: on, l2: preOnly}, ["l1", "l2"]);

    await updateSafetyRequirement.run(
      callRequest("admin-1", {
        organizationId: ORG_A,
        id: created.id,
        requiredLearningIds: ["l1", "l3"],
      })
    );

    const requirement = await getRequirement(ORG_A, created.id);
    expect(requirement.requiredLearningIds).toEqual(["l1", "l3"]);
    expect(requirement.learningSettings).toEqual({l1: on, l3: off});
  });

  test("changing lessons on a legacy requirement (no map) keeps it legacy",
    async () => {
      await seedAdmin("admin-1");
      await seedLessons("l1", "l2");
      const created = await createSafetyRequirement.run(
        callRequest("admin-1", {...base, requiredLearningIds: ["l1"]})
      );

      await updateSafetyRequirement.run(
        callRequest("admin-1", {
          organizationId: ORG_A,
          id: created.id,
          requiredLearningIds: ["l1", "l2"],
        })
      );

      const requirement = await getRequirement(ORG_A, created.id);
      expect(requirement.learningSettings).toBeUndefined();
      expect(requirement.gatesAttendance).toBe(true);
    });

  test("an unrelated update leaves learningSettings untouched", async () => {
    await seedAdmin("admin-1");
    await seedLessons("l1");
    const created = await createWith({l1: preOnly}, ["l1"]);

    await updateSafetyRequirement.run(
      callRequest("admin-1", {
        organizationId: ORG_A,
        id: created.id,
        name: "Renamed",
      })
    );

    const requirement = await getRequirement(ORG_A, created.id);
    expect(requirement.name).toBe("Renamed");
    expect(requirement.learningSettings).toEqual({l1: preOnly});
  });
});

describe("createSafetyLearning (Admin only, smoke test)", () => {
  test("a non-Admin cannot create a safety learning item", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker");

    await expect(
      createSafetyLearning.run(
        callRequest("worker-1", {
          organizationId: ORG_A,
          title: "Video",
          type: "video",
          contentReference: "https://example.com/video.mp4",
        })
      )
    ).rejects.toThrow(/permission/);
  });
});

describe("createSafetyLearning/updateSafetyLearning (watch time)", () => {
  test("an Admin creates a video item with a minimum watch time", async () => {
    await seedAdmin("admin-1");

    const result = await createSafetyLearning.run(
      callRequest("admin-1", {
        organizationId: ORG_A,
        title: "Working at Height",
        type: "video",
        contentReference: "https://example.com/video.mp4",
        minimumWatchSeconds: 90,
      })
    );

    const learning = await getLearning(ORG_A, result.id);
    expect(learning.minimumWatchSeconds).toBe(90);
  });

  test("omitting minimumWatchSeconds leaves it unset — existing items are " +
    "unaffected", async () => {
    await seedAdmin("admin-1");

    const result = await createSafetyLearning.run(
      callRequest("admin-1", {
        organizationId: ORG_A,
        title: "Working at Height",
        type: "video",
        contentReference: "https://example.com/video.mp4",
      })
    );

    const learning = await getLearning(ORG_A, result.id);
    expect(learning.minimumWatchSeconds).toBeUndefined();
  });

  test("is refused for a negative minimumWatchSeconds", async () => {
    await seedAdmin("admin-1");

    await expect(
      createSafetyLearning.run(
        callRequest("admin-1", {
          organizationId: ORG_A,
          title: "Working at Height",
          type: "video",
          contentReference: "https://example.com/video.mp4",
          minimumWatchSeconds: -5,
        })
      )
    ).rejects.toThrow(/non-negative/);
  });

  test("an Admin can update the minimum watch time on an existing item",
    async () => {
      await seedAdmin("admin-1");
      const created = await createSafetyLearning.run(
        callRequest("admin-1", {
          organizationId: ORG_A,
          title: "Working at Height",
          type: "video",
          contentReference: "https://example.com/video.mp4",
          minimumWatchSeconds: 30,
        })
      );

      await updateSafetyLearning.run(
        callRequest("admin-1", {
          organizationId: ORG_A,
          id: created.id,
          minimumWatchSeconds: 60,
        })
      );

      const learning = await getLearning(ORG_A, created.id);
      expect(learning.minimumWatchSeconds).toBe(60);
    });

  test("an Admin can clear the minimum watch time back to \"no minimum\" " +
    "with null", async () => {
    await seedAdmin("admin-1");
    const created = await createSafetyLearning.run(
      callRequest("admin-1", {
        organizationId: ORG_A,
        title: "Working at Height",
        type: "video",
        contentReference: "https://example.com/video.mp4",
        minimumWatchSeconds: 30,
      })
    );

    await updateSafetyLearning.run(
      callRequest("admin-1", {
        organizationId: ORG_A,
        id: created.id,
        minimumWatchSeconds: null,
      })
    );

    const learning = await getLearning(ORG_A, created.id);
    expect(learning.minimumWatchSeconds).toBeUndefined();
  });

  test("a non-Admin cannot set a minimum watch time", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker");

    await expect(
      createSafetyLearning.run(
        callRequest("worker-1", {
          organizationId: ORG_A,
          title: "Working at Height",
          type: "video",
          contentReference: "https://example.com/video.mp4",
          minimumWatchSeconds: 30,
        })
      )
    ).rejects.toThrow(/permission/);
  });
});

describe("knowledge-check question CRUD", () => {
  async function seedLearningItem(id = "l1", overrides = {}) {
    await db.doc(`organizations/${ORG_A}/safety_learning/${id}`).set({
      organizationId: ORG_A,
      title: "Working at Height",
      type: "video",
      contentReference: "https://example.com/video.mp4",
      status: "active",
      createdAt: new Date(),
      updatedAt: new Date(),
      ...overrides,
    });
  }

  const validOptions = [
    {id: "a", text: "Option A"},
    {id: "b", text: "Option B"},
    {id: "c", text: "Option C"},
  ];

  test("an Admin adds a question with valid multiple-choice options",
    async () => {
      await seedAdmin("admin-1");
      await seedLearningItem();

      const result = await addKnowledgeCheckQuestion.run(
        callRequest("admin-1", {
          organizationId: ORG_A,
          learningId: "l1",
          prompt: "What must you wear at height?",
          options: validOptions,
          correctOptionId: "a",
          order: 0,
        })
      );

      const snapshot = await db
        .doc(
          `organizations/${ORG_A}/safety_learning/l1/` +
            `knowledge_check_questions/${result.id}`
        )
        .get();
      expect(snapshot.exists).toBe(true);
      expect(snapshot.data().correctOptionId).toBe("a");
      expect(snapshot.data().options).toEqual(validOptions);
    });

  test("is refused with fewer than 2 options", async () => {
    await seedAdmin("admin-1");
    await seedLearningItem();

    await expect(
      addKnowledgeCheckQuestion.run(
        callRequest("admin-1", {
          organizationId: ORG_A,
          learningId: "l1",
          prompt: "Q",
          options: [{id: "a", text: "Only one"}],
          correctOptionId: "a",
          order: 0,
        })
      )
    ).rejects.toThrow(/between 2 and 6/);
  });

  test("is refused with more than 6 options", async () => {
    await seedAdmin("admin-1");
    await seedLearningItem();

    await expect(
      addKnowledgeCheckQuestion.run(
        callRequest("admin-1", {
          organizationId: ORG_A,
          learningId: "l1",
          prompt: "Q",
          options: Array.from({length: 7}, (_, i) => ({
            id: `opt-${i}`,
            text: `Option ${i}`,
          })),
          correctOptionId: "opt-0",
          order: 0,
        })
      )
    ).rejects.toThrow(/between 2 and 6/);
  });

  test("is refused when correctOptionId does not match any option",
    async () => {
      await seedAdmin("admin-1");
      await seedLearningItem();

      await expect(
        addKnowledgeCheckQuestion.run(
          callRequest("admin-1", {
            organizationId: ORG_A,
            learningId: "l1",
            prompt: "Q",
            options: validOptions,
            correctOptionId: "not-an-option",
            order: 0,
          })
        )
      ).rejects.toThrow(/correctOptionId must match/);
    });

  test("is refused when option ids are not unique", async () => {
    await seedAdmin("admin-1");
    await seedLearningItem();

    await expect(
      addKnowledgeCheckQuestion.run(
        callRequest("admin-1", {
          organizationId: ORG_A,
          learningId: "l1",
          prompt: "Q",
          options: [
            {id: "a", text: "First"},
            {id: "a", text: "Duplicate id"},
          ],
          correctOptionId: "a",
          order: 0,
        })
      )
    ).rejects.toThrow(/unique/);
  });

  test("is refused for a learningId that does not exist", async () => {
    await seedAdmin("admin-1");

    await expect(
      addKnowledgeCheckQuestion.run(
        callRequest("admin-1", {
          organizationId: ORG_A,
          learningId: "no-such-item",
          prompt: "Q",
          options: validOptions,
          correctOptionId: "a",
          order: 0,
        })
      )
    ).rejects.toThrow(/no longer exists/);
  });

  test("a non-Admin cannot add a question", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker");
    await seedLearningItem();

    await expect(
      addKnowledgeCheckQuestion.run(
        callRequest("worker-1", {
          organizationId: ORG_A,
          learningId: "l1",
          prompt: "Q",
          options: validOptions,
          correctOptionId: "a",
          order: 0,
        })
      )
    ).rejects.toThrow(/permission/);
  });

  test("an Admin updates an existing question, including its options and " +
    "correct answer", async () => {
    await seedAdmin("admin-1");
    await seedLearningItem();
    const created = await addKnowledgeCheckQuestion.run(
      callRequest("admin-1", {
        organizationId: ORG_A,
        learningId: "l1",
        prompt: "Original",
        options: validOptions,
        correctOptionId: "a",
        order: 0,
      })
    );

    await updateKnowledgeCheckQuestion.run(
      callRequest("admin-1", {
        organizationId: ORG_A,
        learningId: "l1",
        questionId: created.id,
        prompt: "Updated",
        options: [
          {id: "x", text: "New A"},
          {id: "y", text: "New B"},
        ],
        correctOptionId: "y",
        order: 1,
      })
    );

    const snapshot = await db
      .doc(
        `organizations/${ORG_A}/safety_learning/l1/` +
          `knowledge_check_questions/${created.id}`
      )
      .get();
    expect(snapshot.data().prompt).toBe("Updated");
    expect(snapshot.data().correctOptionId).toBe("y");
  });

  test("update is refused when the new correctOptionId does not match the " +
    "new options", async () => {
    await seedAdmin("admin-1");
    await seedLearningItem();
    const created = await addKnowledgeCheckQuestion.run(
      callRequest("admin-1", {
        organizationId: ORG_A,
        learningId: "l1",
        prompt: "Original",
        options: validOptions,
        correctOptionId: "a",
        order: 0,
      })
    );

    await expect(
      updateKnowledgeCheckQuestion.run(
        callRequest("admin-1", {
          organizationId: ORG_A,
          learningId: "l1",
          questionId: created.id,
          prompt: "Updated",
          options: [
            {id: "x", text: "New A"},
            {id: "y", text: "New B"},
          ],
          // Stale id from the OLD option set — must be refused, not
          // silently accepted against the new set.
          correctOptionId: "a",
          order: 0,
        })
      )
    ).rejects.toThrow(/correctOptionId must match/);
  });

  test("a non-Admin cannot update a question", async () => {
    await seedAdmin("admin-1");
    await seedLearningItem();
    const created = await addKnowledgeCheckQuestion.run(
      callRequest("admin-1", {
        organizationId: ORG_A,
        learningId: "l1",
        prompt: "Original",
        options: validOptions,
        correctOptionId: "a",
        order: 0,
      })
    );
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker");

    await expect(
      updateKnowledgeCheckQuestion.run(
        callRequest("worker-1", {
          organizationId: ORG_A,
          learningId: "l1",
          questionId: created.id,
          prompt: "Hijacked",
          options: validOptions,
          correctOptionId: "a",
          order: 0,
        })
      )
    ).rejects.toThrow(/permission/);
  });

  test("an Admin removes a question outright", async () => {
    await seedAdmin("admin-1");
    await seedLearningItem();
    const created = await addKnowledgeCheckQuestion.run(
      callRequest("admin-1", {
        organizationId: ORG_A,
        learningId: "l1",
        prompt: "Original",
        options: validOptions,
        correctOptionId: "a",
        order: 0,
      })
    );

    await removeKnowledgeCheckQuestion.run(
      callRequest("admin-1", {
        organizationId: ORG_A,
        learningId: "l1",
        questionId: created.id,
      })
    );

    const snapshot = await db
      .doc(
        `organizations/${ORG_A}/safety_learning/l1/` +
          `knowledge_check_questions/${created.id}`
      )
      .get();
    expect(snapshot.exists).toBe(false);
  });

  test("a non-Admin cannot remove a question", async () => {
    await seedAdmin("admin-1");
    await seedLearningItem();
    const created = await addKnowledgeCheckQuestion.run(
      callRequest("admin-1", {
        organizationId: ORG_A,
        learningId: "l1",
        prompt: "Original",
        options: validOptions,
        correctOptionId: "a",
        order: 0,
      })
    );
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker");

    await expect(
      removeKnowledgeCheckQuestion.run(
        callRequest("worker-1", {
          organizationId: ORG_A,
          learningId: "l1",
          questionId: created.id,
        })
      )
    ).rejects.toThrow(/permission/);
  });

  test("an Admin lists every question, INCLUDING correctOptionId",
    async () => {
      await seedAdmin("admin-1");
      await seedLearningItem();
      await addKnowledgeCheckQuestion.run(
        callRequest("admin-1", {
          organizationId: ORG_A,
          learningId: "l1",
          prompt: "Q1",
          options: validOptions,
          correctOptionId: "a",
          order: 1,
        })
      );
      await addKnowledgeCheckQuestion.run(
        callRequest("admin-1", {
          organizationId: ORG_A,
          learningId: "l1",
          prompt: "Q0",
          options: validOptions,
          correctOptionId: "b",
          order: 0,
        })
      );

      const result = await listKnowledgeCheckQuestions.run(
        callRequest("admin-1", {organizationId: ORG_A, learningId: "l1"})
      );

      expect(result.questions).toHaveLength(2);
      // Ordered by `order` — Q0 (order 0) before Q1 (order 1).
      expect(result.questions[0].prompt).toBe("Q0");
      expect(result.questions[0].correctOptionId).toBe("b");
      expect(result.questions[1].prompt).toBe("Q1");
      expect(result.questions[1].correctOptionId).toBe("a");
    });

  test("a non-Admin cannot list questions", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker");
    await seedLearningItem();

    await expect(
      listKnowledgeCheckQuestions.run(
        callRequest("worker-1", {organizationId: ORG_A, learningId: "l1"})
      )
    ).rejects.toThrow(/permission/);
  });
});
