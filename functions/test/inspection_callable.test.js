/**
 * Business-logic tests for `inspection_callable.ts` — templates, starting,
 * answering, submitting (deficiencies become hazards) and sign-off. Run
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
  fns = require("../lib/inspection_callable");
});

afterAll(async () => {
  if (app) await deleteApp(app);
});

async function clearFirestore() {
  const collections = await db.listCollections();
  await Promise.all(collections.map((c) => db.recursiveDelete(c)));
}

async function seedPerson(uid, role, siteIds = [], name = "Test User") {
  await db.doc(`users/${uid}`).set({
    uid,
    name,
    email: `${uid}@example.com`,
    accountStatus: "active",
  });
  await db.doc(`users/${uid}/memberships/${ORG_A}`).set({
    organizationId: ORG_A,
    role,
    siteIds,
    status: "active",
  });
}

function call(uid, data) {
  return {auth: {uid, token: {}}, data: {organizationId: ORG_A, ...data},
    rawRequest: {}};
}

async function installDefaults() {
  await fns.installDefaultInspectionTemplates.run(call("manager-a", {}));
  const snapshot = await db
    .collection(`organizations/${ORG_A}/inspection_templates`).get();
  const byKey = {};
  for (const doc of snapshot.docs) byKey[doc.data().defaultKey] = doc.id;
  return byKey;
}

async function getInspection(id) {
  return (await db.doc(`organizations/${ORG_A}/inspections/${id}`).get())
    .data();
}

async function answerAll(uid, id, result = "ok") {
  const inspection = await getInspection(id);
  for (const item of inspection.items) {
    await fns.recordInspectionItem.run(call(uid, {
      inspectionId: id, itemId: item.id, result,
    }));
  }
}

beforeEach(async () => {
  await clearFirestore();
  await db.doc(`organizations/${ORG_A}/sites/site-1`).set({
    organizationId: ORG_A, projectId: "project-1", name: "Rosslyn Ridge",
  });
  await db.doc(`organizations/${ORG_A}/sites/site-2`).set({
    organizationId: ORG_A, projectId: "project-1", name: "Other site",
  });
  await seedPerson("manager-a", "siteManager", [], "Eston Gikonyo");
  await seedPerson("manager-b", "siteManager", [], "Giuseppe Ferrante");
  await seedPerson("foreman-a", "foreman", ["site-1"], "Fred Foreman");
  await seedPerson("worker-a", "worker", ["site-1"]);
});

describe("templates", () => {
  test("installs the daily inspection and weekly walk-down once", async () => {
    const byKey = await installDefaults();
    expect(Object.keys(byKey).sort())
      .toEqual(["daily-site-inspection", "weekly-hse-walkdown"]);

    // Again: nothing is duplicated.
    const result =
      await fns.installDefaultInspectionTemplates.run(call("manager-a", {}));
    expect(result.added).toBe(0);
  });

  test("a Foreman cannot install or edit templates", async () => {
    await expect(
      fns.installDefaultInspectionTemplates.run(call("foreman-a", {}))
    ).rejects.toThrow();
  });

  test("a Site Manager can create a template; items keep their ids",
    async () => {
      const {id} = await fns.saveInspectionTemplate.run(call("manager-a", {
        name: "Environmental check",
        kind: "environmental",
        sections: [{
          title: "Dust & waste",
          items: [
            {text: "Dust suppressed (water spraying)", hazardCategory:
              "environment"},
            {id: "keep-me", text: "Skips not overflowing"},
          ],
        }],
      }));
      const template = (await db
        .doc(`organizations/${ORG_A}/inspection_templates/${id}`).get())
        .data();
      expect(template.kind).toBe("environmental");
      expect(template.sections[0].items[1].id).toBe("keep-me");
      expect(template.sections[0].items[1].hazardCategory).toBe("other");
    });

  test("rejects a template with an empty section", async () => {
    await expect(fns.saveInspectionTemplate.run(call("manager-a", {
      name: "Bad", kind: "other", sections: [{title: "Empty", items: []}],
    }))).rejects.toThrow(/at least one item/);
  });
});

describe("running an inspection", () => {
  test("a Foreman inspects their own site; the items are a snapshot",
    async () => {
      const byKey = await installDefaults();
      const {id} = await fns.startInspection.run(call("foreman-a", {
        siteId: "site-1", templateId: byKey["daily-site-inspection"],
      }));
      const inspection = await getInspection(id);
      expect(inspection.status).toBe("inProgress");
      expect(inspection.inspectorName).toBe("Fred Foreman");
      expect(inspection.siteName).toBe("Rosslyn Ridge");
      expect(inspection.items).toHaveLength(10);
      expect(inspection.items[0].result).toBeNull();
    });

  test("a Foreman cannot inspect a site that isn't theirs", async () => {
    const byKey = await installDefaults();
    await expect(fns.startInspection.run(call("foreman-a", {
      siteId: "site-2", templateId: byKey["daily-site-inspection"],
    }))).rejects.toThrow();
  });

  test("a Worker cannot start an inspection", async () => {
    const byKey = await installDefaults();
    await expect(fns.startInspection.run(call("worker-a", {
      siteId: "site-1", templateId: byKey["daily-site-inspection"],
    }))).rejects.toThrow();
  });

  test("only the inspector can record answers", async () => {
    const byKey = await installDefaults();
    const {id} = await fns.startInspection.run(call("foreman-a", {
      siteId: "site-1", templateId: byKey["daily-site-inspection"],
    }));
    await expect(fns.recordInspectionItem.run(call("manager-a", {
      inspectionId: id, itemId: "d1", result: "ok",
    }))).rejects.toThrow();
  });

  test("submit needs every item answered and a note on each Not OK",
    async () => {
      const byKey = await installDefaults();
      const {id} = await fns.startInspection.run(call("foreman-a", {
        siteId: "site-1", templateId: byKey["daily-site-inspection"],
      }));
      await expect(fns.submitInspection.run(call("foreman-a", {
        inspectionId: id,
      }))).rejects.toThrow(/still need an answer/);

      await answerAll("foreman-a", id);
      await fns.recordInspectionItem.run(call("foreman-a", {
        inspectionId: id, itemId: "d2", result: "notOk",
      }));
      await expect(fns.submitInspection.run(call("foreman-a", {
        inspectionId: id,
      }))).rejects.toThrow(/need a note/);
    });

  test("each Not OK becomes a deficiency (hazard) linked to the " +
    "inspection", async () => {
    const byKey = await installDefaults();
    const {id} = await fns.startInspection.run(call("foreman-a", {
      siteId: "site-1", templateId: byKey["daily-site-inspection"],
    }));
    await answerAll("foreman-a", id);
    await fns.recordInspectionItem.run(call("foreman-a", {
      inspectionId: id, itemId: "d2", result: "notOk",
      note: "Two roofers not tied off on block 3",
      photoUrl: "https://example.com/p.jpg",
    }));
    await fns.recordInspectionItem.run(call("foreman-a", {
      inspectionId: id, itemId: "d10", result: "na",
    }));

    const result = await fns.submitInspection.run(call("foreman-a", {
      inspectionId: id,
    }));
    expect(result.deficiencies).toBe(1);

    const inspection = await getInspection(id);
    expect(inspection.status).toBe("submitted");
    expect(inspection.okCount).toBe(8);
    expect(inspection.notOkCount).toBe(1);
    expect(inspection.naCount).toBe(1);
    const failed = inspection.items.find((item) => item.id === "d2");
    expect(failed.hazardId).toBeTruthy();

    const hazard = (await db
      .doc(`organizations/${ORG_A}/hazards/${failed.hazardId}`).get()).data();
    expect(hazard.status).toBe("reported");
    expect(hazard.category).toBe("workingAtHeight");
    expect(hazard.reportedByUid).toBe("foreman-a");
    expect(hazard.siteId).toBe("site-1");
    expect(hazard.inspectionId).toBe(id);
    expect(hazard.description).toContain("Two roofers not tied off");
    expect(hazard.photoUrl).toBe("https://example.com/p.jpg");
  });
});

describe("sign-off", () => {
  async function submitted(byUid = "manager-a") {
    const byKey = await installDefaults();
    const {id} = await fns.startInspection.run(call(byUid, {
      siteId: "site-1", templateId: byKey["weekly-hse-walkdown"],
    }));
    await answerAll(byUid, id);
    await fns.submitInspection.run(call(byUid, {inspectionId: id}));
    return id;
  }

  test("another Site Manager signs off the walk-down", async () => {
    const id = await submitted("manager-a");
    await fns.signOffInspection.run(call("manager-b", {
      inspectionId: id, note: "Good week",
    }));
    const inspection = await getInspection(id);
    expect(inspection.status).toBe("signedOff");
    expect(inspection.signedOffByName).toBe("Giuseppe Ferrante");
    expect(inspection.signOffNote).toBe("Good week");
  });

  test("the inspector cannot sign off their own inspection", async () => {
    const id = await submitted("manager-a");
    await expect(fns.signOffInspection.run(call("manager-a", {
      inspectionId: id,
    }))).rejects.toThrow(/another manager/);
  });

  test("a Foreman cannot sign off", async () => {
    const id = await submitted("manager-a");
    await expect(fns.signOffInspection.run(call("foreman-a", {
      inspectionId: id,
    }))).rejects.toThrow();
  });

  test("cannot sign off before it is submitted", async () => {
    const byKey = await installDefaults();
    const {id} = await fns.startInspection.run(call("foreman-a", {
      siteId: "site-1", templateId: byKey["daily-site-inspection"],
    }));
    await expect(fns.signOffInspection.run(call("manager-a", {
      inspectionId: id,
    }))).rejects.toThrow(/not been submitted/);
  });
});
