/**
 * Business-logic tests for `risk_assessment_callable.ts` — Activity Hazard
 * Analyses: drafting, acceptance by someone other than the preparer,
 * revisions superseding the accepted version, and discarding drafts. Run
 * against the Firestore emulator via `npm run test:callables`.
 */

const {initializeApp, getApps, deleteApp} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");

const PROJECT_ID = "jva-safety-rules-test";
const ORG_A = "org-alpha";

let app;
let db;
let fns;

beforeAll(() => {
  process.env.GCLOUD_PROJECT = PROJECT_ID;
  if (!process.env.FIRESTORE_EMULATOR_HOST) {
    process.env.FIRESTORE_EMULATOR_HOST = "127.0.0.1:8080";
  }
  app = getApps()[0] ?? initializeApp({projectId: PROJECT_ID});
  db = getFirestore(app);
  fns = require("../lib/risk_assessment_callable");
});

afterAll(async () => {
  if (app) await deleteApp(app);
});

async function clearFirestore() {
  const collections = await db.listCollections();
  await Promise.all(collections.map((c) => db.recursiveDelete(c)));
}

async function seedPerson(uid, role, name) {
  await db.doc(`users/${uid}`).set({
    uid, name, email: `${uid}@example.com`, accountStatus: "active",
  });
  await db.doc(`users/${uid}/memberships/${ORG_A}`).set({
    organizationId: ORG_A, role, siteIds: ["site-1"], status: "active",
  });
}

function call(uid, data) {
  return {auth: {uid, token: {}}, data: {organizationId: ORG_A, ...data},
    rawRequest: {}};
}

function form(overrides = {}) {
  return {
    siteId: "site-1",
    featureOfWork: "Removals",
    activity: "Dismantles and temporary removals",
    estimatedStartDate: "2026-10-20",
    steps: [{
      step: "Remove roof sheets",
      hazards: ["Falls from the roof edge", " "],
      controls: ["Harness tied off to an anchorage"],
    }],
    equipment: ["Scaffold", "Harnesses"],
    inspectionRequirements: ["Scaffold inspected daily"],
    trainingRequirements: ["Fall protection"],
    ...overrides,
  };
}

async function get(id) {
  return (await db.doc(`organizations/${ORG_A}/risk_assessments/${id}`).get())
    .data();
}

beforeEach(async () => {
  await clearFirestore();
  await db.doc(`organizations/${ORG_A}/sites/site-1`).set({
    organizationId: ORG_A, projectId: "project-1", name: "Rosslyn Ridge",
  });
  await seedPerson("eston", "siteManager", "Eston Gikonyo");
  await seedPerson("giuseppe", "siteManager", "Giuseppe Ferrante");
  await seedPerson("foreman-a", "foreman", "Fred Foreman");
});

describe("drafting", () => {
  test("a Site Manager creates a draft; blank lines are dropped", async () => {
    const {id} = await fns.saveRiskAssessment.run(call("eston", form()));
    const aha = await get(id);
    expect(aha).toMatchObject({
      siteId: "site-1",
      siteName: "Rosslyn Ridge",
      projectId: "project-1",
      featureOfWork: "Removals",
      status: "draft",
      revision: 1,
      preparedByUid: "eston",
      preparedByName: "Eston Gikonyo",
      steps: [{
        id: "s1",
        step: "Remove roof sheets",
        hazards: ["Falls from the roof edge"],
        controls: ["Harness tied off to an anchorage"],
      }],
    });
  });

  test("editing a draft keeps step ids and records the new preparer",
    async () => {
      const {id} = await fns.saveRiskAssessment.run(call("eston", form()));
      await fns.saveRiskAssessment.run(call("giuseppe", form({
        id,
        steps: [
          {id: "s1", step: "Remove roof sheets", hazards: ["Falls"],
            controls: ["Harness"]},
          {step: "Lower debris", hazards: [], controls: []},
        ],
      })));
      const aha = await get(id);
      expect(aha.steps.map((s) => s.id)).toEqual(["s1", "s2"]);
      expect(aha.preparedByUid).toBe("giuseppe");
    });

  test("a Foreman cannot prepare an AHA", async () => {
    await expect(fns.saveRiskAssessment.run(call("foreman-a", form())))
      .rejects.toThrow(/permission/);
  });

  test("needs a feature of work and at least one step", async () => {
    await expect(fns.saveRiskAssessment.run(
      call("eston", form({featureOfWork: " "}))
    )).rejects.toThrow(/feature of work/);
    await expect(fns.saveRiskAssessment.run(
      call("eston", form({steps: []}))
    )).rejects.toThrow(/step/);
  });

  test("a draft can be discarded", async () => {
    const {id} = await fns.saveRiskAssessment.run(call("eston", form()));
    await fns.discardRiskAssessmentDraft.run(call("eston", {id}));
    expect(await get(id)).toBeUndefined();
  });
});

describe("acceptance", () => {
  test("someone other than the preparer accepts it", async () => {
    const {id} = await fns.saveRiskAssessment.run(call("eston", form()));
    await expect(fns.acceptRiskAssessment.run(call("eston", {id})))
      .rejects.toThrow(/other than/);

    await fns.acceptRiskAssessment.run(call("giuseppe", {
      id, corName: "J. Smith", note: "OK for use",
    }));
    expect(await get(id)).toMatchObject({
      status: "accepted",
      acceptedByUid: "giuseppe",
      acceptedByName: "Giuseppe Ferrante",
      corName: "J. Smith",
      acceptanceNote: "OK for use",
    });
  });

  test("every step needs a hazard and a control", async () => {
    const {id} = await fns.saveRiskAssessment.run(call("eston", form({
      steps: [{step: "Remove roof sheets", hazards: ["Falls"], controls: []}],
    })));
    await expect(fns.acceptRiskAssessment.run(call("giuseppe", {id})))
      .rejects.toThrow(/Step 1/);
  });

  test("the equipment, inspection and training lists are required",
    async () => {
      const {id} = await fns.saveRiskAssessment.run(
        call("eston", form({trainingRequirements: []}))
      );
      await expect(fns.acceptRiskAssessment.run(call("giuseppe", {id})))
        .rejects.toThrow(/training/);
    });

  test("an accepted AHA cannot be edited, discarded or accepted again",
    async () => {
      const {id} = await fns.saveRiskAssessment.run(call("eston", form()));
      await fns.acceptRiskAssessment.run(call("giuseppe", {id}));
      await expect(fns.saveRiskAssessment.run(call("eston", form({id}))))
        .rejects.toThrow(/revision/);
      await expect(fns.discardRiskAssessmentDraft.run(call("eston", {id})))
        .rejects.toThrow(/draft/);
      await expect(fns.acceptRiskAssessment.run(call("eston", {id})))
        .rejects.toThrow(/draft/);
    });
});

describe("revisions", () => {
  async function accepted() {
    const {id} = await fns.saveRiskAssessment.run(call("eston", form()));
    await fns.acceptRiskAssessment.run(call("giuseppe", {id}));
    return id;
  }

  test("a revision is a new draft; accepting it supersedes the old one",
    async () => {
      const original = await accepted();
      const {id: revision} =
        await fns.reviseRiskAssessment.run(call("eston", {id: original}));

      expect(await get(revision)).toMatchObject({
        status: "draft", revision: 2, previousId: original,
        featureOfWork: "Removals", preparedByUid: "eston",
      });
      expect((await get(original)).status).toBe("accepted");
      await expect(
        fns.reviseRiskAssessment.run(call("giuseppe", {id: original}))
      ).rejects.toThrow(/already/);

      await fns.acceptRiskAssessment.run(call("giuseppe", {id: revision}));
      expect(await get(original)).toMatchObject({
        status: "superseded", supersededById: revision,
      });
      expect((await get(revision)).status).toBe("accepted");
    });

  test("discarding a revision draft allows a new revision", async () => {
    const original = await accepted();
    const {id: revision} =
      await fns.reviseRiskAssessment.run(call("eston", {id: original}));
    await fns.discardRiskAssessmentDraft.run(call("eston", {id: revision}));
    expect((await get(original)).revisionDraftId).toBeNull();
    await expect(fns.reviseRiskAssessment.run(call("eston", {id: original})))
      .resolves.toHaveProperty("id");
  });

  test("a draft cannot be revised", async () => {
    const {id} = await fns.saveRiskAssessment.run(call("eston", form()));
    await expect(fns.reviseRiskAssessment.run(call("eston", {id})))
      .rejects.toThrow(/accepted/);
  });
});
