/**
 * Site inspection callables for JV ALMA C.I.S. — the daily site inspection
 * and the weekly HSE walk-down required by the Safety Plan (Section 7:
 * daily inspections by the Safety Manager, SSHO and Foremen; a deficiency
 * log with follow-up).
 *
 * Two collections, flat under the organization:
 *
 * - `inspection_templates/{id}` — the checklists (sections of items). The
 *   standard ones come from `inspection_templates.ts` via
 *   `installDefaultInspectionTemplates`; a Site Manager/Admin can edit them
 *   (`saveInspectionTemplate`) or switch them off.
 * - `inspections/{id}` — one inspection: a SNAPSHOT of the template's items
 *   (so later template edits never rewrite past records), each answered
 *   ok / notOk / na with an optional note and photo.
 *
 * WORKFLOW: start → answer items (saved as you go) → submit → sign-off.
 *
 * - `startInspection`: a Foreman at one of their own sites, or a Site
 *   Manager/Admin at any site of the organization (`requireInspector`).
 * - `recordInspectionItem`: only the inspector, only while in progress.
 * - `submitInspection`: only the inspector; every item answered, and every
 *   "Not OK" needs a note. Each "Not OK" becomes a DEFICIENCY — a hazard
 *   (`hazards/{id}` with `inspectionId`/`inspectionItemId`) reported by the
 *   inspector — so it is tracked to closure through the existing hazard →
 *   corrective action → evidence → approval flow, which is exactly the
 *   Safety Plan's deficiency log (date found, description, person
 *   responsible, target date, date resolved, follow-up).
 * - `signOffInspection`: a Site Manager/Admin (the Safety Manager), never
 *   the inspector themselves.
 *
 * `firestore.rules` denies every client write to both collections; reads
 * are for reviewer roles (Admin/Site Manager/Foreman) of the organization.
 */

import {FieldValue, getFirestore} from "firebase-admin/firestore";
import {CallableRequest, HttpsError, onCall} from "firebase-functions/v2/https";
import {requireIncidentInvestigator} from "./corrective_action_callable";
import {DEFAULT_TEMPLATES, TemplateSection} from "./inspection_templates";

const KINDS = ["daily", "weekly", "environmental", "welfare", "other"];
const RESULTS = ["ok", "notOk", "na"];
const HAZARD_CATEGORIES = [
  "workingAtHeight", "electrical", "equipment", "ppe", "housekeeping",
  "environment", "chemical", "fire", "other",
];
const MAX_SECTIONS = 30;
const MAX_ITEMS = 200;

/**
 * The single refusal returned for every authorization failure.
 *
 * @return {HttpsError} the opaque permission-denied error.
 */
function denied(): HttpsError {
  return new HttpsError(
    "permission-denied",
    "You do not have permission to do that."
  );
}

/**
 * Reads and validates a required non-empty string argument.
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
 * Reads an optional trimmed string argument, null when absent or blank.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @param {string} field the argument name.
 * @param {number} max the longest value kept.
 * @return {string | null} the value, or null.
 */
function optionalString(
  request: CallableRequest,
  field: string,
  max = 1000
): string | null {
  const value = (request.data ?? {})[field];
  if (typeof value !== "string" || !value.trim()) return null;
  return value.trim().slice(0, max);
}

/**
 * The caller's uid, role in [organizationId] and whether they are the
 * System Administrator. Refuses inactive callers and non-members.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @param {string} organizationId the organization.
 * @return {Promise<object>} the caller: uid, role, siteIds, name and
 * whether they are the System Administrator.
 */
async function requireCaller(
  request: CallableRequest,
  organizationId: string
): Promise<{
  uid: string;
  role: string | null;
  siteIds: string[];
  name: string | null;
  isPlatformAdmin: boolean;
}> {
  const uid = request.auth?.uid;
  if (!uid) throw denied();
  const profile = (await getFirestore().doc(`users/${uid}`).get()).data();
  if (!profile || profile.accountStatus !== "active") throw denied();
  const name =
    typeof profile.name === "string" && profile.name.trim() ?
      profile.name.trim() :
      null;
  if (profile.platformRole === "admin") {
    return {uid, role: "admin", siteIds: [], name, isPlatformAdmin: true};
  }
  const membership = (
    await getFirestore().doc(`users/${uid}/memberships/${organizationId}`).get()
  ).data();
  if (!membership || membership.status !== "active") throw denied();
  const siteIds = Array.isArray(membership.siteIds) ?
    (membership.siteIds as unknown[]).filter(
      (id): id is string => typeof id === "string"
    ) :
    [];
  return {
    uid,
    role: typeof membership.role === "string" ? membership.role : null,
    siteIds,
    name,
    isPlatformAdmin: false,
  };
}

/**
 * Authorizes the caller to INSPECT [siteId]: a Foreman at one of their own
 * sites, or a Site Manager/Admin (any site of the organization).
 *
 * @param {CallableRequest} request the incoming callable request.
 * @param {string} organizationId the organization.
 * @param {string} siteId the site inspected.
 * @return {Promise<object>} the inspector's uid and name.
 */
async function requireInspector(
  request: CallableRequest,
  organizationId: string,
  siteId: string
): Promise<{uid: string; name: string | null}> {
  const caller = await requireCaller(request, organizationId);
  if (caller.role === "admin" || caller.role === "siteManager") {
    return caller;
  }
  if (caller.role === "foreman" && caller.siteIds.includes(siteId)) {
    return caller;
  }
  throw denied();
}

/**
 * Validates and normalizes template sections from the request: 1–30
 * sections, each with a title and items (text + hazard category), at most
 * 200 items overall. Items keep their ids when given (so edits don't
 * renumber), otherwise get fresh ones.
 *
 * @param {unknown} raw the `sections` argument.
 * @return {TemplateSection[]} the clean sections.
 */
function readSections(raw: unknown): TemplateSection[] {
  if (!Array.isArray(raw) || raw.length === 0 || raw.length > MAX_SECTIONS) {
    throw new HttpsError(
      "invalid-argument",
      `A template needs between 1 and ${MAX_SECTIONS} sections.`
    );
  }
  const usedIds = new Set<string>();
  let count = 0;
  const sections = raw.map((rawSection, sectionIndex) => {
    const title =
      typeof rawSection?.title === "string" ? rawSection.title.trim() : "";
    if (!title) {
      throw new HttpsError("invalid-argument", "Every section needs a title.");
    }
    const rawItems: unknown = rawSection?.items;
    if (!Array.isArray(rawItems) || rawItems.length === 0) {
      throw new HttpsError(
        "invalid-argument",
        `Section "${title}" needs at least one item.`
      );
    }
    const items = rawItems.map((rawItem, itemIndex) => {
      const text =
        typeof rawItem?.text === "string" ? rawItem.text.trim() : "";
      if (!text) {
        throw new HttpsError("invalid-argument", "Every item needs text.");
      }
      const category =
        typeof rawItem?.hazardCategory === "string" &&
          HAZARD_CATEGORIES.includes(rawItem.hazardCategory) ?
          rawItem.hazardCategory :
          "other";
      let id =
        typeof rawItem?.id === "string" && rawItem.id.trim() ?
          rawItem.id.trim() :
          `s${sectionIndex + 1}i${itemIndex + 1}`;
      while (usedIds.has(id)) id = `${id}x`;
      usedIds.add(id);
      count++;
      return {id, text: text.slice(0, 400), hazardCategory: category};
    });
    return {title: title.slice(0, 120), items};
  });
  if (count > MAX_ITEMS) {
    throw new HttpsError(
      "invalid-argument",
      `A template can have at most ${MAX_ITEMS} items.`
    );
  }
  return sections;
}

/**
 * Reads the sites a template is used at: each must be a site of the
 * organization. Empty means every site.
 *
 * @param {string} organizationId the organization.
 * @param {unknown} raw the `siteIds` argument.
 * @return {Promise<string[]>} the site ids.
 */
async function readSiteIds(
  organizationId: string,
  raw: unknown
): Promise<string[]> {
  if (raw === undefined || raw === null) return [];
  if (!Array.isArray(raw) || raw.some((id) => typeof id !== "string")) {
    throw new HttpsError("invalid-argument", "siteIds must be a list.");
  }
  const ids = [...new Set(raw as string[])].filter((id) => id.trim());
  if (ids.length > 200) {
    throw new HttpsError("invalid-argument", "Too many sites.");
  }
  const db = getFirestore();
  await Promise.all(ids.map(async (id) => {
    const site = (
      await db.doc(`organizations/${organizationId}/sites/${id}`).get()
    ).data();
    if (!site) {
      throw new HttpsError("invalid-argument", "One of the sites is unknown.");
    }
  }));
  return ids;
}

/**
 * The checklist library: every standard checklist, and whether this
 * organization already has it. Site Manager/Admin only.
 */
export const listStandardInspectionTemplates = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  await requireIncidentInvestigator(request, organizationId);
  const existing = await getFirestore()
    .collection(`organizations/${organizationId}/inspection_templates`)
    .get();
  const installed = new Set(
    existing.docs.map((doc) => doc.data().defaultKey).filter(Boolean)
  );
  return {
    templates: DEFAULT_TEMPLATES.map((t) => ({
      key: t.defaultKey,
      name: t.name,
      kind: t.kind,
      description: t.description,
      core: t.core,
      itemCount: t.sections.reduce((n, s) => n + s.items.length, 0),
      installed: installed.has(t.defaultKey),
    })),
  };
});

/**
 * Installs standard templates for [organizationId], skipping any already
 * installed — safe to call more than once. Without `keys`, the general
 * ones (`core`: daily site inspection, weekly HSE walk-down); with `keys`,
 * exactly those library checklists. Site Manager/Admin only.
 */
export const installDefaultInspectionTemplates = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const uid = await requireIncidentInvestigator(request, organizationId);
  const rawKeys = (request.data ?? {}).keys;
  if (
    rawKeys !== undefined && rawKeys !== null &&
    (!Array.isArray(rawKeys) || rawKeys.some((k) => typeof k !== "string"))
  ) {
    throw new HttpsError("invalid-argument", "keys must be a list.");
  }
  const keys = Array.isArray(rawKeys) ? rawKeys as string[] : null;
  if (keys && keys.some((k) => !DEFAULT_TEMPLATES.some(
    (t) => t.defaultKey === k
  ))) {
    throw new HttpsError("invalid-argument", "Unknown standard checklist.");
  }
  const wanted = DEFAULT_TEMPLATES.filter(
    (t) => keys ? keys.includes(t.defaultKey) : t.core
  );
  const db = getFirestore();
  const collection = db.collection(
    `organizations/${organizationId}/inspection_templates`
  );
  const existing = await collection.get();
  const installed = new Set(
    existing.docs.map((doc) => doc.data().defaultKey).filter(Boolean)
  );
  const batch = db.batch();
  const now = FieldValue.serverTimestamp();
  let added = 0;
  const ids: string[] = [];
  for (const template of wanted) {
    if (installed.has(template.defaultKey)) continue;
    const ref = collection.doc();
    ids.push(ref.id);
    batch.set(ref, {
      organizationId,
      defaultKey: template.defaultKey,
      name: template.name,
      kind: template.kind,
      description: template.description,
      sections: template.sections,
      siteIds: [],
      status: "active",
      createdAt: now,
      createdBy: uid,
      updatedAt: now,
      updatedBy: uid,
    });
    added++;
  }
  if (added > 0) await batch.commit();
  return {added, ids};
});

/**
 * Creates (no `templateId`) or updates an inspection template. Site
 * Manager/Admin only. Past inspections are unaffected — each keeps its own
 * snapshot of the items it was started with.
 */
export const saveInspectionTemplate = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const uid = await requireIncidentInvestigator(request, organizationId);
  const name = requireString(request, "name").slice(0, 120);
  const kind = requireString(request, "kind");
  if (!KINDS.includes(kind)) {
    throw new HttpsError(
      "invalid-argument",
      "kind must be one of: " + KINDS.join(", ")
    );
  }
  const description = optionalString(request, "description", 500);
  const sections = readSections((request.data ?? {}).sections);
  const siteIds = await readSiteIds(
    organizationId, (request.data ?? {}).siteIds
  );
  const templateId = optionalString(request, "templateId", 200);
  const status = optionalString(request, "status", 20) ?? "active";
  if (status !== "active" && status !== "inactive") {
    throw new HttpsError(
      "invalid-argument",
      "status must be active or inactive."
    );
  }

  const db = getFirestore();
  const collection = db.collection(
    `organizations/${organizationId}/inspection_templates`
  );
  const now = FieldValue.serverTimestamp();
  if (templateId) {
    const ref = collection.doc(templateId);
    const snapshot = await ref.get();
    const existing = snapshot.data();
    if (!snapshot.exists || existing?.organizationId !== organizationId) {
      throw new HttpsError("not-found", "That template no longer exists.");
    }
    await ref.update({
      name,
      kind,
      description,
      sections,
      siteIds,
      status,
      updatedAt: now,
      updatedBy: uid,
    });
    return {id: templateId};
  }
  const ref = collection.doc();
  await ref.set({
    organizationId,
    defaultKey: null,
    name,
    kind,
    description,
    sections,
    siteIds,
    status,
    createdAt: now,
    createdBy: uid,
    updatedAt: now,
    updatedBy: uid,
  });
  return {id: ref.id};
});

/**
 * Loads an inspection and confirms it belongs to [organizationId].
 *
 * @param {string} organizationId the organization.
 * @param {string} inspectionId the inspection id.
 * @return {Promise<{ref: FirebaseFirestore.DocumentReference,
 * data: FirebaseFirestore.DocumentData}>} the inspection.
 */
async function requireInspection(
  organizationId: string,
  inspectionId: string
): Promise<{
  ref: FirebaseFirestore.DocumentReference;
  data: FirebaseFirestore.DocumentData;
}> {
  const ref = getFirestore().doc(
    `organizations/${organizationId}/inspections/${inspectionId}`
  );
  const snapshot = await ref.get();
  const data = snapshot.data();
  if (!snapshot.exists || !data || data.organizationId !== organizationId) {
    throw new HttpsError("not-found", "That inspection no longer exists.");
  }
  return {ref, data};
}

/**
 * Starts an inspection of [siteId] from an active template, snapshotting
 * its items. A Foreman at their own site, or a Site Manager/Admin.
 */
export const startInspection = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const siteId = requireString(request, "siteId");
  const templateId = requireString(request, "templateId");
  const inspector = await requireInspector(request, organizationId, siteId);

  const db = getFirestore();
  const site = (
    await db.doc(`organizations/${organizationId}/sites/${siteId}`).get()
  ).data();
  if (!site || site.organizationId !== organizationId) {
    throw new HttpsError("failed-precondition", "That site does not exist.");
  }
  const template = (
    await db
      .doc(`organizations/${organizationId}/inspection_templates/${templateId}`)
      .get()
  ).data();
  if (!template || template.organizationId !== organizationId) {
    throw new HttpsError("not-found", "That template no longer exists.");
  }
  if (template.status !== "active") {
    throw new HttpsError(
      "failed-precondition",
      "That template is switched off."
    );
  }
  const usedAt = (template.siteIds as string[] | undefined) ?? [];
  if (usedAt.length > 0 && !usedAt.includes(siteId)) {
    throw new HttpsError(
      "failed-precondition",
      "That checklist is not used at this site."
    );
  }

  const items = (template.sections as TemplateSection[]).flatMap((s) =>
    s.items.map((item) => ({
      id: item.id,
      section: s.title,
      text: item.text,
      hazardCategory: item.hazardCategory ?? "other",
      result: null,
      note: null,
      photoUrl: null,
      hazardId: null,
    }))
  );
  const now = FieldValue.serverTimestamp();
  const ref = db
    .collection(`organizations/${organizationId}/inspections`)
    .doc();
  await ref.set({
    organizationId,
    projectId: site.projectId ?? null,
    siteId,
    siteName: typeof site.name === "string" ? site.name : null,
    templateId,
    templateName: template.name,
    kind: template.kind,
    items,
    status: "inProgress",
    inspectorUid: inspector.uid,
    inspectorName: inspector.name,
    okCount: 0,
    notOkCount: 0,
    naCount: 0,
    startedAt: now,
    submittedAt: null,
    signedOffBy: null,
    signedOffByName: null,
    signedOffAt: null,
    signOffNote: null,
    createdAt: now,
    updatedAt: now,
  });
  return {id: ref.id};
});

/**
 * Records the answer to one item — saved as the inspector goes. Only the
 * inspector, only while in progress.
 */
export const recordInspectionItem = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const inspectionId = requireString(request, "inspectionId");
  const itemId = requireString(request, "itemId");
  const rawResult = (request.data ?? {}).result;
  const result = rawResult === null || rawResult === undefined ?
    null :
    String(rawResult);
  if (result !== null && !RESULTS.includes(result)) {
    throw new HttpsError(
      "invalid-argument",
      "result must be one of: " + RESULTS.join(", ")
    );
  }
  const note = optionalString(request, "note");
  const photoUrl = optionalString(request, "photoUrl", 2000);

  const caller = await requireCaller(request, organizationId);
  const {ref} = await requireInspection(organizationId, inspectionId);
  await getFirestore().runTransaction(async (tx) => {
    const data = (await tx.get(ref)).data();
    if (!data) throw new HttpsError("not-found", "That inspection is gone.");
    if (data.inspectorUid !== caller.uid) throw denied();
    if (data.status !== "inProgress") {
      throw new HttpsError(
        "failed-precondition",
        "This inspection has already been submitted."
      );
    }
    const items = data.items as Array<Record<string, unknown>>;
    const index = items.findIndex((item) => item.id === itemId);
    if (index < 0) throw new HttpsError("not-found", "No such item.");
    items[index] = {...items[index], result, note, photoUrl};
    tx.update(ref, {items, updatedAt: FieldValue.serverTimestamp()});
  });
  return {id: inspectionId, itemId, result};
});

/**
 * Submits a finished inspection. Every item must be answered and every
 * "Not OK" needs a note. Each "Not OK" becomes a deficiency (a hazard
 * reported by the inspector, linked back to this inspection), in the same
 * write as the submission.
 */
export const submitInspection = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const inspectionId = requireString(request, "inspectionId");
  const caller = await requireCaller(request, organizationId);
  const {ref, data} = await requireInspection(organizationId, inspectionId);
  if (data.inspectorUid !== caller.uid) throw denied();
  if (data.status !== "inProgress") {
    throw new HttpsError(
      "failed-precondition",
      "This inspection has already been submitted."
    );
  }
  const items = data.items as Array<Record<string, unknown>>;
  const unanswered = items.filter((item) => !item.result).length;
  if (unanswered > 0) {
    throw new HttpsError(
      "failed-precondition",
      `${unanswered} item(s) still need an answer.`
    );
  }
  const missingNote = items.filter(
    (item) =>
      item.result === "notOk" &&
      !(typeof item.note === "string" && item.note.trim())
  ).length;
  if (missingNote > 0) {
    throw new HttpsError(
      "failed-precondition",
      `${missingNote} "Not OK" item(s) need a note saying what is wrong.`
    );
  }

  const db = getFirestore();
  const batch = db.batch();
  const now = FieldValue.serverTimestamp();
  const hazards = db.collection(`organizations/${organizationId}/hazards`);
  const updatedItems = items.map((item) => {
    if (item.result !== "notOk") return item;
    const hazardRef = hazards.doc();
    batch.set(hazardRef, {
      organizationId,
      projectId: data.projectId,
      siteId: data.siteId,
      reportedByUid: caller.uid,
      kind: "hazard",
      category: HAZARD_CATEGORIES.includes(item.hazardCategory as string) ?
        item.hazardCategory :
        "other",
      description: `${item.text} — ${item.note}`,
      location: null,
      photoUrl: item.photoUrl ?? null,
      status: "reported",
      correctiveActionId: null,
      acknowledgedBy: null,
      acknowledgedAt: null,
      closedBy: null,
      closedAt: null,
      inspectionId,
      inspectionItemId: item.id,
      inspectionName: data.templateName,
      createdAt: now,
      createdBy: caller.uid,
      updatedAt: now,
      updatedBy: caller.uid,
    });
    return {...item, hazardId: hazardRef.id};
  });
  const count = (result: string) =>
    items.filter((item) => item.result === result).length;
  batch.update(ref, {
    items: updatedItems,
    status: "submitted",
    okCount: count("ok"),
    notOkCount: count("notOk"),
    naCount: count("na"),
    submittedAt: now,
    updatedAt: now,
  });
  await batch.commit();
  return {
    id: inspectionId,
    status: "submitted",
    deficiencies: count("notOk"),
  };
});

/**
 * Signs off a submitted inspection — the Safety Manager's review. A Site
 * Manager/Admin of the organization, never the inspector themselves.
 */
export const signOffInspection = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const inspectionId = requireString(request, "inspectionId");
  const note = optionalString(request, "note");
  const uid = await requireIncidentInvestigator(request, organizationId);
  const {ref, data} = await requireInspection(organizationId, inspectionId);
  if (data.inspectorUid === uid) {
    throw new HttpsError(
      "failed-precondition",
      "You can't sign off your own inspection — another manager must."
    );
  }
  if (data.status !== "submitted") {
    throw new HttpsError(
      "failed-precondition",
      data.status === "signedOff" ?
        "This inspection is already signed off." :
        "This inspection has not been submitted yet."
    );
  }
  const profile = (await getFirestore().doc(`users/${uid}`).get()).data();
  await ref.update({
    status: "signedOff",
    signedOffBy: uid,
    signedOffByName:
      typeof profile?.name === "string" && profile.name.trim() ?
        profile.name.trim() :
        null,
    signedOffAt: FieldValue.serverTimestamp(),
    signOffNote: note,
    updatedAt: FieldValue.serverTimestamp(),
  });
  return {id: inspectionId, status: "signedOff"};
});
