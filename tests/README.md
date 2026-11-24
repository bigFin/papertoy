# Local Wayland integration smoke test

```sh
python3 tests/wayland-smoke.py ./result/bin/papertoy
```

Pass the **built executable** you intend to ship (for the flake's default package, `nix build` creates `./result`). The script needs no Python packages and does not build Papertoy. It exits zero only if both checks pass. It prints the executable path and a scratch directory with service logs, Wayland traces, monitor links and native PPM frames; remove that directory when you no longer need it.

For the opt-in Linux Nix package (`nix build .#audio`), add `--isolate-app-path` to verify that the installed wrapper supplies `wpctl` and `pw-record`. This gives only Papertoy an empty directory as its `PATH`; the fixture still uses the tools below. Omit the flag for the default package, source builds, and portable releases, which use the caller's tools.

**Linux prerequisites:** Python 3.8+, Xvfb, Niri with its nested X11 backend and fractional scaling, `grim` with PPM capture, `dbus-daemon`, and Mesa software EGL. Audio needs PipeWire (`pipewire`, `pw-dump`, `pw-link`, `pw-play`, `pw-record`, and the null-sink SPA plugin) and WirePlumber 0.5+ (`wireplumber -p policy`, `wpctl`). Put the commands on `PATH`. No running desktop or sound server is required.

### What a pass proves

- **Fullscreen rendering:** Papertoy renders a shader at a requested **321×181**, deliberately smaller than the output. The shader is magenta only for that exact `iResolution.xy`, green otherwise. Starting from a black desktop, the test checks the four outermost pixels and the center of a native capture at **100% and 125%** scale. The client trace must set the logical viewport destination before attaching the first buffer; when Mesa exposes `wl_shm` buffer allocations, those must also be 321×181.
- **Playback response:** The packaged `--demo` runs from an empty directory, with no capture target or shader overrides. The test verifies the private stereo null sink is the default, checks its monitor-to-`pw-record` links, and plays a 120 Hz WAV into **that sink only**. It requires two changing, cool-colored idle frames, more than 35% red-dominant samples during playback, and a return to a cool palette with less than 2% red-dominant samples after playback. These thresholds test **Tidelines**, not arbitrary shaders.

The fixture uses a new Xvfb display, private Niri socket, home/XDG directories, a non-activating session bus, and a private PipeWire runtime. WirePlumber runs policy only, not hardware discovery. The script checks there is no other source or sink before playing. It does not restart desktop services, change the host default sink, or record the host microphone. Ctrl-C and SIGTERM tear down the test processes. This is a single-output software rendering check, not a GPU benchmark, hotplug/reconnect test, or hardware audio test.

### NixOS: separate the compositor and client libraries if needed

If Niri cannot load an X11 library (`niri.log`), supply `--niri-x11-libs` from the **compositor's** nixpkgs. If Papertoy fails EGL initialization (`viewport-1.log`), supply `--egl-vendor` from the **application's** nixpkgs. For example, from this checkout, with `nixpkgs` pointing to the host revision:

```sh
mesa=$(nix build --no-link --print-out-paths --inputs-from . nixpkgs#mesa)
xlibs=$(nix build --no-link --print-out-paths nixpkgs#libx11^out nixpkgs#libxi^out \
    nixpkgs#libxrandr^out nixpkgs#libxcursor^out |
    while read -r pkg; do printf '%s/lib\n' "$pkg"; done | paste -sd:)
python3 tests/wayland-smoke.py ./result/bin/papertoy \
    --egl-vendor "$mesa/share/glvnd/egl_vendor.d/50_mesa.json" --niri-x11-libs "$xlibs"
```

The two flags affect different processes; neither changes system driver discovery. If socket creation fails because `TMPDIR` is too long, select a shorter writable directory and rerun. For audio startup failures check `pipewire.log`, `wireplumber.log` and `demo.log` in the printed evidence directory.

## Output removal and reconnect

```sh
python3 tests/output-reconnect.py ./result/bin/papertoy
```

This separate Linux fixture runs a **private headless Sway** with two outputs, pixman, and software EGL. It needs Python 3, `sway`, `swaymsg`, `grim`, and `/proc`; it does not use the host compositor or start audio. Use **Sway 1.12 / wlroots 0.20.2** or a version whose headless backend removes and re-announces `wl_output` on disable/enable and resumes page flips. Older versions can accept the commands without doing this. On NixOS, put `$(nix build --no-link --print-out-paths nixpkgs#sway-unwrapped)/bin` on `PATH` and pass the same `--egl-vendor` option as above.

- **Explicit selection:** disabling `HEADLESS-1` leaves `HEADLESS-2` bare. The process waits without consuming a full CPU, then paints red on a fresh registry global. The shader returns red only at `111x77` with `iFrameRate == 15`; the Wayland trace confirms the bottom layer and configure acknowledgement before its first buffer.
- **Automatic selection:** the original surface on `HEADLESS-2` continues submitting buffers both while its peer is absent and after the replacement has painted. Only `HEADLESS-1` gets a replacement, and a subsequently created `HEADLESS-3` picks up the global defaults. Both cases delete the shader file after startup, so a replacement must use the original source.

The fixture also verifies that invalid base GLSL is fatal with outputs present at launch or when the first output appears later. In the deferred case, it also checks custom post-process compile and link failures. The script prints the package path, test PIDs, and evidence directory. This tests compositor hotplug events, not physical cable detection or reconnecting to a restarted compositor.
