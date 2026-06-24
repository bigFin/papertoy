# Preset Tuning Guide

Use `--audio-overlay` while tuning to see whether the preset is responding to
level, bass, mid, treble, beat, impact, energy, drive, or brightness.

## General Knobs

- Postprocess `strength`: first knob to adjust. It scales the audio signal for
  that pass without changing the rest of the chain.
- `time_strength`: changes how much the base shader's `iTime` motion speeds up
  with audio. Lower it if the original shader motion gets hard to read.
- `visual_reactive`: tracked presets keep this off so the base shader is not
  pre-graded before postprocess passes run. Enable it only when you explicitly
  want the base shader wrapper to change color and contrast.
- `visual_strength`: changes the generic visual wrapper when
  `visual_reactive` is enabled.
- `visual_style`: changes the base shader wrapper feel when `visual_reactive`
  is enabled. `drift` is smoother, `heat` is stronger and warmer, and `blend`
  is the safest default.

## Preset Notes

### Soft

File: [desktop-audio-soft.example.toml](desktop-audio-soft.example.toml)

- Main work: built-in `glow_grade` and light `heat_shift`.
- Tune first: lower `heat_shift` if colors get too warm; raise `glow_grade` if
  the preset feels too static.
- Daily-use risk: low. This is the safest wallpaper preset.

### Liquid

File: [desktop-audio-liquid.example.toml](desktop-audio-liquid.example.toml)

- Main work: `audio-liquid-orbit.post.glsl`.
- Tune first: lower the liquid pass strength if the base shader loses shape;
  raise it if the motion is too subtle on sparse tracks.
- Daily-use risk: medium. Usually readable, but can get busy on bright shaders.

### Deep Space

File: [desktop-audio-deep-space.example.toml](desktop-audio-deep-space.example.toml)

- Main work: `audio-feedback-tunnel.post.glsl` for depth, then
  `audio-liquid-orbit.post.glsl` for drift.
- Tune first: lower tunnel strength if the scene collapses inward; lower liquid
  strength if the final image swims too much.
- Daily-use risk: medium-high. Good for ambient or melodic tracks, less subtle
  than `liquid`.

### Prism Rift

File: [desktop-audio-prism-rift.example.toml](desktop-audio-prism-rift.example.toml)

- Main work: `audio-prism-rift.post.glsl`, with `shock_ring` before it and
  `impact_flash` after it.
- Tune first: lower prism strength if edges split too hard; lower
  `impact_flash` if beat accents wash out the shader.
- Daily-use risk: high. Treat this as a visualizer preset, not a quiet desktop
  preset.

### Feedback Tunnel

File: [desktop-audio-feedback-tunnel.example.toml](desktop-audio-feedback-tunnel.example.toml)

- Main work: `audio-feedback-tunnel.post.glsl`.
- Tune first: lower tunnel strength if the center pulls too aggressively; lower
  `time_strength` if the base shader and tunnel both accelerate too much.
- Daily-use risk: high. Best with bass-forward tracks or when the wallpaper is
  the focus.

## Listening Notes Template

```text
Preset:
Track/source:
Display:
Too subtle / good / too intense:
Best moment:
Issue noticed:
First knob to change:
```
