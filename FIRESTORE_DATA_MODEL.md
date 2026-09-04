# JVA Safety — Firestore Data Model

**Status:** Reflects the implemented data model as of the 4-role platform redesign (see PROJECT_CONTEXT.md §12–19). Where this document describes fields not yet implemented in code, that is called out explicitly.

Collections are nested under `organizations/{organizationId}/...` so organization isolation is enforced by path structure, matching `firestore.rules`. Document IDs are Firestore auto-IDs; entities reference each other via explicit ID fields.

---

## 1. Conventions

Every document in an operational collection carries:

```
organizationId: string   // redundant with path, kept for defense-in-depth and collectionGroup queries
projectId: string?       // where applicable
siteId: string?          // where applicable
createdAt: Timestamp
createdBy: string        // uid
updatedAt: Timestamp
updatedBy: string        // uid
```

Documents that represent **auditable safety records** (see §9) additionally never allow client-side field mutation after a `status`/`completedAt` transition marks them closed — enforced in security rules, not just convention.

**Platform roles.** JVA Safety uses exactly four platform authorization roles,
stored as `platformRole` on `users/{uid}`: `admin`, `siteManager`, `foreman`,
`worker` (PROJECT_CONTEXT.md §12). `platformRole` is distinct from
`workerType` (`jvaEmployee` | `contractor` | `subcontractor` | `other` —
employment relationship) and from `trade` (e.g. Electrician, Mason, Plumber —
job discipline, worker-only). None of these three fields may be written by
the client at registration time or at any time thereafter except through the
authorized approval/assignment Cloud Functions — see §2 `users/{uid}` below.

---

## 2. Top-level collections

### `users/{uid}`  *(implemented — authentication foundation)*
The bridge between Firebase Auth identity and JVA Safety. Read (and streamed)
by `SessionController` after sign-in.

**Top-level, deliberately not `organizations/{orgId}/users/{uid}`.** JVA
Safety uses self-registration + admin approval (PROJECT_CONTEXT.md §15), so a
user creates their profile *before* any organization is known — there is no
organization path to write into at registration time. `organizationId` is
therefore a nullable field assigned at approval rather than part of the
document path. Operational collections remain org-scoped, so organization
isolation for safety *data* is still structural; only the identity document
sits outside that tree.

```
uid: string
organizationId: string?    // null until an approver assigns one
name: string
email: string              // bound to the Firebase Auth token email
phone: string
accountStatus: string      // pending | active | suspended | rejected
platformRole: string?      // admin | siteManager | foreman | worker — null until assigned
workerType: string?        // jvaEmployee | contractor | subcontractor | other (typically worker-only)
trade: string?             // e.g. "Electrician", "Mason", "Plumber" (worker-only; never named "role")
siteIds: string[]          // explicit site assignment; default []
supervisorUid: string?     // for a worker: their supervising Foreman's uid
                            // for a foreman: the Site Manager who approved/manages them
createdAt: Timestamp       // server timestamp
updatedAt: Timestamp       // server timestamp
approvedAt: Timestamp?     // set by the approval authority only
approvedBy: string?        // uid of the approver
```

`accountStatus` is the **authoritative account-state field**. There is
deliberately no second `active` boolean (PROJECT_CONTEXT.md §19) — two
booleans would eventually disagree. Only `accountStatus == "active"` grants
operational access.

`platformRole` is the sole authorization-role field and carries exactly four
values (§12 above). `trade` is a separate, worker-only field describing job
discipline and must never be conflated with `platformRole` or stored under a
field literally named `role`.

Client write permissions:

| Operation | Allowed? | Notes |
|---|---|---|
| Create own profile | yes | Only with `accountStatus: "pending"`, own uid as doc id, email matching the auth token, and **no** `organizationId`/`approvedAt`/`approvedBy`/`platformRole`/`workerType`/`trade`/`siteIds`/`supervisorUid` keys. |
| Read own profile | yes | Needed so the pending screen sees approval live. |
| Read another profile | no client read | Reads of other org members' profiles go through Cloud Functions callables (e.g. `listOrganizationUsers`), which apply the caller's `platformRole` and org/site scope server-side — never a direct Firestore client read. |
| Update `name`, `phone` | yes | Plus a server `updatedAt`. |
| Update `accountStatus`, `organizationId`, `approvedAt`, `approvedBy`, `uid`, `email`, `createdAt`, `platformRole`, `workerType`, `trade`, `siteIds`, `supervisorUid` | **no** | Admin SDK only, via the approval/assignment callables. This is the field set that prevents self-approval and privilege escalation. |
| Delete | no | Rejection is a status, not a deletion — history is preserved. |

Approval, organization assignment, `platformRole` assignment, and status
transitions run through `functions/src/account_approval.ts` under the Admin
SDK. Who may approve whom is gated by the approver's own `platformRole`
against the hierarchy in PROJECT_CONTEXT.md §16: Admin approves Site
Managers; a Site Manager approves Foremen within the organization(s) they
manage; a Foreman approves Workers within their own assigned site(s). A
caller can never approve or promote themselves, and can never grant a
`platformRole` above their own authority (e.g. a Foreman cannot approve
another Foreman or grant `siteManager`/`admin`). The very first Admin is
created outside this flow entirely, via a controlled deployment/operator
process — see PROJECT_CONTEXT.md §18.

### `organizations/{organizationId}`
```
name: string
country: string            // e.g. "KE", "IT" — supports future multi-country per PROJECT_CONTEXT.md
active: boolean
createdAt, createdBy, updatedAt, updatedBy
```

### `audit_logs/{logId}`
Append-only, Admin-SDK-only writes (which bypass rules). Captures privileged actions — currently account approvals, rejections, suspensions and reinstatements; later record closures and deletions. Client reads are denied outright until roles exist to identify an administrator.

```
organizationId: string
actorUid: string
action: string              // e.g. "meeting.completed", "user.roleChanged"
targetCollection: string
targetDocId: string
metadata: map
createdAt: Timestamp
```

---

## 3. Organization structure

See §2 — user profiles are a **top-level** collection, not an
organization subcollection, under the self-registration model.

### `organizations/{orgId}/projects/{projectId}`
```
name: string
organizationId: string
status: string              // active | onHold | closed
createdAt, createdBy, updatedAt, updatedBy
```

### `organizations/{orgId}/sites/{siteId}`
```
name: string
organizationId: string
projectId: string
address: string?
status: string               // active | closed
foremanUids: string[]        // Foremen/Site Supervisors assigned to this site
createdAt, createdBy, updatedAt, updatedBy
```

Site Manager/Site Superintendent authority over a site is derived from their
`organizationId` match, not from a per-site list — a Site Manager manages
every site within the organization(s) they manage.

### `organizations/{orgId}/activities/{activityId}`
Activity *types* performed on sites (e.g. Roofing, Electrical Works) — the link between work being done and required Safety Meeting Points / Safety Learning.

```
name: string
organizationId: string
siteId: string
projectId: string
requiredSafetyLearningIds: string[]   // -> safety_learning
recommendedMeetingPointIds: string[]  // -> safety_meeting_points, default suggestion set
status: string                        // active | completed
createdAt, createdBy, updatedAt, updatedBy
```

### `organizations/{orgId}/workers/{workerId}`  *(not yet implemented — design reference only)*
Worker roster entries — distinct from `users/{uid}` because not every worker necessarily has app login credentials (some may be registered by a Foreman without self-service access initially).

```
organizationId: string
siteId: string
projectId: string
uid: string?                // linked users/{uid} if this worker has app access
fullName: string
trade: string                // e.g. "Mason", "Electrician", "Plumber" — job discipline, NOT an authorization role
workerType: string           // jvaEmployee | contractor | subcontractor | other
supervisorUid: string        // the Foreman/Site Supervisor who registered/manages this worker
activityIds: string[]        // -> activities this worker is assigned to
phone: string?
active: boolean
createdAt, createdBy, updatedAt, updatedBy
```

**Never name this field `role`.** A worker's trade is a job discipline, not
a platform authorization role — the platform role for every document in this
collection that has a linked `uid` is `worker`, stored on the corresponding
`users/{uid}.platformRole`, never here.

---

## 4. Safety Learning

### `organizations/{orgId}/safety_learning/{itemId}`
The learning library (videos, courses, knowledge checks) — admin-authored.

```
title: string
organizationId: string
type: string                 // video | course | document | knowledgeCheck
description: string
mediaUrl: string?            // Storage path
applicableTrades: string[]?  // trade labels this applies to, e.g. ["Electrician", "Mason"] — never platform roles
active: boolean
createdAt, createdBy, updatedAt, updatedBy
```

### `organizations/{orgId}/safety_learning/{itemId}/completions/{workerId}`
Per-worker completion record — answers "did this worker receive this instruction?" (PROJECT_CONTEXT.md §11).

```
workerId: string
organizationId: string
completedAt: Timestamp
knowledgeCheckScore: number?
status: string                // notStarted | inProgress | completed
```

---

## 5. Safety Meeting Points

### `organizations/{orgId}/safety_meeting_points/{pointId}`
The admin-managed Safety Point Library (PROJECT_CONTEXT.md §4).

```
title: string                 // e.g. "Working at Height"
organizationId: string
category: string?
icon: string?                 // for visual/low-literacy presentation
applicableActivityIds: string[]?  // default recommendation linkage
active: boolean
createdAt, createdBy, updatedAt, updatedBy
```

---

## 6. Daily Safety Meetings

### `organizations/{orgId}/daily_safety_meetings/{meetingId}`
The structured record the foreman creates *after* physically conducting the meeting. This is the auditable safety record described in PROJECT_CONTEXT.md §6.

```
organizationId: string
projectId: string
siteId: string
activityIds: string[]
date: string                  // YYYY-MM-DD, for simple querying
startTime: Timestamp?
endTime: Timestamp?
foremanUid: string             // the conducting Foreman/Site Supervisor (implemented in code as `foremanId`)
meetingPointsCovered: [
  { pointId: string, title: string, covered: boolean }
]
siteSpecificPoints: string[]  // free-text points added by foreman, kept short
concerns: [
  { description: string, raisedBy: string? }
]
correctiveActionIds: string[]  // -> corrective_actions created from this meeting
status: string                 // draft | completed
completedAt: Timestamp?
createdAt, createdBy, updatedAt, updatedBy
```

**Auditability rule:** once `status == "completed"`, the document becomes immutable to clients (no field edits, no deletes) — enforced in `firestore.rules`, not just app logic. Corrections happen via new corrective actions/concerns, never by editing history.

### `organizations/{orgId}/daily_safety_meetings/{meetingId}/attendance/{workerId}`
```
workerId: string
present: boolean
recordedAt: Timestamp
```

---

## 7. Hazards & Corrective Actions

### `organizations/{orgId}/hazards/{hazardId}`
Worker-facing hazard report (PROJECT_CONTEXT.md §24). Mirrors the
`corrective_actions` creation pattern below: `organizationId` is derived
server-side from the caller's own profile, `siteId` is re-validated against
the reporting worker's own `siteIds` (reusing
`daily_safety_meeting_callable.ts`'s `requireWorkerAtSite` pattern), and
`projectId` is looked up server-side from the site document — never trusted
from the client request.

```
organizationId: string
projectId: string              // looked up server-side from the site document
siteId: string                 // re-validated: must be in the reporter's own siteIds
reportedByUid: string           // caller's own uid; never a request argument
category: string                // workingAtHeight | electrical | equipment | ppe | housekeeping | environment | chemical | fire | other
description: string
location: string?               // free text (e.g. "East wing, 3rd floor"); geopoint deferred
photoUrl: string?                // Storage path under organizations/{orgId}/hazards/{hazardId}/..., optional
status: string                    // reported | acknowledged | correctiveActionCreated | closed
correctiveActionId: string?       // set once a corrective action is raised from this hazard
acknowledgedBy: string?           // uid of the reviewer who acknowledged it
acknowledgedAt: Timestamp?
closedBy: string?
closedAt: Timestamp?
createdAt, createdBy, updatedAt, updatedBy
```

Lifecycle: `reported → acknowledged → correctiveActionCreated → closed`.
`acknowledged` mirrors `safety_alerts`' own acknowledge/resolve split — a
reviewer can signal "seen, triaging" before committing to a formal corrective
action. A hazard does **not** require a corrective action to close: a
reviewer may set `status: closed` directly (no `correctiveActionId`) when no
remediation is warranted — e.g. the hazard is a duplicate or was already
resolved by observation. Once `correctiveActionCreated`, the linked
`corrective_actions` document's own status (`open | inProgress | completed |
overdue`) is the authoritative remediation-progress record; the hazard itself
does not duplicate `inProgress`/`overdue`, to avoid two competing status
sources for the same remediation.

The original report content (`category`, `description`, `location`,
`photoUrl`) is immutable to clients from the moment of creation — only the
status-transition fields above are ever written by later callables, matching
how a completed meeting's concerns are never edited after the fact.

**Auditability rule:** once `status == "closed"`, the document becomes
immutable to clients (no field edits, no deletes) — enforced in
`firestore.rules`, not just convention.

**Photo-upload sequencing — decided.** The client pre-allocates the hazard's
document id locally (`FirebaseFirestore.collection(hazardsCollection).doc()`
generates an id without writing anything), uploads the photo directly to
Cloud Storage at `organizations/{orgId}/hazards/{hazardId}/{fileName}` using
that id — `StorageService.orgRef()` already documents exactly this path
shape — and only THEN calls `createHazard` with both the pre-allocated id and
the resulting Storage download URL as `photoUrl`. `createHazard` accepts the
id as an argument (unlike every other callable in this codebase, which lets
Firestore mint the id) specifically so the photo can be uploaded first
against a known path; the callable still performs every other validation
(site membership, organization membership) before writing, so a caller
cannot use the pre-allocated id to overwrite an existing hazard — creation
fails outright if a document already exists at that id. Uploading is
low-friction by design (`storage.rules` already permits any org member to
write under their own organization's path, ≤25MB), matching this feature's
field-usability requirement; there is no separate attach-photo callable.

### `organizations/{orgId}/corrective_actions/{actionId}`
```
organizationId: string
projectId: string
siteId: string
meetingId: string?              // originating meeting, if raised from one
concernId: string?              // originating meeting concern, if any (mutually exclusive with hazardId)
hazardId: string?               // originating hazard, if any (mutually exclusive with concernId)
title: string
description: string
assignedTo: string               // uid; never the creator's own uid
assignedBy: string                // uid of the creator
dueDate: Timestamp
evidenceRequired: boolean
status: string                    // open | inProgress | completed | overdue
completedAt: Timestamp?
createdAt, createdBy, updatedAt, updatedBy
```

**Reciprocal link:** creating a corrective action from a hazard sets
`corrective_actions.hazardId` on the new document AND
`hazards.correctiveActionId` + `hazards.status = "correctiveActionCreated"`
on the originating hazard, in the same write path — matching how
`daily_safety_meetings.correctiveActionIds` is kept in sync when a meeting
concern produces one. A corrective action names at most one origin
(`meetingId`+`concernId`, or `hazardId`) — never both.

**Auditability rule:** once `status == "completed"`, immutable to clients — reopening (if ever needed) happens via a new action referencing the old one, not by editing the closed record.

---

## 8. Safety Alerts & Notifications

### `organizations/{orgId}/safety_alerts/{alertId}`
Management-issued alerts (PROJECT_CONTEXT.md §19).

```
organizationId: string
title: string
message: string
severity: string               // info | warning | emergency
affectedSiteIds: string[]
issuedByUid: string
active: boolean
createdAt, createdBy, updatedAt, updatedBy
```

### `organizations/{orgId}/notifications/{notificationId}`
Per-user delivered notification records (FCM payload mirror for in-app history), fanned out by a Cloud Function when an alert is issued — not directly client-written.

```
organizationId: string
recipientUid: string
title: string
body: string
relatedAlertId: string?
read: boolean
createdAt: Timestamp
```

---

## 9. Auditability summary

Records that become immutable once completed/closed (client-side):

| Collection | Immutability trigger |
|---|---|
| `daily_safety_meetings` | `status == "completed"` |
| `corrective_actions` | `status == "completed"` |
| `hazards` | `status == "closed"` |

All other collections remain editable by their designated writer roles (§10) since they represent living configuration (safety learning library, meeting point library) or in-progress data (open hazards, draft meetings).

---

## 10. Per-collection write permissions (informs firestore.rules)

All writes to operational collections go through Cloud Functions callables
under the Admin SDK; `firestore.rules` denies client writes to these
collections outright (`allow write: if false`) and enforces read scope by
organization membership. The table below documents the authorization each
callable enforces server-side — the actual security boundary — using the
4-role model (`admin` / `siteManager` / `foreman` / `worker`).

| Collection | Read | Write (enforced in Cloud Functions callables) |
|---|---|---|
| `users` | self; `siteManager`+ for others in an organization they manage; `admin` for anyone | self: `name`/`phone` only, via direct Firestore write. `organizationId`/`platformRole`/`workerType`/`trade`/`siteIds`/`supervisorUid`/`accountStatus`/`approvedAt`/`approvedBy`/`createdAt`: **no client writes at all** — only via `account_approval.ts` callables, gated by the approval hierarchy (Admin approves Site Managers; Site Manager approves Foremen in their org; Foreman approves Workers on their site). No client create beyond self-registration, no delete. |
| `organizations` | members; `admin` for any | create: `siteManager` (creating their own organization) or `admin`. update: `siteManager` for the organization(s) they manage; `admin` for any — Admin retains platform-level intervention rights (reassign, suspend, manage) over every organization |
| `projects`, `sites`, `activities` | org members | `siteManager` for the organization(s) they manage; `admin` for any |
| `workers` *(not yet implemented)* | org members | create/approve: `foreman` for their own assigned site(s); `siteManager`/`admin` for any worker in an organization they manage/any organization respectively |
| `safety_learning` (library) | org members | `admin` only — platform-level, company-wide library, not delegated to Site Managers |
| `safety_learning/*/completions/{workerId}` | org members | the worker themself (`uid == workerId`) or `foreman`+ for workers on their site |
| `safety_meeting_points` (library) | org members | `admin` only — platform-level, company-wide library |
| `daily_safety_meetings` | org members | `foreman` create/update while `draft`, for their own assigned site(s) only; **no client writes once `completed`** |
| `daily_safety_meetings/*/attendance/*` | org members | `foreman`, only while parent meeting is `draft`, only for workers on their own site |
| `hazards` | org members | any active org member with the hazard's own `siteId` in their `siteIds` can **create**; acknowledge/link a corrective action/close: `foreman` for their own site, or `siteManager`/`admin` for the organization(s) they manage/any organization; **no client writes once `closed`**; original report content (`category`/`description`/`location`/`photoUrl`) is never client-editable after creation, even before closure |
| `corrective_actions` | org members | create: the originating meeting's own `foreman` only, while that meeting is `inProgress` (hazard-originated actions: reuse the same reviewer set that can act on the hazard); status update: `foreman` (their own site), `siteManager` (their organization(s)), or `admin` (any); **no client writes once `completed`**; no delete |
| `safety_alerts` | org members | `siteManager`+ (`siteManager` for the organization(s) they manage; `admin` for any) |
| `notifications` | recipient only | Cloud Functions only (no client writes) |

"`foreman`+" means `foreman`, `siteManager`, `admin`. "`siteManager`+" means `siteManager`, `admin`.

This table is the basis for the enforced authorization in `functions/src/*_callable.ts` and `firestore.rules` — see those files for the implementation.
