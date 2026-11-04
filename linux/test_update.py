#!/usr/bin/env python3
import hashlib,io,json,os,pathlib,shutil,subprocess,tarfile,tempfile,unittest
from unittest.mock import patch
from update import Updater,UpdateError,PRODUCT

class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=pathlib.Path(self.tmp.name);self.bundle=self.root/'stillepost/app/0.9.47';(self.bundle/'bin').mkdir(parents=True)
        (self.bundle/'bin/openssl').symlink_to(shutil.which('openssl'))
        self.private=self.root/'private.pem';self.public=self.bundle/'update-public.pem'
        subprocess.run(['openssl','genpkey','-algorithm','ED25519','-out',str(self.private)],check=True,capture_output=True)
        subprocess.run(['openssl','pkey','-in',str(self.private),'-pubout','-out',str(self.public)],check=True,capture_output=True)
        (self.bundle/'linux-build.json').write_text('{"build":9047}')
        (self.bundle.parent/'current').symlink_to(self.bundle.name)
        self.manifest=self.root/'manifest';self.signature=self.root/'signature'
        self.data={'product':PRODUCT,'channel':'stable','arch':'x86_64','build':9048,'version':'0.9.48','min_glibc':'2.39','size':10,'sha256':'0'*64,'url':'https://github.com/DanielMuellerIR/stille_post/releases/download/v0.9.48/StillePost-linux.tar.gz'}
        self.updater=Updater(self.bundle)
    def sign(self):
        self.manifest.write_text(json.dumps(self.data))
        subprocess.run(['openssl','pkeyutl','-sign','-inkey',str(self.private),'-rawin','-in',str(self.manifest),'-out',str(self.signature)],check=True,capture_output=True)
    def test_valid_signed_manifest(self):
        self.sign();self.assertEqual(self.updater.verify(self.manifest,self.signature)['build'],9048)
    def test_tampered_manifest_is_rejected(self):
        self.sign();self.manifest.write_bytes(self.manifest.read_bytes()+b' ')
        with self.assertRaises(UpdateError):self.updater.verify(self.manifest,self.signature)
    def test_other_product_and_download_source_rejected_even_when_signed(self):
        for key,value in [('product','other'),('url','https://example.org/payload'),('arch','aarch64'),('size',2**40),('build',True)]:
            original=self.data[key];self.data[key]=value;self.sign()
            with self.assertRaises(UpdateError):self.updater.verify(self.manifest,self.signature)
            self.data[key]=original
    def archive(self,name,kind=tarfile.REGTYPE):
        path=self.root/'bad.tar.gz'
        with tarfile.open(path,'w:gz') as tar:
            info=tarfile.TarInfo(name);info.type=kind
            if kind==tarfile.REGTYPE:info.size=1;tar.addfile(info,io.BytesIO(b'x'))
            else:info.linkname='/tmp/escape';tar.addfile(info)
        return path
    def test_traversal_and_links_rejected(self):
        for name,kind in [('StillePost.AppDir/../escape',tarfile.REGTYPE),('/absolute',tarfile.REGTYPE),('StillePost.AppDir/link',tarfile.SYMTYPE),('StillePost.AppDir/fifo',tarfile.FIFOTYPE)]:
            dest=self.root/'dest';dest.mkdir(exist_ok=True)
            with self.assertRaises(UpdateError):Updater.extract(self.archive(name,kind),dest)
    def test_normal_archive_and_atomic_rollback(self):
        dest=self.root/'dest';dest.mkdir();Updater.extract(self.archive('StillePost.AppDir/bin/test'),dest)
        self.assertEqual((dest/'bin/test').read_bytes(),b'x')
        newer=self.bundle.parent/'0.9.48';newer.mkdir();(newer/'AppRun').write_text('fixture');(self.bundle/'AppRun').write_text('fixture')
        Updater.switch(self.bundle.parent,'0.9.48');self.assertEqual((self.bundle.parent/'current').resolve(),newer)
        result=Updater(newer).rollback();self.assertTrue(result['rolledBack']);self.assertEqual((self.bundle.parent/'current').resolve(),self.bundle)
    def test_failed_download_does_not_switch_version(self):
        with patch.dict(os.environ,{'XDG_DATA_HOME':str(self.root)}):
            def fail(*args):raise OSError('fixture')
            self.updater.download=fail
            with self.assertRaises(OSError):self.updater.install()
            self.assertEqual((self.bundle.parent/'current').resolve(),self.bundle)
            self.assertTrue((self.bundle.parent/'.update-lock').is_file())
            with self.assertRaises(OSError):self.updater.install() # Sperre ist nach dem Fehler wieder frei.
    def tearDown(self):self.tmp.cleanup()
if __name__=='__main__':unittest.main(verbosity=2)
