/**
 * Business-logic tests for `push_callable.ts` — registering this device's
 * push token on the caller's own account, removing it, and a push failure
 * never stopping the in-app notification. Run against the Firestore
 * emulator (`npm run test:callables`); no real messages are sent.
 */

const {initializeApp, getApps, deleteApp} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");

const PROJECT_ID = "jva-safety-rules-test";

let app;
let db;
let fns;
let notifications;

beforeAll(() => {
  process.env.GCLOUD_PROJECT = PROJECT_ID;
  if (!process.env.FIRESTORE_EMULATOR_HOST) {
    process.env.FIRESTORE_EMULATOR_HOST = "127.0.0.1:8080";
  }
  app = getApps()[0] ?? initializeApp({projectId: PROJECT_ID});
  db = getFirestore(app);
  fns = require("../lib/push_callable");
  notifications = require("../lib/notification_callable");
});

afterAll(async () => {
  if (app) await deleteApp(app);
});

async function clearFirestore() {
  const collections = await db.listCollections();
  await Promise.all(collections.map((c) => db.recursiveDelete(c)));
}

function call(uid, data) {
  return {auth: uid ? {uid, token: {}} : undefined, data, rawRequest: {}};
}

async function tokens(uid) {
  const snapshot = await db.collection(`users/${uid}/push_tokens`).get();
  return snapshot.docs.map((d) => d.data());
}

beforeEach(clearFirestore);

test("a device registers on the caller's own account, once", async () => {
  await fns.registerPushToken.run(
    call("fred", {token: "token-abc", platform: "web"})
  );
  await fns.registerPushToken.run(
    call("fred", {token: "token-abc", platform: "web"})
  );
  const saved = await tokens("fred");
  expect(saved).toHaveLength(1);
  expect(saved[0]).toMatchObject({token: "token-abc", platform: "web"});
});

test("signing out removes the device", async () => {
  await fns.registerPushToken.run(call("fred", {token: "token-abc"}));
  await fns.unregisterPushToken.run(call("fred", {token: "token-abc"}));
  expect(await tokens("fred")).toEqual([]);
});

test("signed-out callers and empty tokens are refused", async () => {
  await expect(fns.registerPushToken.run(call(null, {token: "t"})))
    .rejects.toThrow(/sign in/);
  await expect(fns.registerPushToken.run(call("fred", {token: " "})))
    .rejects.toThrow(/token/);
});

test("no devices: nothing is pushed", async () => {
  expect(await fns.sendPush({
    recipientUid: "nobody", title: "t", message: "m",
  })).toBe(0);
});

test("a push that cannot be sent never stops the inbox notification",
  async () => {
    await fns.registerPushToken.run(call("fred", {token: "not-a-real-token"}));
    const id = await notifications.createNotification({
      organizationId: "org",
      recipientUid: "fred",
      type: "incident",
      title: "INCIDENT reported",
      message: "Fell from a ladder",
      relatedEntityType: "incident",
      relatedEntityId: "i-1",
    });
    const saved = (await db.doc(`organizations/org/notifications/${id}`)
      .get()).data();
    expect(saved).toMatchObject({recipientUid: "fred", isRead: false});
  });
