/**
 * Jest config for the Cloud Functions callable business-logic test suite.
 *
 * Kept separate from `jest.rules.config.js` so the two suites' `testMatch`
 * patterns don't overlap. Like the rules suite, these tests need a running
 * Firestore emulator (the callables under test call `getFirestore()`
 * directly via the Admin SDK); `npm run test:callables` wraps them in
 * `firebase emulators:exec`, which starts and stops it around the run.
 */
module.exports = {
  testEnvironment: "node",
  testMatch: ["<rootDir>/test/*_callable.test.js"],
  testTimeout: 20000,
  // These files share one Firestore emulator project and each clears the
  // whole database in its own beforeEach — run serially or parallel workers
  // race and clobber each other's fixtures.
  maxWorkers: 1,
};
