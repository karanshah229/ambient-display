<#
.SYNOPSIS
    Builds a release of Ambient Display for Windows (the counterpart of `make bundle` on macOS).

.DESCRIPTION
    1. Runs the unit tests (skip with -SkipTests).
    2. Publishes a self-contained, single-file AmbientDisplay.exe (no .NET install needed on the target PC).
    3. Copies install.ps1 next to it and zips the folder.

    Output: windows-app/dist/AmbientDisplay-<version>-<runtime>/ and a matching .zip.

.EXAMPLE
    pwsh windows-app/build.ps1
.EXAMPLE
    pwsh windows-app/build.ps1 -Version 1.1.0 -Runtime win-arm64 -SkipTests
#>
[CmdletBinding()]
param(
    [string]$Version,
    [ValidateSet('win-x64', 'win-arm64')]
    [string]$Runtime = 'win-x64',
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

$dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
$dotnet = if ($dotnetCommand) { $dotnetCommand.Source } else { Join-Path $env:ProgramFiles 'dotnet\dotnet.exe' }
if (-not (Test-Path $dotnet)) { throw 'The .NET 10 SDK is required: winget install Microsoft.DotNet.SDK.10' }
$env:DOTNET_NOLOGO = '1'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'

if (-not $Version) {
    $Version = ([xml](Get-Content (Join-Path $root 'Directory.Build.props'))).Project.PropertyGroup.Version
}

$name = "AmbientDisplay-$Version-$Runtime"
$dist = Join-Path $root 'dist'
$out = Join-Path $dist $name
$zip = "$out.zip"

if (-not $SkipTests) {
    Write-Host "==> Running tests" -ForegroundColor Cyan
    & $dotnet test (Join-Path $root 'AmbientDisplay.slnx') -c Release --nologo
    if ($LASTEXITCODE -ne 0) { throw 'Tests failed; release not built.' }
}

Write-Host "==> Publishing $name" -ForegroundColor Cyan
if (Test-Path $out) { Remove-Item -Recurse -Force -LiteralPath $out }
& $dotnet publish (Join-Path $root 'src\AmbientDisplay.App\AmbientDisplay.App.csproj') `
    -c Release -r $Runtime --self-contained true `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:EnableCompressionInSingleFile=true `
    -p:DebugType=none `
    -p:Version=$Version `
    -o $out --nologo
if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed.' }

# NuGet XML API docs (from the WebView2 package) are not needed at runtime.
Get-ChildItem -LiteralPath $out -Filter '*.xml' | Remove-Item -Force

Copy-Item (Join-Path $root 'install.ps1') $out
@"
Ambient Display $Version for Windows ($Runtime)

Install (per user, no admin needed except for the optional firewall rule):
    powershell -ExecutionPolicy Bypass -File .\install.ps1

Options:
    -LaunchAtLogin      start Ambient Display when you sign in
    -SkipFirewall       do not add the private-network firewall rule (no admin prompt)
    -FirewallOnly       only (re)create the firewall rule
    -Uninstall          remove the app (add -Purge to also delete settings and the saved sign-in)

Cloud sync is optional: see docs/DEPLOYMENT_GUIDE.md (Windows section) for firebase.json.
"@ | Set-Content -Encoding utf8 (Join-Path $out 'INSTALL.txt')

if (Test-Path $zip) { Remove-Item -Force -LiteralPath $zip }
Compress-Archive -Path (Join-Path $out '*') -DestinationPath $zip

$exe = Get-Item (Join-Path $out 'AmbientDisplay.exe')
Write-Host ''
Write-Host "Built $($exe.FullName) ($([math]::Round($exe.Length / 1MB, 1)) MB)" -ForegroundColor Green
Write-Host "Zip   $zip ($([math]::Round((Get-Item $zip).Length / 1MB, 1)) MB)" -ForegroundColor Green
Write-Host "Install with: powershell -ExecutionPolicy Bypass -File `"$(Join-Path $out 'install.ps1')`""
