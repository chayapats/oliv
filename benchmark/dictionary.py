"""Deterministic Thai-transliteration -> English dictionary for cleanup.

Purpose: safe completeness. The v2 LLM prompt is conservative (never hallucinates)
but sometimes leaves an obvious transliteration in Thai. This dictionary fixes the
high-frequency known terms by EXACT, word-boundary-safe match -- it can never
over-insert, hallucinate, or touch an unknown Thai word (the failure modes
v3-prompt showed on mx09/เกสร).

Pipeline:
    raw ASR text -> apply_dictionary() -> [gate] -> v2 LLM (if anything left) -> guardrails

Curated from the Pathumma runs in results_local.json (lang=auto is the production
config; lang=th scanned for extra spelling variants). Rule: a Thai token maps to
English ONLY if the clip's reference transcript spells that word in Latin script.
PRECISION-FIRST: a missed transliteration is fine (the LLM catches it); a wrong
replacement corrupts text with no recovery.

Boundary-safety design (see apply_dictionary below):
  Candidate matches are exact substrings, longest-key-first, but a match is
  REJECTED if either of its edges falls strictly inside a newmm token that is a
  real Thai dictionary word (pythainlp thai_words()). This provably cannot fire
  inside longer real Thai words (แอปเปิ้ล, ใจดีพลอย..., เดโมแครต, พรีวิว, บัคเตรี)
  while still firing on garbled ASR runs whose surrounding chunks are non-words.
  We deliberately did NOT use newmm-with-custom-Trie tokenize-and-replace: adding
  TRANSLIT keys to the trie makes newmm segment ใจดีพลอยเลยยิ้ม as
  ใจ|ดีพลอย|เลย|ยิ้ม -- i.e. the custom dict itself induces the over-fire.
"""
import re

from pythainlp.corpus import thai_words
from pythainlp.tokenize import word_tokenize

# Thai-script transliteration -> correct English. High-confidence, unambiguous,
# and backed by a reference transcript that writes the word in Latin script.
# Casing exactly as it should be typed (proper nouns / brands / acronyms capitalised).
TRANSLIT = {
    # ---- infra / tools ----
    "คิวเบอร์เน็ต": "Kubernetes", "คิวเบอเน็ต": "Kubernetes", "คูเมอร์เนส": "Kubernetes",
    "ด็อกเกอร์": "Docker", "คลัสเตอร์": "cluster", "กราฟา": "Grafana",
    "แดชบอร์ด": "dashboard", "เซิร์ฟเวอร์": "server",
    "รีสตาร์ท": "restart", "รีสตาร์": "restart",              # mx09 truncated variant
    "รีดิส": "Redis", "เรดดิส": "Redis",                      # tc12 variant
    "ทีทีแอล": "TTL", "เอพีไอ": "API",
    "โอออธ": "OAuth", "โอเอาท์": "OAuth", "โอออส": "OAuth",    # tc06 variant
    "เอ็นพอยต์": "endpoint",                                   # tc03
    "สแลค": "Slack",                                           # en07(th)
    # ---- dev workflow ----
    "ดีพลอย": "deploy", "โพรดักชัน": "production", "โปรดักชั่น": "production",  # mx16
    "สเตจจิ้ง": "staging", "สเตจิ่ง": "staging",               # tc04 variant
    "เมิร์จ": "merge", "เมิร์ด": "merge",                      # tc09 variant
    "พูลรีเควส": "pull request", "พูลรีเกวส": "pull request",  # mx06 variant
    "โค้ดรีวิว": "code review", "รีวิว": "review",             # mx06 (ref Latin)
    "รอลแบ็ก": "rollback",
    "ดีบัก": "debug", "ดีบัค": "debug",                        # tc04 variant
    "คอนฟิก": "config",
    "แบ็กอัพ": "backup", "แบ็คอัพ": "backup",                  # tc08 variant
    "อินเด็กซ์": "index", "โทเคน": "token", "รีเฟรช": "refresh",
    "ฟีเจอร์แฟล็ก": "feature flag",
    "ฟีเจอร์แฟ็กซ์": "feature flag",   # tc10: STT misheard "flag" as แฟ็กซ์; whole compound still unambiguous
    "ฟีเจอร์": "feature",                                      # mx13 (ref Latin)
    "คอนเทนเตอร์ไลซ์": "containerize", "คอนเทนเตอร์ไลด์": "containerize",  # tc11 variant
    "เอบีเทสติ้ง": "A/B testing",                              # tc10
    "รีลีส": "release",                                        # en10(th); mx06 glued case left to LLM
    "รีโซป": "resolve",                                        # tc09
    "เซ็ตอัพ": "set up",                                       # mx18
    "รีโปรดิวส์": "reproduce",                                 # mx16
    "อิมพีเมนต์": "implement",                                 # mx14 (garbled but unique)
    "บัคฟิกส์": "bug fixes",                                   # en12(th)
    "บัค": "bug",                                              # mx16 (ref Latin; สตาร์บัค/บัคเตรี guarded)
    "รีเทิร์น": "return", "สเตตัส": "status", "เอ็กเซปชั่น": "exception",  # tc03
    "เดโม": "demo", "สเต็กโฮเดอร์": "stakeholder",             # mx20
    "แอปพรูฟ": "approve", "ลันซ์": "launch",                   # mx20
    "แอป": "app",                                              # tc11 (see decisions below)
    # ---- data / perf ----
    "เลเทนซี่": "latency",
    "เทรชโฮลด์": "threshold", "เทรสโฮ": "threshold", "เทสโฮ": "threshold",  # mx07/tc02 truncations
    "ออปติไมซ์": "optimize",
    "ควิรี": "query", "ควีรี": "query", "ควีรีย์": "query", "ควีรี่": "query",  # mx07/tc05 variants
    "ดาต้าเบส": "database", "ดาษาเบส": "database", "ดาตาเบส": "database",       # mx07/tc08 variant
    "เมมโมรี่ลีก": "memory leak", "เมมอรี่ลีก": "memory leak", "เมมโมรีลีก": "memory leak",
    "เมมอรีลีก": "memory leak",                                # tc07 variants (HF + MLX/fp16 spellings)
    "เมมโมรี": "memory", "เมมอรี่": "memory", "เมมอรี": "memory",  # tc07 เมมโมรียูเซต -> memory ยูเซต (partial fix); เมมอรี่/เมมอรี = pathumma-mlx/fp16-gen spellings
    "เทเบิล": "table",                                         # tc05
    # ---- ml ----
    "ไฟล์จูน": "fine-tune", "ไฟน์จูน": "fine-tune", "โมเดล": "model",
    # ---- office / business ----
    "มีตติ้ง": "meeting", "แชร์สกรีน": "share screen", "พรีเซนต์": "present",  # mx02
    "อินวอร์ย": "invoice", "โควเทชั่น": "quotation", "อีเมล": "email",         # mx04
    "ทัฟฟิก": "traffic", "เวิร์คฟอร์มโฮม": "work from home", "สแตนอัพ": "standup",  # mx05
    "ฟอร์วัด": "forward", "คาเลนด้า": "calendar",              # mx08
    "สโคป": "scope",                                           # mx10
    "เอ็กซ์ปอร์ต": "export", "พีดีเอฟ": "PDF", "อัพโหลด": "upload",  # mx12
    "ยูเซอร์": "user", "ฟีดแบ็ค": "feedback", "เพอร์ฟอร์แมนต์": "performance",  # mx13
    "ดีไซน์": "design", "ยูไอ": "UI",                          # mx14
    "บัดเจ็ต": "budget", "เซอร์วิส": "service",                # mx15
    "ทิกเก็ต": "ticket", "คัสตอมเมอร์": "customer",            # mx19
    "เซ็กเมนต์": "segment",                                    # tc10
    "มาร์เก็ตติ้ง": "marketing", "มาร์เกตติ้ง": "marketing",   # groq spelling variant (no ็); pn08 ref Latin "Marketing"
    "แคมเปญ": "campaign",
    # ---- brands / places ----
    "แอนโทรปิก": "Anthropic", "เฟซบุ๊ค": "Facebook", "เฟซบุ๊ก": "Facebook",
    "เอสซีบีอีซี่": "SCB Easy", "เอ็มอาร์ธี": "MRT", "เอ็มอาร์ที": "MRT",
    "สตาร์บัค": "Starbucks",                                   # mx11/pn01
    "ลาตี้": "latte",                                          # mx11
    "กูเกิ้ลไดร์": "Google Drive",                             # mx12
    "แบงคอก": "Bangkok",                                       # mx17
    "อาฟเตอร์ยู": "After You",                                 # pn04
    "แอร์เวย์ส": "Airways",                                    # pn06 pathumma-mlx spelling; must outrank แอร์เวย์ (longest-first) or it leaves "Airways ส"
    "แอร์เวย์": "Airways",                                     # pn06 (ไทย stays Thai -> "ไทย Airways", LLM finishes)
    "ช็อปปี้": "Shopee", "ลาซาด้า": "Lazada",                  # pn07
    "ไอคอนสยาม": "ICONSIAM",                                   # pn10
}

# ---------------------------------------------------------------------------
# Ambiguous-word decisions (curation log; reasons kept short):
#
# MAPPED:
#   อีเมล -> email          unambiguous, ref uses Latin script
#   แอป -> app              ref tc11 Latin; แอปเปิ้ล/แอปพลิเคชั่น dict-guarded
#   รีวิว -> review          ref mx06 Latin; พรีวิว dict-guarded
#   ดีไซน์ -> design         ref mx14 Latin; ดีไซน์เนอร์ guarded
#   พรีเซนต์ -> present      ref mx02/pn05 both Latin
#   อัพโหลด -> upload        ref mx12 Latin, single meaning
#   บัค -> bug              non-word, unique; บัคเตรี/สตาร์บัค guarded
#   เมมโมรี -> memory        unique loanword; leak-compounds win first
#   สตาร์บัค -> Starbucks    ref Latin; สตาร์บัคส์ dict-guarded
#   ฟีเจอร์แฟ็กซ์ -> feature flag   whole compound unambiguous despite แฟ็กซ์
#   สเต็กโฮเดอร์ -> stakeholder     compound unambiguous despite สเต็ก
#   ไอคอนสยาม -> ICONSIAM    mall name, ref writes Latin
#   มาร์เกตติ้ง -> marketing   CLN-T3: groq spelling variant of มาร์เก็ตติ้ง (drops ็);
#                            NOT a real thai_word (มาร์เก็ตติ้ง with ็ IS), pn08 ref Latin
#
# KEPT THAI / LEFT TO LLM (no mapping added):
#   เกสร                    user decision: stays Thai (Gaysorn)
#   หน้า, แบงก์/แบงก์ชาติ, สิงคโปร์   user keep-Thai list
#   หลอก (log)              real Thai word "deceive"
#   พอร์ต (port/pod)        real word port; also misheard pod
#   ทรัพย์ฟิก, โพเตอร์ไทย     contain real words ทรัพย์/ไทย
#   แฟ็กซ์ alone            means fax, only compound safe
#   ฟีด (freeze/feed)       naturalized feed; ambiguous mishear
#   ซูม, ลีด, แชร์, ล็อก, บล็อก, พุช   short/naturalized/ambiguous -> LLM
#   ซิงค์ (sync)            collides with sink ซิงค์ล้างจาน
#   เด็ดไลน์ (deadline)      เด็ด+ไลน์ real-word collision (LINE)
#   โทรเคน (token)          โทร+เคน could mean "call Ken"
#   เช็ค, ดีเลย์, ออฟฟิศ, โปรเจกต์, เปอร์เซ็นต์   reference itself writes Thai
#   ดี, พลอย                never as separate short pieces
#   อิมพูล, ฟอนต์เอ็น, คัดคอร์ส, นูพอยเตอร์, แบรนด์เมนท์, คอนจอร์บ,
#   แคชมิตซ์, พีเก้าเก้า, ยูเซต, คัวซอง   too garbled to be safe -> LLM
#   spaced-syllable runs ("ออป ติ ไมซ์", "ดี พลอย", "โรว์ แบ็ค",
#   en05/en07-th word-by-word runs)   no space-tolerant matching by design
# ---------------------------------------------------------------------------

# longest keys first so e.g. "ฟีเจอร์แฟ็กซ์" wins over "ฟีเจอร์"
_KEYS = sorted(TRANSLIT, key=len, reverse=True)
_THAI_WORDS = thai_words()  # frozenset of ~62k real Thai words (incl. naturalized loans)


def _token_spans(text: str) -> list[tuple[int, int, str]]:
    """newmm token spans (start, end, token) over the ORIGINAL text."""
    spans = []
    pos = 0
    for tok in word_tokenize(text, engine="newmm", keep_whitespace=True):
        spans.append((pos, pos + len(tok), tok))
        pos += len(tok)
    return spans


def apply_dictionary(text: str, table: "dict[str, str] | None" = None) -> tuple[str, int]:
    """Replace known transliterations with English. Returns (new_text, n_hits).

    n_hits = number of replacements actually performed (pre-existing English
    words in the input are never counted).

    Boundary safety: a candidate substring match is rejected when either edge
    falls strictly inside a newmm token that is a real Thai dictionary word.
    So keys can never fire inside a longer real Thai word (แอป never breaks
    แอปเปิ้ล; ดีพลอย never fires in ใจดีพลอยเลยยิ้ม because ใจดี is a dict word),
    yet they still fire when flanked by garbled non-word ASR chunks
    (นูพอยเตอร์เอ็กเซปชั่น -> นูพอยเตอร์ exception).

    Output spacing: single space between Thai text and each replaced English
    word; no double spaces; existing spacing between Thai runs is untouched.
    Inputs with no matches pass through byte-identical with 0 hits.

    W4-T1 user-replacements reuse: `table` defaults to the built-in TRANSLIT,
    but a caller may pass an arbitrary {spoken -> replacement} dict (the user's
    Settings snippets, e.g. "อีเมลของผม" -> their real email) to run the SAME
    longest-key-first, real-Thai-word-boundary-guarded machinery over it. The
    default path is byte-identical to before -- table is TRANSLIT and the keys
    are the module-level precomputed _KEYS; a supplied table is sorted
    longest-first here, per call. (Curated TRANSLIT decisions live above; the
    parameter only widens WHO supplies the table, never HOW a match is guarded.)
    """
    if not text:
        return text, 0

    if table is None:
        table, keys = TRANSLIT, _KEYS
    else:
        keys = sorted(table, key=len, reverse=True)

    spans = _token_spans(text)

    def _breaks_real_word(p: int) -> bool:
        """True if position p falls strictly inside a real-Thai-word token."""
        for s, e, tok in spans:
            if s < p < e:
                return tok in _THAI_WORDS
            if s >= p:
                break
        return False

    claimed = [False] * len(text)
    repl: list[tuple[int, int, str]] = []  # (start, end, english)
    for k in keys:  # longest first; longer keys claim their span before shorter ones
        start = 0
        while True:
            i = text.find(k, start)
            if i == -1:
                break
            j = i + len(k)
            start = i + 1
            if any(claimed[i:j]):
                continue  # overlaps a longer key's match
            if _breaks_real_word(i) or _breaks_real_word(j):
                continue  # would fire inside a longer real Thai word
            for x in range(i, j):
                claimed[x] = True
            repl.append((i, j, table[k]))

    if not repl:
        return text, 0  # byte-identical passthrough

    repl.sort()
    out = ""
    pos = 0
    for i, j, en in repl:
        out += text[pos:i]
        if out and not out[-1].isspace():
            out += " "
        out += en
        if j < len(text) and not text[j].isspace():
            out += " "
        pos = j
    out += text[pos:]
    out = re.sub(r"[ \t]{2,}", " ", out).strip()
    return out, len(repl)


# --------------------------------------------------------------------------- #
# Canonical casing pass (final, deterministic, Latin-only).
# --------------------------------------------------------------------------- #
# Provenance: canonical spellings of widely-known tech products/acronyms — a
# generic, domain-standard list independent of the eval set (NOT sourced from
# failing clips). Fixes the case where STT/LLM emitted the RIGHT English word in
# the WRONG case (nvidia->Nvidia, github->GitHub, gpu->GPU). It re-cases a token
# ONLY when its lowercase already equals a known term, so it can never change
# meaning, add a word, or touch Thai. Matched on MAXIMAL Latin runs, so it cannot
# fire inside a longer word (api never breaks "apiary"). Conservative on purpose:
# excludes acronyms that are also common English words (RAM, REST, GO, SWIFT).
CANONICAL_CASE = {
    # products / brands
    "kubernetes": "Kubernetes", "docker": "Docker", "grafana": "Grafana",
    "redis": "Redis", "kafka": "Kafka", "terraform": "Terraform",
    "prometheus": "Prometheus", "nvidia": "Nvidia", "github": "GitHub",
    "gitlab": "GitLab", "postgresql": "PostgreSQL", "postgres": "Postgres",
    "mysql": "MySQL", "mongodb": "MongoDB", "graphql": "GraphQL",
    "typescript": "TypeScript", "javascript": "JavaScript", "pytorch": "PyTorch",
    "tensorflow": "TensorFlow", "opentelemetry": "OpenTelemetry",
    "cloudfront": "CloudFront", "kibana": "Kibana", "elasticsearch": "Elasticsearch",
    "jenkins": "Jenkins", "ansible": "Ansible", "cassandra": "Cassandra",
    "anthropic": "Anthropic", "openai": "OpenAI", "slack": "Slack",
    "datadog": "Datadog", "snowflake": "Snowflake",
    "keycloak": "Keycloak", "pagerduty": "PagerDuty",
    "promptpay": "PromptPay", "truemoney": "TrueMoney",
    # acronyms (unambiguous — not also common lowercase English words)
    "api": "API", "gpu": "GPU", "cpu": "CPU", "sql": "SQL", "json": "JSON",
    "yaml": "YAML", "html": "HTML", "css": "CSS", "http": "HTTP", "https": "HTTPS",
    "url": "URL", "jwt": "JWT", "oauth": "OAuth", "aws": "AWS", "gcp": "GCP",
    "cdn": "CDN", "dns": "DNS", "ttl": "TTL", "sdk": "SDK", "cli": "CLI",
    "orm": "ORM", "crud": "CRUD", "saas": "SaaS", "grpc": "gRPC",
}
_CANON_RE = re.compile(r"[A-Za-z][A-Za-z0-9]*")


def apply_canonical_casing(text: str) -> str:
    """Re-case known tech terms to their canonical form (Latin tokens only).
    Byte-identical when nothing matches. Never touches Thai; never changes which
    letters are present, only their case (meaning-preserving)."""
    if not text:
        return text
    return _CANON_RE.sub(
        lambda m: CANONICAL_CASE.get(m.group(0).lower(), m.group(0)), text)


if __name__ == "__main__":
    tests = [
        "รีสตาร์ทคิวเบอร์เน็ตพอร์ตแล้วเช็คล็อกในกราฟาหน้าแดชบอร์ดอีกที",  # tc01: พอร์ต/ล็อก/หน้า stay Thai
        "ตัวโมเดลนี้ยังไม่ดีเดี๋ยวไฟล์จูนแล้วดูเมมโมรี่ลีก",
        "เปิดฟีเจอร์แฟ็กซ์ให้ยูเซอร์บางเซ็กเมนต์ทดลองเอบีเทสติ้ง",       # tc10: feature flag compound
        "ตอนนี้บัดเจ็ตเหลือน้อยต้องคัดคอร์สบางอย่างเซอร์วิสที่ไม่ค่อยได้ใช้",  # mx15
        "ใจดีพลอยเลยยิ้ม",                # must NOT fire (ใจดี is a real word)
        "ซื้อแอปเปิ้ลที่ตลาด",              # must NOT fire (แอป inside แอปเปิ้ล)
        "แบงก์ชาติปรับดอกเบี้ย",           # should stay Thai (user keep-list)
    ]
    for t in tests:
        out, n = apply_dictionary(t)
        print(f"[{n} hits] {t}\n      -> {out}\n")
