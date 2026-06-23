const std = @import("std");
const Allocator = std.mem.Allocator;

const audio = @import("audio.zig");
const AudioSnapshot = @import("audio.zig").Snapshot;
const gl = @import("zgl");
const shader = @import("shader.zig");

const glb = gl.binding;

pub const PassKind = enum {
    base,
    postprocess,
};

pub const PostProcessEffect = enum(i32) {
    pulse_zoom = 0,
};

pub const PassConfig = struct {
    kind: PassKind = .base,
    source: ?[]const u8 = null,
    effect: ?PostProcessEffect = null,
    strength: f32 = 1.0,
    time_modulation: shader.TimeModulation = .{},
    visual_modulation: shader.VisualModulation = .{},
};

pub const PipelineConfig = struct {
    resolution: shader.Resolution,
    frame_rate: u32,
    pass_count: usize,
    passes: [2]PassConfig,

    pub fn activePasses(self: *const PipelineConfig) ![]const PassConfig {
        if (self.pass_count == 0 or self.pass_count > self.passes.len) return error.InvalidPipelineValue;
        return self.passes[0..self.pass_count];
    }

    pub fn legacy(
        source: []const u8,
        resolution: shader.Resolution,
        frame_rate: u32,
        time_modulation: shader.TimeModulation,
        visual_modulation: shader.VisualModulation,
    ) PipelineConfig {
        return .{
            .resolution = resolution,
            .frame_rate = frame_rate,
            .pass_count = 1,
            .passes = .{
                .{
                    .kind = .base,
                    .source = source,
                    .time_modulation = time_modulation,
                    .visual_modulation = visual_modulation,
                },
                .{},
            },
        };
    }

    pub fn unified(
        source: []const u8,
        resolution: shader.Resolution,
        frame_rate: u32,
        time_modulation: shader.TimeModulation,
        visual_modulation: shader.VisualModulation,
        post_effect: ?PostProcessEffect,
        post_strength: f32,
    ) PipelineConfig {
        if (post_effect) |effect| {
            return .{
                .resolution = resolution,
                .frame_rate = frame_rate,
                .pass_count = 2,
                .passes = .{
                    .{
                        .kind = .base,
                        .source = source,
                        .time_modulation = time_modulation,
                        .visual_modulation = visual_modulation,
                    },
                    .{
                        .kind = .postprocess,
                        .effect = effect,
                        .strength = post_strength,
                    },
                },
            };
        }

        return legacy(source, resolution, frame_rate, time_modulation, visual_modulation);
    }
};

test "PipelineConfig stores generated passes inline" {
    const source = "void mainImage(out vec4 fragColor, in vec2 fragCoord) { fragColor = vec4(fragCoord, 0.0, 1.0); }";
    const resolution: shader.Resolution = .{ .width = 64, .height = 32 };

    const legacy_config = PipelineConfig.legacy(source, resolution, 60, .{}, .{});
    try std.testing.expectEqual(@as(usize, 1), legacy_config.pass_count);
    try std.testing.expectEqual(.base, legacy_config.passes[0].kind);
    try std.testing.expectEqualStrings(source, legacy_config.passes[0].source.?);

    const post_config = PipelineConfig.unified(source, resolution, 60, .{}, .{}, .pulse_zoom, 0.75);
    try std.testing.expectEqual(@as(usize, 2), post_config.pass_count);
    try std.testing.expectEqual(.base, post_config.passes[0].kind);
    try std.testing.expectEqualStrings(source, post_config.passes[0].source.?);
    try std.testing.expectEqual(.postprocess, post_config.passes[1].kind);
    try std.testing.expectEqual(PostProcessEffect.pulse_zoom, post_config.passes[1].effect.?);
    try std.testing.expectEqual(@as(f32, 0.75), post_config.passes[1].strength);
}

test "PipelineConfig rejects invalid pass counts" {
    const source = "void mainImage(out vec4 fragColor, in vec2 fragCoord) { fragColor = vec4(fragCoord, 0.0, 1.0); }";
    const resolution: shader.Resolution = .{ .width = 64, .height = 32 };

    var config = PipelineConfig.legacy(source, resolution, 60, .{}, .{});
    config.pass_count = 0;
    try std.testing.expectError(error.InvalidPipelineValue, config.activePasses());

    config.pass_count = config.passes.len + 1;
    try std.testing.expectError(error.InvalidPipelineValue, config.activePasses());
}

pub const FileConfig = struct {
    base_path: []u8,
    post_effect: ?PostProcessEffect = null,
    post_strength: f32 = 1.0,
    audio_enabled: bool = false,
    audio_target: ?[]u8 = null,
    audio_capture_mode: audio.CaptureMode = .sink,
    time_modulation: shader.TimeModulation = .{},
    visual_modulation: shader.VisualModulation = .{},

    pub fn deinit(self: *FileConfig, allocator: Allocator) void {
        allocator.free(self.base_path);
        if (self.audio_target) |target| allocator.free(target);
    }
};

pub const ParseError = error{
    MissingEnvironmentVariable,
    MissingBaseShader,
    MissingPassEffect,
    MissingPassPath,
    InvalidPipelineSyntax,
    InvalidPipelineSection,
    InvalidPipelineKey,
    InvalidPipelineValue,
};

pub fn loadFileConfig(allocator: Allocator, pipeline_path: []const u8) !FileConfig {
    const source = try std.fs.cwd().readFileAlloc(allocator, pipeline_path, std.math.maxInt(usize));
    defer allocator.free(source);

    var result = FileConfig{
        .base_path = try allocator.dupe(u8, ""),
    };
    errdefer result.deinit(allocator);

    var section: enum { root, pipeline, audio, modulation, pass } = .root;
    var base_value: ?[]u8 = null;
    defer if (base_value) |value| allocator.free(value);

    var current_pass_kind: PassKind = .base;
    var current_pass_path: ?[]u8 = null;
    defer if (current_pass_path) |value| allocator.free(value);
    var current_pass_effect: ?PostProcessEffect = null;
    var current_pass_strength: f32 = 1.0;
    var in_pass = false;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[') {
            if (line[line.len - 1] != ']') return error.InvalidPipelineSyntax;

            if (in_pass) {
                try finalizePass(&result, &base_value, &current_pass_kind, &current_pass_path, &current_pass_effect, &current_pass_strength);
                in_pass = false;
            }

            const is_array_table = line.len >= 4 and line[1] == '[' and line[line.len - 2] == ']';
            const header = if (is_array_table)
                std.mem.trim(u8, line[2 .. line.len - 2], " \t")
            else
                std.mem.trim(u8, line[1 .. line.len - 1], " \t");

            if (std.mem.eql(u8, header, "pipeline")) {
                if (is_array_table) return error.InvalidPipelineSyntax;
                section = .pipeline;
            } else if (std.mem.eql(u8, header, "audio")) {
                if (is_array_table) return error.InvalidPipelineSyntax;
                section = .audio;
            } else if (std.mem.eql(u8, header, "modulation")) {
                if (is_array_table) return error.InvalidPipelineSyntax;
                section = .modulation;
            } else if (std.mem.eql(u8, header, "passes")) {
                if (!is_array_table) return error.InvalidPipelineSyntax;
                section = .pass;
                in_pass = true;
                current_pass_kind = .base;
                current_pass_effect = null;
                current_pass_strength = 1.0;
                if (current_pass_path) |old| {
                    allocator.free(old);
                    current_pass_path = null;
                }
            } else {
                return error.InvalidPipelineSection;
            }
            continue;
        }

        const equals_index = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidPipelineSyntax;
        const key = std.mem.trim(u8, line[0..equals_index], " \t");
        const value = std.mem.trim(u8, line[equals_index + 1 ..], " \t");
        if (key.len == 0 or value.len == 0) return error.InvalidPipelineSyntax;

        switch (section) {
            .pipeline => {
                if (std.mem.eql(u8, key, "base")) {
                    if (base_value) |old| allocator.free(old);
                    base_value = try parseString(allocator, value);
                } else {
                    return error.InvalidPipelineKey;
                }
            },
            .audio => {
                if (std.mem.eql(u8, key, "enabled")) {
                    result.audio_enabled = try parseBool(value);
                } else if (std.mem.eql(u8, key, "capture")) {
                    result.audio_capture_mode = try parseCaptureMode(value);
                } else if (std.mem.eql(u8, key, "target")) {
                    const parsed = try parseString(allocator, value);
                    if (std.mem.eql(u8, parsed, "auto")) {
                        allocator.free(parsed);
                        if (result.audio_target) |old| allocator.free(old);
                        result.audio_target = null;
                    } else {
                        if (result.audio_target) |old| allocator.free(old);
                        result.audio_target = parsed;
                    }
                } else {
                    return error.InvalidPipelineKey;
                }
            },
            .modulation => {
                if (std.mem.eql(u8, key, "time_reactive")) {
                    result.time_modulation.enabled = try parseBool(value);
                } else if (std.mem.eql(u8, key, "time_strength")) {
                    result.time_modulation.strength = try parseFloat(value);
                } else if (std.mem.eql(u8, key, "visual_reactive")) {
                    result.visual_modulation.enabled = try parseBool(value);
                } else if (std.mem.eql(u8, key, "visual_strength")) {
                    result.visual_modulation.strength = try parseFloat(value);
                } else if (std.mem.eql(u8, key, "visual_style")) {
                    result.visual_modulation.style = try parseVisualStyle(value);
                } else {
                    return error.InvalidPipelineKey;
                }
            },
            .pass => {
                if (std.mem.eql(u8, key, "kind")) {
                    current_pass_kind = try parsePassKind(value);
                } else if (std.mem.eql(u8, key, "path")) {
                    if (current_pass_path) |old| allocator.free(old);
                    current_pass_path = try parseString(allocator, value);
                } else if (std.mem.eql(u8, key, "effect")) {
                    current_pass_effect = try parsePostProcessEffect(value);
                } else if (std.mem.eql(u8, key, "strength")) {
                    current_pass_strength = try parseFloat(value);
                } else {
                    return error.InvalidPipelineKey;
                }
            },
            .root => return error.InvalidPipelineSyntax,
        }
    }

    if (in_pass) {
        try finalizePass(&result, &base_value, &current_pass_kind, &current_pass_path, &current_pass_effect, &current_pass_strength);
        in_pass = false;
    }

    const base = base_value orelse return error.MissingBaseShader;
    allocator.free(result.base_path);
    result.base_path = try resolvePipelinePath(allocator, pipeline_path, base);
    return result;
}

fn finalizePass(
    result: *FileConfig,
    base_value: *?[]u8,
    pass_kind: *PassKind,
    pass_path: *?[]u8,
    pass_effect: *?PostProcessEffect,
    pass_strength: *f32,
) !void {
    switch (pass_kind.*) {
        .base => {
            const path = pass_path.* orelse return error.MissingPassPath;
            if (pass_effect.* != null or base_value.* != null or pass_strength.* != 1.0) return error.InvalidPipelineSyntax;
            base_value.* = path;
            pass_path.* = null;
        },
        .postprocess => {
            if (pass_path.* != null) return error.InvalidPipelineSyntax;
            const effect = pass_effect.* orelse return error.MissingPassEffect;
            if (result.post_effect != null) return error.InvalidPipelineSyntax;
            result.post_effect = effect;
            result.post_strength = pass_strength.*;
        },
    }

    pass_effect.* = null;
    pass_strength.* = 1.0;
}

fn resolvePipelinePath(allocator: Allocator, pipeline_path: []const u8, target: []const u8) ![]u8 {
    const expanded_target = try expandEnvironmentReference(allocator, target);
    defer allocator.free(expanded_target);

    if (std.fs.path.isAbsolute(expanded_target)) return allocator.dupe(u8, expanded_target);
    const base_dir = std.fs.path.dirname(pipeline_path) orelse ".";
    return std.fs.path.resolve(allocator, &.{ base_dir, expanded_target });
}

test "resolvePipelinePath resolves literal paths without leaking expanded target" {
    const allocator = std.testing.allocator;

    const relative = try resolvePipelinePath(allocator, "/tmp/papertoy/pipeline.toml", "shader.glsl");
    defer allocator.free(relative);
    try std.testing.expectEqualStrings("/tmp/papertoy/shader.glsl", relative);

    const absolute = try resolvePipelinePath(allocator, "/tmp/papertoy/pipeline.toml", "/opt/shaders/base.glsl");
    defer allocator.free(absolute);
    try std.testing.expectEqualStrings("/opt/shaders/base.glsl", absolute);
}

fn parseString(allocator: Allocator, value: []const u8) ![]u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return error.InvalidPipelineValue;
    if (std.mem.indexOfScalar(u8, value[1 .. value.len - 1], '\\') != null) return error.InvalidPipelineValue;
    return allocator.dupe(u8, value[1 .. value.len - 1]);
}

fn parseBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidPipelineValue;
}

fn parseFloat(value: []const u8) !f32 {
    return std.fmt.parseFloat(f32, value) catch error.InvalidPipelineValue;
}

fn parseCaptureMode(value: []const u8) !audio.CaptureMode {
    const parsed = try parseUnquotedIdentifier(value);
    if (std.mem.eql(u8, parsed, "sink")) return .sink;
    if (std.mem.eql(u8, parsed, "source")) return .source;
    return error.InvalidPipelineValue;
}

fn parseVisualStyle(value: []const u8) !shader.VisualStyle {
    const parsed = try parseUnquotedIdentifier(value);
    if (std.mem.eql(u8, parsed, "blend")) return .blend;
    if (std.mem.eql(u8, parsed, "pulse")) return .pulse;
    if (std.mem.eql(u8, parsed, "drift")) return .drift;
    if (std.mem.eql(u8, parsed, "strobe")) return .strobe;
    if (std.mem.eql(u8, parsed, "heat")) return .heat;
    return error.InvalidPipelineValue;
}

fn parsePassKind(value: []const u8) !PassKind {
    const parsed = try parseUnquotedIdentifier(value);
    if (std.mem.eql(u8, parsed, "base")) return .base;
    if (std.mem.eql(u8, parsed, "postprocess")) return .postprocess;
    return error.InvalidPipelineValue;
}

fn parsePostProcessEffect(value: []const u8) !PostProcessEffect {
    const parsed = try parseUnquotedIdentifier(value);
    if (std.mem.eql(u8, parsed, "pulse_zoom")) return .pulse_zoom;
    return error.InvalidPipelineValue;
}

fn parseUnquotedIdentifier(value: []const u8) ![]const u8 {
    if (value.len == 0) return error.InvalidPipelineValue;
    if (value[0] == '"') return error.InvalidPipelineValue;
    return value;
}

fn expandEnvironmentReference(allocator: Allocator, value: []const u8) ![]u8 {
    if (value.len >= 3 and value[0] == '$' and value[1] == '{' and value[value.len - 1] == '}') {
        const env_name = value[2 .. value.len - 1];
        return std.process.getEnvVarOwned(allocator, env_name) catch return error.MissingEnvironmentVariable;
    }
    return allocator.dupe(u8, value);
}

pub const PipelineRunner = struct {
    base_pass: *shader.Shader,
    post_pass: ?PostProcessPass = null,
    offscreen_target: ?RenderTarget = null,

    pub fn createLegacy(allocator: Allocator, config: PipelineConfig) !PipelineRunner {
        const passes = try config.activePasses();

        const base_config = passes[0];
        if (base_config.kind != .base) return error.InvalidPipelineValue;
        var self = PipelineRunner{
            .base_pass = try shader.Shader.create(
                allocator,
                base_config.source orelse return error.InvalidPipelineValue,
                config.resolution,
                config.frame_rate,
                base_config.time_modulation,
                base_config.visual_modulation,
            ),
        };
        errdefer self.base_pass.destroy(allocator);

        if (passes.len > 1) {
            const post_config = passes[1];
            if (post_config.kind != .postprocess or post_config.effect == null) return error.InvalidPipelineValue;

            self.offscreen_target = try RenderTarget.init(config.resolution);
            errdefer if (self.offscreen_target) |*target| target.deinit();

            self.post_pass = try PostProcessPass.init(allocator, config.resolution, post_config.effect.?);
            errdefer if (self.post_pass) |*pass| pass.deinit(allocator);
            self.post_pass.?.strength = post_config.strength;
        }

        return self;
    }

    pub fn destroy(self: *PipelineRunner, allocator: Allocator) void {
        if (self.post_pass) |*pass| pass.deinit(allocator);
        if (self.offscreen_target) |*target| target.deinit();
        self.base_pass.destroy(allocator);
    }

    pub fn resize(self: *PipelineRunner, resolution: shader.Resolution) !void {
        self.base_pass.resolution = resolution;
        if (self.offscreen_target) |*target| try target.resize(resolution);
        if (self.post_pass) |*pass| pass.resolution = resolution;
    }

    pub fn render(self: *PipelineRunner, snapshot: AudioSnapshot) !void {
        if (self.offscreen_target) |*target| {
            target.bind();
            gl.viewport(0, 0, target.resolution.width, target.resolution.height);
            gl.clearColor(0, 0, 0, 1);
            gl.clear(.{ .color = true });
            try self.base_pass.render(snapshot);

            gl.bindFramebuffer(.invalid, .buffer);
            gl.viewport(0, 0, target.resolution.width, target.resolution.height);
            try self.post_pass.?.render(target.texture, snapshot);
        } else {
            try self.base_pass.render(snapshot);
        }
    }

    pub fn frame(self: *const PipelineRunner) u32 {
        return self.base_pass.frame;
    }
};

const RenderTarget = struct {
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

const PostProcessPass = struct {
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

        self.program.use();
        gl.uniform1i(self.input_texture_uniform, 0);
        gl.uniform2f(self.resolution_uniform, @floatFromInt(self.resolution.width), @floatFromInt(self.resolution.height));
        gl.uniform4f(self.audio_bands_uniform, snapshot.level, snapshot.bass, snapshot.mid, snapshot.treble);
        gl.uniform4f(self.audio_state_uniform, snapshot.beat, snapshot.active, 0, 0);
        gl.uniform4f(
            self.audio_visualizer_uniform,
            snapshot.impact * self.strength,
            snapshot.energy * self.strength,
            snapshot.drive,
            snapshot.brightness * self.strength,
        );
        gl.uniform1f(self.time_uniform, total_time / std.time.ns_per_s);
        gl.uniform1i(self.effect_uniform, @intFromEnum(self.effect));

        gl.activeTexture(.texture_0);
        bindTexture2D(input_texture);
        gl.drawElements(.triangles, 6, .unsigned_byte, 0);
    }
};
