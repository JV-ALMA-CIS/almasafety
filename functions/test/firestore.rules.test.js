/**
 * Firestore Security Rules tests for JVA Safety authentication.
 *
 * These assert the *real* authorization boundary. The Flutter client's
 * SessionController checks are usability only, so the guarantees that
 * actually matter — that a user cannot approve themselves, assign themselves
 * an organization, or reach operational data while pending/suspended/rejected
 * — are verified here against the rules themselves.
 *
 * Requires the Firestore emulator. Run:
 *
 *   cd functions
 *   npm run test:rules
 *
 * which wraps this file in `firebase emulators:exec`, starting and stopping
 * the emulator around the run.
 *
 * Model under test: SELF-REGISTRATION -> PENDING -> ADMIN APPROVAL -> ACTIVE.
 * Profiles live at the top level (`users/{uid}`) because a pending user has
 * no organization to be scoped under. `accountStatus` is the single
 * authoritative account-state field.
 */

const fs = require("fs");
const path = require("path");
const {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} = require("@firebase/rules-unit-testing");
const {serverTimestamp} = require("firebase/firestore");

const PROJECT_ID = "jva-safety-rules-test";

const ORG_A = "org-alpha";
const ORG_B = "org-beta";

let testEnv;

/**
 * Resolves the emulator address from FIRESTORE_EMULATOR_HOST, which
 * `firebase emulators:exec` exports for us.
 */
function emulatorAddress() {
  const fromEnv = process.env.FIRESTORE_EMULATOR_HOST;
  if (fromEnv) {
    const separator = fromEnv.lastIndexOf(":");
    return {
      host: fromEnv.slice(0, separator),
      port: Number(fromEnv.slice(separator + 1)),
    };
  }
  return {host: "127.0.0.1", port: 8080};
}

/**
 * An authenticated context. The rules read account state from the profile
 * document rather than from claims, so the only token field that matters is
 * `email` — which registration binds the new profile's email to.
 */
function actor(uid, email) {
  return testEnv
    .authenticatedContext(uid, {email, email_verified: true})
    .firestore();
}

function userPath(uid) {
  return `users/${uid}`;
}

function assignmentPath(organizationId, activityId, uid) {
  return `organizations/${organizationId}/activities/${activityId}` +
    `/assignments/${uid}`;
}

/**
 * A seeded (already-reviewed) profile, as the Admin SDK would write it.
 *
 * Under the multi-organization membership model, `organizationId` is no
 * longer read by the rules from this document at all — a user's
 * organization relationship lives on `users/{uid}/memberships/{orgId}`
 * instead (see [membership]/[seedMembership] below). It is harmless to keep
 * accepting/setting it here for backward compatibility with tests that
 * still pass it through `overrides` (the rules simply ignore it), but new
 * tests should rely on a real seeded membership document for any
 * `belongsToOrganization` behavior.
 */
function profile(uid, accountStatus, overrides = {}) {
  return {
    uid,
    name: "Test User",
    email: `${uid}@example.com`,
    phone: "+254700000000",
    accountStatus,
    createdAt: new Date("2026-01-01"),
    updatedAt: new Date("2026-01-01"),
    ...overrides,
  };
}

/**
 * A seeded `users/{uid}/memberships/{organizationId}` document, as the
 * Admin SDK would write it (`approveAccount`/`addMembership`/
 * `createOrganization`). Defaults to `status: "active"` — the common case —
 * and a `worker` role, since most read-boundary tests only care about
 * organization membership, not the specific role.
 */
function membership(uid, organizationId, overrides = {}) {
  return {
    organizationId,
    role: "worker",
    workerType: null,
    trade: null,
    siteIds: [],
    supervisorUid: null,
    status: "active",
    approvedAt: new Date("2026-01-01"),
    approvedBy: "approver-a",
    createdAt: new Date("2026-01-01"),
    updatedAt: new Date("2026-01-01"),
    ...overrides,
  };
}

/**
 * A well-formed self-registration payload — the exact shape the client
 * builds in UserProfile.registrationPayload.
 */
function registration(uid, overrides = {}) {
  return {
    uid,
    name: "New User",
    email: `${uid}@example.com`,
    phone: "+254700000000",
    accountStatus: "pending",
    // The rules require these to equal request.time, which only a server
    // timestamp satisfies — a client-supplied Date is exactly what the
    // "cannot backdate createdAt" test below proves is rejected.
    createdAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
    ...overrides,
  };
}

/** Seeds documents with rules disabled, as the Admin SDK would. */
async function seed(writer) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await writer(context.firestore());
  });
}

beforeAll(async () => {
  const {host, port} = emulatorAddress();
  testEnv = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: {
      rules: fs.readFileSync(
        path.resolve(__dirname, "../../firestore.rules"),
        "utf8"
      ),
      host,
      port,
    },
  });
});

afterAll(async () => {
  if (testEnv) await testEnv.cleanup();
});

beforeEach(async () => {
  await testEnv.clearFirestore();

  // One account in each lifecycle state, plus an organization to reach for.
  await seed(async (db) => {
    await db.doc(userPath("active-a")).set(profile("active-a", "active"));
    await db
      .doc(`users/active-a/memberships/${ORG_A}`)
      .set(membership("active-a", ORG_A));
    await db.doc(userPath("pending-a")).set(
      profile("pending-a", "pending", {organizationId: null})
    );
    await db.doc(userPath("suspended-a")).set(
      profile("suspended-a", "suspended")
    );
    await db
      .doc(`users/suspended-a/memberships/${ORG_A}`)
      .set(membership("suspended-a", ORG_A));
    await db.doc(userPath("rejected-a")).set(
      profile("rejected-a", "rejected", {organizationId: null})
    );
    await db.doc(userPath("active-b")).set(
      profile("active-b", "active", {organizationId: ORG_B})
    );
    await db
      .doc(`users/active-b/memberships/${ORG_B}`)
      .set(membership("active-b", ORG_B));
    // A reviewer — the role the app's approvals screen requires. Written
    // here with rules disabled because that is the only way it can ever be
    // written: the operator script and approval callables use the Admin SDK
    // too.
    await db.doc(userPath("approver-a")).set(
      profile("approver-a", "active", {platformRole: "siteManager"})
    );
    await db
      .doc(`users/approver-a/memberships/${ORG_A}`)
      .set(membership("approver-a", ORG_A, {role: "siteManager"}));
    // The bootstrap Admin: platform-level, so no organizationId —
    // mirroring exactly what scripts/approve_account.ts's bootstrap-admin
    // command writes.
    await db.doc(userPath("sysadmin-a")).set(
      profile("sysadmin-a", "active", {
        platformRole: "admin",
        organizationId: null,
      })
    );

    await db.doc(`organizations/${ORG_A}`).set({name: "Org Alpha"});
    await db.doc(`organizations/${ORG_B}`).set({name: "Org Beta"});
    await db
      .doc(`organizations/${ORG_A}/hazards/hazard-1`)
      .set({organizationId: ORG_A, status: "open"});

    // A project and site under ORG_A, as `organization_callable.ts` would
    // write them, for the Organization -> Project -> Site foundation tests.
    await db.doc(`organizations/${ORG_A}/projects/project-1`).set({
      organizationId: ORG_A,
      name: "Rosslyn Tower",
      code: "ROSS-01",
      status: "active",
      createdAt: new Date(),
      updatedAt: new Date(),
      createdBy: "sysadmin-a",
      updatedBy: "sysadmin-a",
    });
    await db.doc(`organizations/${ORG_A}/sites/site-1`).set({
      organizationId: ORG_A,
      projectId: "project-1",
      name: "Rosslyn Site",
      code: "ROSS-SITE-01",
      status: "active",
      createdAt: new Date(),
      updatedAt: new Date(),
      createdBy: "sysadmin-a",
      updatedBy: "sysadmin-a",
    });
  });
});

describe("unauthenticated access", () => {
  test("cannot read any user profile", async () => {
    const db = testEnv.unauthenticatedContext().firestore();

    await assertFails(db.doc(userPath("active-a")).get());
    await assertFails(db.doc(userPath("pending-a")).get());
  });

  test("cannot create a profile", async () => {
    const db = testEnv.unauthenticatedContext().firestore();

    await assertFails(
      db.doc(userPath("brand-new")).set(registration("brand-new"))
    );
  });

  test("cannot read organization or operational data", async () => {
    const db = testEnv.unauthenticatedContext().firestore();

    await assertFails(db.doc(`organizations/${ORG_A}`).get());
    await assertFails(db.doc(`organizations/${ORG_A}/hazards/hazard-1`).get());
  });
});

describe("self-registration", () => {
  test("a new user may create their own pending profile", async () => {
    const db = actor("new-user", "new-user@example.com");

    await assertSucceeds(
      db.doc(userPath("new-user")).set(registration("new-user"))
    );
  });

  test("cannot register with accountStatus active", async () => {
    const db = actor("new-user", "new-user@example.com");

    await assertFails(
      db
        .doc(userPath("new-user"))
        .set(registration("new-user", {accountStatus: "active"}))
    );
  });

  test("cannot register as suspended or rejected either", async () => {
    const db = actor("new-user", "new-user@example.com");

    for (const status of ["suspended", "rejected", "approved", ""]) {
      await assertFails(
        db
          .doc(userPath("new-user"))
          .set(registration("new-user", {accountStatus: status}))
      );
    }
  });

  test("cannot self-assign an organizationId at registration", async () => {
    const db = actor("new-user", "new-user@example.com");

    await assertFails(
      db
        .doc(userPath("new-user"))
        .set(registration("new-user", {organizationId: ORG_A}))
    );
  });

  test("cannot self-approve at registration", async () => {
    const db = actor("new-user", "new-user@example.com");

    await assertFails(
      db
        .doc(userPath("new-user"))
        .set(registration("new-user", {approvedBy: "new-user"}))
    );
    await assertFails(
      db
        .doc(userPath("new-user"))
        .set(registration("new-user", {approvedAt: new Date()}))
    );
  });

  test("cannot grant themselves a role at registration", async () => {
    const db = actor("new-user", "new-user@example.com");

    await assertFails(
      db
        .doc(userPath("new-user"))
        .set(registration("new-user", {platformRole: "siteManager"}))
    );
  });

  test("cannot self-assign a workerType at registration", async () => {
    const db = actor("new-user", "new-user@example.com");

    await assertFails(
      db
        .doc(userPath("new-user"))
        .set(registration("new-user", {workerType: "contractor"}))
    );
  });

  test("cannot self-assign sites or activities at registration", async () => {
    const db = actor("new-user", "new-user@example.com");

    await assertFails(
      db
        .doc(userPath("new-user"))
        .set(registration("new-user", {siteIds: ["site-1"]}))
    );
    await assertFails(
      db
        .doc(userPath("new-user"))
        .set(registration("new-user", {activityIds: ["act-1"]}))
    );
  });

  test("cannot resurrect the old `active` boolean", async () => {
    const db = actor("new-user", "new-user@example.com");

    await assertFails(
      db.doc(userPath("new-user")).set(registration("new-user", {active: true}))
    );
  });

  test("cannot create a profile for somebody else", async () => {
    const db = actor("new-user", "new-user@example.com");

    await assertFails(
      db.doc(userPath("victim")).set(registration("victim"))
    );
  });

  test("cannot register under another person's email", async () => {
    const db = actor("new-user", "new-user@example.com");

    await assertFails(
      db
        .doc(userPath("new-user"))
        .set(registration("new-user", {email: "ceo@example.com"}))
    );
  });

  test("cannot overwrite an existing profile via create", async () => {
    // `set` on an existing document is an update, so the far stricter
    // update rules apply and the privileged fields are protected.
    const db = actor("active-a", "active-a@example.com");

    await assertFails(
      db.doc(userPath("active-a")).set(registration("active-a"))
    );
  });

  test("cannot backdate createdAt", async () => {
    const db = actor("new-user", "new-user@example.com");

    await assertFails(
      db
        .doc(userPath("new-user"))
        .set(registration("new-user", {createdAt: new Date("2020-01-01")}))
    );
  });

  test("cannot register with an empty name", async () => {
    const db = actor("new-user", "new-user@example.com");

    await assertFails(
      db.doc(userPath("new-user")).set(registration("new-user", {name: ""}))
    );
  });
});

describe("reading own profile", () => {
  test("an active user can read their own profile", async () => {
    const db = actor("active-a", "active-a@example.com");

    await assertSucceeds(db.doc(userPath("active-a")).get());
  });

  test("a pending user can read their own profile", async () => {
    // Required: the pending screen watches this document to learn the
    // moment it is approved.
    const db = actor("pending-a", "pending-a@example.com");

    await assertSucceeds(db.doc(userPath("pending-a")).get());
  });

  test("suspended and rejected users can still read their own profile",
    async () => {
      await assertSucceeds(
        actor("suspended-a", "s@example.com").doc(userPath("suspended-a")).get()
      );
      await assertSucceeds(
        actor("rejected-a", "r@example.com").doc(userPath("rejected-a")).get()
      );
    });

  test("no user can read another user's profile", async () => {
    const db = actor("active-a", "active-a@example.com");

    await assertFails(db.doc(userPath("pending-a")).get());
    await assertFails(db.doc(userPath("active-b")).get());
  });

  test("no user can list the whole users collection", async () => {
    const db = actor("active-a", "active-a@example.com");

    await assertFails(db.collection("users").get());
  });
});

describe("self-service profile updates", () => {
  test("a user may update their own name and phone", async () => {
    const db = actor("active-a", "active-a@example.com");

    await assertSucceeds(
      db.doc(userPath("active-a")).update({
        name: "New Name",
        phone: "+254711111111",
        updatedAt: serverTimestamp(),
      })
    );
  });

  test("a user may not add a workerType field to their profile", async () => {
    const db = actor("active-a", "active-a@example.com");

    await assertFails(
      db.doc(userPath("active-a")).update({
        workerType: "contractor",
        updatedAt: serverTimestamp(),
      })
    );
  });

  test("a pending user may correct their own name while waiting", async () => {
    const db = actor("pending-a", "pending-a@example.com");

    await assertSucceeds(
      db
        .doc(userPath("pending-a"))
        .update({name: "Corrected Name", updatedAt: serverTimestamp()})
    );
  });

  test("a user may not approve themselves", async () => {
    const db = actor("pending-a", "pending-a@example.com");

    await assertFails(
      db.doc(userPath("pending-a")).update({accountStatus: "active"})
    );
  });

  test("a suspended user cannot un-suspend themselves", async () => {
    const db = actor("suspended-a", "s@example.com");

    await assertFails(
      db.doc(userPath("suspended-a")).update({accountStatus: "active"})
    );
  });

  test("a rejected user cannot revert themselves to pending", async () => {
    const db = actor("rejected-a", "r@example.com");

    await assertFails(
      db.doc(userPath("rejected-a")).update({accountStatus: "pending"})
    );
  });

  test("a user may not assign themselves an organization", async () => {
    const db = actor("pending-a", "pending-a@example.com");

    await assertFails(
      db.doc(userPath("pending-a")).update({organizationId: ORG_A})
    );
  });

  test("an active user may not move themselves to another organization",
    async () => {
      const db = actor("active-a", "active-a@example.com");

      await assertFails(
        db.doc(userPath("active-a")).update({organizationId: ORG_B})
      );
    });

  test("a user may not forge the approval audit trail", async () => {
    const db = actor("pending-a", "pending-a@example.com");

    await assertFails(
      db.doc(userPath("pending-a")).update({approvedBy: "pending-a"})
    );
    await assertFails(
      db.doc(userPath("pending-a")).update({approvedAt: new Date()})
    );
  });

  test("a user may not grant themselves a role", async () => {
    const db = actor("active-a", "active-a@example.com");

    await assertFails(
      db.doc(userPath("active-a")).update({platformRole: "siteManager"})
    );
  });

  test("a reviewer may not change their own role either", async () => {
    // Escalation-in-place matters as much as first grant: a reviewer must
    // not be able to widen or otherwise alter their own role by direct
    // write, only through review of somebody else's account, which this
    // update path is not.
    const db = actor("approver-a", "approver-a@example.com");

    await assertFails(
      db.doc(userPath("approver-a")).update({platformRole: "admin"})
    );
  });

  test("a user may not forge createdAt, uid or email", async () => {
    const db = actor("active-a", "active-a@example.com");

    await assertFails(
      db.doc(userPath("active-a")).update({createdAt: new Date(0)})
    );
    await assertFails(
      db.doc(userPath("active-a")).update({uid: "somebody-else"})
    );
    await assertFails(
      db.doc(userPath("active-a")).update({email: "attacker@example.com"})
    );
  });

  test("bundling a legal field with a protected one is still rejected",
    async () => {
      const db = actor("pending-a", "pending-a@example.com");

      await assertFails(
        db
          .doc(userPath("pending-a"))
          .update({name: "Legit", accountStatus: "active"})
      );
      await assertFails(
        db
          .doc(userPath("pending-a"))
          .update({phone: "+254700000001", organizationId: ORG_A})
      );
    });

  test("a user cannot edit somebody else's profile", async () => {
    const db = actor("active-a", "active-a@example.com");

    await assertFails(
      db.doc(userPath("pending-a")).update({name: "Tampered"})
    );
    await assertFails(
      db.doc(userPath("pending-a")).update({accountStatus: "rejected"})
    );
  });

  test("a user may not backdate updatedAt", async () => {
    const db = actor("active-a", "active-a@example.com");

    await assertFails(
      db.doc(userPath("active-a")).update({
        name: "New Name",
        updatedAt: new Date("2020-01-01"),
      })
    );
  });

  test("profiles cannot be deleted, so history is preserved", async () => {
    await assertFails(
      actor("active-a", "a@example.com").doc(userPath("active-a")).delete()
    );
    await assertFails(
      actor("rejected-a", "r@example.com").doc(userPath("rejected-a")).delete()
    );
  });
});

describe("the reviewer role", () => {
  // DESIGN NOTE. Review (approve/reject, and assigning organization, role
  // and worker type) is performed by Cloud Functions callables
  // (`approval_callable.ts`), which run on the Admin SDK and check the
  // caller's `platformRole` field server-side. These rules therefore grant
  // `platformRole` NO power of its own — deliberately, so there is only one
  // implementation of the reviewer check rather than two that could drift.
  //
  // What these tests pin down is that boundary: a role cannot be
  // self-granted, and holding a reviewer role widens a client's direct
  // Firestore reach by exactly nothing.

  test("cannot be granted at registration", async () => {
    const db = actor("new-user", "new-user@example.com");

    await assertFails(
      db
        .doc(userPath("new-user"))
        .set(registration("new-user", {platformRole: "siteManager"}))
    );
  });

  test("a user cannot grant it to themselves", async () => {
    const db = actor("active-a", "active-a@example.com");

    await assertFails(
      db.doc(userPath("active-a")).update({platformRole: "siteManager"})
    );
  });

  test("a pending user cannot grant it to themselves", async () => {
    const db = actor("pending-a", "pending-a@example.com");

    await assertFails(
      db.doc(userPath("pending-a")).update({platformRole: "siteManager"})
    );
  });

  test("a reviewer cannot mint another reviewer by direct write", async () => {
    // The escalation that matters: holding a reviewer role must not make
    // it grantable via a direct write. Only the callables (which apply their
    // own escalation checks) and the operator script (Admin SDK) can write
    // it.
    const db = actor("approver-a", "approver-a@example.com");

    await assertFails(
      db.doc(userPath("active-a")).update({platformRole: "siteManager"})
    );
    await assertFails(
      db.doc(userPath("pending-a")).update({platformRole: "siteManager"})
    );
  });

  test("a reviewer cannot re-grant their own role once revoked", async () => {
    const db = actor("active-a", "active-a@example.com");

    await assertFails(
      db.doc(userPath("active-a")).update({
        platformRole: "siteManager",
        updatedAt: serverTimestamp(),
      })
    );
  });

  test("bundling it with a legal field is still rejected", async () => {
    const db = actor("active-a", "active-a@example.com");

    await assertFails(
      db.doc(userPath("active-a")).update({
        name: "Legit Name",
        platformRole: "siteManager",
        updatedAt: serverTimestamp(),
      })
    );
  });

  test("a reviewer still cannot read another user's profile directly",
    async () => {
      // The approvals screen reads the queue through the
      // `listPendingApprovals` callable, which uses the Admin SDK and so
      // bypasses these rules. The client's own read surface stays "your own
      // document only" — including for reviewers.
      const db = actor("approver-a", "approver-a@example.com");

      await assertFails(db.doc(userPath("pending-a")).get());
      await assertFails(db.doc(userPath("active-a")).get());
      await assertFails(db.doc(userPath("active-b")).get());
    });

  test("a reviewer cannot list the pending queue directly", async () => {
    const db = actor("approver-a", "approver-a@example.com");

    await assertFails(db.collection("users").get());
    await assertFails(
      db.collection("users").where("accountStatus", "==", "pending").get()
    );
  });

  test("a non-reviewer equally cannot read a pending profile", async () => {
    const db = actor("active-a", "active-a@example.com");

    await assertFails(db.doc(userPath("pending-a")).get());
  });

  test("a reviewer cannot approve anyone by direct write", async () => {
    // Approval must go through the callable, which verifies the role and
    // supplies the reviewer's own organization server-side.
    const db = actor("approver-a", "approver-a@example.com");

    await assertFails(
      db.doc(userPath("pending-a")).update({accountStatus: "active"})
    );
    await assertFails(
      db.doc(userPath("pending-a")).update({
        accountStatus: "active",
        organizationId: ORG_A,
        platformRole: "worker",
      })
    );
    await assertFails(
      db.doc(userPath("pending-a")).update({accountStatus: "rejected"})
    );
  });

  test("a reviewer cannot suspend or reinstate anyone by direct write",
    async () => {
      // Suspend/reinstate must go through the suspendActiveAccount /
      // reinstateSuspendedAccount callables, which additionally confine the
      // reviewer to their own organization — see
      // requireSameOrganizationTarget in approval_callable.ts.
      const db = actor("approver-a", "approver-a@example.com");

      await assertFails(
        db.doc(userPath("active-a")).update({accountStatus: "suspended"})
      );
      await assertFails(
        db.doc(userPath("suspended-a")).update({accountStatus: "active"})
      );
    });

  test("a reviewer can still read and edit their own profile", async () => {
    // The role is additive; it must not cost them anything.
    const db = actor("approver-a", "approver-a@example.com");

    await assertSucceeds(db.doc(userPath("approver-a")).get());
    await assertSucceeds(
      db.doc(userPath("approver-a")).update({
        name: "Renamed Approver",
        updatedAt: serverTimestamp(),
      })
    );
  });

  test("the role grants no operational reach beyond its own org",
    async () => {
      const db = actor("approver-a", "approver-a@example.com");

      await assertSucceeds(db.doc(`organizations/${ORG_A}`).get());
      await assertFails(db.doc(`organizations/${ORG_B}`).get());
      await assertFails(db.doc("audit_logs/log-1").get());
      await assertFails(
        db.doc(`organizations/${ORG_A}/hazards/hazard-2`).set({status: "open"})
      );
    });
});

describe("the bootstrap Admin", () => {
  // DESIGN NOTE. `admin` is a platform-level role, but these
  // rules deliberately give it no special case at all: it is written by the
  // Admin SDK exactly like any other role (only reachable via
  // scripts/approve_account.ts's bootstrap-admin command), and is protected
  // by the same field lists as every other role value. Reviewing pending
  // accounts, including granting the role platform-wide, remains a Cloud
  // Functions callable action — see approval_callable.ts's requireApprover
  // and resolveTargetOrganization. What these tests establish is that an
  // Admin's direct Firestore reach is exactly the same as any other active
  // user: their own profile, and organization data for whatever
  // organization they happen to belong to (none, in their case).

  test("cannot be self-granted at registration", async () => {
    const db = actor("new-user", "new-user@example.com");

    await assertFails(
      db
        .doc(userPath("new-user"))
        .set(registration("new-user", {platformRole: "admin"}))
    );
  });

  test("a user cannot grant themselves admin", async () => {
    const db = actor("active-a", "active-a@example.com");

    await assertFails(
      db.doc(userPath("active-a")).update({platformRole: "admin"})
    );
  });

  test("even an existing Admin cannot mint a second one by " +
    "direct write", async () => {
    // The privileged capability here — creating another platform
    // administrator — must stay reachable only through the operator script
    // under service-account credentials, never through any Firestore write
    // a signed-in user (however privileged) can make.
    const db = actor("sysadmin-a", "sysadmin-a@example.com");

    await assertFails(
      db.doc(userPath("active-a")).update({platformRole: "admin"})
    );
    await assertFails(
      db.doc(userPath("pending-a")).update({platformRole: "admin"})
    );
  });

  test("cannot approve, reject or activate anyone by direct write, " +
    "platform role notwithstanding", async () => {
    const db = actor("sysadmin-a", "sysadmin-a@example.com");

    await assertFails(
      db.doc(userPath("pending-a")).update({accountStatus: "active"})
    );
    await assertFails(
      db.doc(userPath("pending-a")).update({
        accountStatus: "active",
        organizationId: ORG_A,
        platformRole: "siteManager",
      })
    );
  });

  test("cannot act on its own account either", async () => {
    const db = actor("sysadmin-a", "sysadmin-a@example.com");

    await assertFails(
      db.doc(userPath("sysadmin-a")).update({accountStatus: "suspended"})
    );
    await assertFails(
      db.doc(userPath("sysadmin-a")).update({organizationId: ORG_A})
    );
  });

  test("cannot suspend or reinstate anyone by direct write, in any " +
    "organization", async () => {
    // Even though the Admin's authority is platform-wide via
    // the suspendActiveAccount / reinstateSuspendedAccount callables, direct
    // Firestore writes remain denied identically to every other role — see
    // the header note on this describe block.
    const db = actor("sysadmin-a", "sysadmin-a@example.com");

    await assertFails(
      db.doc(userPath("active-a")).update({accountStatus: "suspended"})
    );
    await assertFails(
      db.doc(userPath("active-b")).update({accountStatus: "suspended"})
    );
    await assertFails(
      db.doc(userPath("suspended-a")).update({accountStatus: "active"})
    );
  });

  test("can still read and edit only its own profile, like any user",
    async () => {
      const db = actor("sysadmin-a", "sysadmin-a@example.com");

      await assertSucceeds(db.doc(userPath("sysadmin-a")).get());
      await assertSucceeds(
        db.doc(userPath("sysadmin-a")).update({
          name: "Renamed Admin",
          updatedAt: serverTimestamp(),
        })
      );
      await assertFails(db.doc(userPath("active-a")).get());
      await assertFails(db.doc(userPath("pending-a")).get());
    });

  test("can read every organization directly, via isAdmin(), " +
    "but nothing else elevated", async () => {
    // The one deliberate read exception — see "the Organization -> Project
    // -> Site foundation" below for the full coverage of this grant. Every
    // other collection remains exactly as unreachable as for any org-less
    // account: audit logs and the users collection listing stay
    // Admin-SDK/self-only regardless of role.
    const db = actor("sysadmin-a", "sysadmin-a@example.com");

    await assertSucceeds(db.doc(`organizations/${ORG_A}`).get());
    await assertSucceeds(db.doc(`organizations/${ORG_B}`).get());
    await assertFails(db.doc("audit_logs/log-1").get());
    await assertFails(db.collection("users").get());
    // Operational collections beneath an organization also grant isAdmin()
    // a read, same as organizations/projects/sites — see the
    // `belongsToOrganization(organizationId) || isAdmin()` shape repeated
    // on every operational collection's read rule in firestore.rules.
    await assertSucceeds(
      db.doc(`organizations/${ORG_A}/hazards/hazard-1`).get()
    );
  });
});

describe("operational access is gated on accountStatus", () => {
  test("an active member can read their own organization's data", async () => {
    const db = actor("active-a", "active-a@example.com");

    await assertSucceeds(db.doc(`organizations/${ORG_A}`).get());
    await assertSucceeds(
      db.doc(`organizations/${ORG_A}/hazards/hazard-1`).get()
    );
  });

  test("a pending user reaches no operational data at all", async () => {
    const db = actor("pending-a", "pending-a@example.com");

    await assertFails(db.doc(`organizations/${ORG_A}`).get());
    await assertFails(db.doc(`organizations/${ORG_A}/hazards/hazard-1`).get());
    await assertFails(db.collection(`organizations/${ORG_A}/sites`).get());
  });

  test("a suspended user loses operational data access", async () => {
    const db = actor("suspended-a", "s@example.com");

    await assertFails(db.doc(`organizations/${ORG_A}`).get());
    await assertFails(db.doc(`organizations/${ORG_A}/hazards/hazard-1`).get());
  });

  test("a rejected user reaches nothing", async () => {
    const db = actor("rejected-a", "r@example.com");

    await assertFails(db.doc(`organizations/${ORG_A}`).get());
    await assertFails(db.doc(`organizations/${ORG_A}/hazards/hazard-1`).get());
  });

  test("a user with no profile document at all has no access", async () => {
    const db = actor("ghost", "ghost@example.com");

    await assertFails(db.doc(`organizations/${ORG_A}`).get());
    await assertFails(db.doc(`organizations/${ORG_A}/hazards/hazard-1`).get());
  });
});

describe("organization isolation", () => {
  test("an active user cannot read another organization's data", async () => {
    const db = actor("active-a", "active-a@example.com");

    await assertFails(db.doc(`organizations/${ORG_B}`).get());
    await assertFails(db.collection(`organizations/${ORG_B}/hazards`).get());
  });

  test("isolation holds in both directions", async () => {
    const db = actor("active-b", "active-b@example.com");

    await assertSucceeds(db.doc(`organizations/${ORG_B}`).get());
    await assertFails(db.doc(`organizations/${ORG_A}`).get());
  });
});

describe("operational writes await the RBAC stage", () => {
  test("even an active member cannot write operational data yet", async () => {
    // Deliberately more restrictive than the eventual model: there is no
    // role to authorize a write with, so no client may write at all.
    const db = actor("active-a", "active-a@example.com");

    await assertFails(
      db.doc(`organizations/${ORG_A}/hazards/hazard-2`).set({status: "open"})
    );
    await assertFails(
      db.doc(`organizations/${ORG_A}/sites/site-2`).set({name: "Rosslyn"})
    );
    await assertFails(db.doc(`organizations/${ORG_A}`).set({name: "Renamed"}));
  });
});

describe("the Organization -> Project -> Site foundation", () => {
  // DESIGN NOTE. Creating and editing organizations, projects and sites is
  // Admin-SDK-only via `organization_callable.ts`'s
  // `requireAdmin`, exactly like account review — these rules
  // give write access to NO client, Admin included.
  //
  // Reads: `projects` stays a flat "any active org member" grant — nothing
  // in the target authorization matrix scopes it. `sites` is PHASE 3-scoped:
  // Site Manager/Admin read every site in the organization; a Foreman or
  // Worker reads only a site that is in their OWN membership `siteIds` (see
  // firestore.rules' own doc comment on `sites/{siteId}`). `isAdmin()`
  // additionally lets an Admin read every organization's projects/sites,
  // since they belong to none of their own. `active-a`'s default membership
  // (set in the top-level `beforeEach`) is `role: "worker"` with no
  // `siteIds` — deliberately used here to exercise the "no site access
  // granted" case; a siteManager or a worker WITH a matching siteId is
  // exercised in the dedicated tests below.

  test("an org member can read their own organization's projects " +
    "(not scoped — every active member sees every project)", async () => {
    const db = actor("active-a", "active-a@example.com");

    await assertSucceeds(
      db.doc(`organizations/${ORG_A}/projects/project-1`).get()
    );
  });

  test("a Site Manager can read a site in their organization even with " +
    "no siteIds of their own — Site Manager authority is org-wide, not " +
    "site-scoped", async () => {
    await seed(async (db) => {
      await db
        .doc(`users/active-a/memberships/${ORG_A}`)
        .set(membership("active-a", ORG_A, {role: "siteManager"}));
    });
    const db = actor("active-a", "active-a@example.com");

    await assertSucceeds(
      db.doc(`organizations/${ORG_A}/sites/site-1`).get()
    );
  });

  test("a Foreman/Worker with site-1 in their own siteIds can read it",
    async () => {
      await seed(async (db) => {
        await db
          .doc(`users/active-a/memberships/${ORG_A}`)
          .set(membership("active-a", ORG_A, {
            role: "worker",
            siteIds: ["site-1"],
          }));
      });
      const db = actor("active-a", "active-a@example.com");

      await assertSucceeds(
        db.doc(`organizations/${ORG_A}/sites/site-1`).get()
      );
    });

  test("a Foreman/Worker WITHOUT site-1 in their own siteIds cannot read " +
    "it, even though they belong to the same organization", async () => {
    const db = actor("active-a", "active-a@example.com");

    // active-a's default membership (role: worker, siteIds: []) does not
    // include site-1 — a plain org membership is no longer enough on its
    // own for a non-Site-Manager caller.
    await assertFails(
      db.doc(`organizations/${ORG_A}/sites/site-1`).get()
    );
  });

  test("an org member cannot read another organization's projects or sites",
    async () => {
      const db = actor("active-a", "active-a@example.com");

      await assertFails(
        db.collection(`organizations/${ORG_B}/projects`).get()
      );
      await assertFails(db.collection(`organizations/${ORG_B}/sites`).get());
    });

  test("a pending/suspended/rejected user reads no project or site",
    async () => {
      await assertFails(
        actor("pending-a", "pending-a@example.com")
          .doc(`organizations/${ORG_A}/projects/project-1`)
          .get()
      );
      await assertFails(
        actor("suspended-a", "s@example.com")
          .doc(`organizations/${ORG_A}/sites/site-1`)
          .get()
      );
    });

  test("an Admin can read every organization's projects and " +
    "sites, not just one", async () => {
    const db = actor("sysadmin-a", "sysadmin-a@example.com");

    await assertSucceeds(
      db.doc(`organizations/${ORG_A}/projects/project-1`).get()
    );
    await assertSucceeds(
      db.doc(`organizations/${ORG_A}/sites/site-1`).get()
    );
    // ORG_B has no seeded project/site, but the read itself (a query
    // against the collection) must still be allowed rather than denied —
    // an empty result is a data fact, permission-denied would be an
    // authorization fact, and only the latter is being tested here.
    await assertSucceeds(
      db.collection(`organizations/${ORG_B}/projects`).get()
    );
  });

  test("no client, Admin included, can create an " +
    "organization by direct write", async () => {
    await assertFails(
      actor("sysadmin-a", "sysadmin-a@example.com")
        .doc("organizations/new-org")
        .set({name: "New Org", code: "NEW", status: "active"})
    );
  });

  test("no client, Admin included, can create a project by " +
    "direct write", async () => {
    await assertFails(
      actor("sysadmin-a", "sysadmin-a@example.com")
        .doc(`organizations/${ORG_A}/projects/project-2`)
        .set({
          organizationId: ORG_A,
          name: "New Project",
          code: "NEW-01",
          status: "active",
        })
    );
  });

  test("no client, Admin included, can create a site by " +
    "direct write", async () => {
    await assertFails(
      actor("sysadmin-a", "sysadmin-a@example.com")
        .doc(`organizations/${ORG_A}/sites/site-2`)
        .set({
          organizationId: ORG_A,
          projectId: "project-1",
          name: "New Site",
          code: "NEW-SITE-01",
          status: "active",
        })
    );
  });

  test("no client can update an existing project or site by direct write",
    async () => {
      const db = actor("sysadmin-a", "sysadmin-a@example.com");

      await assertFails(
        db
          .doc(`organizations/${ORG_A}/projects/project-1`)
          .update({status: "inactive"})
      );
      await assertFails(
        db
          .doc(`organizations/${ORG_A}/sites/site-1`)
          .update({status: "inactive"})
      );
    });

  test("a reviewer without the Admin role reads only their " +
    "own organization's records, same as any org member", async () => {
    const db = actor("approver-a", "approver-a@example.com");

    await assertSucceeds(
      db.doc(`organizations/${ORG_A}/projects/project-1`).get()
    );
    await assertFails(
      db.collection(`organizations/${ORG_B}/projects`).get()
    );
  });
});

describe("the Site -> Activity -> Worker Assignment foundation", () => {
  // DESIGN NOTE. Creating/editing activities and assigning/removing workers
  // are Admin-SDK-only via `activity_callable.ts` and
  // `activity_assignment_callable.ts` respectively, exactly like the
  // Organization -> Project -> Site foundation above. These rules give write
  // access to NO client for either collection.
  //
  // Reads: `activities` is PHASE 3-scoped the same way as `sites/{siteId}`
  // — Site Manager/Admin read every activity in the organization; a Foreman
  // or Worker reads only an activity whose OWN `siteId` is in their
  // membership `siteIds`. `assignments` (the subcollection) is deliberately
  // NOT scoped in this pass — see its own doc comment in firestore.rules —
  // and additionally needs to be reachable by a collection-group query (the
  // worker detail screen's "Assigned Activities" section reads across every
  // activity's assignments at once).

  beforeEach(async () => {
    await seed(async (db) => {
      await db.doc(`organizations/${ORG_A}/activities/activity-1`).set({
        organizationId: ORG_A,
        projectId: "project-1",
        siteId: "site-1",
        name: "Masonry",
        code: "MAS-01",
        status: "active",
        createdAt: new Date(),
        updatedAt: new Date(),
        createdBy: "sysadmin-a",
        updatedBy: "sysadmin-a",
      });
      await db
        .doc(assignmentPath(ORG_A, "activity-1", "active-a"))
        .set({
          uid: "active-a",
          organizationId: ORG_A,
          siteId: "site-1",
          activityId: "activity-1",
          assignedAt: new Date(),
          assignedBy: "sysadmin-a",
        });
    });
  });

  test("an org member (assignments — not site-scoped) can read their own " +
    "organization's assignments regardless of siteIds", async () => {
    const db = actor("active-a", "active-a@example.com");

    await assertSucceeds(
      db.doc(assignmentPath(ORG_A, "activity-1", "active-a")).get()
    );
  });

  test("a Site Manager can read an activity in their organization even " +
    "with no siteIds of their own", async () => {
    await seed(async (db) => {
      await db
        .doc(`users/active-a/memberships/${ORG_A}`)
        .set(membership("active-a", ORG_A, {role: "siteManager"}));
    });
    const db = actor("active-a", "active-a@example.com");

    await assertSucceeds(
      db.doc(`organizations/${ORG_A}/activities/activity-1`).get()
    );
  });

  test("a Foreman/Worker with the activity's siteId in their own siteIds " +
    "can read it", async () => {
    await seed(async (db) => {
      await db
        .doc(`users/active-a/memberships/${ORG_A}`)
        .set(membership("active-a", ORG_A, {
          role: "worker",
          siteIds: ["site-1"],
        }));
    });
    const db = actor("active-a", "active-a@example.com");

    await assertSucceeds(
      db.doc(`organizations/${ORG_A}/activities/activity-1`).get()
    );
  });

  test("a Foreman/Worker WITHOUT the activity's siteId in their own " +
    "siteIds cannot read it", async () => {
    const db = actor("active-a", "active-a@example.com");

    // active-a's default membership (role: worker, siteIds: []) does not
    // include site-1, activity-1's own site.
    await assertFails(
      db.doc(`organizations/${ORG_A}/activities/activity-1`).get()
    );
  });

  test("an org member cannot read another organization's activities or " +
    "assignments", async () => {
    const db = actor("active-a", "active-a@example.com");

    await assertFails(db.collection(`organizations/${ORG_B}/activities`).get());
    await assertFails(
      db
        .collection(`organizations/${ORG_B}/activities/activity-x/assignments`)
        .get()
    );
  });

  test("a pending/suspended/rejected user reads no activity or assignment",
    async () => {
      await assertFails(
        actor("pending-a", "pending-a@example.com")
          .doc(`organizations/${ORG_A}/activities/activity-1`)
          .get()
      );
      await assertFails(
        actor("suspended-a", "s@example.com")
          .doc(assignmentPath(ORG_A, "activity-1", "active-a"))
          .get()
      );
    });

  test("an Admin can read every organization's activities " +
    "and assignments", async () => {
    const db = actor("sysadmin-a", "sysadmin-a@example.com");

    await assertSucceeds(
      db.doc(`organizations/${ORG_A}/activities/activity-1`).get()
    );
    await assertSucceeds(
      db.doc(assignmentPath(ORG_A, "activity-1", "active-a")).get()
    );
  });

  test("no client, Admin included, can create an activity " +
    "by direct write", async () => {
    await assertFails(
      actor("sysadmin-a", "sysadmin-a@example.com")
        .doc(`organizations/${ORG_A}/activities/activity-2`)
        .set({
          organizationId: ORG_A,
          projectId: "project-1",
          siteId: "site-1",
          name: "Roofing",
          code: "ROOF-01",
          status: "active",
        })
    );
  });

  test("no client can update an existing activity by direct write",
    async () => {
      await assertFails(
        actor("sysadmin-a", "sysadmin-a@example.com")
          .doc(`organizations/${ORG_A}/activities/activity-1`)
          .update({status: "inactive"})
      );
    });

  test("no client, Admin included, can assign a worker to " +
    "an activity by direct write", async () => {
    await assertFails(
      actor("sysadmin-a", "sysadmin-a@example.com")
        .doc(assignmentPath(ORG_A, "activity-1", "active-b"))
        .set({
          uid: "active-b",
          organizationId: ORG_A,
          siteId: "site-1",
          activityId: "activity-1",
          assignedAt: new Date(),
          assignedBy: "sysadmin-a",
        })
    );
  });

  test("a worker cannot self-assign to an activity by direct write",
    async () => {
      const db = actor("active-a", "active-a@example.com");

      await assertFails(
        db
          .doc(assignmentPath(ORG_A, "activity-1", "active-a"))
          .set({
            uid: "active-a",
            organizationId: ORG_A,
            siteId: "site-1",
            activityId: "activity-1",
            assignedAt: new Date(),
            assignedBy: "active-a",
          })
      );
    });

  test("no client can remove a worker's activity assignment by direct write",
    async () => {
      await assertFails(
        actor("sysadmin-a", "sysadmin-a@example.com")
          .doc(assignmentPath(ORG_A, "activity-1", "active-a"))
          .delete()
      );
    });

  test("a user cannot grant themselves siteIds/activityIds by profile " +
    "update either", async () => {
    // `siteIds`/`activityIds` are reserved on the user profile
    // (`registrationOmitsPrivilegedFields`/`touchesProtectedFields`) even
    // though the actual grant now lives in the `siteIds` array field — this
    // pins down that the reservation still holds now that the feature is
    // implemented, not just at registration.
    const db = actor("active-a", "active-a@example.com");

    await assertFails(
      db.doc(userPath("active-a")).update({
        siteIds: ["site-1"],
        updatedAt: serverTimestamp(),
      })
    );
    await assertFails(
      db.doc(userPath("active-a")).update({
        activityIds: ["activity-1"],
        updatedAt: serverTimestamp(),
      })
    );
  });
});

describe("the Safety Requirement / Safety Learning foundation", () => {
  // DESIGN NOTE. Content management (creating/editing safety_learning and
  // safety_requirements documents) is Admin-SDK-only via
  // `safety_learning_callable.ts`'s `requireOrganizationScopedAdmin`, exactly
  // like activities. Reads follow the same org-membership-or-Admin shape as
  // `activities/{activityId}`.
  //
  // worker_learning_records is different: it is personal data, so read is
  // scoped to the record's own workerUid, or a siteManager / admin of that
  // organization — NOT every org member. Every
  // worker-progress transition (assigned -> inProgress -> completed) is
  // Admin-SDK-only via `worker_learning_callable.ts`'s `startLearning`/
  // `completeLearning`/`getMyRequiredLearning`, which derive the acting
  // worker from `request.auth.uid` alone and never accept a `workerUid`
  // argument — these rules tests pin down that a worker cannot forge that
  // same guarantee by direct write.

  function learningPath(organizationId, learningId) {
    return `organizations/${organizationId}/safety_learning/${learningId}`;
  }

  function requirementPath(organizationId, requirementId) {
    return `organizations/${organizationId}/safety_requirements/` +
      requirementId;
  }

  function recordPath(organizationId, recordId) {
    return `organizations/${organizationId}/worker_learning_records/` +
      recordId;
  }

  beforeEach(async () => {
    await seed(async (db) => {
      await db.doc(learningPath(ORG_A, "learning-1")).set({
        organizationId: ORG_A,
        title: "Fall Protection Basics",
        type: "video",
        contentReference: "https://example.com/video.mp4",
        status: "active",
        createdAt: new Date(),
        updatedAt: new Date(),
        createdBy: "sysadmin-a",
        updatedBy: "sysadmin-a",
      });
      await db.doc(requirementPath(ORG_A, "requirement-1")).set({
        organizationId: ORG_A,
        name: "Working at Height",
        category: "Fall Protection",
        risk: "high",
        requiredLearningIds: ["learning-1"],
        status: "active",
        createdAt: new Date(),
        updatedAt: new Date(),
        createdBy: "sysadmin-a",
        updatedBy: "sysadmin-a",
      });
      await db.doc(recordPath(ORG_A, "active-a_learning-1")).set({
        workerUid: "active-a",
        organizationId: ORG_A,
        learningId: "learning-1",
        status: "assigned",
        assignedAt: new Date(),
      });
    });
  });

  test("an org member can read their own organization's safety learning " +
    "and safety requirements", async () => {
    const db = actor("active-a", "active-a@example.com");

    await assertSucceeds(db.doc(learningPath(ORG_A, "learning-1")).get());
    await assertSucceeds(
      db.doc(requirementPath(ORG_A, "requirement-1")).get()
    );
  });

  test("an org member cannot read another organization's safety learning " +
    "or safety requirements", async () => {
    const db = actor("active-a", "active-a@example.com");

    await assertFails(
      db.collection(`organizations/${ORG_B}/safety_learning`).get()
    );
    await assertFails(
      db.collection(`organizations/${ORG_B}/safety_requirements`).get()
    );
  });

  test("a pending/suspended/rejected user reads no safety learning or " +
    "safety requirement", async () => {
    await assertFails(
      actor("pending-a", "pending-a@example.com")
        .doc(learningPath(ORG_A, "learning-1"))
        .get()
    );
    await assertFails(
      actor("suspended-a", "s@example.com")
        .doc(requirementPath(ORG_A, "requirement-1"))
        .get()
    );
  });

  test("an Admin can read every organization's safety " +
    "learning and safety requirements", async () => {
    const db = actor("sysadmin-a", "sysadmin-a@example.com");

    await assertSucceeds(db.doc(learningPath(ORG_A, "learning-1")).get());
    await assertSucceeds(
      db.doc(requirementPath(ORG_A, "requirement-1")).get()
    );
  });

  test("no client, Admin included, can create or update " +
    "a safety learning item by direct write", async () => {
    await assertFails(
      actor("sysadmin-a", "sysadmin-a@example.com")
        .doc(learningPath(ORG_A, "learning-2"))
        .set({
          organizationId: ORG_A,
          title: "New Item",
          type: "document",
          contentReference: "ref",
          status: "active",
        })
    );
    await assertFails(
      actor("sysadmin-a", "sysadmin-a@example.com")
        .doc(learningPath(ORG_A, "learning-1"))
        .update({status: "inactive"})
    );
  });

  test("no client, Admin included, can create or update " +
    "a safety requirement by direct write", async () => {
    await assertFails(
      actor("sysadmin-a", "sysadmin-a@example.com")
        .doc(requirementPath(ORG_A, "requirement-2"))
        .set({
          organizationId: ORG_A,
          name: "New Requirement",
          category: "General",
          risk: "low",
          requiredLearningIds: [],
          status: "active",
        })
    );
    await assertFails(
      actor("sysadmin-a", "sysadmin-a@example.com")
        .doc(requirementPath(ORG_A, "requirement-1"))
        .update({requiredLearningIds: ["learning-1", "learning-2"]})
    );
  });

  test("a worker can read their own learning record", async () => {
    const db = actor("active-a", "active-a@example.com");

    await assertSucceeds(
      db.doc(recordPath(ORG_A, "active-a_learning-1")).get()
    );
  });

  test("a worker cannot read another worker's learning record", async () => {
    const db = actor("active-b", "active-b@example.com");

    await assertFails(
      db.doc(recordPath(ORG_A, "active-a_learning-1")).get()
    );
  });

  // Previously a real authorization gap: the trailing
  // `match /{operationalCollection}/{documentId=**}` catch-all matched this
  // path too and granted read to ANY active org member regardless of role,
  // widening the "personal data" boundary this collection's firestore.rules
  // comment describes. Fixed by excluding `worker_learning_records` (and
  // `notifications`) from that catch-all by name — see firestore.rules.
  test("an ordinary worker cannot read another worker's learning " +
    "record within the same organization", async () => {
    // A second plain worker in ORG_A (not siteManager/admin), distinct from
    // the shared active-a/active-b fixtures — active-b is deliberately in
    // ORG_B and so cannot exercise this same-organization case.
    await seed(async (db) => {
      await db.doc(userPath("worker-same-org")).set(
        profile("worker-same-org", "active")
      );
      await db
        .doc(`users/worker-same-org/memberships/${ORG_A}`)
        .set(membership("worker-same-org", ORG_A, {role: "worker"}));
    });
    const db = actor("worker-same-org", "worker-same-org@example.com");

    await assertFails(
      db.doc(recordPath(ORG_A, "active-a_learning-1")).get()
    );
  });

  test("a site manager can read another worker's learning record within " +
    "their own organization", async () => {
    const db = actor("approver-a", "approver-a@example.com");

    await assertSucceeds(
      db.doc(recordPath(ORG_A, "active-a_learning-1")).get()
    );
  });

  // A foreman is deliberately NOT granted the siteManager carve-out above —
  // this pins down the Safety Learning Compliance screen's own real
  // authorization boundary (`SafetyComplianceRepository`, gated on
  // `canManageOrgContent` client-side): even if a Foreman reached that
  // screen's code path some other way, the server-side rule underneath it
  // still refuses them, exactly like every other org member who isn't the
  // record's own worker.
  test("a foreman cannot read another worker's learning record within " +
    "their own organization — the compliance screen's real boundary",
  async () => {
    await seed(async (db) => {
      await db.doc(userPath("foreman-same-org")).set(
        profile("foreman-same-org", "active")
      );
      await db
        .doc(`users/foreman-same-org/memberships/${ORG_A}`)
        .set(membership("foreman-same-org", ORG_A, {role: "foreman"}));
    });
    const db = actor("foreman-same-org", "foreman-same-org@example.com");

    await assertFails(
      db.doc(recordPath(ORG_A, "active-a_learning-1")).get()
    );
  });

  test("a site manager cannot read a worker's learning record in another " +
    "organization", async () => {
    const db = actor("approver-a", "approver-a@example.com");

    await assertFails(
      db.doc(recordPath(ORG_B, "active-b_learning-1")).get()
    );
  });

  test("an Admin can read any worker's learning record",
    async () => {
      const db = actor("sysadmin-a", "sysadmin-a@example.com");

      await assertSucceeds(
        db.doc(recordPath(ORG_A, "active-a_learning-1")).get()
      );
    });

  test("a worker cannot forge a completed status via direct write",
    async () => {
      const db = actor("active-a", "active-a@example.com");

      await assertFails(
        db.doc(recordPath(ORG_A, "active-a_learning-1")).update({
          status: "completed",
          completedAt: new Date(),
        })
      );
    });

  test("a worker cannot create a fake completion record for a learning " +
    "item that was never assigned", async () => {
    const db = actor("active-a", "active-a@example.com");

    await assertFails(
      db.doc(recordPath(ORG_A, "active-a_learning-9")).set({
        workerUid: "active-a",
        organizationId: ORG_A,
        learningId: "learning-9",
        status: "completed",
        assignedAt: new Date(),
        completedAt: new Date(),
      })
    );
  });

  test("no client, Admin included, can write another " +
    "worker's learning record", async () => {
    await assertFails(
      actor("sysadmin-a", "sysadmin-a@example.com")
        .doc(recordPath(ORG_A, "active-a_learning-1"))
        .update({status: "completed"})
    );
  });

  test("no client can delete a learning record", async () => {
    await assertFails(
      actor("active-a", "active-a@example.com")
        .doc(recordPath(ORG_A, "active-a_learning-1"))
        .delete()
    );
  });

  // KNOWLEDGE CHECK QUESTIONS. Unlike the parent safety_learning document
  // above (readable by any org member), this subcollection carries
  // `correctOptionId` and is denied to EVERY client outright — the only
  // path a worker ever sees question content through is
  // `getKnowledgeCheckQuestions` (`worker_learning_callable.ts`), which
  // strips `correctOptionId` server-side; the only path an admin sees the
  // correct answer through is `listKnowledgeCheckQuestions`
  // (`safety_learning_callable.ts`), also Admin-SDK-only. These tests pin
  // down that a direct client read — by a worker, a siteManager, or even an
  // Admin's own client SDK — never succeeds, regardless of who is asking.

  function questionPath(organizationId, learningId, questionId) {
    return `organizations/${organizationId}/safety_learning/${learningId}` +
      `/knowledge_check_questions/${questionId}`;
  }

  test("no client can read a knowledge-check question directly, even an " +
    "org member who can read the parent safety_learning document",
  async () => {
    await seed(async (db) => {
      await db.doc(questionPath(ORG_A, "learning-1", "question-1")).set({
        prompt: "What must you wear at height?",
        options: [
          {id: "a", text: "A harness"},
          {id: "b", text: "Sunglasses"},
        ],
        correctOptionId: "a",
        order: 0,
      });
    });

    await assertFails(
      actor("active-a", "active-a@example.com")
        .doc(questionPath(ORG_A, "learning-1", "question-1"))
        .get()
    );
  });

  test("a siteManager (the worker_learning_records compliance carve-out " +
    "role) still cannot read a question directly", async () => {
    await seed(async (db) => {
      await db.doc(questionPath(ORG_A, "learning-1", "question-1")).set({
        prompt: "Q",
        options: [{id: "a", text: "A"}, {id: "b", text: "B"}],
        correctOptionId: "a",
        order: 0,
      });
    });

    await assertFails(
      actor("approver-a", "approver-a@example.com")
        .doc(questionPath(ORG_A, "learning-1", "question-1"))
        .get()
    );
  });

  test("even an Admin's own client SDK cannot read a question directly — " +
    "the admin-facing view goes through listKnowledgeCheckQuestions, " +
    "never a client Firestore read", async () => {
    await seed(async (db) => {
      await db.doc(questionPath(ORG_A, "learning-1", "question-1")).set({
        prompt: "Q",
        options: [{id: "a", text: "A"}, {id: "b", text: "B"}],
        correctOptionId: "a",
        order: 0,
      });
    });

    await assertFails(
      actor("sysadmin-a", "sysadmin-a@example.com")
        .doc(questionPath(ORG_A, "learning-1", "question-1"))
        .get()
    );
  });

  test("no client can write a knowledge-check question directly", async () => {
    await assertFails(
      actor("sysadmin-a", "sysadmin-a@example.com")
        .doc(questionPath(ORG_A, "learning-1", "question-1"))
        .set({
          prompt: "Forged",
          options: [{id: "a", text: "A"}, {id: "b", text: "B"}],
          correctOptionId: "a",
          order: 0,
        })
    );
  });
});

describe("the Safety Meeting Point foundation", () => {
  // DESIGN NOTE. Content management (creating/editing/activating/
  // deactivating safety_meeting_points documents) is Admin-SDK-only from
  // the RULES' point of view (allow write: if false, exactly like
  // safety_learning above) -- but unlike safety_learning, the
  // callable-level authorization behind it
  // (`safety_meeting_point_callable.ts`'s `requireOrganizationScopedManager`)
  // permits BOTH Admin and a Site Manager of the target organization, not
  // Admin alone -- see safety_meeting_point_callable.test.js for that
  // business-logic coverage, which these rules tests structurally cannot
  // reach. Reads follow the same org-membership-or-Admin shape as
  // `safety_learning`.

  function meetingPointPath(organizationId, meetingPointId) {
    return `organizations/${organizationId}/safety_meeting_points/` +
      meetingPointId;
  }

  beforeEach(async () => {
    await seed(async (db) => {
      await db.doc(meetingPointPath(ORG_A, "point-1")).set({
        organizationId: ORG_A,
        title: "Fall Protection Muster Point",
        category: "Fall Protection",
        applicableActivities: [],
        applicableRisks: [],
        status: "active",
        createdAt: new Date(),
        updatedAt: new Date(),
        createdBy: "sysadmin-a",
        updatedBy: "sysadmin-a",
      });
    });
  });

  test("an org member can read their own organization's safety meeting " +
    "points", async () => {
    const db = actor("active-a", "active-a@example.com");

    await assertSucceeds(db.doc(meetingPointPath(ORG_A, "point-1")).get());
  });

  test("an org member cannot read another organization's safety meeting " +
    "points", async () => {
    const db = actor("active-a", "active-a@example.com");

    await assertFails(
      db.collection(`organizations/${ORG_B}/safety_meeting_points`).get()
    );
  });

  test("a pending/suspended/rejected user reads no safety meeting point",
    async () => {
      await assertFails(
        actor("pending-a", "pending-a@example.com")
          .doc(meetingPointPath(ORG_A, "point-1"))
          .get()
      );
      await assertFails(
        actor("suspended-a", "s@example.com")
          .doc(meetingPointPath(ORG_A, "point-1"))
          .get()
      );
    });

  test("an Admin can read every organization's safety " +
    "meeting points", async () => {
    const db = actor("sysadmin-a", "sysadmin-a@example.com");

    await assertSucceeds(db.doc(meetingPointPath(ORG_A, "point-1")).get());
  });

  test("no client, Admin included, can create or update a " +
    "safety meeting point by direct write", async () => {
    await assertFails(
      actor("sysadmin-a", "sysadmin-a@example.com")
        .doc(meetingPointPath(ORG_A, "point-2"))
        .set({
          organizationId: ORG_A,
          title: "New Point",
          category: "General",
          applicableActivities: [],
          applicableRisks: [],
          status: "active",
        })
    );
    await assertFails(
      actor("sysadmin-a", "sysadmin-a@example.com")
        .doc(meetingPointPath(ORG_A, "point-1"))
        .update({status: "inactive"})
    );
  });

  test("a site manager cannot write a safety meeting point by direct write " +
    "either", async () => {
    await assertFails(
      actor("approver-a", "approver-a@example.com")
        .doc(meetingPointPath(ORG_A, "point-1"))
        .update({status: "inactive"})
    );
  });

  test("no client can delete a safety meeting point", async () => {
    await assertFails(
      actor("sysadmin-a", "sysadmin-a@example.com")
        .doc(meetingPointPath(ORG_A, "point-1"))
        .delete()
    );
  });
});

describe("the Daily Safety Meeting foundation", () => {
  // DESIGN NOTE. Every write (create, edit, complete) is Admin-SDK-only via
  // `daily_safety_meeting_callable.ts`'s `requireActiveForeman`, which reads
  // the caller's own stored profile for `platformRole == "foreman"` and
  // confirms `siteId` is in their own `siteIds` — narrower than
  // `requireOrganizationScopedAdmin` used elsewhere, since running a toolbox
  // talk is a foreman's operational duty, not an administrative one.
  //
  // PHASE 3 (authorization matrix): read is role-scoped, NOT a flat
  // any-org-member grant — Site Manager/Admin review every meeting
  // org-wide; a Foreman reviews only meetings THEY conducted
  // (`foremanId == request.auth.uid`).
  //
  // DASHBOARD (Phase 2): a Worker may additionally read a meeting whose
  // OWN `siteId` is in their own `siteIds` — see "a worker CAN read a
  // meeting at their own site" below. Narrower than the Foreman/Site
  // Manager grants (no write, and their own attendance record is still a
  // separate, narrower carve-out — see the `attendance` describe block
  // below); this only lets a Worker discover today's meeting at their own
  // site, which was previously impossible (no read access to the parent
  // document meant no way to learn the `meetingId` their own attendance
  // record lives under).

  function meetingPath(organizationId, meetingId) {
    return `organizations/${organizationId}/daily_safety_meetings/` +
      meetingId;
  }

  beforeEach(async () => {
    await seed(async (db) => {
      // A foreman assigned to ORG_A's site-1, the shape
      // `assignWorkerToSite` would produce.
      await db.doc(userPath("foreman-a")).set(profile("foreman-a", "active"));
      await db
        .doc(`users/foreman-a/memberships/${ORG_A}`)
        .set(membership("foreman-a", ORG_A, {
          role: "foreman",
          siteIds: ["site-1"],
        }));
      // A second foreman, whose OWN meetings a foreman-a read must not
      // reach — see "a foreman cannot read another foreman's meeting"
      // below.
      await db.doc(userPath("foreman-b")).set(profile("foreman-b", "active"));
      await db
        .doc(`users/foreman-b/memberships/${ORG_A}`)
        .set(membership("foreman-b", ORG_A, {
          role: "foreman",
          siteIds: ["site-2"],
        }));
      // active-a is a Site Manager here (not the default worker role) so
      // the "org member" tests below exercise the Site Manager's org-wide
      // read grant specifically.
      await db
        .doc(`users/active-a/memberships/${ORG_A}`)
        .set(membership("active-a", ORG_A, {role: "siteManager"}));
      await db.doc(meetingPath(ORG_A, "meeting-1")).set({
        organizationId: ORG_A,
        projectId: "project-1",
        siteId: "site-1",
        date: "2026-08-20",
        startTime: new Date(),
        endTime: null,
        foremanId: "foreman-a",
        activityIds: ["activity-1"],
        meetingPointIds: ["point-1"],
        status: "inProgress",
        concerns: [],
        correctiveActionIds: [],
        createdAt: new Date(),
        completedAt: null,
      });
    });
  });

  test("a Site Manager can read their own organization's daily safety " +
    "meetings", async () => {
    const db = actor("active-a", "active-a@example.com");

    await assertSucceeds(db.doc(meetingPath(ORG_A, "meeting-1")).get());
  });

  test("a Site Manager cannot read another organization's daily safety " +
    "meetings", async () => {
    const db = actor("active-a", "active-a@example.com");

    await assertFails(
      db.collection(`organizations/${ORG_B}/daily_safety_meetings`).get()
    );
  });

  test("a foreman can read a meeting they conducted", async () => {
    const db = actor("foreman-a", "foreman-a@example.com");

    await assertSucceeds(db.doc(meetingPath(ORG_A, "meeting-1")).get());
  });

  test("a foreman cannot read another foreman's meeting", async () => {
    const db = actor("foreman-b", "foreman-b@example.com");

    await assertFails(db.doc(meetingPath(ORG_A, "meeting-1")).get());
  });

  test("a worker CAN read a meeting at their own site", async () => {
    await seed(async (db) => {
      await db.doc(userPath("worker-a")).set(profile("worker-a", "active"));
      await db
        .doc(`users/worker-a/memberships/${ORG_A}`)
        .set(membership("worker-a", ORG_A, {
          role: "worker",
          siteIds: ["site-1"],
        }));
    });
    const db = actor("worker-a", "worker-a@example.com");

    await assertSucceeds(db.doc(meetingPath(ORG_A, "meeting-1")).get());
  });

  test("a worker cannot read a meeting at a site they are not assigned to",
    async () => {
      await seed(async (db) => {
        await db.doc(userPath("worker-b")).set(profile("worker-b", "active"));
        await db
          .doc(`users/worker-b/memberships/${ORG_A}`)
          .set(membership("worker-b", ORG_A, {
            role: "worker",
            siteIds: ["site-2"],
          }));
      });
      const db = actor("worker-b", "worker-b@example.com");

      await assertFails(db.doc(meetingPath(ORG_A, "meeting-1")).get());
    });

  test("a pending/suspended/rejected user reads no daily safety meeting",
    async () => {
      await assertFails(
        actor("pending-a", "pending-a@example.com")
          .doc(meetingPath(ORG_A, "meeting-1"))
          .get()
      );
      await assertFails(
        actor("suspended-a", "s@example.com")
          .doc(meetingPath(ORG_A, "meeting-1"))
          .get()
      );
    });

  test("an Admin can read every organization's daily " +
    "safety meetings", async () => {
    const db = actor("sysadmin-a", "sysadmin-a@example.com");

    await assertSucceeds(db.doc(meetingPath(ORG_A, "meeting-1")).get());
  });

  test("no client, including the meeting's own foreman, can create a " +
    "daily safety meeting by direct write", async () => {
    await assertFails(
      actor("foreman-a", "foreman-a@example.com")
        .doc(meetingPath(ORG_A, "meeting-2"))
        .set({
          organizationId: ORG_A,
          projectId: "project-1",
          siteId: "site-1",
          date: "2026-08-20",
          foremanId: "foreman-a",
          activityIds: [],
          meetingPointIds: [],
          status: "inProgress",
          concerns: [],
          correctiveActionIds: [],
          createdAt: new Date(),
        })
    );
  });

  test("no client, including the meeting's own foreman, can edit or " +
    "complete a daily safety meeting by direct write", async () => {
    await assertFails(
      actor("foreman-a", "foreman-a@example.com")
        .doc(meetingPath(ORG_A, "meeting-1"))
        .update({concerns: ["Forged concern"]})
    );
    await assertFails(
      actor("foreman-a", "foreman-a@example.com")
        .doc(meetingPath(ORG_A, "meeting-1"))
        .update({status: "completed"})
    );
  });

  test("an Admin cannot write a daily safety meeting by " +
    "direct write either", async () => {
    await assertFails(
      actor("sysadmin-a", "sysadmin-a@example.com")
        .doc(meetingPath(ORG_A, "meeting-1"))
        .update({status: "completed"})
    );
  });

  test("no client can delete a daily safety meeting", async () => {
    await assertFails(
      actor("foreman-a", "foreman-a@example.com")
        .doc(meetingPath(ORG_A, "meeting-1"))
        .delete()
    );
  });

  describe("attendance", () => {
    // DESIGN NOTE. Every write is Admin-SDK-only via
    // `recordMeetingAttendance` (`daily_safety_meeting_callable.ts`), which
    // additionally verifies server-side that the caller is the meeting's own
    // foreman, that the meeting is still `inProgress`, that the target
    // worker belongs to the meeting's own site, and that the target worker
    // is never the caller's own uid.
    //
    // PHASE 3: read follows the parent meeting's role-scoped shape
    // (Site Manager/Admin: all; Foreman: only their own meeting's
    // attendance) PLUS a worker may read their OWN attendance record —
    // the one carve-out into this collection a Worker has at all.

    function attendancePath(organizationId, meetingId, workerId) {
      return `${meetingPath(organizationId, meetingId)}/attendance/` +
        workerId;
    }

    beforeEach(async () => {
      await seed(async (db) => {
        await db.doc(userPath("worker-a")).set(profile("worker-a", "active"));
        await db
          .doc(`users/worker-a/memberships/${ORG_A}`)
          .set(membership("worker-a", ORG_A, {
            role: "worker",
            siteIds: ["site-1"],
          }));
        await db
          .doc(attendancePath(ORG_A, "meeting-1", "worker-a"))
          .set({
            meetingId: "meeting-1",
            organizationId: ORG_A,
            siteId: "site-1",
            workerId: "worker-a",
            status: "present",
            recordedAt: new Date(),
            recordedBy: "foreman-a",
          });
      });
    });

    test("an org member can read attendance for their own organization's " +
      "meeting", async () => {
      const db = actor("active-a", "active-a@example.com");

      await assertSucceeds(
        db.doc(attendancePath(ORG_A, "meeting-1", "worker-a")).get()
      );
    });

    test("an org member cannot read another organization's attendance",
      async () => {
        const db = actor("active-a", "active-a@example.com");

        await assertFails(
          db
            .collection(
              `organizations/${ORG_B}/daily_safety_meetings/meeting-1/` +
                "attendance"
            )
            .get()
        );
      });

    test("a pending/suspended/rejected user reads no attendance", async () => {
      await assertFails(
        actor("pending-a", "pending-a@example.com")
          .doc(attendancePath(ORG_A, "meeting-1", "worker-a"))
          .get()
      );
      await assertFails(
        actor("suspended-a", "s@example.com")
          .doc(attendancePath(ORG_A, "meeting-1", "worker-a"))
          .get()
      );
    });

    test("an Admin can read attendance in any organization",
      async () => {
        const db = actor("sysadmin-a", "sysadmin-a@example.com");

        await assertSucceeds(
          db.doc(attendancePath(ORG_A, "meeting-1", "worker-a")).get()
        );
      });

    test("the meeting's own foreman can read attendance for their meeting",
      async () => {
        const db = actor("foreman-a", "foreman-a@example.com");

        await assertSucceeds(
          db.doc(attendancePath(ORG_A, "meeting-1", "worker-a")).get()
        );
      });

    test("a DIFFERENT foreman cannot read attendance for a meeting they " +
      "did not conduct", async () => {
      const db = actor("foreman-b", "foreman-b@example.com");

      await assertFails(
        db.doc(attendancePath(ORG_A, "meeting-1", "worker-a")).get()
      );
    });

    test("a worker can read their OWN attendance record", async () => {
      const db = actor("worker-a", "worker-a@example.com");

      await assertSucceeds(
        db.doc(attendancePath(ORG_A, "meeting-1", "worker-a")).get()
      );
    });

    test("a worker cannot read another worker's attendance record",
      async () => {
        await seed(async (db) => {
          await db
            .doc(userPath("worker-b"))
            .set(profile("worker-b", "active"));
          await db
            .doc(`users/worker-b/memberships/${ORG_A}`)
            .set(membership("worker-b", ORG_A, {
              role: "worker",
              siteIds: ["site-1"],
            }));
        });
        const db = actor("worker-b", "worker-b@example.com");

        await assertFails(
          db.doc(attendancePath(ORG_A, "meeting-1", "worker-a")).get()
        );
      });

    test("no client, including the meeting's own foreman, can create an " +
      "attendance record by direct write", async () => {
      await assertFails(
        actor("foreman-a", "foreman-a@example.com")
          .doc(attendancePath(ORG_A, "meeting-1", "active-a"))
          .set({
            meetingId: "meeting-1",
            organizationId: ORG_A,
            siteId: "site-1",
            workerId: "active-a",
            status: "present",
            recordedAt: new Date(),
            recordedBy: "foreman-a",
          })
      );
    });

    test("a worker cannot mark themselves present by direct write",
      async () => {
        await assertFails(
          actor("worker-a", "worker-a@example.com")
            .doc(attendancePath(ORG_A, "meeting-1", "worker-a"))
            .set({
              meetingId: "meeting-1",
              organizationId: ORG_A,
              siteId: "site-1",
              workerId: "worker-a",
              status: "present",
              recordedAt: new Date(),
              recordedBy: "worker-a",
            })
        );
      });

    test("no client can update an existing attendance record by direct " +
      "write", async () => {
      await assertFails(
        actor("foreman-a", "foreman-a@example.com")
          .doc(attendancePath(ORG_A, "meeting-1", "worker-a"))
          .update({status: "absent"})
      );
    });

    test("no client can delete an attendance record", async () => {
      await assertFails(
        actor("foreman-a", "foreman-a@example.com")
          .doc(attendancePath(ORG_A, "meeting-1", "worker-a"))
          .delete()
      );
    });
  });

  describe("concerns", () => {
    // DESIGN NOTE. Every write is Admin-SDK-only via `addMeetingConcern`/
    // `updateMeetingConcern`/`removeMeetingConcern`
    // (`daily_safety_meeting_callable.ts`), which additionally verify
    // server-side that the caller is the meeting's own foreman and that the
    // meeting is still `inProgress` — once `completed`, all three refuse, so
    // a concern can never be silently altered after the meeting closes.
    //
    // PHASE 3: read follows the parent meeting's role-scoped shape
    // (Site Manager/Admin: all; Foreman: only their own meeting's
    // concerns) — unlike `attendance`, a Worker has NO carve-out here at
    // all, since a concern is not "this worker's own data" the way their
    // attendance record is.

    function concernPath(organizationId, meetingId, concernId) {
      return `${meetingPath(organizationId, meetingId)}/concerns/` +
        concernId;
    }

    beforeEach(async () => {
      await seed(async (db) => {
        await db.doc(concernPath(ORG_A, "meeting-1", "concern-1")).set({
          meetingId: "meeting-1",
          organizationId: ORG_A,
          siteId: "site-1",
          description: "Loose scaffolding on level 3",
          category: "safety",
          reportedBy: "foreman-a",
          status: "open",
          createdAt: new Date(),
        });
      });
    });

    test("an org member can read concerns for their own organization's " +
      "meeting", async () => {
      const db = actor("active-a", "active-a@example.com");

      await assertSucceeds(
        db.doc(concernPath(ORG_A, "meeting-1", "concern-1")).get()
      );
    });

    test("an org member cannot read another organization's concerns",
      async () => {
        const db = actor("active-a", "active-a@example.com");

        await assertFails(
          db
            .collection(
              `organizations/${ORG_B}/daily_safety_meetings/meeting-1/` +
                "concerns"
            )
            .get()
        );
      });

    test("a pending/suspended/rejected user reads no concern", async () => {
      await assertFails(
        actor("pending-a", "pending-a@example.com")
          .doc(concernPath(ORG_A, "meeting-1", "concern-1"))
          .get()
      );
      await assertFails(
        actor("suspended-a", "s@example.com")
          .doc(concernPath(ORG_A, "meeting-1", "concern-1"))
          .get()
      );
    });

    test("an Admin can read concerns in any organization",
      async () => {
        const db = actor("sysadmin-a", "sysadmin-a@example.com");

        await assertSucceeds(
          db.doc(concernPath(ORG_A, "meeting-1", "concern-1")).get()
        );
      });

    test("the meeting's own foreman can read its concerns", async () => {
      const db = actor("foreman-a", "foreman-a@example.com");

      await assertSucceeds(
        db.doc(concernPath(ORG_A, "meeting-1", "concern-1")).get()
      );
    });

    test("a DIFFERENT foreman cannot read concerns for a meeting they did " +
      "not conduct", async () => {
      const db = actor("foreman-b", "foreman-b@example.com");

      await assertFails(
        db.doc(concernPath(ORG_A, "meeting-1", "concern-1")).get()
      );
    });

    test("a worker has no read access to concerns at all — unlike " +
      "attendance, there is no own-record carve-out here", async () => {
      await seed(async (db) => {
        await db.doc(userPath("worker-a")).set(profile("worker-a", "active"));
        await db
          .doc(`users/worker-a/memberships/${ORG_A}`)
          .set(membership("worker-a", ORG_A, {
            role: "worker",
            siteIds: ["site-1"],
          }));
      });
      const db = actor("worker-a", "worker-a@example.com");

      await assertFails(
        db.doc(concernPath(ORG_A, "meeting-1", "concern-1")).get()
      );
    });

    test("no client, including the meeting's own foreman, can create a " +
      "concern by direct write", async () => {
      await assertFails(
        actor("foreman-a", "foreman-a@example.com")
          .doc(concernPath(ORG_A, "meeting-1", "concern-2"))
          .set({
            meetingId: "meeting-1",
            organizationId: ORG_A,
            siteId: "site-1",
            description: "Forged concern",
            category: "safety",
            reportedBy: "foreman-a",
            status: "open",
            createdAt: new Date(),
          })
      );
    });

    test("no client can update an existing concern by direct write",
      async () => {
        await assertFails(
          actor("foreman-a", "foreman-a@example.com")
            .doc(concernPath(ORG_A, "meeting-1", "concern-1"))
            .update({description: "Tampered description"})
        );
      });

    test("no client can delete a concern by direct write", async () => {
      await assertFails(
        actor("foreman-a", "foreman-a@example.com")
          .doc(concernPath(ORG_A, "meeting-1", "concern-1"))
          .delete()
      );
    });

    test("an Admin cannot write a concern by direct write " +
      "either", async () => {
      await assertFails(
        actor("sysadmin-a", "sysadmin-a@example.com")
          .doc(concernPath(ORG_A, "meeting-1", "concern-1"))
          .update({status: "resolved"})
      );
    });
  });

  describe("point_notes", () => {
    // DESIGN NOTE. Every write is Admin-SDK-only via `setMeetingPointNote`/
    // `removeMeetingPointNote` (`daily_safety_meeting_callable.ts`), which
    // additionally verify server-side that the caller is the meeting's own
    // foreman and that the meeting is still `inProgress` — once
    // `completed`, both refuse.
    //
    // Read follows `concerns`' EXACT shape, not `attendance`'s: Site
    // Manager/Admin see every meeting's notes; a Foreman sees only their
    // own meeting's notes; a Worker has NO carve-out — a discussion note is
    // not "this worker's own data" the way their attendance record is,
    // same reasoning already applied to concerns.

    function pointNotePath(organizationId, meetingId, meetingPointId) {
      return `${meetingPath(organizationId, meetingId)}/point_notes/` +
        meetingPointId;
    }

    beforeEach(async () => {
      await seed(async (db) => {
        await db.doc(pointNotePath(ORG_A, "meeting-1", "point-1")).set({
          meetingId: "meeting-1",
          organizationId: ORG_A,
          siteId: "site-1",
          meetingPointId: "point-1",
          note: "Reminded workers to maintain three points of contact.",
          recordedBy: "foreman-a",
          createdAt: new Date(),
          updatedAt: new Date(),
        });
      });
    });

    test("an org member can read point notes for their own organization's " +
      "meeting", async () => {
      const db = actor("active-a", "active-a@example.com");

      await assertSucceeds(
        db.doc(pointNotePath(ORG_A, "meeting-1", "point-1")).get()
      );
    });

    test("an org member cannot read another organization's point notes",
      async () => {
        const db = actor("active-a", "active-a@example.com");

        await assertFails(
          db
            .collection(
              `organizations/${ORG_B}/daily_safety_meetings/meeting-1/` +
                "point_notes"
            )
            .get()
        );
      });

    test("an Admin can read point notes in any organization", async () => {
      const db = actor("sysadmin-a", "sysadmin-a@example.com");

      await assertSucceeds(
        db.doc(pointNotePath(ORG_A, "meeting-1", "point-1")).get()
      );
    });

    test("the meeting's own foreman can read its point notes", async () => {
      const db = actor("foreman-a", "foreman-a@example.com");

      await assertSucceeds(
        db.doc(pointNotePath(ORG_A, "meeting-1", "point-1")).get()
      );
    });

    test("a DIFFERENT foreman cannot read point notes for a meeting they " +
      "did not conduct", async () => {
      const db = actor("foreman-b", "foreman-b@example.com");

      await assertFails(
        db.doc(pointNotePath(ORG_A, "meeting-1", "point-1")).get()
      );
    });

    test("a worker has no read access to point notes at all — unlike " +
      "attendance, there is no own-record carve-out here", async () => {
      await seed(async (db) => {
        await db
          .doc(`users/worker-a/memberships/${ORG_A}`)
          .set(membership("worker-a", ORG_A, {
            role: "worker",
            siteIds: ["site-1"],
          }));
      });
      const db = actor("worker-a", "worker-a@example.com");

      await assertFails(
        db.doc(pointNotePath(ORG_A, "meeting-1", "point-1")).get()
      );
    });

    test("no client, including the meeting's own foreman, can create a " +
      "point note by direct write", async () => {
      await assertFails(
        actor("foreman-a", "foreman-a@example.com")
          .doc(pointNotePath(ORG_A, "meeting-1", "point-2"))
          .set({
            meetingId: "meeting-1",
            organizationId: ORG_A,
            siteId: "site-1",
            meetingPointId: "point-2",
            note: "Forged note",
            recordedBy: "foreman-a",
            createdAt: new Date(),
            updatedAt: new Date(),
          })
      );
    });

    test("no client can update an existing point note by direct write",
      async () => {
        await assertFails(
          actor("foreman-a", "foreman-a@example.com")
            .doc(pointNotePath(ORG_A, "meeting-1", "point-1"))
            .update({note: "Tampered note"})
        );
      });

    test("no client can delete a point note by direct write", async () => {
      await assertFails(
        actor("foreman-a", "foreman-a@example.com")
          .doc(pointNotePath(ORG_A, "meeting-1", "point-1"))
          .delete()
      );
    });
  });

  describe("evidence", () => {
    // DESIGN NOTE. Every write is Admin-SDK-only via `addMeetingEvidence`/
    // `removeMeetingEvidence` (`daily_safety_meeting_callable.ts`) — the
    // actual file bytes go to Cloud Storage directly, this collection only
    // ever holds metadata. Read follows `concerns`'/`point_notes`' EXACT
    // shape: Site Manager/Admin see every meeting's evidence; a Foreman
    // sees only their own meeting's evidence; a Worker has NO carve-out.

    function evidencePath(organizationId, meetingId, evidenceId) {
      return `${meetingPath(organizationId, meetingId)}/evidence/` +
        evidenceId;
    }

    beforeEach(async () => {
      await seed(async (db) => {
        await db.doc(evidencePath(ORG_A, "meeting-1", "evidence-1")).set({
          meetingId: "meeting-1",
          organizationId: ORG_A,
          siteId: "site-1",
          evidenceType: "handwrittenNotes",
          storagePath: "organizations/org-alpha/daily_safety_meetings/" +
            "meeting-1/evidence-1/photo.jpg",
          downloadUrl: "https://example.com/photo.jpg",
          fileType: "image/jpeg",
          uploadedBy: "foreman-a",
          createdAt: new Date(),
        });
      });
    });

    test("an org member can read evidence for their own organization's " +
      "meeting", async () => {
      const db = actor("active-a", "active-a@example.com");

      await assertSucceeds(
        db.doc(evidencePath(ORG_A, "meeting-1", "evidence-1")).get()
      );
    });

    test("an org member cannot read another organization's evidence",
      async () => {
        const db = actor("active-a", "active-a@example.com");

        await assertFails(
          db
            .collection(
              `organizations/${ORG_B}/daily_safety_meetings/meeting-1/` +
                "evidence"
            )
            .get()
        );
      });

    test("an Admin can read evidence in any organization", async () => {
      const db = actor("sysadmin-a", "sysadmin-a@example.com");

      await assertSucceeds(
        db.doc(evidencePath(ORG_A, "meeting-1", "evidence-1")).get()
      );
    });

    test("the meeting's own foreman can read its evidence", async () => {
      const db = actor("foreman-a", "foreman-a@example.com");

      await assertSucceeds(
        db.doc(evidencePath(ORG_A, "meeting-1", "evidence-1")).get()
      );
    });

    test("a DIFFERENT foreman cannot read evidence for a meeting they " +
      "did not conduct", async () => {
      const db = actor("foreman-b", "foreman-b@example.com");

      await assertFails(
        db.doc(evidencePath(ORG_A, "meeting-1", "evidence-1")).get()
      );
    });

    test("a worker has no read access to evidence at all", async () => {
      await seed(async (db) => {
        await db
          .doc(`users/worker-a/memberships/${ORG_A}`)
          .set(membership("worker-a", ORG_A, {
            role: "worker",
            siteIds: ["site-1"],
          }));
      });
      const db = actor("worker-a", "worker-a@example.com");

      await assertFails(
        db.doc(evidencePath(ORG_A, "meeting-1", "evidence-1")).get()
      );
    });

    test("no client, including the meeting's own foreman, can create " +
      "evidence metadata by direct write", async () => {
      await assertFails(
        actor("foreman-a", "foreman-a@example.com")
          .doc(evidencePath(ORG_A, "meeting-1", "evidence-2"))
          .set({
            meetingId: "meeting-1",
            organizationId: ORG_A,
            siteId: "site-1",
            evidenceType: "other",
            storagePath: "forged/path.jpg",
            downloadUrl: "https://example.com/forged.jpg",
            fileType: "image/jpeg",
            uploadedBy: "foreman-a",
            createdAt: new Date(),
          })
      );
    });

    test("no client can update existing evidence metadata by direct write",
      async () => {
        await assertFails(
          actor("foreman-a", "foreman-a@example.com")
            .doc(evidencePath(ORG_A, "meeting-1", "evidence-1"))
            .update({description: "Tampered description"})
        );
      });

    test("no client can delete evidence metadata by direct write",
      async () => {
        await assertFails(
          actor("foreman-a", "foreman-a@example.com")
            .doc(evidencePath(ORG_A, "meeting-1", "evidence-1"))
            .delete()
        );
      });
  });
});

describe("the Hazards foundation", () => {
  // DESIGN NOTE. Flat under the organization (a sibling of
  // `corrective_actions`) — see `hazard_callable.ts`'s header note for why.
  // Every write (create, acknowledge, link a corrective action, close) is
  // Admin-SDK-only via `createHazard`/`acknowledgeHazard`/
  // `linkHazardCorrectiveAction`/`closeHazard`, which additionally verify
  // server-side that the caller has site access (for creation) or holds an
  // authorized reviewer role within the same organization (for
  // acknowledge/link/close) — see `canReviewPendingAccounts` in
  // `account_approval.ts`, reused rather than re-derived. There is no
  // delete callable and this rule denies delete too: a hazard is a
  // permanent part of the safety record. Reads follow the same
  // org-member-or-Admin shape as `corrective_actions`.

  function hazardPath(organizationId, hazardId) {
    return `organizations/${organizationId}/hazards/${hazardId}`;
  }

  beforeEach(async () => {
    await seed(async (db) => {
      await db.doc(userPath("worker-a")).set(profile("worker-a", "active"));
      await db
        .doc(`users/worker-a/memberships/${ORG_A}`)
        .set(membership("worker-a", ORG_A, {
          role: "worker",
          siteIds: ["site-1"],
        }));
      await db.doc(hazardPath(ORG_A, "hazard-1")).set({
        organizationId: ORG_A,
        projectId: "project-1",
        siteId: "site-1",
        reportedByUid: "worker-a",
        category: "electrical",
        description: "Exposed wiring near the water tank",
        location: null,
        photoUrl: null,
        status: "reported",
        correctiveActionId: null,
        acknowledgedBy: null,
        acknowledgedAt: null,
        closedBy: null,
        closedAt: null,
        createdAt: new Date(),
        createdBy: "worker-a",
        updatedAt: new Date(),
        updatedBy: "worker-a",
      });
    });
  });

  test("an org member can read their own organization's hazards", async () => {
    const db = actor("active-a", "active-a@example.com");

    await assertSucceeds(db.doc(hazardPath(ORG_A, "hazard-1")).get());
  });

  test("an org member cannot read another organization's hazards",
    async () => {
      const db = actor("active-a", "active-a@example.com");

      await assertFails(
        db.collection(`organizations/${ORG_B}/hazards`).get()
      );
    });

  test("a pending/suspended/rejected user reads no hazard", async () => {
    await assertFails(
      actor("pending-a", "pending-a@example.com")
        .doc(hazardPath(ORG_A, "hazard-1"))
        .get()
    );
    await assertFails(
      actor("suspended-a", "s@example.com")
        .doc(hazardPath(ORG_A, "hazard-1"))
        .get()
    );
  });

  test("an Admin can read every organization's hazards",
    async () => {
      const db = actor("sysadmin-a", "sysadmin-a@example.com");

      await assertSucceeds(db.doc(hazardPath(ORG_A, "hazard-1")).get());
    });

  test("no client, including the reporting worker, can create a hazard " +
    "by direct write", async () => {
    await assertFails(
      actor("worker-a", "worker-a@example.com")
        .doc(hazardPath(ORG_A, "hazard-2"))
        .set({
          organizationId: ORG_A,
          projectId: "project-1",
          siteId: "site-1",
          reportedByUid: "worker-a",
          category: "fire",
          description: "Forged hazard",
          status: "reported",
        })
    );
  });

  test("no client, including an authorized reviewer, can acknowledge, " +
    "link or close a hazard by direct write", async () => {
    await assertFails(
      actor("approver-a", "approver-a@example.com")
        .doc(hazardPath(ORG_A, "hazard-1"))
        .update({status: "acknowledged"})
    );
    await assertFails(
      actor("approver-a", "approver-a@example.com")
        .doc(hazardPath(ORG_A, "hazard-1"))
        .update({status: "closed"})
    );
  });

  test("an Admin cannot write a hazard by direct write " +
    "either", async () => {
    await assertFails(
      actor("sysadmin-a", "sysadmin-a@example.com")
        .doc(hazardPath(ORG_A, "hazard-1"))
        .update({status: "closed"})
    );
  });

  test("no client can delete a hazard — it is a permanent part of the " +
    "safety record", async () => {
    await assertFails(
      actor("approver-a", "approver-a@example.com")
        .doc(hazardPath(ORG_A, "hazard-1"))
        .delete()
    );
    await assertFails(
      actor("sysadmin-a", "sysadmin-a@example.com")
        .doc(hazardPath(ORG_A, "hazard-1"))
        .delete()
    );
  });
});

describe("the Incidents foundation", () => {
  // DESIGN NOTE. Like `hazards`, every write is Admin-SDK-only via
  // `incident_callable.ts`. UNLIKE hazards, reads are restricted: an
  // incident can name an injured person, so only the reporter, a reviewer
  // role (admin/siteManager/foreman) in the same organization, or the System
  // Administrator may read one — not every org member.

  function incidentPath(organizationId, incidentId) {
    return `organizations/${organizationId}/incidents/${incidentId}`;
  }

  beforeEach(async () => {
    await seed(async (db) => {
      await db.doc(userPath("worker-a")).set(profile("worker-a", "active"));
      await db
        .doc(`users/worker-a/memberships/${ORG_A}`)
        .set(membership("worker-a", ORG_A, {
          role: "worker",
          siteIds: ["site-1"],
        }));
      await db.doc(userPath("worker-b")).set(profile("worker-b", "active"));
      await db
        .doc(`users/worker-b/memberships/${ORG_A}`)
        .set(membership("worker-b", ORG_A, {
          role: "worker",
          siteIds: ["site-1"],
        }));
      await db.doc(userPath("foreman-a")).set(profile("foreman-a", "active"));
      await db
        .doc(`users/foreman-a/memberships/${ORG_A}`)
        .set(membership("foreman-a", ORG_A, {
          role: "foreman",
          siteIds: ["site-1"],
        }));
      await db.doc(incidentPath(ORG_A, "incident-1")).set({
        organizationId: ORG_A,
        projectId: "project-1",
        siteId: "site-1",
        reportedByUid: "worker-a",
        type: "injury",
        description: "Cut hand on sheet metal",
        injuredPersonName: "John",
        status: "reported",
        createdAt: new Date(),
      });
    });
  });

  test("the reporter can read their own incident", async () => {
    await assertSucceeds(
      actor("worker-a", "worker-a@example.com")
        .doc(incidentPath(ORG_A, "incident-1"))
        .get()
    );
  });

  test("the reporter's own-incidents query is admitted", async () => {
    await assertSucceeds(
      actor("worker-a", "worker-a@example.com")
        .collection(`organizations/${ORG_A}/incidents`)
        .where("reportedByUid", "==", "worker-a")
        .get()
    );
  });

  test("another worker in the same organization cannot read it",
    async () => {
      await assertFails(
        actor("worker-b", "worker-b@example.com")
          .doc(incidentPath(ORG_A, "incident-1"))
          .get()
      );
      await assertFails(
        actor("worker-b", "worker-b@example.com")
          .collection(`organizations/${ORG_A}/incidents`)
          .get()
      );
    });

  test("a Foreman and a Site Manager can read every incident in their " +
    "organization", async () => {
    await assertSucceeds(
      actor("foreman-a", "foreman-a@example.com")
        .collection(`organizations/${ORG_A}/incidents`)
        .get()
    );
    await assertSucceeds(
      actor("approver-a", "approver-a@example.com")
        .collection(`organizations/${ORG_A}/incidents`)
        .get()
    );
  });

  test("a reviewer cannot read another organization's incidents",
    async () => {
      await assertFails(
        actor("approver-a", "approver-a@example.com")
          .collection(`organizations/${ORG_B}/incidents`)
          .get()
      );
    });

  test("the System Administrator can read it", async () => {
    await assertSucceeds(
      actor("sysadmin-a", "sysadmin-a@example.com")
        .doc(incidentPath(ORG_A, "incident-1"))
        .get()
    );
  });

  test("no client can create, update or delete an incident directly",
    async () => {
      await assertFails(
        actor("worker-a", "worker-a@example.com")
          .doc(incidentPath(ORG_A, "incident-2"))
          .set({organizationId: ORG_A, reportedByUid: "worker-a"})
      );
      await assertFails(
        actor("approver-a", "approver-a@example.com")
          .doc(incidentPath(ORG_A, "incident-1"))
          .update({status: "closed"})
      );
      await assertFails(
        actor("sysadmin-a", "sysadmin-a@example.com")
          .doc(incidentPath(ORG_A, "incident-1"))
          .delete()
      );
    });
});

describe("the Inspections foundation", () => {
  beforeEach(async () => {
    await seed(async (db) => {
      for (const [uid, role] of [["worker-a", "worker"],
        ["foreman-a", "foreman"]]) {
        await db.doc(userPath(uid)).set(profile(uid, "active"));
        await db.doc(`users/${uid}/memberships/${ORG_A}`)
          .set(membership(uid, ORG_A, {role, siteIds: ["site-1"]}));
      }
      await db.doc(`organizations/${ORG_A}/inspections/i1`).set({
        organizationId: ORG_A, siteId: "site-1", status: "submitted",
      });
      await db.doc(`organizations/${ORG_A}/inspection_templates/t1`).set({
        organizationId: ORG_A, name: "Daily", status: "active",
      });
    });
  });

  test("Foremen and Site Managers read inspections and templates",
    async () => {
      for (const [uid, email] of [["foreman-a", "foreman-a@example.com"],
        ["approver-a", "approver-a@example.com"]]) {
        await assertSucceeds(actor(uid, email)
          .collection(`organizations/${ORG_A}/inspections`).get());
        await assertSucceeds(actor(uid, email)
          .collection(`organizations/${ORG_A}/inspection_templates`).get());
      }
    });

  test("a Worker reads neither", async () => {
    const db = actor("worker-a", "worker-a@example.com");
    await assertFails(db.doc(`organizations/${ORG_A}/inspections/i1`).get());
    await assertFails(
      db.doc(`organizations/${ORG_A}/inspection_templates/t1`).get()
    );
  });

  test("no client writes either collection directly", async () => {
    const db = actor("approver-a", "approver-a@example.com");
    await assertFails(db.doc(`organizations/${ORG_A}/inspections/i1`)
      .update({status: "signedOff"}));
    await assertFails(db.doc(`organizations/${ORG_A}/inspection_templates/t2`)
      .set({organizationId: ORG_A, name: "Forged"}));
  });
});

describe("the Corrective Actions foundation", () => {
  // DESIGN NOTE. Flat under the organization (a sibling of
  // `daily_safety_meetings`, not a subcollection of one) — see
  // `corrective_action_callable.ts`'s header note for why. Every write
  // (create, status transition) is Admin-SDK-only via `createCorrectiveAction`
  // and `updateCorrectiveActionStatus`, which additionally verify server-side
  // that the caller is the meeting's own foreman on an `inProgress` meeting
  // (for creation) or an authorized reviewer role within the same
  // organization (for status transitions) — see `canReviewPendingAccounts`
  // in `account_approval.ts`, reused rather than re-derived. There is no
  // delete callable and this rule denies delete too: a corrective action is
  // a permanent part of the safety record. Reads follow the flat
  // any-active-org-member-or-Admin shape most operational collections use
  // (unlike `daily_safety_meetings`, which PHASE 3 scoped by role).

  function actionPath(organizationId, actionId) {
    return `organizations/${organizationId}/corrective_actions/${actionId}`;
  }

  beforeEach(async () => {
    await seed(async (db) => {
      await db.doc(userPath("foreman-a")).set(profile("foreman-a", "active"));
      await db
        .doc(`users/foreman-a/memberships/${ORG_A}`)
        .set(membership("foreman-a", ORG_A, {
          role: "foreman",
          siteIds: ["site-1"],
        }));
      await db.doc(userPath("worker-a")).set(profile("worker-a", "active"));
      await db
        .doc(`users/worker-a/memberships/${ORG_A}`)
        .set(membership("worker-a", ORG_A, {
          role: "worker",
          siteIds: ["site-1"],
        }));
      await db.doc(actionPath(ORG_A, "action-1")).set({
        organizationId: ORG_A,
        projectId: "project-1",
        siteId: "site-1",
        meetingId: "meeting-1",
        concernId: null,
        title: "Fix loose scaffolding",
        description: "Level 3 scaffolding needs tightening",
        assignedTo: "worker-a",
        assignedBy: "foreman-a",
        dueDate: new Date("2026-09-01"),
        status: "open",
        evidenceRequired: false,
        createdAt: new Date(),
        updatedAt: new Date(),
        completedAt: null,
      });
    });
  });

  test("an org member can read their own organization's corrective actions",
    async () => {
      const db = actor("active-a", "active-a@example.com");

      await assertSucceeds(db.doc(actionPath(ORG_A, "action-1")).get());
    });

  test("an org member cannot read another organization's corrective " +
    "actions", async () => {
    const db = actor("active-a", "active-a@example.com");

    await assertFails(
      db.collection(`organizations/${ORG_B}/corrective_actions`).get()
    );
  });

  test("a pending/suspended/rejected user reads no corrective action",
    async () => {
      await assertFails(
        actor("pending-a", "pending-a@example.com")
          .doc(actionPath(ORG_A, "action-1"))
          .get()
      );
      await assertFails(
        actor("suspended-a", "s@example.com")
          .doc(actionPath(ORG_A, "action-1"))
          .get()
      );
    });

  test("an Admin can read every organization's corrective " +
    "actions", async () => {
    const db = actor("sysadmin-a", "sysadmin-a@example.com");

    await assertSucceeds(db.doc(actionPath(ORG_A, "action-1")).get());
  });

  test("no client, including the meeting's own foreman, can create a " +
    "corrective action by direct write", async () => {
    await assertFails(
      actor("foreman-a", "foreman-a@example.com")
        .doc(actionPath(ORG_A, "action-2"))
        .set({
          organizationId: ORG_A,
          projectId: "project-1",
          siteId: "site-1",
          meetingId: "meeting-1",
          concernId: null,
          title: "Forged action",
          description: "x",
          assignedTo: "worker-a",
          assignedBy: "foreman-a",
          dueDate: new Date("2026-09-01"),
          status: "open",
          evidenceRequired: false,
          createdAt: new Date(),
          updatedAt: new Date(),
          completedAt: null,
        })
    );
  });

  test("a worker cannot self-assign a corrective action by direct write " +
    "either", async () => {
    await assertFails(
      actor("worker-a", "worker-a@example.com")
        .doc(actionPath(ORG_A, "action-3"))
        .set({
          organizationId: ORG_A,
          projectId: "project-1",
          siteId: "site-1",
          meetingId: "meeting-1",
          concernId: null,
          title: "Self-assigned action",
          description: "x",
          assignedTo: "worker-a",
          assignedBy: "worker-a",
          dueDate: new Date("2026-09-01"),
          status: "open",
          evidenceRequired: false,
          createdAt: new Date(),
          updatedAt: new Date(),
          completedAt: null,
        })
    );
  });

  test("no client, including an authorized reviewer, can update a " +
    "corrective action's status by direct write", async () => {
    await assertFails(
      actor("approver-a", "approver-a@example.com")
        .doc(actionPath(ORG_A, "action-1"))
        .update({status: "completed"})
    );
    await assertFails(
      actor("foreman-a", "foreman-a@example.com")
        .doc(actionPath(ORG_A, "action-1"))
        .update({status: "completed"})
    );
  });

  test("an Admin cannot write a corrective action by " +
    "direct write either", async () => {
    await assertFails(
      actor("sysadmin-a", "sysadmin-a@example.com")
        .doc(actionPath(ORG_A, "action-1"))
        .update({status: "completed"})
    );
  });

  test("no client can delete a corrective action — it is a permanent " +
    "part of the safety record", async () => {
    await assertFails(
      actor("approver-a", "approver-a@example.com")
        .doc(actionPath(ORG_A, "action-1"))
        .delete()
    );
    await assertFails(
      actor("sysadmin-a", "sysadmin-a@example.com")
        .doc(actionPath(ORG_A, "action-1"))
        .delete()
    );
  });
});

describe("the Safety Alerts foundation", () => {
  // DESIGN NOTE. Flat under the organization (a sibling of
  // `corrective_actions`) — see `safety_alert_callable.ts`'s header note for
  // why. Every write (create, acknowledge, resolve) is Admin-SDK-only via
  // `createSafetyAlert`/`acknowledgeSafetyAlert`/`resolveSafetyAlert`, which
  // additionally verify server-side that the caller holds an authorized
  // reviewer role (`canReviewPendingAccounts` in `account_approval.ts`)
  // within the same organization. There is no delete callable and this rule
  // denies delete too: a safety alert is a permanent part of the safety
  // record. Reads follow the same org-member-or-Admin shape
  // as `corrective_actions`, so a worker/foreman can see every alert for
  // their own organization (the client narrows further to their own site).

  function alertPath(organizationId, alertId) {
    return `organizations/${organizationId}/safety_alerts/${alertId}`;
  }

  beforeEach(async () => {
    await seed(async (db) => {
      await db.doc(alertPath(ORG_A, "alert-1")).set({
        organizationId: ORG_A,
        projectId: "project-1",
        siteId: "site-1",
        title: "Crane inspection overdue",
        description: "Crane 3 has not been inspected this week",
        severity: "high",
        category: "equipment",
        status: "active",
        createdBy: "approver-a",
        createdAt: new Date(),
        acknowledgedAt: null,
        acknowledgedBy: null,
        resolvedAt: null,
        resolvedBy: null,
      });
    });
  });

  test("an org member can read their own organization's safety alerts",
    async () => {
      const db = actor("active-a", "active-a@example.com");

      await assertSucceeds(db.doc(alertPath(ORG_A, "alert-1")).get());
    });

  test("an org member cannot read another organization's safety alerts",
    async () => {
      const db = actor("active-a", "active-a@example.com");

      await assertFails(
        db.collection(`organizations/${ORG_B}/safety_alerts`).get()
      );
    });

  test("a pending/suspended/rejected user reads no safety alert", async () => {
    await assertFails(
      actor("pending-a", "pending-a@example.com")
        .doc(alertPath(ORG_A, "alert-1"))
        .get()
    );
    await assertFails(
      actor("suspended-a", "s@example.com")
        .doc(alertPath(ORG_A, "alert-1"))
        .get()
    );
  });

  test("an Admin can read every organization's safety alerts",
    async () => {
      const db = actor("sysadmin-a", "sysadmin-a@example.com");

      await assertSucceeds(db.doc(alertPath(ORG_A, "alert-1")).get());
    });

  test("no client, including an authorized reviewer, can create a safety " +
    "alert by direct write", async () => {
    await assertFails(
      actor("approver-a", "approver-a@example.com")
        .doc(alertPath(ORG_A, "alert-2"))
        .set({
          organizationId: ORG_A,
          projectId: "project-1",
          siteId: "site-1",
          title: "Forged alert",
          description: "x",
          severity: "low",
          category: "other",
          status: "active",
          createdBy: "approver-a",
          createdAt: new Date(),
          acknowledgedAt: null,
          acknowledgedBy: null,
          resolvedAt: null,
          resolvedBy: null,
        })
    );
  });

  test("a worker cannot create a safety alert by direct write either",
    async () => {
      await assertFails(
        actor("active-a", "active-a@example.com")
          .doc(alertPath(ORG_A, "alert-3"))
          .set({
            organizationId: ORG_A,
            projectId: "project-1",
            siteId: "site-1",
            title: "Self-granted alert",
            description: "x",
            severity: "low",
            category: "other",
            status: "active",
            createdBy: "active-a",
            createdAt: new Date(),
          })
      );
    });

  test("no client, including an authorized reviewer, can acknowledge or " +
    "resolve a safety alert by direct write", async () => {
    await assertFails(
      actor("approver-a", "approver-a@example.com")
        .doc(alertPath(ORG_A, "alert-1"))
        .update({status: "acknowledged"})
    );
    await assertFails(
      actor("approver-a", "approver-a@example.com")
        .doc(alertPath(ORG_A, "alert-1"))
        .update({status: "resolved"})
    );
  });

  test("an Admin cannot write a safety alert by direct " +
    "write either", async () => {
    await assertFails(
      actor("sysadmin-a", "sysadmin-a@example.com")
        .doc(alertPath(ORG_A, "alert-1"))
        .update({status: "resolved"})
    );
  });

  test("no client can delete a safety alert — it is a permanent part of " +
    "the safety record", async () => {
    await assertFails(
      actor("approver-a", "approver-a@example.com")
        .doc(alertPath(ORG_A, "alert-1"))
        .delete()
    );
    await assertFails(
      actor("sysadmin-a", "sysadmin-a@example.com")
        .doc(alertPath(ORG_A, "alert-1"))
        .delete()
    );
  });
});

describe("the Notifications foundation", () => {
  // DESIGN NOTE. Flat under the organization (a sibling of
  // `safety_alerts`), but scoped narrower than every other operational
  // collection tested so far — a notification is personal data addressed to
  // exactly one `recipientUid`. Read is limited to the notification's own
  // `recipientUid` or an Admin, deliberately NOT any org member and NOT
  // even a Site Manager, mirroring
  // `worker_learning_records`'s "owning worker only" shape but without that
  // collection's admin compliance-viewing carve-out. There is no
  // client-reachable creation callable at all — `createNotification` in
  // `notification_callable.ts` is a plain internal function, never
  // exported — so every create attempt below is expected to fail
  // regardless of who attempts it. `markNotificationRead`/
  // `markAllNotificationsRead` are Admin-SDK-only and re-derive the acting
  // user from their own auth token, refusing unless
  // `notification.recipientUid` matches.

  function notificationPath(organizationId, notificationId) {
    return `organizations/${organizationId}/notifications/${notificationId}`;
  }

  beforeEach(async () => {
    await seed(async (db) => {
      await db.doc(notificationPath(ORG_A, "notif-1")).set({
        organizationId: ORG_A,
        recipientUid: "active-a",
        type: "system",
        title: "Welcome",
        message: "Your account is active",
        relatedEntityType: null,
        relatedEntityId: null,
        isRead: false,
        createdAt: new Date(),
        readAt: null,
      });
    });
  });

  test("the recipient can read their own notification", async () => {
    const db = actor("active-a", "active-a@example.com");

    await assertSucceeds(db.doc(notificationPath(ORG_A, "notif-1")).get());
  });

  // Previously a real authorization gap: the trailing
  // `match /{operationalCollection}/{documentId=**}` catch-all also matched
  // `notifications` and granted read to any active org member, even though
  // this block's own rule intends "recipient or Admin only". Fixed by
  // excluding `notifications` (and `worker_learning_records`) from that
  // catch-all by name — see firestore.rules.
  test("another org member cannot read someone else's notification",
    async () => {
      // active-b belongs to ORG_B in the shared fixtures, so this also
      // covers cross-organization denial; a same-organization cross-user
      // case is covered by approver-a below.
      const db = actor("approver-a", "approver-a@example.com");

      await assertFails(db.doc(notificationPath(ORG_A, "notif-1")).get());
    });

  test("a user in another organization cannot read this notification",
    async () => {
      const db = actor("active-b", "active-b@example.com");

      await assertFails(db.doc(notificationPath(ORG_A, "notif-1")).get());
    });

  // Same fix as above applied to a collection query rather than a single
  // document read.
  test("no client can list another user's notifications by collection " +
    "query", async () => {
    const db = actor("approver-a", "approver-a@example.com");

    await assertFails(
      db
        .collection(`organizations/${ORG_A}/notifications`)
        .where("recipientUid", "==", "active-a")
        .get()
    );
  });

  test("a pending/suspended/rejected user cannot read even their own " +
    "notification", async () => {
    // Notifications for these accounts are not seeded, but the read rule
    // itself must still require active membership regardless of
    // recipientUid — accountStatus gates before recipientUid is checked.
    await assertFails(
      actor("pending-a", "pending-a@example.com")
        .doc(notificationPath(ORG_A, "notif-1"))
        .get()
    );
  });

  test("an Admin can read any organization's notifications",
    async () => {
      const db = actor("sysadmin-a", "sysadmin-a@example.com");

      await assertSucceeds(db.doc(notificationPath(ORG_A, "notif-1")).get());
    });

  test("no client, including the recipient, can create a notification by " +
    "direct write", async () => {
    await assertFails(
      actor("active-a", "active-a@example.com")
        .doc(notificationPath(ORG_A, "notif-2"))
        .set({
          organizationId: ORG_A,
          recipientUid: "active-a",
          type: "system",
          title: "Self-granted notification",
          message: "x",
          isRead: false,
          createdAt: new Date(),
        })
    );
  });

  test("a user cannot create a notification addressed to someone else " +
    "either", async () => {
    await assertFails(
      actor("approver-a", "approver-a@example.com")
        .doc(notificationPath(ORG_A, "notif-3"))
        .set({
          organizationId: ORG_A,
          recipientUid: "active-a",
          type: "system",
          title: "Forged notification",
          message: "x",
          isRead: false,
          createdAt: new Date(),
        })
    );
  });

  test("the recipient cannot mark their own notification read by direct " +
    "write — must go through markNotificationRead", async () => {
    await assertFails(
      actor("active-a", "active-a@example.com")
        .doc(notificationPath(ORG_A, "notif-1"))
        .update({isRead: true, readAt: new Date()})
    );
  });

  test("no client can change recipientUid or content by direct write",
    async () => {
      await assertFails(
        actor("active-a", "active-a@example.com")
          .doc(notificationPath(ORG_A, "notif-1"))
          .update({recipientUid: "approver-a"})
      );
      await assertFails(
        actor("active-a", "active-a@example.com")
          .doc(notificationPath(ORG_A, "notif-1"))
          .update({title: "Tampered title"})
      );
    });

  test("an Admin cannot write a notification by direct " +
    "write either", async () => {
    await assertFails(
      actor("sysadmin-a", "sysadmin-a@example.com")
        .doc(notificationPath(ORG_A, "notif-1"))
        .update({isRead: true})
    );
  });

  test("no client can delete a notification", async () => {
    await assertFails(
      actor("active-a", "active-a@example.com")
        .doc(notificationPath(ORG_A, "notif-1"))
        .delete()
    );
    await assertFails(
      actor("sysadmin-a", "sysadmin-a@example.com")
        .doc(notificationPath(ORG_A, "notif-1"))
        .delete()
    );
  });
});

describe("audit logs", () => {
  beforeEach(async () => {
    await seed(async (db) => {
      await db.doc("audit_logs/log-1").set({
        organizationId: ORG_A,
        actorUid: "operator:service-account",
        action: "account.approved",
        createdAt: new Date(),
      });
    });
  });

  test("no client may write an audit log", async () => {
    const db = actor("active-a", "active-a@example.com");

    await assertFails(db.doc("audit_logs/forged").set({organizationId: ORG_A}));
    await assertFails(db.doc("audit_logs/log-1").update({action: "x"}));
    await assertFails(db.doc("audit_logs/log-1").delete());
  });

  test("no client may read audit logs until roles exist", async () => {
    const db = actor("active-a", "active-a@example.com");

    await assertFails(db.doc("audit_logs/log-1").get());
  });
});

describe("the multi-organization membership model", () => {
  // DESIGN NOTE. A user's relationship to a specific organization now lives
  // on users/{uid}/memberships/{organizationId} rather than a scalar
  // organizationId field on the profile — see firestore.rules's header
  // note. `belongsToOrganization(organizationId)` requires an ACTIVE
  // membership document for that exact organization; a suspended membership
  // no longer counts as belonging, and a person can hold more than one
  // membership simultaneously, each independently active or suspended.

  test("a user with two active memberships in different organizations " +
    "can read both organizations' data", async () => {
    await seed(async (db) => {
      await db.doc(userPath("multi-org-user")).set(
        profile("multi-org-user", "active")
      );
      await db
        .doc(`users/multi-org-user/memberships/${ORG_A}`)
        .set(membership("multi-org-user", ORG_A, {role: "siteManager"}));
      await db
        .doc(`users/multi-org-user/memberships/${ORG_B}`)
        .set(membership("multi-org-user", ORG_B, {role: "siteManager"}));
    });
    const db = actor("multi-org-user", "multi-org-user@example.com");

    await assertSucceeds(db.doc(`organizations/${ORG_A}`).get());
    await assertSucceeds(db.doc(`organizations/${ORG_B}`).get());
  });

  test("a user with one active and one suspended membership can read " +
    "only the active organization's data, and suspending one membership " +
    "does not affect the other", async () => {
    await seed(async (db) => {
      await db.doc(userPath("mixed-status-user")).set(
        profile("mixed-status-user", "active")
      );
      await db
        .doc(`users/mixed-status-user/memberships/${ORG_A}`)
        .set(membership("mixed-status-user", ORG_A, {status: "active"}));
      await db
        .doc(`users/mixed-status-user/memberships/${ORG_B}`)
        .set(membership("mixed-status-user", ORG_B, {status: "suspended"}));
    });
    const db = actor("mixed-status-user", "mixed-status-user@example.com");

    await assertSucceeds(db.doc(`organizations/${ORG_A}`).get());
    await assertFails(db.doc(`organizations/${ORG_B}`).get());
  });

  test("a membership suspended in one organization does not touch " +
    "another organization's membership document", async () => {
    // Simulates suspendMembership having already run for ORG_B only —
    // proves the ORG_A membership document itself is untouched (still
    // active, still readable), not merely that the read succeeds.
    await seed(async (db) => {
      await db.doc(userPath("multi-org-user-2")).set(
        profile("multi-org-user-2", "active")
      );
      await db
        .doc(`users/multi-org-user-2/memberships/${ORG_A}`)
        .set(membership("multi-org-user-2", ORG_A, {status: "active"}));
      await db
        .doc(`users/multi-org-user-2/memberships/${ORG_B}`)
        .set(membership("multi-org-user-2", ORG_B, {status: "active"}));
    });

    // Admin-SDK write, exactly like suspendMembership would perform.
    await seed(async (db) => {
      await db
        .doc(`users/multi-org-user-2/memberships/${ORG_B}`)
        .update({status: "suspended"});
    });

    // withSecurityRulesDisabled awaits its callback but discards the
    // result, so the snapshot must be captured into an outer variable
    // rather than returned.
    let orgAMembership;
    await testEnv.withSecurityRulesDisabled(async (context) => {
      orgAMembership = await context
        .firestore()
        .doc(`users/multi-org-user-2/memberships/${ORG_A}`)
        .get();
    });
    expect(orgAMembership.data().status).toBe("active");

    const db = actor("multi-org-user-2", "multi-org-user-2@example.com");
    await assertSucceeds(db.doc(`organizations/${ORG_A}`).get());
    await assertFails(db.doc(`organizations/${ORG_B}`).get());
  });

  describe("users/{uid}/memberships/{organizationId} rules", () => {
    test("a user can read their own membership documents", async () => {
      const db = actor("active-a", "active-a@example.com");

      await assertSucceeds(
        db.doc(`users/active-a/memberships/${ORG_A}`).get()
      );
    });

    test("a user cannot read another user's membership documents",
      async () => {
        const db = actor("active-a", "active-a@example.com");

        await assertFails(
          db.doc(`users/active-b/memberships/${ORG_B}`).get()
        );
      });

    test("an Admin can read anyone's membership documents", async () => {
      const db = actor("sysadmin-a", "sysadmin-a@example.com");

      await assertSucceeds(
        db.doc(`users/active-a/memberships/${ORG_A}`).get()
      );
      await assertSucceeds(
        db.doc(`users/active-b/memberships/${ORG_B}`).get()
      );
    });

    test("no client, Admin included, can create a membership document " +
      "by direct write", async () => {
      await assertFails(
        actor("active-a", "active-a@example.com")
          .doc(`users/active-a/memberships/${ORG_B}`)
          .set(membership("active-a", ORG_B))
      );
      await assertFails(
        actor("sysadmin-a", "sysadmin-a@example.com")
          .doc(`users/active-a/memberships/${ORG_B}`)
          .set(membership("active-a", ORG_B))
      );
    });

    test("no client, Admin included, can update a membership document " +
      "by direct write", async () => {
      await assertFails(
        actor("active-a", "active-a@example.com")
          .doc(`users/active-a/memberships/${ORG_A}`)
          .update({role: "siteManager"})
      );
      await assertFails(
        actor("sysadmin-a", "sysadmin-a@example.com")
          .doc(`users/active-a/memberships/${ORG_A}`)
          .update({status: "suspended"})
      );
    });

    test("a user cannot grant themselves a second organization's " +
      "membership by direct write", async () => {
      const db = actor("active-a", "active-a@example.com");

      await assertFails(
        db
          .doc(`users/active-a/memberships/${ORG_B}`)
          .set(membership("active-a", ORG_B, {role: "siteManager"}))
      );
    });

    test("no client can delete a membership document", async () => {
      await assertFails(
        actor("active-a", "active-a@example.com")
          .doc(`users/active-a/memberships/${ORG_A}`)
          .delete()
      );
      await assertFails(
        actor("sysadmin-a", "sysadmin-a@example.com")
          .doc(`users/active-a/memberships/${ORG_A}`)
          .delete()
      );
    });

    test("a pending user has no membership documents to read", async () => {
      const db = actor("pending-a", "pending-a@example.com");

      // isSelf(userId) permits pending-a to READ this path; the rule is not
      // what makes this doc absent. There is simply no membership document
      // here to find (a pending user has never been approved into one), so
      // the read itself succeeds and resolves to a non-existent snapshot,
      // exactly like reading any other absent document you're allowed to
      // read — assertFails would wrongly demand a permission error where
      // none occurs.
      const snapshot = await assertSucceeds(
        db.doc(`users/pending-a/memberships/${ORG_A}`).get()
      );
      expect(snapshot.exists).toBe(false);
    });
  });
});

describe("the Daily Pre-Start Check foundation", () => {
  // A pre-start check is a worker's own daily safety record: readable by
  // that worker, by a Foreman whose own sites include the check's site, by
  // any Site Manager of the organization and by an Admin — never by other
  // workers or by a Foreman of another site. Every write is Admin-SDK-only
  // via `submitPreStartCheck`.

  const CHECK = `organizations/${ORG_A}/pre_start_checks/active-a_2026-10-06`;

  beforeEach(async () => {
    await seed(async (db) => {
      await db.doc(CHECK).set({
        organizationId: ORG_A,
        workerUid: "active-a",
        siteId: "site-1",
        date: "2026-10-06",
        outcome: "stop",
        answers: [],
      });
      await db.doc(userPath("worker-other")).set(
        profile("worker-other", "active")
      );
      await db.doc(`users/worker-other/memberships/${ORG_A}`)
        .set(membership("worker-other", ORG_A, {siteIds: ["site-1"]}));
      await db.doc(userPath("foreman-site-1")).set(
        profile("foreman-site-1", "active")
      );
      await db.doc(`users/foreman-site-1/memberships/${ORG_A}`).set(
        membership("foreman-site-1", ORG_A,
          {role: "foreman", siteIds: ["site-1"]})
      );
      await db.doc(userPath("foreman-site-2")).set(
        profile("foreman-site-2", "active")
      );
      await db.doc(`users/foreman-site-2/memberships/${ORG_A}`).set(
        membership("foreman-site-2", ORG_A,
          {role: "foreman", siteIds: ["site-2"]})
      );
    });
  });

  test("the worker, their site's Foreman, a Site Manager and an Admin can " +
    "read it", async () => {
    for (const uid of [
      "active-a", "foreman-site-1", "approver-a", "sysadmin-a",
    ]) {
      await assertSucceeds(actor(uid, `${uid}@example.com`).doc(CHECK).get());
    }
  });

  test("another worker, another site's Foreman and another organization " +
    "cannot read it", async () => {
    for (const uid of ["worker-other", "foreman-site-2", "active-b"]) {
      await assertFails(actor(uid, `${uid}@example.com`).doc(CHECK).get());
    }
  });

  test("no client can write one — not even the worker it belongs to",
    async () => {
      const own = actor("active-a", "active-a@example.com");
      await assertFails(own.doc(CHECK).update({outcome: "go"}));
      await assertFails(own.doc(CHECK).delete());
      await assertFails(own
        .doc(`organizations/${ORG_A}/pre_start_checks/active-a_2026-10-07`)
        .set({workerUid: "active-a", siteId: "site-1", outcome: "go"}));
      await assertFails(actor("sysadmin-a", "sysadmin-a@example.com")
        .doc(CHECK).update({outcome: "go"}));
    });
});
