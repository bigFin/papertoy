#!/usr/bin/env python3
"""Test output policy and surface lifetime on a private headless Sway. See README.md."""

import argparse
import contextlib
import json
import os
from pathlib import Path
import re
import runpy
import signal
import subprocess
import sys
import tempfile
import time

# Reuse the existing fixture's isolated environment, checked child processes,
# bounded waits and signal-safe cleanup; do not start its Niri or audio services.
smoke = runpy.run_path(str(Path(__file__).with_name('wayland-smoke.py')))
Desktop, until, Failure = (smoke[k] for k in ('Desktop', 'until', 'Failure'))


def center(d, name):
    magic, size, limit, data = d.run('grim', '-o', name, '-t', 'ppm', '-').split(b'\n', 3)
    w, h = map(int, size.split())
    if magic != b'P6' or limit != b'255' or len(data) != w*h*3:
        raise Failure(f'invalid capture of {name}')
    offset = 3 * ((h//2)*w + w//2)
    return tuple(data[offset:offset+3])


def command(d, *cmd):
    if not all(reply['success'] for reply in json.loads(d.run('swaymsg', '-r', *cmd))):
        raise Failure(f'Sway rejected {cmd}')


def start_sway(d, stack):
    d.env.update(WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='2', WLR_RENDERER='pixman',
                 WLR_LIBINPUT_NO_DEVICES='1')
    config = d.root / 'sway.conf'
    config.write_text('xwayland disable\noutput * mode 640x480\n')
    stack.enter_context(d.process('sway', 'sway', '-c', config))

    def sockets():
        d.check()
        ipc = [p for p in d.runtime.glob('sway-ipc.*.sock') if p.is_socket()]
        wl = [p for p in d.runtime.glob('wayland-*') if p.is_socket()]
        return (ipc[0], wl[0]) if ipc and wl else None

    ipc, wl = until('private Sway sockets', sockets)
    d.env.update(SWAYSOCK=str(ipc), WAYLAND_DISPLAY=str(wl))
    outputs = json.loads(d.run('swaymsg', '-r', '-t', 'get_outputs'))
    if {o['name'] for o in outputs if o['active']} != {'HEADLESS-1', 'HEADLESS-2'}:
        raise Failure(f'expected two headless outputs, got {outputs}')


def check_reconnect(d, explicit):
    label = 'explicit' if explicit else 'automatic'
    first, survivor = 'HEADLESS-1', 'HEADLESS-2'
    shader = d.root / 'profile.glsl'
    shader.write_text('void mainImage(out vec4 c, in vec2 p) {\n'
                      '  bool valid = all(equal(iResolution.xy, vec2(111.,77.))) && iFrameRate == 15.;\n'
                      '  c = valid ? vec4(1,0,0,1) : vec4(0,1,0,1);\n}\n')
    args = (['--output', 'id=HEADLESS-1,resolution=111x77,frame-rate=15,layer=bottom']
            if explicit else ['--resolution', '111x77', '--frame-rate', '15'])
    bare = center(d, survivor)
    red = (255, 0, 0)
    if bare == red:
        raise Failure('previous wallpaper still present')
    trace_path = d.logs / (label + '.log')

    def trace():
        d.check()
        return trace_path.read_text(errors='replace')

    def painted(output):
        until(f'{label}: red profile pixel on {output}', lambda: center(d, output) == red)

    def layers(text):
        return re.findall(r'get_layer_surface\(new id (zwlr_layer_surface_v1[#@]\d+), '
                          r'(wl_surface[#@]\d+), (wl_output[#@]\d+), (\d+), "papertoy"', text)

    def bound_global(text, proxy):
        suffix = re.escape(proxy[len('wl_output'):])
        match = re.search(r'\.bind\((\d+), "wl_output", \d+, new id (?:\[unknown\]|wl_output)' + suffix + r'\)', text)
        if not match:
            raise Failure(f'cannot identify registry global for {proxy}; see {trace_path}')
        return match[1]

    with d.app(label, *args, shader, trace=True) as proc:
        painted(first)
        if not explicit:
            painted(survivor)
        initial = trace()
        names = {proxy: name for proxy, name in re.findall(r'(wl_output[#@]\d+)\.name\("([^"]+)"\)', initial)}
        by_name = {names[layer[2]]: layer for layer in layers(initial)}

        def check_survivor(stage):
            surface = by_name[survivor][1]
            before = len(trace())

            def submitted():
                text = trace()
                if f'{surface}.destroy()' in text[len(initial):]:
                    raise Failure(f'original {survivor} surface was destroyed')
                attach = text.find(f'{surface}.attach(wl_buffer', before)
                return attach >= 0 and f'{surface}.commit()' in text[attach:]

            until(f'original survivor submits {stage}', submitted)
            painted(survivor)

        old_global = bound_global(initial, by_name[first][2])
        wanted_layer = '1' if explicit else '0'
        if by_name[first][3] != wanted_layer or len(by_name) != (1 if explicit else 2):
            raise Failure(f'unexpected starting layers: {by_name}')
        shader.unlink()  # A replacement must use the startup source, not reopen the file.
        command(d, 'output', first, 'disable')
        until(f'global_remove({old_global})', lambda: f'.global_remove({old_global})' in trace())
        until('old wallpaper stopped', lambda: 'stopping wallpaper' in trace())
        if explicit:
            if center(d, survivor) != bare:
                raise Failure('explicit profile migrated to the unselected output')
            # Measure the event thread, not driver helper threads. A busy dispatch loop
            # consumes CPU ticks even when WAYLAND_DEBUG has nothing to report.
            def cpu():
                fields = Path(f'/proc/{proc.pid}/task/{proc.pid}/stat').read_text().rsplit(')', 1)[1].split()
                return int(fields[11]) + int(fields[12])
            start = cpu()
            time.sleep(0.75)
            ticks = cpu() - start
            if ticks > 1:
                raise Failure(f'no-output idle consumed {ticks} ticks')
            print(f'{label}: PID {proc.pid}, no-paper idle {ticks} ticks/0.75s, {survivor} bare {bare}', flush=True)
        else:
            check_survivor('while its peer is absent')
        mark = len(trace())
        command(d, 'output', first, 'enable')
        painted(first)
        text = trace()[mark:]
        created = layers(text)
        if len(created) != 1:
            raise Failure(f'expected only one new layer: {created}')
        layer, surface, proxy, kind = created[0]
        new_global = bound_global(text, proxy)
        ack = text.find(layer + '.ack_configure(')
        attach = text.find(surface + '.attach(wl_buffer')
        if (old_global == new_global or kind != wanted_layer or ack < 0 or attach < ack
                or f'{proxy}.name("{first}")' not in text or len(layers(trace())) != len(by_name) + 1):
            raise Failure(f'wrong replacement global, output, layer, or configure/attach order; see {trace_path}')
        if not explicit:
            # A stale red screenshot cannot prove the survivor still renders.
            # Start a fresh trace window after the replacement's red pixel and ack/attach.
            check_survivor('after the replacement paints')
            command(d, 'create_output')
            painted('HEADLESS-3')
            print(f'{label}: original {survivor} kept submitting; new HEADLESS-3 inherited 111x77 @ 15', flush=True)
        print(f'PASS {label}: PID {proc.pid}, {first} global {old_global} → {new_global}, '
              f'layer {kind}, red at 111x77 @ 15 after ack', flush=True)


def check_deferred_shader_validation(d, label, args, diagnostic, error):
    log = d.logs / (label + '.log')
    for output in ('HEADLESS-1', 'HEADLESS-2'):
        command(d, 'output', output, 'disable')
    with d.app(label, *args, trace=True) as proc:
        def initial_roundtrips_done():
            d.check()
            text = log.read_text(errors='replace')
            if re.search(r'\.global\(\d+, "wl_output",', text):
                raise Failure('deferred shader test started with an advertised output')
            return len(re.findall(r'wl_callback[#@]\d+\.done\(', text)) >= 2

        until('startup registry roundtrips without outputs', initial_roundtrips_done)
        command(d, 'output', 'HEADLESS-1', 'enable')
        try:
            status = proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            if diagnostic in log.read_text(errors='replace'):
                raise Failure(f'{label}: Papertoy kept running after deferred shader validation failed') from None
            raise
        text = log.read_text(errors='replace')
        if status != 1 or diagnostic not in text or f'error: {error}' not in text:
            raise Failure(f'{label}: expected fatal deferred shader error; see {log}')
    command(d, 'output', 'HEADLESS-2', 'enable')
    print(f'PASS {label}: {error} is fatal when the first output appears', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('--egl-vendor', type=Path, help='application Mesa vendor JSON')
    parser.add_argument('--isolate-app-path', action='store_true',
                        help='give Papertoy an empty directory as PATH to test packaged helpers')
    args = parser.parse_args()
    args.binary = args.binary.resolve(strict=True)
    if args.egl_vendor:
        args.egl_vendor = args.egl_vendor.resolve(strict=True)
    logs = Path(tempfile.mkdtemp(prefix='reconnect-'))
    print(f'Package: {args.binary}\nLogs and traces: {logs}', flush=True)
    with tempfile.TemporaryDirectory(prefix='pt-') as tmp, contextlib.ExitStack() as stack:
        d = Desktop(Path(tmp), logs, args)
        start_sway(d, stack)
        shader = d.root / 'missing-target.glsl'
        shader.write_text('void mainImage(out vec4 c, in vec2 p) { c=vec4(1); }\n')
        with d.app('missing-target', '--output', 'ABSENT', shader) as proc:
            if proc.wait(timeout=5) != 1 or "output with name 'ABSENT' not found" not in (logs / 'missing-target.log').read_text():
                raise Failure('absent startup name did not produce the expected error')
        shader.write_text('not valid GLSL\n')
        with d.app('invalid-startup-shader', shader) as proc:
            if proc.wait(timeout=5) == 0 or 'failed to compile shader' not in (logs / 'invalid-startup-shader.log').read_text():
                raise Failure('invalid startup shader did not fail validation')
        check_deferred_shader_validation(d, 'invalid-deferred-base', [shader],
                                         'failed to compile shader', 'ShaderFailedToCompile')
        shader.write_text('void mainImage(out vec4 c, in vec2 p) { c=vec4(1); }\n')
        post = d.root / 'custom.post.glsl'
        pipeline = d.root / 'custom-pipeline.toml'
        pipeline.write_text(f'[[passes]]\nkind = base\npath = "{shader.name}"\n\n'
                            f'[[passes]]\nkind = postprocess\npath = "{post.name}"\n')
        for action, source, error in (
            ('compile', 'not valid GLSL\n', 'ShaderFailedToCompile'),
            ('link', '#version 330 core\nout vec4 color;\n', 'ProgramFailedToLink'),  # No main().
        ):
            post.write_text(source)
            check_deferred_shader_validation(d, f'invalid-deferred-post-{action}', ['--pipeline', pipeline],
                                             f'failed to {action} {post} post-process shader', error)
        check_reconnect(d, True)
        check_reconnect(d, False)
    smoke['checkpoint']()


if __name__ == '__main__':
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, smoke['interrupt'])
    try:
        main()
    except (Failure, OSError, subprocess.TimeoutExpired, ValueError) as exc:
        smoke['checkpoint']()
        sys.exit(f'FAIL: {exc}')
