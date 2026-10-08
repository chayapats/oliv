"""Record Rust fixtures from public Python test literals and synthetic examples.

Never reads manifests, recordings, eval results or model outputs. Generation is
mocked. Existing tokenizer fuzz uses the public PyThaiNLP corpus; see its notice.
Run with the developer reference environment, never as part of the app build.
"""
from __future__ import annotations
import ast
import dataclasses
import functools
import gzip
import importlib
import json
import os
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEST = ROOT / "rust/crates/oliv-text/tests"
os.environ["OLIV_SIDECAR_IMPORT_ONLY"] = "1"
os.environ.pop("OLIV_CLEANUP_NO_LLM", None)
sys.path[:0] = [str(ROOT / "benchmark"), str(ROOT / "sidecar"), str(ROOT)]
import pipeline as pl
import sidecar_server as sc
import thai_format as tf
import metrics
import prompts

TARGETS = {
    "tokenize": ("pythainlp.tokenize", "word_tokenize"),
    "royin": ("pythainlp.transliterate", "romanize"),
    "words_to_num": ("pythainlp.util", "words_to_num"),
    "fillers": ("sidecar_server", "remove_fillers"),
    "strip_cjk": ("sidecar_server", "_strip_cjk"),
    "text_hallucination": ("sidecar_server", "_is_text_hallucination"),
    "hallucination_phrase": ("sidecar_server", "_is_hallucination_phrase"),
    "repetition_loop": ("sidecar_server", "_is_repetition_loop"),
    "dictionary": ("dictionary", "apply_dictionary"),
    "casing": ("dictionary", "apply_canonical_casing"),
    "vocab_correct": ("phonetic", "correct_with_vocab"),
    "vocab_hint": ("phonetic", "vocab_hint"),
    "fold": ("phonetic", "fold"), "thai_fold": ("phonetic", "thai_fold"),
    "gate": ("pipeline", "_gate"),
    "suspicious_tokens": ("pipeline", "_suspicious_tokens"),
    "loan_compound_runs": ("pipeline", "_loan_compound_runs"),
    "latin_crumbs": ("pipeline", "_latin_crumbs"),
    "spacing": ("pipeline", "normalize_thai_spacing"),
    "strip_out": ("pipeline", "_strip_out"),
    "guardrail": ("pipeline", "_guardrail"),
    "lost_spans": ("pipeline", "_lost_spans"),
    "thai_divergence": ("pipeline", "_thai_divergence"),
    "latin_gain": ("pipeline", "_latin_gain"),
    "translation_gloss": ("pipeline", "_invented_translation_gloss"),
    "hint_line": ("pipeline", "_hint_line"),
    "normalize": ("metrics", "normalize"), "metrics_tokenize": ("metrics", "tokenize"),
    "thai_format": ("thai_format", "apply_thai_format"),
}
MODULES = ("sidecar_server", "dictionary", "phonetic", "pipeline", "metrics", "thai_format", "prompts")


def value(v):
    if dataclasses.is_dataclass(v):
        return dataclasses.asdict(v)
    if isinstance(v, (tuple, list)):
        return [value(x) for x in v]
    if isinstance(v, dict):
        return {k: value(x) for k, x in v.items()}
    return v


records = defaultdict(dict)
def record(name, fn):
    @functools.wraps(fn)
    def wrapped(*args, **kwargs):
        if name == 'tokenize':
            kwargs = dict(kwargs)
            kwargs.setdefault('engine', 'newmm')
            kwargs.setdefault('keep_whitespace', True)
            if kwargs['engine'] != 'newmm':
                return fn(*args, **kwargs)
        case = {"args": value(args), "kwargs": value(kwargs), "src": "public-test-literal/synthetic"}
        try:
            key = json.dumps([case['args'],case['kwargs']],sort_keys=True)
        except TypeError:
            # Internal PyThaiNLP calls may carry a Trie instead of public JSON.
            return fn(*args, **kwargs)
        try:
            result = fn(*args, **kwargs)
        except Exception as error:
            case["raises"] = type(error).__name__
            records[name].setdefault(key, case)
            raise
        case["out"] = value(result)
        records[name].setdefault(key, case)
        return result
    return wrapped


for module in MODULES:
    importlib.import_module(module)
originals = {}
for name, (module, attribute) in TARGETS.items():
    fn = getattr(importlib.import_module(module), attribute)
    originals[name] = fn
    wrapped = record(name, fn)
    for mname, mod in list(sys.modules.items()):
        if mod is None or not (mname in MODULES or mname == module or mname.startswith('pythainlp')):
            continue
        for key, val in list(vars(mod).items()):
            if val is fn:
                setattr(mod, key, wrapped)


texts = {'', 'hello', 'สวัสดีครับ', '日本語', 'ขึ้นบรรทัดใหม่', 'um hello เอ่อ สวัสดี',
         'รีสตาร์ทเซิร์ฟเวอร์แล้วเช็คล็อกในกราฟา', 'ลง OpenTelemetry ที่ server',
         'หนึ่งร้อยยี่สิบสามบาท', 'ห้าโมงสามสิบนาที', 'OUT: hello', '```\nhello\n```'}
for filename in ['benchmark/test_dictionary.py', 'benchmark/test_pipeline_guardrails.py',
                 'benchmark/test_pipeline_spacing.py', 'sidecar/test_text_passes.py',
                 'sidecar/test_groq_backend.py']:
    tree = ast.parse((ROOT / filename).read_text())
    docs = {id(n.body[0].value) for n in ast.walk(tree)
            if isinstance(n, (ast.Module, ast.FunctionDef, ast.ClassDef)) and n.body
            and isinstance(n.body[0], ast.Expr) and isinstance(n.body[0].value, ast.Constant)}
    texts.update(n.value for n in ast.walk(tree) if isinstance(n, ast.Constant)
                 and isinstance(n.value, str) and id(n) not in docs and 1 <= len(n.value) <= 400)
texts = sorted(texts)
vocabulary = ['Grafana', 'Kafka', 'OpenTelemetry', 'Kubernetes', 'Cassandra']
replacements = {'อีเมลของผม': 'me@example.com', 'โอลีฟ': 'OLIV'}
for text in texts:
    for name in ['royin', 'words_to_num', 'fillers', 'strip_cjk', 'text_hallucination',
                 'hallucination_phrase', 'repetition_loop', 'casing', 'fold', 'thai_fold',
                 'spacing', 'strip_out', 'suspicious_tokens', 'loan_compound_runs',
                 'latin_crumbs', 'normalize', 'thai_format']:
        module, attr = TARGETS[name]
        try:
            fn = getattr(importlib.import_module(module), attr)
            fn(text, engine='royin') if name == 'royin' else fn(text)
        except (ValueError, IndexError):
            pass
    for whitespace in [False, True]:
        pl.word_tokenize(text, engine='newmm', keep_whitespace=whitespace)
    metrics.tokenize(metrics.normalize(text), 'newmm')
    for table in [None, replacements]:
        pl.apply_dictionary(text, table) if table is not None else pl.apply_dictionary(text)
    dt, hits = pl.apply_dictionary(text)
    pl._gate(dt, hits)
    for terms in [[], vocabulary]:
        pl.correct_with_vocab(text, terms)
        pl.vocab_hint(text, terms)
        pl._hint_line(terms)
    for candidate in [text, '', text[:max(1,len(text)//2)], 'OUT: '+text,
                      text+' invented translation', 'completely unrelated']:
        pl._guardrail(text, candidate)
        pl._lost_spans(text, candidate)
        pl._thai_divergence(text, candidate)
        pl._latin_gain(text, candidate)
        pl._invented_translation_gloss(text, candidate)

prompt_cases, clean_cases, dictate_cases, gens = [], [], [], {}
current = {'prompt': 'v2'}
pl._ensure_model = lambda: (None, None, None)
def generate(text, hints=None):
    hints = hints or []
    name = current['prompt']
    content = pl.CLEANUP_PROMPT + pl._hint_line(hints) + f'\n\nIN:  {text}\nOUT: '
    key = (name, text, tuple(hints))
    if key not in gens:
        # Deterministic mock, with output-marker handling on one synthetic case.
        generation = ('OUT: ' + text) if 'OpenTelemetry' in text else text
        gens[key] = {'prompt': name, 'text': text, 'hints': hints, 'gen': generation}
        prompt_cases.append({'args':[name,text,hints], 'kwargs':{}, 'out':{
            'messages':[{'role':'user','content':content}], 'temperature':0,
            'max_tokens':pl.MAX_TOKENS, 'stop':list(pl.STOPS),
            'chat_template_kwargs':{'enable_thinking':False}}, 'src':'synthetic-mock'})
    return gens[key]['gen']
pl._llm_generate = generate

def dictate(text, opts):
    out = dict(final=text,no_speech=False,llm_ran=False,gate_reason='',guardrail_flag='',
               dict_hits=0,vocab_fired=0,fillers_removed=0,replacements_fired=0,thai_format_fired=0,cleanup_error=None)
    t = sc._strip_cjk(text)
    if text.strip() and not t.strip():
        return dict(out,final='',no_speech=True,gate_reason='no_speech')
    if t.strip() and sc._is_text_hallucination(t):
        return dict(out,final='',no_speech=True,gate_reason='hallucination')
    if opts.get('remove_fillers') and t.strip():
        t,out['fillers_removed'] = sc.remove_fillers(t)
    info = sc._clean_and_replace_segments([t],[],cleanup_on=opts.get('cleanup',True),
        replacements=opts.get('replacements'),vocab=opts.get('vocabulary'),pipeline=pl)
    final = info['final']
    if opts.get('thai_format') and final.strip():
        final,out['thai_format_fired'] = tf.apply_thai_format(final)
    for k in ['llm_ran','gate_reason','guardrail_flag','dict_hits','vocab_fired','replacements_fired','cleanup_error']:
        out[k] = info[k]
    return dict(out,final=final)

for name in ['v2','v3','v4']:
    current['prompt'] = name
    pl.CLEANUP_PROMPT = getattr(prompts,'CLEANUP_'+name.upper())
    for text in texts:
        for terms in [[], vocabulary]:
            result = dataclasses.asdict(pl.clean_ex(text,vocab=terms))
            for k in ['t_dict','t_gate','t_llm','t_total']:
                result.pop(k)
            clean_cases.append(dict(args=[text],kwargs={'vocab':terms},prompt=name,out=result,src='synthetic-mock'))
        for opts in [dict(cleanup=True,remove_fillers=True,thai_format=True),
                     dict(cleanup=True,remove_fillers=True,thai_format=True,vocabulary=vocabulary,replacements=replacements),
                     dict(cleanup=False,remove_fillers=False,thai_format=False)]:
            dictate_cases.append(dict(args=[text],kwargs=dict(opts,prompt=name),out=dictate(text,opts),src='synthetic-mock'))

for name,cases in [('prompt',prompt_cases),('clean_ex',clean_cases),('dictate',dictate_cases)]:
    records[name] = {str(i):c for i,c in enumerate(cases)}
for name,cases in sorted(records.items()):
    content = ''.join(json.dumps(c,ensure_ascii=False)+'\n' for c in cases.values()).encode()
    path = DEST/'golden'/f'{name}.jsonl'
    path.unlink(missing_ok=True)
    path.with_suffix('.jsonl.gz').write_bytes(gzip.compress(content,mtime=0))
(DEST/'reference/gens.jsonl').write_text(''.join(json.dumps(c,ensure_ascii=False)+'\n' for c in gens.values()))
print('Public inputs',len(texts),'recorded fixtures',sum(len(x) for x in records.values()))
