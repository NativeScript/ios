module.exports = {
    enabled: true,
    suiteName: "Test262",
    projectSubmodulePath: "TestRunner/app/tests/vendor/test262",
    bundleSubmodulePath: "vendor/test262",
    generatedManifestPath: "TestRunner/app/tests/Test262/generated-manifest.json",
    curatedIncludePathsPath: "TestRunner/app/tests/Test262/curated-prefixes.json",
    harnessDefaults: ["assert.js", "sta.js"],
    unsupportedFlags: ["raw"],
    unsupportedIncludes: [
        "agent.js",
        "detachArrayBuffer.js",
        "nondeterministic.js",
        "shadowrealm.js",
        "timer.js",
        "workerHelper.js"
    ],
    unsupportedFeatures: [
        "Array.fromAsync",
        "arbitrary-module-namespace-names",
        "cross-realm",
        "ShadowRealm",
        "import-attributes",
        "import-bytes",
        "import-defer",
        "import-text",
        "source-phase-imports",
        "source-phase-imports-module-source"
    ],
    includePaths: ["language/module-code"],
    excludePaths: ["built-ins/Array/from/elements-deleted-after.js"],
    timeoutMs: 4000,
    defaultLimit: 100,
    expandStrictVariants: true
};