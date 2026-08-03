#!/usr/bin/env node

import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const exactSemverPattern =
    /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/u;
const sha512IntegrityPattern = /^sha512-[A-Za-z0-9+/]+={0,2}$/u;
const expectedNodeVersion = "24.18.1";

const allowedLicenses = new Set([
    "Apache-2.0",
    "BSD-2-Clause",
    "BSD-3-Clause",
    "CDLA-Permissive-2.0",
    "ISC",
    "MIT",
    "Unicode-3.0",
    "Zlib",
]);

const lightningCssPackages = [
    "lightningcss",
    "lightningcss-android-arm64",
    "lightningcss-darwin-arm64",
    "lightningcss-darwin-x64",
    "lightningcss-freebsd-x64",
    "lightningcss-linux-arm-gnueabihf",
    "lightningcss-linux-arm64-gnu",
    "lightningcss-linux-arm64-musl",
    "lightningcss-linux-x64-gnu",
    "lightningcss-linux-x64-musl",
    "lightningcss-win32-arm64-msvc",
    "lightningcss-win32-x64-msvc",
];

// These are exact, dev-only engineering approvals for the initial locked graph.
// Moving one into the runtime graph, changing its version/license, adding another
// package, or removing it requires an explicit review and an update to this list.
const reviewedExceptions = new Map([
    [
        "@csstools/color-helpers@6.1.0",
        {
            license: "MIT-0",
            rationale: "jsdom test-only CSS parser dependency; not distributed",
        },
    ],
    [
        "@csstools/css-syntax-patches-for-csstree@1.1.7",
        {
            license: "MIT-0",
            rationale: "jsdom test-only CSS parser data; not distributed",
        },
    ],
    [
        "lru-cache@11.5.2",
        {
            license: "BlueOak-1.0.0",
            rationale:
                "ESLint and jsdom development dependency; not distributed",
        },
    ],
    [
        "mdn-data@2.27.1",
        {
            license: "CC0-1.0",
            rationale: "jsdom test-only standards data; not distributed",
        },
    ],
    [
        "minimatch@10.2.6",
        {
            license: "BlueOak-1.0.0",
            rationale: "ESLint development dependency; not distributed",
        },
    ],
    [
        "tslib@2.8.1",
        {
            license: "0BSD",
            rationale:
                "optional Rolldown build-tool dependency; not distributed",
        },
    ],
    ...lightningCssPackages.map((name) => [
        `${name}@1.33.0`,
        {
            license: "MPL-2.0",
            rationale:
                "Vite CSS build tool or platform binary; not distributed",
        },
    ]),
]);

function tokenize(expression) {
    const tokens = [];
    let cursor = 0;
    while (cursor < expression.length) {
        const remaining = expression.slice(cursor);
        const whitespace = remaining.match(/^\s+/u);
        if (whitespace) {
            cursor += whitespace[0].length;
            continue;
        }
        const punctuation = remaining[0];
        if (punctuation === "(" || punctuation === ")") {
            tokens.push(punctuation);
            cursor += 1;
            continue;
        }
        const word = remaining.match(/^[A-Za-z0-9][A-Za-z0-9.+-]*/u);
        if (!word) {
            throw new Error(
                `invalid SPDX token near ${JSON.stringify(remaining)}`,
            );
        }
        tokens.push(word[0]);
        cursor += word[0].length;
    }
    return tokens;
}

function parseSpdx(expression) {
    if (typeof expression !== "string" || expression.trim() === "") {
        throw new Error("missing SPDX license expression");
    }
    const tokens = tokenize(expression);
    let cursor = 0;

    function parsePrimary() {
        const token = tokens[cursor];
        if (token === "(") {
            cursor += 1;
            const value = parseOr();
            if (tokens[cursor] !== ")") {
                throw new Error("unclosed SPDX expression");
            }
            cursor += 1;
            return value;
        }
        if (!token || token === ")" || token === "AND" || token === "OR") {
            throw new Error(
                `expected SPDX license identifier, got ${token ?? "end"}`,
            );
        }
        if (token === "WITH") {
            throw new Error("SPDX WITH expressions require manual approval");
        }
        cursor += 1;
        if (tokens[cursor] === "WITH") {
            throw new Error("SPDX WITH expressions require manual approval");
        }
        return { type: "license", value: token };
    }

    function parseAnd() {
        let value = parsePrimary();
        while (tokens[cursor] === "AND") {
            cursor += 1;
            value = { type: "AND", left: value, right: parsePrimary() };
        }
        return value;
    }

    function parseOr() {
        let value = parseAnd();
        while (tokens[cursor] === "OR") {
            cursor += 1;
            value = { type: "OR", left: value, right: parseAnd() };
        }
        return value;
    }

    const parsed = parseOr();
    if (cursor !== tokens.length) {
        throw new Error(`unexpected SPDX token ${tokens[cursor]}`);
    }
    return parsed;
}

function evaluateSpdx(node) {
    if (node.type === "license") {
        return {
            allowed: allowedLicenses.has(node.value),
            selected: node.value,
        };
    }
    const left = evaluateSpdx(node.left);
    const right = evaluateSpdx(node.right);
    if (node.type === "AND") {
        return {
            allowed: left.allowed && right.allowed,
            selected: `${left.selected} AND ${right.selected}`,
        };
    }
    if (left.allowed) {
        return left;
    }
    return right;
}

function canonicalSpdx(node) {
    if (node.type === "license") {
        return node.value;
    }
    const children = [];
    function collect(candidate) {
        if (candidate.type === node.type) {
            collect(candidate.left);
            collect(candidate.right);
        } else {
            children.push(canonicalSpdx(candidate));
        }
    }
    collect(node);
    return `${node.type}(${children.sort().join(",")})`;
}

function inspectExpression(expression) {
    const parsed = parseSpdx(expression);
    return {
        ...evaluateSpdx(parsed),
        canonical: canonicalSpdx(parsed),
    };
}

function inspectPackageLicense(name, version, expression, devOnly) {
    const result = inspectExpression(expression);
    if (result.allowed) {
        return result;
    }
    const key = `${name}@${version}`;
    const approval = reviewedExceptions.get(key);
    if (
        approval &&
        devOnly === true &&
        inspectExpression(approval.license).canonical === result.canonical
    ) {
        return {
            ...result,
            allowed: true,
            reviewedException: approval,
        };
    }
    return result;
}

function runSelfTest() {
    assert.equal(exactSemverPattern.test("2.11.4"), true);
    assert.equal(exactSemverPattern.test("^2.11.4"), false);
    assert.equal(
        exactSemverPattern.test("https://example.invalid/package.tgz"),
        false,
    );
    assert.equal(sha512IntegrityPattern.test("sha512-YWJjZA=="), true);
    assert.equal(sha512IntegrityPattern.test("sha512-not base64"), false);
    assert.equal(sha512IntegrityPattern.test("sha256-YWJjZA=="), false);
    assert.equal(inspectExpression("MIT").allowed, true);
    assert.equal(inspectExpression("(MIT OR Apache-2.0)").allowed, true);
    assert.equal(inspectExpression("GPL-3.0-only OR MIT").selected, "MIT");
    assert.equal(inspectExpression("MIT AND BSD-3-Clause").allowed, true);
    assert.equal(inspectExpression("MIT AND GPL-3.0-only").allowed, false);
    assert.equal(inspectExpression("MPL-2.0").allowed, false);
    assert.throws(() =>
        inspectExpression("GPL-2.0-only WITH Classpath-exception-2.0"),
    );
    assert.throws(() => inspectExpression("SEE LICENSE IN LICENSE"));
    assert.equal(
        inspectPackageLicense("minimatch", "10.2.6", "BlueOak-1.0.0", true)
            .allowed,
        true,
    );
    assert.equal(
        inspectPackageLicense("minimatch", "10.2.6", "BlueOak-1.0.0", false)
            .allowed,
        false,
    );
    assert.equal(
        inspectPackageLicense("minimatch", "10.2.7", "BlueOak-1.0.0", true)
            .allowed,
        false,
    );
    assert.equal(
        inspectExpression("MIT OR (Apache-2.0 OR ISC)").canonical,
        inspectExpression("(ISC OR MIT) OR Apache-2.0").canonical,
    );
    console.log("npm license checker self-test passed");
}

function packageNameFromLockPath(lockPath, record) {
    if (typeof record.name === "string" && record.name !== "") {
        return record.name;
    }
    const marker = "node_modules/";
    const offset = lockPath.lastIndexOf(marker);
    return offset === -1 ? lockPath : lockPath.slice(offset + marker.length);
}

function inspectLockfile() {
    const scriptDirectory = dirname(fileURLToPath(import.meta.url));
    const repositoryRoot = resolve(scriptDirectory, "..");
    const applicationRoot = resolve(repositoryRoot, "apps/lorepia");
    const lockPath = resolve(applicationRoot, "package-lock.json");
    const nodeModulesRoot = resolve(applicationRoot, "node_modules");
    const applicationManifest = JSON.parse(
        readFileSync(resolve(applicationRoot, "package.json"), "utf8"),
    );
    const lock = JSON.parse(readFileSync(lockPath, "utf8"));

    if (lock.lockfileVersion !== 3 || typeof lock.packages !== "object") {
        throw new Error(
            "apps/lorepia/package-lock.json must use npm lockfileVersion 3",
        );
    }

    const failures = [];
    const consumedExceptions = new Set();
    const approvedExceptions = [];
    const selectedBranches = [];
    let inspected = 0;

    const nodeVersion = readFileSync(
        resolve(repositoryRoot, ".node-version"),
        "utf8",
    ).trim();
    if (nodeVersion !== expectedNodeVersion) {
        failures.push(
            `.node-version must remain exactly pinned to ${expectedNodeVersion}, got ${nodeVersion}`,
        );
    }

    const dependencyGroups = [
        ["dependencies", applicationManifest.dependencies ?? {}],
        ["devDependencies", applicationManifest.devDependencies ?? {}],
    ];
    for (const [groupName, dependencies] of dependencyGroups) {
        for (const [name, version] of Object.entries(dependencies)) {
            if (
                typeof version !== "string" ||
                !exactSemverPattern.test(version)
            ) {
                failures.push(
                    `${groupName}.${name} must use an exact semver, got ${version}`,
                );
            }
            const lockedSpecifier = lock.packages[""]?.[groupName]?.[name];
            if (lockedSpecifier !== version) {
                failures.push(
                    `${groupName}.${name}=${version} differs from lockfile root ${lockedSpecifier}`,
                );
            }
            const lockedVersion =
                lock.packages[`node_modules/${name}`]?.version;
            if (lockedVersion !== version) {
                failures.push(
                    `${name}=${version} resolves directly to ${lockedVersion}`,
                );
            }
        }
    }

    for (const [name, expectedVersion] of [
        ["@tauri-apps/api", "2.11.1"],
        ["@tauri-apps/cli", "2.11.4"],
    ]) {
        const actualVersion =
            applicationManifest.dependencies?.[name] ??
            applicationManifest.devDependencies?.[name];
        if (actualVersion !== expectedVersion) {
            failures.push(
                `${name} must remain exactly pinned to ${expectedVersion}`,
            );
        }
    }

    for (const [relativeManifest, packageName, expectedVersion] of [
        ["apps/lorepia/src-tauri/Cargo.toml", "tauri", "2.11.5"],
        ["apps/lorepia/src-tauri/Cargo.toml", "tauri-build", "2.6.3"],
        ["plugins/lorepia-platform/Cargo.toml", "tauri", "2.11.5"],
        ["plugins/lorepia-platform/Cargo.toml", "tauri-plugin", "2.6.3"],
    ]) {
        const cargoManifest = readFileSync(
            resolve(repositoryRoot, relativeManifest),
            "utf8",
        );
        const escapedVersion = expectedVersion.replaceAll(".", String.raw`\.`);
        const exactPin = new RegExp(
            String.raw`^${packageName}\s*=\s*\{[^\n]*version\s*=\s*"=${escapedVersion}"`,
            "mu",
        );
        if (!exactPin.test(cargoManifest)) {
            failures.push(
                `${relativeManifest} must exactly pin ${packageName} to =${expectedVersion}`,
            );
        }
    }

    for (const [packagePath, record] of Object.entries(lock.packages).sort(
        ([a], [b]) => a.localeCompare(b),
    )) {
        if (packagePath === "") {
            continue;
        }
        const name = packageNameFromLockPath(packagePath, record);
        inspected += 1;

        if (
            !packagePath.startsWith("node_modules/") ||
            packagePath.includes("\\")
        ) {
            failures.push(
                `${name}: unsafe or unsupported lockfile path ${packagePath}`,
            );
            continue;
        }
        if (record.link === true) {
            failures.push(`${name}: linked dependencies are not allowed`);
            continue;
        }
        if (
            typeof record.version !== "string" ||
            !exactSemverPattern.test(record.version)
        ) {
            failures.push(
                `${name}: dependency version is not an exact semver (${record.version})`,
            );
        }
        if (
            typeof record.resolved !== "string" ||
            !record.resolved.startsWith("https://registry.npmjs.org/")
        ) {
            failures.push(
                `${name}@${record.version}: dependency is not pinned to the npm registry`,
            );
        }
        if (
            typeof record.integrity !== "string" ||
            !sha512IntegrityPattern.test(record.integrity)
        ) {
            failures.push(
                `${name}@${record.version}: missing sha512 registry integrity`,
            );
        }

        let lockLicense;
        try {
            lockLicense = inspectPackageLicense(
                name,
                record.version,
                record.license,
                record.dev === true,
            );
            if (!lockLicense.allowed) {
                failures.push(
                    `${name}@${record.version}: license ${record.license} has no approved SPDX branch`,
                );
            } else if (lockLicense.reviewedException) {
                const key = `${name}@${record.version}`;
                consumedExceptions.add(key);
                approvedExceptions.push(
                    `${key}: ${record.license}; ${lockLicense.reviewedException.rationale}`,
                );
            } else if (lockLicense.selected !== record.license) {
                selectedBranches.push(
                    `${name}@${record.version}: ${record.license} -> ${lockLicense.selected}`,
                );
            }
        } catch (error) {
            failures.push(`${name}@${record.version}: ${error.message}`);
            continue;
        }

        const manifestPath = resolve(
            applicationRoot,
            packagePath,
            "package.json",
        );
        const pathFromModules = relative(nodeModulesRoot, manifestPath);
        if (
            pathFromModules.startsWith(`..${sep}`) ||
            pathFromModules === ".."
        ) {
            failures.push(
                `${name}@${record.version}: installed manifest escapes node_modules`,
            );
            continue;
        }
        if (!existsSync(manifestPath)) {
            if (record.optional !== true) {
                failures.push(
                    `${name}@${record.version}: installed package manifest is missing`,
                );
            }
            continue;
        }

        try {
            const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
            const installedLicense = inspectPackageLicense(
                name,
                record.version,
                manifest.license,
                record.dev === true,
            );
            if (!installedLicense.allowed) {
                failures.push(
                    `${name}@${record.version}: installed license ${manifest.license} is not approved`,
                );
            }
            if (installedLicense.canonical !== lockLicense.canonical) {
                failures.push(
                    `${name}@${record.version}: lock license ${record.license} differs from installed artifact ${manifest.license}`,
                );
            }
            if (manifest.version !== record.version) {
                failures.push(
                    `${name}@${record.version}: installed artifact version is ${manifest.version}`,
                );
            }
        } catch (error) {
            failures.push(
                `${name}@${record.version}: cannot inspect installed artifact: ${error.message}`,
            );
        }
    }

    for (const key of reviewedExceptions.keys()) {
        if (!consumedExceptions.has(key)) {
            failures.push(
                `${key}: stale reviewed license exception is not present in the lockfile`,
            );
        }
    }

    if (failures.length > 0) {
        console.error("npm dependency/license gate failed:");
        for (const failure of failures) {
            console.error(`- ${failure}`);
        }
        process.exitCode = 1;
        return;
    }

    console.log(
        `npm dependency/license gate passed for ${inspected} locked packages`,
    );
    for (const selection of selectedBranches) {
        console.log(`selected SPDX branch: ${selection}`);
    }
    for (const approval of approvedExceptions) {
        console.log(`reviewed dev-only exception: ${approval}`);
    }
}

if (process.argv.includes("--self-test")) {
    runSelfTest();
} else {
    inspectLockfile();
}
