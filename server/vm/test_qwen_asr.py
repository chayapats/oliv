import http.client
import json
import threading
import time
import unittest
import sys
from types import SimpleNamespace
from unittest.mock import Mock,patch
try:from . import qwen_asr as q
except ImportError:import qwen_asr as q


class ProtocolTests(unittest.TestCase):
    def test_none_context_matches_frozen_benchmark(self):
        body,forced=q.request_body(b'wave',4.9)
        self.assertEqual(body['seed'],42);self.assertEqual(body['temperature'],0)
        self.assertEqual(body['max_tokens'],176);self.assertFalse(body['cache_prompt'])
        self.assertEqual(body['messages'][0],{'role':'system','content':''});self.assertIsNone(forced)

    def test_language_and_vocabulary_are_request_local(self):
        body,force=q.request_body(b'wave',3,'Kubernetes%2C%20OLIV','en')
        self.assertEqual(body['messages'][0]['content'],'Kubernetes OLIV');self.assertEqual(force,'English')
        other,_=q.request_body(b'wave',3);self.assertEqual(other['messages'][0]['content'],'')

    def test_non_eos_never_returns_partial_text(self):
        with self.assertRaises(q.BackendFailed):q.parse_reply({'choices':[{'finish_reason':'length','message':{'content':'partial'}}],'usage':{'completion_tokens':100}},100)

    def test_envelope_and_uncalibrated_confidence(self):
        result=q.parse_reply({'choices':[{'finish_reason':'stop','message':{'content':'language Thai<asr_text>สวัสดี'}}],'usage':{'completion_tokens':5}},100)
        self.assertEqual(result['text'],'สวัสดี');self.assertEqual(result['language'],'th');self.assertIsNone(result['avg_logprob'])

    def test_context_overflow_is_rejected(self):
        with self.assertRaises(q.InvalidAudio):q.request_body(b'wave',120,'x'*4096)

    def test_backend_timeout_closes_admission_until_owner_stops(self):
        engine=q.Engine({'config':{'server_argv':['llama-server','--port','8087']}})
        engine.ready.set();engine.normalize=Mock(return_value=(b'wave',object(),3.0))
        vad=SimpleNamespace(get_speech_timestamps=lambda *a,**k:[{'start':0,'end':1}],VadOptions=object)
        with patch.dict(sys.modules,{'faster_whisper.vad':vad}),patch.object(q.urllib.request,'urlopen',side_effect=TimeoutError):
            with self.assertRaises(q.BackendFailed):engine.transcribe(b'wave')
        self.assertTrue(engine.failed.is_set());self.assertFalse(engine.ready.is_set())


class AdmissionTests(unittest.TestCase):
    def setUp(self):
        self.started=threading.Event();self.release=threading.Event();self.calls=0
        def transcribe(*args):
            self.calls+=1;self.started.set();self.release.wait(3)
            return {'ok':True,'text':'synthetic'}
        self.engine=SimpleNamespace(ready=threading.Event(),failed=threading.Event(),lock=threading.Lock(),transcribe=transcribe,health=lambda:{'ok':True})
        self.engine.ready.set();self.server=q.ThreadingHTTPServer(('127.0.0.1',0),q.handler(self.engine));self.server.daemon_threads=True
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start();self.connections=[]
    def tearDown(self):
        self.release.set()
        for c in self.connections:c.close()
        self.server.shutdown();self.server.server_close();self.thread.join(2)
    def connection(self,timeout=1):
        c=http.client.HTTPConnection(*self.server.server_address,timeout=timeout);self.connections.append(c);return c
    def test_disconnect_does_not_queue_another_inference(self):
        first=self.connection(.05);first.request('POST','/transcribe',b'wave');self.assertTrue(self.started.wait(1))
        with self.assertRaises(TimeoutError):first.getresponse()
        first.close()
        second=self.connection();second.putrequest('POST','/transcribe');second.putheader('Content-Length','1024');second.endheaders()
        reply=second.getresponse();self.assertEqual(reply.status,503);self.assertEqual(reply.getheader('Connection'),'close');reply.read()
        self.assertEqual(self.calls,1);self.release.set();self.assertTrue(self.engine.lock.acquire(timeout=2));self.engine.lock.release()
    def test_bad_audio_releases_admission(self):
        self.engine.transcribe=Mock(side_effect=q.InvalidAudio('invalid audio'))
        c=self.connection();c.request('POST','/transcribe',b'bad');r=c.getresponse();self.assertEqual(r.status,400);r.read()
        self.assertTrue(self.engine.lock.acquire(timeout=1));self.engine.lock.release()
    def test_failed_backend_stays_closed(self):
        self.engine.failed.set();c=self.connection();c.request('POST','/transcribe',b'wave');r=c.getresponse();self.assertEqual(r.status,503);r.read();self.assertEqual(self.calls,0)
    def test_two_slots_accept_two_requests_and_reject_the_third(self):
        self.engine.lock=threading.BoundedSemaphore(2)
        first=self.connection();second=self.connection()
        first.request('POST','/transcribe',b'wave');second.request('POST','/transcribe',b'wave')
        deadline=time.monotonic()+2
        while self.calls<2 and time.monotonic()<deadline:time.sleep(.005)
        self.assertEqual(self.calls,2)
        third=self.connection();third.request('POST','/transcribe',b'wave')
        rejected=third.getresponse();self.assertEqual(rejected.status,503);rejected.read()
        self.release.set()
        for connection in [first,second]:
            reply=connection.getresponse();self.assertEqual(reply.status,200);reply.read()


if __name__=='__main__':unittest.main()
