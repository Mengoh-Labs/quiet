"""Regression: restore raw/nonblocking input synchronously after SIGSTOP returns."""
import os,pty,termios,fcntl,struct,subprocess,time,select,signal,sys
master,slave=pty.openpty();fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',34,110,0,0))
before=termios.tcgetattr(slave);env=os.environ.copy();env['TERM']='xterm-256color';env['QUIET_AMBIENT']='off'
p=subprocess.Popen([sys.argv[1],'dashboard'],stdin=slave,stdout=slave,stderr=slave,env=env,start_new_session=True)
out=bytearray()
def drain(seconds):
 end=time.monotonic()+seconds
 while time.monotonic()<end:
  if select.select([master],[],[],.1)[0]:out.extend(os.read(master,65536))
try:
 for _ in range(20):
  drain(.5)
  if b'CPU TEMP' in out:break
 assert b'CPU TEMP' in out
 for cycle in range(3):
  os.kill(p.pid,signal.SIGTSTP)
  stopped=False
  for _ in range(50):
   child,status=os.waitpid(p.pid,os.WUNTRACED|os.WNOHANG)
   if child and os.WIFSTOPPED(status):stopped=True;break
   drain(.1)
  assert stopped and termios.tcgetattr(slave)==before,'suspend must restore terminal'
  os.kill(p.pid,signal.SIGCONT)
  for _ in range(50):
   drain(.1)
   if termios.tcgetattr(slave)!=before:break
  assert termios.tcgetattr(slave)!=before,'resume must restore raw input before any read'
  count=out.count(b'\x1b[?1049h')
  os.kill(p.pid,signal.SIGCONT);drain(.4)
  assert p.poll() is None and out.count(b'\x1b[?1049h')==count,'extra SIGCONT should not enter twice'
 os.write(master,b'h')
 for _ in range(20):
  drain(.5)
  if b'APP HISTORY' in out:break
 assert b'APP HISTORY' in out,'history input lost after resume'
 os.write(master,b'q');drain(1);p.wait(timeout=5)
 assert p.returncode==0 and termios.tcgetattr(slave)==before
 print('PASS: three suspend/resume cycles, restored raw input, extra SIGCONT, saved history, clean quit')
finally:
 if p.poll() is None:
  os.kill(p.pid,signal.SIGCONT);p.terminate()
  for _ in range(20):
   drain(.2)
   if p.poll() is not None:break
  if p.poll() is None:p.kill()
  p.wait(timeout=5)
 os.close(master);os.close(slave)
