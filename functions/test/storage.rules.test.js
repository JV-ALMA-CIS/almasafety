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
 * delete (no `request.resource`) still succeeds.
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
