#!/usr/bin/env python3
"""Synthetic signed candidate tests. Generates a disposable APT key, never uses production secrets."""
import base64, copy, hashlib, importlib.util, io, json, os, subprocess, sys, tarfile, tempfile, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]; sys.path.insert(0, str(ROOT/'scripts'))
spec = importlib.util.spec_from_file_location('prepare', ROOT/'scripts/prepare-socialbox-release.py')
p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p)

def tar(files):
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode='w:gz') as archive:
        for name, data in files.items():
            entry = tarfile.TarInfo(name); entry.size = len(data); archive.addfile(entry, io.BytesIO(data))
    return raw.getvalue()

class PreparationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # macOS gpg-agent uses a Unix socket; the default per-user temp path can exceed its limit.
        cls.scratch = tempfile.TemporaryDirectory(prefix='sb-release-', dir='/tmp'); cls.root = Path(cls.scratch.name)
        cls.old = os.environ.get('GNUPGHOME'); os.environ['GNUPGHOME'] = str(cls.root/'gnupg'); Path(os.environ['GNUPGHOME']).mkdir(mode=0o700)
        subprocess.run(['gpg','--batch','--pinentry-mode','loopback','--passphrase','','--quick-generate-key','Synthetic release test <test@invalid>','rsa2048','sign','1d'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        listing = subprocess.check_output(['gpg','--batch','--with-colons','--list-secret-keys'],stderr=subprocess.DEVNULL).decode()
        cls.fingerprint = next(line.split(':')[9] for line in listing.splitlines() if line.startswith('fpr:'))
    @classmethod
    def tearDownClass(cls):
        subprocess.run(['gpgconf','--kill','gpg-agent'],check=False,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        if cls.old is None: os.environ.pop('GNUPGHOME',None)
        else: os.environ['GNUPGHOME']=cls.old
        cls.scratch.cleanup()
    def setUp(self):
        self.controls={'control': b'Package: com.socialbox\nVersion: 3.1.0-1+socialbox.16\nArchitecture: iphoneos-arm64\nName: SocialBox\nDescription: Synthetic test\n',
            'preinst':b'#!/bin/sh\nexit 0\n','postinst':b'#!/bin/sh\nexit 0\n','prerm':b'#!/bin/sh\nexit 0\n','md5sums':b''}
        self.payload={'var/jb/Applications/Fixture.app/test':b'not an executable'}
        self.report={'version':'3.1.0-1+socialbox.16','upgrade_from':'3.1.0-1+socialbox.15','original_controls_backup_required':True,
            'residuals':['Synthetic unresolved engineering blocker'], 'deployment':{'replacement_postinst_sha256':p.digest(self.controls['postinst'])},
            'payload_sha256':{n:p.digest(v) for n,v in self.payload.items()}}
        self.write()
    def write(self):
        raw=bytearray(b'!<arch>\n')
        for name,data in [('debian-binary',b'2.0\n'),('control.tar.gz',tar(self.controls)),('data.tar.gz',tar(self.payload))]:
            raw+=f"{name+'/':<16}{0:<12}{0:<6}{0:<6}{'100644':<8}{len(data):<10}`\n".encode()+data+(b'\n' if len(data)%2 else b'')
        self.package=self.root/'fixture.deb'; self.package.write_bytes(raw);self.report['package_sha256']=p.digest(raw)
    def prepare(self): return p.prepare(self.package,self.report,'Synthetic notes',self.fingerprint,'fixture.public.blob.vercel-storage.com','1'*40)
    def test_signed_snapshot_preserves_blockers_and_exact_upgrade(self):
        c=self.prepare();self.assertEqual(c['blockers'],self.report['residuals']);self.assertEqual(c['supportedFrom'],['3.1.0-1+socialbox.15'])
        for name,file in c['files'].items(): self.assertEqual(p.digest(base64.b64decode(file['base64'])),file['sha256'])
        packages=base64.b64decode(c['files']['Packages']['base64']).decode();self.assertIn('SHA256: '+self.report['package_sha256'],packages)
        self.assertIn('Version: 3.1.0-1+socialbox.16',packages)
        release=base64.b64decode(c['files']['Release']['base64']).decode();self.assertIn('Acquire-By-Hash: yes',release)
        self.assertIn(c['files']['Packages']['sha256'],release)
    def test_package_tamper(self):
        self.package.write_bytes(self.package.read_bytes()+b'x')
        with self.assertRaises(ValueError):self.prepare()
    def test_payload_manifest_mismatch(self):
        self.report['payload_sha256']={}
        with self.assertRaisesRegex(ValueError,'Payload differs'):self.prepare()
    def test_postinst_mismatch(self):
        pinned=self.report['package_sha256']
        self.controls['postinst']+=b'# unreviewed change\n';self.write();self.report['package_sha256']=pinned
        with self.assertRaisesRegex(ValueError,'Package differs'):self.prepare()
    def test_unreviewed_postrm_rejected(self):
        self.controls['postrm']=b'#!/bin/sh\nexit 0\n';self.write()
        with self.assertRaisesRegex(ValueError,'Unexpected upgrade controls'):self.prepare()
    def test_no_implicit_predecessor_or_residual_override(self):
        for field in ['upgrade_from','residuals','original_controls_backup_required']:
            old=self.report.pop(field)
            with self.assertRaises(ValueError):self.prepare()
            self.report[field]=old
    def test_wrong_architecture_and_ownership(self):
        self.controls['control']=self.controls['control'].replace(b'iphoneos-arm64',b'iphoneos-arm');self.write()
        with self.assertRaisesRegex(ValueError,'Wrong package identity'):self.prepare()
    def test_unrelated_real_commit_cannot_claim_build_provenance(self):
        commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
        report=copy.deepcopy(self.report)
        report.update(builder_sha256='0'*64,overlay_build_inputs={'sha256':{'lucid/Presentation/LBXWorkspace.m':'0'*64}},helper_build_inputs={'sha256':{'lucid/HelperSafety/LBXHelperSafety.m':'0'*64}})
        with self.assertRaisesRegex(ValueError,'Build input differs'):p.verify_build_commit(report,commit)

if __name__=='__main__':unittest.main()
