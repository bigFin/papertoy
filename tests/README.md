# Local Wayland integration smoke test

```sh
python3 tests/wayland-smoke.py ./result/bin/papertoy
```

Pass the **built executable** you intend to ship (for the flake's default package, `nix build` creates `./result`). The script needs no Python packages and does not build Papertoy. It exits zero only if both checks pass. It prints the executable path and a scratch directory with service logs, Wayland traces, monitor links and native PPM frames; remove that directory when you no longer need it.

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
