# gsync · 多仓库安全同步工具（macOS）

一条命令装好，跨设备复用的 Git 仓库定时同步工具。

换设备不用再手动 `git pull`：固定时间自动快进、解锁唤醒补一次、只在真正需要时通知到手机。

**安全策略**：只有当「落后远端、没有本地未推送提交、已跟踪文件无改动」三个条件同时满足时，
才执行 `git merge --ff-only` 快进；其余任何情况（合并中、分叉、工作区脏、游离 HEAD、锁残留）
一律跳过并记录，**绝不留下冲突现场**。

## 快速开始

```bash
git clone https://github.com/wangyc-edu/gsync-kit.git
cd gsync-kit
bash gsync install
```

也可以把仓库打包拷到目标机器（无网络时），同样 `bash gsync install`。

按提示回车即可（默认扫 `~/Documents/gitlab`，每天 08:50、13:50，解锁后顺带同步）。
装完立即试跑一次，之后可用下面命令调整。

装完最后一步：**新开一个终端窗口**（让 PATH 生效），执行

```bash
gsync reload
```

把定时任务交给系统。安装时会把 `~/.local/bin` 写进 `~/.zshenv`，所以新终端里
`gsync` 就是一条命令；当前已开着的旧终端需要先 `source ~/.zshenv`。

前置依赖：`git` 和 `jq`（`brew install jq`），`python3` 可选（缺了报告降级为纯文本）。

## 常用命令

| 命令 | 作用 |
|---|---|
| `gsync ui` | 打开浏览器可视化配置界面（推荐） |
| `gsync status` | 配置、定时状态、每个仓库的结果 |
| `gsync run` | 立即同步一次；`-n` 预演不动任何文件 |
| `gsync config --set TIMES=09:00,17:00` | 直接改配置 |
| `gsync reload` | 改完时间/解锁设置后重新加载定时任务 |
| `gsync log -n 50` | 看运行日志 |
| `gsync doctor` | 环境自检（缺什么、哪里被拦一目了然） |
| `gsync uninstall` | 卸载定时任务；`--purge` 连配置状态一起删 |

## 可视化配置

```bash
gsync ui
```

会在 `http://127.0.0.1:7788` 起一个只监听本机的网页，能做：

- 编辑仓库目录（带「扫描本机」建议按钮）、每天时间、解锁开关
- 保存并一键重载定时任务
- 预演 / 立即同步 / 查看最近报告
- 查看每个仓库的分支、状态、待处理原因

## 配置文件

`~/.config/git-sync/config.conf`：

```bash
ROOTS="$HOME/Documents/gitlab"   # 多个目录用英文逗号分隔，也可直接指向单个仓库
TIMES="08:50,13:50"              # 留空 = 不启用定时
SYNC_ON_UNLOCK=1                 # 解锁/唤醒后同步一次
UNLOCK_MIN_INTERVAL=60           # 解锁触发的最小间隔（分钟）
SCAN_DEPTH=2                     # 向下查找 .git 的层级
PROVIDER_NAME="GitLab"           # 报告措辞，可改 Gitee / GitHub
```

手工补充仓库：在 `~/.config/git-sync/repos.txt` 里每行写一个仓库路径（`#` 为注释）。

## 触发机制

| 方式 | 实现 | 说明 |
|---|---|---|
| 每天固定时间 | LaunchAgent `io.gsync.timer` | 睡眠错过的在唤醒后补跑 |
| 解锁 / 唤醒 | LaunchAgent `io.gsync.unlock` | 每 60 秒检查锁屏状态，真正解锁且超过冷却时间才执行 |
| 手动 | `gsync run` | 随时 |

同一时刻只有一个同步在跑（进程锁），时间触发和解锁触发叠加也不会互相干扰。

## 手机提醒（可选）

编辑 `~/.config/git-sync/notify.conf`，三选一：

```bash
NOTIFY_TYPE=pushplus
PUSHPLUS_TOKEN=你的token        # 微信里收，需在 pushplus.plus 实名

NOTIFY_TYPE=wecom
WECOM_WEBHOOK=https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxx

NOTIFY_TYPE=bark
BARK_KEY=xxxx                  # 仅 iOS
```

默认只在「状态有变化」时推送，连续 3 天无变化补一条心跳；`PUSH_ALWAYS=1` 改成每次都推。
完全不配置也不影响同步。

## 自定义邮件报告

每次运行用 `~/.config/git-sync/report-template.html` 渲染 HTML 报告（统计条 + 四列表格），
改样式直接编辑该文件；改坏了用随包版本恢复：

```bash
cp report-template.html ~/.config/git-sync/report-template.html
```

## 目录结构

```
gsync                 命令入口：install / reload / run / status / config / ui / doctor / log / uninstall
git-sync.sh           同步引擎，可单独调用：git-sync.sh -n -v
ui/server.py          可视化界面后端（python3 标准库，仅监听 127.0.0.1）
ui/index.html         可视化界面前端
report-template.html  HTML 报告模板
config.conf.example   配置样例
notify.conf.example   推送配置样例（不含任何密钥）
```

安装后的落点：

```
~/bin/git-sync/            引擎与界面
~/.local/bin/gsync         命令（软链）
~/.config/git-sync/        配置（config.conf / notify.conf / report-template.html）
~/.local/state/git-sync/   状态（state.json / last-report.html / sync.log）
~/Library/LaunchAgents/    定时任务 io.gsync.timer / io.gsync.unlock
```

## 常见问题

- **提示 `command not found: gsync`**：PATH 还没生效。新开一个终端窗口，或执行
  `source ~/.zshenv`。也可以用完整路径：`~/bin/git-sync/gsync`。
- **`gsync reload` 报 `Bootstrap failed: 5: Input/output error`**：命令不是从普通
  终端发起的（例如在 IDE、编辑器、WorkBuddy 的内置终端里执行，这些进程受系统沙箱
  限制，无法写入 launchd）。换到 macOS 自带的「终端」App 里执行即可。
- **定时任务没生效**：`gsync doctor` 检查；`~/Documents` 受隐私保护时需给 `/bin/bash`
  授予「完全磁盘访问权限」（系统设置 → 隐私与安全性）。
- **`gsync ui` 端口被占用**：会自动顺延到 7789、7790…，终端里打印的地址以实际为准。
- **目录扫不到仓库**：仓库嵌套超过一层时把 `SCAN_DEPTH` 调大，或直接把仓库路径写进 `ROOTS`。
- **某仓库一直显示「已分叉」**：这是本地与远端各有新提交，需要手动 merge/rebase，工具不会碰它。
- **token 泄露了怎么办**：去对应平台重置，然后改 `notify.conf` 一个文件即可。

## 更新

本仓库只放工具本体，不含任何个人配置与密钥。改完推上来后，其他机器上：

```bash
cd ~/Documents/github/gsync-kit && git pull   # 若该目录已在 gsync 的 ROOTS 里，会自动快进
bash gsync install                            # 覆盖引擎与界面，保留现有配置
gsync reload
```
