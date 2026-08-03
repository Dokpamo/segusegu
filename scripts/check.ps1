$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

function Invoke-Checked {
    param([scriptblock]$Command)
    & $Command
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

foreach ($RequiredPath in @(
    "$RepoRoot/apps/lorepia/package.json",
    "$RepoRoot/apps/lorepia/package-lock.json"
)) {
    if (-not (Test-Path $RequiredPath -PathType Leaf)) {
        throw "Required Tauri frontend manifest is missing: $RequiredPath"
    }
}

$ExpectedNode = "v$((Get-Content "$RepoRoot/.node-version" -Raw).Trim())"
$ActualNode = node --version
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
if ($ActualNode.Trim() -ne $ExpectedNode) {
    throw "LorePia requires Node $ExpectedNode, got $($ActualNode.Trim())"
}

Push-Location "$RepoRoot/apps/lorepia"
try {
    Invoke-Checked { npm ci --ignore-scripts }
    Invoke-Checked { node "$RepoRoot/scripts/check-npm-licenses.mjs" --self-test }
    Invoke-Checked { node "$RepoRoot/scripts/check-npm-licenses.mjs" }
    Invoke-Checked { node "$RepoRoot/scripts/check-tauri-capabilities.mjs" }
    Invoke-Checked { npm run format:check }
    Invoke-Checked { npm run lint }
    Invoke-Checked { npm run typecheck }
    Invoke-Checked { npm run test }
    Invoke-Checked { npm run test:component }
    Invoke-Checked { npm run build }
}
finally {
    Pop-Location
}

Invoke-Checked { cargo fmt --all --check }
Invoke-Checked { cargo clippy --workspace --all-targets --all-features --locked -- -D warnings }
Invoke-Checked { cargo test --workspace --all-features --locked }
$env:RUSTDOCFLAGS = "-D warnings"
Invoke-Checked { cargo doc --workspace --no-deps --locked }
Invoke-Checked { cargo xtask check repository }
