#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gsync 本地配置界面后端

只监听 127.0.0.1，不对外暴露。仅依赖 Python 3 标准库。
"""

import argparse
import json
import os
import re
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

KEYS = ["ROOTS", "TIMES", "SYNC_ON_UNLOCK", "UNLOCK_MIN_INTERVAL", "SCAN_DEPTH", "PROVIDER_NAME"]

STATE = {
    "home": os.path.expanduser("~"),
    "conf_dir": None,
    "state_dir": None,
    "bin_dir": None,
}

busy = {"run": False}
lock = threading.Lock()


# ---------------------------------------------------------------- 配置读写
def paths():
    home = STATE["home"]
    return {
        "conf_dir": STATE["conf_dir"] or os.path.join(home, ".config", "git-sync"),
        "state_dir": STATE["state_dir"] or os.path.join(home, ".local", "state", "git-sync"),
        "bin_dir": STATE["bin_dir"] or os.path.join(home, "bin", "git-sync"),
    }


def config_file():
    return os.path.join(paths()["conf_dir"], "config.conf")


def read_config():
    data = {}
    path = config_file()
    if os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k, v = k.strip(), v.strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                    v = v[1:-1]
                data[k] = v
    return data


def write_config(values):
    path = config_file()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    lines = []
    if os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().split("\n")
    seen = set()
    out = []
    for line in lines:
        m = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=", line)
        if m and m.group(1) in values:
            k = m.group(1)
            out.append('%s="%s"' % (k, values[k]))
            seen.add(k)
        else:
            out.append(line)
    for k in KEYS:
        if k in values and k not in seen:
            out.append('%s="%s"' % (k, values[k]))
    text = "\n".join(out).rstrip("\n") + "\n"
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)
    os.chmod(path, 0o644)


def expand(value, home=None):
    home = home or STATE["home"]
    p = (value or "").strip()
    if p == "~":
        return home
    if p.startswith("~/"):
        return os.path.join(home, p[2:])
    return p.replace("$HOME", home).replace("${HOME}", home)


def split_roots(raw):
    return [r.strip() for r in (raw or "").split(",") if r.strip()]


def shorten_home(value):
    """把家目录前缀换成 $HOME，便于配置在别的 Mac 上复用。"""
    home = STATE["home"].rstrip("/")
    out = []
    for part in split_roots(value):
        if part == home:
            part = "$HOME"
        elif part.startswith(home + "/"):
            part = "$HOME" + part[len(home):]
        out.append(part)
    return ",".join(out)


def count_repos(path, depth):
    n = 0
    base = path.rstrip("/")
    for root, dirs, files in os.walk(base):
        rel = os.path.relpath(root, base)
        level = 0 if rel == "." else rel.count(os.sep) + 1
        if level >= depth:
            dirs[:] = []
        if ".git" in dirs or ".git" in files:
            n += 1
            dirs[:] = [d for d in dirs if d != ".git"]
        dirs[:] = [d for d in dirs if not d.startswith(".") and d != "node_modules"]
    return n


def validate(cfg):
    errs = []
    roots = split_roots(cfg.get("ROOTS", ""))
    if not roots:
        errs.append("至少填一个仓库目录")
    for r in roots:
        p = expand(r)
        if not os.path.isdir(p):
            errs.append("目录不存在：%s" % p)
    times = (cfg.get("TIMES") or "").strip()
    if times:
        for t in times.split(","):
            t = t.strip()
            if not t:
                continue
            if not re.fullmatch(r"\d{1,2}:\d{2}", t):
                errs.append("时间格式应为 HH:MM：%s" % t)
                continue
            h, m = t.split(":")
            if int(h) > 23 or int(m) > 59:
                errs.append("时间超出范围：%s" % t)
    try:
        d = int(cfg.get("SCAN_DEPTH", "2"))
        if not 1 <= d <= 5:
            errs.append("扫描深度需在 1–5 之间")
    except (TypeError, ValueError):
        errs.append("扫描深度必须是数字")
    try:
        i = int(cfg.get("UNLOCK_MIN_INTERVAL", "60"))
        if not 5 <= i <= 1440:
            errs.append("解锁间隔需在 5–1440 分钟之间")
    except (TypeError, ValueError):
        errs.append("解锁间隔必须是数字")
    if str(cfg.get("SYNC_ON_UNLOCK", "0")) not in ("0", "1"):
        errs.append("解锁同步只能是开或关")
    return errs


# ---------------------------------------------------------------- 运行外部命令
def engine_path():
    return os.path.join(paths()["bin_dir"], "git-sync.sh")


def gsync_path():
    return os.path.join(paths()["bin_dir"], "gsync")


def run_cmd(args, timeout=300):
    env = dict(os.environ)
    env["GSYNC_CONF_DIR"] = paths()["conf_dir"]
    env["GIT_SYNC_STATE_DIR"] = paths()["state_dir"]
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout, env=env)
        out = (p.stdout or "") + (p.stderr or "")
        return p.returncode, out.strip()
    except subprocess.TimeoutExpired:
        return 124, "执行超时（超过 %d 秒）" % timeout
    except FileNotFoundError as exc:
        return 127, "找不到命令：%s" % exc


def device_name():
    code, out = run_cmd(["/usr/sbin/scutil", "--get", "ComputerName"], timeout=5)
    if code == 0 and out.strip():
        return out.strip()
    return os.uname().nodename


def read_state():
    path = os.path.join(paths()["state_dir"], "state.json")
    if not os.path.exists(path):
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (ValueError, OSError):
        return None


def agent_status(label):
    uid = os.getuid()
    code, _ = run_cmd(["/bin/launchctl", "print", "gui/%d/%s" % (uid, label)], timeout=5)
    return code == 0


def tail_log(n=60):
    path = os.path.join(paths()["state_dir"], "sync.log")
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read().splitlines()[-n:]


def notify_summary():
    path = os.path.join(paths()["conf_dir"], "notify.conf")
    info = {"type": "", "ready": False}
    if not os.path.exists(path):
        return info
    vals = {}
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            vals[k.strip()] = v.strip().strip('"').strip("'")
    t = vals.get("NOTIFY_TYPE", "")
    info["type"] = t
    if t == "pushplus":
        info["ready"] = bool(vals.get("PUSHPLUS_TOKEN"))
    elif t == "wecom":
        info["ready"] = bool(vals.get("WECOM_WEBHOOK"))
    elif t == "bark":
        info["ready"] = bool(vals.get("BARK_KEY"))
    return info


def discover(limit=6):
    """在常见位置找「装着多个仓库的父目录」，用于一键填入。"""
    home = STATE["home"]
    candidates = [
        os.path.join(home, "Documents", "gitlab"),
        os.path.join(home, "Documents"),
        os.path.join(home, "code"),
        os.path.join(home, "Projects"),
        os.path.join(home, "WebstormProjects"),
        os.path.join(home, "dev"),
        os.path.join(home, "workspace"),
        home,
    ]
    found = []
    seen = set()
    for base in candidates:
        if not os.path.isdir(base) or base in seen:
            continue
        seen.add(base)
        try:
            n = count_repos(base, 2)
        except OSError:
            n = 0
        if n:
            found.append({"path": base, "count": n})
    found.sort(key=lambda x: -x["count"])
    return found[:limit]


# ---------------------------------------------------------------- HTTP
class Handler(BaseHTTPRequestHandler):
    server_version = "gsync-ui"

    def log_message(self, fmt, *args):  # 静音，避免刷屏
        pass

    # ---- 工具 ----
    def send_json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def send_text(self, text, code=200, ctype="text/html; charset=utf-8"):
        body = text.encode("utf-8") if isinstance(text, str) else text
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def host_ok(self):
        host = (self.headers.get("Host") or "").split(":")[0]
        return host in ("127.0.0.1", "localhost", "::1")

    def read_json(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return {}
        if length <= 0 or length > 1_000_000:
            return {}
        raw = self.rfile.read(length)
        try:
            return json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return {}

    # ---- 路由 ----
    def do_GET(self):
        if not self.host_ok():
            self.send_json({"error": "forbidden"}, 403)
            return
        path = self.path.split("?")[0]
        if path in ("/", "/index.html"):
            self.send_text(self.page())
        elif path == "/api/overview":
            self.send_json(self.overview())
        elif path == "/api/discover":
            self.send_json({"suggestions": discover()})
        elif path == "/api/log":
            self.send_json({"lines": tail_log(80)})
        elif path == "/report":
            rp = os.path.join(paths()["state_dir"], "last-report.html")
            if os.path.exists(rp):
                with open(rp, encoding="utf-8", errors="replace") as fh:
                    self.send_text(fh.read())
            else:
                self.send_text("<p style='font-family:sans-serif;padding:40px'>还没有报告，先运行一次。</p>", 404)
        else:
            self.send_json({"error": "not found"}, 404)

    def do_POST(self):
        if not self.host_ok():
            self.send_json({"error": "forbidden"}, 403)
            return
        path = self.path.split("?")[0]
        payload = self.read_json()

        if path == "/api/config":
            cfg = {k: str(payload.get(k, "")).strip() for k in KEYS if k in payload}
            if 'SYNC_ON_UNLOCK' in cfg:
                cfg['SYNC_ON_UNLOCK'] = '1' if cfg['SYNC_ON_UNLOCK'] in ('1', 'true', 'on') else '0'
            if 'ROOTS' in cfg:
                cfg['ROOTS'] = shorten_home(cfg['ROOTS'])
            errs = validate(cfg)
            if errs:
                self.send_json({"ok": False, "errors": errs})
                return
            write_config(cfg)
            self.send_json({"ok": True, "errors": [], "config": read_config()})
            return

        if path == "/api/apply":
            gp = gsync_path()
            if not os.path.exists(gp):
                self.send_json({"ok": False, "output": "尚未安装：%s 不存在" % gp})
                return
            code, out = run_cmd(["/bin/bash", gp, "reload"], timeout=60)
            self.send_json({"ok": code == 0, "output": out})
            return

        if path == "/api/run":
            with lock:
                if busy["run"]:
                    self.send_json({"ok": False, "output": "已有同步任务在执行"})
                    return
                busy["run"] = True
            try:
                ep = engine_path()
                if not os.path.exists(ep):
                    self.send_json({"ok": False, "output": "尚未安装：%s 不存在" % ep})
                    return
                args = ["/bin/bash", ep, "-v"]
                if payload.get("dry"):
                    args.insert(2, "-n")
                code, out = run_cmd(args, timeout=600)
                self.send_json({
                    "ok": code == 0,
                    "code": code,
                    "output": out,
                    "summary": (read_state() or {}).get("summary"),
                })
            finally:
                with lock:
                    busy["run"] = False
            return

        self.send_json({"error": "not found"}, 404)

    # ---- 数据 ----
    def overview(self):
        cfg = read_config()
        depth = 2
        try:
            depth = int(cfg.get("SCAN_DEPTH", "2"))
        except (TypeError, ValueError):
            pass
        roots = []
        for raw in split_roots(cfg.get("ROOTS", "")):
            p = expand(raw)
            roots.append({
                "raw": raw,
                "path": p,
                "exists": os.path.isdir(p),
                "count": count_repos(p, depth) if os.path.isdir(p) else 0,
            })
        st = read_state()
        report = os.path.join(paths()["state_dir"], "last-report.html")
        return {
            "device": device_name(),
            "config": cfg,
            "roots": roots,
            "state": st,
            "agents": {
                "timer": agent_status("io.gsync.timer"),
                "unlock": agent_status("io.gsync.unlock"),
            },
            "notify": notify_summary(),
            "has_report": os.path.exists(report),
            "report_mtime": os.path.getmtime(report) if os.path.exists(report) else 0,
            "running": busy["run"],
            "now": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "paths": paths(),
        }

    def page(self):
        here = os.path.dirname(os.path.abspath(__file__))
        fp = os.path.join(here, "index.html")
        if os.path.exists(fp):
            with open(fp, encoding="utf-8") as fh:
                return fh.read()
        return "<h1>缺少 index.html</h1>"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=7788)
    ap.add_argument("--home", default=os.path.expanduser("~"))
    ap.add_argument("--conf-dir", default="")
    ap.add_argument("--state-dir", default="")
    ap.add_argument("--bin-dir", default="")
    ap.add_argument("--no-open", action="store_true")
    args = ap.parse_args()

    STATE["home"] = os.path.abspath(args.home)
    STATE["conf_dir"] = args.conf_dir or os.environ.get("GSYNC_CONF_DIR", "")
    STATE["state_dir"] = args.state_dir or os.environ.get("GIT_SYNC_STATE_DIR", "")
    STATE["bin_dir"] = args.bin_dir or ""

    port = args.port
    for _ in range(20):
        try:
            httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
            break
        except OSError:
            port += 1
    else:
        print("找不到可用端口", file=sys.stderr)
        return 1

    url = "http://127.0.0.1:%d" % port
    print("gsync 配置界面：%s" % url, flush=True)
    print("按 Ctrl+C 结束", flush=True)
    if not args.no_open:
        threading.Thread(
            target=lambda: (time.sleep(0.6), subprocess.run(["/usr/bin/open", url],
                         capture_output=True)), daemon=True).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止")
    return 0


if __name__ == "__main__":
    sys.exit(main())
