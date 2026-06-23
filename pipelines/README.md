# Pipeline Files

Paper Toy now supports a minimal pipeline file format through:

```console
papertoy --pipeline <file>
```

A pipeline file currently defines a bounded linear render pipeline:

- one base shader
- zero to four ordered built-in post-process passes
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
strength = 0.95

[[passes]]
kind = postprocess
effect = glow_grade
strength = 0.85

[[passes]]
kind = postprocess
effect = heat_shift
strength = 0.55

[[passes]]
kind = postprocess
effect = impact_flash
strength = 0.75

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
- this version allows up to four ordered `kind = postprocess` passes
- built-in postprocess effects are `pulse_zoom`, `glow_grade`, `heat_shift`,
  `impact_flash`, and `shock_ring`
- built-in postprocess passes currently support `strength`

Compatibility:

- `[pipeline] base = "..."` still works as legacy sugar for a single base pass

## Built-In Effects

Run `papertoy --list-effects` to print the built-in effect list from the CLI.

| Effect | Feel | Main audio drivers | Good use |
| --- | --- | --- | --- |
| `pulse_zoom` | zoom, contrast, subtle swirl | impact, energy, brightness | first pass after the base shader |
| `glow_grade` | glow, saturation, contrast lift | energy, brightness | grading and bloom-like polish |
| `heat_shift` | warm chromatic shimmer | bass, impact, energy | color movement and heat haze |
| `impact_flash` | flash, ring, vignette | beat, impact, brightness | beat accents near the end of a chain |
| `shock_ring` | radial ripple and color separation | beat, impact, drive, brightness | deliberately trippy accent chains |

`strength` scales the audio-reactive inputs for that pass. Effects are ordered:
each postprocess pass samples the output of the previous pass.

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
- [desktop-audio-post.example.toml](desktop-audio-post.example.toml) uses a
  four-pass built-in effect chain
- [desktop-static.example.toml](desktop-static.example.toml)

## Current Limits

Postprocess chaining is linear: each postprocess pass samples the previous pass
output, and the final postprocess pass renders to the wallpaper surface. Named
intermediate textures, feedback passes, and arbitrary graph execution are not
part of this schema yet.
