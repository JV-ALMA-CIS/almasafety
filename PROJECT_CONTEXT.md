JVA Safety Platform — Project Context

Organization: JV ALMA CIS
Platform: JVA Safety
Technology: Flutter + Firebase + Gemini
Primary market: Kenya
Current status: Core operational features implemented — see §40 for the current implemented/not-yet-implemented breakdown. Role model redesigned to 4 platform roles — see §12–19.
Last updated: 3 September 2026

1. Product Definition

JVA Safety is a worker-centered digital safety management platform for construction and facility-management operations.

The platform connects:

Projects → Sites → Activities → Workers → Safety Requirements → Safety Learning → Daily Safety Meetings → Hazards → Corrective Actions → Evidence → Analytics

JVA Safety is not primarily a document-management system.

The existing AlmaWorks platform already has a Safety section focused on Quality & Safety documentation.

JVA Safety is intended to provide a much deeper operational understanding of safety at the worker/site level.

Workforce Model

JVA Safety is designed for a mixed workforce consisting of:

JV ALMA CIS employees (Admins, Site Managers/Superintendents, Foremen/Site Supervisors)
Contractors
Subcontractors
Skilled workers (Masons, Electricians, Plumbers, etc.)
General site workers

Many field workers will not be JV ALMA CIS employees.

Examples include:

Masons
Electricians
Plumbers
Carpenters
Roofers
Painters
Welders
General workers
Other specialist contractors

Therefore, JVA Safety must support external and contracted workers without giving them unnecessary organizational privileges.

A person's employment relationship (`workerType`), their trade (`trade`), and their platform authorization role (`platformRole`) are three separate concepts. See §12–19.

For example:

A contractor can hold the platform role Foreman/Site Supervisor.

A JV ALMA CIS employee can hold the platform role Site Manager/Site Superintendent.

A subcontracted electrician can hold the platform role Worker, with `trade = Electrician`.

2. Core Product Principle

JVA Safety follows:

LEARN → BRIEF → WORK → REPORT → CORRECT → PROVE

Workers learn the safety requirements relevant to their work.

Foremen conduct the physical Daily Safety Meeting.

JVA Safety structures and records the meeting.

Workers and supervisors can report hazards and concerns.

Corrective actions are tracked.

The platform preserves the resulting safety evidence.

3. Daily Safety Meeting — Critical Product Decision

JVA Safety does NOT conduct the Daily Safety Meeting.

The physical meeting is conducted by the site foreman every morning before daily work begins.

The foreman communicates with workers using whatever language is appropriate.

Possible languages include:

English
Kiswahili
Local Kenyan languages
A combination of languages

The platform does not need to record the spoken meeting.

The platform provides Safety Meeting Points that act as structured prompts for the foreman.

Example:

Roofing

Recommended Safety Meeting Points:

Working at Height
Fall Protection
Ladder Safety
PPE
Weather Conditions
Material Handling

The foreman physically explains these topics to the workers.

The foreman then records the outcome in JVA Safety.

### 4. Safety Meeting Point Principle

Safety Meeting Points are **structured prompts from an administrative Safety Meeting Point Library**, not scripts.

The purpose of the library is to provide standardized safety topics that can be reused across projects and sites while still allowing the foreman to decide what is relevant to the day's work.

#### Safety Meeting Point Library

The official Safety Meeting Point Library is managed by the **Admin** platform role.

Admin accesses the library through:

**Administration → Organizations → (select organization) → Safety Meeting Points**

Admin may manage the library for any organization, since it is a platform-level, company-wide administrative responsibility — the Safety Meeting Point Library is not delegated to Site Managers.

Admin can:

* Create safety meeting points
* Edit safety meeting points
* Categorize safety meeting points
* Define applicable activities
* Define applicable risks
* Activate/deactivate safety meeting points
* Maintain the organization's approved safety content

Examples:

* Working at Height
* Fall Protection
* Ladder Safety
* PPE
* Electrical Safety
* Manual Handling
* Weather Conditions
* Material Handling
* Housekeeping
* Equipment Safety

The library is the source of approved safety meeting points used during Daily Safety Meetings.

#### Foreman Responsibilities

The Foreman is the **operational user of Safety Meeting Points**, not the administrator of the library.

Before a meeting, JVA Safety recommends relevant points based on the site's activities, safety requirements, previous concerns, alerts, and other available information.

The Foreman can:

* Accept recommended points
* Remove irrelevant recommended points
* Add other existing Safety Meeting Points from the library
* Mark points as covered
* Record concerns
* Record attendance
* Record corrective actions
* Complete the meeting

The Foreman **does not create new permanent Safety Meeting Point Library content during the meeting**.

If the Foreman identifies a safety topic that does not exist in the library, the appropriate workflow is to record it as a **site concern / meeting concern** or other appropriate structured meeting information. An authorized administrator can subsequently create an official Safety Meeting Point in the library if the topic should become reusable.

Therefore:

**Administrator → manages the Safety Meeting Point Library**

**Foreman → uses the library to conduct and record the Daily Safety Meeting**

This separation prevents field meetings from becoming uncontrolled safety-content authoring sessions while still allowing Foremen to adapt the meeting to actual site conditions.

#### Safety Meeting Points vs Meeting Records

The Safety Meeting Point Library contains reusable safety content.

The Daily Safety Meeting contains the **actual record of what happened on that particular day**.

For example:

Library:

> Working at Height

Daily Meeting:

> Working at Height — Covered

The library point is reusable content. The meeting record is evidence that the topic was covered during a specific meeting.

A library point must never be modified merely because it was used in a particular meeting.

5. Multilingual Safety Principle

Kenyan construction sites may have workers who do not understand English.

Therefore:

Do not require the physical meeting to be conducted in English.
Do not require audio recording.
Do not depend on speech-to-text for the core meeting workflow.
Do not attempt to translate the actual meeting conversation.
Do not make language a mandatory part of the safety evidence.

The platform records the structured safety information that was covered.

Example:

The meeting may be conducted entirely in Kiswahili.

JVA Safety records:

Working at Height — Covered

This allows management to understand the safety record without needing to understand the spoken language.

Visual Safety Meeting Points and icons should be considered to make the system easier for foremen to use.

6. Daily Safety Meeting Workflow

#### 6.1 Administrative Preparation

Authorized administrators maintain the organization's Safety Meeting Point Library.

They create and maintain approved safety topics that can be used across sites and activities.

Administrators do **not** conduct the physical Daily Safety Meeting.

#### 6.2 Before the Meeting

JVA Safety prepares a meeting workspace for the Foreman based on:

* Site
* Project
* Today's activities
* Relevant safety requirements
* Previous safety concerns
* Open corrective actions
* Relevant safety alerts
* Active Safety Meeting Points from the organization's library

The system may recommend Safety Meeting Points relevant to the day's activities.

#### 6.3 Physical Meeting

The Foreman gathers the workers and conducts the physical meeting.

The meeting may be conducted in:

* English
* Kiswahili
* A local Kenyan language
* Multiple languages

The platform does not record the conversation.

The Foreman uses the Safety Meeting Points as prompts and explains the relevant topics to the crew in the appropriate language.

#### 6.4 Recording the Meeting

After or during the physical meeting, the Foreman records structured information in JVA Safety:

* Activities discussed
* Safety Meeting Points covered
* Attendance
* Safety concerns
* Corrective actions
* Other available structured meeting information

The Foreman should not be required to write a lengthy narrative report.

#### 6.5 Adding Safety Meeting Points

The Foreman can add an existing active Safety Meeting Point from the organization's library if it was not included in the initial recommendations.

The Foreman cannot create a new permanent Safety Meeting Point Library entry from the Daily Safety Meeting screen.

If a new safety topic is identified that should become part of the organization's standard library, it should be raised as a concern or other appropriate structured information and subsequently reviewed by an authorized administrator.

#### 6.6 Meeting Completion

The Foreman confirms completion after the required meeting information has been recorded.

At minimum, the meeting must contain:

* At least one activity
* At least one Safety Meeting Point

Additional required information may include attendance depending on the final meeting-completion rules.

#### 6.7 System-Generated Meeting Record

JVA Safety creates a structured record containing:

* Meeting ID
* Organization
* Project
* Site
* Date
* Start/end time
* Foreman
* Activities
* Meeting Points covered
* Attendance
* Concerns
* Corrective actions
* Confirmation information

This record is the authoritative operational evidence of the meeting.

#### 6.8 Management/Admin View

Admin and Site Manager/Site Superintendent users do not need to participate in the Foreman's live meeting workspace.

Their purpose is to **review the resulting meeting record and summary**.

The management-facing Daily Safety Meeting view should therefore present meeting cards containing information such as:

* Site
* Project
* Date
* Foreman
* Activities discussed
* Attendance
* Safety Meeting Points covered
* Concerns
* Corrective actions
* Completion status
* Meeting summary

The Foreman uses the **Meeting Workspace** to conduct and record the meeting.

Management uses the **Meeting History / Meeting Summary** experience to review what occurred.

These are different user experiences over the same underlying Daily Safety Meeting record.

7. Meeting Summary

The foreman should not have to write a meeting report.

The system generates the summary from verified structured information.

Example:

Daily Safety Meeting Summary

Site: Rosslyn

Date: 17 August 2026

Activity: Roofing

Conducted by: Site Foreman

Attendance: 17/18 workers

Topics covered:

Working at Height
Fall Protection
PPE
Ladder Safety
Weather Conditions

Concern:

Unstable ladder at east wing.

Action:

Ladder to be removed and replaced before use.

The summary may eventually be enhanced using Gemini.

However, Gemini must only summarize recorded information.

It must never invent meeting events or claims.

8. Safety Learning

JVA Safety contains a Safety Learning Library.

Learning items can include:

Safety videos
Short courses
Visual guides
Safety topics
Knowledge checks
Safety documents

Examples:

Working at Height
Electrical Safety
PPE
Ladder Safety
Fall Protection
Manual Handling
Fire Safety
Site Induction
9. Training Assignment Principle

Workers should receive safety learning relevant to:

Worker → Role → Site → Activity → Risk

Example:

John:

Worker → Rosslyn → Mason → Roofing

Required learning may include:

Site Induction
PPE
Working at Height
Ladder Safety
Manual Handling

Peter:

Worker → Ambassadors → Electrician → Electrical Works

Required learning may include:

Site Induction
PPE
Electrical Safety
Electrical Hazards
Working at Height if applicable

Training requirements must eventually be configurable rather than hardcoded into Flutter.

10. Safety Learning Completion

A worker should normally complete required learning before beginning the relevant activity.

Example:

Working at Height

Video → Knowledge Check → Completion

The platform records:

Worker
Course
Completion date
Completion status
Knowledge-check result where applicable

Training records are separate from Daily Safety Meeting attendance.

11. Daily Meeting vs Training

These are two different records.

Training Record

Answers:

Did the worker receive the relevant safety instruction?

Example:

John → Working at Height → Completed 17 Aug 2026

Daily Safety Meeting Record

Answers:

Did the worker participate in today's safety briefing?

Example:

John → Rosslyn → 17 Aug 2026 → Roofing → Attended

One must never be treated as a substitute for the other.

12. Platform Role Model

JVA Safety uses exactly four platform authorization roles (`platformRole`):

1. **Admin** — company software/office administrator. Platform-level administration: creates/manages organizations, approves and manages Site Managers/Site Superintendents, manages users/permissions/account status, manages the Safety Learning library and Safety Meeting Point library company-wide, views organization-wide safety information/reports/analytics, audits and can intervene in any organization's account. Admin is not responsible for day-to-day worker approval or conducting site safety meetings.

2. **Site Manager / Site Superintendent** (`siteManager`) — a JV ALMA CIS employee working in the field. Can create an organization (becoming its operational manager) and manages the organization(s) they created or are assigned to: creates/manages projects, sites, and activities; manages the site's workforce; approves/manages Foremen/Site Supervisors and assigns them to sites; views the complete worker list for their organization; reviews hazards and corrective actions; monitors safety learning/training; views Daily Safety Meeting summaries completed by Foremen; views site/organization safety dashboards and reports; receives safety alerts.

3. **Foreman / Site Supervisor** (`foreman`) — normally subcontracted/field personnel who directly supervise workers. Operates only within their assigned organization/site(s): manages their assigned crew, registers/adds workers, approves workers, assigns workers to trades/activities, views their own workers, conducts and records Daily Safety Meetings, records attendance and meeting concerns, creates/links corrective actions where authorized, views relevant safety learning, monitors worker training, reports/views relevant hazards, receives safety alerts. The Foreman/Site Supervisor is the direct operational supervisor of workers.

4. **Worker** (`worker`) — electricians, plumbers, masons, carpenters, technicians, general workers, etc. A worker has a `platformRole` of `worker`, a `trade` (Electrician/Mason/Plumber/etc — **not** an authorization role), an organization, a site assignment, an activity assignment, and a supervising Foreman. Workers can view their assigned site and activities, complete assigned safety learning, view safety videos, participate in Daily Safety Meetings, view their own safety history, report hazards, and receive safety alerts. Workers cannot approve themselves, assign themselves to organizations/sites/activities, or change their own authorization role.

Role alone does not determine access. Access is determined by:

User → Organization → Platform Role → Site Assignment → Supervisor/Foreman Relationship → Activity/Trade Assignment

For example:

John
↓
JV ALMA CIS
↓
Worker (trade: Mason)
↓
Rosslyn Site
↓
Masonry + Roofing
↓
Supervising Foreman: Peter

Another user:

Jane
↓
JV ALMA CIS
↓
Worker (trade: Electrician)
↓
Ambassadors Site
↓
Electrical Works
↓
Supervising Foreman: David

Both users have the same platform role (`worker`) but completely different operational access, trade, and supervising Foreman.

### Organization Hierarchy

Admin
→ Organization
→ Site Manager / Site Superintendent
→ Foreman / Site Supervisor
→ Workers

The Admin remains the platform/company authority above all organizations and can audit, reassign, suspend, or otherwise intervene in any organization — but does not perform day-to-day worker approval or run site safety meetings. A Site Manager/Site Superintendent must be able to create an organization because they are the field operational manager; when they do, the organization is associated with that user as its operational manager, and the Admin retains platform-level oversight over it. A Foreman/Site Supervisor manages only the workers they directly interact with, within their assigned organization/site(s).

**A person may belong to more than one organization at once.** In practice a Site Manager/Site Superintendent often operates several organizations simultaneously (they created each one, or were placed into it), and a contracted Foreman/Site Supervisor may be placed into more than one organization by different Site Managers. Each such relationship — role, worker type, trade, site assignment, and its own active/suspended status — is independent per organization: suspending a Foreman's access to one organization has no effect on their standing in another. Admin is the sole exception, holding platform-level authority scoped to no organization at all rather than a membership in every one. See §19 for how this is represented in the data model, and FIRESTORE_DATA_MODEL.md §2 for the `users/{uid}/memberships/{organizationId}` subcollection this is built on.

A user with more than one such membership needs a way to say which organization they are currently working in — a compact organization switcher, shown only when a person has two or more memberships, distinct from the read-only organization picker Admin already uses to inspect any single organization's data. Switching does not require re-authentication; it only changes which organization's data the app's existing screens are scoped to, the same way selecting an organization in Admin's picker already does today.

13. Worker Types and Trade

JVA Safety distinguishes three separate concepts on a worker's profile:

* `platformRole` — the authorization role (`admin` | `siteManager` | `foreman` | `worker`)
* `workerType` — the employment relationship (`jvaEmployee` | `contractor` | `subcontractor` | `other`)
* `trade` — the job/discipline (e.g. Electrician, Mason, Plumber, Carpenter, Technician, General Worker)

A worker's `trade` is never stored in a field called `role` — that name is reserved for describing platform authorization elsewhere in the codebase and must not be reused for trade.

Example:

Jane
Platform Role: Worker
Worker Type: Contractor
Trade: Electrician
Site: Ambassadors
Activity: Electrical Works

This does not give Jane organizational administration privileges. `workerType` and `trade` carry no authorization weight by themselves.

14. Site and Activity Assignment

Site access must be explicit.

Example:

John
Platform Role: Worker
Status: Active
Trade: Mason

Assigned Sites:
- Rosslyn

Assigned Activities:
- Roofing
- Masonry

Supervising Foreman: Peter

Another worker:

Jane
Platform Role: Worker
Status: Active
Trade: Electrician

Assigned Sites:
- Ambassadors

Assigned Activities:
- Electrical Works

Supervising Foreman: David

A user must never be able to see another site's:

Workers
Meetings
Hazards
Training records
Safety information
Corrective actions
Operational data

merely because they belong to the same organization.

Site assignment, activity assignment, and the Foreman/supervisor relationship are all security-relevant data.

15. Authentication and Account Lifecycle

JVA Safety uses a:

Self-registration + organizational approval model.

Users may create their own account using:

Name
Email
Phone number
Password

However, registration does not automatically grant access to operational data.

A newly registered account initially has:

accountStatus = pending

The user cannot access operational site data until an authorized organizational user approves the account.

Account Lifecycle
REGISTER
   ↓
PENDING
   ↓
AUTHORIZED REVIEW
   ↓
ASSIGN ROLE
   ↓
ASSIGN SITE
   ↓
ASSIGN ACTIVITIES
   ↓
ACTIVATE
   ↓
ACTIVE

Possible alternative outcomes:

PENDING → REJECTED

or:

ACTIVE → SUSPENDED
16. User Approval

Approval authority follows the 4-role hierarchy:

Admin

Approves and manages Site Manager/Site Superintendent accounts. Manages users, permissions, and account status platform-wide. Can audit and intervene in any organization's accounts. Does not normally perform day-to-day worker approval.

Site Manager / Site Superintendent

Approves and manages Foreman/Site Supervisor accounts within the organization(s) they manage. Views the complete worker list for their organization.

Foreman / Site Supervisor

Registers and approves workers within their assigned organization/site(s), and assigns them to trades/activities.

Worker

Cannot approve themselves, cannot approve other workers, and cannot assign themselves privileges, sites, activities, or a different platform role.

Authorization must always be enforced through backend security rules and Cloud Functions, not only through Flutter UI.

#### Site Manager / Site Superintendent — a single combined role

"Site Manager" and "Site Superintendent" are treated as one platform role (`siteManager`) rather than two separate concepts. Both job titles describe the same operational responsibility: the field employee who manages an organization's projects, sites, activities, and Foremen. A JV ALMA CIS employee holding either job title is granted the `siteManager` platform role. This intentionally simplifies the previous deployment's separate "Site Superintendent (job title) vs Organization Administrator (app role)" distinction — both now collapse into one platform role with one consistent set of capabilities.

Likewise, "Foreman" and "Site Supervisor" are treated as one combined platform role (`foreman`) — the direct operational supervisor of a crew of workers.

17. User Registration Security

A user must never be allowed to select their own privileged role, organization, site, or activities during registration.

The registration form should contain:

Name
Email
Phone
Password

The system creates:

accountStatus = pending

The user does not select, and the client cannot write:

platformRole (Admin only, on the profile)
organization membership, or any field on one — role, workerType, trade, siteIds, activityIds, supervisorUid / foremanUid, status
approvedAt / approvedBy

during registration or afterward — none of this exists to write until an approver creates it.

An authorized existing user (Admin, Site Manager, or Foreman, according to the hierarchy in §16) or a secure backend workflow later assigns, by creating an organization membership document for the target uid:

role
Organization
Site assignment
Activity assignment
Supervising Foreman (for workers)

and activates the account (for a first approval) or adds an additional organization (for someone already active). This must be enforced identically whether the request comes from the Flutter UI, a direct Firestore client write, a forged document ID, or a modified request payload — the backend (Cloud Functions + Firestore rules) is the sole authority, never the client.

18. First Admin

There is a bootstrapping problem:

If nobody exists yet, who approves the first user?

Do not solve this by automatically making the first registered user an Admin.

For the initial JVA Safety deployment, the first Admin must be created through a controlled administrative process (Firebase Authentication + Firestore user document created directly via an authorized deployment/administrative process, outside the normal registration flow).

After the initial Admin exists, normal registration and approval can occur through JVA Safety: the Admin approves Site Managers, Site Managers approve Foremen, and Foremen approve Workers.

19. User Profile

Because a person may belong to more than one organization (§12), the user profile is split into two parts: identity/account state on the profile document itself, and one organization membership document per organization the person belongs to.

The user profile (`users/{uid}`) should contain at least:

uid
name
email
phone
accountStatus
platformRole        // "admin" or null — the ONLY value this field ever holds; every other role lives per-membership, never here
createdAt
updatedAt

Each organization a person belongs to is a separate `users/{uid}/memberships/{organizationId}` document, containing:

organizationId
role                 // siteManager | foreman | worker — never "admin"; Admin holds no memberships
workerType           // jvaEmployee | contractor | subcontractor | other (workers only, typically)
trade                // e.g. Electrician, Mason, Plumber (workers only; never stored as "role")
siteIds
supervisorUid / foremanUid  // the worker's or Foreman's assigned supervisor, where applicable
status               // active | suspended — for THIS organization only, independent of accountStatus and of this person's other memberships
approvedAt
approvedBy

Site and activity assignments, and the supervising Foreman relationship, are therefore also per-organization — see FIRESTORE_DATA_MODEL.md §2 for the full membership shape and activity assignment records.

Do not use a field called `role` to store a worker's trade — `role` (on a membership) or `platformRole` (Admin only, on the profile) are reserved exclusively for the 4-value platform authorization enum.

Account Status

Possible values:

pending
active
suspended
rejected

accountStatus should be the authoritative account-state field.

Avoid maintaining a second active boolean unless there is a clear technical requirement for it.

accountStatus is not the same thing as a membership's own status (§12, FIRESTORE_DATA_MODEL.md §2). accountStatus answers "can this person use JVA Safety at all" and is set once, at first approval. A membership's status answers "can this person currently operate inside this one organization" — a suspended membership in one organization coexists with an active accountStatus and active memberships elsewhere.

20. Worker Experience

Workers primarily need:

My Site
My Activities
Safety Learning
Safety Videos
Daily Safety Meeting
Safety Alerts
Report Hazard
Report Near Miss
My Safety History

The worker interface should be extremely simple.

It should use:

Large touch targets
Minimal typing
Clear icons
Simple language
Mobile-first field usability

21. Foreman Experience

The Foreman is the primary operational user of the Daily Safety Meeting feature.

The Foreman needs:

* My Site
* My Crew
* Today's Activities
* Today's Safety Meeting
* Recommended Safety Meeting Points
* Add existing Safety Meeting Points from the library
* Attendance
* Safety Concerns
* Corrective Actions
* Hazard Reporting
* Meeting History

The goal is:

**Conduct the meeting physically → record the structured outcome quickly.**

The Foreman should not become a data-entry clerk or safety-content administrator.

The Foreman:

* Conducts the physical meeting
* Chooses relevant Safety Meeting Points
* Removes irrelevant recommendations
* Adds existing library points when necessary
* Marks topics as covered
* Records attendance
* Records concerns
* Records corrective actions
* Completes the meeting

The Foreman does **not** manage the organization's Safety Meeting Point Library.

If a new reusable safety topic is required, an authorized administrator is responsible for adding it to the library.


22. Site Manager / Site Superintendent Experience

Site Managers/Site Superintendents need:

Site dashboard
Worker safety readiness
Training compliance
Daily meeting compliance
Hazards
Near misses
Incidents
Corrective actions
Safety alerts
Inspections
Reports
Worker approval/assignment where authorized

### 22A. Daily Safety Meeting Administration and Management

The Daily Safety Meeting has two distinct, implemented experiences:

**1. Foreman Meeting Workspace**

Used by the Foreman to conduct and record the meeting.

**2. Administrator Meeting List / Summary (read-only)**

Used by Admin and Site Manager/Site Superintendent users to review completed and in-progress meetings.

Reached through:

**Administration → Organizations → (select organization) → Daily Safety Meetings**

Admin may review any organization's meetings; a Site Manager/Site Superintendent is confined to the organization(s) they manage.

Admin and Site Manager/Site Superintendent primarily review meeting records rather than conduct them; Admin additionally manages the **Safety Meeting Point Library**. Neither conducts the physical meeting, and this view gives them no way to:

* Start a meeting
* Conduct a meeting
* Complete a meeting
* Record attendance, concerns or corrective actions on someone else's meeting
* Act as, or stand in for, the Foreman

The operational meeting workflow exists only in the Foreman's own Meeting Workspace.

The meeting list shows a card per meeting containing:

* Site
* Project
* Date
* Foreman
* Meeting status
* Activities discussed (count)
* Safety Meeting Points covered (count)
* Concerns (count)

Selecting a meeting opens the detailed, read-only meeting summary, which additionally shows:

* Organization / Project / Site / Date / Foreman
* The activities discussed, by name
* The Safety Meeting Points covered, by title
* Attendance, by worker name where the administrator's role has visibility into organization member names
* Concerns, with category and description
* Corrective actions, with status and the assigned person

The summary must be generated only from verified structured meeting information.

If Gemini is used to generate a readable summary, the generated text must remain distinguishable from the underlying verified record and must never introduce information that was not recorded. Gemini-generated summaries are not yet implemented; the current summary is assembled directly from the structured records above.

### Safety Meeting Point Library vs Daily Meeting

These are separate concepts:

**Safety Meeting Point Library**

> What safety topics are available for use?

Managed by:

* Admin

**Daily Safety Meeting**

> What topics were actually discussed/covered today?

Conducted and recorded by:

* Foreman / Site Supervisor

Reviewed by:

* Site Manager / Site Superintendent
* Admin

This separation is fundamental to the JVA Safety architecture.

23. Management Experience

Management needs:

All projects
All sites
All workers
Training compliance
Meeting compliance
Safety performance
Hazards
Incidents
Corrective actions
Reports
Trends
Evidence

Management may operate primarily in English even when field meetings are conducted in other languages.

24. Hazard Reporting

Workers should have a simple:

REPORT A HAZARD

Possible information:

Photo
Location
Category
Description

Categories may include:

Working at Height
Electrical
Equipment
PPE
Housekeeping
Environment
Chemical
Fire
Other

The workflow must remain simple for field workers.

25. Corrective Actions

A hazard or concern can create a corrective action.

Example:

Hazard
↓
Unstable ladder


Corrective Action
↓
Remove and replace ladder


Assigned To
↓
Foreman / Site Supervisor


Due Date
↓
...


Evidence
↓
Photo/document/etc.


Closure
↓
Closed

Core lifecycle:

Hazard → Action → Evidence → Closure

All safety records must remain auditable.

26. Safety Alerts

Management can issue safety alerts.

Example:

Heavy rainfall expected

Affected sites:

Rosslyn
Karen
Westlands

Workers receive push notifications.

Alerts should be event-based and relevant rather than excessive.

27. Near Misses

JVA Safety should eventually support:

Report Near Miss

Example:

A worker almost falls from scaffolding but is not injured.

Near misses should be captured to identify risks before they become incidents.

28. Incidents

Incident Management is planned for a later phase.

Potential fields:

Worker
Site
Date/time
Location
Activity
Incident type
Injury
Witnesses
Photos
Immediate action
Investigation
Root cause
Corrective actions
Closure

Do not prioritize this before the core MVP.

29. Safety Inspections

Planned for a later phase.

Potential areas:

PPE
Fire safety
Electrical
Scaffolding
Ladders
Housekeeping
Equipment
Emergency access
First aid
30. Gemini / AI Principle

Gemini is an assistant, not an authority.

Gemini must not:

Invent safety events
Fabricate meeting content
Replace the foreman
Make authoritative safety/legal decisions
Claim something happened when it was not recorded

AI-generated information must remain distinguishable from verified operational records.

The application already contains:

AiGeneratedBadge

for this principle.

31. Gemini Planned Functions

Gemini may eventually support:

1. Safety Meeting Point recommendations

Based on:

Site
Activities
Previous hazards
Open corrective actions
Relevant site information

Gemini recommends Meeting Points.

The foreman accepts, removes, or adds them.

2. Management meeting summaries

Gemini can turn verified structured meeting information into a readable English summary.

The underlying Firestore data remains the authoritative record.

3. Hazard classification

Gemini may suggest:

Hazard category
Risk type
Description cleanup
Suggested corrective action

Human users remain responsible for confirmation.

4. Safety trend analysis

Gemini may identify patterns such as:

Recurring working-at-height hazards
Repeated PPE issues
Increased safety concerns at a site
Repeated corrective actions
5. Safety content assistance

Gemini may eventually help administrators create draft safety content.

All safety content must be reviewed and approved by an authorized human before becoming official.

32. Gemini Architecture

Gemini must never be called directly from Flutter with an exposed API key.

Architecture:

Flutter
   ↓
Firebase Cloud Function
   ↓
Gemini
   ↓
Cloud Function
   ↓
Firestore / Flutter

Gemini credentials/secrets must remain server-side.

33. Current Technology Stack
Frontend
Flutter
Dart
Responsive web-first design
Future Android/iOS compatibility
Backend
Firebase Authentication
Cloud Firestore
Firebase Storage
Firebase Cloud Functions
Firebase Cloud Messaging
AI
Google Gemini
Accessed securely through Cloud Functions
34. Current Flutter Version

Current environment:

Flutter 3.44.8

Dart 3.12.2

The project was created from a fresh Flutter template.

35. Current Architecture
lib/
├── core/
│   ├── constants/
│   ├── errors/
│   ├── extensions/
│   ├── services/
│   ├── theme/
│   ├── utils/
│   └── widgets/
│
├── features/
│   ├── authentication/
│   ├── dashboard/
│   ├── workers/
│   ├── projects/
│   ├── sites/
│   ├── activities/
│   ├── safety_learning/
│   ├── safety_meeting_points/
│   ├── daily_safety_meetings/
│   ├── hazards/
│   ├── corrective_actions/
│   ├── safety_alerts/
│   ├── notifications/
│   ├── reports/
│   ├── analytics/
│   └── administration/
│
├── routing/
│
├── app.dart
└── main.dart

Feature areas should use:

data/
domain/
presentation/

where appropriate.

36. Foundation Already Implemented

The following foundation has already been created.

RBAC Foundation

core/constants/app_roles.dart

Contains the seven application roles.

This is currently a domain foundation only.

It does not mean complete backend RBAC has already been implemented.

Firestore Paths

core/constants/firestore_paths.dart

Centralized organization-scoped collection path constants.

These should be reviewed against the final Firestore data model before production security rules are finalized.

Error Handling

core/errors/app_exception.dart

Sealed exception hierarchy including:

Auth
Data
PermissionDenied
Network
Theme

Created:

AppColors
AppTextStyles
AppSpacing
AppTheme

Supports:

Material 3
Light theme
Dark theme
Brand colors
Semantic danger/warning/success/info colors
48px minimum touch target for field use
Responsive Layout

core/widgets/responsive_scaffold.dart

Adaptive navigation:

Mobile → Bottom Navigation

Tablet → Navigation Rail

Desktop → Extended Navigation Rail

AI Indicator

core/widgets/ai_generated_badge.dart

Used to distinguish Gemini-generated content from verified operational records.

Reusable Widgets

Created:

PlaceholderScreen
EmptyState
LoadingIndicator
Authentication Foundation

Created:

auth_service.dart
session_controller.dart

These now implement the real Firebase Authentication and user-profile
workflow: email/password registration and sign-in, session persistence, and a
streamed `users/{uid}` profile whose `accountStatus` drives the session state
(pending / active / suspended / rejected). Supporting files:

features/authentication/domain/account_status.dart
features/authentication/domain/user_profile.dart
features/authentication/data/user_profile_repository.dart
features/authentication/presentation/{login,register,pending_approval,access_denied}_screen.dart

Note there is no role enum: RBAC is deferred to the stage after the Firestore
data model, so `accountStatus` is currently the only access gate. There is
also no `workerType` field: the §13 worker-type vocabulary below does not map
cleanly onto real trades (a plumber has no good option), and a worker's role,
trade and site assignment are decided by a foreman or superintendent at
approval time once Sites and Activities exist — not chosen by the registrant
at signup. That richer approval-with-role-assignment workflow is deferred.

Routing

Using:

go_router

Includes:

ShellRoute
AppShell
Auth redirect placeholder
Placeholder route for each major feature
Application Entry

main.dart

Defensively initializes Firebase.

app.dart wires:

Provider
Theme
Router
37. Packages Already Added

Current packages include:

go_router
provider
firebase_core
firebase_auth
cloud_firestore
firebase_storage
firebase_messaging

No Gemini package/integration has been implemented yet.

38. Firebase Configuration Status

Firebase has now been initialized for the JVA Safety project.

Firebase Project

Project ID: jva-safety

Project Name: JVA Safety

Firestore

Configured.

Database location: nam5

The nam5 location is intentionally consistent with the existing JV ALMA CIS Firebase projects.

The platform may eventually be used by JV ALMA CIS and potentially related operations outside Kenya, so application architecture must avoid assumptions that the system is Kenya-only.

Firebase Storage

Configured.

Bucket:

jva-safety.firebasestorage.app

Storage location:

US-EAST1

Cloud Functions

Initialized using:

TypeScript

Firebase Hosting

Initialized.

Firebase Authentication

Firebase Authentication dependency is installed.

The actual authentication workflow still needs to be implemented.

Firebase Cloud Messaging

Firebase Messaging dependency is installed.

The actual notification workflow still needs to be implemented.

Gemini

Gemini has not yet been integrated.

39. Testing Status

The original Flutter counter-app test was replaced to match the new application shell.

The project currently contains scaffolding and foundation code.

The actual JVA Safety business functionality is not yet implemented.

Every major implementation stage must include appropriate tests.

40. Current Implementation Status
COMPLETED
Flutter project created
Flutter/Dart versions confirmed
Feature architecture created
Core architecture created
RBAC foundation created
Firestore path constants created
Error hierarchy created
Theme created
Responsive scaffold created
AI-generated badge created
Auth/session scaffolding created
Authentication foundation implemented (self-registration -> pending -> approval -> active)
go_router configured
Placeholder routes created
Firebase client packages installed
Firebase project created
Firebase project initialized
Firestore initialized
Firebase Storage initialized
Cloud Functions initialized with TypeScript
Firebase Hosting initialized
App shell created
Tests updated
IMPLEMENTED
Real Firebase Authentication workflow (register / login / logout / persistence)
User self-registration (name, email, phone, password only; no role, trade or
  org selection)
Real user profiles at users/{uid} gated on accountStatus
Account approval backend + operator script (functions/src/account_approval.ts)
  and an in-app admin approval UI (Pending Approvals / Active Users /
  Suspended-Rejected Users)
Firestore security rules blocking self-approval and self-assignment
Backend RBAC (platformRole: admin / siteManager / foreman / worker),
  enforced in callables and firestore.rules — migrated from the previous
  7-role model (systemAdministrator / organizationAdministrator /
  safetyManager / siteSuperintendent / siteSupervisor / foreman / worker);
  see the migration report for the old→new mapping
Organizations, Projects, Sites, Activities (admin CRUD + Firestore data model)
Site assignment (assignWorkerToSite/removeWorkerFromSite) with a dedicated
  Site Workers UI, reachable by Admin (any organization) and Site Manager
  (organization(s) they manage)
Activity assignment (assignWorkerToActivity/removeWorkerFromActivity), gated
  on the worker already having site access
Safety Learning library + worker learning completion tracking
Safety Meeting Point Library: admin CRUD (create/edit/activate/deactivate),
  reachable via Administration → Organizations → (organization) → Safety
  Meeting Points, scoped to Admin (any organization) only — a
  platform-level, company-wide responsibility not delegated to Site Managers
Daily Safety Meetings: Foreman Meeting Workspace (recommended points,
  accept/remove/add-from-library, mark covered, attendance, concerns,
  corrective actions, completion validation) and a read-only Administrator
  meeting list/summary view (Administration → Organizations →
  (organization) → Daily Safety Meetings) — see §22A
Corrective Actions (raised from a meeting concern, tracked to closure)
Safety Alerts
Notifications foundation
Reports and Analytics (organization-scoped summaries over the above)
Hazards / hazard reporting (report, acknowledge, link corrective action,
  close — hazard_callable.ts)
Daily Pre-Start Check (October 2026): each Worker answers five standard
  questions plus one per applicable Safety Requirement before work; the
  server decides GO / GO corrected / STOP. A STOP notifies the site's
  Foremen and becomes a concern on today's meeting. Foremen see crew
  results on their dashboard and record a crew GO / GO corrected / STOP
  when completing the meeting (a crew STOP notifies Site Managers).
  Warn-only for now — it does not block attendance. Asks only what today's
  work needs (standard five + one line per activity with high-risk
  requirements). See FIRESTORE_DATA_MODEL.md §6A.
"Needed today" learning (October 2026): instead of every "Before meeting"
  lesson, each Worker/Foreman must finish only a small daily plan before the
  meeting — one lesson per activity they do today plus one general lesson,
  highest risk first. The rest is "When you can" and comes up one a day;
  tomorrow's lesson is shown in advance so workers can get ahead. A Foreman
  can mark a worker present as "Briefed in person" (recorded; the lesson
  stays due). No time budget is assumed — workers arrive with different
  amounts of time. See FIRESTORE_DATA_MODEL.md §4A.

Near-misses (October 2026): a hazard report "kind" — "Something nearly
  happened" on the Report a Hazard form. See FIRESTORE_DATA_MODEL.md §7.
Incidents (October 2026): report → investigate (severity) → corrective
  actions → close with root cause. Visible only to the reporter and
  Foremen/Site Managers/Admin. See FIRESTORE_DATA_MODEL.md §7A.

Site inspections (October 2026): daily site inspection and weekly HSE
  walk-down from the Safety Plan (Section 7), editable checklists, each
  "Not OK" becomes a deficiency (hazard) tracked to closure, sign-off by
  another Site Manager/Admin, and a Deficiency Log. See
  FIRESTORE_DATA_MODEL.md §7B.

NOT YET IMPLEMENTED
Gemini integration (recommendations, summaries, hazard classification,
  trend analysis, content assistance — see §30-32)
Free-text/ad-hoc Safety Meeting Points (deliberately excluded — see §4;
  "Add Safety Point" only ever adds an existing library point)
41. Security Principles

Security is a core architectural requirement.

Organization Isolation

A user must only access data belonging to their organization.

Site Isolation

A user must only access sites to which they have been authorized.

Role Authorization

A user's application role determines what operations they may perform.

Assignment Authorization

Site and activity assignments further restrict operational access.

Backend Enforcement

Flutter UI permissions are not a security boundary.

Firestore Security Rules must independently enforce authorization.

The system must never rely exclusively on:

if (user.role == ...)

inside Flutter.

Self-Privilege Prevention

A newly registered user must never be able to:

Assign themselves a privileged role
Assign themselves to a site
Approve themselves
Activate themselves
Modify their organization
Grant themselves permissions
42. Development Rules

Claude Code must:

Inspect existing code before modifying it.
Preserve existing architecture unless there is a strong technical reason to change it.
Avoid unnecessary packages.
Avoid fake Firestore data in production code.
Avoid hardcoded business data that belongs in Firestore/admin configuration.
Keep safety records auditable.
Keep verified operational data separate from AI-generated data.
Never expose Gemini credentials in Flutter.
Keep field-worker workflows extremely simple.
Avoid making the foreman enter lengthy written reports.
Do not assume the physical safety meeting is conducted in English.
Do not record the spoken Daily Safety Meeting as a core requirement.
Do not allow Gemini to fabricate safety events or meeting content.
Test after each major implementation stage.
Run flutter analyze and relevant tests after changes.
Never implement authorization only in the Flutter UI.
Never allow self-registration to create privileged accounts.
Do not invent Firestore architecture without first inspecting the existing foundation.
Keep organization, site, role, and activity authorization explicit.
Do not proceed to the next major feature until the current stage has been tested and verified.
43. Development Strategy

Do not build the entire platform in one prompt.

Build progressively.

Recommended order:

Firebase configuration — DONE
Authentication
User registration
Account approval workflow
User profile
Organization context
Roles
Site assignments
Activity assignments
Firestore data model
Firestore security rules
Projects
Sites
Workers
Activities
Safety Learning
Safety Meeting Point Library
Daily Safety Meetings
Attendance
Hazards
Corrective Actions
Notifications
Dashboards
Reports
Gemini
Analytics
Hardening/testing/deployment
Important

Authentication should be implemented before the rest of the application.

However, authentication alone does not constitute complete RBAC.

The complete authorization model depends on the Firestore data model, organization structure, site assignments, activity assignments, and security rules.

44. Authentication MVP

The first authentication implementation should support:

Registration

Users can register with:

Name
Email
Phone
Password

Registration creates:

Firebase Authentication user
+
Firestore user profile

with:

accountStatus = pending

The user must not receive operational access immediately.

Login

Registered users can log in with:

Email
Password

Authentication must handle:

Invalid credentials
Disabled accounts
Pending accounts
Suspended accounts
Rejected accounts
Network errors
Loading states
Session persistence
Approval

Authorized users can eventually:

Review pending users
Assign role
Assign site
Assign activities
Approve/activate the account
Reject an account
Suspend an active account

This should be implemented as a separate stage from basic authentication.

45. MVP Definition

The first usable JVA Safety MVP should contain:

Administration
Organizations
Projects
Sites
Users
Roles
Activities
User approval
Site assignments
Activity assignments
Worker Safety
Safety Learning
Required training
Safety videos
Training completion
Daily Safety Meeting
Safety alerts
Hazard reporting
Worker safety history
Foreman
Crew
Today's activities
Safety Meeting Points
Attendance
Concerns
Corrective actions
Meeting completion
Supervisor
Site safety dashboard
Training compliance
Meeting compliance
Hazards
Corrective actions
Management
Organization-wide safety dashboard
Safety evidence
Reports
46. Current Next Development Task

Firebase has already been initialized.

Therefore, the immediate next development task is:

Implement Firebase Authentication and the user identity foundation.

Do not implement:

Projects
Sites
Workers
Safety Learning
Safety Meetings
Hazards
Corrective Actions
Gemini
Notifications

during the first authentication implementation stage.

The authentication stage should establish the foundation for:

Registration
↓
Pending account
↓
Authentication
↓
User profile
↓
Session
↓
Account status
↓
Organization identity

The account approval and complete RBAC workflow should be implemented in the following stage after the identity foundation has been tested.

47. Product Philosophy

JVA Safety should ultimately answer four questions.

Before work

Does this worker have the safety knowledge required for today's work?

Before the daily task

Was the relevant safety discussion conducted with the crew?

During work

Are workers able to report hazards and safety concerns?

Afterward

Can management prove what safety activities happened, what problems were identified, and what actions were taken?

The platform exists to make those four questions answerable with reliable, structured evidence.