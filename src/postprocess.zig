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
    \\    color = mix(vec3(luma), color, 1.0 + brightness * 0.4);
    \\    color = ((color - 0.5) * (1.0 + impact * 0.8 + energy * 0.35)) + 0.5;
    \\    color += vec3(0.12, 0.06, 0.02) * impact;
    \\    return max(color, vec3(0.0));
    \\}
    \\
    \\void main() {
    \\    if (uEffect == 0) {
    \\        fragColor = vec4(applyPulseZoom(vUv), 1.0);
    \\    } else {
    \\        fragColor = texture(uInputTexture, vUv);
    \\    }
    \\}
;

pub const PostProcessPass = struct {
    program: gl.Program,
    resolution: shader.Resolution,
    effect: PostProcessEffect,
    strength: f32 = 1.0,
    input_texture_uniform: ?u32,
    resolution_uniform: ?u32,
    audio_bands_uniform: ?u32,
    audio_state_uniform: ?u32,
    audio_visualizer_uniform: ?u32,
    time_uniform: ?u32,
    effect_uniform: ?u32,
    started: bool = false,
    first_rendered: std.time.Instant = undefined,

    pub fn init(allocator: Allocator, resolution: shader.Resolution, effect: PostProcessEffect) !PostProcessPass {
        const vert = gl.Shader.create(.vertex);
        defer vert.delete();
        vert.source(1, &.{POST_PROCESS_VERTEX_SOURCE[0..]});
        vert.compile();

        const frag = gl.Shader.create(.fragment);
        defer frag.delete();
        frag.source(1, &.{POST_PROCESS_FRAGMENT_SOURCE[0..]});
        frag.compile();

        const frag_compiled = frag.get(.compile_status) == gl.binding.TRUE;
        if (!frag_compiled) {
            const log = try frag.getCompileLog(allocator);
            defer allocator.free(log);
            std.log.err("failed to compile post-process shader:\n{s}", .{log});
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
            std.log.err("failed to link post-process shader:\n{s}", .{log});
            return error.InvalidPipelineValue;
        }

        return .{
            .program = program,
            .resolution = resolution,
            .effect = effect,
            .input_texture_uniform = program.uniformLocation("uInputTexture"),
            .resolution_uniform = program.uniformLocation("uResolution"),
            .audio_bands_uniform = program.uniformLocation("uAudioBands"),
            .audio_state_uniform = program.uniformLocation("uAudioState"),
            .audio_visualizer_uniform = program.uniformLocation("uAudioVisualizer"),
            .time_uniform = program.uniformLocation("uTime"),
            .effect_uniform = program.uniformLocation("uEffect"),
        };
    }

    pub fn deinit(self: *PostProcessPass, allocator: Allocator) void {
        _ = allocator;
        self.program.delete();
    }

    pub fn render(self: *PostProcessPass, input_texture: gl.Texture, snapshot: AudioSnapshot) !void {
        if (!self.started) {
            self.first_rendered = try std.time.Instant.now();
            self.started = true;
        }
        const now = try std.time.Instant.now();
        const total_time: f32 = @floatFromInt(now.since(self.first_rendered));

        const audio_uniforms = AudioUniformPayload.fromSnapshot(snapshot).withEffectStrength(self.strength);

        self.program.use();
        gl.uniform1i(self.input_texture_uniform, 0);
        gl.uniform2f(self.resolution_uniform, @floatFromInt(self.resolution.width), @floatFromInt(self.resolution.height));
        setUniform4f(self.audio_bands_uniform, audio_uniforms.bands);
        setUniform4f(self.audio_state_uniform, audio_uniforms.state);
        setUniform4f(self.audio_visualizer_uniform, audio_uniforms.visualizer);
        gl.uniform1f(self.time_uniform, total_time / std.time.ns_per_s);
        gl.uniform1i(self.effect_uniform, self.effect.shaderValue());

        gl.activeTexture(.texture_0);
        bindTexture2D(input_texture);
        gl.drawElements(.triangles, 6, .unsigned_byte, 0);
    }
};
