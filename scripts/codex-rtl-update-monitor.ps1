<#
.SYNOPSIS
  Checks Microsoft Store for Codex updates and reapplies the RTL patch when safe.

.DESCRIPTION
  This script is intended for Codex/Windows automations. It checks the Microsoft
  Store package for Codex through winget, installs the official Store update
  when available, and then reapplies the RTL patch if the local RTL copy is older.

  It never force-closes Codex. If Codex RTL is running, it asks the user to end
  the task first, because closing the window with X can leave Electron processes
  alive and lock app.asar.
#>
param(
    [string]$StoreId = '9PLM9XGG6VKS',
    [string]$InstallerUrl = 'https://raw.githubusercontent.com/mnigli/codex-desktop-rtl-patch/main/install.ps1',
    [switch]$CheckOnly,
    [switch]$SkipStoreUpdate,
    [switch]$SkipRtlPatch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$InstallRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\CodexRtl'
$TargetAppDir = Join-Path $InstallRoot 'app'
$StatePath = Join-Path $InstallRoot 'patch-state.json'
$ScriptPath = $MyInvocation.MyCommand.Path
$RepoRoot = if ($ScriptPath) { Split-Path -Parent (Split-Path -Parent $ScriptPath) } else { $null }
$LocalInstaller = if ($RepoRoot) { Join-Path $RepoRoot 'install.ps1' } else { $null }

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Ok([string]$Message) {
    Write-Host "OK  $Message" -ForegroundColor Green
}

function Write-Warn([string]$Message) {
    Write-Host "WARN $Message" -ForegroundColor Yellow
}

function Get-WingetCommand {
    $cmd = Get-Command 'winget.exe' -ErrorAction SilentlyContinue
    if (-not $cmd) { $cmd = Get-Command 'winget' -ErrorAction SilentlyContinue }
    if (-not $cmd) {
        throw 'winget was not found. Install App Installer from Microsoft Store.'
    }
    return $cmd.Source
}

function Invoke-Winget([string[]]$Arguments) {
    $output = & $script:Winget @Arguments 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    [pscustomobject]@{
        ExitCode = $exitCode
        Output = $output.Trim()
    }
}

function Test-WingetUpgradeAvailable([string]$PackageId) {
    $result = Invoke-Winget @(
        'upgrade',
        '--id', $PackageId,
        '--source', 'msstore',
        '--accept-source-agreements',
        '--disable-interactivity'
    )

    if ($result.Output -match 'No available upgrade found|No newer package versions are available') {
        return [pscustomobject]@{ Available = $false; Output = $result.Output }
    }

    if ($result.Output -match [regex]::Escape($PackageId)) {
        return [pscustomobject]@{ Available = $true; Output = $result.Output }
    }

    return [pscustomobject]@{ Available = $false; Output = $result.Output }
}

function Install-StoreUpgrade([string]$PackageId) {
    Invoke-Winget @(
        'upgrade',
        '--id', $PackageId,
        '--source', 'msstore',
        '--accept-source-agreements',
        '--accept-package-agreements',
        '--disable-interactivity'
    )
}

function Get-CodexPackage {
    $pkg = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if (-not $pkg) {
        throw 'OpenAI.Codex package was not found. Install Codex Desktop first.'
    }
    return $pkg
}

function Get-RtlState {
    if (-not (Test-Path -LiteralPath $StatePath)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    } catch {
        Write-Warn "Could not read RTL patch state: $($_.Exception.Message)"
        return $null
    }
}

function Get-RtlProcesses {
    $target = [System.IO.Path]::GetFullPath($TargetAppDir).TrimEnd('\')
    Get-CimInstance Win32_Process -Filter "name = 'Codex.exe' OR name = 'codex.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ExecutablePath -and
            [System.IO.Path]::GetFullPath($_.ExecutablePath).StartsWith(
                $target,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        }
}

function Invoke-RtlInstaller {
    if ($LocalInstaller -and (Test-Path -LiteralPath $LocalInstaller)) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $LocalInstaller
        if ($LASTEXITCODE -ne 0) {
            throw "Local installer failed with exit code $LASTEXITCODE"
        }
        return
    }

    $scriptText = Invoke-RestMethod -Uri $InstallerUrl -UseBasicParsing
    Invoke-Expression $scriptText
}

$script:Winget = Get-WingetCommand

Write-Step 'Checking Microsoft Store for Codex updates'
$storeCheck = Test-WingetUpgradeAvailable $StoreId
if ($storeCheck.Available) {
    Write-Warn 'A Microsoft Store update is available for Codex.'

    if ($CheckOnly -or $SkipStoreUpdate) {
        Write-Warn 'Store update was not installed because this is a check-only run or Store update is disabled.'
    } else {
        Write-Step 'Installing official Microsoft Store Codex update'
        $storeInstall = Install-StoreUpgrade $StoreId
        if ($storeInstall.ExitCode -ne 0) {
            Write-Warn "winget returned exit code $($storeInstall.ExitCode). Output:"
            Write-Host $storeInstall.Output
            exit 10
        }
        Write-Ok 'Microsoft Store Codex update finished.'
    }
} else {
    Write-Ok 'No Microsoft Store Codex update is currently available.'
}

Write-Step 'Comparing official Codex and Codex RTL versions'
$pkg = Get-CodexPackage
$state = Get-RtlState

if (-not $state) {
    Write-Warn "Codex RTL state file is missing: $StatePath"
    if ($CheckOnly -or $SkipRtlPatch) { exit 20 }

    $running = @(Get-RtlProcesses)
    if ($running.Count -gt 0) {
        Write-Warn 'Codex RTL is still running. End the Codex task in Task Manager, then rerun this monitor or the installer.'
        exit 21
    }

    Invoke-RtlInstaller
    Write-Ok 'Codex RTL was installed.'
    exit 0
}

$officialVersion = [version]$pkg.Version
$rtlVersion = [version]$state.packageVersion

Write-Host "Official Codex: $officialVersion"
Write-Host "Codex RTL copy:  $rtlVersion"

if ($officialVersion -le $rtlVersion) {
    Write-Ok 'Codex RTL is up to date.'
    exit 0
}

Write-Warn 'Official Codex is newer than the Codex RTL copy.'
if ($CheckOnly -or $SkipRtlPatch) {
    Write-Warn 'RTL patch was not updated because this is a check-only run or RTL patching is disabled.'
    exit 20
}

$rtlProcesses = @(Get-RtlProcesses)
if ($rtlProcesses.Count -gt 0) {
    Write-Warn 'Codex RTL is still running, so app.asar may be locked.'
    Write-Host 'Use Task Manager > Codex > End task. Closing with X is not enough.'
    Write-Host 'After that, rerun:'
    Write-Host 'irm https://raw.githubusercontent.com/mnigli/codex-desktop-rtl-patch/main/install.ps1 | iex'
    exit 21
}

Write-Step 'Reapplying RTL patch to the updated official Codex version'
Invoke-RtlInstaller
Write-Ok 'Codex RTL was updated.'
