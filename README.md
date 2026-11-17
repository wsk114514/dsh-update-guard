# dsh-update-guard

> 接管 DeepSeek Harness 桌面版在 Windows 上失败的自动安装。
> 当应用内更新因「优雅退出超时」而放弃安装时，由计划任务把**已经下载好的安装包**静默装完。

[![DSH](https://img.shields.io/badge/DSH-%3E%3D0.2.0--rc.1-4D6BFE)](https://github.com/deepseek-ai)
[![平台](https://img.shields.io/badge/platform-Windows-0078D4)](#限制)
[![许可证](https://img.shields.io/badge/license-MIT-green)](LICENSE)

## 问题

DeepSeek Harness 桌面版更新时，界面经常报：

```
desktop update: Host did not complete graceful task teardown
(exit null, signal SIGTERM, shutdown acknowledged true, graceful deadline exceeded true)
```

然后更新就没了。安装包其实已经下载好躺在缓存里，但应用只显示失败，于是每次发版都要去官网重新下载、手动安装。

## 原因

不是网络问题，是 DSH 自己的保护逻辑。`lib/main.js` 里 `host.stop(requireGraceful)` 要求宿主进程在 10 秒内**主动**退出
（shutdown 消息 → 10 秒 → SIGTERM → 5 秒 → SIGKILL），否则判定为不干净退出并抛错；
而更新流程在关闭阶段失败时，`install()` 压根不会走到 `quitAndInstall()`（见 [docs/DETAIL.md](docs/DETAIL.md)）。

安装包留在：

```
%LOCALAPPDATA%\@deepseek-aidsh-desktop-updater\pending\
```

而 DSH 关闭了 `autoInstallOnAppQuit` 和 `autoDownload`，所以**这个目录里有安装包，就一定是你点过"下载/安装"**——
这就是可以安全接管的信号。

## 它做什么

`DshUpdateGuard` 计划任务每 5 分钟检查一次，发现等待安装的安装包就在 DSH 退出后静默安装，下次打开即是新版：

```
deepseek-harness-<版本>-win-x64.exe --updated /S --force-run
```

- **不打断会话**：默认策略下不会关闭正在运行的 DSH，只在它退出后动手。
- **不闪窗**：计划任务通过 `wscript.exe` 跑一个 VBS 启动器，再用隐藏窗口拉起 PowerShell，屏幕上不会每几分钟闪一次黑窗。
- **只装官方包**：校验 Authenticode，签名必须有效且 Subject 含 `DeepSeek`。
- **普通用户权限**：安装器 `isAdminRightsRequired=false`，不需要管理员。
- **可观察**：日志在 `%LOCALAPPDATA%\dsh-update-guard\guard.log`，随时用工具查状态。

## 安装

### 通过 DSH 插件管理器

```
plugin_manager install_bundle  target = <本包目录的绝对路径>
```

装完在插件列表里能看到「更新守卫」，并出现三个工具。随后执行一次：

```
dsh_update_guard_setup  action = install
```

会把脚本发布到 `%LOCALAPPDATA%\dsh-update-guard\scripts\` 并注册计划任务 `DshUpdateGuard`
（指向稳定副本，重装插件不会让任务失效）。

### 从 GitHub 源码

```powershell
git clone https://github.com/wsk114514/dsh-update-guard.git
# 然后用 plugin_manager install_bundle 指向 clone 下来的目录
```

## 使用

| 工具 | 说明 |
| --- | --- |
| `dsh_update_guard_status` | 只读汇总：已装版本、更新源最新版本、待装安装包、计划任务状态、日志尾部 |
| `dsh_update_guard_run` | 立刻执行一次（`policy`: `auto` / `onexit` / `now` / `stage`，`dryRun` 只探测不操作） |
| `dsh_update_guard_setup` | `install` / `remove` / `status` 计划任务 |

只想看现状：

```
dsh_update_guard_status
```

### 直接跑脚本

```powershell
cd "$env:LOCALAPPDATA\dsh-update-guard\scripts"

.\dsh-update-guard.ps1 -SelfTest            # 自检（含版本比较与 YAML 解析断言）
.\dsh-update-guard.ps1 -DryRun              # 只报告会做什么
.\dsh-update-guard.ps1 -Policy Auto         # 等 DSH 退出后安装
.\dsh-update-guard.ps1 -Policy Now          # 立刻关闭 DSH、安装并重启（会中断会话）
.\dsh-update-guard.ps1 -Policy Stage        # 只下载 + 校验，不安装
.\register-dsh-update-guard.ps1             # 注册/更新计划任务
.\register-dsh-update-guard.ps1 -Unregister # 卸载计划任务
```

### 策略

| Policy | 何时安装 | 打断会话 | 装完自动启动 |
| --- | --- | --- | --- |
| `Auto`（默认） | DSH 退出后；pending 包放置超过 10 分钟视为"用户已放弃" | 否 | 否 |
| `OnExit` | 同 Auto，但从不主动下载 | 否 | 否 |
| `Stage` | 只下载校验 | 否 | — |
| `Now` | 立即，45 秒优雅期后强杀 | **是** | 是 |
| `Auto -ForceClose` | 有 pending 包就关掉装 | **是** | 是 |

## 限制

- **仅 Windows**：依赖 NSIS 安装器、Authenticode、计划任务。
- 需要 **Windows PowerShell 5.1**（系统自带）；脚本文件必须保持 UTF-8 **带 BOM**，否则 5.1 按 ANSI 解码中文会解析失败。
- 更新源读取 `<feed>/<channel>.yml`（DSH 用的是 `nightly.yml`，不是 `latest.yml`）。官方若改用其他 provider 需调整，但接管 pending 安装包的主路径不受影响。
- 不做自动回滚：新版本有问题时用官网安装包覆盖安装即可。

## 卸载

```powershell
.\register-dsh-update-guard.ps1 -Unregister
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\dsh-update-guard"   # 可选：日志与脚本副本
# 再用 plugin_manager 移除插件 dsh-update-guard
```

## 开发

```
index.js                    Host 插件入口：注册三个工具
cordis.patch.yml            bundle patch（插入插件行）
scripts/dsh-update-guard.ps1          核心守卫脚本
scripts/register-dsh-update-guard.ps1 计划任务注册
scripts/guard-status.ps1              只读状态探测，输出单行 JSON
scripts/dsh-update-guard-launch.vbs   隐藏窗口启动器（计划任务经 wscript 调用它）
docs/DETAIL.md              根因与实现细节
```

改完 `index.js` 后 `node --check index.js`；改 PowerShell 后用 `-SelfTest` 与 `-DryRun` 自检。

## 更新记录

- **1.0.1** —— 修：计划任务每 5 分钟在屏幕上闪一次黑窗。任务动作从 `powershell.exe -WindowStyle Hidden`
  改为 `wscript.exe //B //Nologo <启动器>.vbs`，由启动器以隐藏窗口拉起 PowerShell
  （`powershell.exe` 是控制台程序，控制台窗口总会在隐藏样式生效前先被创建）。同时修掉重定向输出时的中文乱码。
- **1.0.0** —— 首个版本：三个工具（status / run / setup）、五种策略、计划任务、自带签名校验与日志。

## 许可证

[MIT](LICENSE)
