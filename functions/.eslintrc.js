module.exports = {
  root: true,
  env: {
    es6: true,
    node: true,
  },
  extends: [
    "eslint:recommended",
    "plugin:import/errors",
    "plugin:import/warnings",
    "plugin:import/typescript",
    "google",
    "plugin:@typescript-eslint/recommended",
  ],
  parser: "@typescript-eslint/parser",
  parserOptions: {
    project: ["tsconfig.json", "tsconfig.dev.json"],
    sourceType: "module",
  },
  ignorePatterns: [
    "/lib/**/*", // Ignore built files.
    "/generated/**/*", // Ignore generated files.
  ],
  plugins: [
    "@typescript-eslint",
    "import",
  ],
  rules: {
    "quotes": ["error", "double"],
    "import/no-unresolved": 0,
    "indent": ["error", 2],
  },
  overrides: [
    {
      // The Firestore rules suite is plain CommonJS run by Jest, not part
      // of the TypeScript build, so the TS-oriented and JSDoc rules that
      // apply to src/ are not meaningful here.
      files: [
        "test/**/*.js",
        "scripts/**/*.js",
        "jest.rules.config.js",
        "jest.callables.config.js",
      ],
      env: {
        jest: true,
        node: true,
      },
      rules: {
        "@typescript-eslint/no-var-requires": "off",
        "require-jsdoc": "off",
        "valid-jsdoc": "off",
      },
    },
  ],
};
