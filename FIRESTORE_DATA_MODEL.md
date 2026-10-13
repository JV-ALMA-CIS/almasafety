# JVA Safety — Firestore Data Model

**Status:** Reflects the implemented data model as of the 4-role platform redesign (see PROJECT_CONTEXT.md §12–19) and the subsequent multi-organization membership migration, which moved `organizationId`/role/`workerType`/`trade`/`siteIds`/`supervisorUid` off `users/{uid}` onto a `users/{uid}/memberships/{organizationId}` subcollection so a Site Manager or Foreman can belong to more than one organization at once. Where this document describes fields not yet implemented in code, that is called out explicitly.

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

**Platform roles.** JVA Safety uses exactly four platform authorization
roles: `admin`, `siteManager`, `foreman`, `worker` (PROJECT_CONTEXT.md §12).
`admin` is platform-level and stored as `platformRole` on `users/{uid}` — an
Admin belongs to no organization and holds no membership document. Every
other role (`siteManager`, `foreman`, `worker`) is **per-organization**,
stored as `role` on a `users/{uid}/memberships/{organizationId}` document —
see §2 below — because a Site Manager or Foreman may operate across more
than one organization at once, each with its own role, worker type, site
assignment and status. `role` (per membership) is distinct from `workerType`
(`jvaEmployee` | `contractor` | `subcontractor` | `other` — employment
relationship) and from `trade` (e.g. Electrician, Mason, Plumber — job
discipline, worker-only), both also per-membership. None of these fields may
be written by the client at registration or assignment time — only through
the authorized approval/assignment Cloud Functions.

---

## 2. Top-level collections

### `users/{uid}`  *(implemented — authentication foundation)*
The bridge between Firebase Auth identity and JVA Safety. Read (and streamed)
by `SessionController` after sign-in. Holds identity and account-level state
only — organization membership lives on the subcollection below.

**Top-level, deliberately not `organizations/{orgId}/users/{uid}`.** JVA
Safety uses self-registration + admin approval (PROJECT_CONTEXT.md §15), so a
user creates their profile *before* any organization is known — there is no
organization path to write into at registration time. Operational
collections remain org-scoped, so organization isolation for safety *data*
is still structural; only the identity document sits outside that tree.

```
uid: string
name: string
email: string              // bound to the Firebase Auth token email
phone: string
accountStatus: string      // pending | active | suspended | rejected
platformRole: string?      // "admin" | null — the ONLY value this field ever
                            // carries; every other role lives per-membership
                            // below, never here
createdAt: Timestamp       // server timestamp
updatedAt: Timestamp       // server timestamp
```

`accountStatus` is the **authoritative account-state field**. There is
deliberately no second `active` boolean (PROJECT_CONTEXT.md §19) — two
booleans would eventually disagree. Only `accountStatus == "active"` grants
operational access at all; it gates sign-in and app access globally,
independent of which (or how many) organizations the account belongs to.

`platformRole` is written only for Admin — the sole role with platform-wide
authority not scoped to any single organization (PROJECT_CONTEXT.md §12).
Every other person's role, worker type and trade are per-organization
fields, living on the membership document below, not here.

Client write permissions:

| Operation | Allowed? | Notes |
|---|---|---|
| Create own profile | yes | Only with `accountStatus: "pending"`, own uid as doc id, email matching the auth token, and **no** `platformRole` key. |
| Read own profile | yes | Needed so the pending screen sees approval live. |
| Read another profile | no client read | Reads of other org members' profiles go through Cloud Functions callables (e.g. `listOrganizationUsers`), which apply the caller's own membership role and org/site scope server-side — never a direct Firestore client read. |
| Update `name`, `phone` | yes | Plus a server `updatedAt`. |
| Update `accountStatus`, `uid`, `email`, `createdAt`, `platformRole` | **no** | Admin SDK only, via the approval callables. This is the field set that prevents self-approval and privilege escalation. |
| Delete | no | Rejection is a status, not a deletion — history is preserved. |

### `users/{uid}/memberships/{organizationId}`  *(implemented)*
One document per organization a person belongs to — the source of truth for
"does this person belong to this organization, and with what role/status."
Replaces what used to be a single `organizationId`/`platformRole`/
`workerType`/`trade`/`siteIds`/`supervisorUid` set of fields directly on the
profile: a Site Manager routinely operates several organizations at once,
and a contracted Foreman may be placed into more than one — a scalar field
on the profile cannot represent that.

```
organizationId: string      // == the document id, denormalized for queries
role: string                 // siteManager | foreman | worker — never "admin"; Admin holds no memberships
workerType: string?          // jvaEmployee | contractor | subcontractor | other (typically worker-only)
trade: string?                // e.g. "Electrician", "Mason", "Plumber" (worker-only; never named "role")
siteIds: string[]             // explicit site assignment within this organization; default []
supervisorUid: string?        // for a worker: their supervising Foreman's uid
                                // for a foreman: the Site Manager who approved/manages them
status: string                 // active | suspended — PER ORGANIZATION, independent of accountStatus
approvedAt: Timestamp
approvedBy: string             // uid of the approver
createdAt: Timestamp
updatedAt: Timestamp
```

**`status` here is independent of `accountStatus` on the parent profile.**
`accountStatus` answers "can this person use JVA Safety at all"; a
membership's own `status` answers "can this person currently operate inside
*this* organization." A manager can suspend a Foreman's access to one
organization without touching that Foreman's other memberships or their
account-level status — e.g. Foreman X can be `active` in Organization A,
`suspended` in Organization B, and still `active` in Organization C, all
simultaneously.

A first-ever approval for a person sets `accountStatus: active` on the
profile AND creates their first membership document, in the same operation.
Placing an already-active person into an additional organization only
creates another membership document — it never touches `accountStatus` or
any other membership.

Client write permissions: read is limited to the owning uid or Admin (both
matching the profile's own read scope); write is Admin SDK only, exactly
like the fields it replaced — provisioned exclusively through
`approvePendingAccount` (first membership), `addOrganizationMembership` (an
additional organization for an already-active person),
`createOrganization` (the creating Site Manager's own membership), and
`suspendMembership`/`reinstateMembership` (toggling `status` only) — see
`functions/src/approval_callable.ts`/`organization_callable.ts`.

Approval, membership creation, and status transitions run through
`functions/src/account_approval.ts` and `functions/src/approval_callable.ts`
under the Admin SDK. Who may approve whom is gated by the approver's own
role against the hierarchy in PROJECT_CONTEXT.md §16: Admin approves Site
Managers (account activation; organization is usually left unset — the Site
Manager creates or is later placed into their own organization); a Site
Manager approves Foremen within an organization they belong to; a Foreman
approves Workers within their own assigned site(s). A caller can never
approve or promote themselves, and can never grant a role above their own
authority (e.g. a Foreman cannot approve another Foreman or grant
`siteManager`/`admin`). The very first Admin is created outside this flow
entirely, via a controlled deployment/operator process — see
PROJECT_CONTEXT.md §18.

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

Site Manager/Site Superintendent authority over a site is derived from
holding an active `siteManager` membership in that site's organization
(`users/{uid}/memberships/{organizationId}`), not from a per-site list — a
Site Manager manages every site within each organization they hold that
membership in, and may hold it in more than one organization at once.

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

**Worker → Site → Activity → Required Safety Learning → Completion Status.**
This is the Phase 1 foundation for the LEARN → BRIEF → WORK workflow: before
a worker participates in a Daily Safety Meeting, JVA Safety can determine
whether they have completed the safety learning required for the
Activity/Site they are assigned to. This phase does not yet gate meeting
participation — see `daily_safety_meeting_callable.ts` (unmodified).

### `organizations/{orgId}/safety_learning/{itemId}`
The learning library (videos, courses, visual guides, documents, knowledge
checks) — admin-authored.

```
title: string
organizationId: string
type: string                 // video | course | visualGuide | document | knowledgeCheck
description: string?
contentReference: string     // a single opaque URL/reference — a direct video file URL for `video` items renders as an embedded player when recognisable, else falls back to a link
status: string                // active | inactive
minimumWatchSeconds: number?  // ANY type — see "Minimum engagement-time gate" below
passingScorePercent: number?  // 0-100 — see "Knowledge check gate" below; NOT confined to type == knowledgeCheck
createdAt, createdBy, updatedAt, updatedBy
```

**Minimum engagement-time gate.** ANY learning item (not just `video`) with
a positive `minimumWatchSeconds` cannot be completed until that many
seconds have elapsed, server-side, between the worker's own `startLearning`
call (a real `FieldValue.serverTimestamp()`) and their `completeLearning`
call. This is an honest elapsed-time signal, not verified playback/reading:
this architecture (a direct-URL `video_player` embed or an externally-
opened content link, no hosting/DRM/analytics service) has no way to
confirm actual watch position, scroll position, or reading completion from
the server, so no client-reported value of any of those is ever trusted.
`completeLearning` (`functions/src/worker_learning_callable.ts`) is the
single, callable-only authority on this — a worker can never write
`worker_learning_records.status = "completed"` directly (see
`firestore.rules`' denial below).

### `organizations/{orgId}/safety_learning/{itemId}/knowledge_check_questions/{questionId}`
Multiple-choice knowledge-check questions for one learning item —
admin-authored, `admin`-only, via `addKnowledgeCheckQuestion`/
`updateKnowledgeCheckQuestion`/`removeKnowledgeCheckQuestion`
(`safety_learning_callable.ts`).

```
prompt: string
options: { id: string, text: string }[]  // 2-6 entries, unique ids
correctOptionId: string                   // must match one of options[].id
order: number
createdAt, updatedAt
```

**A knowledge check is NOT confined to `type == "knowledgeCheck"`** — any
learning item (including a `video`) may have questions configured, and a
video with both `minimumWatchSeconds` and questions requires BOTH gates to
pass independently. **A knowledge-check item with ZERO configured
questions has no knowledge-check gate at all** — it completes exactly like
any other item, keeping every item that predates this feature (or simply
has no quiz) unaffected.

**Answer-key security — the reason this is a subcollection, not fields on
the parent document.** `safety_learning/{itemId}` itself is readable by any
org member (unchanged, correct — workers need to see title/type/
description), but `correctOptionId` must never reach a worker. Firestore
rules are document-level, not field-level, so the two requirements cannot
coexist on one document; `firestore.rules` therefore denies EVERY client
read/write of `knowledge_check_questions` outright
(`allow read, write: if false`), and grants access only through two
narrow, audited callables:
- `getKnowledgeCheckQuestions` (`worker_learning_callable.ts`) — worker-
  facing, strips `correctOptionId` before the response is built (there is
  no field for it in that response type at all, not merely an omitted
  one).
- `listKnowledgeCheckQuestions` (`safety_learning_callable.ts`) —
  `admin`-only, returns the full question including `correctOptionId`, for
  the authoring UI. This is the one path in this codebase that ever
  returns a correct answer.

### `organizations/{orgId}/safety_requirements/{requirementId}`
Names which `safety_learning` items are mandatory, and for whom.

```
organizationId: string
name: string
category: string              // free text
risk: string                  // low | medium | high
description: string?
requiredLearningIds: string[] // -> safety_learning
status: string                 // active | inactive
gatesAttendance: bool?         // missing = true. FALLBACK for lessons with no learningSettings entry
requiredBeforeWork: bool?      // missing = false. FALLBACK for lessons with no learningSettings entry
learningSettings: map?         // { [learningId]: { gatesAttendance: bool, requiredBeforeWork: bool } } — per selected lesson, within THIS requirement only
siteId: string?                // scopes this requirement to one site — mutually exclusive with activityId
activityId: string?            // scopes this requirement to one activity (implicitly that activity's own site too)
createdAt, createdBy, updatedAt, updatedBy
```

**Scope resolution rule.** A requirement applies to a worker when:
- both `siteId` and `activityId` are absent (organization-wide — the
  original, still-default behavior; every pre-Phase-1 requirement reads back
  this way, unchanged), OR
- `siteId` matches a site the worker holds an `ActivityAssignment` at, OR
- `activityId` matches an activity the worker holds an `ActivityAssignment`
  for.

A worker's full required-learning set is the de-duplicated union of
`requiredLearningIds` across every ACTIVE, applicable requirement, narrowed
to ACTIVE `safety_learning` items. This is implemented in exactly two
places, deliberately kept in sync by convention rather than shared code:
`SafetyRequirementRepository.watchResolvedRequiredLearning` (Dart, drives
display) and `resolveRequiredLearning`/`workerWorkContext` in
`worker_learning_callable.ts` (TypeScript, the server-side source of truth —
re-derived fresh from the worker's own `ActivityAssignment` documents on
every call, never trusted from the client). At most one of `siteId`/
`activityId` may be set on a requirement; both are validated server-side to
name a real document in the same organization before writing.

**Required vs. pre-work vs. attendance-gating.** Three independent sets,
all resolved per learning id from the requirements that contribute it
(`resolveApplicableRequirementLearningIds`), never inferred after
flattening:
- *required*: every applicable requirement — `resolveRequiredLearningForScope`
  (compliance, `MySafetyLearningScreen`, start/complete checks). Unaffected
  by either flag.
- *attendance-gating*: at least one contributing requirement has
  `gatesAttendance != false` — `resolveAttendanceGatingLearningIds` (the only
  resolver the Daily Safety Meeting gates use).
- *pre-work*: at least one contributing requirement has
  `requiredBeforeWork == true` — `resolvePreWorkLearningIds`. Display only
  (Today's Safety Readiness); gates nothing.

Neither flag implies the other; all four combinations are valid. No
migration: legacy documents read back as gating and not pre-work.

**Per-lesson settings.** `requiredLearningIds` still decides WHICH lessons
belong to a requirement; `learningSettings[learningId]` decides how each
behaves within that requirement (the requirement→learning relationship —
never stored on `safety_learning`, so one lesson can differ between
requirements). A lesson's own entry wins; a lesson with no entry falls back
to the requirement-level flags, so requirements saved before this existed
behave unchanged. The callables only ever write a map covering exactly the
selected lessons (both booleans set), and when an update changes the lesson
list without resending settings, removed lessons' entries are dropped and
added lessons default to `{false, false}`. Flags are resolved per lesson,
per requirement, before ids are aggregated, so a lesson that is gating (or
pre-work) under ANY applicable requirement stays gating (or pre-work).
`getMyTodaysSafetyReadiness` (worker, own data only) and
`getSiteCrewReadiness` (Foreman, own authorized site only, gating learning
only) are read-only callables built on these resolvers.

### `organizations/{orgId}/worker_learning_records/{workerUid}_{learningId}`
Per-worker progress against one required learning item — answers "did this
worker complete this instruction?" Deterministic composite document id
(`${workerUid}_${learningId}`) so at most one record exists per pair and
creation is idempotent.

```
workerUid: string
organizationId: string
learningId: string             // -> safety_learning
status: string                  // assigned | inProgress | completed
assignedAt: Timestamp
startedAt: Timestamp?
completedAt: Timestamp?
knowledgeCheckResult: { passed: boolean, score: number?, totalQuestions: number? }?
```

Materialized lazily: `getMyRequiredLearning` creates an `assigned` record
for each of the caller's currently-required items that has no record yet,
so both the worker's own view and an admin's compliance view are plain
queries over real documents, not runtime resolution re-run per viewer.
`startLearning`/`completeLearning` accept no `workerUid` argument at all —
the acting worker is always the caller's own auth uid, so a worker cannot
create, advance, or complete another worker's record.

**`knowledgeCheckResult` is SERVER-COMPUTED, never client-submitted.** The
client sends only `selectedAnswers: [{questionId, optionId}]` to
`completeLearning`; the server loads the authoritative questions (including
`correctOptionId`) via Admin SDK, grades the submission itself, and writes
this shape verbatim. No `passed`/`score`/`percent`/`completedAt` value the
client might send is ever read. A `questionId` in the submission that
doesn't match a real question for that item is silently ignored — it
affects neither the numerator nor the denominator, so it can neither
inflate a score nor shrink the pass threshold's denominator.

**A failed knowledge check is an expected outcome, not an error.**
`completeLearning` does not throw when grading concludes `passed: false` —
it returns `{status: <unchanged>, knowledgeCheckResult: {passed: false,
score, totalQuestions}}`, the record stays `assigned`/`inProgress`, and the
worker may resubmit (no retry limit in this phase).

`score`/`totalQuestions` are absent on a record completed before this
phase (the old self-attested `{passed: true}` shape, written before any
question or grading logic existed) — `KnowledgeCheckResult.fromMap` (Dart)
and every reader of this field tolerate that shape, so an existing
completed record is never broken by this change.

---

## 4A. Daily learning plan — "Needed today"

### `organizations/{orgId}/daily_learning_plans/{uid}_{date}`  *(implemented, callable-only)*
Each Worker's / Foreman's small plan of the learning they must finish
before **today's** meeting. Clients never read it directly
(`firestore.rules` excludes it); `daily_learning_plan.ts` builds and serves
it to the readiness and meeting callables.

```
uid, date, siteId
byActivity: { [activityId]: learningId | null }  // one per activity they do today
general: learningId | null                       // one site/project/org-wide lesson
updatedAt
```

**The rule.** From "Before meeting" lessons only (per-lesson
`gatesAttendance`), not yet completed: **one per activity the person does
today** (from requirements scoped to that activity) plus **one general
lesson** (from requirements not tied to an activity) — highest requirement
risk first. Everything else is "When you can": still required, and later
days' plans draw from it, one per slot per day. No time budget is assumed.

**Today's work.** A worker: their activity assignments at today's site (or
the meeting's activities if they have none there). A Foreman: their
meeting's activities, or all active activities at their site before it
starts. When a specific meeting is being checked, that meeting is used.

**Stable for the day.** Completing a planned lesson does not pull the
next one into today. Tomorrow's plan is shown today ("Get ahead for
tomorrow") and never repeats today's lessons, so a lesson done the
evening before means nothing is needed in the morning. Picks are
re-checked on every read: if a Site Manager turns "Before meeting" off on a
planned lesson, or deactivates it, the slot is planned again.

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
crewOutcome: string?           // go | goCorrected | stop — the Foreman's crew result, set on completion (null for meetings completed before this existed)
crewOutcomeNote: string?       // required for goCorrected / stop
ahaIds: string[]               // accepted risk_assessments (§7D) covered with the crew
ahasCovered: [{ id, featureOfWork, revision }]  // snapshot of ahaIds when recorded
createdAt, createdBy, updatedAt, updatedBy
```

**Crew result.** `completeDailySafetyMeeting` takes an optional
`crewOutcome` (the app always sends one) using the same three values as a
worker's Pre-Start Check (§6A). A note is required for anything but `go`. A
`stop` notifies every active Site Manager of the organization.

**Risk assessment (AHA) coverage.** The Safety Plan: Foremen cover the
activity hazard analysis with the crew before work begins. The Foreman ticks
each accepted AHA for the meeting's site that was covered
(`updateDailySafetyMeeting` `ahaIds` — each must be an accepted AHA for that
site). `completeDailySafetyMeeting` refuses (`failed-precondition`) while
`ahaIds` is empty and the site has any accepted AHA; a site with none is not
held up.

**Auditability rule:** once `status == "completed"`, the document becomes immutable to clients (no field edits, no deletes) — enforced in `firestore.rules`, not just app logic. Corrections happen via new corrective actions/concerns, never by editing history.

**Safety Learning gate (Phase 2, LEARN → BRIEF → WORK).**
`completeDailySafetyMeeting` refuses to complete the meeting unless the
FOREMAN THEMSELF has a `completed` `worker_learning_records` entry for every
`safety_learning` item named by an ACTIVE `safety_requirement` that applies
to this meeting's own `siteId`/`activityIds` — resolved via
`resolveRequiredLearningForScope` (§4's scope-resolution rule, applied to
the meeting's own site/activities directly, not the foreman's assignments,
since a foreman holds no `ActivityAssignment`). A foreman with nothing
required of them for this meeting is never blocked. This gates only the
foreman completing the record, not individual attendees — attendee-level
gating is out of scope for this phase. The refusal is a `failed-precondition`
naming the outstanding learning item titles, surfaced verbatim to the
foreman by the existing error-banner path (no new client UI was needed).

### `organizations/{orgId}/daily_safety_meetings/{meetingId}/attendance/{workerId}`
```
workerId: string
status: string                 // present | absent
briefedInPerson: boolean       // present without today's lessons done — the Foreman briefed them face to face
briefedLearningTitles: string[]// the lessons that were outstanding (they stay due)
recordedAt: Timestamp
recordedBy: string
```

**Who may be marked present.** Only a worker's outstanding **"Needed
today"** lessons (§4A) block `present`. The Foreman may still mark them
present with `briefedInPerson: true`; that is recorded with the lesson
titles, and the lessons remain due.

---

## 6A. Daily Pre-Start Checks

### `organizations/{orgId}/pre_start_checks/{workerUid}_{date}`  *(implemented)*
A worker's daily "safe to start?" checklist (a Take 5 / Safety Green
Light), one per worker per day. `date` is the server's UTC `YYYY-MM-DD` —
the same day boundary Daily Safety Meetings use.

```
organizationId: string
workerUid: string
workerName: string
siteId: string                 // today's meeting site, else the worker's assigned site
projectId: string?
activityIds: string[]          // the worker's activities at that site
date: string
outcome: string                // go | goCorrected | stop — computed server-side
answers: [
  { questionId, prompt, kind: "standard" | "requirement", risk: string?,
    answer: "yes" | "fixed" | "cannotFix", note: string? }
]
issueCount: number             // answers other than "yes"
meetingId: string?             // the meeting a STOP concern was raised on
concernId: string?             // that concern
submittedAt, createdAt: Timestamp
```

**Questions** are never stored as configuration: `getMyPreStartCheck`
re-derives them on every call, asking only what today's work needs — the
five standard questions, plus **one line per activity the worker does
today that has HIGH-risk requirements** (naming them all), plus **one line
for high-risk requirements not tied to an activity**. Medium/low risk
requirements are left to learning and the meeting. "Today's work" is the
same context as the daily learning plan (§4A). `submitPreStartCheck` requires exactly one
answer per question and a note for every "no".

**Outcome:** any `cannotFix` → `stop`; otherwise any `fixed` →
`goCorrected`; otherwise `go`. A `stop` notifies every active Foreman whose
membership includes the site, and raises a concern (`source:
"preStartCheck"`) on today's meeting at that site — immediately if the
meeting exists, otherwise when `createDailySafetyMeeting` starts it.

**Warn-only.** No other callable reads this collection: a worker who has not
checked in, or who answered STOP, can still be marked present. Once
submitted a check is permanent — a second submission the same day is
refused.

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
kind: string                    // hazard | nearMiss — "could happen" vs "nearly happened"; absent on older docs = hazard
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

The original report content (`kind`, `category`, `description`, `location`,
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
evidenceRequired: boolean        // true when evidenceKinds is non-empty
evidenceKinds: string[]          // photo | confirmation — what the assignee must attach (older docs: none + evidenceRequired true = photo)
evidenceInstructions: string?    // e.g. "Photo of the new guard rail"
assignedToName: string?          // names stored at creation so no screen shows a uid
assignedByName: string?
completionNote: string?          // the assignee's "what I did", sent with submitCorrectiveActionForReview
evidencePhotos: {storagePath, downloadUrl}[]   // ≤5, uploaded under organizations/{orgId}/corrective_actions/{actionId}/
submittedAt: Timestamp?
submittedBy: string?
reviewFeedback: string?          // why a reviewer sent it back; cleared on resubmit
completedBy: string?             // the reviewer who approved it
completedByName: string?
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

## 7A. Incidents

### `organizations/{orgId}/incidents/{incidentId}`  *(implemented, callable-only)*

Something that ACTUALLY happened — someone hurt, something damaged, a spill,
a dangerous event. Distinct from a hazard (could happen) and a near-miss
(`hazards.kind == "nearMiss"`, nearly happened). Created by
`createIncident` (any active member with the site in their `siteIds`), then
`startIncidentInvestigation` → `linkIncidentCorrectiveAction` (any number) →
`closeIncident`, all reviewer-only (`admin`/`siteManager`/`foreman`) — see
`functions/src/incident_callable.ts`.

```
organizationId, projectId, siteId   // projectId looked up from the site
reportedByUid: string               // caller's own uid
type: string                        // injury | propertyDamage | environmental | dangerousOccurrence
description: string
occurredAt: Timestamp               // when it happened; never in the future
location: string?
injuredPersonName: string?          // injury only; dropped for other types
immediateAction: string?            // what was done straight away
photoUrl: string?                   // Storage organizations/{orgId}/incidents/{incidentId}/...
status: string                      // reported | underInvestigation | closed
severity: string?                   // minor | moderate | serious — set by a reviewer when the investigation starts
investigationStartedBy, investigationStartedAt
correctiveActionIds: string[]       // appended by linkIncidentCorrectiveAction
rootCause: string?                  // required to close
closingNotes: string?
closedBy, closedAt
createdAt, createdBy, updatedAt, updatedBy
```

**Reads are restricted** (unlike hazards): only the reporter, a reviewer
role in the same organization, or the System Administrator — an incident can
name an injured person. `incidents` is also excluded from the operational
catch-all read rule for that reason. A corrective action raised from an
incident carries `incidentId` (exactly one of `meetingId`/`hazardId`/
`incidentId` is set). Completing it does **not** close the incident;
`closeIncident` refuses while any of its actions is incomplete, and requires
a root cause. Never deletable.

## 7B. Site inspections (daily inspection, weekly HSE walk-down)

Safety Plan Section 7: daily inspections (Safety Manager, SSHO, Foremen) and
a deficiency log with follow-up. Callables in `functions/src/inspection_callable.ts`;
standard checklists in `functions/src/inspection_templates.ts`.

### `organizations/{orgId}/inspection_templates/{templateId}`  *(callable-only)*

```
organizationId, name, kind            // daily | weekly | environmental | welfare | other
description: string?
defaultKey: string?                   // set on the standard ones (installDefaultInspectionTemplates)
sections: [{title, items: [{id, text, hazardCategory}]}]
status: string                        // active | inactive
createdAt, createdBy, updatedAt, updatedBy
```

### `organizations/{orgId}/inspections/{inspectionId}`  *(callable-only)*

```
organizationId, projectId, siteId, siteName
templateId, templateName, kind
items: [{id, section, text, hazardCategory, result, note, photoUrl, hazardId}]
                                      // a SNAPSHOT of the template; result ok | notOk | na
status: string                        // inProgress | submitted | signedOff
inspectorUid, inspectorName
okCount, notOkCount, naCount          // set on submit
startedAt, submittedAt
signedOffBy, signedOffByName, signedOffAt, signOffNote
```

Start: a Foreman at their own site, or a Site Manager/Admin. Only the
inspector answers and submits; submit needs every item answered and a note on
each "Not OK". **Each "Not OK" becomes a deficiency** — a `hazards` document
with `inspectionId`, `inspectionItemId`, `inspectionName` — tracked through
hazard → corrective action → evidence → approval (the plan's deficiency log:
date identified, description, person responsible, target date, date
resolved). Sign-off: a Site Manager/Admin other than the inspector. Reads:
Admin/Site Manager/Foreman of the organization only (excluded from the
operational catch-all read rule).

## 7C. Weekly employee and monthly supervisory safety meetings

### `organizations/{orgId}/safety_meetings/{meetingId}`  *(callable-only)*
The Safety Plan's weekly employee safety meeting (Thursday 08:00) and monthly
supervisory safety meeting (Thursday 08:30). Separate from
`daily_safety_meetings` (the Foreman's daily toolbox talk, with its learning
gate, crew GO/STOP and "today's meeting"). Recorded once, after the meeting,
by `recordSafetyMeeting` (`safety_meeting_callable.ts`); never updated or
deleted.

```
organizationId: string
kind: string                  // weeklyEmployee | monthlySupervisory
siteId: string?               // null only for a monthly meeting covering every site
siteName: string?
date: string                  // yyyy-MM-dd the meeting was held (not future, ≤31 days back)
topics: string[]              // subjects covered (1–40)
attendeeUids: string[]        // active members of the organization
attendeeNames: map<uid, name> // stored at recording time
otherAttendees: string[]      // people without an account, by name
attendeeCount: number         // attendeeUids + otherAttendees (≥1)
concerns: string[]
notes: string?
facilitatorUid: string        // the caller
facilitatorName: string?
createdAt: Timestamp
```

Who records: weekly — a Foreman at one of their own sites, or a Site
Manager/Admin at any site; monthly — Site Manager/Admin only. Reads:
Admin/Site Manager/Foreman of the organization only (excluded from the
operational catch-all read rule).

## 7D. Risk assessments (Activity Hazard Analyses)

### `organizations/{orgId}/risk_assessments/{id}`  *(callable-only)*
The Safety Plan's AHA (Section 10, Appendix X; EM 385-1-1 Figure 1-2): one per
phase / feature of work (the plan lists "Removals" and "Roof construction").
Written by `risk_assessment_callable.ts`.

```
organizationId, siteId, siteName, projectId
activityIds: string[]          // the site's activities covered; [] = whole site
featureOfWork: string          // e.g. "Removals"
activity, contractNo, location: string?
estimatedStartDate: string?    // yyyy-MM-dd
steps: [{ id, step, hazards: string[], controls: string[] }]   // principal steps, in order
equipment: string[]
inspectionRequirements: string[]
trainingRequirements: string[]
status: string                 // draft | accepted | superseded
revision: number               // 1, 2, ...
previousId: string?            // the revision this one replaces
revisionDraftId: string?       // on an accepted AHA: the revision being prepared
supersededById: string?, supersededAt: Timestamp?
preparedByUid, preparedByName  // whoever last saved the draft
acceptedByUid, acceptedByName, acceptedAt
corName: string?, acceptanceNote: string?
createdAt, updatedAt
```

`saveRiskAssessment` (create/edit a draft) and `reviseRiskAssessment`/
`discardRiskAssessmentDraft`: Site Manager/Admin. `acceptRiskAssessment`: a
Site Manager/Admin other than the preparer, once every step has a hazard and a
control and the three lists are filled in; accepting a revision supersedes
the previous one. An accepted AHA is never edited. Reads: every member of the
organization (operational catch-all); the app shows Workers and Foremen only
the accepted AHAs for their own sites.

### Many sites, many kinds of work

The company runs several sites doing different work (e.g. roofing at Rosslyn
Ridge, other work at the Italian Embassy), so nothing work-specific is
organization-wide:

- **Checklists** (`inspection_templates`) carry `siteIds: string[]` — empty =
  used at every site. `startInspection` refuses a checklist not used at the
  chosen site, and the app only offers the ones that are. The standard daily
  inspection and weekly walk-down are general; roofing checks live in the
  separate "Roof work inspection" (`defaultKey: roof-work-inspection`), to be
  limited to the roofing sites.
- **Checklist library.** `inspection_templates.ts` holds the standard
  checklists: the general ones (`core`: daily inspection, weekly walk-down —
  "Install standard checklists") and a library added one at a time
  (`installDefaultInspectionTemplates` with `keys`; listed by
  `listStandardInspectionTemplates`): Roof work, Scaffolds & ladders,
  Electrical & temporary power, Excavations & trenches, Machinery & cranes,
  Fire prevention & hot work, Demolition & removals, Site welfare &
  sanitation. A company's own checklists are entered with "Paste a list"
  (one item per line, headings start sections, categories guessed) or by
  duplicating an existing checklist.
- **AHAs** (`risk_assessments`) carry `activityIds: string[]` — the site's
  activities they cover; empty = the whole site. The daily meeting offers the
  AHAs for the activities worked that day, and EVERY one of the meeting's
  activities with an applicable accepted AHA must have one covered before it
  can be completed (`activitiesNeedingAha`). A new AHA starts from a blank
  form, a copy of any AHA (accepted or draft, any site), or a starting draft
  from the app's AHA library (general drafts for scaffolding, electrical
  work, excavation, lifting & machinery, hot work and demolition, plus the
  Rosslyn roofing drafts). A company's own AHA is entered with "Paste an
  AHA" (numbered steps, then "Hazards:"/"Controls:", then the three lists).
- **New and finished projects.** A new project only needs its sites and
  activities set up (Projects); general checklists (`siteIds: []`) and the
  weekly/monthly meetings apply straight away, and its AHAs are prepared per
  activity (blank or copied). Switching a project off (`updateProject`
  status `inactive`) switches off its sites; switching it back on does not
  reopen them. Every "choose a site" list for NEW work (reports,
  inspections, meetings, AHAs, checklist "Used at", placing new people)
  offers only active sites; history and filters still show closed ones.

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
| `pre_start_checks` | on creation — never editable |

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
| `users` | self; `admin` for anyone | self: `name`/`phone` only, via direct Firestore write. `accountStatus`/`platformRole`/`createdAt`: **no client writes at all** — only via `account_approval.ts`/`approval_callable.ts` callables. No client create beyond self-registration, no delete. |
| `users/{uid}/memberships` | self; `admin` for anyone | **no client writes at all** — only via the approval/membership callables (`approvePendingAccount`, `addOrganizationMembership`, `createOrganization`, `suspendMembership`/`reinstateMembership`), gated by the approval hierarchy (Admin approves Site Managers; Site Manager approves Foremen in an org they belong to; Foreman approves Workers on their site). |
| `organizations` | members; `admin` for any | create: `siteManager` (creating their own organization) or `admin`. update: `siteManager` for the organization(s) they manage; `admin` for any — Admin retains platform-level intervention rights (reassign, suspend, manage) over every organization |
| `projects`, `sites`, `activities` | org members | `siteManager` for the organization(s) they manage; `admin` for any |
| `workers` *(not yet implemented)* | org members | create/approve: `foreman` for their own assigned site(s); `siteManager`/`admin` for any worker in an organization they manage/any organization respectively |
| `safety_learning` (library), `safety_requirements` | org members | `admin` only — platform-level, company-wide library, not delegated to Site Managers |
| `safety_learning/*/knowledge_check_questions` | **no client, admin included** (`allow read, write: if false`) | `admin` only, and ONLY via callables — `addKnowledgeCheckQuestion`/`updateKnowledgeCheckQuestion`/`removeKnowledgeCheckQuestion` to write, `listKnowledgeCheckQuestions` (full, including `correctOptionId`) or `getKnowledgeCheckQuestions` (worker-safe, `correctOptionId` stripped) to read — never a direct Firestore read/write by any client, ever |
| `worker_learning_records` | the owning worker (`workerUid == uid`), `siteManager`, `admin` — deliberately NOT `foreman` (compliance-viewing across the whole organization is a `siteManager`/`admin` responsibility) | the worker themself, and only their own record, via `startLearning`/`completeLearning`/`getMyRequiredLearning` (no `workerUid` argument exists on any of them) |
| `safety_meeting_points` (library) | org members | `admin` only — platform-level, company-wide library |
| `pre_start_checks` | the owning worker, a `foreman` whose `siteIds` include the check's site, `siteManager`, `admin` | the worker themself, and only their own check for today, via `submitPreStartCheck` (no `workerUid` argument); **no client writes, no updates, no delete** |
| `daily_safety_meetings` | org members | `foreman` create/update while `draft`, for their own assigned site(s) only; **no client writes once `completed`** |
| `daily_safety_meetings/*/attendance/*` | org members | `foreman`, only while parent meeting is `draft`, only for workers on their own site |
| `hazards` | org members | any active org member with the hazard's own `siteId` in their `siteIds` can **create**; acknowledge/link a corrective action/close: `foreman` for their own site, or `siteManager`/`admin` for the organization(s) they manage/any organization; **no client writes once `closed`**; original report content (`category`/`description`/`location`/`photoUrl`) is never client-editable after creation, even before closure |
| `corrective_actions` | org members | create: the originating meeting's own `foreman` only, while that meeting is `inProgress` (hazard-originated actions: reuse the same reviewer set that can act on the hazard); status update: `foreman` (their own site), `siteManager` (their organization(s)), or `admin` (any); **no client writes once `completed`**; no delete |
| `safety_alerts` | org members | create / acknowledge / resolve: `foreman` for their own assigned site(s) only (they are on the ground with the crew); `siteManager` for any site in the organization(s) they manage; `admin` for any |
| `notifications` | recipient only | Cloud Functions only (no client writes) |

"`foreman`+" means `foreman`, `siteManager`, `admin`. "`siteManager`+" means `siteManager`, `admin`.

This table is the basis for the enforced authorization in `functions/src/*_callable.ts` and `firestore.rules` — see those files for the implementation.
