<#
.SYNOPSIS
    DeepSeek Harness（DSH）桌面版更新守卫 / DSH desktop update guard.

.DESCRIPTION
    DSH 桌面版在 Windows 上的自动更新经常卡在「关闭旧进程」这一步，报错：

        desktop update: Host did not complete graceful task teardown
        (exit null, signal SIGTERM, shutdown acknowledged true, graceful deadline exceeded true)

    这是 DSH 自己的保护逻辑：只有 host 子进程在 10 秒内「优雅退出」才允许安装；
    一旦有后台任务/插件占着连接，DSH 只能 SIGTERM 强杀，然后拒绝安装。
    此时更新包已经下载好了，留在
        %LOCALAPPDATA%\@deepseek-aidsh-desktop-updater\pending\
    里，但界面只会提示失败，用户只能自己去官网重新下载安装包。

    本脚本接管「安装」这一步：读取 DSH 已下载的安装包（或直接从官方更新源下载），
    校验签名后用 electron-updater 完全相同的参数静默安装，并校验安装结果。

    electron-updater 原生的安装调用（DSH 内部 quitAndInstall(true,true)）等价于：
        deepseek-harness-<version>-win-x64.exe --updated /S --force-run
    本脚本在「用户自己点了安装但失败」的场景沿用 --force-run（装完自动拉起），
    在「等用户下班关掉 DSH 再装」的场景不加 --force-run（下次自己打开就是新版）。

.PARAMETER Policy
    Auto     默认，非侵入。① DSH 已暂存待安装包（说明用户点过下载/安装）就接管；
              ② DSH 未运行 → 立刻静默安装；DSH 正在运行 → 最多等 WaitForExitMinutes，
              用户退出后立刻装上，绝不打断正在使用的会话。装上后不强制拉起，
              下次打开 DSH 就是新版。
    OnExit   与 Auto 同样保守，但从不主动下载（只装 DSH 自己已经下好的包）。
    Now      立即安装：先尝试优雅关闭 DSH，超时后强制结束，装完自动重启。
    Stage    只下载并校验安装包，不安装。

.PARAMETER MinPendingAgeMinutes
    Policy=Auto 时，DSH 暂存的待安装包至少放置多少分钟才认定「可以接管」（默认 10）。

.PARAMETER WaitForExitMinutes
    Policy=Auto/OnExit 时，每次运行最多等待 DSH 退出多少分钟（默认 3；配合每 15 分钟
    一次的计划任务，等价于持续守候）。

.PARAMETER Force
    即使版本相同也重新安装（急救用）。

.PARAMETER ForceClose
    Auto 模式下，若 DSH 已暂存待安装包且放置超过 MinPendingAgeMinutes，直接关闭 DSH、
    安装并重启（会打断当前会话）。适合「宁可被打断也要立刻更新」的场景。

.EXAMPLE
    # 手动立刻装（会关掉正在运行的 DSH）
    .\dsh-update-guard.ps1 -Policy Now

.EXAMPLE
    # 只看当前判定，不下载也不安装
    .\dsh-update-guard.ps1 -DryRun

.NOTES
    日志：%LOCALAPPDATA%\dsh-update-guard\guard.log
    退出码：0 无事可做或已成功；10 仅完成下载；2 出错。
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Auto', 'OnExit', 'Now', 'Stage')]
    [string]$Policy = 'Auto',

    [string]$Channel,
    [string]$FeedUrl,
    [string]$InstallDir,

    [int]$MinPendingAgeMinutes = 10,
    [int]$WaitForExitMinutes = 3,
    [int]$GracefulCloseSeconds = 45,

    [switch]$Force,
    [switch]$ForceClose,
    [switch]$NoRelaunch,
    [switch]$SkipSignatureCheck,
    [switch]$DryRun,
    [switch]$SelfTest,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
$script:AppName = 'DeepSeek Harness'

# 被宿主以重定向方式调用时（插件工具、计划任务）强制 UTF-8 输出：否则
# Windows PowerShell 5.1 用系统 ANSI 代码页写 stdout，中文日志全变乱码。
# 交互运行（有真实控制台）时保持控制台自己的编码，避免反向乱码。
try {
    if ([Console]::IsOutputRedirected) {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
        $OutputEncoding = [Console]::OutputEncoding
    }
} catch { }

# ---------------------------------------------------------------- logging ----

function Write-GuardLog {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO',
        [string]$Message
    )
    $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if (-not $LogPath) {
        $dir = Join-Path $env:LOCALAPPDATA 'dsh-update-guard'
        if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        $script:LogPath = Join-Path $dir 'guard.log'
    }
    try {
        $logDir = Split-Path -Parent $LogPath
        if ($logDir -and -not (Test-Path $logDir)) { $null = New-Item -ItemType Directory -Path $logDir -Force }
        if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt 1MB) {
            $old = [IO.Path]::ChangeExtension($LogPath, '.1.log')
            Move-Item $LogPath $old -Force
        }
        Add-Content -Path $LogPath -Value $line -Encoding UTF8
    } catch {
        # 日志失败不能影响主流程
    }
    if ($DryRun -or $Level -ne 'INFO') { Write-Host $line }
}

function Exit-Guard {
    param([int]$Code, [string]$Message)
    if ($Message) { Write-GuardLog -Level INFO -Message $Message }
    Write-GuardLog -Level INFO -Message ("结束，退出码 {0}" -f $Code)
    exit $Code
}

# ------------------------------------------------------------ environment ----

function Get-DshInstallInfo {
    <# 定位安装目录 / 主程序 / 官方更新源配置 #>
    $dirs = @()
    if ($InstallDir) { $dirs += $InstallDir }
    foreach ($hive in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        try {
            Get-ItemProperty $hive -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like "$script:AppName*" -and $_.InstallLocation } |
                ForEach-Object { $dirs += $_.InstallLocation }
        } catch { }
    }
    $dirs += (Join-Path $env:LOCALAPPDATA ("Programs\{0}" -f $script:AppName))
    $dirs += (Join-Path $env:ProgramFiles $script:AppName)

    foreach ($d in $dirs) {
        if (-not $d) { continue }
        $exe = Join-Path $d ("{0}.exe" -f $script:AppName)
        if (Test-Path $exe) {
            $info = [pscustomobject]@{
                InstallDir = $d.TrimEnd('\')
                ExePath    = $exe
                Version    = (Get-Item $exe).VersionInfo.FileVersion
                FeedUrl    = $null
                Channel    = $null
                CacheDir   = $null
            }
            $yml = Join-Path $d 'resources\app-update.yml'
            if (Test-Path $yml) {
                foreach ($line in Get-Content $yml) {
                    if ($line -match '^\s*url:\s*(.+?)\s*$') { $info.FeedUrl = $Matches[1].Trim("'", '"') }
                    elseif ($line -match '^\s*channel:\s*(.+?)\s*$') { $info.Channel = $Matches[1].Trim("'", '"') }
                    elseif ($line -match '^\s*updaterCacheDirName:\s*(.+?)\s*$') { $info.CacheDir = $Matches[1].Trim("'", '"') }
                }
            }
            return $info
        }
    }
    return $null
}

function Get-DshProcesses {
    Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -eq $script:AppName }
}

# --------------------------------------------------------------- versions ----

function Split-DshVersion {
    param([string]$Text)
    if (-not $Text) { return $null }
    $t = $Text.Trim().TrimStart('v', 'V')
    $t = ($t -split '\+')[0]
    $core = $t
    $pre = @()
    if ($t -match '^(?<core>[^-]+)-(?<pre>.+)$') {
        $core = $Matches['core']
        $pre = $Matches['pre'] -split '\.'
    }
    $nums = @()
    foreach ($p in ($core -split '\.')) {
        $n = 0
        if ([int]::TryParse($p, [ref]$n)) { $nums += $n } else { $nums += 0 }
    }
    return [pscustomobject]@{ Numeric = $nums; Pre = $pre }
}

function Compare-DshVersion {
    <# 返回 1 / 0 / -1：Left 大于 / 等于 / 小于 Right（支持 0.2.2-rc.3 这类预发布号）#>
    param([string]$Left, [string]$Right)
    $l = Split-DshVersion $Left
    $r = Split-DshVersion $Right
    if (-not $l) { return $(if (-not $r) { 0 } else { -1 }) }
    if (-not $r) { return 1 }

    for ($i = 0; $i -lt [Math]::Max(3, [Math]::Max($l.Numeric.Count, $r.Numeric.Count)); $i++) {
        $a = if ($i -lt $l.Numeric.Count) { $l.Numeric[$i] } else { 0 }
        $b = if ($i -lt $r.Numeric.Count) { $r.Numeric[$i] } else { 0 }
        if ($a -gt $b) { return 1 }
        if ($a -lt $b) { return -1 }
    }

    $lp = @($l.Pre); $rp = @($r.Pre)
    if ($lp.Count -eq 0 -and $rp.Count -eq 0) { return 0 }
    if ($lp.Count -eq 0) { return 1 }   # 正式版 > 预发布版
    if ($rp.Count -eq 0) { return -1 }

    for ($i = 0; $i -lt [Math]::Max($lp.Count, $rp.Count); $i++) {
        if ($i -ge $lp.Count) { return -1 }
        if ($i -ge $rp.Count) { return 1 }
        $x = $lp[$i]; $y = $rp[$i]
        $xn = 0; $yn = 0
        $xIsNum = [int]::TryParse($x, [ref]$xn)
        $yIsNum = [int]::TryParse($y, [ref]$yn)
        if ($xIsNum -and $yIsNum) {
            if ($xn -gt $yn) { return 1 }
            if ($xn -lt $yn) { return -1 }
        } elseif ($xIsNum) { return -1 }     # 数字标识 < 字母标识
        elseif ($yIsNum) { return 1 }
        else {
            $c = [string]::CompareOrdinal($x, $y)
            if ($c -gt 0) { return 1 }
            if ($c -lt 0) { return -1 }
        }
    }
    return 0
}

# ------------------------------------------------------------- feed parse ----

function ConvertFrom-SimpleYaml {
    <# 极简 YAML 读取：取所有 key（含列表项），支持 >- / | 折叠写法；同名 key 以先出现者为准 #>
    param([string]$Text)
    $map = [ordered]@{}
    $lines = $Text -split "\r?\n"
    $i = 0
    while ($i -lt $lines.Count) {
        $raw = [string]$lines[$i]
        if ($raw.Trim() -eq '' -or $raw.TrimStart().StartsWith('#')) { $i++; continue }
        if ($raw -notmatch '^\s*(?:-\s*)?(?<k>[A-Za-z0-9_.\-]+)\s*:\s*(?<v>.*)$') { $i++; continue }

        $key = $Matches['k']
        $val = $Matches['v'].Trim()
        $keyCol = $raw.IndexOf($key)

        if ($val -eq '>' -or $val -eq '>-' -or $val -eq '|' -or $val -eq '|-') {
            $fold = $val.StartsWith('|')
            $parts = @()
            $i++
            while ($i -lt $lines.Count) {
                $l = [string]$lines[$i]
                if ($l.Trim() -eq '') { $parts += ''; $i++; continue }
                $li = $l.Length - $l.TrimStart().Length
                if ($li -le $keyCol) { break }
                $parts += $l.Trim()
                $i++
            }
            $joined = if ($fold) { ($parts -join "`n").Trim() } else { ($parts -join ' ').Trim() }
            if (-not $map.Contains($key)) { $map[$key] = $joined }
            continue
        }

        $val = $val.Trim("'", '"')
        if (-not $map.Contains($key) -and $val -ne '') { $map[$key] = $val }
        $i++
    }
    return $map
}

function Get-FeedRelease {
    <# 读取官方更新源（generic provider）：<FeedUrl>/<channel>.yml #>
    param([string]$Url, [string]$ChannelName)
    $feedFile = ($Url.TrimEnd('/')) + '/' + $ChannelName + '.yml'
    Write-GuardLog -Message ("读取更新源：" + $feedFile)
    $resp = Invoke-WebRequest -Uri $feedFile -UseBasicParsing -TimeoutSec 60
    $text = if ($resp.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($resp.Content) } else { [string]$resp.Content }
    $map = ConvertFrom-SimpleYaml -Text $text

    $version = $map['version']
    $fileUrl = $map['path']
    if (-not $fileUrl) { $fileUrl = $map['url'] }
    $size = 0
    if ($map['size']) { $null = [int64]::TryParse([string]$map['size'], [ref]$size) }

    if (-not $version) { throw "更新源缺少 version 字段：$feedFile" }
    if (-not $fileUrl) { throw "更新源缺少 path/url 字段：$feedFile" }

    return [pscustomobject]@{
        Version  = $version
        FileUrl  = $fileUrl
        FileName = [IO.Path]::GetFileName(([uri]$fileUrl).AbsolutePath)
        Size     = $size
        Sha512   = $map['sha512']
        Source   = 'feed'
    }
}

# ----------------------------------------------------- DSH 已暂存的更新包 ----

function Get-PendingRelease {
    param([string]$CacheDirName)
    if (-not $CacheDirName) { return $null }
    $pending = Join-Path (Join-Path $env:LOCALAPPDATA $CacheDirName) 'pending'
    $infoPath = Join-Path $pending 'update-info.json'
    if (-not (Test-Path $infoPath)) { return $null }

    try { $info = Get-Content $infoPath -Raw | ConvertFrom-Json } catch { return $null }
    $fileName = $info.fileName
    $filePath = $null
    if ($fileName) {
        $candidate = Join-Path $pending $fileName
        if (Test-Path $candidate) { $filePath = $candidate }
    }
    if (-not $filePath) {
        $fallback = Join-Path $pending 'installer.exe'
        if (Test-Path $fallback) {
            $filePath = $fallback
            if (-not $fileName) { $fileName = 'installer.exe' }
        }
    }
    if (-not $filePath) { return $null }

    $version = $null
    if ($fileName -match '(\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?)') { $version = $Matches[1] }

    $age = 0
    try { $age = [Math]::Round(((Get-Date) - (Get-Item $filePath).LastWriteTime).TotalMinutes, 1) } catch { }

    return [pscustomobject]@{
        Version  = $version
        FilePath = $filePath
        FileName = $fileName
        Size     = (Get-Item $filePath).Length
        AgeMin   = $age
        Source   = 'dsh-pending'
    }
}

# ------------------------------------------------------------- downloads ----

function Save-UpdateInstaller {
    <# 下载安装包到本地缓存，校验大小/签名；已存在且大小对得上则跳过下载 #>
    param([pscustomobject]$Release)

    $cacheDir = Join-Path (Join-Path $env:LOCALAPPDATA 'dsh-update-guard') 'cache'
    if (-not (Test-Path $cacheDir)) { $null = New-Item -ItemType Directory -Path $cacheDir -Force }
    $target = Join-Path $cacheDir $Release.FileName

    if ((Test-Path $target) -and $Release.Size -gt 0 -and (Get-Item $target).Length -eq $Release.Size) {
        Write-GuardLog -Message ("缓存中已有完整安装包：" + $target)
        return $target
    }

    $partial = $target + '.download'
    if (Test-Path $partial) { Remove-Item $partial -Force -ErrorAction SilentlyContinue }

    Write-GuardLog -Message ("开始下载 {0}（{1:N0} MB）：{2}" -f $Release.Version, ($Release.Size / 1MB), $Release.FileUrl)
    $downloaded = $false
    try {
        Import-Module BitsTransfer -ErrorAction Stop
        Start-BitsTransfer -Source $Release.FileUrl -Destination $partial -Description 'DSH update' -ErrorAction Stop
        $downloaded = $true
    } catch {
        Write-GuardLog -Level WARN -Message ("BITS 下载不可用，改用 Invoke-WebRequest：" + $_.Exception.Message)
    }
    if (-not $downloaded) {
        $oldProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri $Release.FileUrl -OutFile $partial -UseBasicParsing -TimeoutSec 3600
        } finally {
            $ProgressPreference = $oldProgress
        }
    }

    if ($Release.Size -gt 0 -and (Get-Item $partial).Length -ne $Release.Size) {
        throw ("下载大小不符：期望 {0}，实际 {1}" -f $Release.Size, (Get-Item $partial).Length)
    }
    Move-Item $partial $target -Force
    Unblock-File -Path $target -ErrorAction SilentlyContinue
    Write-GuardLog -Message ("下载完成：" + $target)
    return $target
}

function Test-UpdateInstaller {
    <# 安装包体检：大小、Authenticode 签名、签名者 #>
    param([string]$Path, [int64]$ExpectedSize = 0)

    if (-not (Test-Path $Path)) { throw "安装包不存在：$Path" }
    $len = (Get-Item $Path).Length
    if ($len -lt 50MB) { throw ("安装包过小（{0:N0} 字节），疑似下载不完整：{1}" -f $len, $Path) }
    if ($ExpectedSize -gt 0 -and $len -ne $ExpectedSize) {
        throw ("安装包大小不符：期望 {0}，实际 {1}" -f $ExpectedSize, $len)
    }

    if ($SkipSignatureCheck) {
        Write-GuardLog -Level WARN -Message '已跳过签名校验（-SkipSignatureCheck）'
        return
    }
    try {
        $sig = Get-AuthenticodeSignature -FilePath $Path
        if ($sig.Status -ne 'Valid') { throw ("数字签名无效（状态 {0}）：{1}" -f $sig.Status, $Path) }
        $subject = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '' }
        if ($subject -notmatch 'DeepSeek') {
            throw ("签名者不是 DeepSeek（{0}）：{1}" -f $subject, $Path)
        }
        Write-GuardLog -Message ("签名校验通过：" + $subject)
    } catch [System.Management.Automation.RuntimeException] {
        throw
    } catch {
        throw ("无法校验数字签名：{0}" -f $_.Exception.Message)
    }
}

# --------------------------------------------------------------- install ----

function Wait-DshIdle {
    <# 等待 DSH 退出；期间若 DSH 自己升级成功则提前返回 'updated'。返回 exited / updated / timeout #>
    param([string]$ExePath, [string]$OldVersion, [int]$Minutes)

    if (-not (Get-DshProcesses)) { return 'exited' }

    $deadline = (Get-Date).AddMinutes($Minutes)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-DshProcesses)) { return 'exited' }
        try {
            $v = (Get-Item $ExePath).VersionInfo.FileVersion
            if ($v -and (Compare-DshVersion $v $OldVersion) -gt 0) {
                Write-GuardLog -Message ("DSH 已自行完成更新：{0} -> {1}" -f $OldVersion, $v)
                return 'updated'
            }
        } catch { }
        Start-Sleep -Seconds 3
    }
    if (-not (Get-DshProcesses)) { return 'exited' }
    return 'timeout'
}

function Stop-DshApp {
    <# 先请求窗口关闭，超时后强制结束（含 host 子进程，同名进程一次清理）#>
    param([int]$GraceSeconds = 45)

    $procs = @(Get-DshProcesses)
    if ($procs.Count -eq 0) { return }

    Write-GuardLog -Message ("尝试关闭 DSH（{0} 个进程）" -f $procs.Count)
    foreach ($p in $procs) {
        try { $null = $p.CloseMainWindow() } catch { }
    }

    $deadline = (Get-Date).AddSeconds($GraceSeconds)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-DshProcesses)) {
            Write-GuardLog -Message 'DSH 已正常退出'
            return
        }
        Start-Sleep -Seconds 2
    }

    Write-GuardLog -Level WARN -Message '优雅等待超时，强制结束 DSH 进程'
    foreach ($p in @(Get-DshProcesses)) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch {
            Write-GuardLog -Level WARN -Message ("结束进程失败 {0}: {1}" -f $p.Id, $_.Exception.Message)
        }
    }
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-DshProcesses)) { break }
        Start-Sleep -Milliseconds 500
    }
    if (Get-DshProcesses) { throw 'DSH 进程无法结束，放弃安装' }
}

function Invoke-DshInstaller {
    <# 用 electron-updater 相同参数静默安装：--updated /S [--force-run] [/D=...] #>
    param(
        [string]$InstallerPath,
        [string]$InstallDir,
        [string]$ExePath,
        [string]$OldVersion,
        [bool]$Relaunch
    )

    $argString = '--updated /S'
    if ($Relaunch -and -not $NoRelaunch) { $argString += ' --force-run' }
    if ($InstallDir) { $argString += (' /D=' + $InstallDir) }

    if ($DryRun) {
        Write-GuardLog -Message ("[DryRun] 将执行：`"{0}`" {1}" -f $InstallerPath, $argString)
        return $true
    }

    Write-GuardLog -Message ("执行安装：`"{0}`" {1}" -f $InstallerPath, $argString)
    $proc = Start-Process -FilePath $InstallerPath -ArgumentList $argString -Wait -PassThru
    Write-GuardLog -Message ("安装程序退出，退出码 {0}" -f $proc.ExitCode)

    # 安装器偶尔先退出、后写盘，这里轮询确认 exe 版本
    $deadline = (Get-Date).AddSeconds(90)
    $newVersion = $OldVersion
    while ((Get-Date) -lt $deadline) {
        try { $newVersion = (Get-Item $ExePath).VersionInfo.FileVersion } catch { }
        if ($newVersion -and (Compare-DshVersion $newVersion $OldVersion) -gt 0) { break }
        Start-Sleep -Seconds 2
    }

    if (-not $newVersion -or (Compare-DshVersion $newVersion $OldVersion) -le 0) {
        Write-GuardLog -Level ERROR -Message ("安装后版本仍为 {0}，安装可能失败" -f $newVersion)
        return $false
    }

    Write-GuardLog -Message ("安装成功：{0} -> {1}" -f $OldVersion, $newVersion)

    if ($Relaunch -and -not $NoRelaunch) {
        Start-Sleep -Seconds 3
        if (-not (Get-DshProcesses)) {
            Write-GuardLog -Message '重新启动 DSH'
            Start-Process -FilePath $ExePath | Out-Null
        }
    }
    return $true
}

# ------------------------------------------------------------------ main ----

if ($SelfTest) {
    $cases = @(
        @('0.2.2-rc.3', '0.2.2-rc.4', -1),
        @('0.2.2-rc.10', '0.2.2-rc.9', 1),
        @('0.2.2', '0.2.2-rc.3', 1),
        @('0.2.3-rc.1', '0.2.2', 1),
        @('0.2.2-rc.3', '0.2.2-rc.3', 0),
        @('v0.2.10', '0.2.9', 1),
        @('0.3.0', '0.2.9', 1)
    )
    $bad = 0

    # 更新源 YAML 解析自检（样本取自官方 nightly.yml）
    $sample = @(
        'version: 0.2.2-rc.3'
        'files:'
        '  - url: >-'
        '      https://download.deepseek.com/dsh-desk/bin/win-x64/deepseek-harness-0.2.2-rc.3-win-x64.exe'
        '    size: 299595752'
        '    sha512: >-'
        '      GiJf8kx+C7eoiZ0xQSYBcTyh5xmXQl+vh63U6uSm963McK1AkMgB8PydzuekWdUY7hyURvhVMHANM4pn+tCKzQ=='
        'path: >-'
        '  https://download.deepseek.com/dsh-desk/bin/win-x64/deepseek-harness-0.2.2-rc.3-win-x64.exe'
        'sha512: >-'
        '  GiJf8kx+C7eoiZ0xQSYBcTyh5xmXQl+vh63U6uSm963McK1AkMgB8PydzuekWdUY7hyURvhVMHANM4pn+tCKzQ=='
        'stagingPercentage: 100'
        "releaseDate: '2026-11-13T07:31:42.937Z'"
    ) -join "`n"
    $ym = ConvertFrom-SimpleYaml -Text $sample
    $yamlChecks = @(
        @{ Name = 'version'; Got = $ym['version']; Want = '0.2.2-rc.3' }
        @{ Name = 'size'; Got = $ym['size']; Want = '299595752' }
        @{ Name = 'sha512'; Got = [bool]($ym['sha512'] -match '^GiJf8kx.*==$'); Want = $true }
        @{ Name = 'path'; Got = [bool]($ym['path'] -match '^https://download\.deepseek\.com/.+\.exe$'); Want = $true }
        @{ Name = 'url 未吞掉后续字段'; Got = [bool]($ym['url'] -notmatch 'size:|sha512:'); Want = $true }
    )
    foreach ($c in $yamlChecks) {
        if ($c.Got -ne $c.Want) {
            $bad++
            Write-Host ('FAIL  yaml {0} => {1}' -f $c.Name, $c.Got)
        } else {
            Write-Host ('OK    yaml {0}' -f $c.Name)
        }
    }
    foreach ($c in $cases) {
        $got = Compare-DshVersion -Left $c[0] -Right $c[1]
        $ok = ($got -eq $c[2])
        if (-not $ok) { $bad++ }
        Write-Host ('{0}  {1} vs {2} => {3}（期望 {4}）' -f $(if ($ok) { 'OK  ' } else { 'FAIL' }), $c[0], $c[1], $got, $c[2])
    }
    if ($bad -eq 0) { Write-Host '版本比较自检通过'; exit 0 }
    Write-Host ('版本比较自检失败 {0} 项' -f $bad)
    exit 3
}

Write-GuardLog -Message ('===== 开始（Policy={0}，DryRun={1}） =====' -f $Policy, [bool]$DryRun)

# 单实例互斥，避免计划任务重叠运行
$mutex = $null
try {
    $mutex = New-Object System.Threading.Mutex($false, 'Local\DshUpdateGuard')
    if (-not $mutex.WaitOne(0)) { Exit-Guard -Code 0 -Message '已有另一个守卫实例在运行，本次跳过' }
} catch {
    # 互斥量创建失败不阻断主流程
}

try {
    $app = Get-DshInstallInfo
    if (-not $app) { Exit-Guard -Code 2 -Message ("找不到 DSH 安装目录（默认路径 {0}\Programs\{1}）" -f $env:LOCALAPPDATA, $script:AppName) }

    if ($FeedUrl) { $app.FeedUrl = $FeedUrl }
    if ($Channel) { $app.Channel = $Channel }
    if (-not $app.FeedUrl) { Exit-Guard -Code 2 -Message '未能从 resources\app-update.yml 读到更新源地址，请用 -FeedUrl 指定' }
    if (-not $app.Channel) { $app.Channel = 'nightly' }
    if (-not $app.CacheDir) { $app.CacheDir = '@deepseek-aidsh-desktop-updater' }

    Write-GuardLog -Message ("已安装版本 {0}；安装目录 {1}；更新源 {2}（channel={3}）" -f $app.Version, $app.InstallDir, $app.FeedUrl, $app.Channel)

    $pending = Get-PendingRelease -CacheDirName $app.CacheDir
    $feed = $null
    try { $feed = Get-FeedRelease -Url $app.FeedUrl -ChannelName $app.Channel } catch {
        Write-GuardLog -Level WARN -Message ("读取更新源失败：" + $_.Exception.Message)
    }

    if ($pending) {
        Write-GuardLog -Message ("DSH 已暂存待安装包：{0}（版本 {1}，已放置 {2} 分钟）" -f $pending.FileName, $pending.Version, $pending.AgeMin)
    }
    if ($feed) {
        Write-GuardLog -Message ("更新源最新版本：{0}（{1}）" -f $feed.Version, $feed.FileName)
    }
    if (-not $pending -and -not $feed) { Exit-Guard -Code 2 -Message '既没有 DSH 暂存的安装包，也无法读取更新源' }

    # 选目标版本：优先取比已安装更新的最高版本
    $target = $null
    foreach ($candidate in @($pending, $feed)) {
        if (-not $candidate -or -not $candidate.Version) { continue }
        if (-not $target) { $target = $candidate; continue }
        if ((Compare-DshVersion $candidate.Version $target.Version) -gt 0) { $target = $candidate }
    }
    if (-not $target) { Exit-Guard -Code 2 -Message '无法确定可安装的目标版本' }

    $cmp = Compare-DshVersion $target.Version $app.Version
    if ($cmp -le 0 -and -not $Force) {
        Exit-Guard -Code 0 -Message ("已是最新（{0}），无需更新" -f $app.Version)
    }
    Write-GuardLog -Message ("准备更新：{0} -> {1}" -f $app.Version, $target.Version)

    # 拿到可用的安装包路径
    switch ($target.Source) {
        'dsh-pending' { $installer = $target.FilePath }
        default {
            if ($DryRun) {
                $installer = Join-Path (Join-Path (Join-Path $env:LOCALAPPDATA 'dsh-update-guard') 'cache') $target.FileName
                Write-GuardLog -Message ("[DryRun] 将下载到：" + $installer)
            } else {
                $installer = Save-UpdateInstaller -Release $target
            }
        }
    }
    if (-not $DryRun) { Test-UpdateInstaller -Path $installer -ExpectedSize $target.Size }

    if ($Policy -eq 'Stage') {
        Exit-Guard -Code 10 -Message ("已下载并校验安装包，等待安装：" + $installer)
    }

    $relaunch = $false
    $installed = $false

    switch ($Policy) {
        'Now' {
            Stop-DshApp -GraceSeconds $GracefulCloseSeconds
            $relaunch = $true
            $installed = Invoke-DshInstaller -InstallerPath $installer -InstallDir $app.InstallDir -ExePath $app.ExePath -OldVersion $app.Version -Relaunch $relaunch
        }

        'OnExit' {
            if (Get-DshProcesses) { Write-GuardLog -Message 'DSH 正在运行，等待其退出后再安装' }
            $wait = Wait-DshIdle -ExePath $app.ExePath -OldVersion $app.Version -Minutes $WaitForExitMinutes
            if ($wait -eq 'updated') { Exit-Guard -Code 0 -Message 'DSH 已自行完成更新，无需接管' }
            if ($wait -eq 'timeout') { Exit-Guard -Code 0 -Message ("DSH {0} 分钟内未退出，本次不安装（下次运行继续）" -f $WaitForExitMinutes) }
            $installed = Invoke-DshInstaller -InstallerPath $installer -InstallDir $app.InstallDir -ExePath $app.ExePath -OldVersion $app.Version -Relaunch $false
        }

        'Auto' {
            $stalePending = ($target.Source -eq 'dsh-pending' -and $target.AgeMin -ge $MinPendingAgeMinutes)
            if ($stalePending) {
                Write-GuardLog -Message ("检测到 DSH 已下载待安装包 {0}（已放置 {1} 分钟），予以接管" -f $target.Version, $target.AgeMin)
            }
            if ($stalePending -and $ForceClose) {
                Write-GuardLog -Level WARN -Message '-ForceClose 生效：关闭 DSH 后立即安装并重启'
                Stop-DshApp -GraceSeconds $GracefulCloseSeconds
                $installed = Invoke-DshInstaller -InstallerPath $installer -InstallDir $app.InstallDir -ExePath $app.ExePath -OldVersion $app.Version -Relaunch $true
            } else {
                if (Get-DshProcesses) {
                    Write-GuardLog -Message 'DSH 正在运行：等它退出后立刻安装（不打断当前会话）；要马上安装用 -Policy Now 或 -ForceClose'
                }
                $wait = Wait-DshIdle -ExePath $app.ExePath -OldVersion $app.Version -Minutes $WaitForExitMinutes
                if ($wait -eq 'updated') { Exit-Guard -Code 0 -Message 'DSH 已自行完成更新，无需接管' }
                if ($wait -eq 'timeout') { Exit-Guard -Code 10 -Message ("已备好新版本 {0}；DSH 仍在运行，退出后自动安装" -f $target.Version) }
                $installed = Invoke-DshInstaller -InstallerPath $installer -InstallDir $app.InstallDir -ExePath $app.ExePath -OldVersion $app.Version -Relaunch $false
            }
        }
    }

    if ($installed) { Exit-Guard -Code 0 -Message '更新完成' }
    Exit-Guard -Code 2 -Message '更新失败，详见日志'
} catch {
    Write-GuardLog -Level ERROR -Message ("异常：" + $_.Exception.Message)
    Write-GuardLog -Level ERROR -Message ("位置：" + $_.InvocationInfo.PositionMessage)
    exit 2
} finally {
    if ($mutex) { try { $mutex.ReleaseMutex() } catch { } ; $mutex.Dispose() }
}
