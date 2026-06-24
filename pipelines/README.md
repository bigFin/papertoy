# Pipeline Files

Paper Toy now supports a minimal pipeline file format through:

```console
papertoy --pipeline <file>
```

A pipeline file currently defines a bounded linear render pipeline:

- one base shader
- zero to four ordered post-process passes
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

[[passes]]
kind = postprocess
path = "audio-soft-vignette.post.glsl"
strength = 0.85

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
- enum-style values such as `kind`, `effect`, `capture`, and `visual_style`
  may be written as bare identifiers or quoted strings.
- this version requires exactly one `kind = base` pass
- this version allows up to four ordered `kind = postprocess` passes
- each postprocess pass defines either `effect` for a built-in pass or `path`
  for a custom GLSL fragment shader, but not both
- built-in postprocess effects are `pulse_zoom`, `glow_grade`, `heat_shift`,
  `impact_flash`, and `shock_ring`
- `time_strength`, `visual_strength`, and postprocess `strength` must be
  non-negative finite numbers

Compatibility:

- `[pipeline] base = "..."` still works as legacy sugar for a single base pass

## Built-In Effects

Run `papertoy --list-effects` to print the built-in effect list and strength
guidance from the CLI.

| Effect | Feel | Main audio drivers | Good use |
| --- | --- | --- | --- |
| `pulse_zoom` | zoom, contrast, subtle swirl | impact, energy, brightness | first pass after the base shader |
| `glow_grade` | glow, saturation, contrast lift | energy, brightness | grading and bloom-like polish |
| `heat_shift` | warm chromatic shimmer | bass, impact, energy | color movement and heat haze |
| `impact_flash` | flash, ring, vignette | beat, impact, brightness | beat accents near the end of a chain |
| `shock_ring` | radial ripple and color separation | beat, impact, drive, brightness | deliberately trippy accent chains |

`strength` scales the audio-reactive inputs for that pass. Effects are ordered:
each postprocess pass samples the output of the previous pass. The CLI strength
values are tuning hints, not hard validation limits.

## Custom Postprocess Shaders

Custom postprocess shader files are full GLSL 330 core fragment shaders. They
sample the previous pass from `uInputTexture` using normalized coordinates and
write `fragColor`.

Available inputs:

- `in vec2 vUv`
- `uniform sampler2D uInputTexture`
- `uniform vec2 uResolution`
- `uniform vec4 uAudioBands`
- `uniform vec4 uAudioState`
- `uniform vec4 uAudioVisualizer`
- `uniform float uTime`
- `uniform float uStrength`

Example:

```glsl
#version 330 core

in vec2 vUv;
out vec4 fragColor;

uniform sampler2D uInputTexture;
uniform vec4 uAudioVisualizer;
uniform float uStrength;

void main() {
    vec3 color = texture(uInputTexture, vUv).rgb;
    color += vec3(0.08, 0.04, 0.02) * uAudioVisualizer.x * uStrength;
    fragColor = vec4(color, 1.0);
}
```

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
- `--audio-overlay`

## Examples

- [desktop-audio.example.toml](desktop-audio.example.toml)
- [desktop-audio-post.example.toml](desktop-audio-post.example.toml) uses a
  four-pass built-in effect chain
- [desktop-audio-soft.example.toml](desktop-audio-soft.example.toml) uses a
  gentler three-pass chain for daily desktop use
- [desktop-audio-shock.example.toml](desktop-audio-shock.example.toml)
  showcases the more intense `shock_ring` effect
- [desktop-audio-custom-post.example.toml](desktop-audio-custom-post.example.toml)
  combines a built-in effect with a custom GLSL postprocess pass
- [desktop-audio-liquid.example.toml](desktop-audio-liquid.example.toml)
  adds a custom orbital liquid-warp pass for smoother music-reactive motion
- [desktop-audio-prism-rift.example.toml](desktop-audio-prism-rift.example.toml)
  adds a custom folded prism pass for more aggressive chromatic movement
- [desktop-static.example.toml](desktop-static.example.toml)

## Current Limits

Postprocess chaining is linear: each postprocess pass samples the previous pass
output, and the final postprocess pass renders to the wallpaper surface. Named
intermediate textures, feedback passes, and arbitrary graph execution are not
part of this schema yet.
