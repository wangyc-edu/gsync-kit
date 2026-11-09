# gsync-kit

macOS 自用工具集，按方案分目录存放。每个目录是一套能独立安装、独立卸载的完整方案，
不含任何个人配置与密钥。

| 目录 | 方案 | 说明 | 版本 |
|---|---|---|---|
| [`gsync/`](gsync/README.md) | 多仓库定时同步 | Git 仓库定点自动快进 + 解锁补跑 + 手机推送 + HTML 邮件报告 | v1.0.1 |

## 安装 gsync

```bash
git clone https://github.com/wangyc-edu/gsync-kit.git
cd gsync-kit
bash gsync/gsync install      # 交互式，一路回车用默认值
```

装完**新开一个终端窗口**（让 PATH 生效），然后：

```bash
gsync reload                  # 把定时任务交给系统 launchd
```

> `gsync reload` 必须在 macOS 自带的「终端」App 里执行。IDE / 编辑器 / WorkBuddy
> 的内置终端受系统沙箱限制，写 launchd 会报 `Bootstrap failed: 5: Input/output error`。

前置依赖：`git`、`jq`（`brew install jq`），`python3` 可选（缺了报告降级为纯文本）。

详细用法、配置项、邮件接线、常见问题见 [`gsync/README.md`](gsync/README.md)；
版本变更见 [`gsync/CHANGELOG.md`](gsync/CHANGELOG.md)。

## 仓库结构

```
gsync-kit/
├── README.md            本文件：仓库索引
├── .gitignore           忽略本地配置、密钥、日志
└── gsync/               方案一：多仓库安全同步
    ├── gsync            CLI 入口
    ├── git-sync.sh      同步引擎
    ├── ui/              可视化配置界面（python3 标准库）
    ├── report-template.html
    ├── config.conf.example
    ├── notify.conf.example
    ├── README.md        方案详细文档
    └── CHANGELOG.md
```

## 约定

- **配置与密钥不入库**：`config.conf`、`notify.conf`、`state.json`、`*.log` 已在
  `.gitignore` 中屏蔽，样例文件只留占位名。
- **方案自带安装器**：拷走任意方案目录即可安装，脚本按自身位置解析同目录资源，
  不依赖仓库根路径。
- **改完在目标机更新**：`git pull && bash gsync/gsync install && gsync reload`。

## 版本

打标签归档，当前 `v1.1.0`（目录重构）。历史版本：`v1.0.1` 修复大脏工作区导致同步中止，
`v1.0.0` 首个可用版本。
