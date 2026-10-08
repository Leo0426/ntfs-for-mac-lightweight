from pathlib import Path
import hashlib,shlex,subprocess,re
binary=Path('.scratch/write-identity-bug/ReadOnlyHelperFacts').resolve()
digest=hashlib.sha256(binary.read_bytes()).hexdigest()
script='''import os,stat,tempfile,hashlib,subprocess
from pathlib import Path
path=Path(__PATH__)
fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
s=os.fstat(fd)
assert stat.S_ISREG(s.st_mode) and s.st_uid==501
with os.fdopen(fd,'rb') as f: data=f.read()
assert hashlib.sha256(data).hexdigest()==__HASH__
stage=Path(tempfile.mkdtemp(prefix='ntfslite-readonly-diag-',dir='/private/var/tmp'))
exe=stage/'ReadOnlyHelperFacts'
with open(exe,'xb') as f: f.write(data)
os.chmod(exe,0o555); os.chmod(stage,0o755)
subprocess.run(['/usr/bin/codesign','--verify','--strict','-R=anchor apple generic and identifier "com.leolu.ntfslite.readonly" and certificate leaf[subject.OU] = "NP3U2GYHWL"',str(exe)],check=True)
p=subprocess.run([str(exe)],capture_output=True,text=True,timeout=90)
print(p.stdout,end=''); print(p.stderr,end='')
raise SystemExit(p.returncode)
'''.replace('__PATH__',repr(str(binary))).replace('__HASH__',repr(digest))
p=subprocess.run(['/usr/bin/osascript','-e','on run argv\nreturn do shell script (item 1 of argv) with administrator privileges\nend run','/usr/bin/python3 -c '+shlex.quote(script)],capture_output=True,text=True)
Path('.scratch/write-identity-bug/root-facts.txt').write_text(p.stdout+p.stderr)
for line in (p.stdout+p.stderr).splitlines():
 if '[D-LITE]' in line or 'owned=' in line: print(line)
raise SystemExit(p.returncode)
