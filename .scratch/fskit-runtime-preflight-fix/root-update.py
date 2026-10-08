import os,sys,stat,subprocess,tempfile,hashlib,json,plistlib
from pathlib import Path
EXPECTED_FILES={'Contents/Info.plist': '78330cd43b66e2aacea4f36a24ea04ce8af3bc38b05759e5873d62c0e1dcc0a5', 'Contents/_CodeSignature/CodeResources': '552f0c88c2f3d334a27ba0b13cb12a26802d56fdb31a4720c7e778277b055a7f', 'Contents/MacOS/NTFSLiteHelper': 'd1ec41a4d3c071ba9801469fca501bf8529dc3248d1b9a23c0c82cef2a8ffe83', 'Contents/MacOS/NTFSLiteReadOnlyApp': '19a1f8d967218d06f03732afd01e6978fc9dac551d53e72b4d7344d3175e0da4', 'Contents/Resources/NTFSLite.icns': '316966680d7835d000d61cfc0872c4de1a3654562b6b54c8bab848018d7d259d', 'Contents/Resources/FSKitRuntimeProbe.ntfs.zlib': 'bc13f484e9bc508733246b1bc2145068041b883a5eaad32273106d54c09d7c34', 'Contents/Helpers/ntfs-3g.probe': '9a87e20665692ad8dc33c3a984025e9753cae80990c26e6b88d45c0e0e67647f', 'Contents/Helpers/ntfs-3g': '371c6071d5e25243336afdd90cc2f771d4ad43af7944a6cacd481cf5f9387cdd', 'Contents/Library/LaunchDaemons/com.leolu.ntfslite.helper.v2.plist': '61b68feb490ad1fc8339d96270336ffeed1c37ff1689ad97fe62af295cd0fe66'}
OLD_FILES={'Contents/Info.plist': '722e5a0ce660bff985d6833a31037d76b3d57af4f7ec3b5ced41be8d2cb3b6df', 'Contents/_CodeSignature/CodeResources': 'b694afd57c3e36adad4555b4ee341fbc863e05b023ca600c2e628f07f12f07ee', 'Contents/MacOS/NTFSLiteHelper': '26bf48aa2f0988a2dc22fbc75724513b98ced237a06389c7952f8639750a747f', 'Contents/MacOS/NTFSLiteReadOnlyApp': 'dcbb3be2251a7e07a567e06458525a5ab988be8dfa629e1426e121338d66be2c', 'Contents/Resources/NTFSLite.icns': '316966680d7835d000d61cfc0872c4de1a3654562b6b54c8bab848018d7d259d', 'Contents/Library/LaunchDaemons/com.leolu.ntfslite.helper.v2.plist': '61b68feb490ad1fc8339d96270336ffeed1c37ff1689ad97fe62af295cd0fe66', 'Contents/Helpers/ntfs-3g.probe': '567602ae3c0e7e530861ea41e6e8bc22b95ff85c26c5c1ceaf35a836ec450777', 'Contents/Helpers/ntfs-3g': '4b37998f6728436f6af632d72438df988d3d9f3ca0db17abe3e71408eb54a926'}
SOURCE='/Users/heyonepiece/Projects/chatgpt_worktrees/protected-helper-install/ntfs-for-mac-lightweight/.build/NTFSLite-local.pkg'
DIGEST='5708d93a878a3de4820e76312d551205b77599b10f303787bdaddbc6a7b057b2'
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
  assert stat.S_ISREG(s.st_mode) and s.st_uid==501 and s.st_size==4481366,'invalid source file'
  with os.fdopen(fd,'rb',closefd=False) as f: data=f.read(4481367)
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
 assert info['CFBundleShortVersionString']=='0.1.4' and info['CFBundleVersion']=='5'
 idle()
 print('PASS: protected App 0.1.4 (5) installed; signatures, permissions, every file digest and idle service state verified.')
 print('BACKUP='+str(backup))
finally:
 os.rmdir(lock)
