/**
 * PUSH NOTIFICATIONS to people's phones and browsers (Firebase Cloud
 * Messaging) — the same notifications as the in-app inbox, shown by the
 * device even when the app is closed.
 *
 * Each device that allows notifications registers its token
 * (`registerPushToken`) under `users/{uid}/push_tokens/{id}`; signing out
 * removes it (`unregisterPushToken`). Both act only on the caller's own
 * account — except that a device belongs to ONE person: registering it
 * removes it from anyone else's account, so a shared phone/tablet/computer
 * never gets the previous person's notifications, even when their sign-out
 * could not reach the server. `firestore.rules` has no grant for
 * `push_tokens`, so clients can neither read nor write them directly.
 *
 * `sendPush` is called by `createNotification` after it writes the inbox
 * notification. It never throws (a push problem must not stop the inbox
 * notification or the action behind it) and removes tokens the messaging
 * service reports as no longer valid (app uninstalled, notifications
 * blocked).
 */

import {createHash} from "crypto";
import {FieldValue, getFirestore} from "firebase-admin/firestore";
import {getMessaging} from "firebase-admin/messaging";
import * as logger from "firebase-functions/logger";
import {HttpsError, onCall} from "firebase-functions/v2/https";

/**
 * The document id for [token] — a hash, so a token never appears in a
 * document path.
 *
 * @param {string} token the device token.
 * @return {string} the id.
 */
function tokenId(token: string): string {
  return createHash("sha256").update(token).digest("hex").slice(0, 40);
}

/**
 * The token argument, validated.
 *
 * @param {unknown} data the request data.
 * @return {string} the token.
 */
function requireToken(data: unknown): string {
  const token = (data as Record<string, unknown> | undefined)?.token;
  if (typeof token !== "string" || !token.trim() || token.length > 4096) {
    throw new HttpsError("invalid-argument", "token is required.");
  }
  return token.trim();
}

/** Registers (or refreshes) this device for the caller's notifications. */
export const registerPushToken = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError("unauthenticated", "Please sign in again.");
  }
  const token = requireToken(request.data);
  const rawPlatform = (request.data ?? {}).platform;
  const platform =
    typeof rawPlatform === "string" ? rawPlatform.slice(0, 20) : "unknown";
  const db = getFirestore();
  const mine = db.doc(`users/${uid}/push_tokens/${tokenId(token)}`);
  // The same device on anyone else's account (shared device; a sign-out
  // without signal) — it is now the caller's alone.
  const elsewhere = await db.collectionGroup("push_tokens")
    .where("token", "==", token)
    .get();
  const batch = db.batch();
  for (const doc of elsewhere.docs) {
    if (doc.ref.path !== mine.path) batch.delete(doc.ref);
  }
  batch.set(mine, {
    token,
    platform,
    lastSeenAt: FieldValue.serverTimestamp(),
  }, {merge: true});
  await batch.commit();
  return {registered: true};
});

/** Removes this device (e.g. on sign-out) from the caller's account. */
export const unregisterPushToken = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError("unauthenticated", "Please sign in again.");
  }
  const token = requireToken(request.data);
  await getFirestore()
    .doc(`users/${uid}/push_tokens/${tokenId(token)}`)
    .delete();
  return {removed: true};
});

/** The page (hash route) a notification opens, by what it relates to. */
const ROUTES: Record<string, string> = {
  correctiveAction: "/corrective-actions",
  hazard: "/hazards",
  incident: "/incidents",
  inspection: "/inspections",
  riskAssessment: "/risk-assessments",
  dailySafetyMeeting: "/daily-safety-meetings",
  safetyAlert: "/safety-alerts",
};

/** Error codes meaning a token will never work again. */
const DEAD_TOKEN_CODES = new Set([
  "messaging/registration-token-not-registered",
  "messaging/invalid-registration-token",
  "messaging/invalid-argument",
]);

/**
 * Pushes a notification to every device [recipientUid] has registered.
 * Never throws.
 *
 * @param {object} params the notification.
 * @return {Promise<number>} how many devices accepted it.
 */
export async function sendPush(params: {
  recipientUid: string;
  title: string;
  message: string;
  relatedEntityType?: string | null;
  /** Stays on a computer's screen until clicked (incidents, serious
   * alerts) instead of fading away. Never louder — same sound as any other.
   */
  urgent?: boolean;
}): Promise<number> {
  try {
    const db = getFirestore();
    const tokens = await db
      .collection(`users/${params.recipientUid}/push_tokens`)
      .get();
    if (tokens.empty) return 0;

    const route = (params.relatedEntityType &&
      ROUTES[params.relatedEntityType]) || "/notifications";
    const project = process.env.GCLOUD_PROJECT ?? "jva-safety";
    const link = `https://${project}.web.app/#${route}`;

    const docs = tokens.docs;
    const response = await getMessaging().sendEachForMulticast({
      tokens: docs.map((d) => d.data().token as string),
      notification: {title: params.title, body: params.message},
      data: {route, urgent: params.urgent ? "1" : "0"},
      webpush: {
        // Clicks are handled in web/firebase-messaging-sw.js (opens the
        // page on whichever address the app is used from); this link is
        // only the fallback.
        fcmOptions: {link},
        notification: {
          icon: "/icons/Icon-192.png",
          badge: "/favicon.png",
          ...(params.urgent ? {requireInteraction: true} : {}),
        },
      },
      // The "Safety alerts" channel (android/.../MainActivity.kt): pops up
      // as a banner with the phone's own default sound — nothing custom.
      android: {
        priority: "high",
        notification: {
          channelId: "safety_alerts",
          icon: "ic_notification",
          color: "#0B4F6C",
        },
      },
    });

    const dead = response.responses
      .map((r, i) => (!r.success && DEAD_TOKEN_CODES.has(r.error?.code ?? "")) ?
        docs[i].ref :
        null)
      .filter((ref) => ref !== null);
    await Promise.all(dead.map((ref) => ref.delete()));
    return response.successCount;
  } catch (e) {
    logger.error("Push notification failed", e);
    return 0;
  }
}
