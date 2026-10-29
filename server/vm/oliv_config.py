#!/usr/bin/env python3
"""Read and write config.toml next to this file (~/oliv/config.toml on the server).

start.sh, whisper_server.py, and the dashboard all go through this module
so the values that actually launch are the values on the page.
"""

import ipaddress
import json
import shlex
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONFIG_PATH = ROOT / "config.toml"
MODELS = ROOT / "models"

# These binds are the only ones this machine should use.
# 0.0.0.0 would expose the models with no password.
LOCK = {
    "gemma": {"host": "127.0.0.1", "port": 8081},
    "whisper": {"host": "127.0.0.1", "port": 8082},
    "dashboard": {"host": "127.0.0.1", "port": 8090},
    # New installations stay on loopback; a private overlay bind is opt-in.
    "api": {"host": "127.0.0.1", "port": 8083},
}
# Besides loopback, oliv-api may bind one address on a private overlay network
# such as Tailscale or Headscale, which use the RFC 6598 range. That is
# also the only bind where the legacy shared-token auth mode is allowed.
PRIVATE_OVERLAY = ipaddress.ip_network("100.64.0.0/10")


def is_private_overlay(host):
    if not isinstance(host, str):
        return False
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return False
    return address.version == 4 and str(address) == host and address in PRIVATE_OVERLAY


def api_host_allowed(host):
    return host == LOCK["api"]["host"] or is_private_overlay(host)


API_PROMPTS = ("v2", "v3", "v4", "v5")
API_ASR_PROFILES = ("turbo", "qwen3asr", "typhoon-ctx")
API_DEFAULT = {"prompt": "v2", "llm_timeout": 5, "auth_mode": "keys", "asr_profile": "turbo", "asr_concurrency": 1}
TOKEN_PATH = ROOT / "api.token"

KV_TYPES = ("f32", "f16", "bf16", "q8_0", "q4_0", "q4_1", "iq4_nl", "q5_0", "q5_1")
# Bytes per element. Block types are the ggml block size divided by 32 values.
KV_BYTES = {
    "f32": 4.0,
    "f16": 2.0,
    "bf16": 2.0,
    "q8_0": 34 / 32,
    "q5_1": 24 / 32,
    "q5_0": 22 / 32,
    "q4_1": 20 / 32,
    "q4_0": 18 / 32,
    "iq4_nl": 18 / 32,
}
FLASH = ("on", "off", "auto")
REASONING = ("off", "on", "auto")
WHISPER_COMPUTE = ("int8", "int8_float16", "int8_float32", "float16", "bfloat16", "float32")
WHISPER_DEVICE = ("cuda", "cpu")

# Gemma 4 E2B in models/gemma: 35 layers, but shared_kv_layers = 20, so only the
# first 15 allocate a KV cache. The sliding-window pattern on those 15 layers is
# 12 windowed layers (k/v 256, window 512) and 3 full layers (k/v 512).
FULL_LAYERS = 3
SWA_LAYERS = 12
SWA_WINDOW = 512
FULL_DIM = 512
SWA_DIM = 256

# Measured with nvidia-smi on a 6 GB reference card, locked baseline resident.
MEASURED_GEMMA_MIB = 1566.0
MEASURED_WHISPER_MIB = {
    "int8": 980,
    "int8_float16": 1060,
    "int8_float32": 1168,  # the default
    "float16": 2100,
    "bfloat16": 2100,
    "float32": 4200,
}
HEADROOM_MIB = 384
CONTEXT_MAX = 8192
SLOTS_MAX = 4

GEMMA_FIELDS = (
    "model",
    "gpu_layers",
    "context",
    "batch",
    "ubatch",
    "kv_k",
    "kv_v",
    "flash_attn",
    "slots",
    "reasoning",
)
WHISPER_FIELDS = ("model", "device", "compute_type", "beam_size")

FIELD_LABEL = {
    "model": "โมเดล",
    "gpu_layers": "ชั้นบน GPU",
    "context": "context",
    "batch": "batch",
    "ubatch": "ubatch",
    "kv_k": "KV ของ K",
    "kv_v": "KV ของ V",
    "flash_attn": "flash attention",
    "slots": "slot",
    "reasoning": "reasoning",
    "device": "device",
    "compute_type": "compute type",
    "beam_size": "beam",
}


class ConfigError(ValueError):
    pass


def kv_mib(context, slots, kv_k, kv_v):
    bk = KV_BYTES[kv_k]
    bv = KV_BYTES[kv_v]
    full = FULL_LAYERS * context * (FULL_DIM * bk + FULL_DIM * bv)
    swa = SWA_LAYERS * min(context, SWA_WINDOW) * (SWA_DIM * bk + SWA_DIM * bv)
    return slots * (full + swa) / (1024 * 1024)


def _int(value, name, lo, hi):
    if isinstance(value, bool) or not isinstance(value, int):
        raise ConfigError(f"{name} ต้องเป็นจำนวนเต็ม")
    if value < lo or value > hi:
        raise ConfigError(f"{name} ต้องอยู่ระหว่าง {lo} กับ {hi}")
    return value


def _choice(value, name, allowed):
    if value not in allowed:
        raise ConfigError(f"{name} ต้องเป็นหนึ่งใน: {', '.join(allowed)}")
    return value


def resolve_model(rel, kind):
    if not isinstance(rel, str) or not rel.strip():
        raise ConfigError("ยังไม่ได้ใส่พาธโมเดล")
    raw = rel.strip()
    if raw.startswith("/") or ".." in Path(raw).parts:
        path = Path(raw).resolve() if raw.startswith("/") else None
        if path is None:
            raise ConfigError("พาธโมเดลต้องอยู่ใต้ models/")
    else:
        path = (ROOT / raw).resolve()
    models = MODELS.resolve()
    if path != models and models not in path.parents:
        raise ConfigError("โมเดลต้องอยู่ใต้ models/")
    if kind == "gemma":
        if not path.is_file():
            raise ConfigError(f"ไม่พบไฟล์ Gemma: {raw}")
    elif not (path / "model.bin").is_file():
        raise ConfigError(f"ไม่พบ model.bin ของ Whisper ใน {raw}")
    return path


def _bind(section, name, overwrite):
    locked = LOCK[name]
    if overwrite:
        section["host"] = locked["host"]
        section["port"] = locked["port"]
        return
    host = section.get("host")
    port = section.get("port")
    allowed = api_host_allowed(host) if name == "api" else host == locked["host"]
    where = f"{locked['host']} หรือ private overlay IP ({PRIVATE_OVERLAY})" if name == "api" else locked["host"]
    if not allowed or port != locked["port"] or isinstance(port, bool):
        raise ConfigError(
            f"{name} ต้องฟังที่ {where} พอร์ต {locked['port']} เท่านั้น (ไม่เปิด 0.0.0.0)"
        )


def _gemma(raw, overwrite_bind):
    if not isinstance(raw, dict):
        raise ConfigError("ส่วน gemma ใช้ไม่ได้")
    section = dict(raw)
    _bind(section, "gemma", overwrite_bind)
    model = section.get("model")
    if not isinstance(model, str):
        raise ConfigError("ยังไม่ได้ใส่พาธโมเดล Gemma")
    resolve_model(model, "gemma")
    context = _int(section.get("context"), "context", 256, CONTEXT_MAX)
    if context % 256 != 0:
        raise ConfigError("context ต้องเป็นจำนวนเท่าของ 256")
    batch = _int(section.get("batch"), "batch", 64, 1024)
    ubatch = _int(section.get("ubatch"), "ubatch", 64, 1024)
    if ubatch > batch:
        raise ConfigError("ubatch ต้องไม่เกิน batch")
    if batch % 64 != 0 or ubatch % 64 != 0:
        raise ConfigError("batch และ ubatch ต้องเป็นจำนวนเท่าของ 64")
    return {
        "model": model.strip(),
        "host": section["host"],
        "port": int(section["port"]),
        "gpu_layers": _int(section.get("gpu_layers"), "ชั้นบน GPU", 0, 99),
        "context": context,
        "batch": batch,
        "ubatch": ubatch,
        "kv_k": _choice(section.get("kv_k"), "KV ของ K", KV_TYPES),
        "kv_v": _choice(section.get("kv_v"), "KV ของ V", KV_TYPES),
        "flash_attn": _choice(section.get("flash_attn"), "flash attention", FLASH),
        "slots": _int(section.get("slots"), "slot", 1, SLOTS_MAX),
        "reasoning": _choice(section.get("reasoning"), "reasoning", REASONING),
    }


def _whisper(raw, overwrite_bind):
    if not isinstance(raw, dict):
        raise ConfigError("ส่วน whisper ใช้ไม่ได้")
    section = dict(raw)
    _bind(section, "whisper", overwrite_bind)
    model = section.get("model")
    if not isinstance(model, str):
        raise ConfigError("ยังไม่ได้ใส่พาธโมเดล Whisper")
    resolve_model(model, "whisper")
    return {
        "model": model.strip(),
        "host": section["host"],
        "port": int(section["port"]),
        "device": _choice(section.get("device"), "device ของ Whisper", WHISPER_DEVICE),
        "compute_type": _choice(section.get("compute_type"), "compute type", WHISPER_COMPUTE),
        "beam_size": _int(section.get("beam_size"), "beam", 1, 5),
    }


def _api(raw):
    """API defaults are loopback + individual keys, never implicit legacy auth."""
    if raw is None:
        raw = {**LOCK["api"], **API_DEFAULT}
    if not isinstance(raw, dict):
        raise ConfigError("ส่วน api ใช้ไม่ได้")
    unknown = set(raw) - {"host", "port", "prompt", "llm_timeout", "auth_mode", "asr_profile", "asr_concurrency"}
    if unknown:
        raise ConfigError("ไม่รู้จักค่า api: " + ", ".join(sorted(unknown)))
    section = dict(raw)
    _bind(section, "api", False)
    auth_mode = _choice(section.get("auth_mode", "keys"), "auth_mode ของ api", ("keys", "legacy"))
    if auth_mode == "legacy" and not is_private_overlay(section["host"]):
        raise ConfigError(f"api.auth_mode=legacy ใช้ได้เฉพาะเมื่อฟังที่ private overlay IP ({PRIVATE_OVERLAY}) เท่านั้น")
    prompt = section.get("prompt", API_DEFAULT["prompt"])
    if not isinstance(prompt, str):
        raise ConfigError("prompt ของ api ต้องเป็นหนึ่งใน: " + ", ".join(API_PROMPTS))
    concurrency = _int(section.get("asr_concurrency", 1), "asr_concurrency", 1, 4)
    profile = _choice(section.get("asr_profile", API_DEFAULT["asr_profile"]), "asr_profile ของ api", API_ASR_PROFILES)
    if concurrency > 1 and profile != "qwen3asr":
        raise ConfigError("asr_concurrency > 1 รองรับเฉพาะ qwen3asr")
    return {
        "host": section["host"],
        "port": int(section["port"]),
        "auth_mode": auth_mode,
        "prompt": _choice(prompt.lower(), "prompt ของ api", API_PROMPTS),
        "llm_timeout": _int(
            section.get("llm_timeout", API_DEFAULT["llm_timeout"]), "llm_timeout", 1, 30
        ),
        "asr_concurrency": concurrency,
        "asr_profile": _choice(
            section.get("asr_profile", API_DEFAULT["asr_profile"]),
            "asr_profile ของ api", API_ASR_PROFILES,
        ),
    }


def _file_api():
    """The [api] already on disk. The dashboard never edits it, so a config
    posted from the page keeps whatever the file says."""
    try:
        with CONFIG_PATH.open("rb") as handle:
            data = tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise ConfigError("อ่าน [api] เดิมไม่ได้ จึงไม่เปลี่ยน config") from exc
    return _api(data.get("api"))


def normalize(data, from_client=False):
    if not isinstance(data, dict):
        raise ConfigError("config ต้องเป็นตาราง")
    gemma = _gemma(data.get("gemma"), from_client)
    whisper = _whisper(data.get("whisper"), from_client)
    dash_raw = {} if from_client else data.get("dashboard")
    if not from_client:
        if not isinstance(dash_raw, dict):
            raise ConfigError("ส่วน dashboard ใช้ไม่ได้")
        _bind(dict(dash_raw), "dashboard", False)
    api = _file_api() if from_client else _api(data.get("api"))
    return {
        "gemma": gemma,
        "whisper": whisper,
        "dashboard": dict(LOCK["dashboard"]),
        "api": api,
    }


def load():
    try:
        with CONFIG_PATH.open("rb") as handle:
            data = tomllib.load(handle)
    except OSError as exc:
        raise ConfigError(f"อ่าน config ไม่ได้: {exc}") from exc
    except tomllib.TOMLDecodeError as exc:
        raise ConfigError(f"config.toml อ่านไม่ผ่าน: {exc}") from exc
    return normalize(data, from_client=False)


def render(cfg):
    g = cfg["gemma"]
    w = cfg["whisper"]
    d = cfg["dashboard"]
    a = cfg["api"]
    return f"""# Read by start.sh, whisper_server.py, oliv-api and the dashboard.
# Gemma: context 2048, 1 slot, KV q8_0, flash attention on, reasoning off.
# Binds are locked to loopback so nothing is exposed beyond this machine.

[gemma]
model = {json.dumps(g["model"], ensure_ascii=False)}
host = {json.dumps(g["host"])}
port = {g["port"]}
gpu_layers = {g["gpu_layers"]}
context = {g["context"]}
batch = {g["batch"]}
ubatch = {g["ubatch"]}
kv_k = {json.dumps(g["kv_k"])}
kv_v = {json.dumps(g["kv_v"])}
flash_attn = {json.dumps(g["flash_attn"])}
slots = {g["slots"]}
reasoning = {json.dumps(g["reasoning"])}

[whisper]
model = {json.dumps(w["model"], ensure_ascii=False)}
host = {json.dumps(w["host"])}
port = {w["port"]}
device = {json.dumps(w["device"])}
compute_type = {json.dumps(w["compute_type"])}
beam_size = {w["beam_size"]}

[dashboard]
host = {json.dumps(d["host"])}
port = {d["port"]}

# oliv-api: loopback, or one private overlay IP (100.64.0.0/10); never public.
# auth_mode=keys uses api-keys.json; legacy uses api.token, overlay IP only.
# prompt is the cleanup prompt (v2/v3/v4/v5); llm_timeout is seconds to wait for Gemma.
[api]
host = {json.dumps(a["host"])}
port = {a["port"]}
auth_mode = {json.dumps(a["auth_mode"])}
prompt = {json.dumps(a["prompt"])}
llm_timeout = {a["llm_timeout"]}
asr_profile = {json.dumps(a["asr_profile"])}
asr_concurrency = {a["asr_concurrency"]}
"""


def dump(cfg):
    text = render(cfg)
    tmp = CONFIG_PATH.with_suffix(".toml.tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(CONFIG_PATH)


def export_shell(cfg=None):
    cfg = cfg or load()
    g = cfg["gemma"]
    w = cfg["whisper"]
    values = {
        "GEMMA_MODEL": str(resolve_model(g["model"], "gemma")),
        "GEMMA_HOST": g["host"],
        "GEMMA_PORT": g["port"],
        "GEMMA_NGL": g["gpu_layers"],
        "GEMMA_CTX": g["context"],
        "GEMMA_BATCH": g["batch"],
        "GEMMA_UBATCH": g["ubatch"],
        "GEMMA_CTK": g["kv_k"],
        "GEMMA_CTV": g["kv_v"],
        "GEMMA_FA": g["flash_attn"],
        "GEMMA_NP": g["slots"],
        "GEMMA_REASONING": g["reasoning"],
        "WHISPER_HOST": w["host"],
        "WHISPER_PORT": w["port"],
        "API_HOST": cfg["api"]["host"],
        "API_PORT": cfg["api"]["port"],
        "API_AUTH_MODE": cfg["api"]["auth_mode"],
    }
    return "".join(f"{key}={shlex.quote(str(value))}\n" for key, value in values.items())


def diff(old, new):
    """Services whose tracked fields differ, Gemma first."""
    changed = []
    detail = []
    for service, fields in (("gemma", GEMMA_FIELDS), ("whisper", WHISPER_FIELDS)):
        rows = []
        for field in fields:
            before = old[service][field]
            after = new[service][field]
            if before != after:
                rows.append(
                    {
                        "field": field,
                        "label": FIELD_LABEL[field],
                        "from": before,
                        "to": after,
                    }
                )
        if rows:
            changed.append(service)
            detail.append({"service": service, "fields": rows})
    return changed, detail


def estimate(cfg, card_mib):
    g = cfg["gemma"]
    w = cfg["whisper"]
    base_kv = kv_mib(2048, 1, "q8_0", "q8_0")
    resident = MEASURED_GEMMA_MIB - base_kv
    fixed = 80.0
    scalable = max(0.0, resident - fixed)
    weights = fixed + scalable * (g["gpu_layers"] / 99)
    extra = 0.0
    if g["context"] > 2048:
        extra += (g["context"] - 2048) / 2048 * 120
    if g["slots"] > 1:
        extra += (g["slots"] - 1) * 180
    if g["flash_attn"] != "on":
        extra += 200
    if g["batch"] > 256:
        extra += (g["batch"] - 256) / 256 * 40
    gemma = max(200.0, weights + kv_mib(g["context"], g["slots"], g["kv_k"], g["kv_v"]) + extra)
    if cfg.get("api", {}).get("asr_profile") == "qwen3asr":
        whisper = float({1:3040,2:3300,3:3560,4:3820}[cfg["api"].get("asr_concurrency",1)])  # Rounded above measured ASR residency.
    elif w["device"] == "cpu":
        whisper = 0.0
    else:
        whisper = float(MEASURED_WHISPER_MIB[w["compute_type"]])
        if w["beam_size"] > 1:
            whisper += (w["beam_size"] - 1) * 40
    used = gemma + whisper
    card = int(card_mib) if card_mib else 6144
    raised = g["context"] > 2048 or g["slots"] > 1
    fits = used + HEADROOM_MIB <= card
    notes = [
        "ประมาณจาก VRAM ที่วัดได้ตอน context 2048, slot 1, KV q8_0 "
        "(Gemma 1566 MiB) และ Whisper int8_float16 (1060 MiB) / int8_float32 (1168 MiB) "
        "แคช KV คิดจาก 15 ชั้นที่มีแคชของ Gemma 4 E2B ในไฟล์นี้"
    ]
    if cfg.get("api", {}).get("asr_profile") == "qwen3asr":
        notes = [f"ASR ที่ใช้อยู่คือ Qwen3-ASR Q8_0, {cfg['api'].get('asr_concurrency',1)} slots ประมาณ {whisper:.0f} MiB; Whisper สำรองไม่ได้โหลดบน GPU"]
    if raised:
        notes.append(
            "context เกิน 2048 หรือ slot มากกว่า 1 ใช้ VRAM เพิ่ม "
            "งาน OLIV ส่งไม่ถึง 200 token จึงไม่จำเป็นต้องเปิดยาวกว่า 2048"
        )
    if g["flash_attn"] != "on" or g["slots"] > 1 or g["context"] > 2048 or g["batch"] > 256:
        notes.append("ส่วนที่เพิ่มจากจุดที่วัดไว้เป็นกันชนของการจองหน่วยความจำบนการ์ด ไม่ใช่ตัวเลขที่วัดรอบใหม่")
    if w["device"] == "cpu":
        notes.append("Whisper บน CPU ไม่กิน VRAM แต่ถอดเสียงช้าลงมาก")
    elif w["compute_type"] not in ("int8_float16", "int8_float32"):
        notes.append("เลข Whisper นอกจาก int8_float16/int8_float32 เป็นการกะจากขนาดโมเดล ยังไม่ได้วัดบนการ์ดนี้")
    if not fits:
        notes.append(f"ที่ว่างไม่พอหลังกันไว้ {HEADROOM_MIB} MiB จึงยังไม่รีสตาร์ทด้วยค่านี้")
    elif raised:
        notes.append("ตามประมาณการนี้ VRAM พอ")
    return {
        "gemma_mib": int(round(gemma)),
        "whisper_mib": int(round(whisper)),
        "total_mib": int(round(used)),
        "card_mib": card,
        "free_after_mib": int(round(card - used)),
        "headroom_mib": HEADROOM_MIB,
        "fits": fits,
        "raised": raised,
        "notes": notes,
    }


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("export", "check", "estimate"):
        print("usage: oliv_config.py [export|check|estimate]", file=sys.stderr)
        return 2
    try:
        cfg = load()
    except ConfigError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    if sys.argv[1] == "export":
        sys.stdout.write(export_shell(cfg))
    elif sys.argv[1] == "check":
        print("ok")
    else:
        print(json.dumps(estimate(cfg, 6144), ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
