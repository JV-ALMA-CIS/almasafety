/**
 * Business-logic tests for `man_hours_callable.ts` — entering a site's
 * monthly man-hours and marking a month reported to the Safety Office.
 * Run against the Firestore emulator (`npm run test:callables`).
 */

const {initializeApp, getApps, deleteApp} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");

const PROJECT_ID = "jva-safety-rules-test";
const ORG = "org-alpha";

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
  fns = require("../lib/man_hours_callable");
});

afterAll(async () => {
  if (app) await deleteApp(app);
});

async function clearFirestore() {
  const collections = await db.listCollections();
  await Promise.all(collections.map((c) => db.recursiveDelete(c)));
}

async function seedPerson(uid, role, siteIds = []) {
  await db.doc(`users/${uid}`).set({uid, name: uid, accountStatus: "active"});
  await db.doc(`users/${uid}/memberships/${ORG}`).set({
    organizationId: ORG, role, siteIds, status: "active",
  });
}

function call(uid, data) {
  return {auth: {uid, token: {}}, data: {organizationId: ORG, ...data},
    rawRequest: {}};
}

const lastMonth = (() => {
  const d = new Date();
  d.setUTCDate(1);
  d.setUTCMonth(d.getUTCMonth() - 1);
  return d.toISOString().slice(0, 7);
})();

beforeEach(async () => {
  await clearFirestore();
  const sites = [["site-1", "Rosslyn Ridge"], ["site-2", "Embassy"]];
  for (const [id, name] of sites) {
    await db.doc(`organizations/${ORG}/sites/${id}`).set({
      organizationId: ORG, name,
    });
  }
  await seedPerson("eston", "siteManager");
  await seedPerson("fred", "foreman", ["site-1"]);
  await seedPerson("wanjiru", "worker", ["site-1"]);
});

test("a Foreman enters man-hours for their own site", async () => {
  await fns.saveManHours.run(call("fred", {
    siteId: "site-1", month: lastMonth, hours: 3520.25, workers: 22,
    notes: "Includes two Saturdays",
  }));
  const saved = (await db.doc(
    `organizations/${ORG}/man_hours/site-1_${lastMonth}`
  ).get()).data();
  expect(saved).toMatchObject({
    siteName: "Rosslyn Ridge", month: lastMonth, hours: 3520.3, workers: 22,
    notes: "Includes two Saturdays", enteredByName: "fred",
  });
});

test("a Foreman cannot enter another site's; a Worker cannot enter any",
  async () => {
    await expect(fns.saveManHours.run(call("fred", {
      siteId: "site-2", month: lastMonth, hours: 10, workers: 1,
    }))).rejects.toThrow(/permission/);
    await expect(fns.saveManHours.run(call("wanjiru", {
      siteId: "site-1", month: lastMonth, hours: 10, workers: 1,
    }))).rejects.toThrow(/permission/);
  });

test("bad numbers and future months are refused", async () => {
  for (const data of [
    {hours: -1, workers: 1},
    {hours: 10, workers: 1.5},
    {hours: "10", workers: 1},
  ]) {
    await expect(fns.saveManHours.run(call("eston", {
      siteId: "site-1", month: lastMonth, ...data,
    }))).rejects.toThrow(/must be a number/);
  }
  await expect(fns.saveManHours.run(call("eston", {
    siteId: "site-1", month: "2099-01", hours: 1, workers: 1,
  }))).rejects.toThrow(/future/);
});

test("a Site Manager marks the month reported, with the total", async () => {
  await expect(fns.markManHoursReported.run(call("eston", {month: lastMonth})))
    .rejects.toThrow(/Enter the man-hours/);
  await fns.saveManHours.run(call("eston", {
    siteId: "site-1", month: lastMonth, hours: 1000, workers: 10,
  }));
  await fns.saveManHours.run(call("eston", {
    siteId: "site-2", month: lastMonth, hours: 500, workers: 5,
  }));
  await expect(fns.markManHoursReported.run(call("fred", {month: lastMonth})))
    .rejects.toThrow(/permission/);
  const result = await fns.markManHoursReported.run(
    call("eston", {month: lastMonth})
  );
  expect(result).toMatchObject({sites: 2, totalHours: 1500});
  const report = (await db.doc(
    `organizations/${ORG}/man_hours_reports/${lastMonth}`
  ).get()).data();
  expect(report).toMatchObject({reportedBy: "eston", totalHours: 1500});
});

test("the suggestion counts worker-days present that month", async () => {
  const meeting = (id, date, siteId, present, absent) => [
    db.doc(`organizations/${ORG}/daily_safety_meetings/${id}`).set({
      organizationId: ORG, siteId, date, foremanId: "fred",
    }),
    ...present.map((w) => db.doc(
      `organizations/${ORG}/daily_safety_meetings/${id}/attendance/${w}`
    ).set({status: "present"})),
    ...absent.map((w) => db.doc(
      `organizations/${ORG}/daily_safety_meetings/${id}/attendance/${w}`
    ).set({status: "absent"})),
  ];
  await Promise.all([
    ...meeting("m1", `${lastMonth}-03`, "site-1", ["a", "b", "c"], ["d"]),
    ...meeting("m2", `${lastMonth}-04`, "site-1", ["a", "b"], []),
    ...meeting("m3", `${lastMonth}-04`, "site-2", ["x"], []),
    ...meeting("m4", "2020-01-04", "site-1", ["a"], []),
  ]);
  const result = await fns.getManHoursSuggestion.run(
    call("fred", {siteId: "site-1", month: lastMonth})
  );
  expect(result).toEqual({workerDays: 5, meetingDays: 2, meetings: 2});
  await expect(fns.getManHoursSuggestion.run(
    call("fred", {siteId: "site-2", month: lastMonth})
  )).rejects.toThrow(/permission/);
});
