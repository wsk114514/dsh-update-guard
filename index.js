/**
 * dsh-update-guard — take over the install step of DeepSeek Harness Desktop's
 * self-update on Windows.
 *
 * The desktop app refuses to install an update unless its host child process
 * exits "gracefully" within 10 seconds; when a background task holds a
 * connection, DSH can only SIGTERM the host and then aborts the install with
 *
 *   desktop update: Host did not complete graceful task teardown
 *   (exit null, signal SIGTERM, shutdown acknowledged true, graceful deadline exceeded true)
 *
 * The downloaded installer then sits in
 *   %LOCALAPPDATA%\@deepseek-aidsh-desktop-updater\pending\
 * and the only way forward is a manual reinstall.
 *
 * This plugin ships the PowerShell guard that finishes the job instead:
 *   - re-runs the pending installer silently, with electron-updater's own
 *     arguments (`--updated /S --force-run`), after DSH has exited;
 *   - downloads and verifies the installer itself from the official feed when
 *     nothing is pending;
 *   - keeps that running on a per-user scheduled task (DshUpdateGuard);
 *   - and exposes three tools so the agent can read the state, run the guard on
 *     demand, and install/remove the task.
 *
 * It is a host-plane bundle: no per-agent wiring, no background services, and
 * it never touches the profile. All privileged work happens in the scripts.
 *
 * @module dsh-update-guard
 */

import { execFile } from 'node:child_process'
import { copyFile, mkdir, readdir } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

import { defineTool } from '@deepseek-ai/dsh-tools'

export const name = 'dsh-update-guard'

/** The registry tools live on the host service injected as `tools`. */
export const inject = ['tools']

const HERE = path.dirname(fileURLToPath(import.meta.url))
const SCRIPTS_DIR = path.join(HERE, 'scripts')

/** Guard scripts are copied here so a plugin update cannot break the task. */
const STABLE_DIR = path.join(process.env.LOCALAPPDATA ?? '', 'dsh-update-guard', 'scripts')

const POWERSHELL = path.join(
  process.env.SystemRoot ?? 'C:\\Windows',
  'System32',
  'WindowsPowerShell',
  'v1.0',
  'powershell.exe',
)

const POLICIES = ['auto', 'onexit', 'now', 'stage']
const POLICY_TITLES = {
  auto: 'Auto',
  onexit: 'OnExit',
  now: 'Now',
  stage: 'Stage',
}

/** Quote one value for a PowerShell command line. */
function psQuote (value) {
  const text = String(value)
  return /^[\w./:\\=-]+$/.test(text) ? text : `'${text.replace(/'/g, "''")}'`
}

/**
 * Run one guard script and collect its output.
 *
 * The scripts are Windows PowerShell 5.1 compatible on purpose: `pwsh` (7+) is
 * not installed on a stock machine, while `powershell.exe` always is.
 *
 * Output is forced to UTF-8 first. DSH spawns us with no console, so 5.1 would
 * otherwise encode the scripts' Chinese output with the system ANSI code page
 * and every log line would reach us as U+FFFD replacement characters.
 */
function runScript (scriptPath, args = [], timeoutMs = 120_000) {
  const invocation = args.length ? `& ${psQuote(scriptPath)} ${args.map(psQuote).join(' ')}` : `& ${psQuote(scriptPath)}`
  const command = [
    '[Console]::OutputEncoding = [Text.Encoding]::UTF8;',
    '$OutputEncoding = [Console]::OutputEncoding;',
    `${invocation};`,
    'exit $LASTEXITCODE',
  ].join(' ')
  return new Promise((resolve) => {
    execFile(
      POWERSHELL,
      ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', command],
      { timeout: timeoutMs, windowsHide: true, maxBuffer: 16 * 1024 * 1024, encoding: 'utf8' },
      (error, stdout, stderr) => {
        resolve({
          code: typeof error?.code === 'number' ? error.code : error ? 1 : 0,
          timedOut: error?.killed === true,
          stdout: stdout ?? '',
          stderr: stderr ?? '',
        })
      },
    )
  })
}

/** Split "0.2.2-rc.3" into numeric/prerelease parts for ordering. */
function splitVersion (value) {
  const raw = String(value ?? '').trim().replace(/^v/i, '')
  const match = /^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$/.exec(raw)
  if (!match) return null
  return {
    major: Number(match[1]),
    minor: Number(match[2]),
    patch: Number(match[3]),
    prerelease: match[4] ? match[4].split('.') : [],
  }
}

/**
 * Compare two versions: negative when a < b, positive when a > b, 0 when equal,
 * null when either side is not a version. Prerelease identifiers are compared
 * numerically when both are numeric, and a release sorts after its prereleases.
 */
function compareVersions (a, b) {
  const left = splitVersion(a)
  const right = splitVersion(b)
  if (!left || !right) return null
  for (const key of ['major', 'minor', 'patch']) {
    if (left[key] !== right[key]) return left[key] - right[key]
  }
  if (!left.prerelease.length && !right.prerelease.length) return 0
  if (!left.prerelease.length) return 1
  if (!right.prerelease.length) return -1
  const length = Math.max(left.prerelease.length, right.prerelease.length)
  for (let index = 0; index < length; index += 1) {
    const one = left.prerelease[index]
    const two = right.prerelease[index]
    if (one === undefined) return -1
    if (two === undefined) return 1
    const oneNumber = /^\d+$/.test(one)
    const twoNumber = /^\d+$/.test(two)
    if (oneNumber && twoNumber) {
      if (Number(one) !== Number(two)) return Number(one) - Number(two)
      continue
    }
    if (oneNumber) return -1
    if (twoNumber) return 1
    if (one !== two) return one < two ? -1 : 1
  }
  return 0
}

function formatBytes (value) {
  const bytes = Number(value)
  if (!Number.isFinite(bytes) || bytes <= 0) return '未知'
  const mb = bytes / (1024 * 1024)
  return `${mb.toFixed(1)} MB`
}

function formatAge (minutes) {
  const value = Number(minutes)
  if (!Number.isFinite(value)) return '未知'
  if (value < 60) return `${Math.round(value)} 分钟`
  if (value < 60 * 24) return `${(value / 60).toFixed(1)} 小时`
  return `${(value / (60 * 24)).toFixed(1)} 天`
}

/** Human-readable report for the status tool. */
function renderStatus (status) {
  const lines = []
  const installed = status?.installedVersion ?? null
  const latest = status?.feed?.version ?? null
  const order = installed && latest ? compareVersions(latest, installed) : null

  lines.push('## DSH 桌面版更新状态')
  lines.push('')
  lines.push(`- 已安装版本：${installed ?? '未找到'}`)
  lines.push(`- 安装目录：${status?.installDir ?? '未找到'}`)
  lines.push(`- DSH 进程：${status?.appRunning ? `运行中（${status.processCount} 个进程）` : '未运行'}`)
  if (latest) {
    lines.push(`- 更新源最新：${latest}（${status.feed.releaseDate ?? '无日期'}，${formatBytes(status.feed.size)}）`)
    if (order === null) lines.push('- 版本关系：无法比较（版本号格式异常）')
    else if (order > 0) lines.push('- 版本关系：**有可用更新**')
    else if (order === 0) lines.push('- 版本关系：已是最新')
    else lines.push('- 版本关系：已安装版本比更新源更新（预览/回滚版本）')
  } else {
    lines.push(`- 更新源最新：读取失败（${status?.feed?.error ?? '未知原因'}）`)
  }

  const pending = status?.pending
  lines.push('')
  lines.push('### 待安装包')
  if (pending?.exists && pending.fileName) {
    lines.push(`- 文件：${pending.fileName}`)
    lines.push(`- 大小：${formatBytes(pending.sizeBytes)}`)
    lines.push(`- 已放置：${formatAge(pending.ageMinutes)}`)
    if (pending.isAdminRightsRequired === true) lines.push('- 需要管理员权限')
    lines.push('- 判定：electron-updater 下载成功但安装未完成（守卫会接管这一步）')
  } else if (pending?.exists) {
    lines.push('- 目录存在，但没有安装包文件')
  } else {
    lines.push('- 没有待安装包')
  }

  const task = status?.task
  lines.push('')
  lines.push('### 计划任务')
  if (task?.exists) {
    const result = task.lastTaskResult === 0 ? '成功' : `结果码 ${task.lastTaskResult}`
    lines.push(`- ${task.name}：${task.state}（上次运行 ${task.lastRunTime ?? '未知'}，${result}）`)
    lines.push(`- 动作：${task.execute ?? '?'} ${task.arguments ?? ''}`.trim())
  } else {
    lines.push(`- ${task?.name ?? 'DshUpdateGuard'}：未注册（可用 dsh_update_guard_setup 创建）`)
  }

  const tail = Array.isArray(status?.log?.tail) ? status.log.tail : []
  lines.push('')
  lines.push(`### 守卫日志（${status?.log?.path ?? '无'}）`)
  if (tail.length === 0) lines.push('- 暂无日志')
  else for (const line of tail.slice(-10)) lines.push(`- ${String(line).replace(/^\d{4}-\d{2}-\d{2} /, '')}`)

  lines.push('')
  lines.push('提示：让守卫完成一次安装用 dsh_update_guard_run；安装/修复计划任务用 dsh_update_guard_setup。')
  return lines.join('\n')
}

/** Runs `guard-status.ps1` and parses its JSON. */
async function readStatus ({ logLines = 12 } = {}) {
  const script = path.join(SCRIPTS_DIR, 'guard-status.ps1')
  if (!existsSync(script)) throw new Error(`找不到 guard-status.ps1：${script}`)
  const result = await runScript(script, ['-LogLines', String(logLines)], 90_000)
  const text = result.stdout.trim()
  if (!text) {
    throw new Error(`状态探测没有输出（退出码 ${result.code}）：${result.stderr.trim() || '无错误信息'}`)
  }
  try {
    return JSON.parse(text)
  } catch (error) {
    throw new Error(`状态探测输出不是 JSON：${error.message}；前 200 字符：${text.slice(0, 200)}`)
  }
}

/** Copy both scripts to the stable per-user location the task points at. */
async function publishScripts () {
  await mkdir(STABLE_DIR, { recursive: true })
  const names = (await readdir(SCRIPTS_DIR)).filter(
    (entry) => entry.endsWith('.ps1') || entry.endsWith('.vbs')
  )
  for (const entry of names) {
    await copyFile(path.join(SCRIPTS_DIR, entry), path.join(STABLE_DIR, entry))
  }
  return names
}

function normalizePolicy (value) {
  const policy = String(value ?? 'auto').toLowerCase()
  if (!POLICIES.includes(policy)) {
    throw new Error(`未知策略 "${value}"，可选：${POLICIES.join(' / ')}`)
  }
  return policy
}

export function apply (ctx) {
  ctx.tools.register(defineTool({
    name: 'dsh_update_guard_status',
    description:
      'Read the DeepSeek Harness Desktop update state on this Windows machine without changing anything: '
      + 'the installed version, the version the official update feed advertises, whether a downloaded '
      + 'installer is sitting in electron-updater\'s pending directory (the signature of a self-update that '
      + 'failed at the install step), the DshUpdateGuard scheduled task, and the tail of the guard log. '
      + 'Use it before suggesting an update, and to explain why DSH keeps asking to install the same build.',
    parameters: {
      logLines: {
        type: 'number',
        description: 'How many trailing guard log lines to include (default 12, max 200).',
      },
    },
    output: {
      schema: { type: 'object', additionalProperties: true },
      render: (_args, value) => [{ type: 'text', text: renderStatus(value) }],
    },
    execute: async (args) => {
      const raw = Number(args?.logLines)
      const logLines = Number.isFinite(raw) && raw > 0 ? Math.min(Math.floor(raw), 200) : 12
      return readStatus({ logLines })
    },
    timeoutMs: 120_000,
  }))

  ctx.tools.register(defineTool({
    name: 'dsh_update_guard_run',
    description:
      'Run the DSH desktop update guard now, on this machine, and report what it did. The guard installs the '
      + 'installer electron-updater already downloaded (or downloads the current release itself), verifies its '
      + 'Authenticode signature, and finishes the install that the DSH in-app updater abandoned.\n\n'
      + 'POLICY picks how intrusive it may be: `auto` (default) never interrupts a running DSH — it waits up to '
      + 'waitForExitMinutes for the app to quit, then installs silently; `onexit` is the same but never downloads; '
      + '`stage` only downloads and verifies without installing; `now` closes DSH (forcefully after a grace '
      + 'period) and installs immediately, restarting the app afterwards.\n\n'
      + 'WARNING: `now`, and `auto` with forceClose=true, will terminate the running DeepSeek Harness — which '
      + 'also terminates this session mid-call. Only use them when the user explicitly asked for the update to '
      + 'happen right now. Otherwise call with `auto` after the user has closed DSH, or schedule it with '
      + 'dsh_update_guard_setup and let the task do the work.',
    parameters: {
      policy: {
        type: 'string',
        description: 'auto (default) | onexit | stage | now. See the description for what each one may do.',
      },
      forceClose: {
        type: 'boolean',
        description: 'auto/onexit only: when a pending installer is older than the minimum age, close DSH, install and relaunch. Terminates the current session.',
      },
      dryRun: {
        type: 'boolean',
        description: 'Decide and log what would happen without downloading or installing anything.',
      },
      waitForExitMinutes: {
        type: 'number',
        description: 'How long auto/onexit may wait for DSH to exit (default 3 minutes).',
      },
    },
    output: {
      schema: { type: 'object', additionalProperties: true },
      render: (_args, value) => [{ type: 'text', text: value.summary }],
    },
    execute: async (args) => {
      const policy = normalizePolicy(args?.policy)
      const script = path.join(SCRIPTS_DIR, 'dsh-update-guard.ps1')
      if (!existsSync(script)) throw new Error(`找不到 dsh-update-guard.ps1：${script}`)

      const argv = ['-Policy', POLICY_TITLES[policy]]
      const wait = Number(args?.waitForExitMinutes)
      if (Number.isFinite(wait) && wait >= 0) argv.push('-WaitForExitMinutes', String(Math.floor(wait)))
      if (args?.forceClose === true) argv.push('-ForceClose')
      if (args?.dryRun === true) argv.push('-DryRun')

      const timeout = Math.max(120_000, Math.min(900_000, (policy === 'now' ? 10 : 4) * 60_000))
      const result = await runScript(script, argv, timeout)

      const status = await readStatus({ logLines: 20 }).catch(() => null)
      const heading = result.timedOut
        ? `守卫执行超时（${Math.round(timeout / 60_000)} 分钟），可能仍在等待 DSH 退出。`
        : `守卫执行完成，退出码 ${result.code}。`
      const parts = [heading]
      if (status) parts.push('', renderStatus(status))
      if (result.stderr.trim()) parts.push('', '### 标准错误', result.stderr.trim())
      return {
        summary: parts.join('\n'),
        exitCode: result.code,
        timedOut: result.timedOut,
        stdout: result.stdout.trim(),
        stderr: result.stderr.trim(),
        status,
      }
    },
    timeoutMs: 900_000,
  }))

  ctx.tools.register(defineTool({
    name: 'dsh_update_guard_setup',
    description:
      'Install, repair, remove or inspect the DshUpdateGuard scheduled task that keeps finishing DSH desktop '
      + 'updates in the background. `install` copies the guard scripts to a stable per-user folder '
      + '(%LOCALAPPDATA%\\dsh-update-guard\\scripts) so later plugin updates cannot break the task, then '
      + 'registers the task: once at logon and every 5 minutes, running as the current user in a hidden window. '
      + '`remove` unregisters it. `status` only reports whether it exists.',
    parameters: {
      action: {
        type: 'string',
        description: 'install (default) | remove | status.',
      },
      policy: {
        type: 'string',
        description: 'Policy the scheduled run uses: auto (default) | onexit | stage | now.',
      },
      forceClose: {
        type: 'boolean',
        description: 'Pass -ForceClose to every scheduled run (lets auto interrupt a running DSH). Off by default.',
      },
    },
    output: {
      schema: { type: 'object', additionalProperties: true },
      render: (_args, value) => [{ type: 'text', text: value.summary }],
    },
    execute: async (args) => {
      const action = String(args?.action ?? 'install').toLowerCase()
      if (!['install', 'remove', 'status'].includes(action)) {
        throw new Error(`未知 action "${args?.action}"，可选：install / remove / status`)
      }

      if (action === 'status') {
        const status = await readStatus({ logLines: 5 })
        const task = status?.task
        const summary = task?.exists
          ? `计划任务 ${task.name} 已注册：${task.state}，上次运行 ${task.lastRunTime ?? '未知'}，结果码 ${task.lastTaskResult}。`
          : `计划任务 ${task?.name ?? 'DshUpdateGuard'} 未注册。`
        return { summary, task }
      }

      const published = await publishScripts()
      const register = path.join(STABLE_DIR, 'register-dsh-update-guard.ps1')
      if (!existsSync(register)) throw new Error(`脚本复制后仍找不到 ${register}`)

      const argv = action === 'remove'
        ? ['-Unregister']
        : ['-Policy', POLICY_TITLES[normalizePolicy(args?.policy)], ...(args?.forceClose === true ? ['-ForceClose'] : [])]

      const result = await runScript(register, argv, 120_000)
      const status = await readStatus({ logLines: 3 }).catch(() => null)
      const parts = [
        action === 'remove' ? '已请求卸载计划任务。' : '已注册计划任务。',
        '',
        `- 脚本目录：${STABLE_DIR}（${published.join(', ')}）`,
        `- 退出码：${result.code}`,
      ]
      if (status?.task?.exists) {
        parts.push(`- 任务：${status.task.name}，${status.task.state}，动作 ${status.task.arguments ?? ''}`.trim())
      }
      const output = (result.stdout || result.stderr).trim()
      if (output) parts.push('', '### 脚本输出', output)
      return { summary: parts.join('\n'), exitCode: result.code, stdout: result.stdout.trim(), stderr: result.stderr.trim() }
    },
    timeoutMs: 180_000,
  }))
}
