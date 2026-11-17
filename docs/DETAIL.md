# 更新守卫 / Update guard — 设计说明

> 本文是插件在 DSH 里的详情页内容，也是实现细节的归档。

## 1. 它解决什么

DeepSeek Harness 桌面版（Windows）的应用内更新分两步：先下载安装包，再关闭自身并执行安装。
第二步经常失败，界面报：

```
desktop update: Host did not complete graceful task teardown
(exit null, signal SIGTERM, shutdown acknowledged true, graceful deadline exceeded true)
```

失败之后安装包已经下载好了，却留在缓存目录里，界面只提示"更新失败"，用户只能去官网重新下载、手动安装。
每次发版都要重复一次，这就是本插件存在的原因。

## 2. 根因

反编译 `app.asar` 的 `lib/main.js` 可以确认这不是网络或权限问题，而是 DSH 自己的保护逻辑：

```js
// lib/main.js:11951  host.stop(requireGraceful)
if (requireGraceful && (!graceful || child.exitCode !== 0 || !this.shutdownCompleted)) {
  throw new DesktopHostUncleanExitError(...)
}
```

`stop()` 的顺序是：发 `{type:"shutdown"}` → 等 10 秒 → `SIGTERM` → 等 5 秒 → `SIGKILL` → 等 5 秒。
只要 host 子进程没在 10 秒内**主动**退出（有后台任务、插件连接或长任务的会话就会这样），
DSH 只能强杀，`shutdownCompleted` 为假，于是抛错。

安装调用链是：

```js
// lib/main.js:14885-14915  install(version, revision)
await this.beforeRestart()        // -> host.updateTasks('lock') -> backend.stop()  (requireCleanStop = true)
if (stopFailed) throw new DesktopUpdatePreparationError('stop-failed', ...)   // 记录 updateStopFailure
this.updater.quitAndInstall(true, true)                                       // 只有成功才走到这里
```

也就是说：**DSH 在 close 阶段失败时根本不会执行安装**，而 `electron-updater` 已经把安装包下载到了
`%LOCALAPPDATA%\@deepseek-aidsh-desktop-updater\pending\`。
同时 `autoInstallOnAppQuit = false`、`autoDownload = false`（`main.js:14740-14741`），
所以 pending 目录里出现安装包，一定意味着"用户点过下载/安装"，可以安全地作为接管的信号。

## 3. 守卫怎么做

`scripts/dsh-update-guard.ps1` 复刻 electron-updater 的安装调用（`NsisUpdater.doInstall`）：

```
deepseek-harness-<version>-win-x64.exe --updated /S --force-run [/D=<installDir>]
```

1. 读安装目录（注册表 Uninstall 项 + 默认路径），读 `resources/app-update.yml` 得到更新源 `url` 与 `channel`。
2. 读 `<url>/<channel>.yml`（DSH 用的是 `nightly.yml`，不是 `latest.yml`）得到最新版本、文件名、sha512、大小。
3. 取安装包：优先用 pending 目录里 DSH 已经下好的；没有就用 BITS（失败退 `Invoke-WebRequest`）下载并校验大小。
4. 校验 Authenticode：签名状态必须是 `Valid`，Subject 必须含 `DeepSeek`（可用 `-SkipSignatureCheck` 关闭，不建议）。
5. 等 DSH 空闲或退出（`-Policy` 决定），然后静默安装，安装后轮询 exe 的 `FileVersion` 90 秒确认版本真的变了。
6. 写日志到 `%LOCALAPPDATA%\dsh-update-guard\guard.log`（超过 1 MB 轮转成 `guard.1.log`）。

### 策略

| Policy | 何时装 | 会不会打断当前会话 | 装完是否自动启动 |
| --- | --- | --- | --- |
| `Auto`（默认） | DSH 退出后装；有 pending 包且放置超过 10 分钟时视为"用户已放弃" | 否 | 否（下次打开就是新版） |
| `OnExit` | 同 Auto，但从不主动下载，只用 DSH 自己下好的包 | 否 | 否 |
| `Stage` | 只下载 + 校验，不安装 | 否 | — |
| `Now` | 立即：先优雅关闭，45 秒后强杀 | **是** | 是 |
| `Auto` + `-ForceClose` | 有 pending 包时直接关闭、安装并重启 | **是** | 是 |

默认选择 `Auto` 是有意的：更新不值得打断一次正在进行的会话，而 DSH 退出后安装、下次启动即新版，用户感知不到。

### 计划任务

`scripts/register-dsh-update-guard.ps1` 注册名为 `DshUpdateGuard` 的**当前用户**任务：

- 登录时触发一次 + 之后每 5 分钟触发一次（重复 3650 天，等价于长期有效）；
- `Interactive` / `Limited`：普通用户权限，不需要管理员（安装器 `isAdminRightsRequired=false`）；
- 隐藏窗口运行 `powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ... -Policy Auto`；
- `MultipleInstances IgnoreNew`，守卫内部还有 `Local\DshUpdateGuard` 互斥体，不会并发安装。

插件安装任务时会把两个脚本复制到 `%LOCALAPPDATA%\dsh-update-guard\scripts\`，让任务指向**稳定副本**：
以后升级/重装插件都不会因为 `node_modules` 目录被替换而让任务失效。

### 工具

| 工具 | 作用 |
| --- | --- |
| `dsh_update_guard_status` | 只读汇总：已装版本、更新源最新版本、pending 安装包、计划任务、日志尾部 |
| `dsh_update_guard_run` | 立刻跑一次守卫（`policy` / `forceClose` / `dryRun` / `waitForExitMinutes`） |
| `dsh_update_guard_setup` | `install` / `remove` / `status` 计划任务，并把脚本发布到稳定目录 |

`Now` 与 `forceClose` 会结束正在运行的 DSH——连同承载会话的宿主进程，所以工具描述里明确警告，
只在用户明确要求"现在就装"时使用。

## 4. 限制与注意

- **仅 Windows**：依赖 NSIS 安装器、Authenticode、计划任务与注册表。`package.json` 的 `os` 字段已限制。
- **依赖官方的更新源格式**：`<feed>/<channel>.yml` + `provider: generic`。如果官方改用其他 provider
  （如 GitHub releases），`Get-FeedRelease` 需要相应调整，但"接管 pending 安装包"的主路径不受影响。
- **需要 Windows PowerShell 5.1**：脚本刻意不用 `pwsh` 7 的特性（PS 5.1 是系统自带的）。
  脚本文件必须保存为 **UTF-8 带 BOM**，否则 5.1 会按本地 ANSI 解码中文导致解析失败。
- **安装那一步依赖官方签名校验**：只接受 Subject 含 `DeepSeek` 的有效签名安装包，避免被替换成任意 exe。
- **没有做自动回滚**：如果新版本装坏了，用官网安装包覆盖安装即可，守卫不会因此重试或降级。
- **任务不处理"下载失败"**：网络问题由守卫的重试与日志体现，不额外做重试队列。

## 5. 卸载

```powershell
# 1) 删除计划任务（推荐先做，否则任务会继续按策略安装更新）
.\register-dsh-update-guard.ps1 -Unregister
# 或：Unregister-ScheduledTask -TaskName DshUpdateGuard -Confirm:$false

# 2) 移除插件
#    在 DSH 里用 plugin_manager 移除 dsh-update-guard，或从 profile 里删掉这个包

# 3) 可选：删掉日志与稳定脚本副本
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\dsh-update-guard"
```
