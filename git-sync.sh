#!/bin/bash
# git-sync.sh - 多仓库安全同步引擎
#
# 安全策略：只有当 behind>0 且 ahead==0 且 已跟踪文件无改动 时，才执行 ff-only 快进。
# 任何异常状态一律跳过并记录，绝不留下 merge/rebase 冲突现场。
#
# 用法：
#   ./git-sync.sh              正常执行
#   ./git-sync.sh -n           预演，只报告不修改
#   ./git-sync.sh -v           同时输出到终端
#   ./git-sync.sh -u           解锁检查模式：屏幕已解锁且距上次同步超过冷却时间才执行
#
# 配置：~/.config/git-sync/config.conf（不存在则用默认值）
#   ROOTS                 仓库目录，多个用逗号分隔（父目录或仓库本身均可）
#   TIMES                 每天同步时间，如 08:50,13:50（仅用于报告文案）
#   SYNC_ON_UNLOCK        1=启用解锁触发
#   UNLOCK_MIN_INTERVAL   两次解锁触发的最小间隔（分钟）
#   SCAN_DEPTH            向下查找 .git 的层级，默认 2
#   PROVIDER_NAME         报告里的产品名，默认 GitLab
#
# 环境变量覆盖：GIT_SYNC_ROOTS / GIT_SYNC_STATE_DIR / GIT_SYNC_CONF_DIR
#               GSYNC_DRY_RUN=1 等价于 -n

set -uo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/usr/bin/true
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="${GSYNC_CONF_DIR:-$HOME/.config/git-sync}"
CONFIG_FILE="$CONF_DIR/config.conf"
STATE_DIR="${GIT_SYNC_STATE_DIR:-$HOME/.local/state/git-sync}"
LOG_FILE="$STATE_DIR/sync.log"
STATE_FILE="$STATE_DIR/state.json"
PREV_SIG_FILE="$STATE_DIR/.last-sig"
REPORT_FILE="$STATE_DIR/last-report.txt"
JSONL="$STATE_DIR/.repos.jsonl"
LAST_RUN_FILE="$STATE_DIR/.last-run"
LOCK_DIR="$STATE_DIR/.lock"

# 先读用户配置，再读推送配置（推送里的 DEVICE_NAME 优先）
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE" 2>/dev/null
NOTIFY_CONF="$CONF_DIR/notify.conf"
[ -f "$NOTIFY_CONF" ] && . "$NOTIFY_CONF" 2>/dev/null

ROOTS_SPEC="${GIT_SYNC_ROOTS:-${GIT_SYNC_ROOT:-${ROOTS:-$HOME/Documents/gitlab}}}"
SCAN_DEPTH="${GIT_SYNC_SCAN_DEPTH:-${SCAN_DEPTH:-2}}"
PROVIDER_NAME="${PROVIDER_NAME:-GitLab}"
TIMES="${TIMES:-}"
SYNC_ON_UNLOCK="${SYNC_ON_UNLOCK:-0}"
UNLOCK_MIN_INTERVAL="${UNLOCK_MIN_INTERVAL:-60}"
DEVICE_NAME="${DEVICE_NAME:-$(scutil --get ComputerName 2>/dev/null || hostname -s 2>/dev/null || echo "Mac")}"

DRY_RUN=0
VERBOSE=0
UNLOCK_CHECK=0

while getopts "nvuh" opt; do
  case $opt in
    n) DRY_RUN=1 ;;
    v) VERBOSE=1 ;;
    u) UNLOCK_CHECK=1 ;;
    *) sed -n '2,22p' "$0"; exit 0 ;;
  esac
done
[ "${GSYNC_DRY_RUN:-0}" = "1" ] && DRY_RUN=1

mkdir -p "$STATE_DIR"
: > "$JSONL"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"; }
say() { [ "$VERBOSE" -eq 1 ] && printf '%s\n' "$*"; return 0; }

# 日志轮转：超过 1MB 只保留最后 2000 行
if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE" | tr -d ' ')" -gt 1048576 ]; then
  tail -n 2000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
fi

# ---------- 路径展开 ----------
expand_path() {
  local p="$1"
  p="${p#"${p%%[![:space:]]*}"}"
  p="${p%"${p##*[![:space:]]}"}"
  p="${p%/}"
  case "$p" in
    "~")    printf '%s' "$HOME" ;;
    "~/"*)  printf '%s' "$HOME/${p#\~/}" ;;
    *)      printf '%s' "$p" ;;
  esac
}

# ---------- 屏幕锁定判定 ----------
# macOS 在锁屏时会在 IOConsoleUsers 里出现 CGSSessionScreenIsLocked 键，解锁后键消失。
# 键出现与否即可判断，不需要任何第三方依赖。
screen_locked() {
  local dump
  dump=$(ioreg -n Root -d1 -a 2>/dev/null | plutil -extract IOConsoleUsers xml1 -o - - 2>/dev/null | plutil -p - 2>/dev/null)
  if [ -n "$dump" ]; then
    printf '%s' "$dump" | grep -q 'CGSSessionScreenIsLocked => 1' && return 0
    printf '%s' "$dump" | grep -q '"CGSSessionScreenIsLocked"' && return 0
    return 1
  fi
  # 兜底：拿不到 CGS 信息时看用户是否活跃（0 视为不可用，宁可不跑）
  pmset -g assertions 2>/dev/null | grep -q 'UserIsActive *1' && return 1
  return 0
}

# ---------- 解锁触发模式 ----------
if [ "$UNLOCK_CHECK" -eq 1 ]; then
  if [ "$SYNC_ON_UNLOCK" != "1" ]; then
    exit 0
  fi
  if screen_locked; then
    log "UNLOCK skip: 屏幕仍锁定"
    exit 0
  fi
  now_ts=$(date +%s)
  last_ts=$(cat "$LAST_RUN_FILE" 2>/dev/null || printf '0')
  gap_min=$(( (now_ts - last_ts) / 60 ))
  if [ "$gap_min" -lt "$UNLOCK_MIN_INTERVAL" ]; then
    exit 0
  fi
  log "UNLOCK trigger: 距上次同步 ${gap_min} 分钟，开始执行"
  [ "$VERBOSE" -eq 1 ] && printf '解锁触发：距上次 %s 分钟，开始同步\n' "$gap_min"
fi

# ---------- 并发锁 ----------
acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s' "$$" > "$LOCK_DIR/pid"
    trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM
    return 0
  fi
  local holder
  holder=$(cat "$LOCK_DIR/pid" 2>/dev/null || printf '')
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    return 1
  fi
  # 持锁进程已不存在（被强杀或重启），清理后重试一次
  rm -rf "$LOCK_DIR" 2>/dev/null
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s' "$$" > "$LOCK_DIR/pid"
    trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM
    return 0
  fi
  return 1
}

if ! acquire_lock; then
  log "SKIP: 已有同步任务在运行，本次退出"
  [ "$VERBOSE" -eq 1 ] && printf '已有同步任务在运行，本次跳过\n'
  exit 0
fi

[ "$DRY_RUN" -eq 0 ] && date +%s > "$LAST_RUN_FILE"

# ---------- 解析仓库根目录 ----------
ROOTS_ARR=()
IFS=',' read -ra _raw_roots <<< "$ROOTS_SPEC"
for _r in ${_raw_roots[@]+"${_raw_roots[@]}"}; do
  _r="$(expand_path "$_r")"
  [ -n "$_r" ] && ROOTS_ARR+=("$_r")
done

READABLE_ROOTS=()
for _r in "${ROOTS_ARR[@]}"; do
  if [ -d "$_r" ] && ls "$_r" > /dev/null 2>&1; then
    READABLE_ROOTS+=("$_r")
  else
    log "WARN: 跳过不可读的根目录 $_r"
  fi
done

if [ "${#READABLE_ROOTS[@]}" -eq 0 ]; then
  roots_str=$(printf '%s, ' "${ROOTS_ARR[@]}"); roots_str="${roots_str%, }"
  log "FATAL: 没有任何可读的仓库根目录（${roots_str}）"
  jq -n --arg ts "$(date '+%Y-%m-%dT%H:%M:%S%z')" --arg root "$roots_str" --arg dev "$DEVICE_NAME" \
    --arg pn "$PROVIDER_NAME" \
    '{timestamp:$ts, root:$root, roots:[], device:$dev, provider:$pn, changed:true, fatal:"tcc-denied",
      message:"无法读取仓库根目录：目录不存在，或被 macOS 隐私保护拦截",
      repos:[], summary:{total:0,updated:0,uptodate:0,skipped:0,error:0}}' > "$STATE_FILE"
  printf '%s 同步失败\n无法读取：%s\n可能原因：目录不存在，或未授予「完全磁盘访问权限」\n' \
    "$PROVIDER_NAME" "$roots_str" > "$REPORT_FILE"
  [ "$VERBOSE" -eq 1 ] && printf 'FATAL: 没有任何可读的根目录（%s）\n' "$roots_str"
  exit 2
fi

# ---------- 收集仓库 ----------
list_repos() {
  local r
  for r in "${READABLE_ROOTS[@]}"; do
    if [ -d "$r/.git" ]; then
      printf '%s\n' "$r"                       # 直接指向某个仓库
    else
      find "$r" -maxdepth "$SCAN_DEPTH" -type d -name .git 2>/dev/null | sed 's|/\.git$||'
    fi
  done
  # 手工补充的仓库清单（每行一个路径，# 开头为注释）
  if [ -f "$CONF_DIR/repos.txt" ]; then
    grep -vE '^[[:space:]]*(#|$)' "$CONF_DIR/repos.txt" 2>/dev/null | sed "s|^~|$HOME|"
  fi
}

# ---------- 写入单条结果 ----------
TOTAL=0; N_UPDATED=0; N_UPTODATE=0; N_SKIPPED=0; N_ERROR=0
BLOCKERS=""

emit() {
  local name="$1" path="$2" branch="$3" status="$4" ahead="$5" behind="$6" dirty="$7" detail="$8"
  local note=""

  jq -nc \
    --arg n "$name" --arg p "$path" --arg b "$branch" --arg s "$status" \
    --argjson a "${ahead:-0}" --argjson h "${behind:-0}" --argjson d "${dirty:-0}" \
    --arg t "$detail" \
    '{name:$n, path:$p, branch:$b, status:$s, ahead:$a, behind:$h, dirty:$d, detail:$t}' >> "$JSONL"

  case "$status" in
    updated|would-update) N_UPDATED=$((N_UPDATED+1)) ;;
    uptodate)             N_UPTODATE=$((N_UPTODATE+1)) ;;
    error)                N_ERROR=$((N_ERROR+1)); note="! " ;;
    *)                    N_SKIPPED=$((N_SKIPPED+1)); note="· " ;;
  esac

  case "$status" in
    busy|conflict|diverged|error|detached|locked|blocked-untracked|ahead|noupstream)
      BLOCKERS="${BLOCKERS}${note}${name} [${branch:-无分支}] ${detail}"$'\n' ;;
  esac

  say "$(printf '%-20s %-16s %-22s %s' "$name" "${branch:--}" "$status" "$detail")"
  log "$name | ${branch:--} | $status | $detail"
}

# ---------- 主循环 ----------
while IFS= read -r repo; do
  [ -n "$repo" ] || continue
  [ -d "$repo/.git" ] || continue

  TOTAL=$((TOTAL+1))
  name="$(basename "$repo")"

  # 1. index.lock 残留（上次 git 被强杀）
  if [ -e "$repo/.git/index.lock" ]; then
    emit "$name" "$repo" "" "locked" 0 0 0 "存在 index.lock，可能有 git 进程残留"
    continue
  fi

  # 2. 进行中的 multi-step 操作
  busy=""
  [ -f "$repo/.git/MERGE_HEAD" ]       && busy="merge"
  [ -d "$repo/.git/rebase-merge" ]     && busy="rebase"
  [ -d "$repo/.git/rebase-apply" ]     && busy="rebase/am"
  [ -f "$repo/.git/CHERRY_PICK_HEAD" ] && busy="cherry-pick"
  [ -f "$repo/.git/REVERT_HEAD" ]      && busy="revert"
  if [ -n "$busy" ]; then
    emit "$name" "$repo" "" "busy" 0 0 0 "正在进行 ${busy}，需人工处理"
    continue
  fi

  # 3. 未合并路径（兜底）
  unmerged=$(git -C "$repo" diff --name-only --diff-filter=U 2>/dev/null)
  if [ -n "$unmerged" ]; then
    cnt=$(printf '%s\n' "$unmerged" | wc -l | tr -d ' ')
    emit "$name" "$repo" "" "conflict" 0 0 0 "存在 $cnt 个未合并文件"
    continue
  fi

  # 4. 分支与上游
  branch=$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null)
  if [ -z "$branch" ]; then
    emit "$name" "$repo" "" "detached" 0 0 0 "HEAD 处于游离状态，跳过以免丢失提交"
    continue
  fi

  upstream=$(git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)
  if [ -z "$upstream" ]; then
    emit "$name" "$repo" "$branch" "noupstream" 0 0 0 "该分支未设置上游，无法判断该拉什么"
    continue
  fi

  # 5. fetch（只读，不改工作区）
  fetch_err=$(git -C "$repo" -c http.lowSpeedLimit=2000 -c http.lowSpeedTime=25 \
              fetch --prune --quiet 2>&1)
  if [ $? -ne 0 ]; then
    short=$(printf '%s' "$fetch_err" | head -1 | cut -c1-90)
    emit "$name" "$repo" "$branch" "error" 0 0 0 "fetch 失败：$short"
    continue
  fi

  # 6. 计算领先/落后
  ab=$(git -C "$repo" rev-list --left-right --count '@{u}...HEAD' 2>/dev/null)
  behind=$(printf '%s' "$ab" | awk '{print $1+0}')
  ahead=$(printf '%s' "$ab" | awk '{print $2+0}')
  : "${behind:=0}"
  : "${ahead:=0}"

  # 7. 工作区状态（一次采集，分开统计）
  st=$(git -C "$repo" status --porcelain 2>/dev/null)
  tracked_dirty=$(printf '%s\n' "$st" | awk 'NF && $0 !~ /^\?\?/ {n++} END{print n+0}')
  untracked=$(printf '%s\n' "$st" | awk '/^\?\?/ {n++} END{print n+0}')

  # 8. 判定
  if [ "$behind" -eq 0 ] && [ "$ahead" -eq 0 ]; then
    msg="已是最新"
    [ "$tracked_dirty" -gt 0 ] && msg="已是最新（本地 ${tracked_dirty} 个文件有改动）"
    [ "$untracked" -gt 0 ] && msg="${msg}（${untracked} 个未跟踪文件）"
    emit "$name" "$repo" "$branch" "uptodate" "$ahead" "$behind" "$tracked_dirty" "$msg"
    continue
  fi

  if [ "$ahead" -gt 0 ] && [ "$behind" -gt 0 ]; then
    emit "$name" "$repo" "$branch" "diverged" "$ahead" "$behind" "$tracked_dirty" \
      "已分叉：领先 ${ahead} / 落后 ${behind}，需手动 merge 或 rebase"
    continue
  fi

  if [ "$ahead" -gt 0 ]; then
    emit "$name" "$repo" "$branch" "ahead" "$ahead" "$behind" "$tracked_dirty" \
      "$ahead 个提交未推送，其他设备拿不到"
    continue
  fi

  if [ "$tracked_dirty" -gt 0 ]; then
    files=$(printf '%s\n' "$st" | awk 'NF && $0 !~ /^\?\?/ {print $2}' | head -3 | paste -sd ', ' -)
    emit "$name" "$repo" "$branch" "dirty" "$ahead" "$behind" "$tracked_dirty" \
      "落后 ${behind}，但 ${tracked_dirty} 个文件已改动（${files}）"
    continue
  fi

  # 到这一步：behind>0 && ahead==0 && 已跟踪文件干净 → 可以安全快进
  if [ "$DRY_RUN" -eq 1 ]; then
    emit "$name" "$repo" "$branch" "would-update" "$ahead" "$behind" 0 \
      "落后 $behind 个提交，预演模式未执行"
    continue
  fi

  ff_err=$(git -C "$repo" merge --ff-only '@{u}' 2>&1)
  if [ $? -eq 0 ]; then
    emit "$name" "$repo" "$branch" "updated" "$ahead" "$behind" 0 "已快进 $behind 个提交"
  else
    if printf '%s' "$ff_err" | grep -qi 'untracked working tree'; then
      emit "$name" "$repo" "$branch" "blocked-untracked" "$ahead" "$behind" 0 \
        "远端新增文件与本地未跟踪文件同名，已放弃快进"
    else
      short=$(printf '%s' "$ff_err" | head -1 | cut -c1-90)
      emit "$name" "$repo" "$branch" "error" "$ahead" "$behind" 0 "快进失败：$short"
    fi
  fi
done < <(list_repos | awk '!seen[$0]++')

# ---------- 汇总 ----------
repos_json=$(jq -s '.' "$JSONL" 2>/dev/null)
[ -z "$repos_json" ] && repos_json="[]"

sig=$(printf '%s' "$repos_json" | jq -r '.[] | "\(.name)=\(.status)"' 2>/dev/null | sort | md5 -q)
prev_sig=$(cat "$PREV_SIG_FILE" 2>/dev/null || printf '')
changed=false
[ "$sig" != "$prev_sig" ] && changed=true

roots_json=$(jq -nc '$ARGS.positional' --args "${READABLE_ROOTS[@]}")
roots_display=$(printf '%s、' "${READABLE_ROOTS[@]}"); roots_display="${roots_display%、}"

jq -n \
  --arg ts "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
  --arg root "$roots_display" \
  --argjson roots "$roots_json" \
  --arg dev "$DEVICE_NAME" \
  --arg pn "$PROVIDER_NAME" \
  --argjson dry "$([ "$DRY_RUN" -eq 1 ] && printf true || printf false)" \
  --argjson changed "$([ "$changed" = true ] && printf true || printf false)" \
  --argjson repos "$repos_json" \
  '{timestamp:$ts, root:$root, roots:$roots, device:$dev, provider:$pn,
    dry_run:$dry, changed:$changed, repos:$repos,
    summary:{
      total:($repos|length),
      updated:([$repos[]|select(.status=="updated")]|length),
      would_update:([$repos[]|select(.status=="would-update")]|length),
      uptodate:([$repos[]|select(.status=="uptodate")]|length),
      skipped:([$repos[]|select(.status|IN("busy","conflict","diverged","dirty","ahead","detached","noupstream","locked","blocked-untracked"))]|length),
      error:([$repos[]|select(.status=="error")]|length)
    }}' > "$STATE_FILE"

printf '%s' "$sig" > "$PREV_SIG_FILE"

if [ "$changed" = true ]; then
  touch "$STATE_DIR/.need-notify"
fi

# ---------- 人类可读报告 ----------
{
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s 同步预演  %s  (%s)\n' "$PROVIDER_NAME" "$(date '+%Y-%m-%d %H:%M')" "$DEVICE_NAME"
  else
    printf '%s 同步报告  %s  (%s)\n' "$PROVIDER_NAME" "$(date '+%Y-%m-%d %H:%M')" "$DEVICE_NAME"
  fi
  printf '%s\n' "----------------------------------------"
  printf '扫描目录：%s\n' "$roots_display"
  jq -r '.summary | "共 \(.total) 个仓库：已更新 \(.updated)｜已最新 \(.uptodate)｜跳过 \(.skipped)｜异常 \(.error)"' "$STATE_FILE"
  printf '%s\n' "----------------------------------------"
  jq -r '.repos[] | select(.status|IN("updated","would-update")) | "  [更新] \(.name)  \(.detail)"' "$STATE_FILE"
  if [ -n "$BLOCKERS" ]; then
    printf '%s\n' "需要你处理："
    printf '%s' "$BLOCKERS"
  fi
  printf '%s\n' "其余仓库状态正常或无变化。"
} > "$REPORT_FILE"

# ---------- HTML 报告（模板渲染，供邮件正文使用） ----------
REPORT_HTML="$STATE_DIR/last-report.html"
ROWS_FILE="$STATE_DIR/.rows.html"
REPORT_TPL=""
for t in "$CONF_DIR/report-template.html" "$SCRIPT_DIR/report-template.html"; do
  [ -f "$t" ] && { REPORT_TPL="$t"; break; }
done

jq -r '
  def esc: gsub("&";"&amp;") | gsub("<";"&lt;") | gsub(">";"&gt;");
  def st_label: {updated:"已更新","would-update":"可更新",uptodate:"已最新",ahead:"待推送",
              dirty:"有改动",diverged:"已分叉",conflict:"冲突中",busy:"处理中",
              detached:"游离 HEAD",locked:"锁残留","blocked-untracked":"未跟踪冲突",
              noupstream:"无上游",error:"异常"}[.] // .;
  def st_color: {updated:"#0969da","would-update":"#0969da",uptodate:"#57606a",ahead:"#bc4c00",
              dirty:"#bc4c00",diverged:"#cf222e",conflict:"#cf222e",busy:"#cf222e",
              detached:"#cf222e",locked:"#cf222e","blocked-untracked":"#cf222e",
              noupstream:"#57606a",error:"#cf222e"}[.] // "#57606a";
  def st_rank: {error:0,conflict:1,busy:1,diverged:1,locked:1,"blocked-untracked":1,
             detached:2,ahead:3,dirty:3,updated:4,"would-update":4,uptodate:5,noupstream:6}[.] // 7;
  .repos
  | sort_by(.status | st_rank)
  | .[]
  | "      <tr>"
    + "<td style=\"border:1px solid #d0d7de;padding:8px 10px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px\">" + (.name | esc) + "</td>"
    + "<td style=\"border:1px solid #d0d7de;padding:8px 10px;color:#57606a\">" + (if .branch == "" or .branch == null then "—" else (.branch | esc) end) + "</td>"
    + "<td style=\"border:1px solid #d0d7de;padding:8px 10px;white-space:nowrap;font-weight:600;color:" + (.status | st_color) + "\">" + (.status | st_label) + "</td>"
    + "<td style=\"border:1px solid #d0d7de;padding:8px 10px;color:#57606a\">" + (.detail | esc) + "</td>"
    + "</tr>"
' "$STATE_FILE" > "$ROWS_FILE" 2>/dev/null

BLOCKERS_HTML=""
if [ -n "$BLOCKERS" ]; then
  BLK=$(printf '%s' "$BLOCKERS" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' | awk 'NR>1{printf "<br>"} {printf "%s", $0}')
  BLOCKERS_HTML="  <p style=\"margin:14px 0 0;padding:10px 12px;background:#fff8c5;border-left:3px solid #d4a72c;font-size:13px\"><strong>需要你处理</strong><br>$BLK</p>"
fi

if [ -n "$REPORT_TPL" ] && command -v python3 > /dev/null 2>&1; then
  RPT_TITLE="$DEVICE_NAME · ${PROVIDER_NAME} 同步$([ "$DRY_RUN" -eq 1 ] && printf '预演' || printf '报告')"
  RPT_TIME="$(date '+%Y-%m-%d %H:%M')"
  if [ -n "$TIMES" ]; then
    RPT_FOOTER="本邮件由 $DEVICE_NAME 的 ${PROVIDER_NAME} 同步任务自动发送，每天 $(printf '%s' "$TIMES" | tr ',' '、') 各一次"
    [ "$SYNC_ON_UNLOCK" = "1" ] && RPT_FOOTER="${RPT_FOOTER}，解锁屏幕后也会自动同步"
    RPT_FOOTER="${RPT_FOOTER}。"
  else
    RPT_FOOTER="本邮件由 $DEVICE_NAME 的 ${PROVIDER_NAME} 同步任务自动发送（未启用定时，由手动触发）。"
  fi
  RPT_N_TOTAL=$(jq -r '.summary.total' "$STATE_FILE")
  RPT_N_UPDATED=$(jq -r '.summary | (.updated + .would_update)' "$STATE_FILE")
  RPT_N_UPTODATE=$(jq -r '.summary.uptodate' "$STATE_FILE")
  RPT_N_SKIPPED=$(jq -r '.summary.skipped' "$STATE_FILE")
  RPT_N_ERROR=$(jq -r '.summary.error' "$STATE_FILE")

  python3 - "$REPORT_TPL" "$REPORT_HTML" "$ROWS_FILE" "$BLOCKERS_HTML" \
           "$RPT_TITLE" "$RPT_TIME" "$RPT_FOOTER" \
           "$RPT_N_TOTAL" "$RPT_N_UPDATED" "$RPT_N_UPTODATE" "$RPT_N_SKIPPED" "$RPT_N_ERROR" \
           > /dev/null 2>&1 <<'PY'
import sys, io, re
(tpl_p, out_p, rows_p, blockers, title, ts, footer,
 n_total, n_updated, n_uptodate, n_skipped, n_error) = sys.argv[1:13]

tpl = io.open(tpl_p, encoding='utf-8').read()
tpl = re.sub(r'<!--.*?-->', '', tpl, flags=re.S).strip()
rows = io.open(rows_p, encoding='utf-8').read().rstrip('\n') if rows_p else ''

pairs = [
    ('{{TITLE}}', title),
    ('{{TIME}}', ts),
    ('{{ROWS}}', rows),
    ('{{BLOCKERS}}', blockers),
    ('{{FOOTER}}', footer),
    ('{{N_TOTAL}}', n_total),
    ('{{N_UPDATED}}', n_updated),
    ('{{N_UPTODATE}}', n_uptodate),
    ('{{N_SKIPPED}}', n_skipped),
    ('{{N_ERROR}}', n_error),
]
for k, v in pairs:
    tpl = tpl.replace(k, v)

io.open(out_p, 'w', encoding='utf-8').write(tpl)
PY

  if [ -s "$REPORT_HTML" ] && grep -q '{{' "$REPORT_HTML"; then
    log "WARN: HTML 报告仍有未替换占位符，请检查模板 $REPORT_TPL"
  fi
else
  log "WARN: 未找到 report-template.html 或 python3，HTML 报告降级为纯文本"
  {
    printf '<pre style="font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px;color:#1f2328;line-height:1.6">'
    cat "$REPORT_FILE"
    printf '</pre>'
  } > "$REPORT_HTML"
fi
rm -f "$ROWS_FILE"

# ---------- 推送通知 ----------
NOTIFY_TYPE="${NOTIFY_TYPE:-}"
notify_ready=0
case "$NOTIFY_TYPE" in
  wecom)    [ -n "${WECOM_WEBHOOK:-}" ] && notify_ready=1 ;;
  pushplus) [ -n "${PUSHPLUS_TOKEN:-}" ] && notify_ready=1 ;;
  bark)     [ -n "${BARK_KEY:-}" ] && notify_ready=1 ;;
esac

send_push() {
  local title="$1" body="$2" resp="" payload="" md=""
  case "$NOTIFY_TYPE" in
    wecom)
      md=$(printf '### %s\n%s' "$title" "$(printf '%s' "$body" | sed 's/^/> /')")
      payload=$(jq -nc --arg c "$md" '{msgtype:"markdown",markdown:{content:$c}}')
      resp=$(curl -s -m 20 -X POST "$WECOM_WEBHOOK" -H 'Content-Type: application/json' \
             -d "$payload" 2>/dev/null)
      printf '%s' "$resp" | jq -e '.errcode == 0' > /dev/null 2>&1 && return 0
      ;;
    pushplus)
      payload=$(jq -nc --arg t "$PUSHPLUS_TOKEN" --arg ti "$title" --arg c "$body" \
        '{token:$t, title:$ti, content:$c, template:"txt"}')
      resp=$(curl -s -m 20 -X POST "${PUSHPLUS_API:-https://www.pushplus.plus/send}" \
             -H 'Content-Type: application/json' -d "$payload" 2>/dev/null)
      printf '%s' "$resp" | jq -e '.code == 200' > /dev/null 2>&1 && return 0
      ;;
    bark)
      payload=$(jq -nc --arg k "$BARK_KEY" --arg t "$title" --arg b "$body" \
        '{device_key:$k, title:$t, body:$b, group:"gsync"}')
      resp=$(curl -s -m 20 -X POST "${BARK_SERVER:-https://api.day.app}/push" \
             -H 'Content-Type: application/json' -d "$payload" 2>/dev/null)
      printf '%s' "$resp" | jq -e '.code == 200' > /dev/null 2>&1 && return 0
      ;;
    *) return 1 ;;
  esac
  log "NOTIFY resp($NOTIFY_TYPE): $(printf '%s' "$resp" | head -c 200)"
  return 1
}

if [ "$DRY_RUN" -eq 0 ] && [ "$notify_ready" -eq 1 ]; then
  now_ts=$(date +%s)
  last_push_ts=$(cat "$STATE_DIR/.last-push" 2>/dev/null)
  last_push_ts=${last_push_ts:-0}
  gap_days=$(( (now_ts - last_push_ts) / 86400 ))

  if [ "${PUSH_ALWAYS:-0}" = "1" ] || [ "$changed" = true ] || [ "$gap_days" -ge 3 ]; then
    if [ "$N_UPDATED" -gt 0 ]; then
      push_title="${PROVIDER_NAME} 已更新 ${N_UPDATED} 个仓库"
    elif [ "$N_ERROR" -gt 0 ]; then
      push_title="${PROVIDER_NAME} 同步出错"
    elif [ -n "$BLOCKERS" ]; then
      push_title="${PROVIDER_NAME} 有仓库待处理"
    else
      push_title="${PROVIDER_NAME} 同步正常"
    fi
    push_title="${DEVICE_NAME} · ${push_title}"

    push_body=$(jq -r '
      (.summary | "共\(.total)个 · 更新\(.updated) 最新\(.uptodate) 跳过\(.skipped) 异常\(.error)"),
      (.repos[] | select(.status=="updated") | "已更新 " + .name + "（" + .detail + "）"),
      (.repos[] | select(.status|IN("conflict","diverged","ahead","busy","detached","error","blocked-untracked","locked")) | "待处理 " + .name + "：" + .detail)
    ' "$STATE_FILE" 2>/dev/null | head -8)

    if send_push "$push_title" "$push_body"; then
      printf '%s' "$now_ts" > "$STATE_DIR/.last-push"
      log "NOTIFY sent($NOTIFY_TYPE): $push_title"
      rm -f "$STATE_DIR/.need-notify"
    else
      log "NOTIFY failed($NOTIFY_TYPE): $push_title"
    fi
  fi
elif [ "$DRY_RUN" -eq 1 ] && [ "$notify_ready" -eq 1 ]; then
  say "(预演模式，跳过推送)"
elif [ "$DRY_RUN" -eq 0 ]; then
  log "NOTIFY skipped: 未配置推送通道"
fi

log "SUMMARY total=$TOTAL updated=$N_UPDATED uptodate=$N_UPTODATE skipped=$N_SKIPPED error=$N_ERROR changed=$changed"
[ "$VERBOSE" -eq 1 ] && printf '\n完成：更新 %s，最新 %s，跳过 %s，异常 %s（changed=%s）\n' \
  "$N_UPDATED" "$N_UPTODATE" "$N_SKIPPED" "$N_ERROR" "$changed"

[ "$N_ERROR" -gt 0 ] && exit 1
exit 0
