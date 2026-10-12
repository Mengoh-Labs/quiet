"""Measure the actual dashboard process, including its collector and renderer, in a drained PTY."""
import os,sys,pty,termios,fcntl,struct,subprocess,time,select,json
binary=sys.argv[1];duration=float(sys.argv[2]) if len(sys.argv)>2 else 30
master,slave=pty.openpty();fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',50,160,0,0))
before=termios.tcgetattr(slave);env=os.environ.copy();env['TERM']='xterm-256color'
arguments=sys.argv[3:] or ['dashboard']
p=subprocess.Popen([binary]+arguments,stdin=slave,stdout=slave,stderr=slave,env=env,start_new_session=True)
def drain(seconds):
 end=time.monotonic()+seconds;size=0
 while time.monotonic()<end:
  if select.select([master],[],[],.1)[0]:size+=len(os.read(master,65536))
 return size
def stats():
 value=subprocess.check_output(['/bin/ps','-p',str(p.pid),'-o','time=,rss='],text=True).split()
 parts=value[0].split(':');cpu=0
 for part in parts:cpu=cpu*60+float(part)
 return cpu,int(value[1])*1024
try:
 drain(4);old=stats();start=time.monotonic();output=drain(duration);elapsed=time.monotonic()-start;new=stats()
 print(json.dumps({'duration_s':round(elapsed,2),'cpu_percent_one_core':round((new[0]-old[0])/elapsed*100,2),'rss_mib':round(new[1]/1048576,2),'terminal_kib_s':round(output/1024/elapsed,2),'columns':160,'rows':50,'interval_s':2,'inference_requested':False},indent=2))
 os.write(master,b'q');drain(.5);p.wait(timeout=5)
 assert termios.tcgetattr(slave)==before
finally:
 if p.poll() is None:
  p.terminate();drain(2)
  try:p.wait(timeout=5)
  except subprocess.TimeoutExpired:p.kill();p.wait()
 os.close(master);os.close(slave)
