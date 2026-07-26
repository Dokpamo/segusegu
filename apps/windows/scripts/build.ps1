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

$msbuild = Get-Command "msbuild.exe" -ErrorAction Stop
& $msbuild.Source `
    $appProject `
    /nologo `
    /m `
    /t:Build `
    "/p:Configuration=$Configuration" `
    "/p:Platform=$msbuildPlatform" `
    "/p:LorepiaNativeDllPath=$resolvedNativeDll" `
    /p:RequireLorepiaNativeDll=true
if ($LASTEXITCODE -ne 0) {
    throw "WinUI build failed with exit code $LASTEXITCODE."
}

$runtimeIdentifier = "win-$Architecture"
$appExecutable = Join-Path `
    $windowsRoot `
    "Lorepia.App/bin/$msbuildPlatform/$Configuration/net8.0-windows10.0.19041.0/$runtimeIdentifier/Lorepia.App.exe"
if (-not (Test-Path -LiteralPath $appExecutable -PathType Leaf)) {
    throw "Built WinUI executable was not found at '$appExecutable'."
}

$smokeMarker = Join-Path `
    ([System.IO.Path]::GetTempPath()) `
    "lorepia-ci-smoke-$([Guid]::NewGuid().ToString('N')).txt"
$previousSmokeMarker = $env:LOREPIA_CI_SMOKE_MARKER
$env:LOREPIA_CI_SMOKE_MARKER = $smokeMarker
try {
    $smokeProcess = Start-Process `
        -FilePath $appExecutable `
        -ArgumentList "--lorepia-ci-smoke" `
        -PassThru
    if (-not $smokeProcess.WaitForExit(30000)) {
        $smokeProcess.Kill()
        $smokeProcess.WaitForExit()
        throw "WinUI launch smoke timed out after 30 seconds."
    }
    if ($smokeProcess.ExitCode -ne 0) {
        $failureMarker = if (Test-Path -LiteralPath $smokeMarker) {
            Get-Content -LiteralPath $smokeMarker -Raw
        } else {
            "no marker"
        }
        throw "WinUI launch smoke failed with exit code $($smokeProcess.ExitCode): $failureMarker"
    }
    if (-not (Test-Path -LiteralPath $smokeMarker -PathType Leaf)) {
        throw "WinUI launch smoke did not write its success marker."
    }
    $markerContents = Get-Content -LiteralPath $smokeMarker -Raw
    $expectedRouteTrace = "routes=Library>ImportReview>Chat>Settings>Library"
    if (-not $markerContents.StartsWith("LOREPIA_CI_SMOKE_OK") `
        -or -not $markerContents.Contains($expectedRouteTrace)) {
        throw "WinUI launch smoke returned an invalid marker: $markerContents"
    }
    Write-Host $markerContents
} finally {
    if ($null -eq $previousSmokeMarker) {
        Remove-Item Env:LOREPIA_CI_SMOKE_MARKER
    } else {
        $env:LOREPIA_CI_SMOKE_MARKER = $previousSmokeMarker
    }
    if (Test-Path -LiteralPath $smokeMarker) {
        Remove-Item -LiteralPath $smokeMarker -Force
    }
}
