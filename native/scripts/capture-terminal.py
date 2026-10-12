"""Capture actual PTY output with pyte, then render its terminal cells for visual QA.
Dependencies: pyte, Pillow. No generated or fabricated dashboard measurements.
"""
import os, sys, pty, termios, fcntl, struct, subprocess, time, select, pathlib
import pyte
from PIL import Image, ImageDraw, ImageFont
binary, destination = sys.argv[1:3]
cols = int(sys.argv[3]) if len(sys.argv) > 3 else 160
rows = int(sys.argv[4]) if len(sys.argv) > 4 else 50
seconds = float(sys.argv[5]) if len(sys.argv) > 5 else 10
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
before = termios.tcgetattr(slave)
env = os.environ.copy(); env['TERM'] = 'xterm-256color'
p = subprocess.Popen([binary, 'dashboard'], stdin=slave, stdout=slave, stderr=slave, env=env, start_new_session=True)
screen = pyte.Screen(cols, rows); stream = pyte.ByteStream(screen)
raw = bytearray()
try:
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if select.select([master], [], [], .1)[0]:
            data = os.read(master, 65536); raw.extend(data); stream.feed(data)
        if p.poll() is not None: raise RuntimeError('Dashboard exited before capture: ' + str(p.returncode))
    pathlib.Path(destination).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(destination + '.txt').write_text('\n'.join(screen.display))
    pathlib.Path(destination + '.ansi').write_bytes(raw)
    font = ImageFont.truetype('/System/Library/Fonts/Menlo.ttc', 15)
    cell_w, cell_h, padding = 9, 21, 14
    image = Image.new('RGB', (cols*cell_w+padding*2, rows*cell_h+padding*2), '#10151b')
    draw = ImageDraw.Draw(image)
    colors = {'default':'d7dce2','black':'10151b','white':'d7dce2','red':'e78284','green':'a6d189','brown':'e5c890','blue':'8caaee','magenta':'ca9ee6','cyan':'81c8be','brightblack':'626880','brightwhite':'ffffff'}
    def color(value, background=False):
        if value == 'default' and background: return '#10151b'
        return '#' + colors.get(value, value if len(value)==6 else 'd7dce2')
    for y in range(rows):
        for x in range(cols):
            char = screen.buffer[y][x]
            fg, bg = color(char.fg), color(char.bg, True)
            if char.reverse: fg,bg=bg,fg
            left, top = padding+x*cell_w, padding+y*cell_h
            draw.rectangle((left,top,left+cell_w,top+cell_h),fill=bg)
            code = ord(char.data) if len(char.data) == 1 else 0
            if 0x2800 <= code <= 0x28ff:
                mask = code - 0x2800
                for side, bits in enumerate(((0,1,2,6),(3,4,5,7))):
                    for row, bit in enumerate(bits):
                        if mask & (1 << bit):
                            dx,dy=left+1+side*4,top+3+row*4
                            draw.ellipse((dx,dy,dx+1,dy+1),fill=fg)
            else:
                draw.text((left,top),char.data,font=font,fill=fg)
    image.save(destination + '.png')
    os.write(master,b'q')
    until = time.monotonic()+10
    while p.poll() is None and time.monotonic()<until:
        if select.select([master],[],[],.1)[0]: os.read(master,65536)
    p.wait(timeout=2)
    assert p.returncode == 0 and termios.tcgetattr(slave)==before
    print('PASS: live terminal capture',cols,rows,destination+'.png')
finally:
    if p.poll() is None:
        p.terminate()
        try: p.wait(timeout=10)
        except subprocess.TimeoutExpired: p.kill();p.wait()
    os.close(master);os.close(slave)
