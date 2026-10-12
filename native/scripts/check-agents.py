"""Agents mode against a real pseudo-terminal, using a disposable fake session; requires pyte.

A compiled sleeper named `claude` stands in for an agent. Its session record and transcript
live in a temporary home passed through QUIET_AGENT_HOME, so no real session is read or opened.
"""
import os,sys,pty,termios,fcntl,struct,subprocess,time,select,json,shutil,tempfile,re
import pyte
binary=sys.argv[1]
SECRET='ghp_'+'a1B2'*9
home=tempfile.mkdtemp(prefix='quiet-agents-')
work=os.path.join(home,'work','demo-project');os.makedirs(work)
# A copied system binary is killed on launch (its signature no longer matches), so build a sleeper.
fake=os.path.join(home,'claude');source=os.path.join(home,'sleeper.c')
open(source,'w').write('#include <unistd.h>\nint main(void){sleep(600);return 0;}\n')
subprocess.run(['cc','-o',fake,source],check=True)
agent=subprocess.Popen([fake],cwd=work)
time.sleep(.3);assert agent.poll() is None,'fixture agent did not start'
def stamp(offset=0): return time.strftime('%Y-%m-%dT%H:%M:%S',time.gmtime(time.time()+offset))+'.000Z'
def entry(kind,content,offset=0,**extra):
 return json.dumps({'type':kind,'timestamp':stamp(offset),'message':dict({'role':kind,'content':content},**extra)})+'\n'
try:
 os.makedirs(os.path.join(home,'.claude','sessions'))
 project=os.path.join(home,'.claude','projects',re.sub(r'[^A-Za-z0-9]','-',work));os.makedirs(project)
 with open(os.path.join(home,'.claude','sessions',f'{agent.pid}.json'),'w') as f:
  json.dump({'pid':agent.pid,'sessionId':'fixture-session','cwd':work,'status':'busy','name':'demo'},f)
 log=os.path.join(project,'fixture-session.jsonl')
 def write_log():
  with open(log,'w') as f:
   f.write(entry('user','Please add the **orbital** widget',-30))
   f.write(entry('assistant',[{'type':'text','text':'Reading the widget module first.'},
    {'type':'tool_use','id':'t1','name':'Bash','input':{'command':'export GH_TOKEN='+SECRET+' && make widget'}}],-20,
    id='m1',usage={'input_tokens':900,'output_tokens':300}))
   f.write(entry('user',[{'type':'tool_result','tool_use_id':'t1','content':'built widget\ntoken '+SECRET+' accepted'}],-10))
   for i in range(40): f.write(entry('assistant',[{'type':'text','text':f'Progress note {i}'}],-9))
 for cols,rows in [(80,26),(110,34),(160,50)]:
  write_log()  # fresh timestamps: token rate only counts the last minute
  master,slave=pty.openpty()
  fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',rows,cols,0,0))
  before=termios.tcgetattr(slave)
  env=os.environ.copy();env.update(TERM='xterm-256color',QUIET_AMBIENT='off',QUIET_AGENT_HOME=home,QUIET_RENDERER='text')
  p=subprocess.Popen([binary,'dashboard'],stdin=slave,stdout=slave,stderr=slave,env=env,start_new_session=True)
  screen=pyte.Screen(cols,rows);stream=pyte.ByteStream(screen);raw=bytearray()
  def collect(seconds):
   end=time.monotonic()+seconds
   while time.monotonic()<end:
    if select.select([master],[],[],.1)[0]:
     data=os.read(master,65536);raw.extend(data);stream.feed(data)
  def key(text,wait=.4): os.write(master,text);collect(wait)
  def text(): return '\n'.join(screen.display)
  def row_of(needle): return next((i for i,line in enumerate(screen.display) if needle in line),None)
  try:
   collect(4.5)
   assert p.poll() is None
   assert 'system observatory' in screen.display[0] and 'Agents' in screen.display[0]
   # Process view: the fake agent is badged, and `t` brings agents to the top.
   key(b't')
   assert 'agents first' in text()
   header=row_of('PID PROGRAM')
   assert re.search(r'│ \*\s+\d+ ',screen.display[header+1]),screen.display[header+1]
   key(b't')
   # Agents mode.
   key(b'\t',1.0)
   assert 'agent observatory' in screen.display[0] and 'System' in screen.display[0],screen.display[0]
   assert 'AGENTS' in screen.display[3] and 'sessions' in screen.display[3]
   assert any('TOKENS/min' in line and 'all agents' in line for line in screen.display)
   assert any('AGENT MEMORY' in line for line in screen.display) and any('AGENT SESSIONS' in line for line in screen.display)
   assert any('not measured' in line for line in screen.display)
   assert all(len(line)==cols for line in screen.display) and all(not line[-1].strip() for line in screen.display)
   # Other agents on this Mac share the list; walk the selection down until the fixture scrolls into view.
   y=row_of(f'{agent.pid} ')
   for _ in range(60):
    if y is not None: break
    key(b'j',.15);y=row_of(f'{agent.pid} ')
   assert y is not None,'fake agent row missing\n'+text()
   # Logs are adopted two per sample, so the fixture's token rate can take a few samples to appear.
   for _ in range(12):
    y=row_of(f'{agent.pid} ');line=screen.display[y]
    if cols<140 or '1.2k' in line: break
    collect(2)
   assert 'claude' in line and 'demo-project' in line and 'working' in line,line
   assert '1.2k' in line or cols<140,line  # 900+300 tokens within the last minute (wide rows only)
   # First click selects, second click opens the stream.
   x=line.index(str(agent.pid))+1
   click=f'\x1b[<0;{x};{y+1}M\x1b[<0;{x};{y+1}m'.encode()
   key(click)
   y=row_of(f'{agent.pid} ');click=f'\x1b[<0;{x};{y+1}M\x1b[<0;{x};{y+1}m'.encode()   # the list may have re-sorted
   key(click,1.2)
   if not any('STREAM' in line for line in screen.display): key(b'o',1.2)   # a re-sort between clicks only selected it
   assert any('STREAM' in line and str(agent.pid) in line and 'following' in line for line in screen.display),text()
   body=text()
   assert 'Progress note 39' in body and 'AGENT' in body
   assert SECRET not in body and SECRET.encode() not in raw,'secret reached the terminal'
   # Follow: a new entry appears without input.
   with open(log,'a') as f: f.write(entry('user','Now ship **it**'))
   collect(3.5)
   assert 'Now ship it' in text() and 'YOU' in text()
   # Scroll back to the start: prompt, tool call and masked secret.
   key(b'\x1b[H',.8)
   body=text()
   assert 'scrolled back' in body and 'Please add the orbital widget' in body,body
   assert 'TOOL' in body and 'Bash' in body and 'make widget' in body and '[redacted]' in body,body
   assert 'RESULT' in body and 'built widget' in body
   assert SECRET.encode() not in raw
   with open(log,'a') as f: f.write(entry('assistant',[{'type':'text','text':'Shipped.'}]))
   collect(3.5)
   assert 'Please add the orbital widget' in text(),'scrolled view moved when the tail grew'
   key(b'f',.8)
   assert 'Shipped.' in text() and 'following' in text()
   # Review and other process actions do nothing here; the stream closes with o, Esc or the button.
   key(b'r');assert 'PROCESS REVIEW' not in text()
   key(b'o',.8)
   assert not any('STREAM' in line for line in screen.display) and any('AGENT SESSIONS' in line for line in screen.display)
   # From the process view, `o` on the agent's own process opens the same stream.
   key(b'g',.8)
   assert 'system observatory' in screen.display[0]
   key(b'/');key(str(agent.pid).encode());key(b'\r');key(b'o',1.2)
   assert 'agent observatory' in screen.display[0]
   assert any('STREAM' in line and str(agent.pid) in line for line in screen.display),text()
   key(b'\x1b',.8)
   assert not any('STREAM' in line for line in screen.display)
   key(b'q',1.0)
   p.wait(timeout=5)
   assert termios.tcgetattr(slave)==before,'terminal settings not restored'
   print('PASS: agents mode, badges, stream follow/scroll/redaction, process-view open, restoration',cols,rows)
  finally:
   if p.poll() is None: p.kill()
   os.close(master);os.close(slave)
finally:
 agent.kill();shutil.rmtree(home,ignore_errors=True)
