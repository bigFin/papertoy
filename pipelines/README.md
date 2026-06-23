# Pipeline Files

Paper Toy now supports a minimal pipeline file format through:

```console
papertoy --pipeline <file>
```

This first version intentionally models the current "unified" behavior rather
than the final multi-pass design. A pipeline file currently defines:

- one base shader
- zero or one built-in post-process pass
- audio capture settings
- unified time and visual modulation settings

## Environment

Tracked example pipelines use `PAPERTOY_DEFAULT_SHADER` so machine-local shader
paths do not need to be committed.

Example:

```console
export PAPERTOY_DEFAULT_SHADER=/storage/SyncBox/shaders/stochastic-asym-quads-everforest-dark-medium.glsl
papertoy --pipeline pipelines/desktop-audio.example.toml
```

## Schema

```toml
[[passes]]
kind = base
path = "${PAPERTOY_DEFAULT_SHADER}"

[[passes]]
kind = postprocess
effect = pulse_zoom
strength = 1.35

[audio]
enabled = true
capture = sink
target = "auto"

[modulation]
time_reactive = true
time_strength = 2.0
visual_reactive = true
visual_strength = 1.0
visual_style = blend
```

Notes:

- `path` may be absolute, relative to the pipeline file, or `${ENV_VAR}`.
- `capture` is `sink` or `source`.
- `target = "auto"` means use automatic device selection.
- `visual_style` is one of `blend`, `pulse`, `drift`, `strobe`, `heat`.
- this version requires exactly one `kind = base` pass
- this version optionally allows one `kind = postprocess` pass
- the first built-in postprocess effect is `pulse_zoom`
- built-in postprocess passes currently support `strength`

Compatibility:

- `[pipeline] base = "..."` still works as legacy sugar for a single base pass

## CLI Interaction

In this version, `--pipeline` owns audio and modulation settings. These flags
cannot be combined with `--pipeline`:

- `--audio-reactive`
- `--audio-target`
- `--audio-capture`
- `--audio-time-reactive`
- `--audio-time-strength`
- `--audio-visual-reactive`
- `--audio-visual-strength`
- `--audio-visual-style`

The remaining top-level runtime controls still come from the CLI:

- `--output`
- `--frame-rate`
- `--resolution`
- `--audio-debug`

## Examples

- [desktop-audio.example.toml](desktop-audio.example.toml)
- [desktop-audio-post.example.toml](desktop-audio-post.example.toml)
- [desktop-static.example.toml](desktop-static.example.toml)

## Next Step

The next evolution of this format is explicit pass lists. The current unified
schema is intentionally small so it can be the stable bridge from the existing
single-shader launcher to a real composable pipeline runner.
