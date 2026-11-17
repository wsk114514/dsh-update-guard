<#
.SYNOPSIS
    Report the DSH desktop update state as JSON (read-only).

.DESCRIPTION
    Probe used by the dsh-update-guard plugin's status tool. It changes nothing:
      - installed DSH version (from the executable's FileVersion / uninstall registry)
      - whether DSH is running
      - the pending update package electron-updater left behind after a failed install
      - the latest release advertised by the update feed (nightly.yml by default)
      - the DshUpdateGuard scheduled task
      - the tail of the guard log

    Prints one JSON object on stdout. Every section is probed defensively, so a
    machine without DSH, without the task, or offline still yields valid JSON.

.PARAMETER FeedUrl
    Override the update feed base URL. Default: read from resources/app-update.yml.

.PARAMETER Channel
    Override the feed channel. Default: read from resources/app-update.yml (nightly).

.PARAMETER LogLines
    How many trailing guard log lines to include (default 12).
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$FeedUrl,
    [string]$Channel,
    [int]$LogLines = 12,
    [string]$InstallDir
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 被插件以重定向方式调用时强制 UTF-8 输出，否则 5.1 用 ANSI 代码页写 stdout，
# 中文日志变成替换符。交互运行时保持控制台编码不变。
try {
    if ([Console]::IsOutputRedirected) {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
        $OutputEncoding = [Console]::OutputEncoding
    }
} catch { }

$result = [ordered]@{
    generatedAt      = (Get-Date).ToString('o')
    installDir       = $null
    installedVersion = $null
    appRunning       = $false
    processCount     = 0
    updateConfig     = [ordered]@{ url = $null; channel = $null }
    pending          = [ordered]@{
        dir = $null; exists = $false; fileName = $null; sizeBytes = 0
        ageMinutes = $null; isAdminRightsRequired = $null; sha512 = $null
    }
    feed             = [ordered]@{ url = $null; ok = $false; version = $null; releaseDate = $null; size = 0; error = $null }
    task             = [ordered]@{
        name = 'DshUpdateGuard'; exists = $false; state = $null; lastRunTime = $null
        lastTaskResult = $null; execute = $null; arguments = $null
    }
    log              = [ordered]@{ path = $null; exists = $false; tail = @() }
}

# ------------------------------------------------------------- install info ---
function Resolve-InstallDir {
    param([string]$hint)
    if ($hint -and (Test-Path (Join-Path $hint 'DeepSeek Harness.exe'))) { return $hint }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness'),
        (Join-Path $env:ProgramFiles 'DeepSeek Harness'),
        (Join-Path ${env:ProgramFiles(x86)} 'DeepSeek Harness')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path (Join-Path $c 'DeepSeek Harness.exe'))) { return $c }
    }
    foreach ($root in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (-not (Test-Path $root)) { continue }
        foreach ($key in Get-ChildItem $root -ErrorAction SilentlyContinue) {
            $props = Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue
            if ($props.DisplayName -like 'DeepSeek Harness*' -and $props.InstallLocation) {
                if (Test-Path (Join-Path $props.InstallLocation 'DeepSeek Harness.exe')) { return $props.InstallLocation }
            }
        }
    }
    return $null
}

try {
    $dir = Resolve-InstallDir -hint $InstallDir
    if ($dir) {
        $result.installDir = $dir
        $exe = Join-Path $dir 'DeepSeek Harness.exe'
        $result.installedVersion = (Get-Item $exe).VersionInfo.FileVersion
        $yml = Join-Path $dir 'resources\app-update.yml'
        if (Test-Path $yml) {
            foreach ($line in Get-Content $yml) {
                if ($line -match '^\s*url:\s*(.+?)\s*$') { $result.updateConfig.url = $Matches[1].Trim("'", '"') }
                if ($line -match '^\s*channel:\s*(.+?)\s*$') { $result.updateConfig.channel = $Matches[1].Trim("'", '"') }
            }
        }
    }
} catch {
    $result.installedVersion = $null
}

try {
    $procs = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue)
    $result.processCount = $procs.Count
    $result.appRunning = $procs.Count -gt 0
} catch { }

# ------------------------------------------------------------ pending update -
try {
    $pendingDir = Join-Path $env:LOCALAPPDATA '@deepseek-aidsh-desktop-updater\pending'
    $result.pending.dir = $pendingDir
    if (Test-Path $pendingDir) {
        $result.pending.exists = $true
        $info = Join-Path $pendingDir 'update-info.json'
        $fileName = $null
        if (Test-Path $info) {
            $raw = Get-Content $info -Raw
            if ($raw -match '"fileName"\s*:\s*"([^"]+)"') { $fileName = $Matches[1] }
            if ($raw -match '"isAdminRightsRequired"\s*:\s*(true|false)') { $result.pending.isAdminRightsRequired = [bool]::Parse($Matches[1]) }
            if ($raw -match '"sha512"\s*:\s*"([^"]+)"') { $result.pending.sha512 = $Matches[1].Substring(0, [Math]::Min(16, $Matches[1].Length)) }
        }
        if (-not $fileName) {
            $candidate = Get-ChildItem $pendingDir -Filter *.exe -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($candidate) { $fileName = $candidate.Name }
        }
        if ($fileName) {
            $result.pending.fileName = $fileName
            $exePath = Join-Path $pendingDir $fileName
            if (Test-Path $exePath) {
                $item = Get-Item $exePath
                $result.pending.sizeBytes = $item.Length
                $result.pending.ageMinutes = [int][Math]::Round(((Get-Date) - $item.LastWriteTime).TotalMinutes)
            }
        }
    }
} catch { }

# ------------------------------------------------------------------- feed ----
try {
    $base = if ($FeedUrl) { $FeedUrl } else { $result.updateConfig.url }
    $chan = if ($Channel) { $Channel } else { $result.updateConfig.channel }
    if (-not $chan) { $chan = 'nightly' }
    if ($base) {
        $url = ($base.TrimEnd('/') + '/' + $chan + '.yml')
        $result.feed.url = $url
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 20
        # application/yaml responses arrive as a byte[]; decode before matching.
        $body = if ($resp.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($resp.Content) } else { [string]$resp.Content }
        if ($body -match '(?m)^version:\s*(\S+)\s*$') { $result.feed.version = $Matches[1].Trim("'", '"') }
        if ($body -match '(?m)^releaseDate:\s*(\S+)\s*$') { $result.feed.releaseDate = $Matches[1].Trim("'", '"') }
        if ($body -match '(?m)^\s*size:\s*(\d+)') { $result.feed.size = [int64]$Matches[1] }
        $result.feed.ok = [bool]$result.feed.version
        if (-not $result.feed.ok) { $result.feed.error = 'feed has no version field' }
    } else {
        $result.feed.error = 'no feed url (install dir not found?)'
    }
} catch {
    $result.feed.error = $_.Exception.Message
}

# ------------------------------------------------------------------- task ----
try {
    $task = Get-ScheduledTask -TaskName 'DshUpdateGuard' -ErrorAction SilentlyContinue
    if ($task) {
        $result.task.exists = $true
        $result.task.state = [string]$task.State
        $info = Get-ScheduledTaskInfo -TaskName 'DshUpdateGuard' -ErrorAction SilentlyContinue
        if ($info) {
            $result.task.lastRunTime = if ($info.LastRunTime) { $info.LastRunTime.ToString('s') } else { $null }
            $result.task.lastTaskResult = $info.LastTaskResult
        }
        $action = @($task.Actions)[0]
        if ($action) {
            $result.task.execute = [string]$action.Execute
            $result.task.arguments = [string]$action.Arguments
        }
    }
} catch { }

# -------------------------------------------------------------------- log ----
try {
    $logPath = Join-Path $env:LOCALAPPDATA 'dsh-update-guard\guard.log'
    $result.log.path = $logPath
    if (Test-Path $logPath) {
        $result.log.exists = $true
        # Join + split to obtain clean .NET strings: lines read here can carry
        # provider ETS metadata (PSPath / PSDrive / PSProvider) and serialize
        # into megabytes of JSON instead of the text itself.
        $flat = @(Get-Content $logPath -Tail $LogLines -Encoding UTF8) -join "`n"
        $result.log.tail = @($flat -split "`n")
    }
} catch { }

$result | ConvertTo-Json -Depth 6 -Compress
