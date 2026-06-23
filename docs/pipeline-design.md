# Pipeline Design

## Goal

Replace the current single-shader runtime model with a real composable shader
pipeline system that can be configured from TOML.

This is the long-term direction for audio-reactive visuals. The current
audio-reactive branch work has proven that:

- system audio capture is viable
- audio-derived signals are useful
- generic inline modulation inside a Shadertoy wrapper is not enough

The next meaningful step is a proper render pipeline that can chain passes
together and feed common uniforms, textures, and audio data into each pass.

## Why A Pipeline System

The current single-pass model has hard limits:

- one fragment shader owns the whole frame
- generic effects must be hacked into the shader wrapper
- there is no natural place for post-processing
- reusable audio-reactive effects cannot be composed cleanly

A pipeline system fixes this by making effects first-class passes rather than
special cases in the launcher or shader wrapper.

## Product Direction

Paper Toy should support two usage modes:

### Legacy Mode

Run a single shader directly:

```console
papertoy shader.glsl
```

This should remain supported. Internally, it becomes an implicit pipeline with
one base pass and no post-process passes.

### Pipeline Mode

Run a TOML-defined pipeline:

```console
papertoy --pipeline desktop-audio.toml
```

This becomes the primary path for advanced visuals, audio-reactive presets, and
reusable post-processing effects.

## Requirements

### Functional

- render a base shader to an offscreen target
- support zero or more subsequent passes
- allow passes to sample outputs of prior passes
- expose audio-derived uniforms to every pass
- support both file-based shaders and built-in effects
- preserve current single-shader mode as a compatibility path

### Non-Functional

- low overhead for the default case
- deterministic pass ordering
- explicit resource ownership and lifetime
- easy-to-debug runtime behavior
- future room for feedback effects and multi-buffer pipelines

## Configuration Model

TOML is a reasonable fit because:

- it is readable and hand-editable
- it works well for ordered arrays of pass definitions
- it is straightforward to extend with nested parameter tables
- it avoids inventing a custom config format

## Proposed TOML Shape

### Minimal

```toml
[[passes]]
kind = "base"
path = "${PAPERTOY_DEFAULT_SHADER}"

[[passes]]
kind = "postprocess"
effect = "pulse_zoom"
strength = 1.35
```

### Audio-Reactive Desktop Preset

```toml
[pipeline]
base = "/storage/SyncBox/shaders/stochastic-asym-quads-everforest-dark-medium.glsl"

[audio]
enabled = true
capture = "sink"
target = "auto"

[[passes]]
kind = "postprocess"
effect = "pulse_zoom"
strength = 0.8

[[passes]]
kind = "postprocess"
effect = "glow_grade"
strength = 0.5
```

### Explicit File-Based Post Passes

```toml
[pipeline]
base = "/storage/SyncBox/shaders/base.glsl"

[audio]
enabled = true
capture = "sink"

[[passes]]
name = "pulse"
kind = "shader"
path = "/storage/SyncBox/passes/pulse_zoom.glsl"

[passes.params]
strength = 1.2

[[passes]]
name = "grade"
kind = "shader"
path = "/storage/SyncBox/passes/glow_grade.glsl"

[passes.params]
strength = 0.6
```

## Pass Model

Each pass should have:

- a kind
- a shader source or built-in effect identifier
- a set of inputs
- a set of parameters
- an output target

Initial pass kinds:

- `base`
- `postprocess`

Likely future pass kinds:

- `feedback`
- `blend`
- `mask`

## Resource Model

Each pass should be able to read:

- the previous pass output
- named intermediate textures
- common uniforms
- common audio uniforms

The runtime should manage:

- framebuffer creation
- texture allocation
- pass output reuse where possible
- resize propagation

## Audio Model

Audio should not be special-cased per pass.

Instead, every pass should receive the same common audio context:

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

This keeps pass authorship simple and predictable.

## Built-In Effects

The pipeline system should support built-in post-process effects.

Why:

- most users will not want to author a multi-pass shader stack from scratch
- built-ins provide a stable vocabulary for presets
- they make a good default desktop background possible

Implemented first built-ins:

- `pulse_zoom`
- `glow_grade`
- `heat_shift`
- `impact_flash`
- `shock_ring`

Reasonable future built-ins:

- `drift_warp`

These should eventually be implemented as normal passes, not hardcoded branches
inside the main renderer.

## Backward Compatibility

Current CLI:

```console
papertoy shader.glsl
```

Compatibility behavior:

- if `--pipeline` is not used, build an implicit pipeline with a single base pass
- existing audio flags continue to work
- internally, legacy mode should reuse the same pipeline runner

This avoids maintaining two rendering architectures long-term.

## Suggested Runtime Architecture

### Core Types

- `PipelineConfig`
- `AudioConfig`
- `PassConfig`
- `effects.PostProcessEffect`
- `PipelineRunner`
- `postprocess.RenderTarget`
- `postprocess.PostProcessProgram`
- `postprocess.PostProcessPass`

### Responsibilities

`PipelineConfig`

- parsed TOML representation
- validation
- migration/defaulting

`effects.PostProcessEffect`

- built-in effect identifiers
- config names such as `pulse_zoom`
- shader integer values for postprocess dispatch

`PipelineRunner`

- compile passes
- allocate render targets
- execute pass sequence every frame
- update common uniforms

`postprocess.PostProcessProgram`

- shared built-in postprocess shader program
- uniform locations common to all postprocess passes
- one compiled program reused across the ordered postprocess chain

`postprocess.PostProcessPass`

- selected built-in postprocess effect
- per-pass strength
- per-pass timing state
- current output resolution

## Implementation Phases

### Phase 1

Introduce the internal pipeline runner while keeping user-facing behavior
unchanged.

Status: implemented.

Deliverables:

- implicit single-pass pipeline
- offscreen render target abstraction
- base pass rendering through the pipeline runner

### Phase 2

Add one explicit post-process pass.

Status: implemented.

Deliverables:

- render base shader to texture
- render one fullscreen post-process pass that samples that texture
- pass common audio uniforms into both passes

### Phase 3

Add multi-pass chaining.

Status: implemented with a bounded linear chain.

Deliverables:

- ordered pass list
- named outputs or simple previous-pass chaining
- resize-safe intermediate textures

### Phase 4

Add TOML configuration.

Status: implemented for one base pass plus up to four built-in postprocess
passes.

Deliverables:

- `--pipeline <file>`
- parser and validation
- legacy mode mapped onto the same internal representation

### Phase 5

Add built-in effect library and presets.

Status: implemented for the first built-in set and desktop example presets.

Deliverables:

- built-in post-process effects
- desktop-friendly presets
- branch-local experimentation becomes reproducible config

The current branch implements the first bounded built-in set, sample desktop
pipelines, and a shared postprocess shader program. Later work can add more
effects without changing the linear pipeline contract.

## Open Design Questions

- Should pass parameters be fully dynamic uniforms or partially static config?
- How should textures from previous passes be named and referenced?
- Do built-in effects live as GLSL files, generated shaders, or Zig-side templates?
- Should feedback passes be part of the initial config schema or added later?
- How much validation should happen at parse time versus shader compile time?

## Recommended Near-Term Scope

Do not start with full arbitrary graph execution.

Start with:

- linear ordered pipeline
- one base pass
- zero or more post-process passes
- previous-pass texture as the standard input

This is still “full gold” in direction, but it avoids inventing a more general
graph system before the actual needs are proven.

## Out Of Scope

- bundling a large shader library inside `src`
- committing to one universal desktop preset before the pass system exists
- inventing a custom DSL for pass configuration
- trying to solve every future pass type in the first implementation

## Current Branch Status

Implemented in this branch:

- audio-reactive shader uniforms and PipeWire capture
- derived audio signals for impact, energy, drive, and brightness
- direct shader mode mapped through the same `PipelineRunner`
- TOML pipeline files
- one base pass plus up to four ordered built-in postprocess passes
- ping-pong render targets for linear postprocess chaining
- shared compiled postprocess shader program per output pipeline
- built-in effects: `pulse_zoom`, `glow_grade`, `heat_shift`,
  `impact_flash`, and `shock_ring`
- example pipelines under `pipelines/`, including calmer and more intense
  audio-reactive presets

Recommended next work:

- consider simple per-effect parameter metadata before adding many more effects
- decide whether file-based postprocess shaders belong in this branch or a
  later branch
- update screenshots or recordings once the branch is ready to publish
