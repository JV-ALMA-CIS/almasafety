/**
 * Each site's EMERGENCY CONTACTS — the Safety Plan's Section 9 (medical
 * support): the medical facility's name, address and numbers posted where
 * everyone can see them, an ambulance and other emergency numbers, the
 * first-aid kit's location and the trained first-aiders, plus the assembly
 * point. Different for every site, so stored on the site
 * (`organizations/{orgId}/sites/{siteId}.emergency`), and shown to its
 * crew in the app.
 *
 * Written only by `updateSiteEmergencyInfo` (Site Manager/Admin, via
 * `requireOrganizationScopedManager`); the site's own read rules apply.
 */

import {FieldValue, getFirestore} from "firebase-admin/firestore";
import {HttpsError, onCall} from "firebase-functions/v2/https";
import {requireOrganizationScopedManager} from "./organization_callable";

/**
 * A trimmed string of at most [max] characters, or null when blank.
 *
 * @param {unknown} value the raw value.
 * @param {string} label how it is named in errors.
 * @param {number} max the longest allowed.
 * @return {string | null} the value.
 */
function text(value: unknown, label: string, max = 200): string | null {
  if (value === undefined || value === null) return null;
  if (typeof value !== "string") {
    throw new HttpsError("invalid-argument", `${label} must be text.`);
  }
  const trimmed = value.trim();
  if (!trimmed) return null;
  if (trimmed.length > max) {
    throw new HttpsError(
      "invalid-argument",
      `${label} must be ${max} characters or fewer.`
    );
  }
  return trimmed;
}

/**
 * A list of short strings (blanks dropped), at most [maxCount].
 *
 * @param {unknown} raw the raw value.
 * @param {string} label how it is named in errors.
 * @param {number} maxCount the most entries.
 * @param {number} max the longest entry.
 * @return {string[]} the entries.
 */
function list(
  raw: unknown,
  label: string,
  maxCount: number,
  max = 100
): string[] {
  if (raw === undefined || raw === null) return [];
  if (!Array.isArray(raw)) {
    throw new HttpsError("invalid-argument", `${label} must be a list.`);
  }
  const values = raw
    .map((entry) => text(entry, label, max))
    .filter((entry): entry is string => entry !== null);
  if (values.length > maxCount) {
    throw new HttpsError(
      "invalid-argument",
      `${label}: at most ${maxCount} entries.`
    );
  }
  return values;
}

/**
 * Saves a site's emergency contacts (replacing what was there).
 */
export const updateSiteEmergencyInfo = onCall(async (request) => {
  const data = request.data ?? {};
  const organizationId = text(data.organizationId, "organizationId");
  const siteId = text(data.siteId, "siteId");
  if (!organizationId || !siteId) {
    throw new HttpsError(
      "invalid-argument",
      "organizationId and siteId are required."
    );
  }
  const actorUid = await requireOrganizationScopedManager(
    request,
    organizationId
  );
  const raw = (data.emergency ?? {}) as Record<string, unknown>;

  const rawOther = raw.otherNumbers;
  if (rawOther !== undefined && rawOther !== null && !Array.isArray(rawOther)) {
    throw new HttpsError("invalid-argument", "otherNumbers must be a list.");
  }
  const otherNumbers = ((rawOther as unknown[] | undefined) ?? [])
    .map((entry) => {
      const e = (entry ?? {}) as Record<string, unknown>;
      const number = text(e.number, "Phone number", 40);
      if (!number) return null;
      return {label: text(e.label, "Label", 60) ?? "Emergency", number};
    })
    .filter((e) => e !== null);
  if (otherNumbers.length > 10) {
    throw new HttpsError(
      "invalid-argument",
      "At most 10 other emergency numbers."
    );
  }

  const db = getFirestore();
  const ref = db.doc(`organizations/${organizationId}/sites/${siteId}`);
  if (!(await ref.get()).exists) {
    throw new HttpsError("not-found", "That site no longer exists.");
  }
  const profile = (await db.doc(`users/${actorUid}`).get()).data();

  await ref.update({
    emergency: {
      clinicName: text(raw.clinicName, "Clinic name"),
      clinicAddress: text(raw.clinicAddress, "Clinic address", 300),
      clinicPhones: list(raw.clinicPhones, "Clinic phone numbers", 5, 40),
      ambulancePhone: text(raw.ambulancePhone, "Ambulance number", 40),
      otherNumbers,
      assemblyPoint: text(raw.assemblyPoint, "Assembly point"),
      firstAidKitLocation: text(raw.firstAidKitLocation, "First-aid kit"),
      firstAiders: list(raw.firstAiders, "First-aiders", 20),
      notes: text(raw.notes, "Notes", 500),
      updatedAt: FieldValue.serverTimestamp(),
      updatedBy: actorUid,
      updatedByName: typeof profile?.name === "string" ? profile.name : null,
    },
    updatedAt: FieldValue.serverTimestamp(),
    updatedBy: actorUid,
  });
  return {siteId};
});
