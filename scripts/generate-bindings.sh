#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

language="${1:?usage: generate-bindings.sh kotlin|swift}"
cargo xtask bindings "$language"
