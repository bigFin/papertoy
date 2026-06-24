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

void main() {
    vec2 centered = vUv - 0.5;
    float radius = length(centered);
    float angle = atan(centered.y, centered.x);
    float bass = uAudioBands.y;
    float treble = uAudioBands.w;
    float beat = uAudioState.x;
    float impact = uAudioVisualizer.x;
    float energy = uAudioVisualizer.y;
    float drive = uAudioVisualizer.z;
    float brightness = uAudioVisualizer.w;

    float orbit = sin(angle * 4.0 + uTime * (0.75 + energy * 1.3)) * (0.004 + impact * 0.016);
    float ripple = sin(radius * 62.0 - uTime * (3.0 + drive * 5.0)) * (0.002 + bass * 0.008);
    float twist = (0.10 + radius * 0.70) * (impact + energy * 0.45) * uStrength;
    vec2 warped = rotate2d(twist) * centered;
    vec2 uv = warped + 0.5 + normalize(centered + vec2(0.0001)) * (orbit + ripple) * uStrength;

    vec2 tangent = vec2(-centered.y, centered.x);
    vec2 chroma = tangent * (0.0015 + treble * 0.007 + beat * 0.004) * uStrength;
    vec3 color;
    color.r = texture(uInputTexture, clamp(uv + chroma, 0.0, 1.0)).r;
    color.g = texture(uInputTexture, clamp(uv, 0.0, 1.0)).g;
    color.b = texture(uInputTexture, clamp(uv - chroma, 0.0, 1.0)).b;

    float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
    color = mix(vec3(luma), color, 1.0 + brightness * 0.16 + energy * 0.08);
    color = ((color - 0.5) * (1.0 + impact * 0.16 + drive * 0.08)) + 0.5;
    color += vec3(0.015, 0.04, 0.07) * energy * (1.0 - smoothstep(0.22, 0.90, radius));
    fragColor = vec4(max(color, vec3(0.0)), 1.0);
}
