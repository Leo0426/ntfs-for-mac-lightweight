import os,sys,stat,subprocess,tempfile,hashlib,json,plistlib
from pathlib import Path
EXPECTED_FILES={'Contents/Info.plist': '489f0c78b3ae5f43ae839ec3fb483da622742e6c59c7b146972358c949b51634', 'Contents/_CodeSignature/CodeResources': 'b694afd57c3e36adad4555b4ee341fbc863e05b023ca600c2e628f07f12f07ee', 'Contents/MacOS/NTFSLiteHelper': 'd9daed1ab9e4c5894cc35dc6dc7a0e7d737ed4731dae6d19bfd8c8e807dd0682', 'Contents/MacOS/NTFSLiteReadOnlyApp': '4eedc6c9c5dea16f5a2104617176d286e1b101ba0583989535c43b41af94467b', 'Contents/Resources/NTFSLite.icns': '316966680d7835d000d61cfc0872c4de1a3654562b6b54c8bab848018d7d259d', 'Contents/Library/LaunchDaemons/com.leolu.ntfslite.helper.v2.plist': '61b68feb490ad1fc8339d96270336ffeed1c37ff1689ad97fe62af295cd0fe66', 'Contents/Helpers/ntfs-3g.probe': 'a3a896de5631161ffb0f8cd9ca9279bcf5ae39c1216feb39c6e7b1c38ac43a16', 'Contents/Helpers/ntfs-3g': '37c8e317446b55e27680de8915ef0c602a668dbef93970e727f2412b2eda8304'}
SOURCE='/Users/heyonepiece/Projects/chatgpt_worktrees/protected-helper-install/ntfs-for-mac-lightweight/.build/NTFSLite-local.pkg'
DIGEST='8cb098fd31d481cbcdfc258fade584c590ef0183bf7e3d20739833c6d97fa03b'
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
run(['/usr/bin/codesign','--verify','--strict','--deep',REQ,str(APP)])
idle()
lock=ROOT/'.NTFSLite-maintenance-lock'
os.mkdir(lock,0o700)
stage=None
try:
 fd=os.open(SOURCE,os.O_RDONLY|os.O_NOFOLLOW)
 try:
  s=os.fstat(fd)
  assert stat.S_ISREG(s.st_mode) and s.st_uid==501 and s.st_size==4326710,'invalid source file'
  with os.fdopen(fd,'rb',closefd=False) as f: data=f.read(4326711)
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
 assert info['CFBundleShortVersionString']=='0.1.2' and info['CFBundleVersion']=='3'
 idle()
 print('PASS: protected App 0.1.2 (3) installed; signatures, permissions, every file digest and idle service state verified.')
 print('BACKUP='+str(backup))
finally:
 os.rmdir(lock)
