const fs = require("fs");
const path = require("path");

const projectRoot = path.resolve(__dirname, "..");
const config = require(path.join(projectRoot, "TestRunner/app/tests/Test262/config.js"));

function parseNumber(value, fallback) {
    const parsed = Number.parseInt(value, 10);
    return Number.isFinite(parsed) ? parsed : fallback;
}

function toPosix(relativePath) {
    return relativePath.split(path.sep).join("/");
}

function ensureDirectory(filePath) {
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
}

function writeManifest(payload) {
    const outputPath = path.join(projectRoot, config.generatedManifestPath);
    ensureDirectory(outputPath);
    fs.writeFileSync(outputPath, JSON.stringify(payload, null, 2) + "\n");
}

function writeEmptyManifest(reason) {
    writeManifest({
        generatedAt: new Date().toISOString(),
        enabled: false,
        reason,
        summary: {
            discovered: 0,
            included: 0,
            excluded: 0
        },
        tests: []
    });
}

function readJsonIfPresent(filePath, fallbackValue) {
    if (!filePath || !fs.existsSync(filePath)) {
        return fallbackValue;
    }

    return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function parseList(frontmatter, key) {
    const inlineMatch = frontmatter.match(new RegExp("^" + key + ":\\s*\\[(.*?)\\]\\s*$", "m"));
    if (inlineMatch) {
        return inlineMatch[1]
            .split(",")
            .map((value) => value.trim())
            .filter(Boolean)
            .map((value) => value.replace(/^['\"]|['\"]$/g, ""));
    }

    const blockMatch = frontmatter.match(new RegExp("^" + key + ":\\s*\\n((?:\\s+-.*(?:\\n|$))*)", "m"));
    if (!blockMatch) {
        return [];
    }

    return blockMatch[1]
        .split(/\r?\n/)
        .map((line) => line.trim())
        .filter(Boolean)
        .map((line) => line.replace(/^-\s*/, "").trim());
}

function parseNegative(frontmatter) {
    const match = frontmatter.match(/^negative:\s*\n((?:\s{2,}.*(?:\n|$))*)/m);
    if (!match) {
        return null;
    }

    const block = match[1];
    const phase = (block.match(/^\s+phase:\s*(.+)$/m) || [])[1];
    const type = (block.match(/^\s+type:\s*(.+)$/m) || [])[1];

    return {
        phase: phase ? phase.trim() : "runtime",
        type: type ? type.trim() : null
    };
}

function parseFrontmatter(source) {
    const match = source.match(/\/\*---\s*([\s\S]*?)\s*---\*\//);
    if (!match) {
        return {
            flags: [],
            features: [],
            includes: [],
            negative: null
        };
    }

    const frontmatter = match[1];
    return {
        flags: parseList(frontmatter, "flags"),
        features: parseList(frontmatter, "features"),
        includes: parseList(frontmatter, "includes"),
        negative: parseNegative(frontmatter)
    };
}

function walkTests(rootDirectory) {
    const entries = fs.readdirSync(rootDirectory, { withFileTypes: true });
    const results = [];

    for (const entry of entries) {
        const absolutePath = path.join(rootDirectory, entry.name);
        if (entry.isDirectory()) {
            results.push(...walkTests(absolutePath));
            continue;
        }

        if (!entry.isFile()) {
            continue;
        }

        if (!entry.name.endsWith(".js") || entry.name.includes("_FIXTURE")) {
            continue;
        }

        results.push(absolutePath);
    }

    return results;
}

function matchesAnyPrefix(relativePath, prefixes) {
    if (!prefixes.length) {
        return false;
    }

    return prefixes.some((prefix) => relativePath.startsWith(prefix));
}

function getModes(flags) {
    if (flags.includes("module")) {
        return ["module"];
    }

    if (flags.includes("onlyStrict")) {
        return ["strict"];
    }

    if (flags.includes("noStrict") || !config.expandStrictVariants) {
        return ["non-strict"];
    }

    return ["non-strict", "strict"];
}

function unique(values) {
    return Array.from(new Set(values));
}

function normalizePrefixes(prefixes) {
    return unique((prefixes || []).map((prefix) => String(prefix).trim()).filter(Boolean));
}

function buildManifest() {
    const test262Root = path.join(projectRoot, config.projectSubmodulePath);
    const testDirectory = path.join(test262Root, "test");
    const manifestTests = [];
    const exclusionCounts = {};

    if (!config.enabled) {
        writeEmptyManifest("disabled");
        console.log("Test262 manifest generation skipped because the suite is disabled.");
        return;
    }

    if (!fs.existsSync(testDirectory)) {
        writeEmptyManifest("missing-submodule");
        console.log("Test262 manifest generation skipped because the submodule is missing.");
        return;
    }

    const curatedPrefixes = normalizePrefixes(
        readJsonIfPresent(path.join(projectRoot, config.curatedIncludePathsPath), [])
    );
    const requestedPrefixes = (process.env.TEST262_FILTER || "")
        .split(",")
        .map((value) => value.trim())
        .filter(Boolean);
    const activeFilterPrefixes = normalizePrefixes(requestedPrefixes);
    const activeIncludePrefixes = normalizePrefixes(
        activeFilterPrefixes.length
            ? activeFilterPrefixes
            : (config.includePaths && config.includePaths.length ? config.includePaths : curatedPrefixes)
    );
    const shardCount = parseNumber(process.env.TEST262_SHARD_COUNT, 0);
    const shardIndex = parseNumber(process.env.TEST262_SHARD_INDEX, 0);
    const limit = parseNumber(process.env.TEST262_LIMIT, config.defaultLimit);

    const discoveredFiles = walkTests(testDirectory)
        .map((absolutePath) => ({
            absolutePath,
            relativePath: toPosix(path.relative(testDirectory, absolutePath))
        }))
        .sort((left, right) => left.relativePath.localeCompare(right.relativePath));

    for (const testFile of discoveredFiles) {
        const source = fs.readFileSync(testFile.absolutePath, "utf8");
        const metadata = parseFrontmatter(source);
        const flags = metadata.flags || [];
        const features = metadata.features || [];
        const includes = unique(config.harnessDefaults.concat((metadata.includes || []).filter((include) => include !== "doneprintHandle.js")));
        let exclusionReason = null;

        if (matchesAnyPrefix(testFile.relativePath, config.excludePaths || [])) {
            exclusionReason = "excluded-path";
        } else if (activeFilterPrefixes.length && !matchesAnyPrefix(testFile.relativePath, activeFilterPrefixes)) {
            exclusionReason = "filter";
        } else if (activeIncludePrefixes.length && !matchesAnyPrefix(testFile.relativePath, activeIncludePrefixes)) {
            exclusionReason = "not-included";
        } else if (flags.some((flag) => (config.unsupportedFlags || []).includes(flag))) {
            exclusionReason = "unsupported-flag";
        } else if (includes.some((include) => (config.unsupportedIncludes || []).includes(include))) {
            exclusionReason = "unsupported-include";
        } else if (features.some((feature) => (config.unsupportedFeatures || []).includes(feature))) {
            exclusionReason = "unsupported-feature";
        }

        if (exclusionReason) {
            exclusionCounts[exclusionReason] = (exclusionCounts[exclusionReason] || 0) + 1;
            continue;
        }

        for (const mode of getModes(flags)) {
            manifestTests.push({
                id: testFile.relativePath + " [" + mode + "]",
                relativePath: testFile.relativePath,
                mode,
                async: flags.includes("async"),
                includes,
                negative: metadata.negative || null
            });
        }
    }

    let selectedTests = manifestTests;
    if (shardCount > 0) {
        selectedTests = selectedTests.filter((_, index) => index % shardCount === shardIndex);
    }

    if (limit > 0) {
        selectedTests = selectedTests.slice(0, limit);
    }

    writeManifest({
        generatedAt: new Date().toISOString(),
        enabled: true,
        reason: "generated",
        summary: {
            discovered: discoveredFiles.length,
            included: selectedTests.length,
            excluded: discoveredFiles.length - manifestTests.length,
            exclusions: exclusionCounts,
            shardCount,
            shardIndex,
            filter: activeFilterPrefixes,
            includePrefixes: activeIncludePrefixes,
            curatedIncludePrefixes: curatedPrefixes,
            limit
        },
        tests: selectedTests
    });

    console.log("Generated Test262 manifest with " + selectedTests.length + " runnable entries from " + discoveredFiles.length + " discovered test files.");
}

buildManifest();