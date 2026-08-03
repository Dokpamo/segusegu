#!/usr/bin/env node

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join, resolve } from "node:path";

const usage =
  "usage: node scripts/normalize-tauri-android-generated.mjs [--check]";
const argumentsList = process.argv.slice(2);
if (
  argumentsList.length > 1 ||
  (argumentsList.length === 1 && argumentsList[0] !== "--check")
) {
  console.error(usage);
  process.exit(2);
}

const checkOnly = argumentsList[0] === "--check";
const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = resolve(scriptDirectory, "..");
const androidRoot = join(
  repositoryRoot,
  "apps",
  "lorepia",
  "src-tauri",
  "gen",
  "android",
);
const manifestPath = join(
  androidRoot,
  "app",
  "src",
  "main",
  "AndroidManifest.xml",
);
const capturePathsPath = join(
  androidRoot,
  "app",
  "src",
  "main",
  "res",
  "xml",
  "file_paths.xml",
);
const wrapperPropertiesPath = join(
  androidRoot,
  "gradle",
  "wrapper",
  "gradle-wrapper.properties",
);

const canonicalCapturePaths = `<?xml version="1.0" encoding="utf-8"?>
<paths xmlns:android="http://schemas.android.com/apk/res/android">
    <external-files-path
        name="tauri_capture_images"
        path="Pictures/" />
</paths>
`;

const generatedBroadCapturePaths = `<?xml version="1.0" encoding="utf-8"?>
<paths xmlns:android="http://schemas.android.com/apk/res/android">
  <external-path name="my_images" path="." />
  <cache-path name="my_cache_images" path="." />
</paths>
`;

const expectedWrapperProperties = new Map([
  [
    "distributionUrl",
    "https\\://services.gradle.org/distributions/gradle-8.14.3-bin.zip",
  ],
  [
    "distributionSha256Sum",
    "bd71102213493060956ec229d946beee57158dbd89d0e62b91bca0fa2c5f3531",
  ],
  ["networkTimeout", "10000"],
  ["validateDistributionUrl", "true"],
]);

function fail(message) {
  console.error(`Tauri Android generated-source check failed: ${message}`);
  process.exit(1);
}

function readUtf8(filePath) {
  try {
    return readFileSync(filePath, "utf8");
  } catch (error) {
    fail(`${filePath} could not be read: ${error.message}`);
  }
}

function occurrences(value, pattern) {
  return [...value.matchAll(pattern)].length;
}

function requireSingleAttribute(tag, name, expectedValue) {
  const escapedName = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const matches = [
    ...tag.matchAll(new RegExp(`\\b${escapedName}="([^"]*)"`, "g")),
  ];
  if (matches.length !== 1 || matches[0][1] !== expectedValue) {
    fail(`${name} must occur once with value ${expectedValue}`);
  }
}

function checkFileProvider(manifest) {
  const providerBlocks = [
    ...manifest.matchAll(/<provider\b[^>]*>[\s\S]*?<\/provider>/g),
  ].map((match) => match[0]);
  const fileProviderBlocks = providerBlocks.filter((block) =>
    block.includes('android:name="androidx.core.content.FileProvider"'),
  );
  if (fileProviderBlocks.length !== 1) {
    fail("the generated manifest must contain exactly one AndroidX FileProvider");
  }

  const provider = fileProviderBlocks[0];
  const openingTag = provider.match(/^<provider\b[^>]*>/)?.[0];
  if (!openingTag) {
    fail("the FileProvider opening tag is malformed");
  }
  requireSingleAttribute(
    openingTag,
    "android:name",
    "androidx.core.content.FileProvider",
  );
  requireSingleAttribute(
    openingTag,
    "android:authorities",
    "${applicationId}.fileprovider",
  );
  requireSingleAttribute(openingTag, "android:exported", "false");
  requireSingleAttribute(openingTag, "android:grantUriPermissions", "true");

  const providerAttributes = [
    ...openingTag.matchAll(/\bandroid:([A-Za-z][A-Za-z0-9_]*)="[^"]*"/g),
  ]
    .map((match) => match[1])
    .sort();
  const expectedProviderAttributes = [
    "authorities",
    "exported",
    "grantUriPermissions",
    "name",
  ].sort();
  if (
    JSON.stringify(providerAttributes) !==
    JSON.stringify(expectedProviderAttributes)
  ) {
    fail("the FileProvider has an unexpected Android attribute");
  }

  const metadataTags = [
    ...provider.matchAll(/<meta-data\b[^>]*\/>/g),
  ].map((match) => match[0]);
  if (metadataTags.length !== 1) {
    fail("the FileProvider must contain exactly one self-closing metadata tag");
  }
  requireSingleAttribute(
    metadataTags[0],
    "android:name",
    "android.support.FILE_PROVIDER_PATHS",
  );
  requireSingleAttribute(
    metadataTags[0],
    "android:resource",
    "@xml/file_paths",
  );

  const metadataAttributes = [
    ...metadataTags[0].matchAll(
      /\bandroid:([A-Za-z][A-Za-z0-9_]*)="[^"]*"/g,
    ),
  ]
    .map((match) => match[1])
    .sort();
  if (
    JSON.stringify(metadataAttributes) !==
    JSON.stringify(["name", "resource"])
  ) {
    fail("the FileProvider metadata has an unexpected Android attribute");
  }

  const remainingBody = provider
    .replace(openingTag, "")
    .replace(metadataTags[0], "")
    .replace("</provider>", "")
    .trim();
  if (remainingBody !== "") {
    fail("the FileProvider contains an unexpected child element");
  }
}

function normalizeNewlines(value) {
  return value.replaceAll("\r\n", "\n");
}

function normalizeWrapperProperties(contents) {
  const hadFinalNewline = contents.endsWith("\n");
  const lines = normalizeNewlines(contents).split("\n");
  if (lines.at(-1) === "") {
    lines.pop();
  }

  for (const [key, expectedValue] of expectedWrapperProperties) {
    const indexes = [];
    for (const [index, line] of lines.entries()) {
      if (line.startsWith(`${key}=`)) {
        indexes.push(index);
      }
    }
    if (indexes.length > 1) {
      fail(`${key} occurs more than once in gradle-wrapper.properties`);
    }

    if (key === "distributionUrl") {
      if (indexes.length !== 1 || lines[indexes[0]] !== `${key}=${expectedValue}`) {
        fail(
          "the generated Gradle distribution URL changed; review and update the pinned checksum deliberately",
        );
      }
      continue;
    }

    if (indexes.length === 1) {
      lines[indexes[0]] = `${key}=${expectedValue}`;
      continue;
    }

    const insertionAnchor =
      key === "distributionSha256Sum"
        ? lines.findIndex((line) => line.startsWith("distributionUrl="))
        : key === "networkTimeout"
          ? lines.findIndex((line) =>
              line.startsWith("distributionPath="),
            )
          : lines.findIndex((line) => line.startsWith("networkTimeout="));
    if (insertionAnchor < 0) {
      fail(`could not find a safe insertion point for ${key}`);
    }
    lines.splice(insertionAnchor + 1, 0, `${key}=${expectedValue}`);
  }

  return `${lines.join("\n")}${hadFinalNewline ? "\n" : ""}`;
}

const manifest = readUtf8(manifestPath);
checkFileProvider(manifest);

const currentCapturePaths = normalizeNewlines(readUtf8(capturePathsPath));
if (
  currentCapturePaths !== canonicalCapturePaths &&
  currentCapturePaths !== generatedBroadCapturePaths
) {
  fail(
    "file_paths.xml is neither the audited Tauri 2.11.4 generator output nor the LorePia canonical policy",
  );
}

const currentWrapperProperties = readUtf8(wrapperPropertiesPath);
const normalizedWrapperProperties = normalizeWrapperProperties(
  currentWrapperProperties,
);

if (checkOnly) {
  if (currentCapturePaths !== canonicalCapturePaths) {
    fail("file_paths.xml has not been normalized to the app-owned Pictures path");
  }
  if (currentWrapperProperties !== normalizedWrapperProperties) {
    fail("gradle-wrapper.properties has not been normalized");
  }
  console.log("Tauri Android generated-source normalization check passed");
  process.exit(0);
}

if (currentCapturePaths !== canonicalCapturePaths) {
  writeFileSync(capturePathsPath, canonicalCapturePaths, "utf8");
}
if (currentWrapperProperties !== normalizedWrapperProperties) {
  writeFileSync(
    wrapperPropertiesPath,
    normalizedWrapperProperties,
    "utf8",
  );
}
console.log("Tauri Android generated-source normalization complete");
