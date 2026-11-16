/**
 * Publishing an uploaded Safety Learning file (a JVA video, a document)
 * into an organization's library folder.
 *
 * WHY A SERVER STEP
 *
 * `storage.rules` cannot tell an Admin or Site Manager from any other
 * signed-in user: checking Firestore memberships from Storage Rules
 * returned 403 in production (see `storage.rules`' header), and the app
 * has no custom claims. So the library folder
 * (`organizations/{org}/safety_learning/...`) accepts NO client writes at
 * all. Instead:
 *
 * 1. The author's client uploads to their OWN staging folder,
 *    `learning_uploads/{theirUid}/{uploadId}/{fileName}` — a path Storage
 *    Rules can scope to the uploader by `request.auth.uid` alone, with the
 *    same size limit and file types as the library.
 * 2. This callable checks the caller is a library author for the
 *    organization (`requireLibraryAuthor` — Admin, or a Site Manager of
 *    that organization for videos only), re-checks the staged file's size
 *    and type, copies it into the library folder under a fresh download
 *    token, deletes the staged copy, and returns the download URL to save
 *    as the item's `contentReference`.
 *
 * Writing within the project's own bucket with the Admin SDK needs no
 * signing permission (unlike signed upload URLs), so this adds no new IAM
 * requirement. Nothing is ever overwritten: an existing library file at
 * the target path is refused.
 */

import {randomUUID} from "crypto";
import {getStorage} from "firebase-admin/storage";
import {HttpsError, onCall} from "firebase-functions/v2/https";
import type {CallableRequest} from "firebase-functions/v2/https";
import {requireLibraryAuthor} from "./safety_learning_callable";

/** Mirrors `request.resource.size < 25 * 1024 * 1024` in storage.rules. */
const MAX_UPLOAD_BYTES = 25 * 1024 * 1024;

/** The library's file types — mirrors the allow-list in storage.rules. */
const LIBRARY_TYPES = new RegExp(
  "^(video/.*|image/(png|jpeg)|application/pdf|application/msword|" +
    "application/vnd[.]ms-(powerpoint|excel)|" +
    "application/vnd[.]openxmlformats-officedocument[.].*)$"
);

/**
 * Reads a required, non-empty string argument.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @param {string} field the argument name.
 * @return {string} the trimmed value.
 */
function requireString(request: CallableRequest, field: string): string {
  const value = (request.data ?? {})[field];
  if (typeof value !== "string" || !value.trim()) {
    throw new HttpsError("invalid-argument", `${field} is required.`);
  }
  return value.trim();
}

/**
 * Whether [segment] is a safe single path segment.
 *
 * @param {string} segment the segment.
 * @return {boolean} true when non-empty and not `.`/`..`.
 */
function isSafeSegment(segment: string): boolean {
  return segment.length > 0 && segment !== "." && segment !== "..";
}

export const publishLearningUpload = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const {uid, videoOnly} = await requireLibraryAuthor(request, organizationId);
  const uploadPath = requireString(request, "uploadPath");

  // Only the caller's own staged file: learning_uploads/{uid}/{id}/{name}.
  const parts = uploadPath.split("/");
  if (
    parts.length !== 4 ||
    parts[0] !== "learning_uploads" ||
    parts[1] !== uid ||
    !parts.every(isSafeSegment)
  ) {
    throw new HttpsError(
      "invalid-argument",
      "uploadPath must be one of your own staged uploads."
    );
  }
  const [, , uploadId, fileName] = parts;

  const bucket = getStorage().bucket();
  const staged = bucket.file(uploadPath);
  const [exists] = await staged.exists();
  if (!exists) {
    throw new HttpsError("not-found", "That upload could not be found.");
  }
  const [metadata] = await staged.getMetadata();
  const size = Number(metadata.size ?? 0);
  const contentType =
    typeof metadata.contentType === "string" ? metadata.contentType : "";
  const typeAllowed = videoOnly ?
    contentType.startsWith("video/") :
    LIBRARY_TYPES.test(contentType);
  if (!(size > 0 && size < MAX_UPLOAD_BYTES) || !typeAllowed) {
    await staged.delete({ignoreNotFound: true});
    throw new HttpsError(
      "invalid-argument",
      videoOnly ?
        "Only video files under 25 MB can be added." :
        "Only library file types under 25 MB can be added."
    );
  }

  const target = bucket.file(
    `organizations/${organizationId}/safety_learning/${uploadId}/${fileName}`
  );
  const [targetExists] = await target.exists();
  if (targetExists) {
    throw new HttpsError(
      "already-exists",
      "A library file already exists at that path. Upload it again."
    );
  }

  // Read and re-write (at most 25 MB) rather than a server-side copy: the
  // Storage emulator applies Rules to Admin SDK copies, which would make
  // this path untestable there. A fresh download token, so no link handed
  // out for the staged copy can ever open the published one.
  // `ifGenerationMatch: 0` makes the write fail rather than overwrite if a
  // file appeared since the check above.
  const [bytes] = await staged.download();
  const token = randomUUID();
  try {
    await target.save(bytes, {
      contentType,
      resumable: false,
      preconditionOpts: {ifGenerationMatch: 0},
      metadata: {metadata: {firebaseStorageDownloadTokens: token}},
    });
  } catch (error) {
    if ((error as {code?: number}).code === 412) {
      throw new HttpsError(
        "already-exists",
        "A library file already exists at that path. Upload it again."
      );
    }
    throw error;
  }
  await staged.delete({ignoreNotFound: true});

  return {
    organizationId,
    contentReference: downloadUrl(bucket.name, target.name, token),
  };
});

/**
 * The Firebase Storage download URL for [path] with [token] — the same
 * format the client SDK's `getDownloadURL` returns (and that
 * `VideoSource` recognises as a JVA video). Built here rather than via
 * the Admin SDK's `getDownloadURL`, which re-reads the file through the
 * Storage REST API (and its Rules, in the emulator).
 *
 * @param {string} bucketName the bucket.
 * @param {string} path the object path.
 * @param {string} token the object's download token.
 * @return {string} the download URL.
 */
function downloadUrl(bucketName: string, path: string, token: string): string {
  const emulatorHost = process.env.FIREBASE_STORAGE_EMULATOR_HOST;
  const origin = emulatorHost ?
    `http://${emulatorHost}` :
    "https://firebasestorage.googleapis.com";
  return `${origin}/v0/b/${bucketName}/o/${encodeURIComponent(path)}` +
    `?alt=media&token=${token}`;
}
