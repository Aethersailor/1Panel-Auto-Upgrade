# 1Panel 自动升级管理器

一个公开、可审阅的单文件脚本，用于自动升级：

- 1Panel 应用商店中的可升级应用；
- 1Panel Core、Agent 和 `1pctl`。

安装时可以选择仅启用应用升级、仅启用面板升级，或者同时启用。安装完成后只需运行 `1pup`，其余操作都通过中文菜单完成。

## 特点

- 单文件源码：主要功能全部位于 [`1pup.sh`](./1pup.sh)。
- 无编译二进制，不安装 PyPI 依赖。
- 应用升级复用 1Panel 本机 Agent API，参数与人工点击升级一致。
- 面板升级调用 1Panel 官方升级 API，不自行替换面板二进制。
- 应用和面板升级使用独立定时器，并通过全局锁避免并发。
- 支持自定义功能、时间和时区。
- 提供只读检查、状态、日志、修复、更新和卸载菜单。
- 面板目标版本不健康时，调用官方 `1pctl restore` 恢复上一版本。

## 要求

- 1Panel V2 主节点；
- 使用 systemd 的 Linux；
- `root` 或 `sudo` 权限；
- Python 3.8 或更高版本，仅使用标准库；
- 服务器能够访问 1Panel 和 GitHub；
- 如果启用面板本体升级：需要在 1Panel 中启用 API，并允许本机回环地址访问。

应用自动升级不要求启用对外 API，它通过 `/etc/1panel/agent.sock` 调用本机 Agent。

## 首次安装

使用 `curl`：

```bash
curl -fsSL https://raw.githubusercontent.com/Aethersailor/1Panel-Auto-Upgrade/main/1pup.sh -o /tmp/1pup.sh \
  && sudo bash /tmp/1pup.sh
```

使用 `wget`：

```bash
wget -qO /tmp/1pup.sh https://raw.githubusercontent.com/Aethersailor/1Panel-Auto-Upgrade/main/1pup.sh \
  && sudo bash /tmp/1pup.sh
```

### 中国大陆网络

如果 GitHub Raw 访问不稳定，可以尝试 jsDelivr。

使用 `curl`：

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/Aethersailor/1Panel-Auto-Upgrade@main/1pup.sh -o /tmp/1pup.sh \
  && sudo bash /tmp/1pup.sh
```

使用 `wget`：

```bash
wget -qO /tmp/1pup.sh https://cdn.jsdelivr.net/gh/Aethersailor/1Panel-Auto-Upgrade@main/1pup.sh \
  && sudo bash /tmp/1pup.sh
```

jsDelivr 的分支文件可能存在缓存延迟。需要立即获取仓库最新内容时，以 GitHub Raw 地址为准。

当前已验证的 v0.1.1 固定提交地址：

```text
https://cdn.jsdelivr.net/gh/Aethersailor/1Panel-Auto-Upgrade@07543c3268fc78b824f0374e4268076def1c8d0e/1pup.sh
```

安装脚本首先执行只读环境检查，然后进入设置向导：

```text
1) 仅应用自动升级
2) 仅 1Panel 本体自动升级
3) 两者都启用 [默认]
```

默认时间使用服务器当前时区：

- 应用升级：每天 03:17；
- 面板升级：每天 04:47。

安装不会立即执行升级。

## 后续使用

```bash
1pup
```

菜单提供：

```text
1. 查看状态
2. 修改功能和时间
3. 只读检查更新
4. 立即执行升级
5. 查看日志
6. 修复自动升级工具
7. 卸载
8. 更新管理脚本
0. 退出
```

`1pup` 在需要权限时自动调用 `sudo`。

## 升级行为

### 应用升级

1. 同步 1Panel 应用商店。
2. 读取「可升级」页面中的全部应用。
3. 选择页面默认的第一个目标版本。
4. 实时读取面板当前的「升级前备份」和「升级后删除旧镜像」设置。
5. 保持 `pullImage=true`。
6. 逐个调用 1Panel 原生应用升级任务，并等待任务中心返回结果。

脚本不把固定标签改成 `latest`，也不自行增加应用白名单或版本策略。

### 面板升级

1. 调用 `/api/v2/core/settings/upgrade` 检查版本。
2. 按 1Panel 页面顺序选择 `latestVersion`、`testVersion`、`newVersion`。
3. 检查面板空闲、Core/Agent 正常、应用升级未运行，以及至少 500 MB 可用空间。
4. 调用 1Panel 官方升级 API。
5. 验证 Core、Agent、数据库、API 和 `1pctl` 版本。
6. 目标版本已写入但运行状态不健康时，调用 `1pctl restore`。

API Key 只从本机 1Panel 数据库读取，不写入本项目配置，不输出到日志，也不发送到外部地址。

## 只读检查

从菜单选择「只读检查更新」，或者执行：

```bash
1pup check all
```

只检查应用和面板更新，不安装、不升级、不重启。

## 修复

从菜单选择「修复自动升级工具」，或者执行：

```bash
1pup repair
```

修复会校验脚本、配置、权限和 systemd 单元，重新生成缺失的定时器，并执行只读检查。修复不会升级或重启 1Panel。

如果已安装脚本本身无法运行，可以重新下载仓库脚本并执行：

```bash
sudo bash /tmp/1pup.sh repair
```

## 卸载

从菜单选择「卸载」，或者执行：

```bash
1pup uninstall
```

普通卸载保留 `/etc/1panel-auto-upgrade/config.conf`。完全删除配置：

```bash
1pup uninstall --purge
```

卸载不会删除应用、镜像、容器、1Panel 数据、面板升级备份或 journald 历史日志。

## 更新管理脚本

运行 `1pup` 并选择「更新管理脚本」。脚本优先从 GitHub Raw 下载仓库 `main` 分支，失败时自动回退到 jsDelivr。完成 Bash 语法检查和嵌入 Python 自检后才替换当前文件，并保留现有配置。

本项目不发布 GitHub Release；仓库 `main` 分支是公开更新来源。

## 高级命令

普通用户无需记忆这些命令，运行 `1pup` 即可。

```text
1pup status
1pup configure
1pup check apps|panel|all
1pup run apps|panel|all
1pup logs apps|panel|all
1pup repair
1pup update
1pup uninstall [--purge]
```

## 日志

日志保存在 journald：

```bash
journalctl -u 1panel-app-auto-upgrade.service
journalctl -u 1panel-system-auto-upgrade.service
```

也可以直接从 `1pup` 菜单查看。

## 安全说明

- 请先阅读脚本，再以 root 权限运行。
- 不要从第三方镜像地址下载修改过的脚本。
- 脚本不会自动开启或修改 1Panel API 设置。
- API 未启用或回环地址无权访问时，面板升级模块会停止安装或检查。
- 应用或面板升级正在运行时，修复、更新和卸载会拒绝执行。

更多信息参见 [SECURITY.md](./SECURITY.md)。

## 许可证

[MIT](./LICENSE)
