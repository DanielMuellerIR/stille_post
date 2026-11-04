#!/usr/bin/env python3
"""Signierte Linux-Vollupdates. Keine Ausführung heruntergeladener Shellbefehle."""
import argparse, fcntl, hashlib, json, os, pathlib, platform, re, shutil, subprocess, sys, tarfile, tempfile, time, urllib.request, urllib.parse

PRODUCT='io.github.danielmuellerir.stillepost'
FEED='https://danielmuellerir.github.io/stille_post/linux/stable.json'
MAX_PACKAGE=1024*1024*1024
class UpdateError(Exception):pass

class Redirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,req,fp,code,msg,headers,newurl):
        url=urllib.parse.urlsplit(newurl)
        if url.scheme!='https' or url.username or url.password or url.hostname not in {'github.com','release-assets.githubusercontent.com','objects.githubusercontent.com','danielmuellerir.github.io'}:
            raise UpdateError('Unzulässige Download-Weiterleitung.')
        return super().redirect_request(req,fp,code,msg,headers,newurl)

class Updater:
    def __init__(self,bundle,public_key=None,feed=FEED):
        self.bundle=pathlib.Path(bundle).resolve()
        self.key=pathlib.Path(public_key) if public_key else self.bundle/'update-public.pem'
        self.feed=feed
        self.openssl=self.bundle/'bin/openssl'
        self.opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),Redirects())
    def download(self,url,target,limit):
        parts=urllib.parse.urlsplit(url)
        if parts.scheme!='https' or parts.username or parts.password:raise UpdateError('Nur HTTPS ist zulässig.')
        request=urllib.request.Request(url,headers={'User-Agent':'StillePost-Linux-Updater/1'})
        total=0
        with self.opener.open(request,timeout=30) as response,open(target,'xb') as out:
            length=response.headers.get('Content-Length')
            if length and int(length)>limit:raise UpdateError('Download zu groß.')
            while True:
                block=response.read(65536)
                if not block:break
                total+=len(block)
                if total>limit:raise UpdateError('Download zu groß.')
                out.write(block)
        return total
    def verify(self,manifest,signature):
        if not self.key.is_file():raise UpdateError('Vertrauensanker fehlt.')
        result=subprocess.run([str(self.openssl),'pkeyutl','-verify','-pubin','-inkey',str(self.key),'-rawin','-in',str(manifest),'-sigfile',str(signature)],capture_output=True,timeout=5)
        if result.returncode:raise UpdateError('Update-Signatur ist ungültig.')
        raw=pathlib.Path(manifest).read_bytes()
        if len(raw)>65536:raise UpdateError('Manifest zu groß.')
        try:data=json.loads(raw)
        except (ValueError,UnicodeError):raise UpdateError('Manifest unlesbar.')
        if data.get('product')!=PRODUCT or data.get('channel')!='stable' or data.get('arch')!='x86_64' or platform.machine()!='x86_64':raise UpdateError('Update gehört nicht zu dieser Plattform.')
        if type(data.get('build')) is not int or data['build']<1 or type(data.get('size')) is not int or not 0<data['size']<=MAX_PACKAGE:raise UpdateError('Ungültige Build- oder Größenangabe.')
        if not isinstance(data.get('sha256'),str) or len(data['sha256'])!=64 or any(c not in '0123456789abcdef' for c in data['sha256']):raise UpdateError('Ungültige Prüfsumme.')
        version=data.get('version','')
        if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+',version) or len(version)>30:raise UpdateError('Ungültige Version.')
        url=urllib.parse.urlsplit(data.get('url',''))
        if url.scheme!='https' or url.hostname!='github.com' or url.username or url.password or not url.path.startswith('/DanielMuellerIR/stille_post/releases/download/') or url.query or url.fragment:raise UpdateError('Ungültige Paketquelle.')
        minimum=data.get('min_glibc','2.39')
        try:
            required=tuple(int(x) for x in minimum.split('.'))
            actual=tuple(int(x) for x in platform.libc_ver()[1].split('.'))
            if not actual or actual<required:raise UpdateError('Systembibliothek ist zu alt.')
        except ValueError:raise UpdateError('Ungültige Plattformuntergrenze.')
        return data
    def current_build(self):
        try:return json.loads((self.bundle/'linux-build.json').read_text())['build']
        except (OSError,ValueError,KeyError):raise UpdateError('Installationsmetadaten fehlen.')
    def check(self):
        with tempfile.TemporaryDirectory(prefix='stillepost-feed-') as temp:
            manifest=pathlib.Path(temp)/'manifest';signature=pathlib.Path(temp)/'signature'
            self.download(self.feed,manifest,65536);self.download(self.feed+'.sig',signature,256)
            data=self.verify(manifest,signature)
        return {'available':data['build']>self.current_build(),'version':data['version'],'build':data['build']}
    def install(self):
        # Nur die benutzerlokale, versionierte Standardinstallation austauschen.
        root=self.bundle.parent
        data_root=pathlib.Path(os.environ.get('XDG_DATA_HOME',str(pathlib.Path.home()/'.local/share'))).resolve()
        if root!=data_root/'stillepost/app' or not (root/'current').is_symlink() or (root/'current').resolve()!=self.bundle:raise UpdateError('Bitte das Update über die installierte App starten.')
        descriptor=os.open(root/'.update-lock',os.O_CREAT|os.O_RDWR,0o600)
        try:fcntl.flock(descriptor,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(descriptor)
            raise UpdateError('Eine andere Aktualisierung läuft bereits.')
        try:
            with tempfile.TemporaryDirectory(prefix='.update-',dir=root) as temp:
                work=pathlib.Path(temp);manifest=work/'manifest';signature=work/'signature';archive=work/'package.tar.gz'
                self.download(self.feed,manifest,65536);self.download(self.feed+'.sig',signature,256)
                data=self.verify(manifest,signature)
                if data['build']<=self.current_build():raise UpdateError('Kein neueres Update verfügbar.')
                size=self.download(data['url'],archive,data['size'])
                digest=hashlib.sha256()
                with archive.open('rb') as f:
                    for block in iter(lambda:f.read(1048576),b''):digest.update(block)
                if size!=data['size'] or digest.hexdigest()!=data['sha256']:raise UpdateError('Paketprüfung fehlgeschlagen.')
                stage=work/'app';stage.mkdir()
                self.extract(archive,stage)
                version=(stage/'VERSION').read_text().strip()
                metadata=json.loads((stage/'linux-build.json').read_text())
                if version!=data['version'] or metadata.get('build')!=data['build']:raise UpdateError('Paket und Manifest passen nicht zusammen.')
                # Das nächste Update muss weiterhin demselben Vertrauensanker folgen.
                if (stage/'update-public.pem').read_bytes()!=self.key.read_bytes():raise UpdateError('Unbestätigter Schlüsselwechsel.')
                env=dict(os.environ,LD_LIBRARY_PATH=str(stage/'lib'))
                subprocess.run([str(stage/'bin/stillepost-linux'),'--version'],env=env,capture_output=True,check=True,timeout=15)
                env.update(QT_QPA_PLATFORM='offscreen',STILLEPOST_CONFIG=str(work/'smoke-config.json'),STILLEPOST_APP_SUPPORT=str(work/'smoke-data'),STILLEPOST_SCREENSHOT=str(work/'smoke.png'))
                subprocess.run([str(stage/'AppRun'),'--smoke-test'],env=env,capture_output=True,check=True,timeout=20)
                destination=root/version
                if destination.exists():raise UpdateError('Zielversion ist bereits vorhanden.')
                stage.rename(destination)
                self.switch(root,version)
                return {'installed':True,'version':version}
        finally:
            fcntl.flock(descriptor,fcntl.LOCK_UN);os.close(descriptor)
    @staticmethod
    def extract(archive,destination):
        with tarfile.open(archive,'r:gz') as tar:
            members=tar.getmembers();total=0
            if len(members)>12000:raise UpdateError('Zu viele Paketdateien.')
            seen=set()
            for member in members:
                path=pathlib.PurePosixPath(member.name)
                if path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0]!='StillePost.AppDir' or not (member.isfile() or member.isdir()):raise UpdateError('Unsicherer Archivpfad oder Dateityp.')
                total+=member.size
                if total>2*1024**3 or member.size>600*1024**2:raise UpdateError('Entpacktes Paket zu groß.')
                relative=path.parts[1:]
                if not relative:continue
                if tuple(relative) in seen:raise UpdateError('Doppelter Archivpfad.')
                seen.add(tuple(relative));target=destination.joinpath(*relative)
                if member.isdir():target.mkdir(parents=True,exist_ok=True);continue
                target.parent.mkdir(parents=True,exist_ok=True)
                with tar.extractfile(member) as src,target.open('xb') as out:shutil.copyfileobj(src,out,1024*1024)
                target.chmod(0o755 if member.mode&0o111 else 0o644)
    @staticmethod
    def switch(root,version):
        old=os.readlink(root/'current')
        (root/'previous-version').write_text(old+'\n')
        temporary=root/('.current-'+str(os.getpid()));temporary.symlink_to(version);os.replace(temporary,root/'current')
    def rollback(self):
        root=self.bundle.parent
        previous=(root/'previous-version').read_text().strip()
        if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+',previous) or not (root/previous/'AppRun').is_file():raise UpdateError('Keine geprüfte Vorgängerversion vorhanden.')
        self.switch(root,previous);return {'rolledBack':True,'version':previous}

def main():
    parser=argparse.ArgumentParser();parser.add_argument('action',choices=['check','install','rollback']);parser.add_argument('--bundle',default=str(pathlib.Path(__file__).resolve().parent));args=parser.parse_args()
    try:
        updater=Updater(args.bundle);result=getattr(updater,args.action)();print(json.dumps(result));return 0
    except Exception as error:
        message=str(error) if isinstance(error,UpdateError) else 'Update konnte nicht vollständig geprüft werden. Bitte später erneut versuchen.'
        print(json.dumps({'error':message}));return 1
if __name__=='__main__':sys.exit(main())
