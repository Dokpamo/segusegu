#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_root="$repo_root/apps/lorepia"
expected_node="v$(tr -d '[:space:]' < "$repo_root/.node-version")"

if [[ ! -f "$app_root/package.json" || ! -f "$app_root/package-lock.json" ]]; then
  echo "apps/lorepia must contain package.json and package-lock.json" >&2
  exit 1
fi

actual_node="$(node --version)"
if [[ "$actual_node" != "$expected_node" ]]; then
  echo "LorePia requires Node $expected_node, got $actual_node" >&2
  exit 1
fi

cd "$app_root"
npm ci --ignore-scripts
node "$repo_root/scripts/normalize-tauri-android-generated.mjs" --check
node "$repo_root/scripts/check-tauri-capabilities.mjs"
node "$repo_root/scripts/check-npm-licenses.mjs" --self-test
node "$repo_root/scripts/check-npm-licenses.mjs"
npm run format:check
npm run lint
npm run typecheck
npm run test
npm run test:component
npm run build
