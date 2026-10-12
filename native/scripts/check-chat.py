"""Chat panel against a real pseudo-terminal and the real on-device model; requires pyte.

History goes to a temporary directory (QUIET_CHAT_DIR) and session discovery to an empty home
(QUIET_AGENT_HOME), so no real chat history is touched. Answers are checked for presence only.
"""
import os,sys,pty,termios,fcntl,struct,subprocess,time,select,json,shutil,tempfile,glob
import pyte
binary=sys.argv[1]
SECRET='ghp_'+'a1B2'*9
store=tempfile.mkdtemp(prefix='quiet-chat-');home=tempfile.mkdtemp(prefix='quiet-home-')
def records(): return [json.loads(line) for path in sorted(glob.glob(os.path.join(store,'chat-*.jsonl'))) for line in open(path)]
try:
 for run,(cols,rows) in enumerate([(80,26),(160,50)]):
  master,slave=pty.openpty()
  fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',rows,cols,0,0))
  before=termios.tcgetattr(slave)
  env=os.environ.copy();env.update(TERM='xterm-256color',QUIET_AMBIENT='off',QUIET_CHAT_DIR=store,QUIET_AGENT_HOME=home,QUIET_RENDERER='text')
  p=subprocess.Popen([binary,'dashboard'],stdin=slave,stdout=slave,stderr=slave,env=env,start_new_session=True)
  screen=pyte.Screen(cols,rows);stream=pyte.ByteStream(screen);raw=bytearray()
  def collect(seconds):
   end=time.monotonic()+seconds
   while time.monotonic()<end:
    if select.select([master],[],[],.1)[0]:
     data=os.read(master,65536);raw.extend(data);stream.feed(data)
  def key(text,wait=.4): os.write(master,text);collect(wait)
  def text(): return '\n'.join(screen.display)
  def wait_for(predicate,seconds,what):
   end=time.monotonic()+seconds
   while time.monotonic()<end:
    collect(.5)
    if predicate(): return
   raise AssertionError(what+'\n'+text())
  try:
   collect(4.5)
   assert p.poll() is None
   assert any('Chat' in line and '◖c◗' in line for line in screen.display),'chat control missing\n'+text()
   key(b'c',.8)
   assert any('GLYPH CHAT' in line and 'ready' in line for line in screen.display),text()
   assert all(len(line)==cols for line in screen.display) and all(not line[-1].strip() for line in screen.display)
   if run==0: assert 'has no tools' in text()
   else: assert 'What is the CPU doing' in text() and 'YOU' in text() and 'GLYPH' in text(),'history was not restored\n'+text()
   # Keys that are actions elsewhere are only text here.
   key(b'qryig/sx')
   assert p.poll() is None and 'PROCESS REVIEW' not in text() and any('GLYPH CHAT' in line for line in screen.display)
   assert any('> qryig/sx_' in line for line in screen.display),text()
   key(b'\x7f'*8)
   # A paste fills the box but cannot send, even with a newline in it.
   count=len(records())
   key(b'\x1b[200~What is the CPU doing?\r\x1b[201~',.8)
   assert any('> What is the CPU doing? _' in line for line in screen.display),text()
   assert len(records())==count and 'thinking' not in text()
   key(b'\x7f\r',.8)
   wait_for(lambda: len(records())==count+2 and any('GLYPH CHAT' in l and 'ready' in l for l in screen.display),90,'no answer')
   saved=records()
   assert saved[-2]['role']=='owner' and saved[-2]['text']=='What is the CPU doing?'
   assert saved[-1]['role']=='glyph' and len(saved[-1]['text'].strip())>20 and saved[-1].get('model')
   # A long answer pushes its own heading above the panel; scroll back until it shows.
   for _ in range(12):
    if any(line.strip('│ ').startswith('GLYPH') for line in screen.display): break
    key(b'\x1b[5~',.3)
   assert any(line.strip('│ ').startswith('GLYPH') for line in screen.display),text()
   key(b'\x1b[F',.3)
   # A typed credential is masked in the transcript and never written to disk.
   key(b'my token is '+SECRET.encode()+b' is that ok?\r',.8)
   wait_for(lambda: len(records())==count+4 and any('GLYPH CHAT' in l and 'ready' in l for l in screen.display),90,'no second answer')
   assert '[redacted]' in records()[-2]['text'] and all(SECRET not in r['text'] for r in records())
   assert not any(SECRET in open(path).read() for path in glob.glob(os.path.join(store,'*')))
   key(b'\x1b[H',.6)   # scroll to the top of the conversation
   assert 'YOU' in text()
   key(b'\x1b[F',.6)
   mode=oct(os.stat(glob.glob(os.path.join(store,'chat-*.jsonl'))[0]).st_mode&0o777)
   assert mode=='0o600' and oct(os.stat(store).st_mode&0o777)=='0o700',mode
   key(b'\x1b',.8)
   assert not any('GLYPH CHAT' in line for line in screen.display) and any('PROCESSES' in line for line in screen.display),text()
   key(b'q',1.0)
   p.wait(timeout=8)
   assert termios.tcgetattr(slave)==before,'terminal settings not restored'
   print('PASS: chat text entry, paste safety, model answers, saved and masked history, restoration',cols,rows)
  finally:
   if p.poll() is None: p.kill()
   os.close(master);os.close(slave)
finally:
 shutil.rmtree(store,ignore_errors=True);shutil.rmtree(home,ignore_errors=True)
