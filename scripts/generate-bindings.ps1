param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("kotlin", "swift")]
    [string]$Language
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot
cargo xtask bindings $Language
