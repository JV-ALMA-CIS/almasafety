/**
 * Business-logic tests for `learning_delete_callable.ts` —
 * `deleteSafetyLearning`, which permanently deletes a learning item only
 * when nothing depends on it.
 *
 * Requires the Firestore and Storage emulators — see
 * `npm run test:callables`.
 */

const {initializeApp, getApps, deleteApp} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");
const {getStorage} = require("firebase-admin/storage");

const PROJECT_ID = "jva-safety-rules-test";
const BUCKET = `${PROJECT_ID}.appspot.com`;
const ORG_A = "org-alpha";
const ORG_B = "org-beta";

let app;
let db;
let bucket;
let deleteSafetyLearning;
let ownedLibraryFile;
let storageOps;
let finishAllPendingDeletions;
let updateSafetyLearning;
let addKnowledgeCheckQuestion;
let createSafetyRequirement;
let updateSafetyRequirement;

beforeAll(() => {
  process.env.GCLOUD_PROJECT = PROJECT_ID;
  if (!process.env.FIRESTORE_EMULATOR_HOST) {
    process.env.FIRESTORE_EMULATOR_HOST = "127.0.0.1:8080";
  }
  if (!process.env.FIREBASE_STORAGE_EMULATOR_HOST) {
    process.env.FIREBASE_STORAGE_EMULATOR_HOST = "127.0.0.1:9199";
  }
  app = getApps()[0] ??
    initializeApp({projectId: PROJECT_ID, storageBucket: BUCKET});
  db = getFirestore(app);
  bucket = getStorage(app).bucket(BUCKET);
  ({
    deleteSafetyLearning,
    ownedLibraryFile,
    storageOps,
    finishAllPendingDeletions,
  } = require("../lib/learning_delete_callable"));
  ({
    updateSafetyLearning,
    addKnowledgeCheckQuestion,
    createSafetyRequirement,
    updateSafetyRequirement,
  } = require("../lib/safety_learning_callable"));
});

afterAll(async () => {
  if (app) await deleteApp(app);
});

beforeEach(async () => {
  const collections = await db.listCollections();
  await Promise.all(collections.map((c) => db.recursiveDelete(c)));
  const [files] = await bucket.getFiles();
  await Promise.all(files.map((file) => file.delete({ignoreNotFound: true})));
});

async function seedUser(uid, {admin = false, role = null, org = ORG_A,
  accountStatus = "active", membershipStatus = "active"} = {}) {
  await db.doc(`users/${uid}`).set({
    uid,
    name: uid,
    email: `${uid}@example.com`,
    accountStatus,
    ...(admin ? {platformRole: "admin"} : {}),
  });
  if (role) {
    await db.doc(`users/${uid}/memberships/${org}`).set({
      organizationId: org,
      role,
      siteIds: [],
      status: membershipStatus,
    });
  }
}

const itemPath = (id, org = ORG_A) =>
  `organizations/${org}/safety_learning/${id}`;

function libraryUrl(path, token = "t") {
  return `http://127.0.0.1:9199/v0/b/${BUCKET}/o/` +
    `${encodeURIComponent(path)}?alt=media&token=${token}`;
}

async function seedItem(id, {type = "video", status = "active", org = ORG_A,
  contentReference = "https://www.youtube.com/watch?v=jfKfPfyJRdk",
  questions = 0} = {}) {
  await db.doc(itemPath(id, org)).set({
    organizationId: org,
    title: `Title ${id}`,
    type,
    contentReference,
    status,
  });
  for (let i = 0; i < questions; i++) {
    await db.doc(`${itemPath(id, org)}/knowledge_check_questions/q${i}`).set({
      prompt: "Q",
      options: [{id: "a", text: "A"}, {id: "b", text: "B"}],
      correctOptionId: "a",
      order: i,
    });
  }
}

function callRequest(uid, data) {
  return {auth: uid ? {uid, token: {}} : undefined, data, rawRequest: {}};
}

const remove = (uid, id, org = ORG_A) => deleteSafetyLearning.run(
  callRequest(uid, {organizationId: org, id})
);

const exists = async (path) => (await db.doc(path).get()).exists;

describe("deleteSafetyLearning — genuinely unused content", () => {
  test("deletes the item and its quiz questions", async () => {
    await seedUser("sm-1", {role: "siteManager"});
    await seedItem("v1", {questions: 2});

    const result = await remove("sm-1", "v1");
    expect(result).toMatchObject({id: "v1", title: "Title v1"});
    expect(await exists(itemPath("v1"))).toBe(false);
    const questions = await db
      .collection(`${itemPath("v1")}/knowledge_check_questions`).get();
    expect(questions.empty).toBe(true);
  });

  test("an inactive item with no dependents can be deleted too", async () => {
    await seedUser("sm-1", {role: "siteManager"});
    await seedItem("v1", {status: "inactive"});
    await remove("sm-1", "v1");
    expect(await exists(itemPath("v1"))).toBe(false);
  });

  test("an uploaded library file is deleted with it", async () => {
    await seedUser("sm-1", {role: "siteManager"});
    const path = `organizations/${ORG_A}/safety_learning/u1/clip.mp4`;
    await bucket.file(path).save(Buffer.from("x"), {contentType: "video/mp4"});
    await seedItem("v1", {contentReference: libraryUrl(path)});

    const result = await remove("sm-1", "v1");
    expect(result.fileDeleted).toBe(true);
    const [still] = await bucket.file(path).exists();
    expect(still).toBe(false);
  });

  test("a file another item still uses is kept", async () => {
    await seedUser("sm-1", {role: "siteManager"});
    const path = `organizations/${ORG_A}/safety_learning/u1/clip.mp4`;
    await bucket.file(path).save(Buffer.from("x"), {contentType: "video/mp4"});
    await seedItem("v1", {contentReference: libraryUrl(path)});
    await seedItem("v2", {contentReference: libraryUrl(path)});

    await remove("sm-1", "v1");
    const [still] = await bucket.file(path).exists();
    expect(still).toBe(true);
    expect(await exists(itemPath("v2"))).toBe(true);
  });

  test("an external link touches no Storage file", async () => {
    await seedUser("sm-1", {role: "siteManager"});
    const other = "organizations/org-alpha/hazards/h1/photo.jpg";
    await bucket.file(other)
      .save(Buffer.from("x"), {contentType: "image/jpeg"});
    await seedItem("v1");
    await remove("sm-1", "v1");
    const [still] = await bucket.file(other).exists();
    expect(still).toBe(true);
  });
});

describe("deleteSafetyLearning — refused when anything depends on it", () => {
  test("a learning record of ANY status refuses it; the item, its " +
    "questions and the record are untouched", async () => {
    await seedUser("sm-1", {role: "siteManager"});
    for (const status of ["assigned", "inProgress", "completed"]) {
      await seedItem("v1", {questions: 1});
      const recordPath =
        `organizations/${ORG_A}/worker_learning_records/w_v1`;
      await db.doc(recordPath).set({
        workerUid: "w",
        learningId: "v1",
        status,
        knowledgeCheckResult: {passed: true, score: 1, totalQuestions: 1},
      });
      await expect(remove("sm-1", "v1")).rejects.toThrow(/training records/);
      expect(await exists(itemPath("v1"))).toBe(true);
      expect(
        await exists(`${itemPath("v1")}/knowledge_check_questions/q0`)
      ).toBe(true);
      const record = (await db.doc(recordPath).get()).data();
      expect(record.status).toBe(status);
      expect(record.knowledgeCheckResult.passed).toBe(true);
      await db.doc(recordPath).delete();
    }
  });

  test("an ACTIVE or INACTIVE requirement listing it refuses it, by name",
    async () => {
      await seedUser("sm-1", {role: "siteManager"});
      for (const status of ["active", "inactive"]) {
        await seedItem("v1");
        await db.doc(`organizations/${ORG_A}/safety_requirements/r1`).set({
          name: "Working at Height",
          requiredLearningIds: ["v1"],
          status,
        });
        await expect(remove("sm-1", "v1"))
          .rejects.toThrow(/Working at Height/);
        expect(await exists(itemPath("v1"))).toBe(true);
      }
    });

  test("the uploaded file is kept when deletion is refused", async () => {
    await seedUser("sm-1", {role: "siteManager"});
    const path = `organizations/${ORG_A}/safety_learning/u1/clip.mp4`;
    await bucket.file(path).save(Buffer.from("x"), {contentType: "video/mp4"});
    await seedItem("v1", {contentReference: libraryUrl(path)});
    await db.doc(`organizations/${ORG_A}/worker_learning_records/w_v1`)
      .set({workerUid: "w", learningId: "v1", status: "completed"});
    await expect(remove("sm-1", "v1")).rejects.toThrow();
    const [still] = await bucket.file(path).exists();
    expect(still).toBe(true);
  });

  test("another organization's records do not block it", async () => {
    await seedUser("sm-1", {role: "siteManager"});
    await seedItem("v1");
    await db.doc(`organizations/${ORG_B}/worker_learning_records/w_v1`)
      .set({workerUid: "w", learningId: "v1", status: "completed"});
    await remove("sm-1", "v1");
    expect(await exists(itemPath("v1"))).toBe(false);
    expect(await exists(`organizations/${ORG_B}/worker_learning_records/w_v1`))
      .toBe(true);
  });
});

describe("deleteSafetyLearning — authorization and isolation", () => {
  test("Workers and Foremen are refused", async () => {
    await seedItem("v1");
    for (const role of ["worker", "foreman"]) {
      await seedUser(`${role}-1`, {role});
      await expect(remove(`${role}-1`, "v1")).rejects.toThrow(/permission/);
    }
    expect(await exists(itemPath("v1"))).toBe(true);
  });

  test("a Site Manager may delete videos only; an Admin any type",
    async () => {
      await seedUser("sm-1", {role: "siteManager"});
      await seedUser("admin-1", {admin: true});
      await seedItem("d1", {type: "document"});
      await expect(remove("sm-1", "d1")).rejects.toThrow(/video/);
      expect(await exists(itemPath("d1"))).toBe(true);
      await remove("admin-1", "d1");
      expect(await exists(itemPath("d1"))).toBe(false);
    });

  test("a Site Manager of another organization cannot reach it", async () => {
    await seedUser("sm-b", {role: "siteManager", org: ORG_B});
    await seedItem("v1");
    await expect(remove("sm-b", "v1")).rejects.toThrow(/permission/);
    // Naming their own organization: the id is not there.
    await expect(remove("sm-b", "v1", ORG_B)).rejects.toThrow(/no longer/);
    expect(await exists(itemPath("v1"))).toBe(true);
  });

  test("a suspended account or membership, or no sign-in, is refused",
    async () => {
      await seedItem("v1");
      await seedUser("sm-s", {role: "siteManager", accountStatus: "suspended"});
      await seedUser("sm-m",
        {role: "siteManager", membershipStatus: "suspended"});
      for (const uid of ["sm-s", "sm-m", null]) {
        await expect(remove(uid, "v1")).rejects.toThrow();
      }
      expect(await exists(itemPath("v1"))).toBe(true);
    });

  test("a missing id or item is a clear error", async () => {
    await seedUser("sm-1", {role: "siteManager"});
    await expect(remove("sm-1", "")).rejects.toThrow(/id is required/);
    await expect(remove("sm-1", "nope")).rejects.toThrow(/no longer exists/);
  });
});

describe("ownedLibraryFile", () => {
  test("only this organization's library folder in the default bucket",
    () => {
      const mine = `organizations/${ORG_A}/safety_learning/u1/a b.mp4`;
      expect(ownedLibraryFile(libraryUrl(mine), ORG_A, BUCKET)).toBe(mine);
      expect(ownedLibraryFile(libraryUrl(mine), ORG_B, BUCKET)).toBeNull();
      expect(ownedLibraryFile(
        libraryUrl("organizations/org-alpha/hazards/h1/p.jpg"), ORG_A, BUCKET
      )).toBeNull();
      expect(ownedLibraryFile(libraryUrl(mine), ORG_A, "other-bucket"))
        .toBeNull();
      expect(ownedLibraryFile(
        "https://www.youtube.com/watch?v=jfKfPfyJRdk", ORG_A, BUCKET
      )).toBeNull();
      expect(ownedLibraryFile(undefined, ORG_A, BUCKET)).toBeNull();
    });
});

describe("deleteSafetyLearning — recovery when it cannot finish", () => {
  let original;
  beforeEach(() => {
    original = storageOps.deleteObject;
  });
  afterEach(() => {
    storageOps.deleteObject = original;
  });

  const failStorage = () => {
    storageOps.deleteObject = async () => {
      throw new Error("storage down");
    };
  };

  async function seedUploaded(id = "v1") {
    const path = `organizations/${ORG_A}/safety_learning/${id}u/clip.mp4`;
    await bucket.file(path).save(Buffer.from("x"), {contentType: "video/mp4"});
    await seedItem(id, {contentReference: libraryUrl(path), questions: 2});
    return path;
  }

  test("a Storage failure leaves the item hidden and MARKED (not deleted, " +
    "not live), says so, and a retry finishes it", async () => {
    await seedUser("sm-1", {role: "siteManager"});
    const path = await seedUploaded();
    failStorage();

    await expect(remove("sm-1", "v1"))
      .rejects.toThrow(/couldn't be removed yet.*marked for deletion/);
    const item = (await db.doc(itemPath("v1")).get()).data();
    expect(item.status).toBe("inactive");
    expect(item.deletion.pending).toBe(true);
    expect(item.deletion.previousStatus).toBe("active");
    expect(
      await exists(`${itemPath("v1")}/knowledge_check_questions/q0`)
    ).toBe(true);
    expect((await bucket.file(path).exists())[0]).toBe(true);

    storageOps.deleteObject = original;
    const result = await remove("sm-1", "v1");
    expect(result.title).toBe("Title v1");
    expect(await exists(itemPath("v1"))).toBe(false);
    expect((await bucket.file(path).exists())[0]).toBe(false);
    const questions = await db
      .collection(`${itemPath("v1")}/knowledge_check_questions`).get();
    expect(questions.empty).toBe(true);
  });

  test("the scheduled recovery finishes marked items on its own", async () => {
    await seedUser("sm-1", {role: "siteManager"});
    const path = await seedUploaded();
    failStorage();
    await expect(remove("sm-1", "v1")).rejects.toThrow();
    storageOps.deleteObject = original;

    const result = await finishAllPendingDeletions();
    expect(result).toEqual({finished: 1, failed: 0});
    expect(await exists(itemPath("v1"))).toBe(false);
    expect((await bucket.file(path).exists())[0]).toBe(false);
  });

  test("while marked, edits, re-activation and quiz changes are refused",
    async () => {
      await seedUser("sm-1", {role: "siteManager"});
      await seedUploaded();
      failStorage();
      await expect(remove("sm-1", "v1")).rejects.toThrow();
      const call = (fn, data) => fn.run(
        callRequest("sm-1", {organizationId: ORG_A, ...data})
      );
      await expect(call(updateSafetyLearning, {id: "v1", status: "active"}))
        .rejects.toThrow(/being deleted/);
      await expect(call(updateSafetyLearning, {id: "v1", title: "X"}))
        .rejects.toThrow(/being deleted/);
      await expect(call(addKnowledgeCheckQuestion, {
        learningId: "v1",
        prompt: "Q",
        options: [{id: "a", text: "A"}, {id: "b", text: "B"}],
        correctOptionId: "a",
        order: 0,
      })).rejects.toThrow(/being deleted/);
      expect((await db.doc(itemPath("v1")).get()).data().status)
        .toBe("inactive");
    });

  const lateDependencies = [
    ["a requirement", async () => {
      await db.doc(`organizations/${ORG_A}/safety_requirements/r1`).set({
        name: "Late Requirement",
        requiredLearningIds: ["v1"],
        status: "inactive",
      });
    }],
    ["a learner record", async () => {
      await db.doc(`organizations/${ORG_A}/worker_learning_records/w_v1`)
        .set({workerUid: "w", learningId: "v1", status: "assigned"});
    }],
  ];
  for (const [kind, seedDependency] of lateDependencies) {
    test(`${kind} that appeared after marking undoes the deletion: the ` +
      "item comes back as it was, file and questions kept", async () => {
      await seedUser("sm-1", {role: "siteManager"});
      const path = await seedUploaded();
      // Marked by an earlier attempt that stopped part-way.
      await db.doc(itemPath("v1")).update({
        status: "inactive",
        deletion: {pending: true, previousStatus: "active"},
      });
      await seedDependency();

      await expect(remove("sm-1", "v1"))
        .rejects.toThrow(/Nothing was deleted/);
      const item = (await db.doc(itemPath("v1")).get()).data();
      expect(item.status).toBe("active");
      expect(item.deletion).toBeUndefined();
      expect((await bucket.file(path).exists())[0]).toBe(true);
      expect(
        await exists(`${itemPath("v1")}/knowledge_check_questions/q1`)
      ).toBe(true);
    });
  }

  test("an item that was inactive before comes back inactive", async () => {
    await seedUser("sm-1", {role: "siteManager"});
    await seedItem("v1", {status: "inactive"});
    await db.doc(itemPath("v1")).update({
      deletion: {pending: true, previousStatus: "inactive"},
    });
    await db.doc(`organizations/${ORG_A}/worker_learning_records/w_v1`)
      .set({workerUid: "w", learningId: "v1", status: "completed"});
    await expect(remove("sm-1", "v1")).rejects.toThrow();
    expect((await db.doc(itemPath("v1")).get()).data().status)
      .toBe("inactive");
  });

  test("the scheduled recovery never deletes an item that gained a " +
    "dependency — it restores it", async () => {
    await seedItem("v1");
    await db.doc(itemPath("v1")).update({
      status: "inactive",
      deletion: {pending: true, previousStatus: "active"},
    });
    await db.doc(`organizations/${ORG_A}/worker_learning_records/w_v1`)
      .set({workerUid: "w", learningId: "v1", status: "completed"});
    const result = await finishAllPendingDeletions();
    expect(result).toEqual({finished: 0, failed: 1});
    expect((await db.doc(itemPath("v1")).get()).data().status)
      .toBe("active");
    expect(await exists(`organizations/${ORG_A}/worker_learning_records/w_v1`))
      .toBe(true);
  });

  test("a second Delete after success reports the item is gone", async () => {
    await seedUser("sm-1", {role: "siteManager"});
    await seedItem("v1");
    await remove("sm-1", "v1");
    await expect(remove("sm-1", "v1")).rejects.toThrow(/no longer exists/);
  });
});

describe("requirement edits racing a deletion", () => {
  let original;
  beforeEach(async () => {
    original = storageOps.deleteObject;
    await seedUser("sm-1", {role: "siteManager"});
  });
  afterEach(() => {
    storageOps.deleteObject = original;
  });

  const call = (fn, data) => fn.run(
    callRequest("sm-1", {organizationId: ORG_A, ...data})
  );
  const newRequirement = (ids) => call(createSafetyRequirement, {
    name: "Working at Height",
    category: "General",
    risk: "low",
    requiredLearningIds: ids,
  });
  const reqPath = (id) => `organizations/${ORG_A}/safety_requirements/${id}`;

  async function markForDeletion() {
    storageOps.deleteObject = async () => {
      throw new Error("storage down");
    };
    const path = `organizations/${ORG_A}/safety_learning/v1u/clip.mp4`;
    await bucket.file(path).save(Buffer.from("x"), {contentType: "video/mp4"});
    await seedItem("v1", {contentReference: libraryUrl(path)});
    await expect(remove("sm-1", "v1")).rejects.toThrow(/marked for deletion/);
    storageOps.deleteObject = original;
  }

  describe("edit starts AFTER the deletion marked the item", () => {
    test("creating a requirement that lists it is refused", async () => {
      await markForDeletion();
      await expect(newRequirement(["v1"])).rejects.toThrow(/being deleted/);
      const all = await db
        .collection(`organizations/${ORG_A}/safety_requirements`).get();
      expect(all.empty).toBe(true);
    });

    test("adding it to an existing requirement is refused; the " +
      "requirement is unchanged", async () => {
      await seedItem("other");
      const {id} = await newRequirement(["other"]);
      await markForDeletion();
      await expect(call(updateSafetyRequirement, {
        id,
        requiredLearningIds: ["other", "v1"],
      })).rejects.toThrow(/being deleted/);
      expect((await db.doc(reqPath(id)).get()).data().requiredLearningIds)
        .toEqual(["other"]);
    });

    test("once deleted, listing it is refused as missing", async () => {
      await seedItem("v1");
      await remove("sm-1", "v1");
      await expect(newRequirement(["v1"])).rejects.toThrow(/do not exist/);
    });

    test("other edits of a requirement still work meanwhile", async () => {
      await seedItem("other");
      const {id} = await newRequirement(["other"]);
      await markForDeletion();
      await call(updateSafetyRequirement, {id, name: "Renamed"});
      expect((await db.doc(reqPath(id)).get()).data().name).toBe("Renamed");
    });
  });

  describe("edit starts BEFORE the deletion marks the item", () => {
    test("a requirement saved first makes the deletion refuse, naming it",
      async () => {
        await seedItem("v1");
        await newRequirement(["v1"]);
        await expect(remove("sm-1", "v1")).rejects.toThrow(/Working at Height/);
        expect((await db.doc(itemPath("v1")).get()).data().status)
          .toBe("active");
      });

    test("racing them repeatedly never leaves a requirement listing a " +
      "deleted or half-deleted item", async () => {
      for (let round = 0; round < 8; round++) {
        await seedItem(`v${round}`);
        await seedItem("other");
        const {id} = await newRequirement(["other"]);
        const results = await Promise.allSettled([
          call(updateSafetyRequirement, {
            id,
            requiredLearningIds: ["other", `v${round}`],
          }),
          remove("sm-1", `v${round}`),
        ]);
        const listed = (await db.doc(reqPath(id)).get()).data()
          .requiredLearningIds.includes(`v${round}`);
        const item = (await db.doc(itemPath(`v${round}`)).get()).data();
        if (listed) {
          // The requirement won: the item must be there, live and unmarked.
          expect(item).toBeDefined();
          expect(item.deletion).toBeUndefined();
          expect(item.status).toBe("active");
        } else {
          // The deletion won (or both were refused): no dangling listing.
          expect(results[0].status === "rejected" || item === undefined ||
            item.deletion === undefined).toBe(true);
        }
        await db.doc(reqPath(id)).delete();
      }
    });
  });
});

describe("simulated Storage failure hook", () => {
  afterEach(() => {
    delete process.env.FUNCTIONS_EMULATOR;
    delete process.env.JVA_SIMULATE_STORAGE_FAILURE;
  });

  test("only fails when BOTH the emulator flag and the opt-in are set",
    async () => {
      await expect(storageOps.deleteObject("organizations/x/none"))
        .resolves.toBeUndefined();
      process.env.JVA_SIMULATE_STORAGE_FAILURE = "true";
      await expect(storageOps.deleteObject("organizations/x/none"))
        .resolves.toBeUndefined();
      process.env.FUNCTIONS_EMULATOR = "true";
      await expect(storageOps.deleteObject("organizations/x/none"))
        .rejects.toThrow(/Simulated/);
    });
});

