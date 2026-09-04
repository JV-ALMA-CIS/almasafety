# Firestore Security Rules tests

`firestore.rules.test.js` verifies the authorization boundary described in
`firestore.rules` for the self-registration model:

- a client may create only its own `pending`, organization-less profile, with
  its email bound to the auth token;
- it can never set `accountStatus`, `organizationId`, `approvedAt`,
  `approvedBy`, `role` or `workerType` — at creation or afterwards;
- a reviewer role cannot be self-granted, and a reviewer cannot mint another
  reviewer by direct write: only the Admin SDK writes that field;
- holding a reviewer role widens a client's *direct* Firestore reach by
  nothing at all. The approvals screen reads the pending queue and writes
  decisions through Cloud Functions callables
  (`functions/src/approval_callable.ts`), which run on the Admin SDK and
  check the role server-side, so these rules deliberately contain no second
  implementation of that check;
- the platform-level `systemAdministrator` role gets no special case in the
  WRITE rules anywhere: it is protected by the same field lists as every
  other role, cannot self-grant or mint a second System Administrator by
  direct write, and cannot approve/reject/activate anyone (including itself)
  by direct write — see "the bootstrap System Administrator". The one READ
  exception (`isSystemAdministrator()`) lets it read every organization,
  project and site rather than only its own, since it belongs to none;
- pending / suspended / rejected accounts reach no operational data;
- organization isolation for operational collections, and for
  `organizations/{orgId}/projects` and `.../sites` specifically — see "the
  Organization -> Project -> Site foundation";
- organizations, projects and sites are Admin-SDK-write-only for every
  client including a System Administrator — created and edited exclusively
  through `functions/src/organization_callable.ts`;
- no client writes to operational collections or audit logs (deferred to the
  RBAC stage).

## Running

```
cd functions
npm run test:rules
```

That wraps the suite in `firebase emulators:exec --only firestore`, which
starts and stops the Firestore emulator around the run.

## Requirements

- **JDK 21 or newer.** `firebase-tools` v15 refuses to start the emulator on
  older runtimes. If the machine has several JDKs, point `JAVA_HOME` at a
  suitable one before running, e.g.

  ```
  export JAVA_HOME="/c/Program Files/Java/jdk-23"
  export PATH="$JAVA_HOME/bin:$PATH"
  ```

- **A free emulator port.** The suite reads `FIRESTORE_EMULATOR_HOST` (which
  `emulators:exec` exports), so it follows whatever port the emulator
  actually bound. `firebase.json` requests 8080; if something else on the
  machine already holds that port, `emulators:exec` fails fast with
  "Could not start Firestore Emulator, port taken." Either free 8080, or run
  against a copy of the config with a different port — the tests follow it:

  ```
  node -e "const c=require('./firebase.json');c.emulators.firestore={host:'127.0.0.1',port:8099};require('fs').writeFileSync('firebase.emulator-tmp.json',JSON.stringify(c))"
  cd functions
  npx firebase emulators:exec --only firestore \
    --project jva-safety-rules-test --config ../firebase.emulator-tmp.json \
    "npx jest --config jest.rules.config.js"
  ```

## Expected output noise

Denied operations are the point of most of these tests, so the run prints a
number of `PERMISSION_DENIED` warnings from the Firestore SDK. Those are the
`assertFails(...)` cases succeeding — only the final Jest summary matters.
