const std = @import("std");
const Allocator = std.mem.Allocator;

const audio = @import("audio.zig");
const AudioSnapshot = audio.Snapshot;
const AudioUniformPayload = audio.UniformPayload;
const effects = @import("effects.zig");
const gl = @import("zgl");
const shader = @import("shader.zig");

const glb = gl.binding;

const PostProcessEffect = effects.PostProcessEffect;

pub const RenderTarget = struct {
    framebuffer: gl.Framebuffer,
    texture: gl.Texture,
    resolution: shader.Resolution,

    pub fn init(resolution: shader.Resolution) !RenderTarget {
        const texture = gl.Texture.gen();
        errdefer texture.delete();
        configureTexture2D(texture, resolution);

        const framebuffer = gl.Framebuffer.gen();
        errdefer framebuffer.delete();
        framebuffer.bind(.buffer);
        framebuffer.texture2D(.buffer, .color0, .@"2d", texture, 0);

        const status = gl.checkFramebufferStatus(.buffer);
        if (status != @as(@TypeOf(status), .complete)) return error.FramebufferIncomplete;

        gl.bindFramebuffer(.invalid, .buffer);

        return .{
            .framebuffer = framebuffer,
            .texture = texture,
            .resolution = resolution,
        };
    }

    pub fn deinit(self: *RenderTarget) void {
        self.framebuffer.delete();
        self.texture.delete();
    }

    pub fn bind(self: *RenderTarget) void {
        self.framebuffer.bind(.buffer);
    }

    pub fn resize(self: *RenderTarget, resolution: shader.Resolution) !void {
        const new_target = try init(resolution);
        self.deinit();
        self.* = new_target;
    }
};

fn configureTexture2D(texture: gl.Texture, resolution: shader.Resolution) void {
    bindTexture2D(texture);
    glb.texImage2D(
        glb.TEXTURE_2D,
        0,
        glb.RGBA8,
        @intCast(resolution.width),
        @intCast(resolution.height),
        0,
        glb.RGBA,
        glb.UNSIGNED_BYTE,
        null,
    );
    glb.texParameteri(glb.TEXTURE_2D, glb.TEXTURE_MIN_FILTER, glb.LINEAR);
    glb.texParameteri(glb.TEXTURE_2D, glb.TEXTURE_MAG_FILTER, glb.LINEAR);
    glb.texParameteri(glb.TEXTURE_2D, glb.TEXTURE_WRAP_S, glb.CLAMP_TO_EDGE);
    glb.texParameteri(glb.TEXTURE_2D, glb.TEXTURE_WRAP_T, glb.CLAMP_TO_EDGE);
}

fn bindTexture2D(texture: gl.Texture) void {
    glb.bindTexture(glb.TEXTURE_2D, @intFromEnum(texture));
}

fn setUniform4f(location: ?u32, values: [4]f32) void {
    gl.uniform4f(location, values[0], values[1], values[2], values[3]);
}

const POST_PROCESS_VERTEX_SOURCE =
    \\#version 330 core
    \\
    \\layout(location = 0) in vec2 position;
    \\out vec2 vUv;
    \\
    \\void main() {
    \\    vUv = position * 0.5 + 0.5;
    \\    gl_Position = vec4(position, 0.0, 1.0);
    \\}
;

const POST_PROCESS_FRAGMENT_SOURCE =
    \\#version 330 core
    \\
    \\in vec2 vUv;
    \\out vec4 fragColor;
    \\
    \\uniform sampler2D uInputTexture;
    \\uniform vec2 uResolution;
    \\uniform vec4 uAudioBands;
    \\uniform vec4 uAudioState;
    \\uniform vec4 uAudioVisualizer;
    \\uniform float uTime;
    \\uniform int uEffect;
    \\
    \\vec3 applyPulseZoom(vec2 uv) {
    \\    vec2 centered = uv - 0.5;
    \\    float impact = uAudioVisualizer.x;
    \\    float energy = uAudioVisualizer.y;
    \\    float brightness = uAudioVisualizer.w;
    \\    float zoom = 1.0 - (impact * 0.07) + (energy * 0.025);
    \\    vec2 sampleUv = centered * zoom + 0.5;
    \\    vec2 swirl = vec2(
    \\        sin(uTime * 1.6 + centered.y * 11.0),
    \\        cos(uTime * 1.3 + centered.x * 11.0)
    \\    ) * (impact * 0.01);
    \\    vec3 color = texture(uInputTexture, clamp(sampleUv + swirl, 0.0, 1.0)).rgb;
    \\    float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
    \\    color = mix(vec3(luma), color, 1.0 + brightness * 0.18);
    \\    color = ((color - 0.5) * (1.0 + impact * 0.35 + energy * 0.16)) + 0.5;
    \\    color += vec3(0.05, 0.025, 0.01) * impact;
    \\    return max(color, vec3(0.0));
    \\}
    \\
    \\vec3 applyGlowGrade(vec2 uv) {
    \\    vec2 texel = 1.0 / max(uResolution, vec2(1.0));
    \\    float energy = uAudioVisualizer.y;
    \\    float brightness = uAudioVisualizer.w;
    \\    vec3 color = texture(uInputTexture, uv).rgb;
    \\    vec3 glow = texture(uInputTexture, clamp(uv + texel * vec2(2.0, 0.0), 0.0, 1.0)).rgb;
    \\    glow += texture(uInputTexture, clamp(uv + texel * vec2(-2.0, 0.0), 0.0, 1.0)).rgb;
    \\    glow += texture(uInputTexture, clamp(uv + texel * vec2(0.0, 2.0), 0.0, 1.0)).rgb;
    \\    glow += texture(uInputTexture, clamp(uv + texel * vec2(0.0, -2.0), 0.0, 1.0)).rgb;
    \\    glow *= 0.25;
    \\    float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
    \\    vec3 graded = mix(vec3(luma), color, 1.0 + brightness * 0.22);
    \\    graded = ((graded - 0.5) * (1.0 + energy * 0.16)) + 0.5;
    \\    graded += glow * (energy * 0.10 + brightness * 0.06);
    \\    return max(graded, vec3(0.0));
    \\}
    \\
    \\vec3 applyHeatShift(vec2 uv) {
    \\    vec2 centered = uv - 0.5;
    \\    float bass = uAudioBands.y;
    \\    float impact = uAudioVisualizer.x;
    \\    float energy = uAudioVisualizer.y;
    \\    float wave = sin((centered.y * 18.0) + (uTime * 2.2)) * (bass * 0.002 + impact * 0.006);
    \\    vec2 offset = vec2(wave, 0.0);
    \\    float red = texture(uInputTexture, clamp(uv + offset, 0.0, 1.0)).r;
    \\    float green = texture(uInputTexture, uv).g;
    \\    float blue = texture(uInputTexture, clamp(uv - offset, 0.0, 1.0)).b;
    \\    vec3 color = vec3(red, green, blue);
    \\    vec3 warmth = vec3(1.0 + impact * 0.08, 1.0 + energy * 0.03, 1.0 - bass * 0.035);
    \\    color *= warmth;
    \\    color += vec3(0.08, 0.025, -0.02) * impact;
    \\    return max(color, vec3(0.0));
    \\}
    \\
    \\vec3 applyImpactFlash(vec2 uv) {
    \\    vec2 centered = uv - 0.5;
    \\    float radius = length(centered);
    \\    float beat = uAudioState.x;
    \\    float impact = uAudioVisualizer.x;
    \\    float brightness = uAudioVisualizer.w;
    \\    vec3 color = texture(uInputTexture, uv).rgb;
    \\    float flash = clamp((impact * 0.75) + (beat * 0.55), 0.0, 1.5);
    \\    float ring = 1.0 - smoothstep(0.18, 0.46, abs(radius - (0.22 + flash * 0.10)));
    \\    float vignette = 1.0 - smoothstep(0.20, 0.82, radius);
    \\    color = mix(color, vec3(1.0, 0.92, 0.78), flash * (0.10 + ring * 0.20));
    \\    color += vec3(0.22, 0.12, 0.04) * flash * vignette;
    \\    color = ((color - 0.5) * (1.0 + flash * 0.22 + brightness * 0.18)) + 0.5;
    \\    return max(color, vec3(0.0));
    \\}
    \\
    \\vec3 applyShockRing(vec2 uv) {
    \\    vec2 centered = uv - 0.5;
    \\    float radius = length(centered);
    \\    float angle = atan(centered.y, centered.x);
    \\    float beat = uAudioState.x;
    \\    float impact = uAudioVisualizer.x;
    \\    float drive = uAudioVisualizer.z;
    \\    float brightness = uAudioVisualizer.w;
    \\    float phase = fract(uTime * 0.12 + impact * 0.18 + beat * 0.12);
    \\    float ring_radius = mix(0.12, 0.78, phase);
    \\    float ring_width = 0.035 + impact * 0.05;
    \\    float ring_activity = clamp(beat + impact + drive * 0.5 + brightness * 0.25, 0.0, 1.0);
    \\    float ring = (1.0 - smoothstep(ring_width, ring_width + 0.20, abs(radius - ring_radius))) * ring_activity;
    \\    float ripple = sin((radius * 68.0) - (uTime * 7.0) + angle * 4.0) * ring;
    \\    vec2 direction = normalize(centered + vec2(0.0001));
    \\    vec2 warp = direction * (ripple * (0.006 + impact * 0.018));
    \\    vec3 color;
    \\    color.r = texture(uInputTexture, clamp(uv + warp * 1.4, 0.0, 1.0)).r;
    \\    color.g = texture(uInputTexture, clamp(uv - warp * 0.6, 0.0, 1.0)).g;
    \\    color.b = texture(uInputTexture, clamp(uv + vec2(-warp.y, warp.x), 0.0, 1.0)).b;
    \\    color = mix(color, vec3(0.98, 0.72, 0.38), ring * impact * 0.24);
    \\    color = ((color - 0.5) * (1.0 + ring * (0.35 + drive * 0.25))) + 0.5;
    \\    color += vec3(0.16, 0.06, 0.22) * ring * brightness;
    \\    return max(color, vec3(0.0));
    \\}
    \\
    \\void main() {
    \\    float alpha = texture(uInputTexture, vUv).a;
    \\    if (uEffect == 0) {
    \\        fragColor = vec4(applyPulseZoom(vUv), alpha);
    \\    } else if (uEffect == 1) {
    \\        fragColor = vec4(applyGlowGrade(vUv), alpha);
    \\    } else if (uEffect == 2) {
    \\        fragColor = vec4(applyHeatShift(vUv), alpha);
    \\    } else if (uEffect == 3) {
    \\        fragColor = vec4(applyImpactFlash(vUv), alpha);
    \\    } else if (uEffect == 4) {
    \\        fragColor = vec4(applyShockRing(vUv), alpha);
    \\    } else {
    \\        fragColor = texture(uInputTexture, vUv);
    \\    }
    \\}
;

pub const PostProcessProgram = struct {
    program: gl.Program,
    input_texture_uniform: ?u32,
    resolution_uniform: ?u32,
    audio_bands_uniform: ?u32,
    audio_state_uniform: ?u32,
    audio_visualizer_uniform: ?u32,
    time_uniform: ?u32,
    effect_uniform: ?u32,
    strength_uniform: ?u32,

    pub fn init(allocator: Allocator) !PostProcessProgram {
        return initWithFragmentSource(allocator, POST_PROCESS_FRAGMENT_SOURCE, "built-in");
    }

    pub fn initCustom(allocator: Allocator, source: []const u8, label: []const u8) !PostProcessProgram {
        return initWithFragmentSource(allocator, source, label);
    }

    fn initWithFragmentSource(allocator: Allocator, source: []const u8, label: []const u8) !PostProcessProgram {
        const vert = gl.Shader.create(.vertex);
        defer vert.delete();
        vert.source(1, &.{POST_PROCESS_VERTEX_SOURCE[0..]});
        vert.compile();

        const frag = gl.Shader.create(.fragment);
        defer frag.delete();
        frag.source(1, &.{source});
        frag.compile();

        const frag_compiled = frag.get(.compile_status) == gl.binding.TRUE;
        if (!frag_compiled) {
            const log = try frag.getCompileLog(allocator);
            defer allocator.free(log);
            std.log.err("failed to compile {s} post-process shader:\n{s}", .{ label, log });
            return error.InvalidPipelineValue;
        }

        const program = gl.Program.create();
        errdefer program.delete();
        program.attach(vert);
        program.attach(frag);
        program.link();
        if (program.get(.link_status) != gl.binding.TRUE) {
            const log = try program.getCompileLog(allocator);
            defer allocator.free(log);
            std.log.err("failed to link {s} post-process shader:\n{s}", .{ label, log });
            return error.InvalidPipelineValue;
        }

        return .{
            .program = program,
            .input_texture_uniform = program.uniformLocation("uInputTexture"),
            .resolution_uniform = program.uniformLocation("uResolution"),
            .audio_bands_uniform = program.uniformLocation("uAudioBands"),
            .audio_state_uniform = program.uniformLocation("uAudioState"),
            .audio_visualizer_uniform = program.uniformLocation("uAudioVisualizer"),
            .time_uniform = program.uniformLocation("uTime"),
            .effect_uniform = program.uniformLocation("uEffect"),
            .strength_uniform = program.uniformLocation("uStrength"),
        };
    }

    pub fn deinit(self: *PostProcessProgram, allocator: Allocator) void {
        _ = allocator;
        self.program.delete();
    }
};

pub const PostProcessPass = struct {
    resolution: shader.Resolution,
    effect: ?PostProcessEffect = null,
    custom_program: ?PostProcessProgram = null,
    strength: f32 = 1.0,
    started: bool = false,
    first_rendered: std.time.Instant = undefined,

    pub fn init(resolution: shader.Resolution, effect: PostProcessEffect) PostProcessPass {
        return .{
            .resolution = resolution,
            .effect = effect,
        };
    }

    pub fn initCustom(allocator: Allocator, resolution: shader.Resolution, source: []const u8, label: []const u8) !PostProcessPass {
        return .{
            .resolution = resolution,
            .custom_program = try PostProcessProgram.initCustom(allocator, source, label),
        };
    }

    pub fn deinit(self: *PostProcessPass, allocator: Allocator) void {
        if (self.custom_program) |*program| {
            program.deinit(allocator);
            self.custom_program = null;
        }
    }

    pub fn render(self: *PostProcessPass, shared_program: ?*PostProcessProgram, input_texture: gl.Texture, snapshot: AudioSnapshot) !void {
        if (!self.started) {
            self.first_rendered = try std.time.Instant.now();
            self.started = true;
        }
        const now = try std.time.Instant.now();
        const total_time: f32 = @floatFromInt(now.since(self.first_rendered));

        const audio_uniforms = AudioUniformPayload.fromSnapshot(snapshot).withEffectStrength(self.strength);
        const program = if (self.custom_program) |*custom_program| custom_program else shared_program orelse return error.InvalidPipelineValue;

        program.program.use();
        gl.uniform1i(program.input_texture_uniform, 0);
        gl.uniform2f(program.resolution_uniform, @floatFromInt(self.resolution.width), @floatFromInt(self.resolution.height));
        setUniform4f(program.audio_bands_uniform, audio_uniforms.bands);
        setUniform4f(program.audio_state_uniform, audio_uniforms.state);
        setUniform4f(program.audio_visualizer_uniform, audio_uniforms.visualizer);
        gl.uniform1f(program.time_uniform, total_time / std.time.ns_per_s);
        gl.uniform1f(program.strength_uniform, self.strength);
        gl.uniform1i(program.effect_uniform, if (self.effect) |effect| effect.shaderValue() else -1);

        gl.activeTexture(.texture_0);
        bindTexture2D(input_texture);
        gl.drawElements(.triangles, 6, .unsigned_byte, 0);
    }
};
