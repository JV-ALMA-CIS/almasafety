# Manual testing against the local Firebase emulators

Everything here runs on this computer against the **Firebase emulators**,
using the project **`demo-jva-safety`**. A `demo-` project cannot reach real
Firebase resources (the CLI says so when it starts), and the app only uses
the emulators when it is run with `--dart-define=USE_FIREBASE_EMULATORS=true`
— a normal run or build still uses production, so never leave that flag out
during these tests.

| Service   | Port | Note |
|-----------|------|------|
| Auth      | 9099 | |
| Functions | 5001 | |
| Firestore | 8085 | not 8080: another program on this PC already uses 8080 |
| Storage   | 9199 | |
| Emulator UI | 4000 | http://127.0.0.1:4000 |

Defined in `firebase.emulators.json` (emulators) and
`lib/core/config/firebase_target.dart` (app). Scheduled functions do not run
here (no Pub/Sub emulator); use **Finish deleting** in the app instead.

## Test accounts (emulator only)

Created by `functions/scripts/seed_emulators.js`. Password for all:
`Test-only-123!`

| Email | Role |
|-------|------|
| admin@test.local | Admin |
| sitemanager@test.local | Site Manager |
| foreman@test.local | Foreman (Test Site) |
| worker@test.local | Worker (Test Site, assigned to "Working at Height") |

## Start (Windows PowerShell)

**Terminal 1 — emulators** (keep it open):

```powershell
cd C:\Users\User\Projects\FlutterApps\jva_safety
$env:JAVA_HOME = "C:\Program Files\Java\jdk-23"
$env:Path = "$env:JAVA_HOME\bin;$env:Path"
npm --prefix functions run build
npx firebase --config firebase.emulators.json emulators:start --project demo-jva-safety --import "$env:TEMP\jva-emulator-data" --export-on-exit "$env:TEMP\jva-emulator-data"
```

(The first time, drop `--import ...` — the folder does not exist yet. Data
is saved to `%TEMP%\jva-emulator-data` when you stop with Ctrl+C, outside
the project.)

**Terminal 2 — test data** (once, after the emulators say "All emulators
ready"):

```powershell
cd C:\Users\User\Projects\FlutterApps\jva_safety
node functions\scripts\seed_emulators.js
```

**Terminal 3 — the app:**

```powershell
cd C:\Users\User\Projects\FlutterApps\jva_safety
flutter run -d chrome --dart-define=USE_FIREBASE_EMULATORS=true
```

**Confirm you are NOT on production** before testing:
- The Flutter console prints `JVA Safety: using the Firebase EMULATORS
  (demo-jva-safety at 127.0.0.1) — not production.`
- In Chrome DevTools → Network, requests go to `127.0.0.1:8085`, `:9099`,
  `:5001`, `:9199` — none to `firestore.googleapis.com` or
  `cloudfunctions.net`. (YouTube thumbnails from `i.ytimg.com` are normal.)
- After signing in, the Emulator UI (http://127.0.0.1:4000) shows your data.

## Checklist

Record pass/fail for each. Sign out (Settings → Sign Out) to switch user.

1. **Create videos (Site Manager).** Safety Videos → Add video:
   a. "YouTube Test" — link `https://www.youtube.com/watch?v=jfKfPfyJRdk`;
      Manage Quiz → add two questions.
   b. "Upload Test" — upload a small .mp4 (under 25 MB).
   c. "Spare Video" — any YouTube link, no quiz.
2. **YouTube thumbnail** shows on "YouTube Test" (learner and manager cards).
   If it shows the coloured tile instead, note any console error.
3. **General learning (Worker, then Foreman).** Safety Videos lists all
   three, labelled **General learning**; "YouTube Test" shows "Quiz · 2
   questions". Watch Video opens the lesson; Practice Quiz grades it. In the
   Emulator UI, `worker_learning_records` stays empty. Workers/Foremen see no
   Edit, Preview, Manage Quiz or More actions.
4. **Delete an unused uploaded video (Site Manager).** "Upload Test" →
   More actions → Delete → the dialog names it → Delete permanently. It
   disappears; in the Emulator UI → Storage, its file under
   `organizations/org-jva/safety_learning/...` is gone.
5. **Requirement refusal — active.** Safety Requirements → new requirement
   "Height Requirement" for Test Site listing "YouTube Test". Back in Safety
   Videos, delete "YouTube Test" → refused, message names **Height
   Requirement**; it stays listed.
6. **Requirement refusal — inactive.** Deactivate "Height Requirement",
   try deleting again → still refused, still named.
7. **Required vs General (Worker).** Re-activate the requirement. Worker →
   Safety Videos: "YouTube Test" is under Required (filter **Required**),
   the others under General learning. Watch Video → I've Watched the Video →
   Take Quiz: the lesson completes only after the quiz is passed.
8. **Learner-record refusal.** Remove "YouTube Test" from the requirement
   (keep the requirement). Delete "YouTube Test" → refused: learners have
   training records — deactivate instead. The Worker's record is unchanged.
9. **Shared file.** Upload "Shared A" (a new .mp4). In the Emulator UI →
   Firestore, create or edit another video item "Shared B" whose
   `contentReference` is exactly "Shared A"'s. Delete "Shared A" → allowed;
   "Shared B" still plays and the file is still in Storage.
10. **Deletion not finished → recovery.** Stop the emulators (Ctrl+C — data
    is exported). Create `functions\.env.local` containing
    `JVA_SIMULATE_STORAGE_FAILURE=true`, restart Terminal 1 (with
    `--import`). Upload "Fail Test", delete it → message says it is hidden
    and **marked for deletion**; the card shows **Deletion not finished**,
    Edit is disabled, More actions offers only **Finish deleting**; Workers
    no longer see it. Stop the emulators, **delete `functions\.env.local`**,
    restart, More actions → Finish deleting → it is deleted and its file is
    gone.
11. **Layouts.** Chrome DevTools device toolbar at 360×800 (phone),
    768×1024 (tablet) and a full-width desktop window, for the Worker library
    and the manager workspace: no overflow, cards readable, filters wrap.

When finished: Ctrl+C in Terminal 1, and make sure `functions\.env.local`
is gone.
