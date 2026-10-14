/**
 * Business-logic tests for `notification_triggers.ts` — who is notified of
 * what, never the person who caused it, and the daily reminders sent at
 * most once a day. The handlers are called directly, against the Firestore
 * emulator (`npm run test:callables`).
 */

const {initializeApp, getApps, deleteApp} = require("firebase-admin/app");
const {getFirestore, Timestamp} = require("firebase-admin/firestore");

const PROJECT_ID = "jva-safety-rules-test";
const ORG = "org-alpha";
const DAY = 24 * 60 * 60 * 1000;

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
  fns = require("../lib/notification_triggers");
});

afterAll(async () => {
  if (app) await deleteApp(app);
});

async function clearFirestore() {
  const collections = await db.listCollections();
  await Promise.all(collections.map((c) => db.recursiveDelete(c)));
}

async function seedMember(uid, role, siteIds = [], status = "active") {
  await db.doc(`users/${uid}`).set({uid, name: uid, accountStatus: "active"});
  await db.doc(`users/${uid}/memberships/${ORG}`).set({
    organizationId: ORG, role, siteIds, status,
  });
}

async function inbox(uid) {
  const snapshot = await db.collection(`organizations/${ORG}/notifications`)
    .where("recipientUid", "==", uid).get();
  return snapshot.docs.map((d) => d.data());
}

async function allRecipients() {
  const snapshot = await db.collection(`organizations/${ORG}/notifications`)
    .get();
  return snapshot.docs.map((d) => d.data().recipientUid).sort();
}

beforeEach(async () => {
  await clearFirestore();
  await db.doc(`organizations/${ORG}/sites/site-1`).set({
    organizationId: ORG, name: "Italian Embassy",
  });
  await seedMember("eston", "siteManager");
  await seedMember("admin-1", "admin");
  await seedMember("old-manager", "siteManager", [], "suspended");
  await seedMember("fred", "foreman", ["site-1"]);
  await seedMember("other-foreman", "foreman", ["site-2"]);
  await seedMember("wanjiru", "worker", ["site-1"]);
});

describe("corrective actions", () => {
  const action = {
    title: "Fit guardrail",
    assignedTo: "fred",
    assignedBy: "eston",
    assignedToName: "Fred",
    status: "open",
    dueDate: Timestamp.fromDate(new Date("2026-10-16T09:00:00Z")),
  };

  test("assigned → the assignee", async () => {
    await fns.correctiveActionChanged(ORG, "ca-1", undefined, action);
    const [n] = await inbox("fred");
    expect(n).toMatchObject({
      type: "correctiveAction",
      title: "New corrective action for you",
      relatedEntityType: "correctiveAction",
      relatedEntityId: "ca-1",
      isRead: false,
    });
    expect(n.message).toMatch(/Fit guardrail — due Fri 16 Oct/);
    expect(await allRecipients()).toEqual(["fred"]);
  });

  test("assigning yourself sends nothing", async () => {
    await fns.correctiveActionChanged(ORG, "ca-1", undefined,
      {...action, assignedTo: "eston"});
    expect(await allRecipients()).toEqual([]);
  });

  test("submitted → whoever assigned it; approved / sent back → assignee",
    async () => {
      await fns.correctiveActionChanged(ORG, "ca-1", action,
        {...action, status: "submittedForReview"});
      expect((await inbox("eston"))[0].title)
        .toBe("Evidence submitted for your review");

      await fns.correctiveActionChanged(ORG, "ca-1",
        {...action, status: "submittedForReview"},
        {...action, status: "open", reviewFeedback: "Photo is blurry"});
      expect((await inbox("fred"))[0].message).toMatch(/Photo is blurry/);

      await fns.correctiveActionChanged(ORG, "ca-1",
        {...action, status: "submittedForReview"},
        {...action, status: "completed", completedBy: "eston"});
      expect((await inbox("fred")).map((n) => n.title))
        .toContain("Corrective action approved");
    });

  test("other edits send nothing", async () => {
    await fns.correctiveActionChanged(ORG, "ca-1", action,
      {...action, title: "Renamed"});
    expect(await allRecipients()).toEqual([]);
  });
});

describe("reports", () => {
  test("a hazard → active managers and the site's Foremen, not the reporter",
    async () => {
      await fns.hazardReported(ORG, "h-1", {
        siteId: "site-1", reportedByUid: "wanjiru", kind: "hazard",
        description: "Loose scaffold board",
      });
      expect(await allRecipients()).toEqual(["admin-1", "eston", "fred"]);
      expect((await inbox("fred"))[0].title)
        .toBe("Hazard reported at Italian Embassy");
    });

  test("a Foreman reporting is not notified of their own report",
    async () => {
      await fns.hazardReported(ORG, "h-1", {
        siteId: "site-1", reportedByUid: "fred", kind: "nearMiss",
        description: "Hammer fell",
      });
      expect(await allRecipients()).toEqual(["admin-1", "eston"]);
      expect((await inbox("eston"))[0].title).toMatch(/Near-miss/);
    });

  test("an incident asks for the COR and the reporting level", async () => {
    await fns.incidentReported(ORG, "i-1", {
      siteId: "site-1", reportedByUid: "wanjiru",
      description: "Fell from a ladder",
    });
    const [n] = await inbox("eston");
    expect(n.title).toBe("INCIDENT reported at Italian Embassy");
    expect(n.message).toMatch(/reporting level/);
    expect(n.type).toBe("incident");
  });
});

describe("inspections and AHAs", () => {
  test("submitted inspection → managers but not the inspector", async () => {
    await fns.inspectionChanged(ORG, "ins-1",
      {status: "inProgress"},
      {status: "submitted", inspectorUid: "eston", inspectorName: "Eston",
        templateName: "Daily site inspection", siteName: "Embassy",
        notOkCount: 2});
    expect(await allRecipients()).toEqual(["admin-1"]);
    expect((await inbox("admin-1"))[0].message).toMatch(/2 deficiencies/);
  });

  test("a new AHA draft → the other managers", async () => {
    await fns.riskAssessmentCreated(ORG, "a-1", {
      status: "draft", preparedByUid: "eston", featureOfWork: "Painting",
    });
    expect(await allRecipients()).toEqual(["admin-1"]);
  });
});

describe("daily reminders", () => {
  const now = new Date("2026-10-15T03:00:00Z");

  beforeEach(async () => {
    const add = (id, due, status = "open") =>
      db.doc(`organizations/${ORG}/corrective_actions/${id}`).set({
        title: id, assignedTo: "fred", status,
        dueDate: Timestamp.fromDate(new Date(now.getTime() + due)),
      });
    await add("due-tomorrow", DAY);
    await add("overdue", -2 * DAY);
    await add("next-week", 7 * DAY);
    await add("done", -DAY, "completed");
    await db.doc(`organizations/${ORG}/incidents/i-1`).set({
      status: "underInvestigation", description: "Fell",
      reportingLevel: "lostTime",
      reportingSteps: [{
        id: "notify24h", label: "24-hour notification",
        dueAt: Timestamp.fromDate(new Date(now.getTime() - DAY)), doneAt: null,
      }],
    });
  });

  test("due soon / overdue actions and overdue reporting, once a day",
    async () => {
      await fns.remindOrganization(ORG, now);
      const fred = (await inbox("fred")).map((n) => n.title).sort();
      expect(fred).toEqual([
        "Corrective action OVERDUE", "Corrective action due soon",
      ]);
      expect((await inbox("eston")).map((n) => n.title))
        .toEqual(["Incident reporting OVERDUE"]);

      // Running again the same day sends nothing new.
      const before = (await allRecipients()).length;
      await fns.remindOrganization(ORG, now);
      expect((await allRecipients()).length).toBe(before);
    });
});
