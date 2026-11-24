// Tidelines — an original Papertoy demo. SPDX-License-Identifier: GPL-3.0-only
void mainImage(out vec4 color, in vec2 pixel) {
    vec2 p = (pixel - 0.5 * iResolution.xy) / iResolution.y;
    float t = iTime * 0.25;
    float swell = sin(p.x * 3.0 + t) * (0.10 + 0.11 * iAudioBass);
    float tide = p.y - swell - 0.05 * sin(p.x * 6.0 - t);
    float depth = exp(-3.0 * abs(tide));

    // Closely spaced contours form a current. High frequencies lift the crests.
    float phase = tide * 17.0 + 0.55 * sin(p.x * 4.0 + tide * 3.0 - t) - t;
    float dist = abs(fract(phase) - 0.5);
    float line = 1.0 - smoothstep(0.025, 0.075 + fwidth(phase), dist);
    vec3 deep = vec3(0.025, 0.055, 0.12);
    vec3 shallows = mix(vec3(0.03, 0.32, 0.36), vec3(0.70, 0.28, 0.08), iAudioEnergy);
    vec3 foam = mix(vec3(0.22, 0.70, 0.66), vec3(1.0, 0.86, 0.51), iAudioBrightness);
    color = vec4(deep + depth * (shallows + foam * line * (0.4 + 0.6 * iAudioLevel)), 1.0);
}
