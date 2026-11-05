#!/usr/bin/env python3
"""Integration gegen echte lokale Testdienste, nur künstliche Audiodaten."""
import base64, json, math, os, pathlib, queue, struct, subprocess, tempfile, threading, time, unittest, wave
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer

class Service(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def reply(self,body,status=200):
        data=json.dumps(body).encode();self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
    def do_GET(self):
        if self.path=='/health':time.sleep(getattr(self.server,'health_delay',0))
        self.reply({'status':'ok'} if self.path=='/health' else {'models':[]})
    def do_POST(self):
        data=self.rfile.read(int(self.headers.get('Content-Length',0)))
        if self.path=='/inference':
            self.server.audio.append(data)
            if self.server.redirect:
                self.send_response(307);self.send_header('Location',self.server.redirect);self.send_header('Content-Length','0');self.end_headers();return
            if self.server.fail_audio:self.reply({'error':'fixture'},503)
            else:self.reply({'text':getattr(self.server,'transcript','Dies ist ein künstlicher Test')})
        else:
            message=json.loads(data);self.server.cleanup.append(message)
            if self.server.fail_service:self.reply({'error':'fixture'},503);return
            if message.get('messages'):
                self.reply({'message':{'content': getattr(self.server,'reply_text','Dies ist ein künstlicher Test.') if not self.server.reject else 'Ein komplett erfundener anderer Inhalt mit Zusatzwörtern.'},'done':True})
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
        self.worker_environment=env
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
    def record(self,command='start'):
        self.send(command=command);self.wait('state','recording')
        # Mehrere abgeschlossene Segmente prüfen die Reihenfolge und genau einen Cleanup.
        for phase in range(2):
            samples=[.25*math.sin(i/16000*2*math.pi*220) for i in range(32000)]+[0.0]*16000
            for offset in range(0,len(samples),2048):
                block=samples[offset:offset+2048]
                self.send(command='samples',data=base64.b64encode(struct.pack('<'+'f'*len(block),*block)).decode())
        self.send(command='holdEnd' if command=='holdStart' else 'stop')
    def test_interrupted_hold_is_cancelled_and_can_start_again(self):
        self.send(command='holdStart');self.wait('state','recording')
        self.send(command='holdInterrupted');self.wait('state','idle')
        self.assertFalse(list((self.path/'data/recordings').glob('*.wav')))
        self.send(command='history');self.assertEqual(self.wait('history')['entries'],[])
        self.record(command='holdStart');self.assertTrue(self.wait('result')['text'])
    def test_hold_release_during_resume_finishes_existing_audio(self):
        self.send(command='holdStart');self.wait('state','recording')
        samples=[.25*math.sin(i/16000*2*math.pi*220) for i in range(24000)]
        for offset in range(0,len(samples),2048):
            block=samples[offset:offset+2048]
            self.send(command='samples',data=base64.b64encode(struct.pack('<'+'f'*len(block),*block)).decode())
        self.send(command='pause');self.wait('state','paused')
        self.stt.health_delay=.5
        self.send(command='resume');self.wait('state','starting')
        self.send(command='holdEnd')
        result=self.wait('result');self.assertTrue(result['text'])
        self.assertFalse(list((self.path/'data/recordings').glob('*.wav')))
    def test_complete_dictation_cleans_once_and_removes_wav(self):
        self.record();result=self.wait('result')
        self.assertTrue(result['text']);self.assertEqual(len(self.stt.audio),2)
        requests=[x for x in self.primary.cleanup if x.get('messages')]
        self.assertEqual(len(requests),1);self.assertEqual(len(self.fallback.cleanup),0)
        self.assertEqual(requests[0]['messages'][-1]['content'],'Dies ist ein künstlicher Test Dies ist ein künstlicher Test');self.assertIn(b'RIFF',self.stt.audio[0])
        self.assertFalse(requests[0]['think']);self.assertEqual(requests[0]['options']['num_ctx'],16384)
        self.assertEqual(list((self.path/'data/recordings').glob('*.wav')),[])
    def test_test_dictation_uses_history_policy_and_preserves_last_regular_result(self):
        self.record();regular=self.wait('result')
        self.send(command='history');before=self.wait('history')['entries']
        self.stt.transcript='Dies bleibt ein privates künstliches Testdiktat'
        self.record(command='startTest');test=self.wait('testResult')
        self.assertNotEqual(regular['text'],test['text'])
        self.send(command='history');after=self.wait('history')['entries']
        self.assertEqual(len(after),len(before)+1)
        self.assertIn(before[0],after)
        self.assertTrue(any(x['cleanText']==test['text'] for x in after))
        self.send(command='recall');self.assertEqual(self.wait('recall')['text'],regular['text'])
    def enable_preview(self):
        self.send(command='config');snapshot=self.wait('config')['config']
        updated=json.loads(json.dumps(snapshot));updated['ui']['previewBeforePaste']=True
        self.send(command='saveConfig',config=updated,expected=snapshot);self.wait('configSaved')
    def test_preview_is_remembered_only_after_confirmation(self):
        self.enable_preview();self.record();result=self.wait('result')
        self.assertTrue(result['preview']);self.assertTrue(result['candidate'])
        self.send(command='recall');self.wait('notice')
        self.send(command='completePreview',candidate=result['candidate'],accepted=True);self.wait('previewCompleted')
        self.send(command='recall');self.assertEqual(self.wait('recall')['text'],result['text'])
    def test_discarded_preview_never_becomes_last_result(self):
        self.enable_preview();self.record();result=self.wait('result')
        self.send(command='completePreview',candidate=result['candidate'],accepted=False);self.wait('previewCompleted')
        self.send(command='recall');self.wait('notice')
    def test_multiple_preview_candidates_keep_their_own_confirmation(self):
        self.enable_preview()
        self.stt.transcript='Erster künstlicher Test';self.primary.reply_text='Erster künstlicher Test.'
        self.record();first=self.wait('result')
        self.stt.transcript='Zweiter künstlicher Test';self.primary.reply_text='Zweiter künstlicher Test.'
        self.record();second=self.wait('result')
        self.assertNotEqual(first['text'],second['text'])
        self.assertNotEqual(first['candidate'],second['candidate'])
        self.send(command='completePreview',candidate=first['candidate'],accepted=True);self.wait('previewCompleted')
        self.send(command='completePreview',candidate=second['candidate'],accepted=False);self.wait('previewCompleted')
        self.send(command='recall');self.assertEqual(self.wait('recall')['text'],first['text'])
    def test_temporary_private_history_keeps_only_transient_result(self):
        self.send(command='privateHistory',enabled=True)
        policy=self.wait('historyPolicy');self.assertFalse(policy['storesText'])
        self.record();result=self.wait('result')
        self.send(command='history');self.assertEqual(self.wait('history')['entries'],[])
        self.send(command='recall');self.assertEqual(self.wait('recall')['text'],result['text'])
        self.assertFalse(list((self.path/'data/recordings').glob('*.wav')))
    def test_stale_history_correction_cannot_overwrite_a_newer_correction(self):
        self.record();self.wait('result')
        self.send(command='history');entry=self.wait('history')['entries'][0]
        self.send(command='editHistory',expected=entry,text='Erste künstliche Korrektur.')
        saved=self.wait('historySaved')['entry']
        self.send(command='editHistory',expected=entry,text='Veraltete künstliche Korrektur.')
        self.wait('error')
        self.send(command='history');current=self.wait('history')['entries'][0]
        self.assertEqual(current['cleanText'],saved['cleanText'])
        self.assertEqual(current['rawText'],entry['rawText'])
    def audio_file(self):
        path=self.path/'fixture.wav'
        with wave.open(str(path),'wb') as audio:
            audio.setnchannels(1);audio.setsampwidth(2);audio.setframerate(16000)
            audio.writeframes(b''.join(struct.pack('<h',int(10000*math.sin(i/16000*2*math.pi*220))) for i in range(32000)))
        return path
    def test_import_after_test_dictation_keeps_its_own_result(self):
        self.record('startTest');self.wait('testResult')
        path=self.audio_file();original=path.read_bytes()
        self.send(command='reviewImport');review=self.wait('importReview')
        self.send(command='import',path=str(path),reviewed=review['configuration'])
        result=self.wait('importResult')
        self.assertTrue(result['text']);self.assertFalse(result['failed'])
        self.assertEqual(path.read_bytes(),original)
        self.assertEqual(len(self.stt.audio),3)
        self.send(command='closeImport')
        self.record();self.assertTrue(self.wait('result')['text'])
        self.send(command='testReport');report=self.wait('testReport')['text']
        self.assertIn('test.state=completed',report)
        self.assertNotIn('künstlicher',report)
    def test_test_dictation_reports_missing_input_without_starting_audio(self):
        self.send(command='reviewTest');review=self.wait('testReview')
        self.send(command='startTest',reviewed=review['configuration'],inputAvailable=False)
        status=self.wait('testStatus')
        self.assertEqual(status['state'],'failed');self.assertFalse(status['active']);self.assertTrue(status['error'])
        self.assertFalse(self.stt.audio);self.assertFalse(self.primary.cleanup)
        self.send(command='testReport');report=self.wait('testReport')['text']
        self.assertIn('test.state=failed',report)
        self.assertNotIn(str(self.path),report)
    def test_test_dictation_rejects_changed_review(self):
        self.send(command='reviewTest');review=self.wait('testReview')
        self.send(command='privateHistory',enabled=True);self.wait('historyPolicy')
        self.send(command='startTest',reviewed=review['configuration'],inputAvailable=True)
        status=self.wait('testStatus')
        self.assertEqual(status['state'],'failed');self.assertFalse(status['active'])
        self.assertFalse(self.stt.audio)
    def test_import_rejects_changed_review_and_does_not_start_audio(self):
        self.send(command='reviewImport');review=self.wait('importReview')
        self.send(command='privateHistory',enabled=True);self.wait('historyPolicy')
        self.send(command='import',path=str(self.audio_file()),reviewed=review['configuration'])
        status=self.wait('importStatus')
        self.assertFalse(status['active']);self.assertTrue(status['finished']);self.assertTrue(status['error'])
        self.assertFalse(self.stt.audio);self.assertFalse(self.primary.cleanup)
    def test_closing_import_does_not_cancel_an_unrelated_recording(self):
        self.send(command='start');self.wait('state','recording')
        self.send(command='closeImport')
        samples=[.25*math.sin(i/16000*2*math.pi*220) for i in range(32000)]
        for offset in range(0,len(samples),2048):
            block=samples[offset:offset+2048]
            self.send(command='samples',data=base64.b64encode(struct.pack('<'+'f'*len(block),*block)).decode())
        self.send(command='stop');self.assertTrue(self.wait('result')['text'])
    def test_selection_cleanup_has_no_audio_or_history_side_effects(self):
        self.send(command='cleanupSelection',text='Dies ist ein künstlicher Test',application='linux.fixture')
        result=self.wait('selectionPreview')
        self.assertEqual(result['text'],'Dies ist ein künstlicher Test.')
        self.assertFalse(result['rawFallback'])
        self.assertEqual(len(self.stt.audio),0)
        self.assertEqual(len([x for x in self.primary.cleanup if x.get('messages')]),1)
        self.send(command='history')
        self.assertEqual(self.wait('history')['entries'],[])
        self.assertFalse(list((self.path/'data/recordings').glob('*.wav')))
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
    def test_large_configuration_message_does_not_disconnect_worker(self):
        self.send(command='config',padding='ä'*150000)
        config=self.wait('config')['config']
        self.assertEqual(config['whisper']['language'],'de')
        self.send(command='history');self.assertEqual(self.wait('history')['entries'],[])
    def test_quit_and_parent_pipe_closure_share_one_shutdown(self):
        for _ in range(10):
            process=subprocess.Popen(self.process.args,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=self.worker_environment)
            process.communicate(input=b'{"command":"quit"}\n',timeout=8)
            self.assertEqual(process.returncode,0)
    def test_closed_output_pipe_still_shuts_down_worker_cleanly(self):
        process=subprocess.Popen(self.process.args,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=self.worker_environment)
        process.stdout.close()
        try:
            process.wait(timeout=8)
            self.assertEqual(process.returncode,0)
        finally:
            if process.poll() is None:process.kill();process.wait()
            process.stdin.close();process.stderr.close()
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
