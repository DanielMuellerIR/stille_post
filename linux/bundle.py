#!/usr/bin/env python3
"""Packt die bereits gebauten ELF-Dateien samt Laufzeit, ohne Host-GPU-Treiber."""
import pathlib, shutil, subprocess, re, os, uuid
root=pathlib.Path('/src')
destination=root/'build/linux/StillePost.AppDir'
bundle=root/('build/linux/.StillePost-stage-'+uuid.uuid4().hex)
swift_dir=pathlib.Path(os.environ.get('SWIFT_BINARY_DIR',str(root/'.build/debug')))
(bundle/'bin').mkdir(parents=True,exist_ok=True)
(bundle/'lib').mkdir(exist_ok=True)
for source,name in [(root/'build/linux/qt/stillepost','stillepost'),(swift_dir/'stillepost-linux','stillepost-linux'),(root/'build/linux/whisper/bin/whisper-server','whisper-server'),(pathlib.Path('/usr/bin/ffmpeg'),'ffmpeg'),(pathlib.Path('/usr/bin/secret-tool'),'secret-tool'),(pathlib.Path('/usr/bin/openssl'),'openssl')]:
 shutil.copy2(source,bundle/'bin'/name)
shutil.copytree(swift_dir/'StillePost_StillePostCore.resources',bundle/'bin/StillePost_StillePostCore.resources',dirs_exist_ok=True)
plugins=pathlib.Path('/usr/lib/x86_64-linux-gnu/qt6/plugins')
for directory in ['platforms','platforminputcontexts','imageformats','multimedia','wayland-decoration-client','wayland-graphics-integration-client','wayland-shell-integration','xcbglintegrations','tls']:
 if (plugins/directory).exists():shutil.copytree(plugins/directory,bundle/'plugins'/directory,dirs_exist_ok=True)
shutil.copytree('/etc/fonts',bundle/'fontconfig',dirs_exist_ok=True)
# Systemloader, glibc und Grafiktreiber müssen vom Zielsystem kommen.
exclude=re.compile(r'^(ld-linux|libc\.|libm\.|libpthread\.|libdl\.|librt\.|libresolv\.|libnss_|libvulkan\.|libGLX\.|libGLdispatch\.|libGL\.|libEGL\.|libdrm|libgbm)')
queue=[p for p in bundle.rglob('*') if p.is_file() and ('.so' in p.name or p.parent.name=='bin')]
seen=set()
while queue:
 p=queue.pop()
 if str(p) in seen:continue
 seen.add(str(p))
 result=subprocess.run(['ldd',str(p)],text=True,capture_output=True)
 for source in re.findall(r'=> (/[^ ]+)',result.stdout):
  src=pathlib.Path(source)
  if exclude.match(src.name):continue
  dest=bundle/'lib'/src.name
  if not dest.exists():shutil.copy2(src,dest);queue.append(dest)
if (root/'build/linux/ollama/bin/ollama').exists():
 shutil.copy2(root/'build/linux/ollama/bin/ollama',bundle/'bin/ollama')
 shutil.copytree(root/'build/linux/ollama/lib/ollama',bundle/'lib/ollama',dirs_exist_ok=True)
# Qt-Plugins müssen die mitgelieferte Qt-Version finden.
(bundle/'bin/qt.conf').write_text('[Paths]\nPlugins=../plugins\nLibraries=../lib\n')
shutil.copy2(root/'linux/AppRun',bundle/'AppRun')
os.chmod(bundle/'AppRun',0o755)
shutil.copy2(root/'linux/install.sh',bundle/'install.sh')
shutil.copy2(root/'linux/stillepost.desktop',bundle/'stillepost.desktop')
for name in ['update.py','launcher.py','update-public.pem','setup-models.py']:
 shutil.copy2(root/'linux'/name,bundle/name)
version=(root/'VERSION').read_text().strip()
major,minor,patch=map(int,version.split('.'))
(bundle/'linux-build.json').write_text(__import__('json').dumps({'build':major*1000000+minor*1000+patch,'version':version}))
shutil.copy2(root/'VERSION',bundle/'VERSION')
shutil.copy2(root/'LICENSE',bundle/'LICENSE')
shutil.copy2(root/'linux/icon.png',bundle/'icon.png')
shutil.copy2(root/'THIRD-PARTY.md',bundle/'THIRD-PARTY.md')
licenses=bundle/'licenses';licenses.mkdir(exist_ok=True)
for package in pathlib.Path('/usr/share/doc').iterdir():
 if (package/'copyright').exists():shutil.copy2(package/'copyright',licenses/(package.name+'.copyright'))
shutil.copy2(root/'build/linux/whisper-src/LICENSE',licenses/'whisper.cpp.LICENSE')
if destination.exists():
 retired=root/('build/linux/.StillePost-retired-'+uuid.uuid4().hex)
 destination.rename(retired)
else:retired=None
bundle.rename(destination)
if retired:shutil.rmtree(retired)
print('Bundle:',destination,'files:',sum(1 for p in destination.rglob('*') if p.is_file()))
