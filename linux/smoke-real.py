#!/usr/bin/env python3
"""Realer Textdienst/Whisper, ausschließlich das übergebene künstliche Referenzaudio."""
import argparse,json,os,pathlib,queue,subprocess,threading,time
p=argparse.ArgumentParser();p.add_argument('--bundle',required=True);p.add_argument('--config',required=True);p.add_argument('--audio');p.add_argument('--cleanup-only',action='store_true');a=p.parse_args()
bundle=pathlib.Path(a.bundle).resolve();config=pathlib.Path(a.config).resolve()
env=dict(os.environ,STILLEPOST_CONFIG=str(config),LD_LIBRARY_PATH=str(bundle/'lib'))
start=time.monotonic()
if a.cleanup_only:
 r=subprocess.run([str(bundle/'bin/stillepost-linux'),'--cleanup'],input=b'dies ist ein synthetischer test morgen beginnt die besprechung um zehn uhr',capture_output=True,env=env,timeout=180,check=True)
 result=json.loads(r.stdout)
 assert not result['rawFallback'] and 'synthetischer' in result['text'].lower(), 'Lokales Modell hat kein gültiges Ergebnis geliefert'
 print(json.dumps({'ok':True,'seconds':round(time.monotonic()-start,3),'characters':len(result['text']),'rawFallback':result['rawFallback']}))
else:
 process=subprocess.Popen([str(bundle/'bin/stillepost-linux')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env)
 events=queue.Queue()
 def reader():
  for line in process.stdout:events.put(json.loads(line))
 threading.Thread(target=reader,daemon=True).start()
 try:
  while events.get(timeout=10).get('event')!='ready':pass
  process.stdin.write((json.dumps({'command':'import','path':str(pathlib.Path(a.audio).resolve())})+'\n').encode());process.stdin.flush()
  while True:
   event=events.get(timeout=180)
   if event['event']=='error':raise AssertionError(event['message'])
   if event['event']=='result':
    text=event['text'].lower()
    assert 'künstlicher' in text and 'besprechung' in text, 'Referenzwörter fehlen'
    print(json.dumps({'ok':True,'seconds':round(time.monotonic()-start,3),'characters':len(text),'rawFallback':event['rawFallback']}));break
 finally:
  process.stdin.write(b'{"command":"quit"}\n');process.stdin.flush();process.wait(timeout=10)
