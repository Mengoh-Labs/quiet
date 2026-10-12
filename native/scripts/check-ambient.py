"""Opt-in live on-device ambient smoke check; consumes one local model request."""
import os, sys, pty, termios, fcntl, struct, subprocess, select, time
import pyte
master, slave = pty.openpty()
before = termios.tcgetattr(slave)
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 50, 160, 0, 0))
env = os.environ.copy()
env.update(TERM='xterm-256color', QUIET_RENDERER='text')
env.pop('QUIET_AMBIENT', None)
process = subprocess.Popen([sys.argv[1], 'dashboard'], stdin=slave, stdout=slave, stderr=slave, env=env, start_new_session=True)
screen = pyte.Screen(160, 50); stream = pyte.ByteStream(screen)
def read(seconds):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if select.select([master], [], [], .1)[0]:
            try: stream.feed(os.read(master, 65536))
            except OSError: break
try:
    deadline = time.monotonic() + 55
    while time.monotonic() < deadline:
        read(.25)
        if any('INTELLIGENCE / local AI / as of' in row for row in screen.display): break
    else: raise AssertionError('\n'.join(screen.display[-9:]))
    row = next(i for i, line in enumerate(screen.display) if 'INTELLIGENCE' in line)
    observation = '\n'.join(screen.display[row + 1:row + 4])
    assert 'Watching the next' not in observation and observation.strip()
    print(observation)
    os.write(master, b'p'); read(.5)
    assert any('INTELLIGENCE / paused' in line for line in screen.display)
    os.write(master, b'q'); read(2); process.wait(timeout=15)
    assert process.returncode == 0 and termios.tcgetattr(slave) == before
    print('PASS: automatic local interpretation, timestamp, pause, and clean exit')
finally:
    if process.poll() is None: process.terminate(); read(2); process.wait(timeout=15)
    os.close(master); os.close(slave)
