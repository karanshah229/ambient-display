<#
.SYNOPSIS
    Installs or removes Ambient Display for the current Windows user.

.DESCRIPTION
    Install (default):
      * copies AmbientDisplay.exe to %LOCALAPPDATA%\Programs\AmbientDisplay
      * adds a Start menu shortcut and an "Installed apps" entry (per user, no admin)
      * optionally starts it at sign-in (-LaunchAtLogin)
      * adds an inbound firewall rule for TCP 8321 on PRIVATE networks only, so your phone can reach the PC
        on home Wi-Fi but not on public networks. This one step asks for administrator approval; use
        -SkipFirewall to leave the firewall alone.
      * starts the app (unless -NoStart)

    Uninstall (-Uninstall): stops the app and removes everything above. Settings, logs and the saved Google
    sign-in under %APPDATA%\AmbientDisplay and %LOCALAPPDATA%\AmbientDisplay are kept unless you add -Purge
    (which also deletes your firebase.json).

    Works in Windows PowerShell 5.1 and PowerShell 7.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -LaunchAtLogin
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$Purge,
    [switch]$LaunchAtLogin,
    [switch]$SkipFirewall,
    [switch]$FirewallOnly,
    [switch]$NoStart,
    [string]$Source,
    [string]$InstallDir
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 does not populate $PSScriptRoot inside parameter defaults, so resolve here.
if (-not $Source) { $Source = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $InstallDir) { $InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\AmbientDisplay' }

$AppName = 'Ambient Display'
$ExeName = 'AmbientDisplay.exe'
$Exe = Join-Path $InstallDir $ExeName
$Port = 8321
$FirewallRuleName = 'Ambient Display (local network)'
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunValue = 'AmbientDisplay'
$UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AmbientDisplay'
$Shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) "$AppName.lnk"

function Write-Step([string]$message) { Write-Host "==> $message" -ForegroundColor Cyan }

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Runs firewall commands elevated (one UAC prompt). Returns $true on success.
function Invoke-Elevated([string]$script) {
    if (Test-Admin) {
        Invoke-Expression $script
        return $true
    }

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    try {
        $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -WindowStyle Hidden `
            -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded
        return $process.ExitCode -eq 0
    }
    catch {
        Write-Warning "Administrator approval was declined: $($_.Exception.Message)"
        return $false
    }
}

function Stop-AmbientDisplay {
    $running = Get-Process -Name 'AmbientDisplay' -ErrorAction SilentlyContinue
    if ($running) {
        Write-Step 'Stopping the running Ambient Display'
        $running | Stop-Process -Force
        Start-Sleep -Milliseconds 800
    }
}

function Set-FirewallRule {
    Write-Step "Allowing TCP $Port on private networks (administrator approval needed)"
    $script = @"
Remove-NetFirewallRule -DisplayName '$FirewallRuleName' -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName '$FirewallRuleName' -Description 'Lets the Ambient Display phone app reach this PC on private (home) networks.' -Direction Inbound -Action Allow -Program '$Exe' -Protocol TCP -LocalPort $Port -Profile Private | Out-Null
"@
    if (Invoke-Elevated $script) {
        Write-Host "    Firewall rule '$FirewallRuleName' added (Private profile only)."
        Write-Host '    If Windows marks your home Wi-Fi as Public, switch it to Private in Settings > Network & internet.'
    }
    else {
        Write-Warning 'Firewall rule not added. Run again with -FirewallOnly, or allow the app when Windows asks.'
    }
}

function Remove-FirewallRule {
    # Our rule, plus any rules Windows created for the installed exe when its "allow access?" prompt was answered.
    $ours = Get-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction SilentlyContinue
    $prompted = Get-NetFirewallApplicationFilter -Program $Exe -ErrorAction SilentlyContinue
    if (-not $ours -and -not $prompted) {
        return
    }

    Write-Step 'Removing firewall rules for Ambient Display (administrator approval needed)'
    $script = @"
Remove-NetFirewallRule -DisplayName '$FirewallRuleName' -ErrorAction SilentlyContinue
Get-NetFirewallApplicationFilter -Program '$Exe' -ErrorAction SilentlyContinue | Get-NetFirewallRule | Remove-NetFirewallRule
"@
    if (-not (Invoke-Elevated $script)) {
        Write-Warning 'Firewall rules for Ambient Display were left in place.'
    }
}

function Install-App {
    $sourceExe = Join-Path $Source $ExeName
    if (-not (Test-Path $sourceExe)) {
        throw "$ExeName not found in '$Source'. Run build.ps1 first, or pass -Source <folder>."
    }

    Stop-AmbientDisplay

    Write-Step "Copying to $InstallDir"
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Get-ChildItem -LiteralPath $Source -File | Where-Object { $_.Extension -ne '.zip' } |
        Copy-Item -Destination $InstallDir -Force

    Write-Step 'Adding Start menu shortcut'
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($Shortcut)
    $link.TargetPath = $Exe
    $link.WorkingDirectory = $InstallDir
    $link.IconLocation = "$Exe,0"
    $link.Description = 'Ambient Display: workstation ambient canvas and sunrise alarm'
    $link.Save()

    Write-Step 'Registering in Installed apps'
    $version = (Get-Item $Exe).VersionInfo.ProductVersion
    if ($version) { $version = ($version -split '\+')[0] }
    New-Item -Path $UninstallKey -Force | Out-Null
    $uninstallCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $InstallDir 'install.ps1')`" -Uninstall"
    $values = @{
        DisplayName     = $AppName
        DisplayVersion  = $version
        Publisher       = $AppName
        DisplayIcon     = "$Exe,0"
        InstallLocation = $InstallDir
        UninstallString = $uninstallCommand
        QuietUninstallString = "$uninstallCommand -SkipFirewall"
    }
    foreach ($entry in $values.GetEnumerator()) {
        Set-ItemProperty -Path $UninstallKey -Name $entry.Key -Value $entry.Value
    }
    Set-ItemProperty -Path $UninstallKey -Name NoModify -Value 1 -Type DWord
    Set-ItemProperty -Path $UninstallKey -Name NoRepair -Value 1 -Type DWord

    if ($LaunchAtLogin) {
        Write-Step 'Enabling launch at login'
        # Same value the app writes from Preferences > General.
        Set-ItemProperty -Path $RunKey -Name $RunValue -Value "`"$Exe`""
    }
    else {
        # Re-point an existing entry (e.g. from a dev build) at the installed copy.
        $existing = (Get-ItemProperty -Path $RunKey -Name $RunValue -ErrorAction SilentlyContinue).$RunValue
        if ($existing) { Set-ItemProperty -Path $RunKey -Name $RunValue -Value "`"$Exe`"" }
    }

    if (-not $SkipFirewall) { Set-FirewallRule }

    if (-not $NoStart) {
        Write-Step 'Starting Ambient Display'
        Start-Process -FilePath $Exe -WorkingDirectory $InstallDir
    }

    Write-Host ''
    Write-Host "$AppName $version installed. It runs from the notification area (double-click the icon for Preferences)." -ForegroundColor Green
}

function Uninstall-App {
    Stop-AmbientDisplay

    $existing = (Get-ItemProperty -Path $RunKey -Name $RunValue -ErrorAction SilentlyContinue).$RunValue
    if ($existing -and $existing.Trim('"') -ieq $Exe) {
        Write-Step 'Removing launch at login'
        Remove-ItemProperty -Path $RunKey -Name $RunValue
    }

    if (Test-Path $Shortcut) {
        Write-Step 'Removing Start menu shortcut'
        Remove-Item -LiteralPath $Shortcut -Force
    }

    if (Test-Path $UninstallKey) { Remove-Item -Path $UninstallKey -Recurse -Force }

    if (-not $SkipFirewall) { Remove-FirewallRule }

    if (Test-Path $InstallDir) {
        Write-Step "Deleting $InstallDir"
        Set-Location $env:TEMP # in case we are running from the install folder
        Remove-Item -LiteralPath $InstallDir -Recurse -Force
    }

    if ($Purge) {
        Write-Step 'Deleting settings, logs and the saved Google sign-in (including firebase.json)'
        foreach ($dir in @((Join-Path $env:APPDATA 'AmbientDisplay'), (Join-Path $env:LOCALAPPDATA 'AmbientDisplay'))) {
            if (Test-Path $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
        }
    }

    Write-Host ''
    Write-Host "$AppName removed." -ForegroundColor Green
    if (-not $Purge) { Write-Host 'Settings and sign-in were kept in %APPDATA%\AmbientDisplay (use -Purge to delete them).' }
}

if ($Uninstall) { Uninstall-App }
elseif ($FirewallOnly) { Set-FirewallRule }
else { Install-App }
