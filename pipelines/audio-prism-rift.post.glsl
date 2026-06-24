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

vec2 foldPrism(vec2 p, float sides) {
    float angle = atan(p.y, p.x);
    float radius = length(p);
    float sector = 6.28318530718 / sides;
    angle = mod(angle + sector * 0.5, sector) - sector * 0.5;
    return vec2(cos(angle), sin(angle)) * radius;
}

void main() {
    vec2 centered = vUv - 0.5;
    float radius = length(centered);
    float angle = atan(centered.y, centered.x);
    float bass = uAudioBands.y;
    float mid = uAudioBands.z;
    float treble = uAudioBands.w;
    float beat = uAudioState.x;
    float impact = uAudioVisualizer.x;
    float energy = uAudioVisualizer.y;
    float drive = uAudioVisualizer.z;
    float brightness = uAudioVisualizer.w;

    float sides = mix(5.0, 9.0, clamp(treble + beat * 0.4, 0.0, 1.0));
    vec2 folded = foldPrism(centered, sides);
    float split = (0.003 + impact * 0.019 + drive * 0.007) * uStrength;
    float pulse = sin(radius * 90.0 - uTime * (5.0 + energy * 4.0) + angle * 3.0);
    vec2 radial = normalize(folded + vec2(0.0001));
    vec2 tangent = vec2(-radial.y, radial.x);
    vec2 uv = folded + 0.5 + radial * pulse * (0.003 + bass * 0.010) * uStrength;

    vec3 color;
    color.r = texture(uInputTexture, clamp(uv + tangent * split, 0.0, 1.0)).r;
    color.g = texture(uInputTexture, clamp(uv + radial * split * 0.35, 0.0, 1.0)).g;
    color.b = texture(uInputTexture, clamp(uv - tangent * split, 0.0, 1.0)).b;

    float ring = 1.0 - smoothstep(0.018, 0.10, abs(radius - (0.22 + fract(uTime * 0.16 + impact * 0.18) * 0.55)));
    float flash = clamp(impact * 0.6 + beat * 0.5 + brightness * 0.25, 0.0, 1.4);
    color = ((color - 0.5) * (1.0 + flash * 0.25 + mid * 0.08)) + 0.5;
    color += vec3(0.10, 0.04, 0.16) * ring * flash * uStrength;
    color += vec3(0.02, 0.05, 0.10) * energy * (1.0 - smoothstep(0.10, 0.92, radius));
    fragColor = vec4(max(color, vec3(0.0)), 1.0);
}
