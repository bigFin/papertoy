# Audio-Reactive Feature

## Status

Paper Toy now supports audio-reactive shader inputs and optional audio-driven
time modulation.

Current implementation goals:

- capture live audio from PipeWire
- expose generic audio uniforms to shaders
- support both sink-monitor capture and microphone/source capture
- provide an opt-in compatibility mode for unmodified `iTime`-driven shaders

This is intentionally still a feature branch feature. The current behavior is
useful and fun, but not yet the final shape of a polished visualizer system.

## Current CLI

### Enable Audio Inputs

```console
papertoy --audio-reactive SHADER_FILE
```

This captures audio and exposes shader uniforms:

- `iAudioLevel`
- `iAudioBass`
- `iAudioMid`
- `iAudioTreble`
- `iAudioBeat`
- `iAudioActive`
- `iAudioImpact`
- `iAudioEnergy`
- `iAudioDrive`
- `iAudioBrightness`

### Capture Mode

```console
papertoy --audio-reactive --audio-capture sink SHADER_FILE
papertoy --audio-reactive --audio-capture source SHADER_FILE
```

Capture modes:

- `sink`: capture the output of the selected/default playback device
- `source`: capture the selected/default source, such as a microphone

The default is `sink`.

### Explicit Target

```console
papertoy --audio-reactive --audio-target <node-name-or-serial> SHADER_FILE
```

This overrides automatic device selection.

### Audio-Modulated Time

```console
papertoy --audio-reactive --audio-time-reactive SHADER_FILE
papertoy --audio-reactive --audio-time-reactive --audio-time-strength 2.5 SHADER_FILE
```

This mode is intended as a compatibility layer for shaders that only use
`iTime`. It is fun and useful, but it should not be treated as the final
general-purpose visualizer mapping.

## Current Behavior

### Device Selection

When no explicit `--audio-target` is provided:

- `--audio-capture sink` resolves `@DEFAULT_AUDIO_SINK@`
- `--audio-capture source` resolves `@DEFAULT_AUDIO_SOURCE@`

The selected target is printed to the terminal when the backend starts or
rebinds.

The implementation also periodically re-resolves the default device so it can
recover from backend death or default-device changes.

### Analyzer Outputs

There are two layers of outputs:

Raw-ish inputs:

- level
- bass
- mid
- treble
- beat

Derived visualizer signals:

- impact
- energy
- drive
- brightness

The derived signals are meant to be closer to what visuals actually need than
raw audio band values.

## Practical Notes

- Audio-reactive uniforms are the main feature.
- Audio-time-reactive mode is a secondary compatibility mode.
- Sink-monitor capture is the intended default for music-reactive visuals.
- Source mode is still valuable as a live-performance or mic-reactive mode.

## Known Limitations

- Generic time warping is fun but not a canonical visualizer mapping.
- Unmodified shaders will only react as much as time modulation allows.
- The strongest results will likely come from shaders explicitly using the new
  audio uniforms.
- Runtime behavior has been tested through manual iteration, but this branch
  still needs broader real-world tuning.

## Recommended Next Steps

### High Priority

- Add a debug mode that prints or overlays live values such as target, impact,
  beat, drive, and brightness.
- Add non-time-based generic modulation paths driven by derived signals.
- Tune smoothing, decay, and weighting for the derived visualizer signals.

### Likely Direction

- Treat `impact`, `energy`, `drive`, and `brightness` as the primary generic
  visualizer vocabulary.
- Use those signals for visible parameters such as zoom, displacement, glow,
  contrast, palette intensity, or camera motion.
- Keep time warping as an optional special mode rather than the main mapping.

### Explicitly Out Of Scope For This Branch Direction

- Adding a library of bundled example shaders to `src`
- Treating one shader-specific mapping as the universal solution
- Overfitting the analyzer to a single track or single visual style

## Suggested Review Units

This feature is currently split into small commits that can be reviewed or
rebased independently:

- audio-reactive shader uniforms and PipeWire capture
- derived visualizer signals
- sink-monitor capture fix
- explicit capture mode selection
