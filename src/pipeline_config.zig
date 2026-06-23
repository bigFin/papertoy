const std = @import("std");
const Allocator = std.mem.Allocator;

const audio = @import("audio.zig");
const effects = @import("effects.zig");
const shader = @import("shader.zig");

pub const PassKind = enum {
    base,
    postprocess,
};

pub const PostProcessEffect = effects.PostProcessEffect;

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

fn expectLoadDiagnostic(
    allocator: Allocator,
    tmp: *const std.testing.TmpDir,
    sub_path: []const u8,
    expected_error: anyerror,
    expected_line: usize,
    expected_message: []const u8,
) !void {
    const pipeline_path = try testingTmpPath(allocator, tmp, sub_path);
    defer allocator.free(pipeline_path);

    var diagnostic: ParseDiagnostic = .{};
    defer diagnostic.deinit(allocator);

    try std.testing.expectError(expected_error, loadFileConfigWithDiagnostic(allocator, pipeline_path, &diagnostic));
    try std.testing.expectEqual(expected_line, diagnostic.line);
    try std.testing.expectEqualStrings(expected_message, diagnostic.message.?);
}

test "loadFileConfigWithDiagnostic reports section key and effect errors" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "bad-section.toml",
        .data =
        \\[bogus]
        \\x = true
        \\
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "bad-key.toml",
        .data =
        \\[audio]
        \\wat = true
        \\
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "bad-effect.toml",
        .data =
        \\[[passes]]
        \\kind = postprocess
        \\effect = blurp
        \\
        ,
    });

    try expectLoadDiagnostic(allocator, &tmp, "bad-section.toml", error.InvalidPipelineSection, 1, "unknown section [bogus]");
    try expectLoadDiagnostic(allocator, &tmp, "bad-key.toml", error.InvalidPipelineKey, 2, "unknown key \"wat\" in [audio]");
    try expectLoadDiagnostic(allocator, &tmp, "bad-effect.toml", error.InvalidPipelineValue, 3, "unknown postprocess effect \"blurp\"; supported: pulse_zoom");
}

test "loadFileConfigWithDiagnostic reports pass validation lines" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "missing-base-path.toml",
        .data =
        \\[[passes]]
        \\kind = base
        \\
        ,
    });
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
        .sub_path = "postprocess-path.toml",
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

    try expectLoadDiagnostic(allocator, &tmp, "missing-base-path.toml", error.MissingPassPath, 1, "base pass must define path");
    try expectLoadDiagnostic(allocator, &tmp, "duplicate-base.toml", error.InvalidPipelineSyntax, 5, "pipeline can only define one base shader");
    try expectLoadDiagnostic(allocator, &tmp, "postprocess-path.toml", error.InvalidPipelineSyntax, 7, "postprocess pass cannot define path");
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

pub const ParseDiagnostic = struct {
    line: usize = 0,
    message: ?[]u8 = null,

    pub fn deinit(self: *ParseDiagnostic, allocator: Allocator) void {
        if (self.message) |message| allocator.free(message);
        self.* = .{};
    }
};

const ParseSection = enum {
    root,
    pipeline,
    audio,
    modulation,
    pass,

    fn label(self: ParseSection) []const u8 {
        return switch (self) {
            .root => "root",
            .pipeline => "[pipeline]",
            .audio => "[audio]",
            .modulation => "[modulation]",
            .pass => "[[passes]]",
        };
    }
};

fn setDiagnostic(
    allocator: Allocator,
    diagnostic: ?*ParseDiagnostic,
    line: usize,
    comptime message_format: []const u8,
    args: anytype,
) !void {
    if (diagnostic) |target| {
        target.deinit(allocator);
        target.line = line;
        target.message = try std.fmt.allocPrint(allocator, message_format, args);
    }
}

pub fn loadFileConfig(allocator: Allocator, pipeline_path: []const u8) !FileConfig {
    return loadFileConfigWithDiagnostic(allocator, pipeline_path, null);
}

pub fn loadFileConfigWithDiagnostic(
    allocator: Allocator,
    pipeline_path: []const u8,
    diagnostic: ?*ParseDiagnostic,
) !FileConfig {
    if (diagnostic) |target| target.deinit(allocator);

    const source = try std.fs.cwd().readFileAlloc(allocator, pipeline_path, std.math.maxInt(usize));
    defer allocator.free(source);

    var result = FileConfig{
        .base_path = try allocator.dupe(u8, ""),
    };
    errdefer result.deinit(allocator);

    var section: ParseSection = .root;
    var base_value: ?[]u8 = null;
    var base_value_line: usize = 0;
    defer if (base_value) |value| allocator.free(value);

    var current_pass_kind: PassKind = .base;
    var current_pass_line: usize = 0;
    var current_pass_path: ?[]u8 = null;
    var current_pass_path_line: usize = 0;
    defer if (current_pass_path) |value| allocator.free(value);
    var current_pass_effect: ?PostProcessEffect = null;
    var current_pass_effect_line: usize = 0;
    var current_pass_strength: f32 = 1.0;
    var in_pass = false;

    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_number: usize = 0;
    while (lines.next()) |line_raw| {
        line_number += 1;
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[') {
            if (line[line.len - 1] != ']') {
                try setDiagnostic(allocator, diagnostic, line_number, "section header must end with ']'", .{});
                return error.InvalidPipelineSyntax;
            }

            if (in_pass) {
                try finalizePass(
                    allocator,
                    diagnostic,
                    current_pass_line,
                    current_pass_path_line,
                    current_pass_effect_line,
                    &result,
                    &base_value,
                    &base_value_line,
                    &current_pass_kind,
                    &current_pass_path,
                    &current_pass_effect,
                    &current_pass_strength,
                );
                in_pass = false;
            }

            const is_array_table = line.len >= 4 and line[1] == '[' and line[line.len - 2] == ']';
            const header = if (is_array_table)
                std.mem.trim(u8, line[2 .. line.len - 2], " \t")
            else
                std.mem.trim(u8, line[1 .. line.len - 1], " \t");

            if (std.mem.eql(u8, header, "pipeline")) {
                if (is_array_table) {
                    try setDiagnostic(allocator, diagnostic, line_number, "[pipeline] must be a table, not an array table", .{});
                    return error.InvalidPipelineSyntax;
                }
                section = .pipeline;
            } else if (std.mem.eql(u8, header, "audio")) {
                if (is_array_table) {
                    try setDiagnostic(allocator, diagnostic, line_number, "[audio] must be a table, not an array table", .{});
                    return error.InvalidPipelineSyntax;
                }
                section = .audio;
            } else if (std.mem.eql(u8, header, "modulation")) {
                if (is_array_table) {
                    try setDiagnostic(allocator, diagnostic, line_number, "[modulation] must be a table, not an array table", .{});
                    return error.InvalidPipelineSyntax;
                }
                section = .modulation;
            } else if (std.mem.eql(u8, header, "passes")) {
                if (!is_array_table) {
                    try setDiagnostic(allocator, diagnostic, line_number, "[passes] must be an array table: [[passes]]", .{});
                    return error.InvalidPipelineSyntax;
                }
                section = .pass;
                in_pass = true;
                current_pass_line = line_number;
                current_pass_kind = .base;
                current_pass_effect = null;
                current_pass_effect_line = 0;
                current_pass_strength = 1.0;
                if (current_pass_path) |old| {
                    allocator.free(old);
                    current_pass_path = null;
                }
                current_pass_path_line = 0;
            } else {
                try setDiagnostic(allocator, diagnostic, line_number, "unknown section [{s}]", .{header});
                return error.InvalidPipelineSection;
            }
            continue;
        }

        const equals_index = std.mem.indexOfScalar(u8, line, '=') orelse {
            try setDiagnostic(allocator, diagnostic, line_number, "expected key = value", .{});
            return error.InvalidPipelineSyntax;
        };
        const key = std.mem.trim(u8, line[0..equals_index], " \t");
        const value = std.mem.trim(u8, line[equals_index + 1 ..], " \t");
        if (key.len == 0 or value.len == 0) {
            try setDiagnostic(allocator, diagnostic, line_number, "key and value must not be empty", .{});
            return error.InvalidPipelineSyntax;
        }

        switch (section) {
            .pipeline => {
                if (std.mem.eql(u8, key, "base")) {
                    if (base_value) |old| allocator.free(old);
                    base_value = parseString(allocator, value) catch |err| {
                        try setDiagnostic(allocator, diagnostic, line_number, "invalid value for [pipeline].base: expected quoted string", .{});
                        return err;
                    };
                    base_value_line = line_number;
                } else {
                    try setDiagnostic(allocator, diagnostic, line_number, "unknown key \"{s}\" in {s}", .{ key, section.label() });
                    return error.InvalidPipelineKey;
                }
            },
            .audio => {
                if (std.mem.eql(u8, key, "enabled")) {
                    result.audio_enabled = parseBool(value) catch |err| {
                        try setDiagnostic(allocator, diagnostic, line_number, "invalid value for [audio].enabled: expected true or false", .{});
                        return err;
                    };
                } else if (std.mem.eql(u8, key, "capture")) {
                    result.audio_capture_mode = parseCaptureMode(value) catch |err| {
                        try setDiagnostic(allocator, diagnostic, line_number, "invalid audio capture mode \"{s}\"; supported: sink, source", .{value});
                        return err;
                    };
                } else if (std.mem.eql(u8, key, "target")) {
                    const parsed = parseString(allocator, value) catch |err| {
                        try setDiagnostic(allocator, diagnostic, line_number, "invalid value for [audio].target: expected quoted string or \"auto\"", .{});
                        return err;
                    };
                    if (std.mem.eql(u8, parsed, "auto")) {
                        allocator.free(parsed);
                        if (result.audio_target) |old| allocator.free(old);
                        result.audio_target = null;
                    } else {
                        if (result.audio_target) |old| allocator.free(old);
                        result.audio_target = parsed;
                    }
                } else {
                    try setDiagnostic(allocator, diagnostic, line_number, "unknown key \"{s}\" in {s}", .{ key, section.label() });
                    return error.InvalidPipelineKey;
                }
            },
            .modulation => {
                if (std.mem.eql(u8, key, "time_reactive")) {
                    result.time_modulation.enabled = parseBool(value) catch |err| {
                        try setDiagnostic(allocator, diagnostic, line_number, "invalid value for [modulation].time_reactive: expected true or false", .{});
                        return err;
                    };
                } else if (std.mem.eql(u8, key, "time_strength")) {
                    result.time_modulation.strength = parseFloat(value) catch |err| {
                        try setDiagnostic(allocator, diagnostic, line_number, "invalid value for [modulation].time_strength: expected number", .{});
                        return err;
                    };
                } else if (std.mem.eql(u8, key, "visual_reactive")) {
                    result.visual_modulation.enabled = parseBool(value) catch |err| {
                        try setDiagnostic(allocator, diagnostic, line_number, "invalid value for [modulation].visual_reactive: expected true or false", .{});
                        return err;
                    };
                } else if (std.mem.eql(u8, key, "visual_strength")) {
                    result.visual_modulation.strength = parseFloat(value) catch |err| {
                        try setDiagnostic(allocator, diagnostic, line_number, "invalid value for [modulation].visual_strength: expected number", .{});
                        return err;
                    };
                } else if (std.mem.eql(u8, key, "visual_style")) {
                    result.visual_modulation.style = parseVisualStyle(value) catch |err| {
                        try setDiagnostic(allocator, diagnostic, line_number, "invalid visual style \"{s}\"; supported: blend, pulse, drift, strobe, heat", .{value});
                        return err;
                    };
                } else {
                    try setDiagnostic(allocator, diagnostic, line_number, "unknown key \"{s}\" in {s}", .{ key, section.label() });
                    return error.InvalidPipelineKey;
                }
            },
            .pass => {
                if (std.mem.eql(u8, key, "kind")) {
                    current_pass_kind = parsePassKind(value) catch |err| {
                        try setDiagnostic(allocator, diagnostic, line_number, "invalid pass kind \"{s}\"; supported: base, postprocess", .{value});
                        return err;
                    };
                } else if (std.mem.eql(u8, key, "path")) {
                    if (current_pass_path) |old| allocator.free(old);
                    current_pass_path = parseString(allocator, value) catch |err| {
                        try setDiagnostic(allocator, diagnostic, line_number, "invalid pass path: expected quoted string", .{});
                        return err;
                    };
                    current_pass_path_line = line_number;
                } else if (std.mem.eql(u8, key, "effect")) {
                    current_pass_effect = parsePostProcessEffect(value) catch |err| {
                        try setDiagnostic(allocator, diagnostic, line_number, "unknown postprocess effect \"{s}\"; supported: {s}", .{ value, effects.supportedConfigNames() });
                        return err;
                    };
                    current_pass_effect_line = line_number;
                } else if (std.mem.eql(u8, key, "strength")) {
                    current_pass_strength = parseFloat(value) catch |err| {
                        try setDiagnostic(allocator, diagnostic, line_number, "invalid pass strength: expected number", .{});
                        return err;
                    };
                } else {
                    try setDiagnostic(allocator, diagnostic, line_number, "unknown key \"{s}\" in {s}", .{ key, section.label() });
                    return error.InvalidPipelineKey;
                }
            },
            .root => {
                try setDiagnostic(allocator, diagnostic, line_number, "key \"{s}\" must be inside a section", .{key});
                return error.InvalidPipelineSyntax;
            },
        }
    }

    if (in_pass) {
        try finalizePass(
            allocator,
            diagnostic,
            current_pass_line,
            current_pass_path_line,
            current_pass_effect_line,
            &result,
            &base_value,
            &base_value_line,
            &current_pass_kind,
            &current_pass_path,
            &current_pass_effect,
            &current_pass_strength,
        );
        in_pass = false;
    }

    const base = base_value orelse {
        try setDiagnostic(allocator, diagnostic, @max(line_number, 1), "pipeline file must define a base shader using [pipeline].base or a base pass path", .{});
        return error.MissingBaseShader;
    };
    allocator.free(result.base_path);
    result.base_path = resolvePipelinePath(allocator, pipeline_path, base) catch |err| {
        if (err == error.MissingEnvironmentVariable) {
            try setDiagnostic(allocator, diagnostic, base_value_line, "pipeline path references an environment variable that is not set: {s}", .{base});
        }
        return err;
    };
    return result;
}

fn finalizePass(
    allocator: Allocator,
    diagnostic: ?*ParseDiagnostic,
    pass_line: usize,
    pass_path_line: usize,
    pass_effect_line: usize,
    result: *FileConfig,
    base_value: *?[]u8,
    base_value_line: *usize,
    pass_kind: *PassKind,
    pass_path: *?[]u8,
    pass_effect: *?PostProcessEffect,
    pass_strength: *f32,
) !void {
    switch (pass_kind.*) {
        .base => {
            const path = pass_path.* orelse {
                try setDiagnostic(allocator, diagnostic, pass_line, "base pass must define path", .{});
                return error.MissingPassPath;
            };
            if (pass_effect.* != null) {
                try setDiagnostic(allocator, diagnostic, pass_effect_line, "base pass cannot define effect", .{});
                return error.InvalidPipelineSyntax;
            }
            if (base_value.* != null) {
                try setDiagnostic(allocator, diagnostic, pass_line, "pipeline can only define one base shader", .{});
                return error.InvalidPipelineSyntax;
            }
            base_value.* = path;
            base_value_line.* = pass_path_line;
            pass_path.* = null;
        },
        .postprocess => {
            if (pass_path.* != null) {
                try setDiagnostic(allocator, diagnostic, pass_path_line, "postprocess pass cannot define path", .{});
                return error.InvalidPipelineSyntax;
            }
            const effect = pass_effect.* orelse {
                try setDiagnostic(allocator, diagnostic, pass_line, "postprocess pass must define effect", .{});
                return error.MissingPassEffect;
            };
            if (result.post_effect != null) {
                try setDiagnostic(allocator, diagnostic, pass_line, "pipeline can only define one postprocess pass", .{});
                return error.InvalidPipelineSyntax;
            }
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
    return PostProcessEffect.parseConfigName(parsed) orelse error.InvalidPipelineValue;
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
