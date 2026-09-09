/**
 * Jest config for the Cloud Storage Security Rules test suite.
 *
 * Kept separate from `jest.rules.config.js` (Firestore rules) because
 * `storage.rules` reads Firestore membership documents via `firestore.get`/
 * `firestore.exists` cross-references, so this suite needs BOTH the
 * Firestore and Storage emulators running together — `npm run
 * test:storage-rules` wraps them in `firebase emulators:exec --only
 * firestore,storage`, which starts and stops both around the run.
 */
module.exports = {
  testEnvironment: "node",
  testMatch: ["<rootDir>/test/storage.rules.test.js"],
  // Emulator round-trips are slower than plain unit tests.
  testTimeout: 20000,
};
