"""Geometry/interaction checks against real terminal frames; requires pyte."""
import os,sys,pty,termios,fcntl,struct,subprocess,time,select,re,socket
import pyte
binary=sys.argv[1]
# This reads capability metadata only; it never requests model inference.
hardware_output=subprocess.check_output([binary,'hardware'],text=True,timeout=20)
metal=re.search(r'^Metal: (.*); unified memory .*; Neural Engine cores: ([0-9]+)$',hardware_output,re.M)
ai=re.search(r'^Apple Intelligence: (.+)$',hardware_output,re.M)
assert metal and ai,hardware_output
hardware=f'{metal[1]} / {metal[2]}-core Neural Engine'
ai_text='AI: '+ai[1]
# MachineMetrics excludes loopback interfaces. A single-interface VM has no
# different interface to cycle to, unlike a developer's physical Mac.
interface_names={name for _,name in socket.if_nameindex() if not name.startswith('lo')}
for cols,rows in [(80,26),(110,34),(160,50),(240,80)]:
 master,slave=pty.openpty()
 fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',rows,cols,0,0))
 before=termios.tcgetattr(slave)
 env=os.environ.copy();env['TERM']='xterm-256color';env['QUIET_AMBIENT']='off'
 p=subprocess.Popen([binary,'dashboard'],stdin=slave,stdout=slave,stderr=slave,env=env,start_new_session=True)
 screen=pyte.Screen(cols,rows);stream=pyte.ByteStream(screen)
 def collect(seconds):
  end=time.monotonic()+seconds
  while time.monotonic()<end:
   if select.select([master],[],[],.1)[0]: stream.feed(os.read(master,65536))
 def key(text): os.write(master,text);collect(.3)
 try:
  collect(4.5)
  assert p.poll() is None
  assert 'QUIET' in screen.display[0] and 'system observatory' in screen.display[0]
  header_row=screen.display[1]
  print(f'HEADER {cols}x{rows}: {header_row!r}',flush=True)
  # The renderer gives the full availability status priority and clips hardware
  # into the space on its left. Long unavailable-model states are valid.
  canvas_width=cols-1  # final terminal column is reserved against wrapping
  ai_column=max(2,canvas_width-len(ai_text)-2)
  visible_hardware=hardware[:max(0,ai_column-5)]
  assert header_row[2:2+len(visible_hardware)]==visible_hardware,(header_row,hardware)
  assert header_row[ai_column:canvas_width-2]==ai_text[:canvas_width-ai_column-2],(header_row,ai_text)
  assert not header_row[:2].strip() and not header_row[-2:].strip(),header_row
  assert '◖s◗ Sort' in screen.display[2] and '◖q◗ Quit' in screen.display[2]
  # Markdown delimiters must disappear without shifting hit targets or borders.
  sort_column=screen.display[2].index('Sort')
  assert all(screen.buffer[2][x].bold for x in range(sort_column,sort_column+4))
  assert screen.buffer[2][sort_column-3].bg != 'default'
  assert any(0x2800 < ord(char) <= 0x28ff for row in screen.display[4:10] for char in row)
  cpu_column=screen.display[3].index('CPU')
  assert all(screen.buffer[3][x].bold for x in range(cpu_column,cpu_column+3))
  assert not screen.buffer[3][cpu_column+4].bold
  assert not any('**' in line for line in screen.display[:4])
  assert any('GPU ' in row and 'driver' in row for row in screen.display)
  assert 'Recording:' in screen.display[-1]
  assert all(not line[-1].strip() for line in screen.display),'last column overwritten'
  assert all(len(line)==cols for line in screen.display)
  header=next(i for i,line in enumerate(screen.display) if 'PID PROGRAM' in line)
  first=screen.display[header+1]
  assert re.search(r'\d+\.\d',first),first # CPU decimal value must survive wide history rendering.
  if rows>=34: assert any('NET ' in row for row in screen.display)
  # Storage and network controls use their rendered coordinates, including narrow tabs.
  assert any('MEMORY' in row for row in screen.display)
  if cols>=160:
   assert any('DISKS' in row for row in screen.display)
   for label in ['Occupied', 'Active', 'Wired', 'Compressed', 'Inactive', 'Other', 'Free pool', 'Swap']:
    assert any(label in row for row in screen.display),label
   assert any(' free / ' in row or 'No local volume data' in row for row in screen.display)
   def gib(value):
    amount, unit = float(value[:-1]), value[-1]
    return amount * {'G': 1, 'M': 1/1024, 'K': 1/1048576}[unit]
   occupied_row=next(row for row in screen.display if re.search(r'Occupied [0-9]',row))
   match=re.search(r'Occupied ([0-9.]+[GMK]) / ([0-9.]+[GMK])\s+([0-9]+)%',occupied_row)
   assert match,occupied_row
   occupied,total=gib(match[1]),gib(match[2])
   free_row=next(row for row in screen.display if 'Free pool' in row)
   free=gib(re.search(r'Free pool\s+([0-9.]+[GMK])',free_row)[1])
   assert abs(occupied+free-total)<=.11, (occupied,free,total)
   assert abs(int(match[3])-100*occupied/total)<=1

  else:
   memory_row=next(i for i,line in enumerate(screen.display) if 'MEMORY' in line)
   memory_control=screen.display[memory_row].index('◖m◗')
   key(f'\x1b[<0;{memory_control+2};{memory_row+1}M'.encode())
   assert any('DISKS' in row for row in screen.display)
   assert any(' free / ' in row or 'No local volume data' in row for row in screen.display)
   key(b'm');assert any('MEMORY' in row for row in screen.display)
  if rows>=34 and not any('No interface data' in row for row in screen.display):
   assert any('DOWN ' in row for row in screen.display)
   assert any('UP ' in row for row in screen.display)
   scale_row=next(i for i,line in enumerate(screen.display) if '◖a◗ Independent' in line)
   scale_control=screen.display[scale_row].index('◖a◗')
   key(f'\x1b[<0;{scale_control+2};{scale_row+1}M'.encode())
   assert any('◖a◗ Shared' in row for row in screen.display)
   key(b'a');assert any('◖a◗ Independent' in row for row in screen.display)
   net_row=next(i for i,line in enumerate(screen.display) if 'NET ' in line)
   previous=screen.display[net_row]
   net_control=screen.display[net_row].index('◖n◗')
   key(f'\x1b[<0;{net_control+2};{net_row+1}M'.encode())
   if len(interface_names)>1:
    assert screen.display[net_row]!=previous,('interface did not cycle',interface_names,previous,screen.display[net_row])
   else:
    assert screen.display[net_row]==previous,('single interface should stay selected',previous,screen.display[net_row])
  elif rows>=34:
   net_row=next(i for i,line in enumerate(screen.display) if 'NET ' in line)
   assert 'n/a' in screen.display[net_row],screen.display[net_row]
   assert any('No interface data' in row for row in screen.display)
   key(b'n')
   assert any('No interface data' in row for row in screen.display)
  # Transparent canvas is preserved outside the selected row.
  assert screen.buffer[0][0].bg=='default'
  # Pause freezes the process list, select second row by mouse coordinates from the actual frame.
  key(b'p')
  row_index=header+2 if "╰" not in screen.display[header+2] else header+1
  second=screen.display[row_index]
  left=second.rfind('\u2502',0,cols-2) # process panel's left border
  pid=re.search(r'\d+',second[left+1:]).group(0)
  key(f'\x1b[<0;{left+5};{row_index+1}M'.encode())
  assert any('SELECTED '+pid+' ' in row for row in screen.display),screen.display
  key(b's');assert any('SORT: memory' in row for row in screen.display)
  key(b'x');assert any('ascending' in row for row in screen.display)
  key(b'-');assert '3000ms' in screen.display[0]
  key(b'+');assert '2000ms' in screen.display[0]
  key(b'h');collect(1)
  history_row=next(i for i,line in enumerate(screen.display) if 'APP HISTORY' in line)
  history_column=screen.display[history_row].index('APP HISTORY')
  assert all(screen.buffer[history_row][x].bold for x in range(history_column,history_column+11))
  assert '**APP HISTORY**' not in screen.display[history_row]
  key(b'q');p.wait(timeout=5)
  assert p.returncode==0 and termios.tcgetattr(slave)==before
  print('PASS: layout, numeric columns, row click, sorting, interval, restoration',cols,rows)
 finally:
  if p.poll() is None:
   p.terminate();collect(2)
   try:p.wait(timeout=5)
   except subprocess.TimeoutExpired:p.kill();p.wait()
  os.close(master);os.close(slave)
