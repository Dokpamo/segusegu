$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

$Architecture = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") {
    "arm64"
} else {
    "x64"
}

& "$RepoRoot/apps/windows/scripts/build.ps1" `
    -Architecture $Architecture `
    -Configuration Release
