#!/usr/bin/env bash
#
# build_app.sh — package OLIV.app as a SELF-CONTAINED bundle (W3-T4, packaging
# half). The shipped .app must run on a Mac that has never seen this repo, so we
# embed BOTH halves the sidecar needs:
#
#   Contents/Resources/oliv-runtime/
#     python/   an embedded, relocatable CPython 3.11 (python-build-standalone)
#               with sidecar/requirements.lock installed into its own
#               site-packages — no system python, no dev .venv. Installed
#               TORCH-FREE (torch + its exclusive transitive deps are dropped;
#               see step 2b for the why and the evidence).
#     root/     the MINIMAL source tree the sidecar imports at runtime:
#                 sidecar/sidecar_server.py     (the server itself)
#                 sidecar/thai_format.py        (deterministic Thai post-pass,
#                                                imported at server top level)
#                 app/ (the STT package)        (import app.stt -> build_backend)
#                 benchmark/pipeline.py + its   (import pipeline -> clean_ex, which
#                   dictionary/prompts/metrics    pulls these three as top-level modules)
#               copied surgically — NOT the whole repo.
#
# At launch SidecarClient.resolveLaunch() sees this tree and runs
#   oliv-runtime/python/bin/python3  oliv-runtime/root/sidecar/sidecar_server.py
# with OLIV_ROOT=oliv-runtime/root (see sidecar_server.py's layout-resolution
# docstring) and an app-owned HF_HOME.
#
# Pipeline: download+verify CPython -> stage runtime -> pip install the lock
# (minus torch) -> prune fat -> xcodebuild Release -> assemble build/OLIV.app -> embed runtime ->
# hardened-runtime codesign (inner binaries + Sparkle.framework first, then the
# bundle — `--deep` is deprecated; per-binary-class entitlements, see step 4)
# -> smoke-test the BUNDLED python running the BUNDLED sidecar with a ping.
#
# No third-party tools beyond curl/tar/codesign/xcodebuild/python. The CPython
# tarball is cached under build/cache/ so re-runs are offline.

set -euo pipefail

# --------------------------------------------------------------------------- #
# Paths. This script lives in <root>/scripts/, so the repo root is one up.
# --------------------------------------------------------------------------- #
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD="$ROOT/build"
CACHE="$BUILD/cache"
RUNTIME="$BUILD/oliv-runtime"       # staging tree, later copied into the .app
DERIVED="$BUILD/DerivedData"
APP="$BUILD/OLIV.app"               # the assembled, self-contained bundle

# --------------------------------------------------------------------------- #
# Pinned CPython. python-build-standalone publishes relocatable, install_only
# CPython builds; "install_only_stripped" is the smallest runnable form (debug
# symbols removed). Pin the release tag + version + sha256 so the build is
# reproducible and offline after the first fetch. To bump: pick a newer tag from
# https://github.com/astral-sh/python-build-standalone/releases, then record the
# asset's sha256 from that release's SHA256SUMS (or the GitHub API `digest`).
# --------------------------------------------------------------------------- #
PBS_TAG="20260623"
PBS_PYVER="3.11.15"
PBS_ASSET="cpython-${PBS_PYVER}+${PBS_TAG}-aarch64-apple-darwin-install_only_stripped.tar.gz"
# The '+' is percent-encoded (%2B) in the download URL.
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/cpython-${PBS_PYVER}%2B${PBS_TAG}-aarch64-apple-darwin-install_only_stripped.tar.gz"
PBS_SHA256="2318799eaf104f8a29bc09a93b0851b05dbbcb4ce9a5f045ddea169c0c7ff3a5"
TARBALL="$CACHE/$PBS_ASSET"

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[31mBLOCKED: %s\033[0m\n' "$*" >&2; exit 1; }

if [ "$(uname -m)" != "arm64" ]; then
  die "this packages an aarch64-apple-darwin runtime; run on Apple Silicon (got $(uname -m))."
fi

# --------------------------------------------------------------------------- #
# 1. Fetch + verify the CPython tarball (cached for offline re-runs).
# --------------------------------------------------------------------------- #
log "1. CPython ${PBS_PYVER} (python-build-standalone ${PBS_TAG})"
mkdir -p "$CACHE"
verify_tarball() { echo "$PBS_SHA256  $TARBALL" | shasum -a 256 -c - >/dev/null 2>&1; }

if [ -f "$TARBALL" ] && verify_tarball; then
  echo "    cached + verified: $TARBALL"
else
  echo "    downloading $PBS_ASSET ..."
  curl -fSL --retry 3 -o "$TARBALL" "$PBS_URL"
  verify_tarball || die "sha256 mismatch for $PBS_ASSET (expected $PBS_SHA256)."
  echo "    downloaded + sha256 verified."
fi

# --------------------------------------------------------------------------- #
# 2a. Stage python/ = the extracted standalone CPython.
#     install_only tarballs unpack to a top-level python/ dir, so extracting into
#     $RUNTIME yields $RUNTIME/python directly.
# --------------------------------------------------------------------------- #
log "2a. Stage embedded CPython -> $RUNTIME/python"
rm -rf "$RUNTIME"
mkdir -p "$RUNTIME"
tar -xzf "$TARBALL" -C "$RUNTIME"
PYBIN="$RUNTIME/python/bin/python3"
[ -x "$PYBIN" ] || die "extracted CPython missing $PYBIN"
echo "    $("$PYBIN" --version)"

# --------------------------------------------------------------------------- #
# 2b. pip install the proven lock into the embedded interpreter's site-packages
#     — MINUS torch (saves ~450 MB). torch is in the lock only because
#     mlx-whisper DECLARES it as a hard dependency; the only mlx-whisper module
#     that imports it is torch_whisper.py, the HF->MLX weight-conversion path,
#     never touched at runtime (we ship pre-converted MLX repos). Verified
#     empirically: full transcription succeeds with a meta_path hook BLOCKING
#     torch imports. The repo's own torch users (app/stt/pathumma.py's HF
#     backend) import it lazily inside methods and are not the shipped default
#     (pathumma-mlx). If a future mlx-whisper upgrade starts importing torch at
#     runtime, the step-2c verify (imports mlx_whisper/mlx_lm, asserts torch is
#     absent) and the end-of-script ping smoke fail the build loudly.
#
#     Torch-exclusive transitive pins go with it — exclusivity verified with
#     `uv pip tree --invert --python sidecar/.venv/bin/python` (2026-07-07):
#       networkx, sympy, mpmath, setuptools    reachable ONLY via torch
#     NOT excludable (other packages require them): jinja2 + markupsafe
#     (mlx-lm), filelock + fsspec (huggingface-hub), typing-extensions (many).
#
#     The runtime install list is DERIVED from the lock right here (grep -v the
#     excluded pins) so sidecar/requirements.lock stays the single source of
#     truth; the dev sidecar/.venv keeps the full lock (torch there is
#     harmless). --no-deps stops pip from re-pulling torch via mlx-whisper's
#     metadata — safe because the lock is a complete flat pin set.
#
#     All remaining pins are arm64-macOS wheels (no compilation) — if pip ever
#     tries to build from source, that surfaces here and the build BLOCKS.
#
#     W5-T2 runtime slim (2026-07-08) adds hf-xet to the SAME exclusion list.
#     hf-xet is the Rust Xet accelerator huggingface-hub loads LAZILY only when a
#     Xet transfer is active; the sidecar forces HF_HUB_DISABLE_XET=1 on every
#     launch (Session Log 2026-07-07: Xet crawled at ~100 KB/s on real networks),
#     so it is never on the code path. Verified empirically: `import
#     huggingface_hub`, `from huggingface_hub import snapshot_download`, and an
#     offline cached snapshot_download all succeed with hf-xet absent. The step-2c
#     tripwire asserts `import hf_xet` FAILS while the hub still imports.
#
#     numba (9 MB) + llvmlite (124 MB) + scipy (55 MB) are excluded too — ~188 MB
#     — but they need one extra move: the lazy-timing patch right after this
#     install. Their ONLY module-scope importer in the pin set is
#     mlx_whisper/timing.py (`import numba`, `from scipy import signal`), which
#     exists solely for the word-timestamps feature — and OLIV NEVER passes
#     word_timestamps=True. The catch: mlx_whisper/__init__.py imports
#     .transcribe, and transcribe.py eagerly does `from .timing import
#     add_word_timestamps`, so WITHOUT the patch `import mlx_whisper` hard-fails
#     the instant any of the three is absent (confirmed empirically with a
#     meta_path import block — unlike torch, whose only importer torch_whisper.py
#     is NOT reached by __init__). The patch rewrites the STAGED transcribe.py to
#     import .timing lazily inside its `if word_timestamps:` branch; the dev
#     sidecar/.venv keeps the stock wheel + the full lock (same policy as torch).
#     Exclusivity re-verified (uv pip tree --invert, 2026-07-08):
#       numba <- mlx-whisper only; llvmlite <- numba only; scipy <- mlx-whisper
#     only. The other scipy mentions in the set are transformers' lazily-loaded
#     vision-model modules (OLIV never loads them) and numpy's pytest conftest —
#     nothing on the runtime import graph, which the step-2c tripwire (imports +
#     a REAL transcription with all three absent) proves on every build.
# --------------------------------------------------------------------------- #
log "2b. Install the runtime pin set (requirements.lock minus excluded pins) into the embedded runtime"
if ! "$PYBIN" -m pip --version >/dev/null 2>&1; then
  echo "    pip absent in the distro — bootstrapping with ensurepip ..."
  "$PYBIN" -m ensurepip --upgrade
fi
RUNTIME_REQS="$BUILD/requirements.runtime.txt"
grep -vE '^(torch|networkx|sympy|mpmath|setuptools|hf-xet|numba|llvmlite|scipy)==' \
  "$ROOT/sidecar/requirements.lock" > "$RUNTIME_REQS"
echo "    derived $(grep -c '==' "$RUNTIME_REQS")/$(grep -c '==' "$ROOT/sidecar/requirements.lock") lock pins (excluded: torch + networkx, sympy, mpmath, setuptools, hf-xet, numba, llvmlite, scipy)"
# --only-binary=:all: refuses any source build: a wheel that needs compiling
# fails loudly instead of silently invoking a compiler (per the W3-T4 contract).
"$PYBIN" -m pip install --no-input --disable-pip-version-check \
  --no-deps --only-binary=:all: -r "$RUNTIME_REQS" \
  || die "pip install failed — check the failing wheel above (all pins should be arm64 wheels)."
SITE="$RUNTIME/python/lib/python3.11/site-packages"

# --------------------------------------------------------------------------- #
# 2b (cont). Patch the STAGED mlx_whisper so the numba/llvmlite/scipy exclusion
# above holds. transcribe.py's module-level `from .timing import
# add_word_timestamps` exists ONLY for word_timestamps=True — which OLIV never
# passes — yet it drags timing.py's module-scope numba + scipy imports into
# `import mlx_whisper` itself (the eager chain __init__ -> transcribe -> timing
# is what forced ~188 MB into the bundle). Move the import INSIDE the
# `if word_timestamps:` branch, in the STAGED copy only; the dev venv keeps the
# stock wheel. FAILS-LOUD CONTRACT: both rewrites are exact-match, exactly-once
# string surgery — if a future mlx-whisper pin changes the text, the build dies
# BLOCKED right here (never a silent skip); re-derive the patch against the new
# wheel, then re-verify with the step-2c real-transcribe tripwire.
# --------------------------------------------------------------------------- #
log "2b. Patch staged mlx_whisper: make the word-timestamps (.timing) import lazy"
"$PYBIN" - "$SITE" <<'PY' \
  || die "mlx_whisper lazy-timing patch failed — the pinned wheel's transcribe.py changed; re-derive the exact-match strings (see the step-2b patch comment)."
import re
import sys
import pathlib

site = pathlib.Path(sys.argv[1])
f = site / "mlx_whisper" / "transcribe.py"
src = f.read_text(encoding="utf-8")

OLD_IMPORT = "from .timing import add_word_timestamps\n"
NEW_IMPORT = (
    "# [OLIV build patch] .timing imports numba+scipy at module scope; it is\n"
    "# imported lazily in the word_timestamps branch so the bundle can drop them.\n"
)
OLD_CALL = (
    "                if word_timestamps:\n"
    "                    add_word_timestamps(\n"
)
NEW_CALL = (
    "                if word_timestamps:\n"
    "                    from .timing import add_word_timestamps\n"
    "                    add_word_timestamps(\n"
)
for what, needle in (("module-level timing import", OLD_IMPORT),
                     ("word_timestamps call site", OLD_CALL)):
    n = src.count(needle)
    assert n == 1, f"expected exactly 1 occurrence of the {what}, found {n}"
f.write_text(src.replace(OLD_IMPORT, NEW_IMPORT).replace(OLD_CALL, NEW_CALL),
             encoding="utf-8")

# Belt-and-suspenders: after the patch, NO module in the package may import
# timing/numba/scipy at MODULE scope — i.e. at column 0; the indented lazy
# import we just inserted is exactly what must NOT match. (timing.py itself
# still does — that is fine, it is now only reachable through the lazy branch.
# The wheel's inert build/lib/ source-junk copies are not on the import graph.)
offenders = []
for p in sorted((site / "mlx_whisper").glob("*.py")):
    if p.name == "timing.py":
        continue
    for i, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
        if re.match(r"(from\s+\.timing\s+import|import\s+numba|from\s+numba"
                    r"|import\s+scipy|from\s+scipy)", line):
            offenders.append(f"{p.name}:{i}: {line.strip()}")
assert not offenders, \
    "module-scope timing/numba/scipy imports remain: " + "; ".join(offenders)
print("    PATCH_OK: transcribe.py now imports .timing lazily; "
      "no other module-scope numba/scipy imports in mlx_whisper")
PY

# --------------------------------------------------------------------------- #
# 2b (cont). Prune the obvious fat. Keep *.dist-info (cheap, and some libs read
# their own metadata at runtime); drop __pycache__, .pyc, and tests/ dirs inside
# site-packages (never imported by the sidecar).
# --------------------------------------------------------------------------- #
log "2b. Prune __pycache__ / *.pyc / tests under site-packages"
find "$RUNTIME/python" -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
find "$RUNTIME/python" -type f -name '*.pyc' -delete 2>/dev/null || true
find "$SITE" -type d -name 'tests' -prune -exec rm -rf {} + 2>/dev/null || true
echo "    runtime size after prune: $(du -sh "$RUNTIME/python" | cut -f1)"

# --------------------------------------------------------------------------- #
# 2b (cont). W5-T2 runtime slim — prune build-time-only tooling and unused data
# from the STAGED runtime ONLY (the dev sidecar/.venv keeps everything, same
# policy as torch). Each cut is safe because the runtime NEVER installs packages
# and NEVER walks the pruned code paths; the step-2c tripwire + the ping smoke +
# the packaged e2e re-prove every survivor.
# --------------------------------------------------------------------------- #
log "2b. Slim the staged runtime (pip/setuptools/ensurepip, mlx C++ headers, pythainlp corpora)"

# (i) pip + setuptools (+ their siblings) + ensurepip: the runtime resolves no
#     dependencies and compiles no extensions, so the whole install toolchain is
#     dead weight once the pip install above has finished. setuptools was already
#     kept OUT of the runtime pin set by the step-2b filter; this also removes any
#     copy the CPython distro / the ensurepip pip-bootstrap left behind. (Nothing
#     on OLIV's runtime import graph pulls pip/setuptools/pkg_resources — the only
#     references live in cffi/numpy/mlx BUILD helpers that a running import never
#     touches; the step-2c import of mlx_whisper/mlx_lm/pythainlp proves it.)
rm -rf "$SITE"/pip "$SITE"/pip-*.dist-info \
       "$SITE"/setuptools "$SITE"/setuptools-*.dist-info \
       "$SITE"/pkg_resources "$SITE"/_distutils_hack \
       "$RUNTIME/python/lib/python3.11/ensurepip" 2>/dev/null || true
# setuptools drops distutils-precedence.pth, which site.py runs at EVERY
# interpreter startup; with _distutils_hack gone it would spew a ModuleNotFound
# traceback to stderr on every launch (harmless but noisy), so remove it too.
rm -f "$SITE"/distutils-precedence.pth 2>/dev/null || true
rm -f "$RUNTIME/python"/bin/pip "$RUNTIME/python"/bin/pip3 "$RUNTIME/python"/bin/pip3.* 2>/dev/null || true

# (ii) mlx C++ headers (mlx/include/**: metal_cpp / mlx / jaccl): shipped only for
#      BUILDING custom C++ MLX extensions. The Python runtime dlopen()s the
#      prebuilt .so and never reads a header.
rm -rf "$SITE/mlx/include" 2>/dev/null || true

# (iii) pythainlp corpora: OLIV's cleanup uses ONLY the newmm tokenizer + the
#       thai_words() dictionary (pipeline/dictionary gate + boundary guard,
#       metrics WER). Traced with sys.addaudithook("open") over the FULL gate
#       (test_dictionary + test_pipeline_guardrails + test_pipeline_spacing +
#       clean_ex internals): the ONLY corpus DATA files opened are words_th.txt
#       (the ~62k-word newmm/thai_words dictionary) and stopwords_th.txt. Keep an
#       ALLOWLIST (those two + the tiny default_db.json catalog + all *.py code)
#       and delete every other data blob (wikipedia_titles 12M, wordnet db 11M,
#       POS taggers, ONNX/CRF models, volubilis/tnc/ttc freq lists, ...). Allowlist
#       not blocklist, so a future pythainlp that adds a new blob still slims; the
#       step-2c tripwire (thai_words()>10000 + a real newmm tokenize) is the
#       backstop. No runtime-download risk: get_corpus reads these two straight
#       from the bundled corpus/ dir (no network), and nothing on OLIV's path ever
#       requests a pruned corpus, so pythainlp's download fallback is never reached.
CORPUS="$SITE/pythainlp/corpus"
if [ -d "$CORPUS" ]; then
  find "$CORPUS" -maxdepth 1 -type f \
    ! -name '*.py' ! -name 'default_db.json' \
    ! -name 'words_th.txt' ! -name 'stopwords_th.txt' \
    -delete 2>/dev/null || true
fi
echo "    runtime size after slim: $(du -sh "$RUNTIME/python" | cut -f1)   (pythainlp corpus now $(du -sh "$CORPUS" 2>/dev/null | cut -f1))"

# --------------------------------------------------------------------------- #
# 2c. Stage root/ = the minimal source tree the sidecar imports. Copy file-by-
#     file (never the whole repo) so nothing dev-only leaks in and there are no
#     __pycache__ dirs to carry.
# --------------------------------------------------------------------------- #
log "2c. Stage the minimal source tree -> $RUNTIME/root"
RTROOT="$RUNTIME/root"
mkdir -p "$RTROOT/sidecar" "$RTROOT/app/stt" "$RTROOT/benchmark"
cp "$ROOT/sidecar/sidecar_server.py"  "$ROOT/sidecar/thai_format.py"  "$RTROOT/sidecar/"
cp "$ROOT/app/__init__.py"                  "$RTROOT/app/"
# All backend modules via glob, not a whitelist: app/stt/__init__.py imports
# every registered backend, so a module missing from the staged tree fails the
# self-containment check below as a hard BLOCKED — exactly what happened when
# groq_cloud.py (the W3-T4 cloud tier) landed after a hardcoded list.
cp "$ROOT"/app/stt/*.py "$RTROOT/app/stt/"
cp "$ROOT/benchmark/pipeline.py"  "$ROOT/benchmark/dictionary.py" \
   "$ROOT/benchmark/prompts.py"   "$ROOT/benchmark/metrics.py"    \
   "$ROOT/benchmark/phonetic.py"                                  "$RTROOT/benchmark/"

# Verify self-containment: import EVERYTHING the sidecar loads using ONLY the
# staged tree + the embedded site-packages. PYTHONSAFEPATH=1 keeps cwd off
# sys.path, and we run from / so the dev repo can't sneak in; we then assert each
# module resolved from under $RTROOT (not the dev app/ or benchmark/).
log "2c. Verify the staged tree imports self-contained (no dev repo on sys.path)"
# PYTHONDONTWRITEBYTECODE keeps this verify import from littering the staged tree
# with __pycache__ (it must ship source-only).
( cd / && PYTHONSAFEPATH=1 PYTHONDONTWRITEBYTECODE=1 HF_HUB_OFFLINE=1 OLIV_ROOT="$RTROOT" "$PYBIN" - "$RTROOT" <<'PY'
import sys, os
rtroot = sys.argv[1]
# Only the staged tree — mirrors sidecar_server.py's sys.path setup. The sidecar/
# dir is added here explicitly because at runtime Python auto-prepends the script's
# own directory ($RTROOT/sidecar) for `from thai_format import ...`; PYTHONSAFEPATH
# suppresses that auto-add under this stdin heredoc, so reproduce it by hand.
sys.path.insert(0, os.path.join(rtroot, "benchmark"))
sys.path.insert(0, rtroot)
sys.path.insert(0, os.path.join(rtroot, "sidecar"))
import app, app.stt
from app.stt import build_backend
import pipeline, dictionary, prompts, metrics
# thai_format is a sidecar/*.py sibling module the sidecar imports at top level
# (deterministic Thai post-pass); catch a future sidecar module missing from 2c's
# copy list HERE, at build time, not at the final ping smoke.
import thai_format
for m in (app, app.stt, pipeline, dictionary, prompts, metrics, thai_format):
    f = getattr(m, "__file__", "") or ""
    assert f.startswith(rtroot), f"{m.__name__} loaded from OUTSIDE the staged tree: {f}"
# build the default engine's backend class (does NOT load weights) to prove the
# import graph the sidecar actually walks is intact.
assert build_backend  # factory present
# The runtime ships torch-free (see step 2b): torch must NOT be importable ...
try:
    import torch
except ImportError:
    pass
else:
    raise AssertionError("torch is importable — the torch-free exclusion did not take effect")
# ... and the heavy modules the dictate path ACTUALLY loads must import without
# it. This is the tripwire for a future mlx-whisper that imports torch at
# runtime: it fails HERE, at build time, not on a user's machine.
import mlx_whisper
import mlx_lm
# W5-T2 slim tripwire. (a) The excluded hf-xet must be ABSENT, while the hub that
# used it lazily still imports (HF_HUB_DISABLE_XET=1 keeps Xet off the path).
try:
    import hf_xet
except ImportError:
    pass
else:
    raise AssertionError("hf_xet is importable — the hf-xet exclusion did not take effect")
import huggingface_hub  # noqa: F401
from huggingface_hub import snapshot_download  # noqa: F401
# (b) pythainlp survives the corpus prune: the newmm tokenizer + thai_words()
# dictionary (the ONLY corpus OLIV loads) must still resolve from the pruned tree.
import pythainlp  # noqa: F401
from pythainlp.corpus import thai_words
from pythainlp.tokenize import word_tokenize
_tw = thai_words()
assert len(_tw) > 10000, f"thai_words() collapsed to {len(_tw)} — corpus prune broke the dictionary"
_toks = word_tokenize("ทดสอบการตัดคำ", engine="newmm", keep_whitespace=False)
assert len(_toks) >= 2 and "".join(_toks) == "ทดสอบการตัดคำ", f"newmm tokenize looks wrong: {_toks}"
# (c) the lazy-timing patch (step 2b) is what lets numba/llvmlite/scipy drop:
# all three must be ABSENT (mlx_whisper already imported fine above).
for _name in ("numba", "llvmlite", "scipy"):
    try:
        __import__(_name)
    except ImportError:
        pass
    else:
        raise AssertionError(f"{_name} is importable — the numba/llvmlite/scipy exclusion did not take effect")
# (d) a REAL (tiny) transcription must succeed with all three absent — the
# tripwire both for the patch itself and for a future mlx-whisper whose decode
# path starts touching numba/scipy at runtime. Offline by construction
# (HF_HUB_OFFLINE=1 above): resolve the already-cached STT snapshot from the dev
# HF cache or the app-owned store, and BLOCK with a clear message if neither has
# it — this build step needs the model fetched once (any benchmark run or the
# sidecar download cmd does it). word_timestamps stays default-False: the lazy
# branch must NOT fire, exactly like every OLIV dictate.
_repo = "kinoppy555/Pathumma-whisper-th-large-v3-mlx"
_app_hub = os.path.expanduser("~/Library/Application Support/OLIV/models/hub")
_model_path = None
for _cache in (None, _app_hub):
    try:
        _model_path = snapshot_download(_repo, local_files_only=True, cache_dir=_cache)
        break
    except Exception:
        continue
assert _model_path, (
    f"STT model {_repo} is not cached locally (checked the default HF cache and {_app_hub}); "
    "the real-transcribe tripwire needs it — fetch it once (run a benchmark or the sidecar "
    "download cmd), then re-run the build"
)
import numpy as _np
_res = mlx_whisper.transcribe(_np.zeros(4800, dtype=_np.float32),
                              path_or_hf_repo=_model_path, temperature=0.0)
assert isinstance(_res.get("text"), str), f"transcribe returned no text field: {_res!r}"
print("    IMPORT_OK: app.stt + pipeline/dictionary/prompts/metrics all from", rtroot)
print("    TORCH_FREE_OK: torch absent; mlx_whisper + mlx_lm import without it")
print("    SLIM_OK: hf_xet absent; huggingface_hub imports; pythainlp newmm+thai_words(%d) intact" % len(_tw))
print("    LAZY_TIMING_OK: numba/llvmlite/scipy absent; REAL transcribe ran (text=%r)" % _res["text"][:40])
PY
) || die "staged tree failed self-contained import — a needed module is missing."
# Belt-and-suspenders: the staged source tree ships source-only, no __pycache__.
find "$RTROOT" -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true

# --------------------------------------------------------------------------- #
# 3. Build the app (Release, ad-hoc signed per project.yml) and assemble the
#    self-contained bundle: copy the built .app, then embed oliv-runtime.
# --------------------------------------------------------------------------- #
log "3. xcodebuild Release"
xcodebuild -project "$ROOT/macos/OLIV.xcodeproj" -scheme OLIV \
  -configuration Release -derivedDataPath "$DERIVED" build \
  | tail -n 20   # keep the log short; the exit code (pipefail) is what gates us

APP_SRC="$DERIVED/Build/Products/Release/OLIV.app"
[ -d "$APP_SRC" ] || die "xcodebuild produced no app at $APP_SRC"

log "3. Assemble $APP + embed oliv-runtime"
rm -rf "$APP"
cp -R "$APP_SRC" "$APP"
# A menu-bar app with no asset catalog ships without Contents/Resources — create
# it before embedding the runtime.
mkdir -p "$APP/Contents/Resources"
cp -R "$RUNTIME" "$APP/Contents/Resources/oliv-runtime"

# --------------------------------------------------------------------------- #
# 4. Codesign under the HARDENED RUNTIME (W5-T1 — notarization precondition).
#    `--deep` is deprecated, so we sign bottom-up: inner Mach-O (dylibs, .so,
#    the interpreter), then Sparkle.framework's nested code, then the framework,
#    then the outer bundle — each outer seal covers the re-signed inner code.
#    Everything gets `--options runtime`; the only thing to flip for Developer ID
#    later is OLIV_SIGN_IDENTITY (entitlements + runtime already match), which
#    is exactly the "config change" W5-T1 was built to leave behind.
#
#    ENTITLEMENTS come in two classes (dylibs/.so get NONE — they inherit the
#    loader's; only LAUNCHED Mach-O executables carry entitlements):
#      APP_ENT (macos/OLIV.entitlements) -> the outer .app. Just
#        com.apple.security.device.audio-input: the hardened runtime BLOCKS the
#        mic without it, and OLIV is a dictation app. Kept minimal on purpose.
#      PY_ENT  (macos/OLIVPython.entitlements) -> the embedded CPython
#        interpreter (python3.11), the process that runs the ML stack. Three keys,
#        each a real hardened-runtime exception this workload needs:
#          - cs.allow-jit                       MLX JIT-compiles Metal kernels at
#                                               runtime (MAP_JIT executable pages).
#          - cs.allow-unsigned-executable-memory belt-and-suspenders for codegen
#                                               paths that map W+X without MAP_JIT.
#          - cs.disable-library-validation      CPython dlopen()s ~170 native
#                                               wheels (.so/.dylib); an embedded
#                                               interpreter loading arbitrary
#                                               native code needs this to be robust.
#    (AMFI's entitlements parser rejects XML comments, so the .entitlements plists
#     themselves are comment-free — the justification lives here, at the use site.)
# --------------------------------------------------------------------------- #
# Identity: prefer a STABLE identity over ad-hoc. Ad-hoc re-signing changes the
# CDHash on every rebuild, and macOS TCC keys Input Monitoring / Accessibility
# grants to the code signature — so every rebuild silently orphaned the user's
# grants (System Settings showed them ON while the OS ignored the app; found in
# 🧑 smoke as a "flaky hotkey" + a stuck warning badge). An Apple Development
# certificate keeps the identity constant across rebuilds, so grants survive.
# Ad-hoc ("-") + hardened runtime is a valid local combo (just not notarizable).
IDENTITY="${OLIV_SIGN_IDENTITY:-Apple Development}"
if ! security find-identity -p codesigning -v | grep -q "$IDENTITY"; then
  echo "    WARNING: signing identity '$IDENTITY' not found — falling back to ad-hoc"
  echo "             (TCC permission grants will NOT survive rebuilds)"
  IDENTITY="-"
fi
APP_ENT="$ROOT/macos/OLIV.entitlements"
PY_ENT="$ROOT/macos/OLIVPython.entitlements"
[ -f "$APP_ENT" ] || die "missing app entitlements: $APP_ENT"
[ -f "$PY_ENT" ]  || die "missing python entitlements: $PY_ENT"
log "4. Codesign (hardened runtime) with identity: $IDENTITY"
RT="$APP/Contents/Resources/oliv-runtime"

# 4a. Every dylib/.so in the WHOLE bundle (embedded runtime + Sparkle.framework):
#     hardened runtime, no entitlements.
signed=0; failed=0
while IFS= read -r -d '' f; do
  if codesign --force --options runtime -s "$IDENTITY" "$f" >/dev/null 2>&1; then signed=$((signed+1)); else failed=$((failed+1)); fi
done < <(find "$APP" -type f \( -name '*.dylib' -o -name '*.so' \) -print0)
echo "    dylib/.so signed (runtime, no entitlements): $signed  (failed: $failed)"
[ "$failed" -eq 0 ] || die "$failed native libraries failed to sign — an incompletely signed bundle must not continue toward notarization/publish."

# 4b. The embedded CPython interpreter — the runtime's only Mach-O EXECUTABLE
#     (python3.11; python3/python are symlinks to it). Gets PY_ENT. We detect
#     Mach-O so the text wrapper scripts in bin/ (hf, mlx_lm, *-config — python
#     source run BY the interpreter, not launched) never get interpreter
#     entitlements; they're sealed as ordinary resources by the bundle seal.
pysigned=0
while IFS= read -r -d '' f; do
  if file -b "$f" | grep -q 'Mach-O'; then
    codesign --force --options runtime --entitlements "$PY_ENT" -s "$IDENTITY" "$f" && pysigned=$((pysigned+1))
  fi
done < <(find "$RT/python/bin" -type f ! -type l -perm +111 -print0)
echo "    python interpreter Mach-O signed (runtime + interpreter entitlements): $pysigned"

# 4c. Sparkle.framework (W5-T1). xcodebuild embeds it ad-hoc + no-runtime (the
#     compile step stays ad-hoc on purpose, project.yml); re-sign its nested code
#     bottom-up, then the framework, so it's hardened + notarization-ready.
FW="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$FW" ]; then
  FWV="$FW/Versions/Current"
  for xpc in "$FWV"/XPCServices/*.xpc; do
    # --preserve-metadata=entitlements keeps whatever entitlements Sparkle shipped
    # its XPC services with (currently none) instead of stripping them.
    [ -e "$xpc" ] && codesign --force --options runtime --preserve-metadata=entitlements -s "$IDENTITY" "$xpc"
  done
  [ -e "$FWV/Autoupdate" ]  && codesign --force --options runtime -s "$IDENTITY" "$FWV/Autoupdate"
  [ -d "$FWV/Updater.app" ] && codesign --force --options runtime -s "$IDENTITY" "$FWV/Updater.app"
  codesign --force --options runtime -s "$IDENTITY" "$FW"   # seals + signs Versions/Current/Sparkle
  echo "    Sparkle.framework re-signed (runtime): nested XPC/Autoupdate/Updater + framework"
else
  echo "    NOTE: no Sparkle.framework embedded — Sparkle auto-update will be inert"
fi

# 4d. Seal the app bundle LAST: hardened runtime + the app entitlements.
codesign --force --options runtime --entitlements "$APP_ENT" -s "$IDENTITY" "$APP"
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /' || true

# --------------------------------------------------------------------------- #
# 5. Smoke: spawn the BUNDLED python on the BUNDLED sidecar with the bundle's
#    OLIV_ROOT, send a ping, assert an ok reply. ping loads no models, so this
#    is fast + offline; stdin EOF makes the sidecar exit cleanly (no orphan).
#    PYTHONDONTWRITEBYTECODE mirrors what the app passes at runtime so this smoke
#    does not write __pycache__ into the freshly-sealed bundle (which would
#    invalidate the signature we just applied).
# --------------------------------------------------------------------------- #
log "5. Smoke-test the bundled sidecar (ping)"
BPY="$RT/python/bin/python3"
BROOT="$RT/root"
SMOKE="$(printf '{"cmd":"ping"}\n' | env PYTHONDONTWRITEBYTECODE=1 OLIV_ROOT="$BROOT" "$BPY" "$BROOT/sidecar/sidecar_server.py")"
echo "    reply: $SMOKE"
echo "$SMOKE" | env PYTHONDONTWRITEBYTECODE=1 "$BPY" -c \
  "import sys,json; o=json.loads(sys.stdin.readline()); assert o.get('ok') is True, o; print('    SMOKE OK — bundled sidecar replied ok, pid=%s' % o.get('pid'))" \
  || die "bundled-sidecar ping smoke failed."
# The seal must survive the smoke (nothing was written into Resources).
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /' \
  || die "bundle signature invalid after smoke (the runtime was mutated)."

# --------------------------------------------------------------------------- #
# Done. Report sizes.
# --------------------------------------------------------------------------- #
log "DONE"
echo "    embedded runtime: $(du -sh "$RT" | cut -f1)   ($RT)"
echo "    OLIV.app      : $(du -sh "$APP" | cut -f1)   ($APP)"
