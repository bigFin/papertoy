#!/usr/bin/env python3
"""Exercise a packaged Papertoy on a disposable desktop. See tests/README.md."""

import argparse
import array
import contextlib
import json
import math
import os
from pathlib import Path
import re
import select
import shutil
import signal
import struct
import subprocess as sp
import sys
import tempfile
import time
import wave
from xml.sax.saxutils import escape


SINK = 'papertoy-smoke'
TOOLS = 'dbus-daemon Xvfb niri grim pipewire wireplumber wpctl pw-dump pw-link pw-play pw-record'
interrupted = 0


class Failure(Exception):
    pass


def interrupt(sig, _frame):
    # Defer unwinding until any newly spawned child has a cleanup handler.
    global interrupted
    interrupted = sig


def checkpoint():
    if interrupted:
        raise SystemExit(128 + interrupted)


def until(label, probe, timeout=12):
    deadline = time.monotonic() + timeout
    while True:
        checkpoint()
        result = probe()
        if result:
            return result
        if time.monotonic() >= deadline:
            raise Failure(f'timed out waiting for {label}')
        time.sleep(0.12)


class Desktop:
    def __init__(self, root, logs, args):
        self.root, self.logs, self.args = root, logs, args
        self.runtime = root / 'run'
        self.config = root / 'config'
        self.children = {}
        self.env = {k: os.environ[k] for k in ('PATH', 'USER') if k in os.environ}
        self.env.update(LC_ALL='C', LIBGL_ALWAYS_SOFTWARE='1',
                        DBUS_SESSION_BUS_ADDRESS=f'unix:path={root}/bus',
                        DBUS_SYSTEM_BUS_ADDRESS=f'unix:path={root}/no-system-bus',
                        PIPEWIRE_RUNTIME_DIR=str(self.runtime), PIPEWIRE_REMOTE='pipewire-0')
        for key, name in [('HOME', 'home'), ('XDG_RUNTIME_DIR', 'run'), ('XDG_CONFIG_HOME', 'config'),
                          ('XDG_CACHE_HOME', 'cache'), ('XDG_DATA_HOME', 'data'), ('XDG_STATE_HOME', 'state'),
                          ('TMPDIR', 'tmp')]:
            (root / name).mkdir(mode=0o700)
            self.env[key] = str(root / name)
        self.cwd = root / 'empty'
        self.cwd.mkdir()

    def check(self):
        checkpoint()
        for name, proc in self.children.items():
            if proc.poll() is not None:
                raise Failure(f'{name} exited ({proc.returncode}); see {self.logs / (name + ".log")}')

    def run(self, *argv, check=True):
        self.check()
        result = sp.run(argv, cwd=self.cwd, env=self.env, capture_output=True, timeout=6)
        if check and result.returncode:
            raise Failure(f'{argv} exited ({result.returncode}): {result.stderr.decode(errors="replace").strip()}')
        return result.stdout

    @contextlib.contextmanager
    def process(self, name, *argv, extra=None, pass_fds=(), service=True):
        self.check()
        with (self.logs / (name + '.log')).open('wb') as log:
            proc = sp.Popen(argv, cwd=self.cwd, env={**self.env, **(extra or {})}, stdin=sp.DEVNULL,
                            stdout=log, stderr=log, start_new_session=True, pass_fds=pass_fds)
            try:
                if service:
                    self.children[name] = proc
                yield proc
            finally:
                self.children.pop(name, None)
                # Papertoy starts pw-record, so stop its group, not only the wrapper.
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(proc.pid, signal.SIGTERM)
                with contextlib.suppress(sp.TimeoutExpired):
                    proc.wait(timeout=2)
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(proc.pid, signal.SIGKILL)
                proc.wait(timeout=2)

    def start(self, stack):
        def start(*args, **kw):
            return stack.enter_context(self.process(*args, **kw))

        bus = self.root / 'bus.conf'
        bus.write_text('<busconfig><type>session</type><listen>' + escape(self.env['DBUS_SESSION_BUS_ADDRESS'])
                       + '</listen><policy context="default"><allow own="*"/><allow send_destination="*"/>'
                       '<allow receive_sender="*"/></policy></busconfig>')  # No host activation services.
        start('dbus', 'dbus-daemon', '--nofork', f'--config-file={bus}')
        until('private session bus', lambda: (self.root / 'bus').is_socket())

        # An Xauthority wildcard record works for the display number Xvfb will allocate.
        auth = self.root / 'Xauthority'
        fields = [b'', b'', b'MIT-MAGIC-COOKIE-1', os.urandom(16)]
        auth.write_bytes(b'\xff\xff' + b''.join(struct.pack('>H', len(x)) + x for x in fields))
        self.env['XAUTHORITY'] = str(auth)
        r, w = os.pipe()
        with os.fdopen(r, 'rb') as read:
            with os.fdopen(w, 'wb'):
                start('xvfb', 'Xvfb', '-displayfd', str(w), '-screen', '0', '1280x800x24', '-noreset',
                      '-auth', str(auth), '-nolisten', 'tcp', pass_fds=(w,))
            until('Xvfb display number', lambda: select.select([read], [], [], 0)[0])
            display = read.readline().strip()
            if not display.isdigit():
                raise Failure('Xvfb did not allocate a display; see xvfb.log')
        self.env['DISPLAY'] = ':' + display.decode()
        config = self.root / 'niri.kdl'
        config.write_text('layout { background-color "#000000"; }\nhotkey-overlay { skip-at-startup; }\n')
        extra = {'LD_LIBRARY_PATH': self.args.niri_x11_libs} if self.args.niri_x11_libs else {}
        start('niri', 'niri', '-c', str(config), extra=extra)  # No --session or global environment export.

        def sockets():
            self.check()
            wl = [p for p in self.runtime.glob('wayland-*') if p.is_socket()]
            ipc = [p for p in self.runtime.glob('niri.*.sock') if p.is_socket()]
            return (wl[0], ipc[0]) if wl and ipc else None

        wl, ipc = until('nested Wayland and Niri IPC sockets (see niri.log)', sockets)
        self.env.update(WAYLAND_DISPLAY=str(wl), NIRI_SOCKET=str(ipc))
        outputs = self.outputs()
        if len(outputs) != 1:
            raise Failure(f'expected one nested output, got {list(outputs)}')
        self.output = next(iter(outputs))

        conf = self.config / 'pipewire/pipewire.conf.d/90-null.conf'
        conf.parent.mkdir(parents=True)
        conf.write_text('context.objects = [{ factory = adapter args = { factory.name = support.null-audio-sink '
                        f'node.name = {SINK} media.class = Audio/Sink audio.position = [ FL FR ] }} }}]')
        start('pipewire', 'pipewire')
        until('private PipeWire socket', lambda: (self.runtime / 'pipewire-0').is_socket())
        start('wireplumber', 'wireplumber', '-p', 'policy')  # No hardware discovery profile.
        until('null sink to become the private default', lambda: f'node.name = "{SINK}"'.encode() in
              self.run('wpctl', 'inspect', '@DEFAULT_AUDIO_SINK@', check=False))
        self.verify_audio_devices()
        print(f'Private default sink: {SINK}; nested output: {self.output}', flush=True)

    def verify_audio_devices(self):
        graph = json.loads(self.run('pw-dump'))
        devices = [p.get('node.name') for node in graph if node['type'] == 'PipeWire:Interface:Node'
                   for p in [node['info']['props']] if p.get('media.class', '').startswith(('Audio/Sink', 'Audio/Source'))]
        if devices != [SINK]:
            raise Failure(f'refusing playback: expected only {SINK}, found {devices}')

    def outputs(self):
        return json.loads(self.run('niri', 'msg', '--json', 'outputs'))

    def frame(self):
        ppm = self.run('grim', '-o', self.output, '-t', 'ppm', '-')
        magic, size, limit, data = ppm.split(b'\n', 3)
        w, h = map(int, size.split())
        if magic != b'P6' or limit != b'255' or len(data) != w*h*3:
            raise Failure(f'invalid grim PPM: {magic!r}, {size!r}, {limit!r}, {len(data)} bytes')
        return w, h, data, ppm

    def app(self, label, *args, trace=False):
        extra = {'WAYLAND_DEBUG': 'client'} if trace else {}
        if self.args.egl_vendor:
            extra['__EGL_VENDOR_LIBRARY_FILENAMES'] = str(self.args.egl_vendor)
        return self.process(label, self.args.binary, *args, extra=extra)


def fullscreen(d):
    shader = d.root / 'resolution.glsl'
    shader.write_text('void mainImage(out vec4 color, in vec2 p) { color = all(equal(iResolution.xy, '
                      'vec2(321.,181.))) ? vec4(1.,0.,1.,1.) : vec4(0.,1.,0.,1.); }\n')
    for scale in (1, 1.25):
        label = f'viewport-{scale}'
        d.run('niri', 'msg', 'output', d.output, 'scale', str(scale))

        def configured():
            output = d.outputs()[d.output]
            return output if output['logical'] and output['logical']['scale'] == scale else None

        output = until(f'{d.output} scale {scale}', configured)
        logical = output['logical']
        mode = output['modes'][output['current_mode']]
        native = (mode['width'], mode['height'])
        if min(native) <= 321:
            raise Failure(f'nested output {native} is too small for viewport fixture')
        colors = []
        frame = None

        def corners():
            nonlocal frame
            w, h, data, frame = d.frame()
            if (w, h) != native:
                raise Failure(f'grim captured {(w, h)}, expected native mode {native}')
            points = [(0, 0), (w-1, 0), (0, h-1), (w-1, h-1), (w//2, h//2)]
            colors[:] = [tuple(data[3*(x+y*w):3*(x+y*w)+3]) for x, y in points]
            return all(r > 240 and g < 16 and b > 240 for r, g, b in colors)

        # Do not let a stale frame from the previous scale satisfy this case.
        until('bare nested output', lambda: not corners() and all(max(c) < 16 for c in colors))
        with d.app(label, shader, '--output', f'id={d.output},resolution=321x181,frame-rate=15', trace=True):
            try:
                until(f'magenta at all four corners and center ({label}, iResolution 321x181)', corners)
            except Failure as exc:
                raise Failure(f'{exc}; last RGB samples: {colors}') from exc
            finally:
                if frame:
                    (d.logs / (label + '.ppm')).write_bytes(frame)
            text = (d.logs / (label + '.log')).read_text(errors='replace')
            destination = f'.set_destination({logical["width"]}, {logical["height"]})'
            attached = re.search(r'\.attach\(wl_buffer', text)
            if not attached or destination not in text[:attached.start()]:
                raise Failure(f'{label}: missing {destination} before first buffer; see client trace')
            sizes = re.findall(r'create_buffer\(new id wl_buffer[#@]\d+, \d+, (\d+), (\d+),', text)
            if sizes and set(sizes) != {('321', '181')}:
                raise Failure(f'{label}: unexpected wl_shm buffer sizes {set(sizes)}')
        until('wallpaper removal', lambda: b'Namespace: "papertoy"' not in d.run('niri', 'msg', 'layers'))
        print(f'PASS {label}: {native}, {destination}, corners and center magenta at 321x181', flush=True)


def audio(d):
    wav = d.root / 'tone.wav'
    rate = 48000
    pcm = array.array('h', (int(14000 * math.sin(2*math.pi*120*n/rate)) for n in range(rate)))
    if sys.byteorder != 'little':
        pcm.byteswap()
    with wave.open(str(wav), 'wb') as f:
        f.setparams((1, 2, rate, 0, 'NONE', 'not compressed'))
        f.writeframes(pcm.tobytes() * 10)

    def linked():
        links = d.run('pw-link', '-l').decode()
        return links if all(re.search(rf'^{SINK}:monitor_{ch}\n\s+\|-> pw-record:input_{ch}$', links, re.M)
                            for ch in ('FL', 'FR')) else None

    def sample(label, phase, baseline=None):
        # In Tidelines, time moves the contours; only audio turns the water amber.
        last = {}
        def probe():
            _, _, data, ppm = d.frame()
            pixels = [data[i:i+3] for i in range(0, len(data), 3*53)]
            amber = sum(r > g and r > b for r, g, b in pixels) / len(pixels)
            cool = sum(b > r for r, g, b in pixels) / len(pixels)
            moved = sum(a != b for a, b in zip(pixels, baseline)) / len(pixels) if baseline else 0
            last.update(amber=round(amber, 4), cool=round(cool, 4), moved=round(moved, 4))
            if phase == 'tone' and player.poll() is not None:
                raise Failure(f'playback ended before tone response (exit {player.returncode})')
            ok = amber > 0.35 if phase == 'tone' else (amber < 0.02 and cool > 0.8)
            if ok and (not baseline or moved > 0.05):
                (d.logs / (label + '.ppm')).write_bytes(ppm)
                return pixels
        try:
            pixels = until(f'{label} pixels', probe)
        except Failure as exc:
            raise Failure(f'{exc}; last fractions {last}') from exc
        print(f'{label}: {last}', flush=True)
        return pixels

    with d.app('demo', '--demo'):
        links = until('stereo monitor → pw-record links (see demo.log)', linked)
        (d.logs / 'pw-links.txt').write_text(links)
        idle = sample('idle-1', 'quiet')
        sample('idle-2', 'quiet', baseline=idle)
        d.verify_audio_devices()  # Never play before checking the graph.
        with d.process('tone', 'pw-play', '--target', SINK, wav, service=False) as player:
            sample('tone', 'tone')
            until('pw-play to finish the WAV', lambda: player.poll() is not None, timeout=13)
            if player.returncode != 0:
                raise Failure('pw-play failed; see tone.log')
        sample('idle-after', 'quiet')
    print('PASS --demo: private default sink monitor drove idle → tone → idle', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path, help='path to the built Papertoy executable')
    parser.add_argument('--egl-vendor', type=Path, help='Mesa EGL vendor JSON for Papertoy only')
    parser.add_argument('--niri-x11-libs', help='colon-separated X11 library directories for Niri only')
    args = parser.parse_args()
    args.binary = args.binary.resolve()
    if not args.binary.is_file() or not os.access(args.binary, os.X_OK):
        parser.error(f'not an executable file: {args.binary}')
    if args.egl_vendor:
        args.egl_vendor = args.egl_vendor.resolve()
        if not args.egl_vendor.is_file():
            parser.error(f'no EGL vendor manifest: {args.egl_vendor}')
    missing = [cmd for cmd in TOOLS.split() if not shutil.which(cmd)]
    if missing:
        parser.error('missing from PATH: ' + ', '.join(missing) + '; see tests/README.md')
    logs = Path(tempfile.mkdtemp(prefix='papertoy-smoke-'))
    print(f'Package: {args.binary}\nLogs and frames: {logs}', flush=True)
    with tempfile.TemporaryDirectory(prefix='pt-') as tmp, contextlib.ExitStack() as stack:
        if len(os.fsencode(tmp)) + 42 >= 108:
            raise Failure('TMPDIR is too long for Unix sockets; set it to a shorter writable path')
        desktop = Desktop(Path(tmp), logs, args)
        desktop.start(stack)
        fullscreen(desktop)
        audio(desktop)
    checkpoint()


if __name__ == '__main__':
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, interrupt)
    try:
        main()
    except (Failure, OSError, sp.TimeoutExpired, ValueError) as error:
        checkpoint()
        sys.exit(f'FAIL: {error}')
