/**
 * Business-logic tests for `learning_upload_callable.ts` —
 * `publishLearningUpload`, the only way a file reaches an organization's
 * Safety Learning library folder (no client may write there).
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

let app;
let db;
let bucket;
let publishLearningUpload;

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

  ({publishLearningUpload} = require("../lib/learning_upload_callable"));
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

async function seedUser(uid, {admin = false, role = null} = {}) {
  await db.doc(`users/${uid}`).set({
    uid,
    name: uid,
    email: `${uid}@example.com`,
    accountStatus: "active",
    ...(admin ? {platformRole: "admin"} : {}),
  });
  if (role) {
    await db.doc(`users/${uid}/memberships/${ORG_A}`).set({
      organizationId: ORG_A,
      role,
      siteIds: [],
      status: "active",
    });
  }
}

let counter = 0;
async function stage(uid, fileName, contentType, bytes = Buffer.from("x")) {
  counter += 1;
  const path = `learning_uploads/${uid}/${Date.now()}-${counter}/${fileName}`;
  await bucket.file(path).save(bytes, {contentType});
  return path;
}

function callRequest(uid, data) {
  return {auth: uid ? {uid, token: {}} : undefined, data, rawRequest: {}};
}

const publish = (uid, uploadPath) => publishLearningUpload.run(
  callRequest(uid, {organizationId: ORG_A, uploadPath})
);

describe("publishLearningUpload", () => {
  test("a Site Manager publishes a staged video into the library folder " +
    "and gets a download URL; the staged copy is removed", async () => {
    await seedUser("sm-1", {role: "siteManager"});
    const staged = await stage("sm-1", "ladder.mp4", "video/mp4");

    const result = await publish("sm-1", staged);

    const [, , uploadId] = staged.split("/");
    const target = `organizations/${ORG_A}/safety_learning/${uploadId}` +
      "/ladder.mp4";
    expect(result.contentReference).toContain(encodeURIComponent(target));
    expect(result.contentReference).toContain("token=");
    expect((await bucket.file(target).exists())[0]).toBe(true);
    expect((await bucket.file(staged).exists())[0]).toBe(false);
    const [metadata] = await bucket.file(target).getMetadata();
    expect(metadata.contentType).toBe("video/mp4");
  });

  test("a Site Manager cannot publish a non-video file", async () => {
    await seedUser("sm-1", {role: "siteManager"});
    const staged = await stage("sm-1", "handbook.pdf", "application/pdf");
    await expect(publish("sm-1", staged)).rejects.toThrow(/video files/);
  });

  test("an Admin can publish a library document", async () => {
    await seedUser("admin-1", {admin: true});
    const staged = await stage("admin-1", "handbook.pdf", "application/pdf");
    const result = await publish("admin-1", staged);
    expect(result.contentReference).toContain("handbook.pdf");
  });

  test("Workers and Foremen cannot publish", async () => {
    for (const role of ["worker", "foreman"]) {
      await seedUser(`${role}-1`, {role});
      const staged = await stage(`${role}-1`, "clip.mp4", "video/mp4");
      await expect(publish(`${role}-1`, staged))
        .rejects.toThrow(/permission/);
    }
  });

  test("nobody can publish someone else's staged upload", async () => {
    await seedUser("sm-1", {role: "siteManager"});
    await seedUser("sm-2", {role: "siteManager"});
    const staged = await stage("sm-2", "ladder.mp4", "video/mp4");
    await expect(publish("sm-1", staged)).rejects.toThrow(/your own/);
    expect((await bucket.file(staged).exists())[0]).toBe(true);
  });

  test("malformed and traversal paths are refused", async () => {
    await seedUser("sm-1", {role: "siteManager"});
    for (const path of [
      "organizations/org-alpha/safety_learning/1/a.mp4",
      "learning_uploads/sm-1/a.mp4",
      "learning_uploads/sm-1/../x/a.mp4",
      "learning_uploads/sm-1/1/2/a.mp4",
    ]) {
      await expect(publish("sm-1", path)).rejects.toThrow(/your own/);
    }
  });

  test("a disallowed type is refused and its staged copy removed",
    async () => {
      await seedUser("admin-1", {admin: true});
      const staged = await stage("admin-1", "page.html", "text/html");
      await expect(publish("admin-1", staged)).rejects.toThrow(/under 25 MB/);
      expect((await bucket.file(staged).exists())[0]).toBe(false);
    });

  test("an existing library file is never overwritten", async () => {
    await seedUser("sm-1", {role: "siteManager"});
    const staged = await stage("sm-1", "ladder.mp4", "video/mp4");
    const [, , uploadId] = staged.split("/");
    const target = `organizations/${ORG_A}/safety_learning/${uploadId}` +
      "/ladder.mp4";
    await bucket.file(target).save(Buffer.from("original"),
      {contentType: "video/mp4"});

    await expect(publish("sm-1", staged)).rejects.toThrow(/already exists/);
    const [contents] = await bucket.file(target).download();
    expect(contents.toString()).toBe("original");
  });

  test("a missing staged file is reported", async () => {
    await seedUser("sm-1", {role: "siteManager"});
    await expect(
      publish("sm-1", "learning_uploads/sm-1/123/gone.mp4")
    ).rejects.toThrow(/could not be found/);
  });
});
