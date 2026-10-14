/**
 * Business-logic tests for `organization_callable.ts` — `createOrganization`
 * (siteManager or admin only; creates the caller's own membership every
 * time, not just the first) and a smoke test of `updateOrganization`'s
 * siteManager scope restriction.
 *
 * Mirrors `hazard_callable.test.js`'s shape: invokes each callable's own
 * exported handler via `.run(request)` against a running Firestore emulator.
 *
 * Requires the Firestore emulator — see `npm run test:callables`.
 */

const {initializeApp, getApps, deleteApp} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");

const PROJECT_ID = "jva-safety-rules-test";

let app;
let db;
let createOrganization;
let updateOrganization;

beforeAll(() => {
  process.env.GCLOUD_PROJECT = PROJECT_ID;
  if (!process.env.FIRESTORE_EMULATOR_HOST) {
    process.env.FIRESTORE_EMULATOR_HOST = "127.0.0.1:8080";
  }

  app = getApps()[0] ?? initializeApp({projectId: PROJECT_ID});
  db = getFirestore(app);

  ({createOrganization, updateOrganization} =
    require("../lib/organization_callable"));
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

async function seedProfile(uid, overrides = {}) {
  await db.doc(`users/${uid}`).set(profile(uid, overrides));
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

function callRequest(uid, data) {
  return {
    auth: {uid, token: {}},
    data,
    rawRequest: {},
  };
}

async function getOrg(id) {
  const snapshot = await db.doc(`organizations/${id}`).get();
  return snapshot.data();
}

async function getMembership(uid, organizationId) {
  const snapshot = await db.doc(
    `users/${uid}/memberships/${organizationId}`
  ).get();
  return snapshot.data();
}

async function listMemberships(uid) {
  const docs = await db.doc(`users/${uid}`).collection("memberships").get();
  return docs.docs.map((d) => d.data());
}

beforeEach(async () => {
  await clearFirestore();
});

describe("createOrganization", () => {
  test("a siteManager with NO existing memberships creates an org, is " +
    "added to managedBy, and gets a siteManager membership in it",
  async () => {
    await seedProfile("sm-1", {platformRole: "siteManager"});

    const result = await createOrganization.run(
      callRequest("sm-1", {name: "Acme Co", code: "ACME"})
    );

    expect(result.id).toBeTruthy();
    const org = await getOrg(result.id);
    expect(org.managedBy).toEqual(["sm-1"]);

    const membership = await getMembership("sm-1", result.id);
    expect(membership.role).toBe("siteManager");
    expect(membership.status).toBe("active");
    expect(membership.organizationId).toBe(result.id);
  });

  test("the SAME siteManager calling it a second time creates a second, " +
    "different organization, and holds independent memberships in both",
  async () => {
    await seedProfile("sm-1", {platformRole: "siteManager"});

    const first = await createOrganization.run(
      callRequest("sm-1", {name: "Org One", code: "ONE"})
    );
    const second = await createOrganization.run(
      callRequest("sm-1", {name: "Org Two", code: "TWO"})
    );

    expect(first.id).not.toBe(second.id);

    const membershipFirst = await getMembership("sm-1", first.id);
    const membershipSecond = await getMembership("sm-1", second.id);
    expect(membershipFirst.status).toBe("active");
    expect(membershipFirst.role).toBe("siteManager");
    expect(membershipSecond.status).toBe("active");
    expect(membershipSecond.role).toBe("siteManager");

    const allMemberships = await listMemberships("sm-1");
    expect(allMemberships.length).toBe(2);
  });

  test("called by admin succeeds but creates no membership for the " +
    "admin caller",
  async () => {
    await seedProfile("admin-1", {platformRole: "admin"});

    const result = await createOrganization.run(
      callRequest("admin-1", {name: "Admin Org", code: "ADM"})
    );

    const org = await getOrg(result.id);
    expect(org.managedBy).toEqual([]);

    const membership = await getMembership("admin-1", result.id);
    expect(membership).toBeUndefined();
  });

  test("called by a foreman is refused", async () => {
    await seedProfile("fm-1");
    await seedMembership("fm-1", "org-x", "foreman", ["site-1"]);

    await expect(
      createOrganization.run(
        callRequest("fm-1", {name: "Nope", code: "NOPE"})
      )
    ).rejects.toThrow();
  });

  test("called by a worker is refused", async () => {
    await seedProfile("worker-1");
    await seedMembership("worker-1", "org-x", "worker", ["site-1"]);

    await expect(
      createOrganization.run(
        callRequest("worker-1", {name: "Nope", code: "NOPE"})
      )
    ).rejects.toThrow();
  });

  test("called by an unauthenticated/no-profile caller is refused",
    async () => {
      await expect(
        createOrganization.run(
          callRequest("ghost-1", {name: "Nope", code: "NOPE"})
        )
      ).rejects.toThrow();
    });
});

describe("updateOrganization (smoke test)", () => {
  test("a siteManager can update name/code/status on an org they manage",
    async () => {
      await seedProfile("sm-1", {platformRole: "siteManager"});
      const created = await createOrganization.run(
        callRequest("sm-1", {name: "Original", code: "ORIG"})
      );

      await updateOrganization.run(
        callRequest("sm-1", {
          id: created.id,
          name: "Renamed",
          code: "RENAMED",
        })
      );

      const org = await getOrg(created.id);
      expect(org.name).toBe("Renamed");
      expect(org.code).toBe("RENAMED");
    });

  test("a siteManager cannot modify managedBy on an org they manage",
    async () => {
      await seedProfile("sm-1", {platformRole: "siteManager"});
      const created = await createOrganization.run(
        callRequest("sm-1", {name: "Original", code: "ORIG"})
      );

      await expect(
        updateOrganization.run(
          callRequest("sm-1", {
            id: created.id,
            managedBy: ["sm-1", "intruder-1"],
          })
        )
      ).rejects.toThrow();

      const org = await getOrg(created.id);
      expect(org.managedBy).toEqual(["sm-1"]);
    });

  test("admin can modify managedBy on any organization", async () => {
    await seedProfile("sm-1", {platformRole: "siteManager"});
    await seedProfile("admin-1", {platformRole: "admin"});
    const created = await createOrganization.run(
      callRequest("sm-1", {name: "Original", code: "ORIG"})
    );

    await updateOrganization.run(
      callRequest("admin-1", {
        id: created.id,
        managedBy: ["sm-1", "second-manager"],
      })
    );

    const org = await getOrg(created.id);
    expect(org.managedBy).toEqual(["sm-1", "second-manager"]);
  });
});

describe("updateProject: finishing a project", () => {
  const ORG = "org-alpha";
  let updateProject;

  beforeAll(() => {
    ({updateProject} = require("../lib/organization_callable"));
  });

  async function siteStatus(id) {
    return (await db.doc(`organizations/${ORG}/sites/${id}`).get())
      .data().status;
  }

  beforeEach(async () => {
    await seedProfile("admin-1", {platformRole: "admin"});
    await db.doc(`organizations/${ORG}`).set({name: "JV ALMA"});
    for (const project of ["rosslyn", "embassy"]) {
      await db.doc(`organizations/${ORG}/projects/${project}`).set({
        organizationId: ORG, name: project, code: project, status: "active",
      });
    }
    for (const [id, projectId] of [
      ["rosslyn-1", "rosslyn"],
      ["rosslyn-2", "rosslyn"],
      ["embassy-1", "embassy"],
    ]) {
      await db.doc(`organizations/${ORG}/sites/${id}`).set({
        organizationId: ORG, projectId, name: id, code: id, status: "active",
      });
    }
  });

  function update(data) {
    return updateProject.run(
      callRequest("admin-1", {organizationId: ORG, id: "rosslyn", ...data})
    );
  }

  test("switching a project off switches off its sites only", async () => {
    await update({status: "inactive"});
    expect(await siteStatus("rosslyn-1")).toBe("inactive");
    expect(await siteStatus("rosslyn-2")).toBe("inactive");
    expect(await siteStatus("embassy-1")).toBe("active");
  });

  test("switching it back on does not reopen its sites", async () => {
    await update({status: "inactive"});
    await update({status: "active"});
    expect(await siteStatus("rosslyn-1")).toBe("inactive");
  });

  test("other edits leave the sites alone", async () => {
    await update({name: "Rosslyn Ridge"});
    expect(await siteStatus("rosslyn-1")).toBe("active");
  });
});

describe("updateSiteEmergencyInfo", () => {
  const ORG = "org-alpha";
  let updateSiteEmergencyInfo;

  beforeAll(() => {
    ({updateSiteEmergencyInfo} = require("../lib/site_emergency_callable"));
  });

  beforeEach(async () => {
    await seedProfile("sm-1", {platformRole: "siteManager", name: "Eston"});
    await seedMembership("sm-1", ORG, "siteManager");
    await seedProfile("fm-1");
    await seedMembership("fm-1", ORG, "foreman", ["site-1"]);
    await db.doc(`organizations/${ORG}`).set({name: "JV ALMA"});
    await db.doc(`organizations/${ORG}/sites/site-1`).set({
      organizationId: ORG, projectId: "p", name: "Embassy", code: "EMB",
      status: "active",
    });
  });

  function save(uid, emergency) {
    return updateSiteEmergencyInfo.run(callRequest(uid, {
      organizationId: ORG, siteId: "site-1", emergency,
    }));
  }

  test("a Site Manager saves the site's emergency contacts", async () => {
    await save("sm-1", {
      clinicName: " Nairobi Hospital ",
      clinicPhones: ["+254 700 000000", " "],
      ambulancePhone: "999",
      otherNumbers: [
        {label: "Fire", number: "999"},
        {label: "", number: "+254 711 111111"},
        {label: "Empty", number: ""},
      ],
      assemblyPoint: "Main gate",
      firstAiders: ["Eston K Gikonyo"],
    });
    const site = (await db.doc(`organizations/${ORG}/sites/site-1`).get())
      .data();
    expect(site.emergency).toMatchObject({
      clinicName: "Nairobi Hospital",
      clinicPhones: ["+254 700 000000"],
      ambulancePhone: "999",
      otherNumbers: [
        {label: "Fire", number: "999"},
        {label: "Emergency", number: "+254 711 111111"},
      ],
      assemblyPoint: "Main gate",
      firstAiders: ["Eston K Gikonyo"],
      clinicAddress: null,
      updatedBy: "sm-1",
      updatedByName: "Eston",
    });
  });

  test("a Foreman cannot change them", async () => {
    await expect(save("fm-1", {ambulancePhone: "999"})).rejects.toThrow();
  });

  test("an unknown site is refused", async () => {
    await expect(updateSiteEmergencyInfo.run(callRequest("sm-1", {
      organizationId: ORG, siteId: "nope", emergency: {},
    }))).rejects.toThrow(/no longer exists/);
  });
});
