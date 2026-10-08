import os,sys,stat,subprocess,tempfile,hashlib,json,plistlib
from pathlib import Path
EXPECTED_FILES={'Contents/Info.plist': '270920a9a1bada5208a78f07761f0bda3b7a1ed7f77c7e4b893d6018d3f27473', 'Contents/_CodeSignature/CodeResources': '877336cf3070c6100c78f2efa77b59b13f3a1bf82a517202a21c3b780b8a4ea4', 'Contents/MacOS/NTFSLiteHelper': 'f6a7136a9e1a2539b353b4c59dee814081ea852925dfaf2ab6aefdbc0a7b2bfe', 'Contents/MacOS/NTFSLiteReadOnlyApp': '12f530915ef63ad45d972820bc200efadef2758bb11d0e2d1f16474e54648592', 'Contents/Resources/NTFSLite.icns': '316966680d7835d000d61cfc0872c4de1a3654562b6b54c8bab848018d7d259d', 'Contents/Resources/FSKitRuntimeProbe.ntfs.zlib': 'bc13f484e9bc508733246b1bc2145068041b883a5eaad32273106d54c09d7c34', 'Contents/Helpers/ntfs-3g.probe': '6888a21305c32dbca2f334546637dbb990678c114e221da8ed36d61ccec980a6', 'Contents/Helpers/ntfs-3g': '6b3887c19f2d46b607ac2bb2354de914edfb8354dbad90d1b3460d30c7ad8a49', 'Contents/Library/LaunchDaemons/com.leolu.ntfslite.helper.v2.plist': '61b68feb490ad1fc8339d96270336ffeed1c37ff1689ad97fe62af295cd0fe66'}
OLD_FILES={'Contents/Info.plist': 'f7168b4dc724c1ea08289eac6e317c5d621b249438b56cdd1080e01616fd45f1', 'Contents/_CodeSignature/CodeResources': '877336cf3070c6100c78f2efa77b59b13f3a1bf82a517202a21c3b780b8a4ea4', 'Contents/MacOS/NTFSLiteHelper': 'c2518418695e133498edc58fd53da3aa3e3016ef3952814fd24847a389d48d05', 'Contents/MacOS/NTFSLiteReadOnlyApp': '116b7792871e9a261803376b744ac6d372e5f1bbc3a1dcb7d5619539a9f43690', 'Contents/Resources/NTFSLite.icns': '316966680d7835d000d61cfc0872c4de1a3654562b6b54c8bab848018d7d259d', 'Contents/Resources/FSKitRuntimeProbe.ntfs.zlib': 'bc13f484e9bc508733246b1bc2145068041b883a5eaad32273106d54c09d7c34', 'Contents/Library/LaunchDaemons/com.leolu.ntfslite.helper.v2.plist': '61b68feb490ad1fc8339d96270336ffeed1c37ff1689ad97fe62af295cd0fe66', 'Contents/Helpers/ntfs-3g.probe': 'ebe36ec4399ba55084a7df608f2eb580694c09ecac74015095f0bd8a2991c714', 'Contents/Helpers/ntfs-3g': '085279e4f4238cb2b96164568feb4f5f4c8c7b64f6166e0ab331f5e1fb8a81b9'}
SOURCE='/Users/heyonepiece/Projects/personal_projects/ntfs-for-mac-lightweight/.build/NTFSLite-local.pkg'
DIGEST='53bada4a5c76c11a645a825b6800a30b55629e1e5787a3e33978f429f26ca5fa'
ROOT=Path('/Library/PrivilegedHelperTools')
APP=ROOT/'NTFSLite.app'
REQ='-R=anchor apple generic and certificate leaf[subject.OU] = "NP3U2GYHWL" and identifier "com.leolu.ntfslite.readonly"'
def run(args):
 return subprocess.run(args,check=True,capture_output=True,text=True,timeout=60).stdout
def safe_tree(root):
 for path in [root]+list(root.rglob('*')):
  s=path.lstat()
  assert s.st_uid==0 and s.st_gid==0 and not s.st_mode&0o022, 'unsafe owner/mode'
  assert stat.S_ISDIR(s.st_mode) or stat.S_ISREG(s.st_mode),'unsafe file type'
  assert len(run(['/bin/ls','-lde',str(path)]).splitlines())==1,'ACL present'
def idle():
 for label in ('com.leolu.ntfslite.helper','com.leolu.ntfslite.helper.v2'):
  p=subprocess.run(['/bin/launchctl','print','system/'+label],capture_output=True,text=True,timeout=15)
  assert p.returncode==113 and 'Could not find service "'+label+'"' in p.stderr, 'service present or unknown'
 procs=run(['/bin/ps','-axo','pid=,comm=']).lower()
 assert 'ntfslite' not in procs and 'ntfs-3g' not in procs,'app/helper/driver process present'
 mounts=run(['/sbin/mount']).lower()
 assert all('read-only' in row and 'macfuse' not in row for row in mounts.splitlines() if 'fskit' in row or 'macfuse' in row),'writable or unknown filesystem active'
 btm=run(['/usr/bin/sfltool','dumpbtm'])
 for block in btm.split('\n\n'):
  if 'Identifier: 16.com.leolu.ntfslite.helper' in block:
   assert 'Disposition: [disabled,' in block,'service background record enabled/unknown'
assert os.geteuid()==0
for parent in (Path('/'),Path('/Library'),ROOT):
 s=parent.lstat()
 assert stat.S_ISDIR(s.st_mode) and s.st_uid==0 and s.st_gid==0 and not s.st_mode&0o022
 assert len(run(['/bin/ls','-lde',str(parent)]).splitlines())==1
safe_tree(APP)
assert {str(p.relative_to(APP)):hashlib.sha256(p.read_bytes()).hexdigest() for p in APP.rglob('*') if p.is_file()}==OLD_FILES, 'old installed app changed'
assert not os.path.lexists('/private/var/db/com.leolu.ntfslite.runtime-probe'), 'unresolved runtime qualification present'
run(['/usr/bin/codesign','--verify','--strict','--deep',REQ,str(APP)])
idle()
lock=ROOT/'.NTFSLite-maintenance-lock'
os.mkdir(lock,0o700)
stage=None
try:
 fd=os.open(SOURCE,os.O_RDONLY|os.O_NOFOLLOW)
 try:
  s=os.fstat(fd)
  assert stat.S_ISREG(s.st_mode) and s.st_uid==501 and s.st_size==4503881,'invalid source file'
  with os.fdopen(fd,'rb',closefd=False) as f: data=f.read(4503882)
 finally: os.close(fd)
 assert hashlib.sha256(data).hexdigest()==DIGEST,'package changed'
 stage=Path(tempfile.mkdtemp(prefix='ntfslite-maintenance-',dir='/private/var/tmp'))
 os.chmod(stage,0o700)
 package=stage/'package.pkg'
 with open(package,'xb') as f: f.write(data)
 os.chmod(package,0o400)
 assert hashlib.sha256(package.read_bytes()).hexdigest()==DIGEST
 idle()
 backup=stage/'previous-NTFSLite.app'
 os.rename(APP,backup)
 print('BACKUP='+str(backup),flush=True)
 p=subprocess.run(['/usr/sbin/installer','-pkg',str(package),'-target','/'],capture_output=True,text=True,timeout=180)
 print(p.stdout,flush=True)
 if p.returncode: print(p.stderr,flush=True); raise RuntimeError('Installer failed; backup retained: '+str(backup))
 safe_tree(APP)
 actual={str(p.relative_to(APP)):hashlib.sha256(p.read_bytes()).hexdigest() for p in APP.rglob('*') if p.is_file()}
 assert actual==EXPECTED_FILES,'installed files differ from verified package'
 run(['/usr/bin/codesign','--verify','--strict','--deep',REQ,str(APP)])
 info=plistlib.loads((APP/'Contents/Info.plist').read_bytes())
 assert info['CFBundleShortVersionString']=='0.1.6' and info['CFBundleVersion']=='7'
 idle()
 print('PASS: protected App 0.1.6 (7) installed; signatures, permissions, every file digest and idle service state verified.')
 print('BACKUP='+str(backup))
finally:
 os.rmdir(lock)
