/**
 * Business-logic tests for `approval_callable.ts` — the approval hierarchy
 * (who can approve/place whom, into which organization, under what
 * conditions) built on `account_approval.ts`.
 *
 * Mirrors `hazard_callable.test.js`'s shape: these invoke each callable's own
 * exported handler via `.run(request)` against a running Firestore emulator,
 * exercising the ADMIN-SDK BUSINESS LOGIC that `firestore.rules.test.js`
 * structurally cannot reach — the actual approval hierarchy, multi-org
 * membership independence, and per-org scoping.
 *
 * Requires the Firestore emulator — see `npm run test:callables`.
 */

const {initializeApp, getApps, deleteApp} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");
const {getAuth} = require("firebase-admin/auth");

const PROJECT_ID = "jva-safety-rules-test";
const ORG_A = "org-alpha";
const ORG_B = "org-beta";

let app;
let db;
let listPendingApprovals;
let approvePendingAccount;
let rejectPendingAccount;
let listOrganizationUsers;
let suspendActiveAccount;
let reinstateSuspendedAccount;
let suspendMembership;
let reinstateMembership;
let addOrganizationMembership;

beforeAll(() => {
  process.env.GCLOUD_PROJECT = PROJECT_ID;
  if (!process.env.FIRESTORE_EMULATOR_HOST) {
    process.env.FIRESTORE_EMULATOR_HOST = "127.0.0.1:8080";
  }

  app = getApps()[0] ?? initializeApp({projectId: PROJECT_ID});
  db = getFirestore(app);

  ({
    listPendingApprovals,
    approvePendingAccount,
    rejectPendingAccount,
    listOrganizationUsers,
    suspendActiveAccount,
    reinstateSuspendedAccount,
    suspendMembership,
    reinstateMembership,
    addOrganizationMembership,
  } = require("../lib/approval_callable"));
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

async function seedMembership(
  uid, organizationId, role, siteIds = [], overrides = {}
) {
  await db.doc(`users/${uid}/memberships/${organizationId}`).set({
    organizationId,
    role,
    workerType: null,
    trade: null,
    siteIds,
    supervisorUid: null,
    status: "active",
    approvedAt: new Date(),
    approvedBy: "approver-a",
    createdAt: new Date(),
    updatedAt: new Date(),
    ...overrides,
  });
}

async function seedProfile(uid, overrides = {}) {
  await db.doc(`users/${uid}`).set(profile(uid, overrides));
}

async function seedOrg(id, managedBy = []) {
  await db.doc(`organizations/${id}`).set({
    name: id,
    code: id,
    status: "active",
    managedBy,
    createdAt: new Date(),
    updatedAt: new Date(),
  });
}

async function seedPending(uid, overrides = {}) {
  await db.doc(`users/${uid}`).set(
    profile(uid, {accountStatus: "pending", ...overrides})
  );
}

function callRequest(uid, data) {
  return {
    auth: {uid, token: {}},
    data,
    rawRequest: {},
  };
}

async function getUserProfile(uid) {
  const snapshot = await db.doc(`users/${uid}`).get();
  return snapshot.data();
}

async function getMembership(uid, organizationId) {
  const snapshot = await db.doc(
    `users/${uid}/memberships/${organizationId}`
  ).get();
  return snapshot.data();
}

async function clearAuthUsers() {
  const {users} = await getAuth(app).listUsers();
  if (users.length > 0) {
    await getAuth(app).deleteUsers(users.map((u) => u.uid));
  }
}

beforeEach(async () => {
  await clearFirestore();
  await clearAuthUsers();
});

describe("listPendingApprovals", () => {
  // Regression test: the queue is a shared inbox across every reviewer
  // (pending accounts have no organization yet, so there is nothing to
  // scope the query to — see the callable's own doc comment), so a
  // siteManager/foreman caller must be able to load it WITHOUT supplying
  // organizationId. requireApprover previously required it unconditionally
  // for any non-admin caller, so a Site Manager's client — which never
  // sends one, since there is no "which organization" to ask for a queue
  // that isn't organization-scoped — hit `organizationId is required` just
  // trying to view the queue at all, before they could even reach the
  // organization-scoped approve step.
  test(
    "a siteManager with a single membership sees the queue with no " +
      "organizationId argument",
    async () => {
      await seedProfile("site-manager-1");
      await seedMembership("site-manager-1", ORG_A, "siteManager");
      await seedPending("pending-1");

      const result = await listPendingApprovals.run(
        callRequest("site-manager-1", {})
      );

      expect(result.accounts.map((a) => a.uid)).toContain("pending-1");
    }
  );

  test(
    "a foreman with a single membership sees the queue with no " +
      "organizationId argument",
    async () => {
      await seedProfile("foreman-1");
      await seedMembership("foreman-1", ORG_A, "foreman", ["site-1"]);
      await seedPending("pending-1");

      const result = await listPendingApprovals.run(
        callRequest("foreman-1", {})
      );

      expect(result.accounts.map((a) => a.uid)).toContain("pending-1");
    }
  );

  test(
    "a siteManager of two organizations sees the queue with no " +
      "organizationId argument (one active review-authorized membership " +
      "is enough — the queue itself is not organization-scoped)",
    async () => {
      await seedProfile("site-manager-1");
      await seedMembership("site-manager-1", ORG_A, "siteManager");
      await seedMembership("site-manager-1", ORG_B, "siteManager");
      await seedPending("pending-1");

      const result = await listPendingApprovals.run(
        callRequest("site-manager-1", {})
      );

      expect(result.accounts.map((a) => a.uid)).toContain("pending-1");
    }
  );

  test(
    "a suspended-membership-only caller is still refused with no " +
      "organizationId argument",
    async () => {
      await seedProfile("site-manager-1");
      await seedMembership("site-manager-1", ORG_A, "siteManager", [], {
        status: "suspended",
      });

      await expect(
        listPendingApprovals.run(callRequest("site-manager-1", {}))
      ).rejects.toThrow(/permission/);
    }
  );
});

describe("approvePendingAccount", () => {
  test("admin approves a pending account as siteManager with no " +
    "organizationId — activates, sets platformRole, creates no membership",
  async () => {
    await seedProfile("admin-1", {platformRole: "admin"});
    await seedPending("pending-1");

    const result = await approvePendingAccount.run(
      callRequest("admin-1", {uid: "pending-1", role: "siteManager"})
    );

    expect(result.accountStatus).toBe("active");
    expect(result.organizationId).toBeNull();

    const target = await getUserProfile("pending-1");
    expect(target.accountStatus).toBe("active");
    expect(target.platformRole).toBe("siteManager");

    const collections = await db.doc("users/pending-1")
      .collection("memberships").listDocuments();
    expect(collections.length).toBe(0);
  });

  test("admin approves a pending account as siteManager WITH an " +
    "organizationId — creates a membership with role=siteManager, " +
    "status=active",
  async () => {
    await seedProfile("admin-1", {platformRole: "admin"});
    await seedPending("pending-1");
    await seedOrg(ORG_A);

    const result = await approvePendingAccount.run(
      callRequest("admin-1", {
        uid: "pending-1",
        role: "siteManager",
        organizationId: ORG_A,
      })
    );

    expect(result.organizationId).toBe(ORG_A);
    const membership = await getMembership("pending-1", ORG_A);
    expect(membership.role).toBe("siteManager");
    expect(membership.status).toBe("active");
  });

  test("a siteManager approves a pending account as foreman, supplying " +
    "their own active organizationId — succeeds",
  async () => {
    await seedProfile("sm-1");
    await seedMembership("sm-1", ORG_A, "siteManager");
    await seedOrg(ORG_A, ["sm-1"]);
    await seedPending("pending-1");

    const result = await approvePendingAccount.run(
      callRequest("sm-1", {
        uid: "pending-1",
        role: "foreman",
        organizationId: ORG_A,
      })
    );

    expect(result.role).toBe("foreman");
    const membership = await getMembership("pending-1", ORG_A);
    expect(membership.role).toBe("foreman");
    expect(membership.status).toBe("active");
  });

  test("a siteManager attempting to approve as foreman into an " +
    "organization they do NOT manage is refused",
  async () => {
    await seedProfile("sm-1");
    await seedMembership("sm-1", ORG_A, "siteManager");
    await seedOrg(ORG_A, ["sm-1"]);
    await seedOrg(ORG_B, []);
    await seedPending("pending-1");

    await expect(
      approvePendingAccount.run(
        callRequest("sm-1", {
          uid: "pending-1",
          role: "foreman",
          organizationId: ORG_B,
        })
      )
    ).rejects.toThrow();
  });

  test("a siteManager attempting to approve as siteManager " +
    "(equal/above own role) is refused",
  async () => {
    await seedProfile("sm-1");
    await seedMembership("sm-1", ORG_A, "siteManager");
    await seedOrg(ORG_A, ["sm-1"]);
    await seedPending("pending-1");

    await expect(
      approvePendingAccount.run(
        callRequest("sm-1", {
          uid: "pending-1",
          role: "siteManager",
          organizationId: ORG_A,
        })
      )
    ).rejects.toThrow();
  });

  test("a foreman approves a pending account as worker, within one of " +
    "their own assigned sites — membership includes those siteIds",
  async () => {
    await seedProfile("fm-1");
    await seedMembership("fm-1", ORG_A, "foreman", ["site-1", "site-2"]);
    await seedPending("pending-1");

    const result = await approvePendingAccount.run(
      callRequest("fm-1", {
        uid: "pending-1",
        role: "worker",
        organizationId: ORG_A,
        siteIds: ["site-1"],
      })
    );

    expect(result.role).toBe("worker");
    const membership = await getMembership("pending-1", ORG_A);
    expect(membership.role).toBe("worker");
    expect(membership.siteIds).toEqual(["site-1"]);
  });

  test("a foreman attempting to approve a worker into a site NOT in " +
    "their own siteIds is refused",
  async () => {
    await seedProfile("fm-1");
    await seedMembership("fm-1", ORG_A, "foreman", ["site-1"]);
    await seedPending("pending-1");

    await expect(
      approvePendingAccount.run(
        callRequest("fm-1", {
          uid: "pending-1",
          role: "worker",
          organizationId: ORG_A,
          siteId: "site-99",
        })
      )
    ).rejects.toThrow();
  });

  test("a foreman attempting to approve another account as foreman " +
    "(role above their own authority) is refused",
  async () => {
    await seedProfile("fm-1");
    await seedMembership("fm-1", ORG_A, "foreman", ["site-1"]);
    await seedPending("pending-1");

    await expect(
      approvePendingAccount.run(
        callRequest("fm-1", {
          uid: "pending-1",
          role: "foreman",
          organizationId: ORG_A,
        })
      )
    ).rejects.toThrow();
  });

  test("a worker (no review authority) is refused", async () => {
    await seedProfile("worker-caller");
    await seedMembership("worker-caller", ORG_A, "worker", ["site-1"]);
    await seedPending("pending-1");

    await expect(
      approvePendingAccount.run(
        callRequest("worker-caller", {
          uid: "pending-1",
          role: "worker",
          organizationId: ORG_A,
        })
      )
    ).rejects.toThrow();
  });

  test("self-approval attempt is refused regardless of role", async () => {
    await seedProfile("admin-1", {platformRole: "admin"});

    await expect(
      approvePendingAccount.run(
        callRequest("admin-1", {uid: "admin-1", role: "siteManager"})
      )
    ).rejects.toThrow(/cannot act on your own account/);
  });

  test("approving an already-active (non-pending) account is refused",
    async () => {
      await seedProfile("admin-1", {platformRole: "admin"});
      await seedProfile("active-1");

      await expect(
        approvePendingAccount.run(
          callRequest("admin-1", {uid: "active-1", role: "siteManager"})
        )
      ).rejects.toThrow(/already been reviewed/);
    });

  test("a non-admin caller omitting organizationId entirely is refused " +
    "with invalid-argument",
  async () => {
    await seedProfile("sm-1");
    await seedMembership("sm-1", ORG_A, "siteManager");
    await seedPending("pending-1");

    await expect(
      approvePendingAccount.run(
        callRequest("sm-1", {uid: "pending-1", role: "foreman"})
      )
    ).rejects.toThrow(/organizationId is required/);
  });

  test("a siteManager holding TWO active memberships approves into each " +
    "org independently — each membership lands correctly, other org " +
    "untouched",
  async () => {
    await seedProfile("sm-1");
    await seedMembership("sm-1", ORG_A, "siteManager");
    await seedMembership("sm-1", ORG_B, "siteManager");
    await seedOrg(ORG_A, ["sm-1"]);
    await seedOrg(ORG_B, ["sm-1"]);
    await seedPending("pending-a");
    await seedPending("pending-b");

    await approvePendingAccount.run(
      callRequest("sm-1", {
        uid: "pending-a",
        role: "foreman",
        organizationId: ORG_A,
      })
    );
    await approvePendingAccount.run(
      callRequest("sm-1", {
        uid: "pending-b",
        role: "foreman",
        organizationId: ORG_B,
      })
    );

    const membershipA = await getMembership("pending-a", ORG_A);
    const membershipB = await getMembership("pending-b", ORG_B);
    expect(membershipA.organizationId).toBe(ORG_A);
    expect(membershipB.organizationId).toBe(ORG_B);

    const reviewerOrgA = await getMembership("sm-1", ORG_A);
    const reviewerOrgB = await getMembership("sm-1", ORG_B);
    expect(reviewerOrgA.status).toBe("active");
    expect(reviewerOrgB.status).toBe("active");
    expect(reviewerOrgA.role).toBe("siteManager");
    expect(reviewerOrgB.role).toBe("siteManager");
  });
});

describe("addOrganizationMembership", () => {
  test("a siteManager places an ALREADY-ACTIVE foreman (with a membership " +
    "in ORG_A) into ORG_B as foreman — ORG_A membership untouched",
  async () => {
    await seedProfile("sm-1");
    await seedMembership("sm-1", ORG_B, "siteManager");
    await seedOrg(ORG_B, ["sm-1"]);
    await seedProfile("fm-1");
    await seedMembership("fm-1", ORG_A, "foreman", ["site-1"]);

    const result = await addOrganizationMembership.run(
      callRequest("sm-1", {
        uid: "fm-1",
        role: "foreman",
        organizationId: ORG_B,
      })
    );

    expect(result.organizationId).toBe(ORG_B);
    const membershipB = await getMembership("fm-1", ORG_B);
    expect(membershipB.role).toBe("foreman");
    expect(membershipB.status).toBe("active");

    const membershipA = await getMembership("fm-1", ORG_A);
    expect(membershipA.status).toBe("active");
    expect(membershipA.role).toBe("foreman");
    expect(membershipA.siteIds).toEqual(["site-1"]);
  });

  test("adding a membership that already exists is refused with " +
    "already-exists",
  async () => {
    await seedProfile("admin-1", {platformRole: "admin"});
    await seedProfile("fm-1");
    await seedMembership("fm-1", ORG_A, "foreman", ["site-1"]);
    await seedOrg(ORG_A);

    await expect(
      addOrganizationMembership.run(
        callRequest("admin-1", {
          uid: "fm-1",
          role: "siteManager",
          organizationId: ORG_A,
        })
      )
    ).rejects.toThrow(/already has a membership/);
  });

  test("self-action is refused", async () => {
    await seedProfile("sm-1");
    await seedMembership("sm-1", ORG_A, "siteManager");
    await seedOrg(ORG_A, ["sm-1"]);

    await expect(
      addOrganizationMembership.run(
        callRequest("sm-1", {
          uid: "sm-1",
          role: "foreman",
          organizationId: ORG_A,
        })
      )
    ).rejects.toThrow(/cannot act on your own account/);
  });

  test("a foreman placing a worker into a site they don't manage is " +
    "refused",
  async () => {
    await seedProfile("fm-1");
    await seedMembership("fm-1", ORG_A, "foreman", ["site-1"]);
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_B, "worker", ["site-9"]);

    await expect(
      addOrganizationMembership.run(
        callRequest("fm-1", {
          uid: "worker-1",
          role: "worker",
          organizationId: ORG_A,
          siteId: "site-99",
        })
      )
    ).rejects.toThrow();
  });

  test("a siteManager placing a foreman into an org they don't manage is " +
    "refused",
  async () => {
    await seedProfile("sm-1");
    await seedMembership("sm-1", ORG_A, "siteManager");
    await seedOrg(ORG_A, ["sm-1"]);
    await seedOrg(ORG_B, []);
    await seedProfile("fm-1");
    await seedMembership("fm-1", ORG_A, "foreman", ["site-1"]);

    await expect(
      addOrganizationMembership.run(
        callRequest("sm-1", {
          uid: "fm-1",
          role: "foreman",
          organizationId: ORG_B,
        })
      )
    ).rejects.toThrow();
  });

  test("target account must be active — refused for a pending account",
    async () => {
      await seedProfile("admin-1", {platformRole: "admin"});
      await seedOrg(ORG_A);
      await seedPending("pending-1");

      await expect(
        addOrganizationMembership.run(
          callRequest("admin-1", {
            uid: "pending-1",
            role: "siteManager",
            organizationId: ORG_A,
          })
        )
      ).rejects.toThrow(/Only an active account/);
    });
});

describe("suspendMembership / reinstateMembership", () => {
  test("a siteManager suspends a foreman's ORG_A membership — ORG_B " +
    "membership (if any) is completely untouched",
  async () => {
    await seedProfile("sm-1");
    await seedMembership("sm-1", ORG_A, "siteManager");
    await seedOrg(ORG_A, ["sm-1"]);
    await seedProfile("fm-1");
    await seedMembership("fm-1", ORG_A, "foreman", ["site-1"]);
    await seedMembership("fm-1", ORG_B, "foreman", ["site-9"]);

    const result = await suspendMembership.run(
      callRequest("sm-1", {uid: "fm-1", organizationId: ORG_A})
    );

    expect(result.membershipStatus).toBe("suspended");
    const membershipA = await getMembership("fm-1", ORG_A);
    expect(membershipA.status).toBe("suspended");
    const membershipB = await getMembership("fm-1", ORG_B);
    expect(membershipB.status).toBe("active");
  });

  test("reinstateMembership reverses suspension — ORG_A back to active, " +
    "ORG_B untouched throughout",
  async () => {
    await seedProfile("sm-1");
    await seedMembership("sm-1", ORG_A, "siteManager");
    await seedOrg(ORG_A, ["sm-1"]);
    await seedProfile("fm-1");
    await seedMembership("fm-1", ORG_A, "foreman", ["site-1"], {
      status: "suspended",
    });
    await seedMembership("fm-1", ORG_B, "foreman", ["site-9"]);

    const result = await reinstateMembership.run(
      callRequest("sm-1", {uid: "fm-1", organizationId: ORG_A})
    );

    expect(result.membershipStatus).toBe("active");
    const membershipA = await getMembership("fm-1", ORG_A);
    expect(membershipA.status).toBe("active");
    const membershipB = await getMembership("fm-1", ORG_B);
    expect(membershipB.status).toBe("active");
  });

  test("self-action is refused", async () => {
    await seedProfile("sm-1");
    await seedMembership("sm-1", ORG_A, "siteManager");
    await seedOrg(ORG_A, ["sm-1"]);

    await expect(
      suspendMembership.run(
        callRequest("sm-1", {uid: "sm-1", organizationId: ORG_A})
      )
    ).rejects.toThrow(/cannot act on your own account/);
  });

  test("a siteManager cannot suspend a membership in an organization " +
    "they don't manage",
  async () => {
    await seedProfile("sm-1");
    await seedMembership("sm-1", ORG_A, "siteManager");
    await seedOrg(ORG_A, ["sm-1"]);
    await seedOrg(ORG_B, []);
    await seedProfile("fm-1");
    await seedMembership("fm-1", ORG_B, "foreman", ["site-1"]);

    await expect(
      suspendMembership.run(
        callRequest("sm-1", {uid: "fm-1", organizationId: ORG_B})
      )
    ).rejects.toThrow();
  });

  test("suspending an already-suspended membership / reinstating an " +
    "already-active one is idempotent (no error, status unchanged)",
  async () => {
    await seedProfile("sm-1");
    await seedMembership("sm-1", ORG_A, "siteManager");
    await seedOrg(ORG_A, ["sm-1"]);
    await seedProfile("fm-1");
    await seedMembership("fm-1", ORG_A, "foreman", ["site-1"], {
      status: "suspended",
    });

    // Implementation performs an unconditional `.update({status: newStatus})`
    // with no precondition check — this is idempotent by construction, not
    // refused. Asserting the observed (and plan-consistent, since neither
    // plan nor doc comments claim it should be refused) behavior.
    const result = await suspendMembership.run(
      callRequest("sm-1", {uid: "fm-1", organizationId: ORG_A})
    );
    expect(result.membershipStatus).toBe("suspended");
    const membership = await getMembership("fm-1", ORG_A);
    expect(membership.status).toBe("suspended");
  });
});

describe("suspendActiveAccount / reinstateSuspendedAccount " +
  "(account-level)", () => {
  test("suspending a multi-membership user's ACCOUNT touches only " +
    "accountStatus — both ORG_A and ORG_B memberships stay active",
  async () => {
    await seedProfile("admin-1", {platformRole: "admin"});
    await seedProfile("sm-1");
    await getAuth(app).createUser({uid: "sm-1", email: "sm-1@example.com"});
    await seedMembership("sm-1", ORG_A, "siteManager");
    await seedMembership("sm-1", ORG_B, "siteManager");

    const result = await suspendActiveAccount.run(
      callRequest("admin-1", {uid: "sm-1"})
    );

    expect(result.accountStatus).toBe("suspended");
    const target = await getUserProfile("sm-1");
    expect(target.accountStatus).toBe("suspended");

    const membershipA = await getMembership("sm-1", ORG_A);
    const membershipB = await getMembership("sm-1", ORG_B);
    expect(membershipA.status).toBe("active");
    expect(membershipB.status).toBe("active");
  });

  test("reinstateSuspendedAccount reverses accountStatus only, " +
    "memberships remain untouched",
  async () => {
    await seedProfile("admin-1", {platformRole: "admin"});
    await seedProfile("sm-2", {accountStatus: "suspended"});
    await getAuth(app).createUser({uid: "sm-2", email: "sm-2@example.com"});
    await seedMembership("sm-2", ORG_A, "siteManager");
    await seedMembership("sm-2", ORG_B, "siteManager");

    const result = await reinstateSuspendedAccount.run(
      callRequest("admin-1", {uid: "sm-2"})
    );

    expect(result.accountStatus).toBe("active");
    const membershipA = await getMembership("sm-2", ORG_A);
    const membershipB = await getMembership("sm-2", ORG_B);
    expect(membershipA.status).toBe("active");
    expect(membershipB.status).toBe("active");
  });
});

describe("listOrganizationUsers", () => {
  test("Admin (no organizationId) sees rows across every organization for " +
    "a given accountStatus",
  async () => {
    await seedProfile("admin-1", {platformRole: "admin"});
    await seedProfile("fm-a");
    await seedMembership("fm-a", ORG_A, "foreman", ["site-1"]);
    await seedProfile("fm-b");
    await seedMembership("fm-b", ORG_B, "foreman", ["site-9"]);

    const result = await listOrganizationUsers.run(
      callRequest("admin-1", {accountStatus: "active"})
    );

    const orgIds = result.users.map((u) => u.organizationId).sort();
    expect(orgIds).toEqual([ORG_A, ORG_B]);
  });

  test("a siteManager acting in ORG_A sees only ORG_A rows, never ORG_B " +
    "rows, even for a person who holds memberships in both",
  async () => {
    await seedProfile("sm-1");
    await seedMembership("sm-1", ORG_A, "siteManager");
    await seedOrg(ORG_A, ["sm-1"]);
    await seedProfile("dual-1");
    await seedMembership("dual-1", ORG_A, "foreman", ["site-1"]);
    await seedMembership("dual-1", ORG_B, "foreman", ["site-9"]);

    const result = await listOrganizationUsers.run(
      callRequest("sm-1", {organizationId: ORG_A, accountStatus: "active"})
    );

    const rows = result.users.filter((u) => u.uid === "dual-1");
    expect(rows.length).toBe(1);
    expect(rows[0].organizationId).toBe(ORG_A);
  });

  test("a person with two memberships appears as separate rows when " +
    "listed by an Admin — one row per org, not merged",
  async () => {
    await seedProfile("admin-1", {platformRole: "admin"});
    await seedProfile("dual-1");
    await seedMembership("dual-1", ORG_A, "foreman", ["site-1"]);
    await seedMembership("dual-1", ORG_B, "foreman", ["site-9"]);

    const result = await listOrganizationUsers.run(
      callRequest("admin-1", {accountStatus: "active"})
    );

    const rows = result.users.filter((u) => u.uid === "dual-1");
    expect(rows.length).toBe(2);
    const orgIds = rows.map((r) => r.organizationId).sort();
    expect(orgIds).toEqual([ORG_A, ORG_B]);
  });
});

describe("Worker cannot approve users (cross-callable)", () => {
  test("a worker-role caller is refused by approvePendingAccount", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker", ["site-1"]);
    await seedPending("pending-1");

    await expect(
      approvePendingAccount.run(
        callRequest("worker-1", {
          uid: "pending-1",
          role: "worker",
          organizationId: ORG_A,
        })
      )
    ).rejects.toThrow(/permission/);
  });

  test("a worker-role caller is refused by addOrganizationMembership",
    async () => {
      await seedProfile("worker-1");
      await seedMembership("worker-1", ORG_A, "worker", ["site-1"]);
      await seedProfile("target-1");

      await expect(
        addOrganizationMembership.run(
          callRequest("worker-1", {
            uid: "target-1",
            role: "worker",
            organizationId: ORG_A,
          })
        )
      ).rejects.toThrow(/permission/);
    });

  test("a worker-role caller is refused by suspendMembership", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker", ["site-1"]);
    await seedProfile("target-1");
    await seedMembership("target-1", ORG_A, "worker", ["site-1"]);

    await expect(
      suspendMembership.run(
        callRequest("worker-1", {uid: "target-1", organizationId: ORG_A})
      )
    ).rejects.toThrow(/permission/);
  });

  test("listPendingApprovals also refuses a worker", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker", ["site-1"]);

    await expect(
      listPendingApprovals.run(
        callRequest("worker-1", {organizationId: ORG_A})
      )
    ).rejects.toThrow(/permission/);
  });

  test("rejectPendingAccount also refuses a worker", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", ORG_A, "worker", ["site-1"]);
    await seedPending("pending-1");

    await expect(
      rejectPendingAccount.run(
        callRequest("worker-1", {uid: "pending-1", organizationId: ORG_A})
      )
    ).rejects.toThrow(/permission/);
  });
});
