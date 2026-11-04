#!/usr/bin/env python3
"""Privaten PEM-Schlüssel nur über stdin oder den Secret-Store der Release-CI beziehen."""
import argparse,os,pathlib,subprocess,sys,tempfile
p=argparse.ArgumentParser();p.add_argument('manifest');p.add_argument('signature');a=p.parse_args()
os.umask(0o077)
key=sys.stdin.buffer.read(65537)
if len(key)>65536 or b'PRIVATE KEY' not in key:raise SystemExit('Kein gültiger Ed25519-Schlüssel auf stdin.')
with tempfile.TemporaryDirectory(prefix='stillepost-sign-') as temporary:
 path=pathlib.Path(temporary)/'key.pem';path.write_bytes(key)
 subprocess.run(['openssl','pkeyutl','-sign','-rawin','-inkey',str(path),'-in',a.manifest,'-out',a.signature],check=True,capture_output=True)
print('Manifest signiert; temporärer Schlüssel entfernt.')
