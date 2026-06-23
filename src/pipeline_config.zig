const std = @import("std");
const Allocator = std.mem.Allocator;

const audio = @import("audio.zig");
const shader = @import("shader.zig");

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

fn testingTmpPath(allocator: Allocator, tmp_dir: *const std.testing.TmpDir, sub_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp_dir.sub_path[0..], sub_path });
}

test "loadFileConfig parses pass pipeline audio and modulation sections" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "pipeline.toml",
        .data =
        \\[[passes]]
        \\kind = base
        \\path = "shader.glsl"
        \\
        \\[[passes]]
        \\kind = postprocess
        \\effect = pulse_zoom
        \\strength = 1.25
        \\
        \\[audio]
        \\enabled = true
        \\capture = source
        \\target = "music-monitor"
        \\
        \\[modulation]
        \\time_reactive = true
        \\time_strength = 1.75
        \\visual_reactive = true
        \\visual_strength = 0.80
        \\visual_style = heat
        \\
        ,
    });

    const pipeline_path = try testingTmpPath(allocator, &tmp, "pipeline.toml");
    defer allocator.free(pipeline_path);

    var config = try loadFileConfig(allocator, pipeline_path);
    defer config.deinit(allocator);

    const expected_base_path = try std.fs.path.resolve(allocator, &.{ ".zig-cache/tmp", tmp.sub_path[0..], "shader.glsl" });
    defer allocator.free(expected_base_path);

    try std.testing.expectEqualStrings(expected_base_path, config.base_path);
    try std.testing.expectEqual(PostProcessEffect.pulse_zoom, config.post_effect.?);
    try std.testing.expectEqual(@as(f32, 1.25), config.post_strength);
    try std.testing.expect(config.audio_enabled);
    try std.testing.expectEqual(audio.CaptureMode.source, config.audio_capture_mode);
    try std.testing.expectEqualStrings("music-monitor", config.audio_target.?);
    try std.testing.expect(config.time_modulation.enabled);
    try std.testing.expectEqual(@as(f32, 1.75), config.time_modulation.strength);
    try std.testing.expect(config.visual_modulation.enabled);
    try std.testing.expectEqual(@as(f32, 0.80), config.visual_modulation.strength);
    try std.testing.expectEqual(shader.VisualStyle.heat, config.visual_modulation.style);
}

test "loadFileConfig treats auto audio target as default target" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "pipeline.toml",
        .data =
        \\[pipeline]
        \\base = "shader.glsl"
        \\
        \\[audio]
        \\enabled = true
        \\capture = sink
        \\target = "auto"
        \\
        ,
    });

    const pipeline_path = try testingTmpPath(allocator, &tmp, "pipeline.toml");
    defer allocator.free(pipeline_path);

    var config = try loadFileConfig(allocator, pipeline_path);
    defer config.deinit(allocator);

    try std.testing.expect(config.audio_enabled);
    try std.testing.expectEqual(audio.CaptureMode.sink, config.audio_capture_mode);
    try std.testing.expectEqual(@as(?[]u8, null), config.audio_target);
}

test "loadFileConfig rejects invalid pass combinations" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "duplicate-base.toml",
        .data =
        \\[[passes]]
        \\kind = base
        \\path = "first.glsl"
        \\
        \\[[passes]]
        \\kind = base
        \\path = "second.glsl"
        \\
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "postprocess-with-path.toml",
        .data =
        \\[[passes]]
        \\kind = base
        \\path = "shader.glsl"
        \\
        \\[[passes]]
        \\kind = postprocess
        \\path = "not-used.glsl"
        \\effect = pulse_zoom
        \\
        ,
    });

    const duplicate_base_path = try testingTmpPath(allocator, &tmp, "duplicate-base.toml");
    defer allocator.free(duplicate_base_path);
    try std.testing.expectError(error.InvalidPipelineSyntax, loadFileConfig(allocator, duplicate_base_path));

    const postprocess_with_path = try testingTmpPath(allocator, &tmp, "postprocess-with-path.toml");
    defer allocator.free(postprocess_with_path);
    try std.testing.expectError(error.InvalidPipelineSyntax, loadFileConfig(allocator, postprocess_with_path));
}

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
