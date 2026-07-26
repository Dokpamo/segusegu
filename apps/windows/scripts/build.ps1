[CmdletBinding()]
param(
    [ValidateSet("x64", "arm64")]
    [string]$Architecture = "x64",

    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Debug",

    [string]$NativeDllPath = ""
)

$ErrorActionPreference = "Stop"
$windowsRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$repositoryRoot = (Resolve-Path (Join-Path $windowsRoot "../..")).Path
$solution = Join-Path $windowsRoot "Lorepia.sln"
$appProject = Join-Path $windowsRoot "Lorepia.App/Lorepia.App.csproj"
$testProject = Join-Path $windowsRoot "Lorepia.Native.Tests/Lorepia.Native.Tests.csproj"
$canonicalHeader = Join-Path $repositoryRoot "bindings/c-api/include/lorepia.h"
$windowsHeader = Join-Path $windowsRoot "include/lorepia.h"

Set-Location $windowsRoot

if ((Get-FileHash $canonicalHeader -Algorithm SHA256).Hash -ne `
    (Get-FileHash $windowsHeader -Algorithm SHA256).Hash) {
    throw "The Windows C ABI header differs from the canonical header."
}

$rustTarget = if ($Architecture -eq "arm64") {
    "aarch64-pc-windows-msvc"
} else {
    "x86_64-pc-windows-msvc"
}
$msbuildPlatform = if ($Architecture -eq "arm64") { "ARM64" } else { "x64" }
$cargoProfile = if ($Configuration -eq "Release") { "release" } else { "debug" }

if ([string]::IsNullOrWhiteSpace($NativeDllPath)) {
    $cargoArguments = @(
        "build",
        "--locked",
        "--package",
        "lorepia-c-api",
        "--target",
        $rustTarget
    )
    if ($Configuration -eq "Release") {
        $cargoArguments += "--release"
    }

    Push-Location $repositoryRoot
    try {
        & cargo @cargoArguments
        if ($LASTEXITCODE -ne 0) {
            throw "cargo build failed with exit code $LASTEXITCODE."
        }
    } finally {
        Pop-Location
    }

    $NativeDllPath = Join-Path `
        $repositoryRoot `
        "target/$rustTarget/$cargoProfile/lorepia_core.dll"
}

if (-not (Test-Path -LiteralPath $NativeDllPath -PathType Leaf)) {
    throw "LorePia native DLL was not found at '$NativeDllPath'."
}

$resolvedNativeDll = (Resolve-Path -LiteralPath $NativeDllPath).Path
Write-Host "LorePia native DLL: $resolvedNativeDll"
Write-Host "Target architecture: $msbuildPlatform ($rustTarget)"

& dotnet restore `
    $solution `
    "--property:Platform=$msbuildPlatform"
if ($LASTEXITCODE -ne 0) {
    throw "dotnet restore failed with exit code $LASTEXITCODE."
}

$previousLiveTest = $env:LOREPIA_RUN_LIVE_NATIVE_TESTS
$env:LOREPIA_RUN_LIVE_NATIVE_TESTS = "1"
try {
    & dotnet test `
        $testProject `
        --configuration $Configuration `
        --no-restore `
        "--property:LorepiaNativeDllPath=$resolvedNativeDll" `
        "--property:RequireLorepiaNativeDll=true"
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet test failed with exit code $LASTEXITCODE."
    }
} finally {
    if ($null -eq $previousLiveTest) {
        Remove-Item Env:LOREPIA_RUN_LIVE_NATIVE_TESTS
    } else {
        $env:LOREPIA_RUN_LIVE_NATIVE_TESTS = $previousLiveTest
    }
}

& dotnet build `
    $appProject `
    --configuration $Configuration `
    --no-restore `
    "--property:Platform=$msbuildPlatform" `
    "--property:LorepiaNativeDllPath=$resolvedNativeDll" `
    "--property:RequireLorepiaNativeDll=true"
if ($LASTEXITCODE -ne 0) {
    throw "WinUI build failed with exit code $LASTEXITCODE."
}
