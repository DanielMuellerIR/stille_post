#!/usr/bin/env python3
"""Öffentliche Modelle einmalig und geprüft im privaten Benutzerdatenordner ablegen."""
import hashlib,json,os,pathlib,subprocess,sys,time,urllib.request
REVISION='5359861c739e955e79d9a303bcbc70fb988958b1'
WHISPER_SHA='1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69'
GEMMA_SHA='ee665637121887cf3befff38abbb1be4ee117c7db867d97a67e29049ecd7e15f'
bundle=pathlib.Path(__file__).resolve().parent
root=pathlib.Path(os.environ.get('XDG_DATA_HOME',str(pathlib.Path.home()/'.local/share')))/'stillepost'
def digest(path):
 h=hashlib.sha256()
 with path.open('rb') as file:
  for block in iter(lambda:file.read(1048576),b''):h.update(block)
 return h.hexdigest()
def main():
 os.umask(0o077);models=root/'models';models.mkdir(parents=True,exist_ok=True)
 target=models/'ggml-large-v3-turbo.bin'
 if not target.exists():
  temporary=models/'ggml-large-v3-turbo.bin.download'
  opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
  print('Whisper large-v3-turbo laden (1,6 GB) …',flush=True)
  with opener.open('https://huggingface.co/ggerganov/whisper.cpp/resolve/'+REVISION+'/ggml-large-v3-turbo.bin',timeout=30) as response,temporary.open('wb') as out:
   count=0
   while True:
    block=response.read(1048576)
    if not block:break
    count+=len(block)
    if count>1624555275:raise RuntimeError('Modell ist zu groß.')
    out.write(block)
  if digest(temporary)!=WHISPER_SHA:raise RuntimeError('Whisper-Prüfsumme stimmt nicht.')
  temporary.rename(target)
 elif digest(target)!=WHISPER_SHA:raise RuntimeError('Vorhandenes Whisper-Modell hat eine andere Prüfsumme; Datei bleibt erhalten.')
 env=dict(os.environ,OLLAMA_HOST='127.0.0.1:11434',OLLAMA_MODELS=str(root/'ollama-models'),OLLAMA_NUM_PARALLEL='1',OLLAMA_MAX_LOADED_MODELS='1',LD_LIBRARY_PATH=str(bundle/'lib'))
 opener=urllib.request.build_opener(urllib.request.ProxyHandler({}));owned=None
 try:
  try:opener.open('http://127.0.0.1:11434/api/tags',timeout=1).close()
  except OSError:
   owned=subprocess.Popen([str(bundle/'bin/ollama'),'serve'],env=env,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
   for _ in range(40):
    try:opener.open('http://127.0.0.1:11434/api/tags',timeout=.5).close();break
    except OSError:time.sleep(.25)
  print('Lokalen Gemma-Fallback laden (etwa 6,2 GB) …',flush=True)
  subprocess.run([str(bundle/'bin/ollama'),'pull','gemma4:e4b-it-qat'],env=env,check=True)
  request=urllib.request.Request('http://127.0.0.1:11434/api/tags')
  data=json.load(opener.open(request,timeout=5))
  found=next((m for m in data.get('models',[]) if m.get('name')=='gemma4:e4b-it-qat'),None)
  if not found or found.get('digest')!=GEMMA_SHA:raise RuntimeError('Gemma-Modellstand hat sich geändert; erneuter Qualitätsabgleich erforderlich.')
 finally:
  if owned:
   owned.terminate()
   try:owned.wait(timeout=5)
   except subprocess.TimeoutExpired:owned.kill();owned.wait()
 print('Modelle sind geprüft und bereit.')
if __name__=='__main__':
 try:main()
 except Exception as error:print('Einrichtung fehlgeschlagen: '+str(error),file=sys.stderr);sys.exit(1)
