// A tiny full-screen program with the same DEC alternate-buffer/mouse modes
// as OpenCode. It records the actual bytes received INSIDE real tmux, and
// continuously redraws coloured rows to exercise the terminal/UI hot path.
const terminalMouseFixture = r'''
import os, sys, tty, termios, select, time, re, json
status = sys.argv[1]
original = termios.tcgetattr(0)
tty.setraw(0)
os.write(1, b'\x1b[?1049h\x1b[?1000h\x1b[?1006h')
counts = dict(up=0, down=0, x=0, y=0, frames=0)
pending = b''
pattern = re.compile(rb'\x1b\[<(\d+);(\d+);(\d+)([Mm])')
try:
    while True:
        if select.select([0], [], [], 0.016)[0]:
            data = os.read(0, 65536)
            if not data or b'q' in data: break
            pending += data
            consumed = 0
            for m in pattern.finditer(pending):
                button, x, y = [int(v) for v in m.groups()[:3]]
                if button in (64, 65):
                    counts['up' if button == 64 else 'down'] += 1
                    counts['x'], counts['y'] = x, y
                consumed = m.end()
            pending = pending[consumed:][-4096:]
        cols, rows = os.get_terminal_size(0)
        counts['frames'] += 1
        lines = ['WHEEL up={up} down={down} x={x} y={y} frame={frames}'.format(**counts)]
        lines += [('row %03d ' % i + 'continuous terminal redraw / synthetic data ' * 8)[:max(cols-1,1)] for i in range(1, max(rows-1,2))]
        output = '\x1b[H' + '\r\n'.join('\x1b[48;2;17;24;39m\x1b[38;2;180;210;240m' + line.ljust(max(cols-1,1)) for line in lines) + '\x1b[0m'
        os.write(1, output.encode())
        with open(status + '.tmp', 'w') as f: json.dump(counts, f)
        os.replace(status + '.tmp', status)
finally:
    os.write(1, b'\x1b[?1000l\x1b[?1006l\x1b[?1049l')
    termios.tcsetattr(0, termios.TCSADRAIN, original)
    os.write(1, b'\r\nMOUSE-FIXTURE-EXIT\r\n')
''';
