# Pipeline Presets

Tracked presets use `PAPERTOY_DEFAULT_SHADER` so local shader paths do not need
to be committed.

```console
export PAPERTOY_DEFAULT_SHADER=/storage/SyncBox/shaders/stochastic-asym-quads-everforest-dark-medium.glsl
papertoy --pipeline pipelines/desktop-audio-liquid.example.toml
```

| Pipeline | Intensity | Feel | Good use |
| --- | --- | --- | --- |
| [desktop-static.example.toml](desktop-static.example.toml) | none | base shader only | non-audio wallpaper |
| [desktop-audio.example.toml](desktop-audio.example.toml) | low | audio uniforms and time modulation only | shader-authored audio reactions |
| [desktop-audio-soft.example.toml](desktop-audio-soft.example.toml) | low | gentle glow and heat | daily desktop use |
| [desktop-audio-post.example.toml](desktop-audio-post.example.toml) | medium | built-in multi-pass polish | broad audio-reactive default |
| [desktop-audio-custom-post.example.toml](desktop-audio-custom-post.example.toml) | medium | soft vignette and pulse | custom-pass sanity check |
| [desktop-audio-liquid.example.toml](desktop-audio-liquid.example.toml) | medium | orbital liquid warp | smoother music-reactive motion |
| [desktop-audio-deep-space.example.toml](desktop-audio-deep-space.example.toml) | medium-high | tunnel depth and liquid drift | spacious ambient or melodic tracks |
| [desktop-audio-shock.example.toml](desktop-audio-shock.example.toml) | high | shock rings and flashes | intense beat accents |
| [desktop-audio-prism-rift.example.toml](desktop-audio-prism-rift.example.toml) | high | folded prism and chromatic split | aggressive visualizer moments |
| [desktop-audio-feedback-tunnel.example.toml](desktop-audio-feedback-tunnel.example.toml) | high | recursive-looking zoom tunnel | trippy bass-forward tracks |

## Quick Commands

```console
papertoy --pipeline pipelines/desktop-audio-soft.example.toml
papertoy --pipeline pipelines/desktop-audio-liquid.example.toml
papertoy --pipeline pipelines/desktop-audio-deep-space.example.toml
papertoy --pipeline pipelines/desktop-audio-prism-rift.example.toml
papertoy --pipeline pipelines/desktop-audio-feedback-tunnel.example.toml
```

Add `--audio-overlay` while tuning to see the analyzer values that drive each
pass.

For per-preset tuning notes, see [TUNING.md](TUNING.md).
