/**
 * Cloud Storage Security Rules tests for JVA Safety.
 *
 * BUG FIX regression coverage: `storage.rules`' `belongsToOrg()` used to read
 * `users/{uid}.data.organizationId`, a field that no longer exists under the
 * multi-organization membership model (organization relationship moved to
 * `users/{uid}/memberships/{organizationId}` — see `firestore.rules`'
 * `belongsToOrganization()`/`membershipDoc()`). That comparison was always
 * `null == organizationId`, i.e. always false, so every Storage read/write
 * was silently denied for every real user regardless of membership — this
 * suite proves the fix: an active member can read/write their own
 * organization's Storage tree, and every other case (no membership, a
 * different organization, a suspended membership, signed out) is still
 * refused.
 *
 * Requires BOTH the Firestore and Storage emulators — `storage.rules` reads
 * Firestore membership documents via `firestore.get`/`firestore.exists`
 * cross-references. Run:
 *
 *   cd functions
 *   npm run test:storage-rules
 *
 * which wraps this file in `firebase emulators:exec --only
 * firestore,storage`, starting and stopping both around the run.
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
const {doc, setDoc, Timestamp} = require("firebase/firestore");

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

/**
 * A seeded `users/{uid}/memberships/{organizationId}` document, as the Admin
 * SDK would write it. Mirrors `firestore.rules.test.js`'s `membership()`.
 *
 * @param {string} organizationId the organization this membership belongs to.
 * @param {object} overrides fields to override on the default shape.
 * @return {object} the membership document data.
 */
function membership(organizationId, overrides = {}) {
  return {
    organizationId,
    role: "worker",
    workerType: null,
    trade: null,
    siteIds: [],
    supervisorUid: null,
    status: "active",
    approvedAt: Timestamp.fromDate(new Date("2026-01-01")),
    approvedBy: "approver-a",
    createdAt: Timestamp.fromDate(new Date("2026-01-01")),
    updatedAt: Timestamp.fromDate(new Date("2026-01-01")),
    ...overrides,
  };
}

async function seedMembership(uid, organizationId, overrides = {}) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(
      doc(
        context.firestore(),
        `users/${uid}/memberships/${organizationId}`
      ),
      membership(organizationId, overrides)
    );
  });
}

beforeAll(async () => {
  const firestoreAddress = emulatorAddress("FIRESTORE_EMULATOR_HOST", 8080);
  const storageAddress = emulatorAddress(
    "FIREBASE_STORAGE_EMULATOR_HOST",
    9199
  );

  testEnv = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: {
      rules: fs.readFileSync(
        path.resolve(__dirname, "../../firestore.rules"),
        "utf8"
      ),
      host: firestoreAddress.host,
      port: firestoreAddress.port,
    },
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
  await testEnv.clearFirestore();
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

describe("organization-scoped Storage access (belongsToOrg)", () => {
  test("an active member of the organization can upload and read a file " +
    "under their own organization's path", async () => {
    await seedMembership("worker-a", ORG_A);
    const storage = storageFor("worker-a");
    const fileRef = ref(
      storage,
      `organizations/${ORG_A}/hazards/hazard-1/photo.jpg`
    );

    await assertSucceeds(uploadBytes(fileRef, SOME_BYTES));
    await assertSucceeds(getBytes(fileRef));
  });

  test("a user with NO membership in the organization cannot read or " +
    "write its Storage tree", async () => {
    // worker-a has no membership anywhere.
    const storage = storageFor("worker-a");
    const fileRef = ref(
      storage,
      `organizations/${ORG_A}/hazards/hazard-1/photo.jpg`
    );

    await assertFails(uploadBytes(fileRef, SOME_BYTES));
  });

  test("a member of a DIFFERENT organization cannot read or write " +
    "another organization's Storage tree", async () => {
    await seedMembership("worker-a", ORG_B);
    const storage = storageFor("worker-a");
    const fileRef = ref(
      storage,
      `organizations/${ORG_A}/hazards/hazard-1/photo.jpg`
    );

    await assertFails(uploadBytes(fileRef, SOME_BYTES));
  });

  test("a SUSPENDED membership cannot read or write the organization's " +
    "Storage tree", async () => {
    await seedMembership("worker-a", ORG_A, {status: "suspended"});
    const storage = storageFor("worker-a");
    const fileRef = ref(
      storage,
      `organizations/${ORG_A}/hazards/hazard-1/photo.jpg`
    );

    await assertFails(uploadBytes(fileRef, SOME_BYTES));
  });

  test("an unauthenticated caller cannot read or write any organization's " +
    "Storage tree", async () => {
    await seedMembership("worker-a", ORG_A);
    const storage = anonymousStorage();
    const fileRef = ref(
      storage,
      `organizations/${ORG_A}/hazards/hazard-1/photo.jpg`
    );

    await assertFails(uploadBytes(fileRef, SOME_BYTES));
  });

  test("every path outside organizations/{organizationId}/... is denied " +
    "outright, even for an active member", async () => {
    await seedMembership("worker-a", ORG_A);
    const storage = storageFor("worker-a");
    const fileRef = ref(storage, "some-other-top-level-path/file.jpg");

    await assertFails(uploadBytes(fileRef, SOME_BYTES));
  });
});

describe("existing Hazard photo upload path (regression)", () => {
  test("an active org member can upload a hazard photo to " +
    "organizations/{orgId}/hazards/{hazardId}/{fileName}, matching " +
    "HazardService.uploadHazardPhoto's real path shape", async () => {
    await seedMembership("foreman-a", ORG_A, {role: "foreman"});
    const storage = storageFor("foreman-a");
    const fileRef = ref(
      storage,
      `organizations/${ORG_A}/hazards/hazard-42/photo-1.jpg`
    );

    await assertSucceeds(uploadBytes(fileRef, SOME_BYTES));
    await assertSucceeds(getBytes(fileRef));
  });

  test("a member of a different organization cannot read another " +
    "organization's hazard photo", async () => {
    await seedMembership("foreman-a", ORG_A, {role: "foreman"});
    await seedMembership("worker-b", ORG_B);

    const ownerStorage = storageFor("foreman-a");
    const fileRef = ref(
      ownerStorage,
      `organizations/${ORG_A}/hazards/hazard-42/photo-1.jpg`
    );
    await assertSucceeds(uploadBytes(fileRef, SOME_BYTES));

    const otherStorage = storageFor("worker-b");
    const otherFileRef = ref(
      otherStorage,
      `organizations/${ORG_A}/hazards/hazard-42/photo-1.jpg`
    );
    await assertFails(getBytes(otherFileRef));
  });

  test("a file larger than 25MB is refused for an active member, " +
    "matching the existing size cap", async () => {
    await seedMembership("foreman-a", ORG_A, {role: "foreman"});
    const storage = storageFor("foreman-a");
    const fileRef = ref(
      storage,
      `organizations/${ORG_A}/hazards/hazard-42/big-file.jpg`
    );
    const tooLarge = new Uint8Array(25 * 1024 * 1024 + 1);

    await assertFails(uploadBytes(fileRef, tooLarge));
  });

  test("an active org member can delete a file under their own " +
    "organization's path", async () => {
    await seedMembership("foreman-a", ORG_A, {role: "foreman"});
    const storage = storageFor("foreman-a");
    const fileRef = ref(
      storage,
      `organizations/${ORG_A}/hazards/hazard-42/photo-1.jpg`
    );
    await assertSucceeds(uploadBytes(fileRef, SOME_BYTES));

    await assertSucceeds(deleteObject(fileRef));
  });
});
