import os,pty,termios,fcntl,struct,subprocess,time,select,signal,re,sys,json,tempfile,pathlib
binary=sys.argv[1]
def start(cols=110,rows=34):
 master,slave=pty.openpty();fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',rows,cols,0,0))
 before=termios.tcgetattr(slave)
 env=os.environ.copy();env['TERM']='xterm-256color';env['QUIET_AMBIENT']='off'
 p=subprocess.Popen([binary,'dashboard'],stdin=slave,stdout=slave,stderr=slave,env=env,start_new_session=True)
 return master,slave,before,p

def collect(master,seconds):
 end=time.monotonic()+seconds;out=b''
 while time.monotonic()<end:
  ready,_,_=select.select([master],[],[],min(.1,max(0,end-time.monotonic())))
  if ready:
   try:out+=os.read(master,65536)
   except OSError:break
 return out

def until(master,needle,ceiling):
 # Wait for the expected text rather than a fixed time: a busy machine is slow, not wrong.
 end=time.monotonic()+ceiling;out=b''
 while needle not in out and time.monotonic()<end: out+=collect(master,.2)
 return out

master,slave,before,p=start();out=b''
try:

 for _ in range(20):
  out+=collect(master,1)
  if b'CPU TEMP' in out:break
 assert b'QUIET' in out and b'CPU TEMP' in out,out[-3000:]
 os.write(master,b'\x1b[<0;3;3M');out+=until(master,b'SORT: memory',10)
 assert b'SORT: memory' in out
 os.write(master,b'\x1b[<0;17;3M');out+=collect(master,.3)
 os.write(master,str(p.pid).encode()+b'\r');out+=collect(master,3.8)
 os.write(master,b'\x1b[<0;41;3M');out+=until(master,b'BLOCKED',12)
 assert b'REVIEW GRACEFUL STOP' in out and b'BLOCKED' in out,out[-7000:]
 os.write(master,b'y');out+=collect(master,.6)
 assert p.poll() is None
 os.write(master,b'n');out+=collect(master,.2)
 os.write(master,b'p');out+=until(master,b'PAUSED',10)
 assert b'PAUSED' in out
 fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',18,60,0,0));out+=until(master,b'Resize to at least',10)
 assert b'Resize to at least' in out
 os.write(master,b'q');out+=collect(master,1)
 p.wait(timeout=10);assert p.returncode==0
 assert termios.tcgetattr(slave)==before,'Terminal mode was not restored'
 assert b'\x1b[?1006l' in out and b'\x1b[?1049l' in out
 open(pathlib.Path(tempfile.gettempdir())/'quiet-terminal-transcript.ansi','wb').write(out)
 clean=re.sub(rb'\x1b\[[0-9;?]*[A-Za-z]',b'',out)
 open(pathlib.Path(tempfile.gettempdir())/'quiet-terminal-transcript.txt','wb').write(clean)
 print('PASS: dashboard, mouse sort/filter/review, protected self, pause, resize, clean quit and terminal restoration')
finally:
 if p.poll() is None:p.terminate();p.wait(timeout=15)
 os.close(master);os.close(slave)
master,slave,before,p=start()
try:
 out=collect(master,3);os.kill(p.pid,signal.SIGINT);out+=collect(master,1)
 p.wait(timeout=10);assert p.returncode==0
 assert termios.tcgetattr(slave)==before
 print('PASS: Ctrl-C/SIGINT restores terminal')
finally:
 if p.poll() is None:p.terminate();p.wait(timeout=15)
 os.close(master);os.close(slave)

# End-to-end signal flow only against disposable test processes created by this script.
import tempfile,pathlib
import shutil
bun=shutil.which('bun') or ''
if os.path.exists(bun):
 for mode in ('graceful','ignore'):
  with tempfile.TemporaryDirectory(prefix='quiet-terminal-fixture-') as folder:
   file=pathlib.Path(folder)/'fixture.test.js'
   setup="process.on('SIGTERM',()=>process.exit(0));" if mode=='graceful' else "process.on('SIGTERM',()=>{});"
   file.write_text("import {test} from 'bun:test'; "+setup+" test('owned fixture', async()=>{await new Promise(r=>setTimeout(r,55000));});")
   fixture=subprocess.Popen([bun,'test','--timeout','60000',str(file)],cwd=folder,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
   master,slave,before,p=start();out=b''
   try:
    out+=collect(master,3)
    os.write(master,b'/'+str(fixture.pid).encode()+b'\r');out+=collect(master,3.5)
    os.write(master,b'r');out+=until(master,b'Isolated test: no children/sockets',12)
    assert b'Isolated test: no children/sockets' in out,out[-6000:]
    out+=collect(master,.7)  # a confirmation is ignored for the first half second of a review
    if mode=='graceful':
     # At 110x34 the review actions are on terminal row 32. The gap is not a button.
     os.write(master,b'\x1b[<0;23;32M');out+=collect(master,.3)
     assert fixture.poll() is None,'Whitespace outside Confirm must not stop a process'
     os.write(master,b'\x1b[<0;7;32M')
    else:os.write(master,b'y')
    # A refused SIGTERM is reported after a ten-second watch.
    out+=until(master,b'exited.' if mode=='graceful' else b'still present',12 if mode=='graceful' else 30)
    if mode=='ignore':
     assert b'still present' in out,out[-5000:]
     os.write(master,b'r');out+=until(master,b'REVIEW FORCE-STOP',12)
     assert b'REVIEW FORCE-STOP' in out,out[-5000:]
     out+=collect(master,.7);os.write(master,b'y');out+=until(master,b'exited.',12)
    fixture.wait(timeout=5)
    assert b'exited.' in out,out[-5000:]
    os.write(master,b'q');out+=collect(master,1);p.wait(timeout=10)
    assert termios.tcgetattr(slave)==before
    print('PASS: terminal reviewed '+mode+' stop; only an owned Bun fixture was signaled')
   finally:
    if p.poll() is None:p.terminate();p.wait(timeout=15)
    if fixture.poll() is None:
     fixture.terminate()
     try:fixture.wait(timeout=2)
     except subprocess.TimeoutExpired:fixture.kill();fixture.wait()
    os.close(master);os.close(slave)
else:
 print('SKIP: owned Bun stop fixtures (bun is not installed)')
