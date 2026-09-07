/**
 * One-time Admin-SDK migration script: backfills
 * `users/{uid}/memberships/{organizationId}` documents from the OLD
 * single-`organizationId`-field model this migration is replacing.
 *
 * BACKGROUND
 *
 * Before this migration, a user's relationship to an organization —
 * `organizationId`, `platformRole` (doubling as their per-org role for
 * everyone but Admin), `workerType`, `trade`, `siteIds`, `supervisorUid`,
 * `approvedAt`, `approvedBy` — lived as scalar fields directly on
 * `users/{uid}`. The new model moves all of that (except `platformRole`,
 * which stays `admin`-only on the profile) onto
 * `users/{uid}/memberships/{organizationId}` instead, so a person can belong
 * to more than one organization.
 *
 * This script performs the one-time backfill: for every `users/{uid}`
 * document with a non-null `organizationId`, it creates the corresponding
 * membership document from that profile's existing fields, with
 * `status: "active"`. An existing Admin account (`platformRole == "admin"`)
 * is skipped — Admin holds no memberships at all under the new model, by
 * construction.
 *
 * This script does NOT delete the old scalar fields from `users/{uid}` —
 * that is a separate, later cleanup step run only after the backfill here has
 * been verified (per the migration plan). Leaving them in place for now is
 * harmless: `firestore.rules` already denies every client write to
 * `organizationId`/`workerType`/`trade`/`siteIds`/`supervisorUid` on
 * `users/{uid}` (they were removed from the update-blocked field list only
 * because they are no longer WRITTEN there by any code path at all, not
 * because a stale value would be writable — `onlySelfEditableFields()` never
 * included them to begin with), and no new code path reads them any more.
 *
 * IDEMPOTENT: a uid that already has a membership document for its
 * `organizationId` is skipped (not overwritten), so running this script
 * again after a partial run, or after some accounts have already been
 * migrated some other way (e.g. through `createOrganization`/
 * `approvePendingAccount` on the new code path), is always safe.
 *
 * DRY-RUN CAPABLE: pass `--dry-run` to log exactly what WOULD be written
 * without writing anything, mirroring `approve_account.ts`'s own
 * flag-driven, `--name value` argument style.
 *
 * Usage (from functions/, with credentials in the environment):
 *
 *   export GOOGLE_APPLICATION_CREDENTIALS=/path/to/service-account.json
 *   npm run build
 *   node lib/scripts/backfill_memberships.js --dry-run
 *   node lib/scripts/backfill_memberships.js
 */

import {initializeApp} from "firebase-admin/app";
import {FieldValue, getFirestore} from "firebase-admin/firestore";
import {isAppRole} from "../account_approval";

/**
 * Reads a boolean `--name` flag (present with no value).
 *
 * @param {string} name the flag name, without the leading dashes.
 * @return {boolean} true when the flag is present.
 */
function flag(name: string): boolean {
  return process.argv.includes(`--${name}`);
}

/**
 * Backfills one user's membership document from their legacy scalar fields.
 *
 * @param {string} uid the user's uid.
 * @param {FirebaseFirestore.DocumentData} profile the user's existing
 * profile data.
 * @param {boolean} dryRun when true, logs the intended write without
 * performing it.
 * @return {Promise<"created" | "skipped-admin" | "skipped-exists" |
 * "skipped-no-org">} what happened for this uid.
 */
async function backfillOne(
  uid: string,
  profile: FirebaseFirestore.DocumentData,
  dryRun: boolean
): Promise<"created" | "skipped-admin" | "skipped-exists" | "skipped-no-org"> {
  // Admin is platform-level and holds no memberships at all, by
  // construction — see firestore.rules's header note and
  // `account_approval.ts`'s APP_ROLES documentation.
  if (profile.platformRole === "admin") {
    return "skipped-admin";
  }

  const organizationId = profile.organizationId;
  if (typeof organizationId !== "string" || !organizationId) {
    return "skipped-no-org";
  }

  const membershipRef = getFirestore()
    .doc(`users/${uid}/memberships/${organizationId}`);

  // Idempotent: never overwrite an existing membership document, whether it
  // was created by an earlier run of this same script or by the new code
  // path (createOrganization / approvePendingAccount) independently.
  const existing = await membershipRef.get();
  if (existing.exists) {
    return "skipped-exists";
  }

  // The legacy model used `platformRole` to double as a non-admin user's
  // per-organization role too (siteManager/foreman/worker); the new
  // membership document's own `role` field is that same value.
  const legacyRole = profile.platformRole;
  const role = isAppRole(legacyRole) && legacyRole !== "admin" ?
    legacyRole :
    null;
  if (!role) {
    // A profile with an organizationId but no recognised non-admin role is
    // a data anomaly this script should surface rather than silently patch
    // over with a guess.
    throw new Error(
      `${uid} has organizationId "${organizationId}" but platformRole ` +
        `"${String(legacyRole)}" is not a valid non-admin role; skipping. ` +
        "Investigate this account manually."
    );
  }

  const membershipData = {
    organizationId,
    role,
    workerType: typeof profile.workerType === "string" ?
      profile.workerType :
      null,
    trade: typeof profile.trade === "string" ? profile.trade : null,
    siteIds: Array.isArray(profile.siteIds) ?
      profile.siteIds.filter((id: unknown) => typeof id === "string") :
      [],
    supervisorUid: typeof profile.supervisorUid === "string" ?
      profile.supervisorUid :
      null,
    status: "active",
    approvedAt: profile.approvedAt ?? FieldValue.serverTimestamp(),
    approvedBy: typeof profile.approvedBy === "string" ?
      profile.approvedBy :
      "migration:backfill_memberships",
    createdAt: profile.approvedAt ?? FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  };

  if (dryRun) {
    process.stdout.write(
      `[dry-run] would create users/${uid}/memberships/${organizationId}: ` +
        `${JSON.stringify({...membershipData, approvedAt: "<preserved>",
          createdAt: "<preserved>", updatedAt: "<server timestamp>"})}\n`
    );
    return "created";
  }

  await membershipRef.set(membershipData);
  process.stdout.write(
    `Created users/${uid}/memberships/${organizationId} ` +
      `(role: ${role}).\n`
  );
  return "created";
}

/**
 * Runs the backfill across every `users/{uid}` document.
 *
 * @return {Promise<void>} resolves once every user has been processed.
 */
async function main(): Promise<void> {
  const dryRun = flag("dry-run");
  initializeApp();

  if (dryRun) {
    process.stdout.write("Running in --dry-run mode: no writes will occur.\n");
  }

  const snapshot = await getFirestore().collection("users").get();

  const counts = {
    "created": 0,
    "skipped-admin": 0,
    "skipped-exists": 0,
    "skipped-no-org": 0,
    "errors": 0,
  };

  for (const doc of snapshot.docs) {
    try {
      const result = await backfillOne(doc.id, doc.data(), dryRun);
      counts[result]++;
    } catch (error) {
      counts.errors++;
      process.stderr.write(
        `Error processing ${doc.id}: ${(error as Error).message}\n`
      );
    }
  }

  process.stdout.write(
    "\nSummary: " +
      `${counts.created} ${dryRun ? "would be created" : "created"}, ` +
      `${counts["skipped-admin"]} skipped (admin), ` +
      `${counts["skipped-exists"]} skipped (already migrated), ` +
      `${counts["skipped-no-org"]} skipped (no organizationId), ` +
      `${counts.errors} errors.\n`
  );

  if (counts.errors > 0) {
    process.exitCode = 1;
  }
}

main().catch((error) => {
  process.stderr.write(`${(error as Error).message}\n`);
  process.exitCode = 1;
});
