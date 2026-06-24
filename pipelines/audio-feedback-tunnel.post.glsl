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

mat2 rotate2d(float angle) {
    float s = sin(angle);
    float c = cos(angle);
    return mat2(c, -s, s, c);
}

vec3 sampleTunnel(vec2 centered, float zoom, float rotation, vec2 drift) {
    vec2 p = rotate2d(rotation) * (centered * zoom) + 0.5 + drift;
    return texture(uInputTexture, clamp(p, 0.0, 1.0)).rgb;
}

void main() {
    vec2 centered = vUv - 0.5;
    float radius = length(centered);
    float angle = atan(centered.y, centered.x);
    float bass = uAudioBands.y;
    float mid = uAudioBands.z;
    float beat = uAudioState.x;
    float impact = uAudioVisualizer.x;
    float energy = uAudioVisualizer.y;
    float drive = uAudioVisualizer.z;
    float brightness = uAudioVisualizer.w;

    float pull = (0.028 + bass * 0.095 + impact * 0.045) * uStrength;
    float spin = (0.08 + drive * 0.28 + beat * 0.16) * uStrength;
    vec2 direction = normalize(centered + vec2(0.0001));
    vec2 drift = direction * sin(radius * 44.0 - uTime * (2.8 + energy * 4.2)) * pull;

    vec3 color = texture(uInputTexture, vUv).rgb * 0.48;
    color += sampleTunnel(centered, 0.90 - pull * 0.40, spin + angle * 0.010, drift * 0.35) * 0.26;
    color += sampleTunnel(centered, 0.78 - pull * 0.65, spin * 1.7, drift * 0.70) * 0.17;
    color += sampleTunnel(centered, 0.64 - pull * 0.80, spin * 2.4, drift * 1.05) * 0.11;
    color += sampleTunnel(centered, 0.50 - pull * 0.95, spin * 3.2, drift * 1.35) * 0.07;

    float lane = sin(log(radius + 0.025) * 8.0 - uTime * (2.4 + drive * 3.0) + angle * 5.0);
    float tunnel = smoothstep(-0.20, 0.85, lane) * (1.0 - smoothstep(0.05, 0.80, radius));
    float flash = clamp(impact * 0.7 + beat * 0.45 + brightness * 0.25, 0.0, 1.35);

    color = ((color - 0.5) * (1.0 + flash * 0.45 + mid * 0.16)) + 0.5;
    color += vec3(0.03, 0.10, 0.22) * tunnel * (0.25 + energy) * uStrength;
    color += vec3(0.18, 0.08, 0.02) * flash * (1.0 - smoothstep(0.15, 0.90, radius));
    fragColor = vec4(max(color, vec3(0.0)), 1.0);
}
