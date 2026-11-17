<#
.SYNOPSIS
    注册 / 卸载 DSH 桌面版更新守卫的计划任务。

.DESCRIPTION
    注册一个名为 DshUpdateGuard 的当前用户计划任务：
      · 登录时触发一次
      · 之后每 5 分钟触发一次
    任务以最低权限（普通用户）运行，静默执行 dsh-update-guard.ps1。
    守卫脚本自己判断有没有待安装的更新：没有就立即退出，有就按策略接管安装。

.PARAMETER Unregister
    删除计划任务。

.PARAMETER Policy
    传给守卫脚本的 -Policy，默认 Auto。
    Auto     非侵入：DSH 退出后立刻安装（推荐）
    OnExit   与 Auto 一样保守，但从不主动下载
    Now      每次触发都尝试立即安装（会关闭 DSH）
    Stage    只下载校验，不安装

.PARAMETER ForceClose
    传给守卫脚本的 -ForceClose（判定自动安装已失败时直接关掉 DSH 安装并重启）。

.PARAMETER TaskName
    计划任务名，默认 DshUpdateGuard。

.EXAMPLE
    .\register-dsh-update-guard.ps1

.EXAMPLE
    .\register-dsh-update-guard.ps1 -Unregister
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Unregister,
    [ValidateSet('Auto', 'OnExit', 'Now', 'Stage')]
    [string]$Policy = 'Auto',
    [switch]$ForceClose,
    [string]$TaskName = 'DshUpdateGuard'
)

$ErrorActionPreference = 'Stop'

# 被插件以重定向方式调用时强制 UTF-8 输出（否则中文提示变乱码）；交互运行时
# 保持控制台自己的编码。
try {
    if ([Console]::IsOutputRedirected) {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
        $OutputEncoding = [Console]::OutputEncoding
    }
} catch { }

$guard = Join-Path $PSScriptRoot 'dsh-update-guard.ps1'
$launcher = Join-Path $PSScriptRoot 'dsh-update-guard-launch.vbs'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'

function Write-Step {
    param([string]$Message)
    Write-Host ('[*] ' + $Message) -ForegroundColor Cyan
}

if ($Unregister) {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $existing) {
        Write-Host ('[-] 计划任务 {0} 不存在，无需卸载' -f $TaskName)
        exit 0
    }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host ('[+] 已删除计划任务 {0}' -f $TaskName) -ForegroundColor Green
    exit 0
}

if (-not (Test-Path $guard)) { throw ('找不到守卫脚本：' + $guard) }
if (-not (Test-Path $powershell)) { throw ('找不到 powershell.exe：' + $powershell) }

# ---------------------------------------------------------------- 组装动作 ----
# 用 wscript.exe 跑一个 VBS 启动器，再由它用「隐藏窗口」拉起 powershell。
# 直接把 powershell.exe 当成任务动作时，即使加了 -WindowStyle Hidden，Windows
# 也是先创建控制台窗口再应用隐藏样式，于是用户会看到黑窗每几分钟闪一下。
if ((Test-Path $launcher) -and (Test-Path $wscript)) {
    $arguments = ('//B //Nologo "{0}" -Policy {1}' -f $launcher, $Policy)
    if ($ForceClose) { $arguments += ' -ForceClose' }
    $action = New-ScheduledTaskAction -Execute $wscript -Argument $arguments -WorkingDirectory $PSScriptRoot
} else {
    $arguments = ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Policy {1}' -f $guard, $Policy)
    if ($ForceClose) { $arguments += ' -ForceClose' }
    $action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments -WorkingDirectory $PSScriptRoot
    Write-Warning '找不到 wscript.exe 或启动器，退回直接调用 powershell（可能短暂闪窗）'
}

# ---------------------------------------------------------------- 组装触发 ----
# 1) 登录时
$triggerLogon = New-ScheduledTaskTrigger -AtLogOn -User ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME)

# 2) 首次 3 分钟后开始，每 5 分钟一次，重复 10 年（等价于长期有效）
$triggerRepeat = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(3)) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) `
    -RepetitionDuration (New-TimeSpan -Days 3650)

$settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1)

$principal = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) `
    -LogonType Interactive -RunLevel Limited

Write-Step ('注册计划任务 {0}' -f $TaskName)
Write-Step ('动作：{0} {1}' -f $action.Execute, $action.Arguments)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($triggerLogon, $triggerRepeat) `
    -Settings $settings -Principal $principal -Description '接管 DeepSeek Harness 桌面版失败/待定的自动更新安装' -Force | Out-Null

$task = Get-ScheduledTask -TaskName $TaskName
Write-Host ('[+] 已注册：{0}（状态 {1}）' -f $task.TaskName, $task.State) -ForegroundColor Green
$task.Triggers | ForEach-Object {
    if ($_.Repetition -and $_.Repetition.Interval) {
        Write-Host ('    · 每 {0} 重复一次' -f $_.Repetition.Interval)
    } else {
        Write-Host ('    · 触发器 {0}' -f $_.CimClass.CimClassName)
    }
}
Write-Host ''
Write-Host '下一步可以：' -ForegroundColor Yellow
Write-Host ('    Start-ScheduledTask -TaskName {0}          # 立即跑一次' -f $TaskName)
Write-Host ('    Get-Content "$env:LOCALAPPDATA\dsh-update-guard\guard.log" -Tail 20' -f '')
Write-Host ('    .\register-dsh-update-guard.ps1 -Unregister # 卸载' -f '')
