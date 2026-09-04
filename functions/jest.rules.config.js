/**
 * Jest config for the Firestore Security Rules test suite.
 *
 * Kept separate from any future unit-test config because these tests need a
 * running Firestore emulator; `npm run test:rules` wraps them in
 * `firebase emulators:exec`, which starts and stops it around the run.
 */
module.exports = {
  testEnvironment: "node",
  testMatch: ["<rootDir>/test/firestore.rules.test.js"],
  // Emulator round-trips are slower than plain unit tests.
  testTimeout: 20000,
};
