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
    [string]$InstallerUrl = 'https://raw.githubusercontent.com/mnigli/codex-desktop-rtl-patch/092d1744f43a14cc9bb2a5bf05d89ef09723eca1/install.ps1',
    [string[]]$ReleaseSignalUrls = @('https://r.jina.ai/https://x.com/CodexReleases'),
    [switch]$CheckOnly,
    [switch]$SkipReleaseSignal,
    [switch]$SkipStoreUpdate,
    [switch]$SkipRtlPatch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$InstallRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\CodexRtl'
$TargetAppDir = Join-Path $InstallRoot 'app'
$StatePath = Join-Path $InstallRoot 'patch-state.json'
$ReleaseSignalStatePath = Join-Path $InstallRoot 'release-signal-state.json'
$ScriptPath = $null
try { $ScriptPath = $MyInvocation.MyCommand.Path } catch { $ScriptPath = $null }
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

function Get-RecentFailedCodexStoreUpdate([version]$InstalledVersion, [int]$LookbackHours = 48) {
    try {
        $events = Get-WinEvent -FilterHashtable @{
            LogName = 'Microsoft-Windows-AppXDeploymentServer/Operational'
            StartTime = (Get-Date).AddHours(-$LookbackHours)
        } -ErrorAction Stop | Where-Object {
            $_.Message -match 'OpenAI\.Codex_'
        }
    } catch {
        Write-Warn "Could not inspect AppX deployment logs: $($_.Exception.Message)"
        return $null
    }

    $failureIds = @(319, 401, 404, 6801)
    $candidates = foreach ($event in $events) {
        if (($event.LevelDisplayName -ne 'Error') -and ($event.Id -notin $failureIds)) {
            continue
        }

        $matches = [regex]::Matches($event.Message, 'OpenAI\.Codex_(\d+\.\d+\.\d+\.\d+)_')
        foreach ($match in $matches) {
            try {
                $version = [version]$match.Groups[1].Value
            } catch {
                continue
            }

            if ($version -gt $InstalledVersion) {
                [pscustomobject]@{
                    Version = $version
                    TimeCreated = $event.TimeCreated
                    EventId = $event.Id
                    Message = (($event.Message -replace '\s+', ' ').Trim())
                }
            }
        }
    }

    $items = @($candidates)
    if ($items.Count -eq 0) { return $null }

    return $items |
        Sort-Object @{ Expression = 'Version'; Descending = $true },
                    @{ Expression = 'TimeCreated'; Descending = $true } |
        Select-Object -First 1
}

function Get-RecentStagedCodexStoreUpdate([version]$InstalledVersion, [int]$LookbackHours = 24) {
    try {
        $events = Get-WinEvent -FilterHashtable @{
            LogName = 'Microsoft-Windows-AppXDeploymentServer/Operational'
            Id = 400
            StartTime = (Get-Date).AddHours(-$LookbackHours)
        } -ErrorAction Stop | Where-Object {
            $_.Message -match 'OpenAI\.Codex_' -and
            $_.Message -match 'Deployment Stage operation' -and
            $_.Message -match 'finished successfully'
        }
    } catch {
        Write-Warn "Could not inspect AppX stage logs: $($_.Exception.Message)"
        return $null
    }

    $candidates = foreach ($event in $events) {
        $matches = [regex]::Matches($event.Message, 'OpenAI\.Codex_(\d+\.\d+\.\d+\.\d+)_')
        foreach ($match in $matches) {
            try {
                $version = [version]$match.Groups[1].Value
            } catch {
                continue
            }

            if ($version -gt $InstalledVersion) {
                [pscustomobject]@{
                    Version = $version
                    TimeCreated = $event.TimeCreated
                    EventId = $event.Id
                }
            }
        }
    }

    $items = @($candidates)
    if ($items.Count -eq 0) { return $null }

    return $items |
        Sort-Object @{ Expression = 'Version'; Descending = $true },
                    @{ Expression = 'TimeCreated'; Descending = $true } |
        Select-Object -First 1
}

function Get-ReleaseSignalState {
    if (-not (Test-Path -LiteralPath $ReleaseSignalStatePath)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $ReleaseSignalStatePath -Raw | ConvertFrom-Json
    } catch {
        Write-Warn "Could not read release signal state: $($_.Exception.Message)"
        return $null
    }
}

function Save-ReleaseSignalState([version]$Version, [string]$SourceUrl) {
    New-Item -ItemType Directory -Force $InstallRoot | Out-Null
    $state = [ordered]@{
        lastSeenVersion = [string]$Version
        lastSeenAt = (Get-Date).ToString('o')
        sourceUrl = $SourceUrl
    }
    $json = $state | ConvertTo-Json -Depth 5
    $utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
    [System.IO.File]::WriteAllText($ReleaseSignalStatePath, $json + "`n", $utf8NoBom)
}

function Get-HighestVersionFromText([string]$Text) {
    if (-not $Text) { return $null }

    $versions = foreach ($match in [regex]::Matches($Text, '(?<!\d)(\d{1,3}\.\d{1,4}\.\d{1,5}\.\d{1,5})(?!\d)')) {
        try {
            [version]$match.Groups[1].Value
        } catch {
            continue
        }
    }

    $items = @($versions)
    if ($items.Count -eq 0) { return $null }
    return $items | Sort-Object -Descending | Select-Object -First 1
}

function Test-ReleaseSignal([version]$InstalledVersion) {
    if ($SkipReleaseSignal) {
        return [pscustomobject]@{ Newer = $false; ShouldNotify = $false; Version = $null; SourceUrl = $null }
    }

    $bestVersion = $null
    $bestSource = $null

    foreach ($url in $ReleaseSignalUrls) {
        if (-not $url) { continue }

        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 30
            $version = Get-HighestVersionFromText $response.Content
            if ($version -and ((-not $bestVersion) -or ($version -gt $bestVersion))) {
                $bestVersion = $version
                $bestSource = $url
            }
        } catch {
            Write-Warn "Release signal check failed for ${url}: $($_.Exception.Message)"
        }
    }

    if (-not $bestVersion) {
        Write-Ok 'Release signal did not expose a desktop version; continuing with Store/AppX checks.'
        return [pscustomobject]@{ Newer = $false; ShouldNotify = $false; Version = $null; SourceUrl = $null }
    }

    if ($bestVersion -le $InstalledVersion) {
        Write-Ok "Release signal latest desktop version is $bestVersion."
        Save-ReleaseSignalState $bestVersion $bestSource
        return [pscustomobject]@{ Newer = $false; ShouldNotify = $false; Version = $bestVersion; SourceUrl = $bestSource }
    }

    $state = Get-ReleaseSignalState
    $lastSeen = $null
    if ($state -and $state.lastSeenVersion) {
        try { $lastSeen = [version]$state.lastSeenVersion } catch { $lastSeen = $null }
    }

    Save-ReleaseSignalState $bestVersion $bestSource
    $shouldNotify = (-not $lastSeen) -or ($bestVersion -gt $lastSeen)

    Write-Warn "Release signal mentions Codex $bestVersion, but installed Codex is $InstalledVersion."
    return [pscustomobject]@{ Newer = $true; ShouldNotify = $shouldNotify; Version = $bestVersion; SourceUrl = $bestSource }
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
    Get-CimInstance Win32_Process -Filter "name = 'Codex.exe' OR name = 'codex.exe' OR name = 'ChatGPT.exe'" -ErrorAction SilentlyContinue |
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

Write-Step 'Checking external Codex release signal'
$pkgBeforeStoreCheck = Get-CodexPackage
$releaseSignal = Test-ReleaseSignal ([version]$pkgBeforeStoreCheck.Version)

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
$officialVersion = [version]$pkg.Version
$stagedStoreUpdate = Get-RecentStagedCodexStoreUpdate $officialVersion
if ($stagedStoreUpdate) {
    Write-Warn "Microsoft Store staged Codex $($stagedStoreUpdate.Version) successfully at $($stagedStoreUpdate.TimeCreated), but the registered app is still $officialVersion."
    Write-Warn 'Use Task Manager > Codex > End task, then reopen Codex Original so Windows can switch to the staged version.'
}

$failedStoreUpdate = Get-RecentFailedCodexStoreUpdate $officialVersion
if ($failedStoreUpdate -and ((-not $stagedStoreUpdate) -or ($failedStoreUpdate.Version -gt $stagedStoreUpdate.Version))) {
    Write-Warn "Microsoft Store attempted to update Codex to $($failedStoreUpdate.Version), but AppX deployment failed at $($failedStoreUpdate.TimeCreated) (event $($failedStoreUpdate.EventId))."
    Write-Warn "Installed Codex is still $officialVersion. Retry the Store update after using Task Manager > Codex > End task. If it fails again, repair/reset Microsoft Store and App Installer."
}

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

$rtlVersion = [version]$state.packageVersion

Write-Host "Official Codex: $officialVersion"
Write-Host "Codex RTL copy:  $rtlVersion"

if ($officialVersion -le $rtlVersion) {
    if ($stagedStoreUpdate) { exit 32 }
    if ($failedStoreUpdate) { exit 30 }
    if ($releaseSignal.Newer -and $releaseSignal.ShouldNotify) { exit 31 }
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
