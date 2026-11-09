# 更新记录

## v1.1.0 — 2026-11-09

仓库结构重构：方案本体收进 `gsync/` 子目录，根目录只留索引 README。

- 全部文件（`gsync`、`git-sync.sh`、`ui/`、`report-template.html`、两个样例配置、
  CHANGELOG）用 `git mv` 平移，历史可追溯，可执行位 `100755` 保留；
- 安装命令由 `bash gsync install` 变为 `bash gsync/gsync install`；
- `gsync` 用 `SRC_DIR` 按自身位置解析同目录的引擎、界面、模板，因此整目录拷贝
  到任意机器仍可安装，不依赖仓库根路径；
- 根目录新增索引 README（方案表格 + 结构树 + 约定），原详细文档移到
  `gsync/README.md`，内部路径引用同步更新。

代码零改动，已安装的机器无需升级引擎，仅后续 `git pull` 后安装路径改变。

## v1.0.1 — 2026-11-09

修复：脏文件过多时整轮同步被静默中止。

- `dirty` 分支原来用 `awk | head -3 | paste` 取前三个文件名。`head` 读三行即退出，
  上游 `awk` 收到 SIGPIPE，而管道首端的 `printf` 是 shell **内建**，SIGPIPE 会直接
  杀掉整个脚本。表现是：仓库有两千个以上改动文件时不写报告、不写汇总、不发通知，
  但退出码只是 1，看起来像「跑完了」。改为单条 awk 在 `n<=3` 时打印，读完全部输入。
- `emit` 中统一剥离 ANSI 转义，`fetch` 增加 `-c color.ui=never`，
  HTML 报告与邮件正文不再出现 `[31m` 之类的乱码。

文档：

- README 增加「接到 WorkBuddy」整节（launchd 同步 → 报告 → automation 只读 → Agent Mail），
  含可直接复制的 prompt 模板、错峰 2 分钟的原因、配额与手机推送注意事项；
- README 增加「已验证场景」，记录 17 个仓库的真实运行结果；
- `config.conf.example` 补充多目录（外接盘 + 家目录）示例与磁盘未挂载的提示。

## v1.0.0 — 2026-11-09

首个可用版本。

- `git-sync.sh`：ff-only 安全快进引擎。仅当「落后远端 + 无本地未推送提交 +
  已跟踪文件无改动」三条件同时成立才快进；合并中、分叉、脏工作区、游离 HEAD、
  index.lock 残留一律跳过并记录。含进程锁、解锁检测、日志轮转、HTML 报告。
- `gsync`：install / reload / run / status / config / ui / doctor / log / uninstall，
  安装时写入 `~/.zshenv`（而非 `.zshrc`，否则非交互 shell 读不到）。
- `ui/`：仅监听 127.0.0.1 的可视化配置界面，端口占用自动顺延。
- 推送：PushPlus（微信）/ 企业微信机器人 / Bark（iOS）三选一，默认仅状态变化时推送。
- 不含任何 token、webhook 与个人配置。
