#!/usr/bin/env python3
"""Operator panel for the Gemma, Whisper and oliv-api processes on this machine.

Binds 127.0.0.1:8090 only. Start, stop, and restart go through start.sh and stop.sh.
"""

import csv
import fcntl
import json
import os
import subprocess
import threading
import time
import urllib.error
import urllib.request
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

from dashboard_keys import KeyAdminError, KeyManager, unique_object
from dashboard_usage import history
from oliv_config import (
    CONFIG_PATH,
    LOCK,
    ROOT,
    ConfigError,
    diff,
    estimate,
    load,
    normalize,
    resolve_model,
)

PAGE = ROOT / "dashboard.html"
AUDIO_LIMIT = 8 * 1024 * 1024
JSON_LIMIT = 64 * 1024
KEY_JSON_LIMIT = 4096
KEY_BODY_TIMEOUT = 5
PIDFILE = {"gemma": "llama.pid", "whisper": "whisper.pid", "api": "api.pid"}
LOGFILE = {"gemma": "llama-server.log", "whisper": "whisper-server.log", "api": "oliv-api.log"}
TITLE = {"gemma": "Gemma", "whisper": "ASR", "api": "oliv-api"}
SERVICES = ("gemma", "whisper", "api")
ACTION = threading.Lock()

FLAG = {
    "-m": "model",
    "--model": "model",
    "-ngl": "gpu_layers",
    "--gpu-layers": "gpu_layers",
    "--n-gpu-layers": "gpu_layers",
    "-c": "context",
    "--ctx-size": "context",
    "-b": "batch",
    "--batch-size": "batch",
    "-ub": "ubatch",
    "--ubatch-size": "ubatch",
    "-ctk": "kv_k",
    "--cache-type-k": "kv_k",
    "-ctv": "kv_v",
    "--cache-type-v": "kv_v",
    "-fa": "flash_attn",
    "--flash-attn": "flash_attn",
    "-np": "slots",
    "--parallel": "slots",
    "--reasoning": "reasoning",
    "--host": "host",
    "--port": "port",
}
INT_FIELDS = {"gpu_layers", "context", "batch", "ubatch", "slots", "port"}


class Busy(Exception):
    pass


@contextmanager
def machine_lock():
    if not ACTION.acquire(blocking=False):
        raise Busy("มีการสั่งงานอยู่แล้ว")
    fd = None
    try:
        path = ROOT / "run" / "action.lock"
        path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o644)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise Busy("สคริปต์ start/stop กำลังทำงานจากที่อื่น") from exc
        yield
    finally:
        if fd is not None:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)
        ACTION.release()


def health_url(service, config=None):
    locked = LOCK[service]
    if service == "api":
        if config is None:
            try:
                config = load()
            except ConfigError:
                config = None
        if config:
            locked = config["api"]
    return f"http://{locked['host']}:{locked['port']}/health"


def fetch_json(url, timeout=2):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return json.loads(resp.read().decode())
    except Exception:
        return None


def probe(service):
    return fetch_json(health_url(service)) is not None


def wait_until(service, want_up, timeout):
    deadline = time.time() + timeout
    while True:
        if probe(service) == want_up:
            return True
        if time.time() >= deadline:
            return False
        time.sleep(0.4)


def read_cmdline(pid):
    try:
        raw = Path(f"/proc/{pid}/cmdline").read_bytes()
    except OSError:
        return []
    return [part.decode("utf-8", "replace") for part in raw.split(b"\0") if part]


def matches(pid, service):
    args = read_cmdline(pid)
    if not args or str(ROOT) not in " ".join(args):
        return False
    if service == "gemma":
        return Path(args[0]).name == "llama-server" and "--port" in args and args[args.index("--port") + 1] == "8081"
    if service == "api":
        return args[0] == str(ROOT / "bin" / "oliv-api")
    return Path(args[0]).name.startswith("python") and any(
        part.endswith("whisper_server.py") for part in args
    )


def pid_from_file(service):
    path = ROOT / "run" / PIDFILE[service]
    try:
        pid = int(path.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return None
    if pid > 1 and Path(f"/proc/{pid}").exists() and matches(pid, service):
        return pid
    return None


def find_pid(service):
    filed = pid_from_file(service)
    if filed:
        return filed
    found = None
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        pid = int(entry.name)
        if matches(pid, service):
            found = pid
    return found


def parse_gemma(args):
    parsed = {}
    index = 1
    while index < len(args):
        key = FLAG.get(args[index])
        if key and index + 1 < len(args):
            value = args[index + 1]
            if key in INT_FIELDS:
                try:
                    value = int(value)
                except ValueError:
                    pass
            parsed[key] = value
            index += 2
        else:
            index += 1
    return parsed


def gemma_live(pid, file_cfg):
    parsed = parse_gemma(read_cmdline(pid))
    if not parsed:
        return None, False
    file_g = file_cfg["gemma"]
    same = True
    for field, live in parsed.items():
        if field == "model":
            try:
                same = same and Path(str(live)).resolve() == resolve_model(file_g["model"], "gemma")
            except ConfigError:
                same = False
        elif field in file_g and live != file_g[field]:
            same = False
    for field in ("context", "kv_k", "kv_v", "flash_attn", "slots", "reasoning"):
        if field not in parsed:
            same = False
    return parsed, same


def whisper_live(health, file_cfg):
    if not health:
        return None, False
    if file_cfg.get("api", {}).get("asr_profile") == "qwen3asr":
        try:
            expected = json.loads((ROOT / "qwen-profile.json").read_text())["config"]
            same = (health.get("backend") == "qwen3asr"
                    and health.get("model_sha256") == expected["model_sha256"]
                    and health.get("projector_sha256") == expected["projector_sha256"]
                    and Path(str(health.get("model"))).resolve() == Path(expected["model"]).resolve()
                    and health.get("device") == "cuda" and health.get("compute_type") == "Q8_0"
                    and health.get("concurrency") == file_cfg.get("api", {}).get("asr_concurrency",1))
            return {key: health.get(key) for key in ("model", "model_id", "device", "compute_type", "gpu_layers", "concurrency")}, same
        except (OSError, KeyError, ValueError):
            return None, False
    file_w = file_cfg["whisper"]
    view = {
        "model": health.get("model"),
        "device": health.get("device"),
        "compute_type": health.get("compute_type"),
        "beam_size": health.get("beam_size"),
    }
    try:
        same = Path(str(health.get("model"))).resolve() == resolve_model(file_w["model"], "whisper")
    except (ConfigError, OSError):
        same = False
    for field in ("device", "compute_type", "beam_size"):
        if view[field] is None or view[field] != file_w[field]:
            same = False
    return view, same


def rss_mib(pid):
    """Resident memory of a process in MiB, or None."""
    if not pid:
        return None
    try:
        for line in Path(f"/proc/{pid}/status").read_text().splitlines():
            if line.startswith("VmRSS:"):
                return round(int(line.split()[1]) / 1024, 1)
    except (OSError, ValueError, IndexError):
        return None
    return None


def api_live(health, file_cfg):
    """What oliv-api reports about itself, and whether it matches [api]."""
    if not health:
        return None, False
    if not all(field in health for field in ("prompt", "llm_timeout", "version")):
        # Public liveness deliberately hides runtime config. Do not read keys or
        # treat unavailable details as proof that a restart is needed.
        return None, None
    view = {
        "prompt": health.get("prompt"),
        "llm_timeout": health.get("llm_timeout"),
        "whisper": bool(health.get("whisper")),
        "gemma": bool(health.get("gemma")),
        "version": health.get("version"),
    }
    file_a = file_cfg["api"]
    same = view["prompt"] == file_a["prompt"] and view["llm_timeout"] == file_a["llm_timeout"]
    return view, same


def gpu_snapshot(pids):
    try:
        summary = subprocess.run(
            [
                "nvidia-smi",
                "--query-gpu=name,memory.total,memory.used,memory.free",
                "--format=csv,noheader,nounits",
            ],
            capture_output=True,
            text=True,
            timeout=8,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {"ok": False, "error": str(exc), "processes": []}
    if summary.returncode != 0 or not summary.stdout.strip():
        err = (summary.stderr or "nvidia-smi failed").strip()
        return {"ok": False, "error": err, "processes": []}
    cols = next(csv.reader(summary.stdout.splitlines()))
    name, total, used, free = [col.strip() for col in cols[:4]]

    def num(text):
        return int(float(text.split()[0]))

    processes = []
    apps = subprocess.run(
        [
            "nvidia-smi",
            "--query-compute-apps=pid,process_name,used_gpu_memory",
            "--format=csv,noheader,nounits",
        ],
        capture_output=True,
        text=True,
        timeout=8,
        check=False,
    )
    if apps.returncode == 0:
        for row in csv.reader(apps.stdout.splitlines()):
            if len(row) < 3 or not row[0].strip():
                continue
            try:
                pid = int(row[0].strip())
                mib = int(float(row[2].strip().split()[0]))
            except ValueError:
                continue
            service = None
            if pid == pids.get("gemma"):
                service = "gemma"
            elif pid == pids.get("whisper"):
                service = "whisper"
            else:
                args = read_cmdline(pid)
                if (args and Path(args[0]).name == "llama-server" and "--port" in args
                        and args[args.index("--port") + 1] == "8087"
                        and str(ROOT) in " ".join(args)):
                    service = "whisper"
            processes.append(
                {
                    "pid": pid,
                    "name": Path(row[1].strip()).name,
                    "service": service,
                    "mib": mib,
                }
            )
    return {
        "ok": True,
        "name": name,
        "total_mib": num(total),
        "used_mib": num(used),
        "free_mib": num(free),
        "processes": processes,
    }


def public_url():
    """https://<hostname> of the consumer tunnel, read from its operator-owned
    config; None when no tunnel is provisioned (clients then use whatever URL
    the operator publishes the API under)."""
    try:
        from consumer_tunnel import ConsumerTunnel, ingress_hostname, read_json

        config = read_json(ConsumerTunnel(ROOT).config)
        return "https://" + ingress_hostname(config["ingress"])
    except (ImportError, OSError, KeyError, TypeError, ValueError):
        return None


def status():
    config = None
    config_error = None
    try:
        config = load()
    except ConfigError as exc:
        config_error = str(exc)
    pids = {name: find_pid(name) for name in SERVICES}
    gpu = gpu_snapshot(pids)
    card = gpu.get("total_mib") or 6144
    body = {
        "gpu": gpu,
        "config": config,
        "config_error": config_error,
        "estimate": estimate(config, card) if config else None,
        "public_url": public_url(),
    }
    for name in SERVICES:
        health = fetch_json(health_url(name, config))
        bind = config["api"] if config and name == "api" else LOCK[name]
        entry = {
            "up": health is not None,
            "pid": pids[name],
            "rss_mib": rss_mib(pids[name]),
            "port": bind["port"],
            "host": bind["host"],
            "health": health,
            "running": None,
            "config_matches": False,
        }
        if config and name == "gemma" and pids["gemma"]:
            entry["running"], entry["config_matches"] = gemma_live(pids["gemma"], config)
            if not entry["up"]:
                entry["config_matches"] = False
        elif config and name == "whisper":
            entry["running"], entry["config_matches"] = whisper_live(health, config)
            if not entry["up"]:
                entry["config_matches"] = False
        elif config and name == "api":
            entry["running"], entry["config_matches"] = api_live(health, config)
            entry["runtime_config_verified"] = entry["running"] is not None
        body[name] = entry
    return body


def run_script(name, arg):
    env = os.environ.copy()
    env["OLIV_HAVE_LOCK"] = "1"
    proc = subprocess.run(
        [str(ROOT / name), arg],
        cwd=str(ROOT),
        env=env,
        capture_output=True,
        text=True,
        timeout=40,
        check=False,
    )
    output = ((proc.stdout or "") + (proc.stderr or "")).strip()
    return proc.returncode, output


def log_tail(filename, count=40):
    path = ROOT / "logs" / filename
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return ""
    return "\n".join(lines[-count:])


def write_text(text):
    tmp = CONFIG_PATH.with_suffix(".toml.tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(CONFIG_PATH)


def restart_one(service):
    _code, out = run_script("stop.sh", service)
    chunks = [out]
    if not wait_until(service, False, 20):
        return False, "\n".join(chunks), f"ปิด {TITLE[service]} แล้วยังตอบ health อยู่"
    code, out = run_script("start.sh", service)
    chunks.append(out)
    if code != 0 or not wait_until(service, True, 90):
        chunks.append(log_tail(LOGFILE[service]))
        return False, "\n".join(chunks), f"{TITLE[service]} ไม่ขึ้น"
    return True, "\n".join(chunk for chunk in chunks if chunk), ""


def warnings_for(changed, up):
    if not changed:
        return ["ค่าไม่เปลี่ยน จึงไม่รีสตาร์ทบริการ"]
    lines = []
    for service in changed:
        if up.get(service):
            lines.append(f"{TITLE[service]} จะหลุดจาก GPU ระหว่างรีสตาร์ท แล้วโหลดค่าใหม่")
        else:
            lines.append(f"{TITLE[service]} ปิดอยู่ จะถูกสตาร์ทด้วยค่าใหม่")
    idle = [TITLE[name] for name in ("gemma", "whisper") if name not in changed]
    if idle:
        lines.append(f"{' และ '.join(idle)} ไม่ถูกปิด")
    if len(changed) == 2:
        lines.append("จะรีสตาร์ททีละตัว เริ่มที่ Gemma ไม่ปิดทั้งคู่พร้อมกัน")
    return lines


def preview_of(new, old=None):
    old = old or load()
    changed, detail = diff(old, new)
    pids = {"gemma": find_pid("gemma"), "whisper": find_pid("whisper")}
    gpu = gpu_snapshot(pids)
    est = estimate(new, gpu.get("total_mib") or 6144)
    up = {"gemma": probe("gemma"), "whisper": probe("whisper")}
    return {
        "ok": True,
        "changed": changed,
        "detail": detail,
        "estimate": est,
        "gpu": gpu,
        "warnings": warnings_for(changed, up),
        "can_apply": (not changed) or est["fits"],
    }


def preview(posted):
    return preview_of(normalize(posted, from_client=True))


def apply_config(posted):
    old_text = CONFIG_PATH.read_text(encoding="utf-8")
    old = load()
    new = normalize(posted, from_client=True)
    view = preview_of(new, old)
    if not view["changed"]:
        view["message"] = "ค่าเดิม ไม่ได้รีสตาร์ท"
        view["restarted"] = []
        view["status"] = status()
        return 200, view
    if not view["estimate"]["fits"]:
        view["ok"] = False
        view["error"] = "VRAM ไม่พอสำหรับค่านี้"
        return 409, view
    from oliv_config import dump

    dump(new)
    restarted = []
    logs = []
    for service in view["changed"]:
        ok, log, err = restart_one(service)
        logs.append(log)
        if ok:
            restarted.append(service)
            continue
        write_text(old_text)
        restore_logs = []
        restore_err = []
        for back in restarted + [service]:
            back_ok, back_log, back_err = restart_one(back)
            restore_logs.append(back_log)
            if not back_ok:
                restore_err.append(back_err)
        message = f"{err} จึงคืน config เดิม"
        if restore_err:
            message += " แต่สตาร์ทค่าเดิมกลับไม่สำเร็จ: " + "; ".join(restore_err)
        else:
            message += " และสตาร์ทค่าเดิมกลับแล้ว"
        return 500, {
            "ok": False,
            "error": message,
            "log": "\n".join(logs + restore_logs),
            "restored": not restore_err,
            "status": status(),
        }
    names = " และ ".join(TITLE[name] for name in restarted)
    view["message"] = f"บันทึกแล้ว และรีสตาร์ท {names}"
    view["restarted"] = restarted
    view["log"] = "\n".join(logs)
    view["status"] = status()
    return 200, view


def service_action(service, action):
    if service not in TITLE:
        raise ConfigError("ไม่รู้จักบริการ")
    if action not in ("start", "stop", "restart"):
        raise ConfigError("ไม่รู้จักคำสั่ง")
    print(f"action {action} {service}", flush=True)
    if action == "restart":
        ok, log, err = restart_one(service)
        if not ok:
            return 500, {"ok": False, "error": err, "log": log, "status": status()}
        return 200, {
            "ok": True,
            "message": f"รีสตาร์ท {TITLE[service]} แล้ว",
            "log": log,
            "status": status(),
        }
    script = "start.sh" if action == "start" else "stop.sh"
    code, out = run_script(script, service)
    if action == "start":
        ready = code == 0 and wait_until(service, True, 90)
        if not ready:
            return 500, {
                "ok": False,
                "error": f"สตาร์ท {TITLE[service]} ไม่สำเร็จ",
                "log": out + "\n" + log_tail(LOGFILE[service]),
                "status": status(),
            }
        message = (
            f"{TITLE[service]} ทำงานอยู่แล้ว"
            if "already up" in out
            else f"สตาร์ท {TITLE[service]} แล้ว"
        )
        return 200, {"ok": True, "message": message, "log": out, "status": status()}
    if not wait_until(service, False, 20):
        return 500, {
            "ok": False,
            "error": f"ปิด {TITLE[service]} ไม่สำเร็จ",
            "log": out,
            "status": status(),
        }
    return 200, {"ok": True, "message": f"ปิด {TITLE[service]} แล้ว", "log": out, "status": status()}


def gemma_test(prompt):
    if not isinstance(prompt, str) or not prompt.strip():
        raise ConfigError("ยังไม่มีข้อความ")
    prompt = prompt.strip()
    if len(prompt) > 400:
        raise ConfigError("ข้อความทดสอบยาวเกิน 400 ตัวอักษร")
    if not probe("gemma"):
        return 503, {"ok": False, "error": "Gemma ยังไม่ขึ้น"}
    model = str(resolve_model(load()["gemma"]["model"], "gemma"))
    payload = json.dumps(
        {
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": 48,
            "temperature": 0.2,
            "stream": False,
        }
    ).encode()
    req = urllib.request.Request(
        "http://127.0.0.1:8081/v1/chat/completions",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    started = time.time()
    try:
        with urllib.request.urlopen(req, timeout=180) as resp:
            data = json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:500]
        return 502, {"ok": False, "error": f"Gemma ตอบ {exc.code}", "detail": detail}
    except Exception as exc:
        return 502, {"ok": False, "error": f"เรียก Gemma ไม่สำเร็จ: {exc}"}
    try:
        content = data["choices"][0]["message"].get("content") or ""
        if isinstance(content, list):
            content = "".join(part.get("text", "") for part in content if isinstance(part, dict))
    except (KeyError, IndexError, TypeError):
        return 502, {"ok": False, "error": "อ่านคำตอบของ Gemma ไม่ได้"}
    return 200, {"ok": True, "text": content.strip(), "ms": int((time.time() - started) * 1000)}


def whisper_test(body, content_type):
    if not body:
        raise ConfigError("ไฟล์ว่าง")
    if len(body) > AUDIO_LIMIT:
        raise ConfigError("ไฟล์ใหญ่เกิน 8 MB ใช้คลิปสั้นๆ")
    if not probe("whisper"):
        return 503, {"ok": False, "error": "Whisper ยังไม่ขึ้น"}
    req = urllib.request.Request(
        "http://127.0.0.1:8082/transcribe",
        data=body,
        headers={"Content-Type": content_type or "application/octet-stream"},
        method="POST",
    )
    started = time.time()
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:500]
        return 502, {"ok": False, "error": f"Whisper ตอบ {exc.code}", "detail": detail}
    except Exception as exc:
        return 502, {"ok": False, "error": f"เรียก Whisper ไม่สำเร็จ: {exc}"}
    if isinstance(data, dict):
        data["ms"] = int((time.time() - started) * 1000)
    return 200, data


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        # Parser errors can contain request bytes. Never log a URL/query,
        # Authorization header, transcript, key name or one-time credential.
        print("dashboard HTTP event", flush=True)

    def log_request(self, code="-", size="-"):
        value = str(code)
        print("dashboard request status=" + (value if value.isdigit() else "unknown"), flush=True)

    def send_json(self, code, payload):
        raw = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        if self.close_connection:
            self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(raw)

    def send_html(self, code, text):
        raw = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        self.end_headers()
        self.wfile.write(raw)

    def read_body(self, limit):
        try:
            size = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return None
        if size < 0 or size > limit:
            return None
        return self.rfile.read(size)

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/api/keys" or path.startswith("/api/keys/"):
            self.handle_keys(path)
            return
        if path == "/health":
            self.send_json(200, {"ok": True})
            return
        if path == "/api/status":
            self.send_json(200, status())
            return
        if path == "/":
            try:
                self.send_html(200, PAGE.read_text(encoding="utf-8"))
            except OSError:
                self.send_html(500, "missing dashboard.html")
            return
        self.send_json(404, {"ok": False, "error": "not found"})

    def cross_site_rejection(self, path):
        """Every POST changes or exercises the machine, so refuse ones a browser
        could send from another site. The admin marker is a custom header, so a
        cross-site page needs a CORS preflight, which this server never grants;
        a simple text/plain POST can't carry it. Sec-Fetch-Site also rejects
        cross-site requests from browsers that report it. Returns a reason, or
        None when the request is acceptable."""
        if self.headers.get("Sec-Fetch-Site", "same-origin").lower() not in ("same-origin", "none"):
            return 403, "cross-site requests are not accepted"
        if self.headers.get_all("X-OLIV-Admin", []) != ["1"]:
            return 403, "admin request marker is required"
        if path != "/api/whisper/test":
            types = self.headers.get_all("Content-Type", [])
            if len(types) != 1 or types[0].split(";")[0].strip().lower() != "application/json":
                return 415, "Content-Type must be application/json"
        return None

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/api/keys" or path.startswith("/api/keys/"):
            self.handle_keys(path)
            return
        rejection = self.cross_site_rejection(path)
        if rejection is not None:
            # The body is never read, so don't reuse the connection.
            self.close_connection = True
            self.send_json(rejection[0], {"ok": False, "error": rejection[1]})
            return
        try:
            if path == "/api/whisper/test":
                body = self.read_body(AUDIO_LIMIT)
                if body is None:
                    self.send_json(413, {"ok": False, "error": "ไฟล์ใหญ่เกิน 8 MB"})
                    return
                code, payload = whisper_test(body, self.headers.get("Content-Type", ""))
                self.send_json(code, payload)
                return
            raw = self.read_body(JSON_LIMIT)
            if raw is None:
                self.send_json(413, {"ok": False, "error": "ข้อมูลใหญ่เกินไป"})
                return
            try:
                posted = json.loads(raw.decode() or "{}")
            except json.JSONDecodeError:
                self.send_json(400, {"ok": False, "error": "JSON อ่านไม่ผ่าน"})
                return
            if path == "/api/preview":
                self.send_json(200, preview(posted))
                return
            if path == "/api/apply":
                with machine_lock():
                    code, payload = apply_config(posted)
                self.send_json(code, payload)
                return
            if path == "/api/service":
                with machine_lock():
                    code, payload = service_action(posted.get("service"), posted.get("action"))
                self.send_json(code, payload)
                return
            if path == "/api/gemma/test":
                code, payload = gemma_test(posted.get("prompt", ""))
                self.send_json(code, payload)
                return
        except Busy as exc:
            self.send_json(409, {"ok": False, "error": str(exc)})
            return
        except ConfigError as exc:
            self.send_json(400, {"ok": False, "error": str(exc)})
            return
        except subprocess.TimeoutExpired:
            self.send_json(500, {"ok": False, "error": "สคริปต์ใช้เวลานานเกินไป"})
            return
        self.send_json(404, {"ok": False, "error": "not found"})

    def handle_keys(self, path):
        self.close_connection = True
        try:
            if self.path != path:
                raise KeyAdminError(400, "invalid_request", "Key routes do not accept query parameters")
            if self.command == "GET" and path == "/api/keys":
                self.send_json(200, KeyManager(ROOT).listing())
                return
            if self.command != "POST" or path not in ("/api/keys/create", "/api/keys/revoke", "/api/keys/usage"):
                raise KeyAdminError(404, "not_found", "Key route not found")
            if self.headers.get("Sec-Fetch-Site", "same-origin").lower() not in ("same-origin", "none"):
                raise KeyAdminError(403, "admin_required", "Cross-site requests are not accepted")
            if self.headers.get_all("X-OLIV-Admin", []) != ["1"]:
                raise KeyAdminError(403, "admin_required", "Admin request marker is required")
            types = self.headers.get_all("Content-Type", [])
            if len(types) != 1 or types[0].split(";")[0].strip().lower() != "application/json":
                raise KeyAdminError(415, "unsupported_media_type", "Content-Type must be application/json")
            if self.headers.get_all("Content-Encoding", []):
                raise KeyAdminError(415, "unsupported_media_type", "Compressed key requests are unsupported")
            lengths = self.headers.get_all("Content-Length", [])
            if (len(lengths) != 1 or not lengths[0].isascii() or not lengths[0].isdigit()
                    or self.headers.get_all("Transfer-Encoding", [])):
                raise KeyAdminError(400, "invalid_request", "One Content-Length is required")
            if len(lengths[0]) > 10:
                raise KeyAdminError(413, "payload_too_large", "Key request must contain 1–4096 bytes")
            length = int(lengths[0])
            if not 0 < length <= KEY_JSON_LIMIT:
                raise KeyAdminError(413, "payload_too_large", "Key request must contain 1–4096 bytes")
            previous_timeout = self.connection.gettimeout()
            body = bytearray()
            deadline = time.monotonic() + KEY_BODY_TIMEOUT
            try:
                while len(body) < length:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise TimeoutError
                    self.connection.settimeout(remaining)
                    chunk = self.rfile.read1(length - len(body))
                    if not chunk:
                        raise KeyAdminError(400, "invalid_request", "Incomplete key request body")
                    body.extend(chunk)
            except TimeoutError:
                raise KeyAdminError(408, "upload_timeout", "Key request upload timed out") from None
            finally:
                self.connection.settimeout(previous_timeout)
            try:
                posted = json.loads(body.decode("utf-8"), object_pairs_hook=unique_object)
            except (ValueError, UnicodeError, RecursionError):
                raise KeyAdminError(400, "invalid_request", "Invalid key request JSON") from None
            if path == "/api/keys/usage":
                self.send_json(200, history(ROOT, posted))
                return
            with machine_lock():
                manager = KeyManager(ROOT)
                creating = path.endswith("/create")
                payload = manager.create(posted) if creating else manager.revoke(posted)
                try:
                    self.send_json(201 if creating else 200, payload)
                except OSError:
                    # A definite origin write failure means the newly created
                    # credential was not reliably delivered. Keep the action
                    # lock through revocation; never append a second response
                    # to bytes that may already be on the failed connection.
                    self.close_connection = True
                    if creating:
                        try:
                            manager.revoke({"id": payload["key"]["id"]})
                            print("dashboard key response failed; new key revoked", flush=True)
                        except (KeyAdminError, OSError):
                            print("dashboard key response failed; automatic revocation failed; "
                                  "inspect recent keys and revoke before retrying", flush=True)
                    return
        except Busy:
            self.send_json(409, {"ok": False, "code": "busy", "error": "Another admin action is in progress"})
        except KeyAdminError as exc:
            self.send_json(exc.status, {"ok": False, "code": exc.code, "error": str(exc)})
        except OSError:
            self.send_json(503, {"ok": False, "code": "key_management_unavailable",
                                 "error": "API key management is unavailable"})


def main():
    try:
        config = load()
    except ConfigError as exc:
        raise SystemExit(str(exc)) from exc
    host = config["dashboard"]["host"]
    port = config["dashboard"]["port"]
    if (host, port) != ("127.0.0.1", 8090):
        raise SystemExit("dashboard refuses to bind anything except 127.0.0.1:8090")
    ThreadingHTTPServer.allow_reuse_address = True
    try:
        httpd = ThreadingHTTPServer((host, port), Handler)
    except OSError as exc:
        raise SystemExit(f"cannot bind {host}:{port}: {exc}") from exc
    print(f"dashboard on http://{host}:{port}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
