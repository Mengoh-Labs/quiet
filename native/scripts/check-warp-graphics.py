"""Exercise the Kitty protocol through a PTY; this does not replace live Warp QA.
Requires pyte and Pillow. Optionally saves a protocol-composited preview PNG.
"""
import base64, io, os, pty, select, signal, struct, subprocess, sys, tempfile, termios, time, fcntl
import pyte
from PIL import Image, ImageDraw, ImageFont

class Session:
    def __init__(self, binary, accept=True, terminal=None, renderer=None, animation=None, sync=2, sync_override=None):
        self.master, self.slave = pty.openpty()
        self.before = termios.tcgetattr(self.slave)
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack('HHHH', 50, 160, 1600, 1000))
        env = os.environ.copy(); env['TERM']='xterm-256color';env['QUIET_AMBIENT']='off'; env.pop('TERM_PROGRAM',None)
        if terminal is not None:env['TERM_PROGRAM']=terminal
        env.pop('QUIET_RENDERER',None); env.pop('TMUX',None); env.pop('STY',None)
        # Rendered labels are pixels, not screen text: Quiet reports what each control says here.
        self.map=tempfile.mktemp(prefix='quiet-controls-');env['QUIET_CONTROL_MAP']=self.map
        env.pop('QUIET_ANIMATION',None)
        env.pop('QUIET_SYNC',None)
        if renderer is not None:env['QUIET_RENDERER']=renderer
        if animation is not None:env['QUIET_ANIMATION']=animation
        if sync_override is not None:env['QUIET_SYNC']=sync_override
        self.process = subprocess.Popen([binary, 'dashboard'], stdin=self.slave, stdout=self.slave,
                                        stderr=self.slave, env=env, start_new_session=True)
        self.screen=pyte.Screen(160,50); self.stream=pyte.ByteStream(self.screen)
        self.buffer=b''; self.chunk=None; self.images={}; self.places={}; self.crops={}
        self.accept=accept; self.probes=0; self.transmissions=0; self.deleted=0
        self.sync=sync; self.sync_queries=0; self.in_frame=False; self.frames=0; self.clears=0
    def text(self, data):
        if data==b'\x1b[16t': os.write(self.master,b'\x1b[6;20;10t')
        if data==b'\x1b[?2026$p':
            self.sync_queries+=1
            if self.sync is not None:
                reply=f'\x1b[?2026;{self.sync}$y'.encode()
                os.write(self.master,reply[:5]);os.write(self.master,reply[5:])
        if data==b'\x1b[?2026h':
            assert not self.in_frame, 'Synchronized frames must not nest'
            self.in_frame=True
        if data==b'\x1b[?2026l':
            if self.in_frame:self.frames+=1
            self.in_frame=False
        if data==b'\x1b[2J':self.clears+=1
        self.stream.feed(data)
    def read(self, seconds):
        end=time.monotonic()+seconds
        while time.monotonic()<end:
            if not select.select([self.master],[],[],.05)[0]:continue
            try: data=os.read(self.master,65536)
            except OSError:break
            self.buffer+=data
            while self.buffer:
                start=self.buffer.find(b'\x1b')
                if start<0:
                    self.text(self.buffer);self.buffer=b''
                    break
                if start:self.text(self.buffer[:start]);self.buffer=self.buffer[start:]
                if len(self.buffer)<3:break
                if self.buffer.startswith(b'\x1b_G'):
                    stop=self.buffer.find(b'\x1b\\',3)
                    if stop<0:break
                    body=self.buffer[3:stop];self.buffer=self.buffer[stop+2:]
                    self.graphics(body)
                elif self.buffer.startswith(b'\x1b['):
                    stop=next((i for i in range(2,len(self.buffer)) if 64<=self.buffer[i]<=126),None)
                    if stop is None:break
                    self.text(self.buffer[:stop+1]);self.buffer=self.buffer[stop+1:]
                else:
                    self.text(self.buffer[:2]);self.buffer=self.buffer[2:]
    def graphics(self, body):
        control,_,payload=body.partition(b';')
        args=dict(item.decode().split('=',1) for item in control.split(b',') if b'=' in item)
        action=args.get('a')
        if action in ('T','p') and self.sync_queries and self.sync in (1,2):
            assert self.in_frame, 'Every pixel update must be inside its synchronized frame'
        if action=='q':
            self.probes+=1
            if self.accept is None:return
            reply=('\x1b_Gp=0,i='+args['i']+';'+('OK' if self.accept else 'ENOTSUP')+'\x1b\\').encode()
            # Deliberate fragmentation exercises the input decoder.
            os.write(self.master,reply[:7]);os.write(self.master,reply[7:])
        elif action=='d':
            assert args['d'] in ('i','I'), 'Must delete only owned IDs'
            identifier=int(args['i'])
            if args['d']=='I':self.images.pop(identifier,None)
            self.places.pop(identifier,None);self.deleted+=1
            self.crops.pop(identifier,None)
        elif action=='p':
            identifier=int(args['i']);assert identifier in self.images
            assert identifier not in self.places, 'Do not depend on Warp replacing placement IDs'
            assert args['p']=='1' and args['C']=='1' and args['z']=='-1'
            self.places[identifier]=(self.screen.cursor.x,self.screen.cursor.y,int(args['c']),int(args['r']))
            self.crop(identifier,args)
        else:
            if action=='T':
                assert int(args['i']) not in self.places, 'Replace owned images explicitly before retransmission'
                assert self.chunk is None
                assert args['q']=='2' and args['C']=='1' and args['z']=='-1'
                self.chunk=[args,b'',(self.screen.cursor.x,self.screen.cursor.y)]
            assert self.chunk is not None and len(payload)<=4096
            self.chunk[1]+=payload
            if args['m']=='0':
                metadata,encoded,point=self.chunk;self.chunk=None
                image=Image.open(io.BytesIO(base64.b64decode(encoded))).convert('RGBA')
                identifier=int(metadata['i']);self.images[identifier]=image
                self.places[identifier]=(*point,int(metadata['c']),int(metadata['r']))
                self.crop(identifier,metadata)
                self.transmissions+=1
                assert len(self.images)<=128
    def crop(self, identifier, args):
        image=self.images[identifier]
        x=int(args.get('x',0));y=int(args.get('y',0))
        w=int(args.get('w',image.width));h=int(args.get('h',image.height))
        assert x>=0 and y>=0 and x+w<=image.width and y+h<=image.height, 'Crop must stay inside cached image'
        self.crops[identifier]=(x,y,x+w,y+h)
    def key(self, key):os.write(self.master,key);self.read(.5)
    def controls(self):
        try: rows=open(self.map).read().splitlines()
        except OSError: return []
        return [(int(x),int(y),int(w),k,l) for x,y,w,k,l in (row.split(',',4) for row in rows if row)]
    def control(self, key, label, click=True):
        found=[c for c in self.controls() if c[3]==key and c[4]==label]
        assert found, f'No control {key!r} {label!r} in {self.controls()}'
        x,y,w=found[0][:3]
        assert (x,y,w,1) in self.places.values(), 'Control must be one rendered button covering exactly its clickable cells'
        assert not self.screen.display[y][x:x+w].strip(), 'A rendered button carries its own label; no text may sit on it'
        if click:self.key(f'\x1b[<0;{x+2};{y+1}M'.encode())
        return x,y
    def preview(self, destination):
        cw,ch,pad=10,20,20
        canvas=Image.new('RGBA',(self.screen.columns*cw+pad*2,self.screen.lines*ch+pad*2),'#101418')
        draw=ImageDraw.Draw(canvas)
        def color(value,default):return '#'+value if len(value)==6 else default
        for y in range(self.screen.lines):
            for x in range(self.screen.columns):
                cell=self.screen.buffer[y][x]
                if cell.bg!='default':draw.rectangle((pad+x*cw,pad+y*ch,pad+(x+1)*cw,pad+(y+1)*ch),fill=color(cell.bg,'#101418'))
        for identifier,(x,y,w,h) in self.places.items():
            picture=self.images[identifier].crop(self.crops[identifier]).resize((w*cw,h*ch),Image.Resampling.LANCZOS)
            canvas.alpha_composite(picture,(pad+x*cw,pad+y*ch))
        draw=ImageDraw.Draw(canvas);font=ImageFont.truetype('/System/Library/Fonts/Menlo.ttc',16)
        for y in range(self.screen.lines):
            for x in range(self.screen.columns):
                cell=self.screen.buffer[y][x];char=cell.data;px,py=pad+x*cw,pad+y*ch;fg=color(cell.fg,'#dadce0')
                if len(char)==1 and 0x2800<=ord(char)<=0x28ff:
                    mask=ord(char)-0x2800
                    for side,bits in enumerate(((0,1,2,6),(3,4,5,7))):
                        for row,bit in enumerate(bits):
                            if mask&(1<<bit):draw.ellipse((px+side*5+1,py+row*4+3,px+side*5+3,py+row*4+5),fill=fg)
                else:draw.text((px,py),char,fill=fg,font=font)
        canvas.convert('RGB').save(destination)
    def close(self):
        if self.process.poll() is None:
            self.key(b'q');self.read(1)
        try:self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:self.process.kill();self.process.wait();raise
        assert self.process.returncode==0
        assert termios.tcgetattr(self.slave)==self.before
        assert not self.in_frame, 'Exit must always release synchronized output'
        os.close(self.master);os.close(self.slave)

session=Session(sys.argv[1])
try:
    session.read(7)
    assert session.probes==1 and len(session.images)>=12
    # With graphics the masthead is one rendered card; renderer state moves to the footer line.
    assert (0,0,159,3) in session.places.values(), 'Rendered header card must span the top three rows'
    assert not session.screen.display[0].strip() and not session.screen.display[1].strip(), 'No text may sit on the header card rows'
    assert "graphics" in session.screen.display[-1], 'Graphics must negotiate without TERM_PROGRAM or a renderer override'
    assert 'sync' in session.screen.display[-1] and session.frames>1
    session.control('s','Sort',click=False);session.control('g','Agents',click=False)
    assert all(x>=0 and y>=0 and x+w<160 and y+h<=50 for x,y,w,h in session.places.values())
    session.key(b'p')
    intelligence_row=next(i for i,row in enumerate(session.screen.display) if 'INTELLIGENCE' in row)
    assert (2,intelligence_row+1,30,3) in session.places.values(), 'Glyph identity card must sit beside ambient commentary'
    assert session.screen.display[intelligence_row+1].index('Ambient')==34, 'Commentary must clear the identity card'
    toolbar=[(x,w) for x,y,w,h in session.places.values() if y==3 and h==1]
    assert len(toolbar)>=8 and all(w>=7 for x,w in toolbar), 'Toolbar must be a row of rendered buttons'
    assert all(a[0]+a[1]<=b[0] for a,b in zip(sorted(toolbar),sorted(toolbar)[1:])), 'Rendered buttons must not overlap'
    stable=(session.transmissions,session.deleted,session.clears)
    session.key(b'\x1b[6;20;10t')
    assert stable==(session.transmissions,session.deleted,session.clears), 'Unchanged cell size must not repaint images or clear the screen'
    # Memory and disks must contain both rounded bars and pixel history plots.
    panel_row=next(i for i,row in enumerate(session.screen.display) if 'MEMORY' in row and 'DISKS' in row)
    disk_x=session.screen.display[panel_row].index('DISKS')-2
    process_x=session.screen.display[panel_row].index('PROCESSES')-2
    for left,right in ((0,disk_x),(disk_x,process_x)):
        panels=[(x,y,w,h) for x,y,w,h in session.places.values() if left<=x<right and y>panel_row]
        assert any(h==1 for x,y,w,h in panels), 'Storage panel needs pixel bars'
        assert any(h>1 for x,y,w,h in panels), 'Storage panel needs pixel history'
    old_places=dict(session.places);session.key(b's')
    assert session.places==old_places, 'Sorting must retain panel geometry without orphan placements'
    assert any('SORT: memory' in row for row in session.screen.display)
    session.key(b'\x1b[<0;3;4M')
    assert any('SORT: CPU/core' in row for row in session.screen.display), 'Image-backed keycap must preserve hit target'
    session.control('d','Next',click=False)
    session.control('n','Next',click=False)
    session.control('a','Independent')
    session.control('a','Shared')
    session.control('i','Explain locally',click=False)
    session.control('r','Review process',click=False)
    if len(sys.argv)>2:session.preview(sys.argv[2])
    os.kill(session.process.pid,signal.SIGTSTP)
    stopped=False
    for _ in range(50):
        session.read(.1)
        child,status=os.waitpid(session.process.pid,os.WNOHANG|os.WUNTRACED)
        if child and os.WIFSTOPPED(status):stopped=True;break
    assert stopped and not session.images and termios.tcgetattr(session.slave)==session.before
    os.kill(session.process.pid,signal.SIGCONT);session.read(2)
    assert session.probes==2 and session.images and termios.tcgetattr(session.slave)!=session.before
    session.control('h','Saved observations');session.read(1)
    assert any('APP HISTORY' in row for row in session.screen.display)
    session.key(b'\x1b');session.read(.3)
    session.key(b'/'+str(session.process.pid).encode()+b'\r')
    session.key(b'\x1b[H') # Filtering clears selection; choose the first match while paused.
    session.key(b'r');session.read(1)
    assert any('BLOCKED:' in row for row in session.screen.display), session.screen.display
    review_row=next(i for i,row in enumerate(session.screen.display) if 'PROCESS REVIEW' in row)
    assert not any(x==2 and y==review_row+1 and h==3 for x,y,w,h in session.places.values()), 'Process review must retire the identity card'
    if len(sys.argv)>2:session.preview(sys.argv[2].replace('.png','-review.png'))
    session.control('y','Blocked')
    assert any('PROCESS REVIEW' in row for row in session.screen.display), 'Disabled action must not confirm'
    session.control('n','Cancel')
    assert not any('PROCESS REVIEW' in row for row in session.screen.display)
    session.screen.resize(26,80)
    fcntl.ioctl(session.slave,termios.TIOCSWINSZ,struct.pack('HHHH',26,80,800,520));session.read(1)
    assert session.deleted>0
    assert all(x+w<80 and y+h<=26 for x,y,w,h in session.places.values())
    intelligence_row=next(i for i,row in enumerate(session.screen.display) if 'INTELLIGENCE' in row)
    assert not any(x==2 and y==intelligence_row+1 and h==3 for x,y,w,h in session.places.values()), 'Compact mode must retain full text width'
    if len(sys.argv)>2:session.preview(sys.argv[2].replace('.png','-compact.png'))
    session.screen.resize(18,60)
    fcntl.ioctl(session.slave,termios.TIOCSWINSZ,struct.pack('HHHH',18,60,600,360));session.read(1)
    assert not session.images and any('Resize to at least' in row for row in session.screen.display)
    session.key(b'q');session.read(.5)
    assert not session.images
finally:session.close()
print('PASS: Warp negotiation, chunked PNGs, cache reuse, mouse/keys, history, resize/suspend cleanup, resume renegotiation, exit restoration')
for accept in (False,None):
    session=Session(sys.argv[1],accept=accept)
    try:
        session.read(5)
        assert session.probes==1 and not session.images
        assert '◖s◗ Sort' in session.screen.display[2]
        assert ('rejected' if accept is False else 'no reply') in session.screen.display[0]
        session.key(b'q')
    finally:session.close()
print('PASS: unsupported graphics falls back to text without interpreting replies as actions')
for renderer,animation in (('text',None),(None,'off')):
    session=Session(sys.argv[1],terminal='WarpTerminal',renderer=renderer,animation=animation)
    try:
        session.read(4)
        if renderer=='text':
            assert session.probes==0 and not session.images
            assert 'text' in session.screen.display[0]
        else:
            assert session.probes==1 and session.images and 'Warp' in session.screen.display[-1]
        session.key(b'q')
    finally:session.close()
print('PASS: explicit text override and Warp graphics with animation disabled')
for sync,override in ((0,None),(None,None),(2,'off')):
    session=Session(sys.argv[1],sync=sync,sync_override=override)
    try:
        session.read(4)
        assert session.images and session.frames==0 and not session.in_frame
        assert 'sync' not in session.screen.display[0] and 'sync' not in session.screen.display[-1]
        if override:assert session.sync_queries==0
        session.key(b'q')
    finally:session.close()
print('PASS: unsupported, absent, and disabled synchronized-output fallbacks')
session=Session(sys.argv[1])
try:
    session.read(7)
    assert session.images
    session.key(b'\t');session.read(2.5)
    assert any('AGENT SESSIONS' in row for row in session.screen.display)
    session.control('g','System',click=False)
    assert session.places and all(x>=0 and y>=0 and x+w<=160 and y+h<=50 for x,y,w,h in session.places.values())
    assert [place for place in session.places.values() if place[1]<3]==[(0,0,159,3)], 'Only the header card may occupy the masthead rows'
    session.key(b'p')
    stable=(session.transmissions,session.deleted,session.clears)
    session.read(2.5)
    assert stable==(session.transmissions,session.deleted,session.clears), 'A paused agent view must not resend images when only the clock changes'
    session.key(b'p')
    session.key(b'c');session.read(1)
    chat_row=next(i for i,row in enumerate(session.screen.display) if 'GLYPH CHAT' in row)
    assert all(y+h<=chat_row for x,y,w,h in session.places.values()), 'No image may sit inside the chat transcript'
    assert all(x>=0 and x+w<=160 for x,y,w,h in session.places.values())
    session.key(b'p');session.read(.3)   # typed into chat, not a pause
    session.key(b'ing')
    assert any('> ping_' in row for row in session.screen.display)
    session.key(b'\x1b');session.key(b'g');session.read(1)
    assert any('PROCESSES' in row for row in session.screen.display)
    session.control('g','Agents',click=False)
    assert all(x>=0 and y>=0 and x+w<=160 and y+h<=50 for x,y,w,h in session.places.values())
    session.key(b'q');session.read(.5)
    assert not session.images
finally:session.close()
print('PASS: agent view and chat in pixel mode keep images in bounds and off repainting rows')
