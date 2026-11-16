/**
 * Permanently deleting a Safety Learning item — only when it is
 * demonstrably unused — and recovering a deletion that could not finish.
 *
 * What references a learning item (`organizations/{org}/safety_learning/
 * {id}`) in this data model:
 *
 * - `worker_learning_records` (`learningId`) — a learner's formal progress,
 *   completion and recorded quiz result. TRAINING EVIDENCE: any record at all
 *   refuses the deletion; the item is deactivated instead, which keeps it.
 * - `safety_requirements.requiredLearningIds` — ACTIVE or inactive: deleting
 *   would leave a requirement pointing at nothing, so any listing refuses it
 *   until that requirement is edited.
 * - Its own `knowledge_check_questions` subcollection — content the item
 *   owns; deleted with it.
 * - An uploaded file at `organizations/{org}/safety_learning/...` — content
 *   the item owns; deleted with it when no other item uses the same file.
 * - `daily_learning_plans` — a per-day cache rebuilt from requirements,
 *   which already discards ids that are no longer active items
 *   (`daily_learning_plan.ts`'s `stillValid`): not evidence, not a blocker.
 *
 * Practice quiz attempts are never stored, so there is nothing else.
 *
 * NOT ATOMIC ACROSS FIRESTORE AND STORAGE — they are separate systems, so
 * the deletion runs in recoverable steps, with the item document itself as
 * the durable marker (no extra collection):
 *
 * 1. MARK (one transaction): the dependency checks pass, and the item is
 *    set `inactive` with `deletion: {pending: true, ...}`. From here no new
 *    dependency can form: requirements refuse to newly list an inactive item
 *    (`requireLearningItemsExist`), learning records exist only for ACTIVE
 *    required items, and edits/quiz changes refuse an item being deleted.
 * 2. RE-CHECK, then the FILE: dependencies are checked again (a requirement
 *    edit that read the item just before step 1 would show up here — the
 *    item is then restored and nothing is deleted); then the uploaded file
 *    is deleted unless another item uses it.
 * 3. DOCUMENTS (one transaction): checked a last time, then the quiz
 *    questions and the item are deleted.
 *
 * If step 2 or 3 fails, the item stays hidden (inactive) with its marker.
 * Calling `deleteSafetyLearning` again finishes it, and
 * `finishPendingLearningDeletions` retries every marked item on a schedule.
 * Nothing ever touches records, requirements or another organization.
 */
import {FieldValue, getFirestore} from "firebase-admin/firestore";
import {getStorage} from "firebase-admin/storage";
import * as logger from "firebase-functions/logger";
import {HttpsError, onCall} from "firebase-functions/v2/https";
import {onSchedule} from "firebase-functions/v2/scheduler";
import {requireLibraryAuthor} from "./safety_learning_callable";

/**
 * Storage operations, swappable in tests to simulate a Storage failure.
 */
export const storageOps = {
  deleteObject: async (path: string): Promise<void> => {
    // Manual testing of the recovery path: only in the Functions EMULATOR
    // (which alone sets FUNCTIONS_EMULATOR) and only when opted in through
    // functions/.env.local, which deploys never include (`*.local`).
    if (
      process.env.FUNCTIONS_EMULATOR === "true" &&
      process.env.JVA_SIMULATE_STORAGE_FAILURE === "true"
    ) {
      throw new Error("Simulated Storage failure (emulator only).");
    }
    await getStorage().bucket().file(path).delete({ignoreNotFound: true});
  },
  bucketName: (): string => getStorage().bucket().name,
};

/**
 * The Storage object path of an uploaded library file, from its download
 * URL — only when it is in THIS organization's library folder of the
 * default bucket. Anything else (YouTube, Vimeo, another site, another
 * organization) is null and never touched.
 *
 * @param {string} reference the item's `contentReference`.
 * @param {string} organizationId the item's organization.
 * @param {string} bucketName the default bucket.
 * @return {string|null} the object path, or null.
 */
export function ownedLibraryFile(
  reference: unknown,
  organizationId: string,
  bucketName: string
): string | null {
  if (typeof reference !== "string") return null;
  const match = /\/v0\/b\/([^/]+)\/o\/([^?#]+)/.exec(reference);
  if (!match || match[1] !== bucketName) return null;
  let path: string;
  try {
    path = decodeURIComponent(match[2]);
  } catch {
    return null;
  }
  const prefix = `organizations/${organizationId}/safety_learning/`;
  if (!path.startsWith(prefix) || path.includes("..")) return null;
  return path;
}

/** Runs a query — inside a transaction, or directly. */
interface Reader {
  get(query: FirebaseFirestore.Query): Promise<FirebaseFirestore.QuerySnapshot>;
}

/** Plain (non-transactional) reads. */
const direct: Reader = {get: (query) => query.get()};

/**
 * Why [learningId] cannot be deleted, or null when nothing depends on it.
 * Reads the authoritative records and requirements (inside a transaction
 * when [reader] is one). A failed read throws — never "no dependents".
 *
 * @param {Reader} reader a transaction, or [direct].
 * @param {string} organizationId the organization.
 * @param {string} learningId the learning item.
 * @return {Promise<string|null>} the refusal message, or null.
 */
async function dependencyRefusal(
  reader: Reader,
  organizationId: string,
  learningId: string
): Promise<string | null> {
  const db = getFirestore();
  const [records, requirements] = await Promise.all([
    reader.get(
      db
        .collection(`organizations/${organizationId}/worker_learning_records`)
        .where("learningId", "==", learningId)
        .limit(1)
    ),
    reader.get(
      db
        .collection(`organizations/${organizationId}/safety_requirements`)
        .where("requiredLearningIds", "array-contains", learningId)
    ),
  ]);
  if (!records.empty) {
    return "Learners already have training records for this item, so it " +
      "can't be deleted — deactivate it instead to keep their history.";
  }
  if (!requirements.empty) {
    const names = requirements.docs.map((doc) => {
      const name = doc.data().name;
      return typeof name === "string" && name.trim() ? name.trim() : doc.id;
    });
    return `It is listed by Safety Requirements: ${names.join(", ")}. ` +
      "Remove it from those requirements before deleting it.";
  }
  return null;
}

/** The marker step 1 writes; read back by every later step. */
interface DeletionMarker {
  pending: true;
  previousStatus: string;
}

/**
 * Steps 2 and 3 for an item already MARKED for deletion. Throws an
 * `HttpsError` saying exactly what state the item is left in.
 *
 * @param {string} organizationId the organization.
 * @param {string} id the learning item.
 * @return {Promise<{title: string}>} the deleted item's title.
 */
export async function finishDeletion(
  organizationId: string,
  id: string
): Promise<{title: string}> {
  const db = getFirestore();
  const ref = db.doc(`organizations/${organizationId}/safety_learning/${id}`);
  const stillMarked =
    "It is hidden and marked for deletion; nothing else was changed. " +
    "Choose Delete again to finish — it is also retried automatically.";

  // Step 2a: re-check. A dependency that appeared means the deletion is
  // undone: the item comes back exactly as it was.
  let snapshot;
  let refusal: string | null;
  try {
    snapshot = await ref.get();
    refusal = snapshot.exists ?
      await dependencyRefusal(direct, organizationId, id) :
      null;
  } catch (error) {
    logger.error("finishDeletion: re-check failed", {
      organizationId, id, error: String(error),
    });
    throw new HttpsError(
      "failed-precondition",
      `Couldn't re-check whether this item is used. ${stillMarked}`
    );
  }
  const item = snapshot.data();
  if (!snapshot.exists || !item) return {title: id};
  const marker = item.deletion as DeletionMarker | undefined;
  if (!marker?.pending) {
    throw new HttpsError("failed-precondition",
      "That item is not being deleted.");
  }
  const title = typeof item.title === "string" ? item.title : id;
  if (refusal !== null) {
    await ref.update({
      status: marker.previousStatus === "active" ? "active" : "inactive",
      deletion: FieldValue.delete(),
    });
    throw new HttpsError("failed-precondition",
      `${refusal} Nothing was deleted.`);
  }

  // Step 2b: the uploaded file, unless another item uses the same file.
  const path = ownedLibraryFile(
    item.contentReference, organizationId, storageOps.bucketName()
  );
  if (path !== null) {
    try {
      const sharing = await db
        .collection(`organizations/${organizationId}/safety_learning`)
        .where("contentReference", "==", item.contentReference)
        .limit(2)
        .get();
      const usedElsewhere = sharing.docs.some((doc) => doc.id !== id);
      if (!usedElsewhere) await storageOps.deleteObject(path);
    } catch (error) {
      logger.error("finishDeletion: file not removed yet", {
        organizationId, id, path, error: String(error),
      });
      throw new HttpsError(
        "failed-precondition",
        `Its uploaded file couldn't be removed yet. ${stillMarked}`
      );
    }
  }

  // Step 3: the documents, after a last check.
  try {
    await db.runTransaction(async (tx) => {
      const current = await tx.get(ref);
      if (!current.exists) return;
      if (!(current.data()?.deletion as DeletionMarker | undefined)?.pending) {
        throw new HttpsError("failed-precondition",
          "That item is not being deleted.");
      }
      const last = await dependencyRefusal(tx, organizationId, id);
      if (last !== null) {
        throw new HttpsError("failed-precondition", `${last} ${stillMarked}`);
      }
      const questions = await tx.get(
        ref.collection("knowledge_check_questions")
      );
      for (const question of questions.docs) tx.delete(question.ref);
      tx.delete(ref);
    });
  } catch (error) {
    if (error instanceof HttpsError) throw error;
    logger.error("finishDeletion: documents not removed yet", {
      organizationId, id, error: String(error),
    });
    throw new HttpsError("failed-precondition",
      `Its records couldn't be removed yet. ${stillMarked}`);
  }
  return {title};
}

export const deleteSafetyLearning = onCall(async (request) => {
  const organizationId = typeof request.data?.organizationId === "string" ?
    request.data.organizationId.trim() :
    "";
  const id = typeof request.data?.id === "string" ? request.data.id.trim() : "";
  if (!organizationId) {
    throw new HttpsError("invalid-argument", "organizationId is required.");
  }
  if (!id || id.includes("/")) {
    throw new HttpsError("invalid-argument", "id is required.");
  }
  const {uid, videoOnly} = await requireLibraryAuthor(request, organizationId);

  const db = getFirestore();
  const ref = db.doc(`organizations/${organizationId}/safety_learning/${id}`);
  // Step 1: check and MARK in one transaction. An item already marked (a
  // retry) goes straight on to finishing.
  try {
    await db.runTransaction(async (tx) => {
      const snapshot = await tx.get(ref);
      const item = snapshot.data();
      if (!snapshot.exists || !item) {
        throw new HttpsError(
          "not-found",
          "That safety learning item no longer exists."
        );
      }
      if (videoOnly && item.type !== "video") {
        throw new HttpsError(
          "permission-denied",
          "Managers can manage video learning items only."
        );
      }
      if ((item.deletion as DeletionMarker | undefined)?.pending) return;
      const refusal = await dependencyRefusal(tx, organizationId, id);
      if (refusal !== null) {
        throw new HttpsError("failed-precondition", refusal);
      }
      tx.update(ref, {
        status: "inactive",
        deletion: {
          pending: true,
          previousStatus: item.status === "active" ? "active" : "inactive",
          requestedAt: FieldValue.serverTimestamp(),
          requestedBy: uid,
        },
      });
    });
  } catch (error) {
    if (error instanceof HttpsError) throw error;
    logger.error("deleteSafetyLearning: check failed", {
      organizationId, id, error: String(error),
    });
    throw new HttpsError(
      "unavailable",
      "Couldn't check whether this item is still used, so nothing was " +
        "deleted. Try again."
    );
  }

  const {title} = await finishDeletion(organizationId, id);
  return {organizationId, id, title, fileDeleted: true};
});

/**
 * Finishes every deletion left part-way (an uploaded file or the documents
 * that could not be removed at the time) — the automatic half of the
 * recovery; a library author can also finish one by choosing Delete again.
 * Each item is re-checked exactly as a manual retry is.
 */
export async function finishAllPendingDeletions(): Promise<{
  finished: number;
  failed: number;
}> {
  const db = getFirestore();
  const organizations = await db.collection("organizations").listDocuments();
  let finished = 0;
  let failed = 0;
  for (const organization of organizations) {
    const pending = await db
      .collection(`organizations/${organization.id}/safety_learning`)
      .where("deletion.pending", "==", true)
      .get();
    for (const doc of pending.docs) {
      try {
        await finishDeletion(organization.id, doc.id);
        finished += 1;
      } catch (error) {
        failed += 1;
        logger.warn("finishAllPendingDeletions: still pending", {
          organizationId: organization.id,
          id: doc.id,
          error: String(error),
        });
      }
    }
  }
  return {finished, failed};
}

export const finishPendingLearningDeletions = onSchedule(
  "every 6 hours",
  async () => {
    const result = await finishAllPendingDeletions();
    logger.info("finishPendingLearningDeletions", result);
  }
);
