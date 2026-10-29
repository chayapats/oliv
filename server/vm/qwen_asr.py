#!/usr/bin/env python3
"""Serve a pinned Qwen ASR package using OLIV's existing /transcribe contract.

The actual model runs in the same pinned llama-server as the benchmark. This
process owns that child, the default CPU empty-speech VAD gate and admission.
"""
import base64
import hashlib
import io
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import threading
import time
import tomllib
import urllib.error
import urllib.request
from urllib.parse import unquote
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PREFIX=re.compile(r'^\s*language\s+([A-Za-z]+)\s*<asr_text>',re.S)
LANGUAGES={'thai':'th','english':'en','chinese':'zh','japanese':'ja','korean':'ko','spanish':'es','french':'fr','german':'de'}
MAX_BYTES=16*1024*1024
MAX_SECONDS=120


class InvalidAudio(ValueError):pass
class BackendFailed(RuntimeError):pass


def sha(path):
    with Path(path).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()


def request_body(wav,duration,prompt='',language=None):
    terms=[x.strip() for x in re.split(r'[,\n]',unquote(prompt)) if x.strip()]
    system=' '.join(terms)
    if len(system.encode())>4096:raise InvalidAudio('vocabulary context is too large')
    force={'en':'English','th':'Thai'}.get(language)
    if language and not force:raise InvalidAudio('supported forced languages: en, th; omit for auto')
    messages=[{'role':'system','content':system},{'role':'user','content':[{'type':'input_audio','input_audio':{'data':base64.b64encode(wav).decode(),'format':'wav'}}]}]
    if force:messages.append({'role':'assistant','content':f'language {force}<asr_text>'})
    budget=min(2400,96+int(duration)*20)
    # Preserve the benchmark budget for ordinary empty-context requests. Bound
    # long/custom-context requests conservatively instead of overflowing KV.
    budget=min(budget,4096-math.ceil(duration*13)-len(system.encode())-128)
    if budget<96:raise InvalidAudio('audio and vocabulary exceed the model context')
    return {'messages':messages,'temperature':0,'seed':42,'max_tokens':budget,'cache_prompt':False},force


def parse_reply(reply,budget,forced=None,model_id='qwen3-asr'):
    choice=reply['choices'][0];tokens=reply.get('usage',{}).get('completion_tokens')
    if not isinstance(tokens,int):tokens=reply.get('timings',{}).get('predicted_n')
    if choice.get('finish_reason')!='stop' or not isinstance(tokens,int) or not 0<=tokens<budget:
        raise BackendFailed('ASR did not finish; no partial transcript returned')
    text=choice['message'].get('content') or '';language=forced
    match=PREFIX.match(text)
    if match:language=match.group(1);text=text[match.end():]
    return {'ok':True,'text':text.replace('<asr_text>','').strip(),
            'language':LANGUAGES.get((language or '').lower(),(language or '').lower() or None),
            # Qwen token confidence is not calibrated to Whisper's re-decode gate.
            'avg_logprob':None,'backend':'qwen3asr','model_id':model_id}


class Engine:
    def __init__(self,profile):
        self.profile=profile;self.config=profile['config'];self.process=None
        self.model_id=str(profile.get('model_id','qwen3-asr'))
        argv=self.config['server_argv'];self.backend='http://127.0.0.1:'+argv[argv.index('--port')+1]
        self.concurrency=int(argv[argv.index('-np')+1]) if '-np' in argv else 1
        if not 1<=self.concurrency<=4:raise ValueError('ASR concurrency must be 1..4')
        self.lock=threading.BoundedSemaphore(self.concurrency)
        self.ready=threading.Event();self.failed=threading.Event()

    def normalize(self,data):
        import numpy as np
        from faster_whisper.audio import decode_audio
        try:audio=decode_audio(io.BytesIO(data),sampling_rate=16000)
        except Exception as error:raise InvalidAudio('audio could not be decoded') from error
        if not len(audio) or not np.isfinite(audio).all():raise InvalidAudio('empty or invalid audio')
        duration=len(audio)/16000
        if duration>MAX_SECONDS:raise InvalidAudio('audio exceeds 120 seconds')
        # Match the benchmark WAV byte-for-byte when already PCM16/mono/16k.
        try:
            with wave.open(io.BytesIO(data),'rb') as f:
                if (f.getnchannels(),f.getsampwidth(),f.getframerate(),f.getcomptype())==(1,2,16000,'NONE'):
                    return data,audio,duration
        except (wave.Error,EOFError):pass
        stream=io.BytesIO()
        with wave.open(stream,'wb') as f:
            f.setnchannels(1);f.setsampwidth(2);f.setframerate(16000)
            f.writeframes(np.clip(np.rint(audio*32768),-32768,32767).astype('<i2').tobytes())
        return stream.getvalue(),audio,duration

    def transcribe(self,data,prompt='',language=None):
        from faster_whisper.vad import get_speech_timestamps,VadOptions
        wav,audio,duration=self.normalize(data)
        if not get_speech_timestamps(audio,vad_options=VadOptions()):
            return {'ok':True,'text':'','language':None,'avg_logprob':None,'backend':'qwen3asr','model_id':self.model_id,'vad_empty_gate':True}
        body,forced=request_body(wav,duration,prompt,language)
        request=urllib.request.Request(self.backend+'/v1/chat/completions',data=json.dumps(body).encode(),headers={'Content-Type':'application/json'})
        try:
            with urllib.request.urlopen(request,timeout=60) as response:reply=json.load(response)
            return parse_reply(reply,body['max_tokens'],forced,self.model_id)
        except Exception as error:
            # Keep future callers out until the owner has stopped its child.
            # A timeout must never release admission onto a still-running job.
            self.ready.clear();self.failed.set()
            raise BackendFailed('Qwen ASR unavailable; retry after service recovery') from error

    def health(self):
        if not self.ready.is_set() or self.failed.is_set():return None
        if self.process and self.process.poll() is not None:return None
        try:
            with urllib.request.urlopen(self.backend+'/health',timeout=2) as response:
                if response.status!=200:return None
        except OSError:return None
        return {'ok':True,'backend':'qwen3asr','model':self.config['model'],'model_id':self.model_id,
                'model_sha256':self.config['model_sha256'],'projector_sha256':self.config['projector_sha256'],
                'device':'cuda','compute_type':'Q8_0','gpu_layers':99,'concurrency':self.concurrency,'max_audio_seconds':MAX_SECONDS,
                'vad':'faster-whisper default CPU empty-speech gate','language':'auto'}


def handler(engine):
    class Handler(BaseHTTPRequestHandler):
        protocol_version='HTTP/1.1'
        def log_message(self,fmt,*args):print(fmt%args,flush=True)
        def send_json(self,status,payload):
            body=json.dumps(payload,ensure_ascii=False).encode();self.send_response(status)
            self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)))
            if self.close_connection:self.send_header('Connection','close')
            self.end_headers();self.wfile.write(body)
        def do_GET(self):
            if self.path.split('?',1)[0]!='/health':return self.send_json(404,{'ok':False,'error':'not found'})
            health=engine.health();self.send_json(200 if health else 503,health or {'ok':False,'error':'ASR not ready'})
        def do_POST(self):
            if self.path.split('?',1)[0]!='/transcribe':return self.send_json(404,{'ok':False,'error':'not found'})
            if not engine.ready.is_set() or engine.failed.is_set() or not engine.lock.acquire(blocking=False):
                self.close_connection=True;return self.send_json(503,{'ok':False,'error':'inference busy or unavailable'})
            try:
                self.connection.settimeout(15)
                try:length=int(self.headers.get('Content-Length','0'))
                except ValueError:raise InvalidAudio('invalid content length')
                if not 0<length<=MAX_BYTES:raise InvalidAudio('empty or oversized audio body')
                data=self.rfile.read(length)
                if len(data)!=length:raise InvalidAudio('incomplete audio body')
                self.send_json(200,engine.transcribe(data,self.headers.get('X-Initial-Prompt',''),self.headers.get('X-Language','').strip() or None))
            except (BrokenPipeError,ConnectionResetError):self.close_connection=True
            except InvalidAudio as error:
                self.close_connection=True;self.send_json(400,{'ok':False,'error':str(error)})
            except (BackendFailed,TimeoutError):
                self.close_connection=True;self.send_json(503,{'ok':False,'error':'ASR unavailable; retry later'})
            finally:engine.lock.release()
    return Handler


def main(profile_path):
    profile=json.loads(Path(profile_path).read_text());config=profile['config']
    for key in ['model','projector','server_binary']:
        if sha(config[key])!=config[key+'_sha256']:raise RuntimeError('Qwen package fingerprint changed: '+key)
    for pin in config.get('binary_files',[]):
        if sha(pin['path'])!=pin['sha256']:raise RuntimeError('Qwen runtime fingerprint changed')
    argv=config['server_argv'];assert argv[0]==config['server_binary']
    assert argv[argv.index('--host')+1]=='127.0.0.1' and argv[argv.index('--port')+1]=='8087'
    assert argv[argv.index('-m')+1]==config['model'] and argv[argv.index('--mmproj')+1]==config['projector']
    assert argv[argv.index('-ngl')+1]=='99' and '--no-mmproj-offload' not in argv
    engine=Engine(profile);server=None;root=Path(profile['root'])
    # Preserve the same 4096-token context per slot; increasing parallelism
    # must not silently reduce the longest accepted recording's context.
    assert int(argv[argv.index('-c')+1])>=4096*engine.concurrency
    api=tomllib.loads((root/'config.toml').read_text()).get('api',{})
    assert api.get('asr_concurrency',1)==engine.concurrency,'API and Qwen concurrency must match'
    def terminate(signum,frame):raise KeyboardInterrupt()
    for sig in [signal.SIGTERM,signal.SIGINT,signal.SIGHUP]:signal.signal(sig,terminate)
    env=dict(os.environ,HF_HUB_OFFLINE='1',OMP_NUM_THREADS='2',LD_LIBRARY_PATH=str(Path(config['server_binary']).parent))
    with (root/'logs/qwen-asr-backend.log').open('a') as log:
        try:
            # The launcher's session contains both wrapper and model. stop.sh
            # stops the whole ASR group without touching Gemma's separate group.
            engine.process=subprocess.Popen(argv,cwd=root,env=env,stdout=log,stderr=subprocess.STDOUT)
            (root/'run/qwen-backend.pid').write_text(str(engine.process.pid)+'\n')
            deadline=time.monotonic()+120
            while time.monotonic()<deadline:
                if engine.process.poll() is not None:raise RuntimeError('Qwen model failed to start')
                try:
                    with urllib.request.urlopen(engine.backend+'/health',timeout=2) as response:
                        if response.status==200:break
                except OSError:pass
                time.sleep(.2)
            else:raise TimeoutError('Qwen model readiness')
            engine.ready.set();server=ThreadingHTTPServer(('127.0.0.1',8082),handler(engine));server.daemon_threads=True
            def watch():
                while engine.process.poll() is None and not engine.failed.wait(.5):pass
                engine.ready.clear();server.shutdown()
            threading.Thread(target=watch,daemon=True).start()
            print(f'Qwen3-ASR ({engine.model_id}) ready on 127.0.0.1:8082',flush=True)
            server.serve_forever(poll_interval=.2)
        except KeyboardInterrupt:pass
        finally:
            engine.ready.clear()
            if server:server.server_close()
            if engine.process and engine.process.poll() is None:
                engine.process.terminate()
                try:engine.process.wait(timeout=10)
                except subprocess.TimeoutExpired:engine.process.kill();engine.process.wait(timeout=5)
            pidfile=root/'run/qwen-backend.pid'
            if pidfile.exists() and engine.process and pidfile.read_text().strip()==str(engine.process.pid):pidfile.unlink()


if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser();parser.add_argument('--profile',type=Path,required=True);args=parser.parse_args();main(args.profile)
