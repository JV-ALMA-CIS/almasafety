/**
 * Seeds the LOCAL Firebase emulators with test-only accounts and data for
 * manual testing of JVA Safety (see EMULATOR_MANUAL_TEST.md).
 *
 *   firebase --config firebase.emulators.json emulators:exec ... (or start)
 *   node functions/scripts/seed_emulators.js
 *
 * Refuses to run unless it is pointed at the emulators of a `demo-` project,
 * so it can never write to real Firebase. All passwords are test values for
 * the emulator only.
 */
const {initializeApp} = require("firebase-admin/app");
const {getAuth} = require("firebase-admin/auth");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");

const PROJECT_ID = "demo-jva-safety";
process.env.GCLOUD_PROJECT = PROJECT_ID;
process.env.FIRESTORE_EMULATOR_HOST ??= "127.0.0.1:8085";
process.env.FIREBASE_AUTH_EMULATOR_HOST ??= "127.0.0.1:9099";

if (!PROJECT_ID.startsWith("demo-") ||
  !process.env.FIRESTORE_EMULATOR_HOST ||
  !process.env.FIREBASE_AUTH_EMULATOR_HOST) {
  console.error("Refusing to run: emulators and a demo- project only.");
  process.exit(1);
}

initializeApp({projectId: PROJECT_ID});
const db = getFirestore();
const auth = getAuth();

const ORG = "org-jva";
const PASSWORD = "Test-only-123!";
const PEOPLE = [
  {uid: "admin-test", email: "admin@test.local", name: "Test Admin",
    admin: true},
  {uid: "sm-test", email: "sitemanager@test.local", name: "Test Site Manager",
    role: "siteManager"},
  {uid: "foreman-test", email: "foreman@test.local", name: "Test Foreman",
    role: "foreman"},
  {uid: "worker-test", email: "worker@test.local", name: "Test Worker",
    role: "worker"},
];

async function main() {
  const now = FieldValue.serverTimestamp();
  for (const person of PEOPLE) {
    try {
      await auth.createUser({
        uid: person.uid,
        email: person.email,
        password: PASSWORD,
        displayName: person.name,
      });
    } catch (error) {
      if (error.code !== "auth/uid-already-exists") throw error;
    }
    await db.doc(`users/${person.uid}`).set({
      uid: person.uid,
      name: person.name,
      email: person.email,
      accountStatus: "active",
      ...(person.admin ? {platformRole: "admin"} : {}),
      createdAt: now,
      updatedAt: now,
    });
    if (person.role) {
      await db.doc(`users/${person.uid}/memberships/${ORG}`).set({
        organizationId: ORG,
        role: person.role,
        status: "active",
        siteIds: ["site-1"],
        workerType: null,
        trade: null,
        approvedAt: now,
        approvedBy: "admin-test",
        createdAt: now,
        updatedAt: now,
      });
    }
  }

  await db.doc(`organizations/${ORG}`).set({
    name: "JV ALMA CIS (test)", code: "JVA", status: "active",
    createdAt: now, updatedAt: now,
  });
  await db.doc(`organizations/${ORG}/projects/project-1`).set({
    organizationId: ORG, name: "Test Project", code: "TP1", status: "active",
    createdAt: now, updatedAt: now,
  });
  await db.doc(`organizations/${ORG}/sites/site-1`).set({
    organizationId: ORG, projectId: "project-1", name: "Test Site",
    code: "TS1", status: "active", createdAt: now, updatedAt: now,
  });
  await db.doc(`organizations/${ORG}/activities/activity-1`).set({
    organizationId: ORG, projectId: "project-1", siteId: "site-1",
    name: "Working at Height", code: "WAH", status: "active",
    createdAt: now, updatedAt: now,
  });
  await db.doc(
    `organizations/${ORG}/activities/activity-1/assignments/worker-test`
  ).set({
    uid: "worker-test", organizationId: ORG, siteId: "site-1",
    activityId: "activity-1", projectId: "project-1",
    assignedAt: now, assignedBy: "sm-test",
  });

  console.log(`Seeded ${PROJECT_ID}: organization ${ORG}, Test Site, ` +
    "activity Working at Height (Test Worker assigned).");
  console.log(`Accounts (password for all: ${PASSWORD}):`);
  for (const person of PEOPLE) {
    console.log(`  ${person.email}  ${person.admin ? "admin" : person.role}`);
  }
}

main().then(() => process.exit(0), (error) => {
  console.error(error);
  process.exit(1);
});
