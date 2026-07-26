[CmdletBinding()]
param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Debug"
)

$ErrorActionPreference = "Stop"
$windowsRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$testProject = Join-Path $windowsRoot "Lorepia.Native.Tests/Lorepia.Native.Tests.csproj"

& dotnet restore $testProject
if ($LASTEXITCODE -ne 0) {
    throw "dotnet restore failed with exit code $LASTEXITCODE."
}

& dotnet test $testProject --configuration $Configuration --no-restore
if ($LASTEXITCODE -ne 0) {
    throw "dotnet test failed with exit code $LASTEXITCODE."
}
