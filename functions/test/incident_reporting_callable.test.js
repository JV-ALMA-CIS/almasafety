/**
 * Business-logic tests for `incident_reporting.ts` — the Safety Plan's
 * Section 8 reporting deadlines on an incident, and that an incident
 * cannot be closed until its reporting is done. Run against the Firestore
 * emulator via `npm run test:callables`.
 */

const {initializeApp, getApps, deleteApp} = require("firebase-admin/app");
const {getFirestore, Timestamp} = require("firebase-admin/firestore");

const PROJECT_ID = "jva-safety-rules-test";
const ORG_A = "org-alpha";
const HOUR = 60 * 60 * 1000;

let app;
let db;
let fns;
let incidents;

beforeAll(() => {
  process.env.GCLOUD_PROJECT = PROJECT_ID;
  if (!process.env.FIRESTORE_EMULATOR_HOST) {
    process.env.FIRESTORE_EMULATOR_HOST = "127.0.0.1:8080";
  }
  app = getApps()[0] ?? initializeApp({projectId: PROJECT_ID});
  db = getFirestore(app);
  fns = require("../lib/incident_reporting");
  incidents = require("../lib/incident_callable");
});

afterAll(async () => {
  if (app) await deleteApp(app);
});

async function clearFirestore() {
  const collections = await db.listCollections();
  await Promise.all(collections.map((c) => db.recursiveDelete(c)));
}

async function seedPerson(uid, role, name) {
  await db.doc(`users/${uid}`).set({
    uid, name, email: `${uid}@example.com`, accountStatus: "active",
  });
  await db.doc(`users/${uid}/memberships/${ORG_A}`).set({
    organizationId: ORG_A, role, siteIds: ["site-1"], status: "active",
  });
}

function call(uid, data) {
  return {auth: {uid, token: {}}, data: {organizationId: ORG_A, ...data},
    rawRequest: {}};
}

const occurred = new Date("2026-10-13T08:00:00Z");

async function get() {
  return (await db.doc(`organizations/${ORG_A}/incidents/inc-1`).get())
    .data();
}

function dueHoursAfter(step) {
  return (step.dueAt.toMillis() - occurred.getTime()) / HOUR;
}

beforeEach(async () => {
  await clearFirestore();
  await seedPerson("eston", "siteManager", "Eston Gikonyo");
  await seedPerson("foreman-a", "foreman", "Fred Foreman");
  await db.doc(`organizations/${ORG_A}/incidents/inc-1`).set({
    organizationId: ORG_A,
    siteId: "site-1",
    projectId: "project-1",
    reportedByUid: "foreman-a",
    type: "injury",
    description: "Fell from a ladder",
    occurredAt: Timestamp.fromDate(occurred),
    status: "underInvestigation",
    severity: "serious",
    correctiveActionIds: [],
  });
});

describe("reporting levels", () => {
  test("lost time: tell the COR now, 24-hour notice, Form 3394 in 5 days",
    async () => {
      await fns.setIncidentReportingLevel.run(
        call("eston", {incidentId: "inc-1", level: "lostTime"})
      );
      const incident = await get();
      expect(incident.reportingLevel).toBe("lostTime");
      expect(incident.reportingSteps.map((s) => [s.id, dueHoursAfter(s)]))
        .toEqual([["notifyCor", 0], ["notify24h", 24], ["form3394", 120]]);
      expect(incident.reportingSteps.every((s) => s.doneAt === null))
        .toBe(true);
    });

  test("immediate: phone at once and seal off the site", async () => {
    await fns.setIncidentReportingLevel.run(
      call("eston", {incidentId: "inc-1", level: "immediate"})
    );
    expect((await get()).reportingSteps.map((s) => s.id)).toEqual([
      "notifyCor", "immediatePhone", "sealSite", "form3394",
    ]);
  });

  test("changing the level keeps steps already done", async () => {
    await fns.setIncidentReportingLevel.run(
      call("eston", {incidentId: "inc-1", level: "medical"})
    );
    await fns.recordIncidentReportingStep.run(call("eston", {
      incidentId: "inc-1", stepId: "notifyCor", note: "Called J. Smith",
    }));
    await fns.setIncidentReportingLevel.run(
      call("eston", {incidentId: "inc-1", level: "lostTime"})
    );
    const steps = (await get()).reportingSteps;
    expect(steps.find((s) => s.id === "notifyCor")).toMatchObject({
      doneByUid: "eston", doneByName: "Eston Gikonyo", note: "Called J. Smith",
    });
    expect(steps.find((s) => s.id === "form3394").doneAt).toBeNull();
  });

  test("only a Site Manager/Admin sets it; unknown levels are refused",
    async () => {
      await expect(fns.setIncidentReportingLevel.run(
        call("foreman-a", {incidentId: "inc-1", level: "medical"})
      )).rejects.toThrow();
      await expect(fns.setIncidentReportingLevel.run(
        call("eston", {incidentId: "inc-1", level: "whatever"})
      )).rejects.toThrow(/level must be/);
    });
});

describe("ticking steps off", () => {
  beforeEach(async () => {
    await fns.setIncidentReportingLevel.run(
      call("eston", {incidentId: "inc-1", level: "minorDamage"})
    );
  });

  test("a step is ticked done, and can be un-ticked", async () => {
    await fns.recordIncidentReportingStep.run(
      call("eston", {incidentId: "inc-1", stepId: "email24h"})
    );
    let step = (await get()).reportingSteps.find((s) => s.id === "email24h");
    expect(step.doneAt).not.toBeNull();

    await fns.recordIncidentReportingStep.run(
      call("eston", {incidentId: "inc-1", stepId: "email24h", done: false})
    );
    step = (await get()).reportingSteps.find((s) => s.id === "email24h");
    expect(step.doneAt).toBeNull();
    expect(step.doneByUid).toBeNull();
  });

  test("a step the level does not require is refused", async () => {
    await expect(fns.recordIncidentReportingStep.run(
      call("eston", {incidentId: "inc-1", stepId: "form3394"})
    )).rejects.toThrow(/not required/);
  });
});

describe("closing", () => {
  function close() {
    return incidents.closeIncident.run(call("eston", {
      incidentId: "inc-1", rootCause: "Ladder not tied off",
    }));
  }

  test("refused without a reporting level", async () => {
    await expect(close()).rejects.toThrow(/reporting level/);
  });

  test("refused until every reporting step is done", async () => {
    await fns.setIncidentReportingLevel.run(
      call("eston", {incidentId: "inc-1", level: "minorDamage"})
    );
    await fns.recordIncidentReportingStep.run(
      call("eston", {incidentId: "inc-1", stepId: "notifyCor"})
    );
    await expect(close()).rejects.toThrow(/Documented by email/);

    await fns.recordIncidentReportingStep.run(
      call("eston", {incidentId: "inc-1", stepId: "email24h"})
    );
    expect((await close()).status).toBe("closed");

    // A closed incident's reporting cannot be changed.
    await expect(fns.setIncidentReportingLevel.run(
      call("eston", {incidentId: "inc-1", level: "lostTime"})
    )).rejects.toThrow(/closed/);
  });
});
