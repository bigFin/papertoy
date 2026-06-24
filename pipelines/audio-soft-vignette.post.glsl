#version 330 core

in vec2 vUv;
out vec4 fragColor;

uniform sampler2D uInputTexture;
uniform vec2 uResolution;
uniform vec4 uAudioBands;
uniform vec4 uAudioState;
uniform vec4 uAudioVisualizer;
uniform float uTime;
uniform float uStrength;

void main() {
    vec2 centered = vUv - 0.5;
    float radius = length(centered);
    float impact = uAudioVisualizer.x;
    float energy = uAudioVisualizer.y;
    float brightness = uAudioVisualizer.w;
    float wave = sin((centered.x - centered.y) * 28.0 + uTime * 2.0) * impact * 0.006 * uStrength;
    vec3 color = texture(uInputTexture, clamp(vUv + vec2(wave, -wave), 0.0, 1.0)).rgb;
    float vignette = 1.0 - smoothstep(0.35, 0.82, radius);
    color = mix(color * (0.92 + vignette * 0.08), color, 0.55 + brightness * 0.18);
    color += vec3(0.03, 0.02, 0.01) * energy * vignette * uStrength;
    fragColor = vec4(max(color, vec3(0.0)), 1.0);
}
