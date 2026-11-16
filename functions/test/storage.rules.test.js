/**
 * Cloud Storage Security Rules tests for JVA Safety.
 *
 * `storage.rules` deliberately does NOT cross-reference Firestore membership
 * documents to scope Storage access per organization — see storage.rules'
 * own header note for why: an earlier version did exactly that (mirroring
 * `firestore.rules`' `belongsToOrganization()`), was syntactically correct
 * per Firebase's documented cross-service Rules syntax and passed in the
 * emulator, but returned 403 in production for real users with a genuinely
 * valid, active membership — a known class of issue where Storage Rules'
 * cross-service Firestore access depends on a project-level IAM grant that
 * is not always present/propagated. Real authorization for every write that
 * matters lives in the Cloud Functions callables instead (which bypass
 * these Rules entirely via the Admin SDK) — see e.g.
 * `daily_safety_meeting_callable.ts`'s EVIDENCE header note.
 *
 * This suite proves the CURRENT, simpler contract: any signed-in user may
 * read/write under `organizations/{organizationId}/...`; every other path
 * and an unauthenticated caller are refused; a >25MB upload is refused; a
 * delete (no `request.resource`) still succeeds — EXCEPT the Safety
 * Learning library folder (`.../safety_learning/{uploadId}/{fileName}`),
 * which no client may write (files are published server-side by
 * `publishLearningUpload`), and each author's own staging folder
 * (`learning_uploads/{uid}/...`), which only that user can use.
 *
 * Requires the Storage emulator. Run:
 *
 *   cd functions
 *   npm run test:storage-rules
 *
 * which wraps this file in `firebase emulators:exec --only
 * firestore,storage` (Firestore is started alongside Storage only because
 * the npm script's emulator selection is shared with other suites — this
 * file itself does not touch Firestore).
 */

const fs = require("fs");
const path = require("path");
const {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} = require("@firebase/rules-unit-testing");
const {
  ref,
  uploadBytes,
  getBytes,
  deleteObject,
} = require("firebase/storage");

const PROJECT_ID = "jva-safety-rules-test";
const ORG_A = "org-alpha";
const ORG_B = "org-beta";

let testEnv;

/**
 * Resolves an emulator's host/port from its *_EMULATOR_HOST env var, which
 * `firebase emulators:exec` exports for us. Mirrors
 * `firestore.rules.test.js`'s `emulatorAddress()`.
 *
 * @param {string} envVar the emulator host env var name.
 * @param {string} defaultPort the fallback port if the env var is unset.
 * @return {{host: string, port: number}} the resolved address.
 */
function emulatorAddress(envVar, defaultPort) {
  const fromEnv = process.env[envVar];
  if (fromEnv) {
    const separator = fromEnv.lastIndexOf(":");
    return {
      host: fromEnv.slice(0, separator),
      port: Number(fromEnv.slice(separator + 1)),
    };
  }
  return {host: "127.0.0.1", port: defaultPort};
}

beforeAll(async () => {
  const storageAddress = emulatorAddress(
    "FIREBASE_STORAGE_EMULATOR_HOST",
    9199
  );

  testEnv = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    storage: {
      rules: fs.readFileSync(
        path.resolve(__dirname, "../../storage.rules"),
        "utf8"
      ),
      host: storageAddress.host,
      port: storageAddress.port,
    },
  });
});

afterAll(async () => {
  await testEnv.cleanup();
});

beforeEach(async () => {
  await testEnv.clearStorage();
});

function storageFor(uid) {
  return testEnv.authenticatedContext(uid, {
    email: `${uid}@example.com`,
    email_verified: true,
  }).storage();
}

function anonymousStorage() {
  return testEnv.unauthenticatedContext().storage();
}

const SOME_BYTES = new Uint8Array([1, 2, 3, 4]);

describe("organization-scoped Storage access (signed-in only)", () => {
  test("any signed-in user can upload and read a file under an " +
    "organization's path, regardless of membership", async () => {
    const storage = storageFor("worker-a");
    const fileRef = ref(
      storage,
      `organizations/${ORG_A}/hazards/hazard-1/photo.jpg`
    );

    await assertSucceeds(uploadBytes(fileRef, SOME_BYTES));
    await assertSucceeds(getBytes(fileRef));
  });

  test("a signed-in user can access a DIFFERENT organization's path too " +
    "— organization isolation is enforced by the callables' Firestore " +
    "metadata, not by this Storage-level check", async () => {
    const storage = storageFor("worker-a");
    const fileRef = ref(
      storage,
      `organizations/${ORG_B}/hazards/hazard-1/photo.jpg`
    );

    await assertSucceeds(uploadBytes(fileRef, SOME_BYTES));
  });

  test("an unauthenticated caller cannot read or write any organization's " +
    "Storage tree", async () => {
    const storage = anonymousStorage();
    const fileRef = ref(
      storage,
      `organizations/${ORG_A}/hazards/hazard-1/photo.jpg`
    );

    await assertFails(uploadBytes(fileRef, SOME_BYTES));
  });

  test("every path outside organizations/{organizationId}/... is denied " +
    "outright, even for a signed-in user", async () => {
    const storage = storageFor("worker-a");
    const fileRef = ref(storage, "some-other-top-level-path/file.jpg");

    await assertFails(uploadBytes(fileRef, SOME_BYTES));
  });
});

describe("existing Hazard photo upload path (regression)", () => {
  test("a signed-in user can upload a hazard photo to " +
    "organizations/{orgId}/hazards/{hazardId}/{fileName}, matching " +
    "HazardService.uploadHazardPhoto's real path shape", async () => {
    const storage = storageFor("foreman-a");
    const fileRef = ref(
      storage,
      `organizations/${ORG_A}/hazards/hazard-42/photo-1.jpg`
    );

    await assertSucceeds(uploadBytes(fileRef, SOME_BYTES));
    await assertSucceeds(getBytes(fileRef));
  });

  test("a file larger than 25MB is refused", async () => {
    const storage = storageFor("foreman-a");
    const fileRef = ref(
      storage,
      `organizations/${ORG_A}/hazards/hazard-42/big-file.jpg`
    );
    const tooLarge = new Uint8Array(25 * 1024 * 1024 + 1);

    await assertFails(uploadBytes(fileRef, tooLarge));
  });

  test("a signed-in user can delete a file under an organization's path",
    async () => {
      const storage = storageFor("foreman-a");
      const fileRef = ref(
        storage,
        `organizations/${ORG_A}/hazards/hazard-42/photo-1.jpg`
      );
      await assertSucceeds(uploadBytes(fileRef, SOME_BYTES));

      await assertSucceeds(deleteObject(fileRef));
    });
});

describe("Daily Safety Meeting evidence upload path (regression)", () => {
  test("a signed-in foreman can upload meeting evidence to " +
    "organizations/{orgId}/daily_safety_meetings/{meetingId}/" +
    "{evidenceId}/{fileName}, matching " +
    "DailySafetyMeetingService.uploadEvidenceFile's real path shape",
  async () => {
    const storage = storageFor("foreman-a");
    const fileRef = ref(
      storage,
      `organizations/${ORG_A}/daily_safety_meetings/meeting-1/` +
        "evidence-1/photo.jpg"
    );

    await assertSucceeds(uploadBytes(fileRef, SOME_BYTES));
    await assertSucceeds(getBytes(fileRef));
  });
});

describe("Safety Learning library files (published server-side only)", () => {
  // A fresh upload id per test — `clearStorage()` does not reliably remove
  // nested files between tests.
  let uploadCounter = 0;
  let uploadId;
  beforeEach(() => {
    uploadCounter += 1;
    uploadId = `${Date.now()}-${uploadCounter}`;
  });
  const asVideo = {contentType: "video/mp4"};
  const libraryPath = () =>
    `organizations/${ORG_A}/safety_learning/${uploadId}/ladder.mp4`;
  const stagingPath = (uid) =>
    `learning_uploads/${uid}/${uploadId}/ladder.mp4`;

  /** What `publishLearningUpload` does with the Admin SDK. */
  async function publishAsServer() {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await uploadBytes(
        ref(context.storage(), libraryPath()),
        SOME_BYTES,
        asVideo
      );
    });
  }

  test("no client may create a library file directly — not even the " +
    "people allowed to author videos", async () => {
    for (const uid of ["admin-a", "site-manager-a", "worker-b"]) {
      await assertFails(
        uploadBytes(ref(storageFor(uid), libraryPath()), SOME_BYTES, asVideo)
      );
    }
  });

  test("a published library file can be read by any signed-in user, not " +
    "an anonymous one", async () => {
    await publishAsServer();
    await assertSucceeds(getBytes(ref(storageFor("worker-b"), libraryPath())));
    await assertFails(getBytes(ref(anonymousStorage(), libraryPath())));
  });

  test("a published library file cannot be overwritten or deleted by any " +
    "client", async () => {
    await publishAsServer();
    for (const uid of ["admin-a", "worker-b"]) {
      await assertFails(
        uploadBytes(ref(storageFor(uid), libraryPath()),
          new Uint8Array([9, 9]), asVideo)
      );
      await assertFails(deleteObject(ref(storageFor(uid), libraryPath())));
    }
    const bytes = await getBytes(ref(storageFor("admin-a"), libraryPath()));
    expect(new Uint8Array(bytes)).toEqual(SOME_BYTES);
  });

  test("an author can stage an upload in their OWN folder, read it back " +
    "and delete it", async () => {
    const fileRef = ref(storageFor("site-manager-a"),
      stagingPath("site-manager-a"));
    await assertSucceeds(uploadBytes(fileRef, SOME_BYTES, asVideo));
    await assertSucceeds(getBytes(fileRef));
    await assertSucceeds(deleteObject(fileRef));
  });

  test("nobody else can stage into, read or delete someone's staging " +
    "folder", async () => {
    await assertSucceeds(
      uploadBytes(ref(storageFor("site-manager-a"),
        stagingPath("site-manager-a")), SOME_BYTES, asVideo)
    );
    const asOther = ref(storageFor("worker-b"), stagingPath("site-manager-a"));
    await assertFails(getBytes(asOther));
    await assertFails(deleteObject(asOther));
    await assertFails(
      uploadBytes(
        ref(storageFor("worker-b"),
          `learning_uploads/site-manager-a/${uploadId}-x/other.mp4`),
        SOME_BYTES,
        asVideo
      )
    );
    await assertFails(
      uploadBytes(ref(anonymousStorage(), stagingPath("anon")), SOME_BYTES,
        asVideo)
    );
  });

  test("a staged file cannot be overwritten", async () => {
    const fileRef = ref(storageFor("site-manager-a"),
      stagingPath("site-manager-a"));
    await assertSucceeds(uploadBytes(fileRef, SOME_BYTES, asVideo));
    await assertFails(uploadBytes(fileRef, new Uint8Array([7]), asVideo));
  });

  test("staging accepts the library's file types only", async () => {
    const storage = storageFor("admin-a");
    for (const [name, contentType] of [
      ["handbook.pdf", "application/pdf"],
      ["slides.pptx", "application/vnd.openxmlformats-officedocument." +
        "presentationml.presentation"],
      ["sheet.xls", "application/vnd.ms-excel"],
      ["guide.png", "image/png"],
      ["clip.mov", "video/quicktime"],
    ]) {
      await assertSucceeds(
        uploadBytes(
          ref(storage, `learning_uploads/admin-a/${uploadId}/${name}`),
          SOME_BYTES,
          {contentType}
        )
      );
    }
    for (const [name, contentType] of [
      ["page.html", "text/html"],
      ["script.js", "application/javascript"],
      ["blob.bin", "application/octet-stream"],
    ]) {
      await assertFails(
        uploadBytes(
          ref(storage, `learning_uploads/admin-a/${uploadId}/${name}`),
          SOME_BYTES,
          {contentType}
        )
      );
    }
  });

  test("a staged file of 25MB or more is refused", async () => {
    await assertFails(
      uploadBytes(ref(storageFor("admin-a"), stagingPath("admin-a")),
        new Uint8Array(25 * 1024 * 1024), asVideo)
    );
  });

  test("staging paths outside {uid}/{uploadId}/{fileName} are refused",
    async () => {
      const storage = storageFor("admin-a");
      for (const filePath of [
        "learning_uploads/admin-a/ladder.mp4",
        `learning_uploads/admin-a/${uploadId}/nested/ladder.mp4`,
      ]) {
        await assertFails(
          uploadBytes(ref(storage, filePath), SOME_BYTES, asVideo)
        );
      }
    });

  test("other organization folders still allow rewrites and deletes " +
    "(regression: e.g. the offline outbox re-uploading)", async () => {
    const storage = storageFor("worker-a");
    const fileRef = ref(
      storage,
      `organizations/${ORG_A}/corrective_actions/action-1/1_photo.jpg`
    );
    await assertSucceeds(uploadBytes(fileRef, SOME_BYTES));
    await assertSucceeds(uploadBytes(fileRef, new Uint8Array([5])));
    await assertSucceeds(deleteObject(fileRef));
  });
});
