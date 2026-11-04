#!/usr/bin/env python3
"""Integration gegen echte lokale Testdienste, nur künstliche Audiodaten."""
import base64, json, math, os, pathlib, queue, struct, subprocess, tempfile, threading, time, unittest
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer

class Service(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def reply(self,body,status=200):
        data=json.dumps(body).encode();self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
    def do_GET(self):
        self.reply({'status':'ok'} if self.path=='/health' else {'models':[]})
    def do_POST(self):
        data=self.rfile.read(int(self.headers.get('Content-Length',0)))
        if self.path=='/inference':
            self.server.audio.append(data)
            if self.server.redirect:
                self.send_response(307);self.send_header('Location',self.server.redirect);self.send_header('Content-Length','0');self.end_headers();return
            if self.server.fail_audio:self.reply({'error':'fixture'},503)
            else:self.reply({'text':'Dies ist ein künstlicher Test'})
        else:
            message=json.loads(data);self.server.cleanup.append(message)
            if self.server.fail_service:self.reply({'error':'fixture'},503);return
            if message.get('messages'):
                self.reply({'message':{'content': 'Dies ist ein künstlicher Test.' if not self.server.reject else 'Ein komplett erfundener anderer Inhalt mit Zusatzwörtern.'},'done':True})
            else:self.reply({'done':True})

def service():
    server=ThreadingHTTPServer(('127.0.0.1',0),Service);server.audio=[];server.cleanup=[];server.reject=False;server.fail_audio=False;server.fail_service=False;server.redirect=None
    threading.Thread(target=server.serve_forever,daemon=True).start();return server

class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.path=pathlib.Path(self.tmp.name)
        self.stt=service();self.primary=service();self.fallback=service()
        def url(server):return 'http://127.0.0.1:'+str(server.server_port)
        config={'whisper':{'serverURL':url(self.stt),'autostart':False,'language':'de'},'cleanup':{'provider':'ollama','ollamaURL':url(self.primary),'model':'fixture','localOnly':False,'fallbacks':[{'provider':'ollama','ollamaURL':url(self.fallback),'model':'fixture'}]}}
        (self.path/'config.json').write_text(json.dumps(config))
        bundle=pathlib.Path(os.environ.get('STILLEPOST_TEST_BUNDLE','build/linux/StillePost.AppDir')).resolve()
        env=dict(os.environ,STILLEPOST_CONFIG=str(self.path/'config.json'),STILLEPOST_APP_SUPPORT=str(self.path/'data'),LD_LIBRARY_PATH=str(bundle/'lib'),http_proxy=url(self.fallback),HTTP_PROXY=url(self.fallback),ALL_PROXY=url(self.fallback))
        self.process=subprocess.Popen([str(bundle/'bin/stillepost-linux')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env)
        self.events=queue.Queue();threading.Thread(target=self.reader,daemon=True).start();self.wait('ready')
    def reader(self):
        for line in self.process.stdout:
            self.events.put(json.loads(line))
    def send(self,**obj):self.process.stdin.write(json.dumps(obj).encode()+b'\n');self.process.stdin.flush()
    def wait(self,event,state=None):
        deadline=time.monotonic()+20
        while time.monotonic()<deadline:
            item=self.events.get(timeout=max(.1,deadline-time.monotonic()))
            if item['event']==event and (state is None or item.get('state')==state):return item
        raise AssertionError('event timeout '+event)
    def record(self):
        self.send(command='start');self.wait('state','recording')
        # Mehrere abgeschlossene Segmente prüfen die Reihenfolge und genau einen Cleanup.
        for phase in range(2):
            samples=[.25*math.sin(i/16000*2*math.pi*220) for i in range(32000)]+[0.0]*16000
            for offset in range(0,len(samples),2048):
                block=samples[offset:offset+2048]
                self.send(command='samples',data=base64.b64encode(struct.pack('<'+'f'*len(block),*block)).decode())
        self.send(command='stop')
    def test_complete_dictation_cleans_once_and_removes_wav(self):
        self.record();result=self.wait('result')
        self.assertTrue(result['text']);self.assertEqual(len(self.stt.audio),2)
        requests=[x for x in self.primary.cleanup if x.get('messages')]
        self.assertEqual(len(requests),1);self.assertEqual(len(self.fallback.cleanup),0)
        self.assertEqual(requests[0]['messages'][-1]['content'],'Dies ist ein künstlicher Test Dies ist ein künstlicher Test');self.assertIn(b'RIFF',self.stt.audio[0])
        self.assertFalse(requests[0]['think']);self.assertEqual(requests[0]['options']['num_ctx'],16384)
        self.assertEqual(list((self.path/'data/recordings').glob('*.wav')),[])
    def test_plausibility_failure_does_not_try_fallback(self):
        self.primary.reject=True;self.record();result=self.wait('result')
        self.assertTrue(result['rawFallback']);self.assertEqual(len(self.fallback.cleanup),0)
        self.assertNotIn('erfundener',result['text'])
    def test_service_failure_tries_local_fallback(self):
        self.primary.fail_service=True;self.record();result=self.wait('result')
        self.assertTrue(result['text'])
        self.assertEqual(len([x for x in self.fallback.cleanup if x.get('messages')]),1)
    def test_audio_redirect_is_rejected_and_does_not_leave_loopback_service(self):
        self.stt.redirect='http://127.0.0.1:'+str(self.fallback.server_port)+'/leak'
        self.record();self.wait('state','error')
        self.assertEqual(len(self.fallback.cleanup),0);self.assertEqual(len(self.fallback.audio),0)
    def test_transcription_error_retains_audio(self):
        self.stt.fail_audio=True;self.record();self.wait('state','error')
        self.assertTrue(list((self.path/'data/recordings').glob('*.wav')))
    def test_parent_pipe_closure_shuts_down_worker(self):
        self.process.stdin.close();self.process.wait(timeout=8);self.assertEqual(self.process.returncode,0)
    def tearDown(self):
        if self.process.poll() is None:
            try:self.send(command='quit');self.process.wait(timeout=8)
            except Exception:self.process.kill();self.process.wait()
        self.process.stdout.close();self.process.stderr.close()
        if not self.process.stdin.closed:self.process.stdin.close()
        for server in [self.stt,self.primary,self.fallback]:server.shutdown();server.server_close()
        self.tmp.cleanup()

if __name__=='__main__':unittest.main(verbosity=2)
