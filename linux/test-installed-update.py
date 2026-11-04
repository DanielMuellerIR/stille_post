#!/usr/bin/env python3
"""Opt-in-Paketabnahme: echtes Bundle, kurzlebiger Testschlüssel, kein GitHub-Upload."""
import argparse,hashlib,json,os,pathlib,shutil,subprocess,tarfile,tempfile
from update import Updater,PRODUCT,FEED
p=argparse.ArgumentParser();p.add_argument('--bundle',required=True);p.add_argument('--work-dir',required=True);a=p.parse_args()
os.umask(0o077)
with tempfile.TemporaryDirectory(prefix='update-e2e-',dir=a.work_dir) as temp:
 root=pathlib.Path(temp);source=pathlib.Path(a.bundle).resolve();old=root/'data/stillepost/app/0.9.46';new=root/'payload/StillePost.AppDir'
 old.parent.mkdir(parents=True);new.parent.mkdir()
 for target in [old,new]:subprocess.run(['cp','-a','--reflink=auto',str(source),str(target)],check=True)
 (old/'VERSION').write_text('0.9.46\n');(old/'linux-build.json').write_text('{"build":9046,"version":"0.9.46"}');(old.parent/'current').symlink_to('0.9.46')
 private=root/'test-key.pem';public=root/'test-public.pem'
 subprocess.run(['openssl','genpkey','-algorithm','ED25519','-out',str(private)],check=True,capture_output=True)
 subprocess.run(['openssl','pkey','-in',str(private),'-pubout','-out',str(public)],check=True,capture_output=True)
 for bundle in [old,new]:shutil.copy2(public,bundle/'update-public.pem')
 archive=root/'package.tar.gz'
 with tarfile.open(archive,'w:gz',compresslevel=1) as tar:tar.add(new,arcname='StillePost.AppDir')
 digest=hashlib.sha256()
 with archive.open('rb') as f:
  for block in iter(lambda:f.read(1048576),b''):digest.update(block)
 version=(new/'VERSION').read_text().strip();build=json.loads((new/'linux-build.json').read_text())['build']
 url='https://github.com/DanielMuellerIR/stille_post/releases/download/v'+version+'/test.tar.gz'
 manifest=root/'manifest';signature=root/'manifest.sig'
 manifest.write_text(json.dumps({'product':PRODUCT,'channel':'stable','arch':'x86_64','build':build,'version':version,'min_glibc':'2.39','size':archive.stat().st_size,'sha256':digest.hexdigest(),'url':url}))
 subprocess.run(['openssl','pkeyutl','-sign','-rawin','-inkey',str(private),'-in',str(manifest),'-out',str(signature)],check=True,capture_output=True)
 def local_download(url_,target,limit):
  source_={FEED:manifest,FEED+'.sig':signature,url:archive}[url_]
  if source_.stat().st_size>limit:raise AssertionError('size limit')
  shutil.copyfile(source_,target);return target.stat().st_size
 os.environ['XDG_DATA_HOME']=str(root/'data')
 updater=Updater(old);updater.download=local_download
 assert updater.check()['available']
 assert updater.install()['installed']
 current=(old.parent/'current').resolve();assert current.name==version
 assert not Updater(current).current_build()<build
 assert Updater(current).rollback()['rolledBack'];assert (old.parent/'current').resolve()==old
 print(json.dumps({'ok':True,'from':'0.9.46','to':version,'signature':True,'qtSelfTest':True,'rollback':True}))
