/**
 * Operator script for acting on registered accounts.
 *
 * This replaces the previous `bootstrap_admin` script. Under the
 * admin-provisioning model the missing capability was creating the first
 * privileged *account*; under self-registration everyone can create their own
 * account, and the missing capability is *review* — approving, assigning a
 * role, and activating.
 *
 * Approval is now ALSO available in-app, to holders of a reviewer-authorized
 * `platformRole` (Admin, Site Manager/Site Superintendent, Foreman/Site
 * Supervisor — see PROJECT_CONTEXT.md §16), via the callables in
 * `approval_callable.ts`. This script remains for the things the app
 * deliberately cannot do:
 *
 *  - `bootstrap-admin`, which creates or promotes the very first platform
 *    Admin (PROJECT_CONTEXT.md §18). `admin` is never a reachable outcome of
 *    registration, of the in-app review flow, or of any other command in
 *    this script — this is the ONLY path that can grant it, and it requires
 *    the target account to already exist (created by normal
 *    self-registration) and possession of service-account credentials to
 *    run. There is deliberately no "first registered user becomes admin"
 *    shortcut: an operator must name the uid explicitly.
 *  - `approve` with any role, for the very first account in an organization,
 *    before any reviewer exists to grant one in-app. In practice this is
 *    superseded by the bootstrap Admin, who can do the same thing in-app
 *    once they exist — this remains available as a fallback.
 *  - `suspend` / `reinstate` of already-active accounts.
 *
 * Usage (from functions/, with credentials in the environment):
 *
 *   export GOOGLE_APPLICATION_CREDENTIALS=/path/to/service-account.json
 *   npm run build
 *   node lib/scripts/approve_account.js list-pending
 *
 *   # One-time bootstrap: promote your own already-registered account (sign
 *   # up normally first, then run this) to the platform-level Admin.
 *   # Requires --uid AND --email, and the email must match the account's own
 *   # stored email exactly, as a guard against pointing this at the wrong
 *   # uid by mistake.
 *   node lib/scripts/approve_account.js bootstrap-admin \
 *     --uid <uid> --email you@jva-safety.example
 *
 *   # First approval, when the organization does not exist yet — bootstraps
 *   # the first Site Manager/Site Superintendent for that organization:
 *   node lib/scripts/approve_account.js approve \
 *     --uid <uid> --organizationId jv-alma-cis \
 *     --role siteManager \
 *     --createOrganization --organizationName "JV Alma CIS"
 *
 *   # Subsequent approvals into an existing organization:
 *   node lib/scripts/approve_account.js approve \
 *     --uid <uid> --organizationId jv-alma-cis --role worker \
 *     --workerType contractor
 *
 *   node lib/scripts/approve_account.js reject --uid <uid>
 *   node lib/scripts/approve_account.js suspend --uid <uid>
 *   node lib/scripts/approve_account.js reinstate --uid <uid>
 */

import {initializeApp} from "firebase-admin/app";
import {FieldValue, getFirestore} from "firebase-admin/firestore";
import {
  approveAccount,
  denyAccount,
  isAppRole,
  isWorkerType,
  reinstateAccount,
} from "../account_approval";

/** Identifies the operator in the audit log. */
const OPERATOR_UID = "operator:service-account";

/**
 * Reads a `--name value` command-line argument.
 *
 * @param {string} name the flag name, without the leading dashes.
 * @return {string | undefined} the value, or undefined when absent.
 */
function arg(name: string): string | undefined {
  const index = process.argv.indexOf(`--${name}`);
  if (index === -1) return undefined;
  return process.argv[index + 1];
}

/**
 * Reads a required `--name value` argument or exits with usage guidance.
 *
 * @param {string} name the flag name.
 * @return {string} the value.
 */
function requireArg(name: string): string {
  const value = arg(name);
  if (!value) throw new Error(`--${name} is required.`);
  return value;
}

/**
 * Prints every account awaiting review.
 *
 * @return {Promise<void>} resolves once the listing is written.
 */
async function listPending(): Promise<void> {
  const snapshot = await getFirestore()
    .collection("users")
    .where("accountStatus", "==", "pending")
    .get();

  if (snapshot.empty) {
    process.stdout.write("No pending accounts.\n");
    return;
  }
  for (const doc of snapshot.docs) {
    const data = doc.data();
    process.stdout.write(
      `${doc.id}\t${data.email}\t${data.name}\t${data.phone ?? ""}\n`
    );
  }
}

/**
 * Ensures the target organization document exists before assigning users to
 * it, so approval cannot silently create a dangling organizationId.
 *
 * @param {string} organizationId the organization to verify.
 * @return {Promise<void>} resolves when the organization exists.
 */
async function requireOrganization(organizationId: string): Promise<void> {
  const ref = getFirestore().doc(`organizations/${organizationId}`);
  const snapshot = await ref.get();
  if (!snapshot.exists) {
    if (arg("createOrganization") === undefined) {
      throw new Error(
        `Organization "${organizationId}" does not exist. Pass ` +
          "--createOrganization to create it."
      );
    }
    await ref.set({
      name: arg("organizationName") ?? organizationId,
      active: true,
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    process.stdout.write(`Created organization "${organizationId}".\n`);
  }
}

/**
 * Writes an append-only record of a privileged account change.
 *
 * Mirrors the private helper of the same shape in `account_approval.ts`
 * (kept separate rather than exported, since this script's audit actions —
 * bootstrapping the platform administrator — are a distinct, rarer category
 * from ordinary account review).
 *
 * @param {object} entry the audit entry to record.
 * @return {Promise<void>} resolves once the log is written.
 */
async function writeAuditLog(entry: {
  organizationId: string | null;
  actorUid: string;
  action: string;
  targetDocId: string;
  metadata: Record<string, unknown>;
}): Promise<void> {
  await getFirestore().collection("audit_logs").add({
    ...entry,
    targetCollection: "users",
    createdAt: FieldValue.serverTimestamp(),
  });
}

/**
 * Creates or promotes the initial, platform-level Admin.
 *
 * This is the ONLY code path anywhere — in the Flutter client, the Cloud
 * Functions callables, or this script's other commands — that can write
 * `role: "admin"`. It is reachable only by an operator holding
 * service-account credentials, never by any in-app action, so an Admin can
 * never mint a second one in-app and no user can request the role for
 * themselves.
 *
 * Requires the target account to already exist: the intended flow is
 * "register normally through the app first, then have an operator run this
 * once against your own uid" — never "the first person to register becomes
 * admin automatically." Requiring `--email` to match the account's own
 * stored email is a deliberate extra guard against an operator fat-fingering
 * a uid and silently elevating the wrong person.
 *
 * A System Administrator has platform-level authority and therefore no
 * `organizationId` — see `AppRole.isPlatformLevel` in the Flutter source and
 * `REVIEWER_ROLES` in `account_approval.ts`, both of which treat it as
 * scoped to the whole platform rather than to one organization.
 *
 * @param {string} uid the account to promote. Must already exist.
 * @param {string} email must match the account's own stored email.
 * @return {Promise<void>} resolves once the account is an active Admin.
 */
async function bootstrapAdmin(uid: string, email: string): Promise<void> {
  const ref = getFirestore().doc(`users/${uid}`);
  const snapshot = await ref.get();
  const profile = snapshot.data();
  if (!snapshot.exists || !profile) {
    throw new Error(
      `No profile found for uid ${uid}. Register the account through the ` +
        "app first, then bootstrap it."
    );
  }
  if (typeof profile.email !== "string" ||
      profile.email.toLowerCase() !== email.toLowerCase()) {
    throw new Error(
      `--email "${email}" does not match the stored email for ${uid}. ` +
        "Refusing to bootstrap the wrong account."
    );
  }
  if (profile.platformRole === "admin") {
    process.stdout.write(`${uid} is already an Admin.\n`);
    return;
  }

  await ref.update({
    platformRole: "admin",
    accountStatus: "active",
    approvedAt: FieldValue.serverTimestamp(),
    approvedBy: OPERATOR_UID,
    updatedAt: FieldValue.serverTimestamp(),
  });

  await writeAuditLog({
    organizationId: null,
    actorUid: OPERATOR_UID,
    action: "account.bootstrappedAdmin",
    targetDocId: uid,
    metadata: {email},
  });

  process.stdout.write(`${uid} is now an active Admin.\n`);
}

/**
 * Dispatches the requested sub-command.
 *
 * @return {Promise<void>} resolves once the command completes.
 */
async function main(): Promise<void> {
  const command = process.argv[2];
  initializeApp();

  switch (command) {
  case "list-pending":
    await listPending();
    return;
  case "bootstrap-admin": {
    const uid = requireArg("uid");
    const email = requireArg("email");
    await bootstrapAdmin(uid, email);
    return;
  }
  case "approve": {
    const uid = requireArg("uid");
    const organizationId = requireArg("organizationId");
    const roleArg = requireArg("role");
    if (!isAppRole(roleArg)) {
      throw new Error(`"${roleArg}" is not a recognised role.`);
    }
    const workerTypeArg = arg("workerType");
    if (workerTypeArg !== undefined && !isWorkerType(workerTypeArg)) {
      throw new Error(`"${workerTypeArg}" is not a recognised worker type.`);
    }
    await requireOrganization(organizationId);
    await approveAccount({
      uid,
      organizationId,
      role: roleArg,
      workerType: workerTypeArg ?? null,
      approvedBy: OPERATOR_UID,
    });
    process.stdout.write(
      `Approved ${uid} into "${organizationId}" as "${roleArg}".\n`
    );
    return;
  }
  case "reject":
  case "suspend": {
    const uid = requireArg("uid");
    const status = command === "reject" ? "rejected" : "suspended";
    await denyAccount({uid, status, actorUid: OPERATOR_UID});
    process.stdout.write(`Set ${uid} to "${status}".\n`);
    return;
  }
  case "reinstate": {
    const uid = requireArg("uid");
    await reinstateAccount({uid, actorUid: OPERATOR_UID});
    process.stdout.write(`Reinstated ${uid}.\n`);
    return;
  }
  default:
    throw new Error(
      "Usage: approve_account <list-pending|bootstrap-admin|approve|" +
        "reject|suspend|reinstate> [--uid <uid>] [--email <email>] " +
        "[--organizationId <id>] [--role <role>] [--workerType <type>]"
    );
  }
}

main().catch((error) => {
  process.stderr.write(`${(error as Error).message}\n`);
  process.exitCode = 1;
});
