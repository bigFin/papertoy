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

pub const max_postprocess_passes = 4;
pub const max_passes = max_postprocess_passes + 1;
const max_pipeline_file_size = 1024 * 1024;

pub const PostProcessConfig = struct {
    effect: ?PostProcessEffect = null,
    path: ?[]const u8 = null,
    source: ?[]const u8 = null,
    strength: f32 = 1.0,
};

pub const PassConfig = struct {
    kind: PassKind = .base,
    source: ?[]const u8 = null,
    path: ?[]const u8 = null,
    effect: ?PostProcessEffect = null,
    strength: f32 = 1.0,
    time_modulation: shader.TimeModulation = .{},
    visual_modulation: shader.VisualModulation = .{},
};

pub const PipelineConfig = struct {
    resolution: shader.Resolution,
    frame_rate: u32,
    pass_count: usize,
    passes: [max_passes]PassConfig,

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
        var passes = [_]PassConfig{.{}} ** max_passes;
        passes[0] = .{
            .kind = .base,
            .source = source,
            .time_modulation = time_modulation,
            .visual_modulation = visual_modulation,
        };

        return .{
            .resolution = resolution,
            .frame_rate = frame_rate,
            .pass_count = 1,
            .passes = passes,
        };
    }

    pub fn withPostprocessPasses(
        source: []const u8,
        resolution: shader.Resolution,
        frame_rate: u32,
        time_modulation: shader.TimeModulation,
        visual_modulation: shader.VisualModulation,
        postprocess_passes: []const PostProcessConfig,
    ) !PipelineConfig {
        if (postprocess_passes.len > max_postprocess_passes) return error.InvalidPipelineValue;

        var passes = [_]PassConfig{.{}} ** max_passes;
        passes[0] = .{
            .kind = .base,
            .source = source,
            .time_modulation = time_modulation,
            .visual_modulation = visual_modulation,
        };
        for (postprocess_passes, 0..) |post_config, i| {
            passes[i + 1] = .{
                .kind = .postprocess,
                .effect = post_config.effect,
                .path = post_config.path,
                .source = post_config.source,
                .strength = post_config.strength,
            };
        }

        return .{
            .resolution = resolution,
            .frame_rate = frame_rate,
            .pass_count = 1 + postprocess_passes.len,
            .passes = passes,
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
            return withPostprocessPasses(
                source,
                resolution,
                frame_rate,
                time_modulation,
                visual_modulation,
                &.{.{ .effect = effect, .strength = post_strength }},
            ) catch unreachable;
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

test "PipelineConfig stores multiple postprocess passes inline" {
    const source = "void mainImage(out vec4 fragColor, in vec2 fragCoord) { fragColor = vec4(fragCoord, 0.0, 1.0); }";
    const resolution: shader.Resolution = .{ .width = 64, .height = 32 };

    const postprocess_passes = [_]PostProcessConfig{
        .{ .effect = .pulse_zoom, .strength = 0.5 },
        .{ .effect = .heat_shift, .strength = 1.25 },
    };
    const config = try PipelineConfig.withPostprocessPasses(source, resolution, 60, .{}, .{}, &postprocess_passes);

    try std.testing.expectEqual(@as(usize, 3), config.pass_count);
    try std.testing.expectEqual(.base, config.passes[0].kind);
    try std.testing.expectEqual(.postprocess, config.passes[1].kind);
    try std.testing.expectEqual(PostProcessEffect.pulse_zoom, config.passes[1].effect.?);
    try std.testing.expectEqual(@as(f32, 0.5), config.passes[1].strength);
    try std.testing.expectEqual(.postprocess, config.passes[2].kind);
    try std.testing.expectEqual(PostProcessEffect.heat_shift, config.passes[2].effect.?);
    try std.testing.expectEqual(@as(f32, 1.25), config.passes[2].strength);
}

test "PipelineConfig stores custom postprocess source and path inline" {
    const source = "void mainImage(out vec4 fragColor, in vec2 fragCoord) { fragColor = vec4(fragCoord, 0.0, 1.0); }";
    const postprocess_source =
        \\#version 330 core
        \\in vec2 vUv;
        \\out vec4 fragColor;
        \\uniform sampler2D uInputTexture;
        \\void main() { fragColor = texture(uInputTexture, vUv); }
    ;
    const postprocess_path = "/tmp/custom-post.glsl";
    const resolution: shader.Resolution = .{ .width = 64, .height = 32 };
    const postprocess_passes = [_]PostProcessConfig{
        .{
            .path = postprocess_path,
            .source = postprocess_source,
            .strength = 0.8,
        },
    };
    const config = try PipelineConfig.withPostprocessPasses(source, resolution, 60, .{}, .{}, &postprocess_passes);

    try std.testing.expectEqual(@as(usize, 2), config.pass_count);
    try std.testing.expectEqual(.postprocess, config.passes[1].kind);
    try std.testing.expectEqual(@as(?PostProcessEffect, null), config.passes[1].effect);
    try std.testing.expectEqualStrings(postprocess_path, config.passes[1].path.?);
    try std.testing.expectEqualStrings(postprocess_source, config.passes[1].source.?);
    try std.testing.expectEqual(@as(f32, 0.8), config.passes[1].strength);
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
    post_count: usize = 0,
    postprocess_passes: [max_postprocess_passes]PostProcessConfig = [_]PostProcessConfig{.{}} ** max_postprocess_passes,
    audio_enabled: bool = false,
    audio_target: ?[]u8 = null,
    audio_capture_mode: audio.CaptureMode = .sink,
    time_modulation: shader.TimeModulation = .{},
    visual_modulation: shader.VisualModulation = .{},

    pub fn activePostprocessPasses(self: *const FileConfig) []const PostProcessConfig {
        return self.postprocess_passes[0..self.post_count];
    }

    pub fn deinit(self: *FileConfig, allocator: Allocator) void {
        allocator.free(self.base_path);
        if (self.audio_target) |target| allocator.free(target);
        for (self.postprocess_passes[0..self.post_count]) |*pass| {
            if (pass.path) |path| allocator.free(path);
            if (pass.source) |source| allocator.free(source);
        }
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
        \\kind = "base"
        \\path = "shader.glsl"
        \\
        \\[[passes]]
        \\kind = "postprocess"
        \\effect = "pulse_zoom"
        \\strength = 1.25
        \\
        \\[[passes]]
        \\kind = postprocess
        \\path = "post.glsl"
        \\strength = 0.50
        \\
        \\[[passes]]
        \\kind = postprocess
        \\effect = glow_grade
        \\strength = 0.75
        \\
        \\[audio]
        \\enabled = true
        \\capture = "source"
        \\target = "music-monitor"
        \\
        \\[modulation]
        \\time_reactive = true
        \\time_strength = 1.75
        \\visual_reactive = true
        \\visual_strength = 0.80
        \\visual_style = "heat"
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
    const postprocess_passes = config.activePostprocessPasses();
    try std.testing.expectEqual(@as(usize, 3), postprocess_passes.len);
    try std.testing.expectEqual(PostProcessEffect.pulse_zoom, postprocess_passes[0].effect.?);
    try std.testing.expectEqual(@as(f32, 1.25), postprocess_passes[0].strength);
    const expected_post_path = try std.fs.path.resolve(allocator, &.{ ".zig-cache/tmp", tmp.sub_path[0..], "post.glsl" });
    defer allocator.free(expected_post_path);
    try std.testing.expectEqualStrings(expected_post_path, postprocess_passes[1].path.?);
    try std.testing.expectEqual(@as(?PostProcessEffect, null), postprocess_passes[1].effect);
    try std.testing.expectEqual(@as(f32, 0.50), postprocess_passes[1].strength);
    try std.testing.expectEqual(PostProcessEffect.glow_grade, postprocess_passes[2].effect.?);
    try std.testing.expectEqual(@as(f32, 0.75), postprocess_passes[2].strength);
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

test "tracked example pipeline files parse" {
    const allocator = std.testing.allocator;

    const example_paths = [_][]const u8{
        "pipelines/desktop-static.example.toml",
        "pipelines/desktop-audio.example.toml",
        "pipelines/desktop-audio-post.example.toml",
        "pipelines/desktop-audio-soft.example.toml",
        "pipelines/desktop-audio-shock.example.toml",
        "pipelines/desktop-audio-custom-post.example.toml",
        "pipelines/desktop-audio-liquid.example.toml",
        "pipelines/desktop-audio-prism-rift.example.toml",
    };

    for (example_paths) |pipeline_path| {
        var config = try loadFileConfig(allocator, pipeline_path);
        defer config.deinit(allocator);

        try std.testing.expect(config.base_path.len > 0);
        try std.testing.expect(config.post_count <= max_postprocess_passes);
    }
}

test "loadFileConfig rejects oversized pipeline files" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const oversized = try allocator.alloc(u8, max_pipeline_file_size + 1);
    defer allocator.free(oversized);
    @memset(oversized, '#');

    try tmp.dir.writeFile(.{
        .sub_path = "oversized.toml",
        .data = oversized,
    });

    const pipeline_path = try testingTmpPath(allocator, &tmp, "oversized.toml");
    defer allocator.free(pipeline_path);

    try std.testing.expectError(error.FileTooBig, loadFileConfig(allocator, pipeline_path));
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
        .sub_path = "postprocess-with-effect-and-path.toml",
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

    const postprocess_with_effect_and_path = try testingTmpPath(allocator, &tmp, "postprocess-with-effect-and-path.toml");
    defer allocator.free(postprocess_with_effect_and_path);
    try std.testing.expectError(error.InvalidPipelineSyntax, loadFileConfig(allocator, postprocess_with_effect_and_path));
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
    try tmp.dir.writeFile(.{
        .sub_path = "missing-env.toml",
        .data =
        \\[pipeline]
        \\base = "${PAPERTOY_TEST_MISSING_ENV_CE6B0CB1043B4DF3}"
        \\
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "negative-strength.toml",
        .data =
        \\[[passes]]
        \\kind = base
        \\path = "shader.glsl"
        \\
        \\[[passes]]
        \\kind = postprocess
        \\effect = pulse_zoom
        \\strength = -0.1
        \\
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "nan-strength.toml",
        .data =
        \\[[passes]]
        \\kind = base
        \\path = "shader.glsl"
        \\
        \\[[passes]]
        \\kind = postprocess
        \\effect = pulse_zoom
        \\strength = nan
        \\
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "inf-strength.toml",
        .data =
        \\[[passes]]
        \\kind = base
        \\path = "shader.glsl"
        \\
        \\[[passes]]
        \\kind = postprocess
        \\effect = pulse_zoom
        \\strength = inf
        \\
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "nan-time-strength.toml",
        .data =
        \\[pipeline]
        \\base = "shader.glsl"
        \\
        \\[modulation]
        \\time_strength = nan
        \\
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "negative-visual-strength.toml",
        .data =
        \\[pipeline]
        \\base = "shader.glsl"
        \\
        \\[modulation]
        \\visual_strength = -1.0
        \\
        ,
    });

    try expectLoadDiagnostic(allocator, &tmp, "bad-section.toml", error.InvalidPipelineSection, 1, "unknown section [bogus]");
    try expectLoadDiagnostic(allocator, &tmp, "bad-key.toml", error.InvalidPipelineKey, 2, "unknown key \"wat\" in [audio]");
    try expectLoadDiagnostic(allocator, &tmp, "bad-effect.toml", error.InvalidPipelineValue, 3, "unknown postprocess effect \"blurp\"; supported: pulse_zoom, glow_grade, heat_shift, impact_flash, shock_ring");
    try expectLoadDiagnostic(allocator, &tmp, "missing-env.toml", error.MissingEnvironmentVariable, 2, "pipeline path references an environment variable that is not set: ${PAPERTOY_TEST_MISSING_ENV_CE6B0CB1043B4DF3}");
    try expectLoadDiagnostic(allocator, &tmp, "negative-strength.toml", error.InvalidPipelineValue, 8, "invalid pass strength: expected non-negative finite number");
    try expectLoadDiagnostic(allocator, &tmp, "nan-strength.toml", error.InvalidPipelineValue, 8, "invalid pass strength: expected non-negative finite number");
    try expectLoadDiagnostic(allocator, &tmp, "inf-strength.toml", error.InvalidPipelineValue, 8, "invalid pass strength: expected non-negative finite number");
    try expectLoadDiagnostic(allocator, &tmp, "nan-time-strength.toml", error.InvalidPipelineValue, 5, "invalid value for [modulation].time_strength: expected non-negative finite number");
    try expectLoadDiagnostic(allocator, &tmp, "negative-visual-strength.toml", error.InvalidPipelineValue, 5, "invalid value for [modulation].visual_strength: expected non-negative finite number");
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
        .sub_path = "postprocess-effect-and-path.toml",
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
    try tmp.dir.writeFile(.{
        .sub_path = "postprocess-missing-effect-and-path.toml",
        .data =
        \\[[passes]]
        \\kind = base
        \\path = "shader.glsl"
        \\
        \\[[passes]]
        \\kind = postprocess
        \\
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "too-many-postprocess.toml",
        .data =
        \\[[passes]]
        \\kind = base
        \\path = "shader.glsl"
        \\
        \\[[passes]]
        \\kind = postprocess
        \\effect = pulse_zoom
        \\
        \\[[passes]]
        \\kind = postprocess
        \\effect = pulse_zoom
        \\
        \\[[passes]]
        \\kind = postprocess
        \\effect = pulse_zoom
        \\
        \\[[passes]]
        \\kind = postprocess
        \\effect = pulse_zoom
        \\
        \\[[passes]]
        \\kind = postprocess
        \\effect = pulse_zoom
        \\
        ,
    });

    try expectLoadDiagnostic(allocator, &tmp, "missing-base-path.toml", error.MissingPassPath, 1, "base pass must define path");
    try expectLoadDiagnostic(allocator, &tmp, "duplicate-base.toml", error.InvalidPipelineSyntax, 5, "pipeline can only define one base shader");
    try expectLoadDiagnostic(allocator, &tmp, "postprocess-effect-and-path.toml", error.InvalidPipelineSyntax, 7, "postprocess pass must define either effect or path, not both");
    try expectLoadDiagnostic(allocator, &tmp, "postprocess-missing-effect-and-path.toml", error.MissingPassEffect, 5, "postprocess pass must define effect or path");
    try expectLoadDiagnostic(allocator, &tmp, "too-many-postprocess.toml", error.InvalidPipelineSyntax, 21, "pipeline supports at most 4 postprocess passes");
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

pub fn loadFileConfig(allocator: Allocator, pipeline_path: []const u8) !FileConfig {
    return loadFileConfigWithDiagnostic(allocator, pipeline_path, null);
}

pub fn loadFileConfigWithDiagnostic(
    allocator: Allocator,
    pipeline_path: []const u8,
    diagnostic: ?*ParseDiagnostic,
) !FileConfig {
    if (diagnostic) |target| target.deinit(allocator);

    const source = try std.fs.cwd().readFileAlloc(allocator, pipeline_path, max_pipeline_file_size);
    defer allocator.free(source);

    var parser = try PipelineFileParser.init(allocator, pipeline_path, diagnostic);
    errdefer parser.result.deinit(allocator);
    defer parser.deinitScratch();

    return parser.parse(source);
}

const PipelineFileParser = struct {
    allocator: Allocator,
    pipeline_path: []const u8,
    diagnostic: ?*ParseDiagnostic,
    result: FileConfig,

    section: ParseSection = .root,
    base_value: ?[]u8 = null,
    base_value_line: usize = 0,
    current_pass_kind: PassKind = .base,
    current_pass_line: usize = 0,
    current_pass_path: ?[]u8 = null,
    current_pass_path_line: usize = 0,
    current_pass_effect: ?PostProcessEffect = null,
    current_pass_effect_line: usize = 0,
    current_pass_strength: f32 = 1.0,
    in_pass: bool = false,
    line_number: usize = 0,

    fn init(allocator: Allocator, pipeline_path: []const u8, diagnostic: ?*ParseDiagnostic) !PipelineFileParser {
        return .{
            .allocator = allocator,
            .pipeline_path = pipeline_path,
            .diagnostic = diagnostic,
            .result = .{ .base_path = try allocator.dupe(u8, "") },
        };
    }

    fn deinitScratch(self: *PipelineFileParser) void {
        if (self.base_value) |value| {
            self.allocator.free(value);
            self.base_value = null;
        }
        if (self.current_pass_path) |value| {
            self.allocator.free(value);
            self.current_pass_path = null;
        }
    }

    fn setDiagnostic(self: *PipelineFileParser, line: usize, comptime message_format: []const u8, args: anytype) !void {
        if (self.diagnostic) |target| {
            target.deinit(self.allocator);
            target.line = line;
            target.message = try std.fmt.allocPrint(self.allocator, message_format, args);
        }
    }

    fn parse(self: *PipelineFileParser, source: []const u8) !FileConfig {
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |line_raw| {
            self.line_number += 1;
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;

            if (line[0] == '[') {
                try self.parseSection(line);
            } else {
                try self.parseKeyValue(line);
            }
        }

        return self.finish();
    }

    fn parseSection(self: *PipelineFileParser, line: []const u8) !void {
        if (line[line.len - 1] != ']') {
            try self.setDiagnostic(self.line_number, "section header must end with ']'", .{});
            return error.InvalidPipelineSyntax;
        }

        if (self.in_pass) {
            try self.finalizePass();
            self.in_pass = false;
        }

        const is_array_table = line.len >= 4 and line[1] == '[' and line[line.len - 2] == ']';
        const header = if (is_array_table)
            std.mem.trim(u8, line[2 .. line.len - 2], " \t")
        else
            std.mem.trim(u8, line[1 .. line.len - 1], " \t");

        if (std.mem.eql(u8, header, "pipeline")) {
            if (is_array_table) {
                try self.setDiagnostic(self.line_number, "[pipeline] must be a table, not an array table", .{});
                return error.InvalidPipelineSyntax;
            }
            self.section = .pipeline;
        } else if (std.mem.eql(u8, header, "audio")) {
            if (is_array_table) {
                try self.setDiagnostic(self.line_number, "[audio] must be a table, not an array table", .{});
                return error.InvalidPipelineSyntax;
            }
            self.section = .audio;
        } else if (std.mem.eql(u8, header, "modulation")) {
            if (is_array_table) {
                try self.setDiagnostic(self.line_number, "[modulation] must be a table, not an array table", .{});
                return error.InvalidPipelineSyntax;
            }
            self.section = .modulation;
        } else if (std.mem.eql(u8, header, "passes")) {
            if (!is_array_table) {
                try self.setDiagnostic(self.line_number, "[passes] must be an array table: [[passes]]", .{});
                return error.InvalidPipelineSyntax;
            }
            self.beginPass();
        } else {
            try self.setDiagnostic(self.line_number, "unknown section [{s}]", .{header});
            return error.InvalidPipelineSection;
        }
    }

    fn beginPass(self: *PipelineFileParser) void {
        self.section = .pass;
        self.in_pass = true;
        self.current_pass_line = self.line_number;
        self.current_pass_kind = .base;
        self.current_pass_effect = null;
        self.current_pass_effect_line = 0;
        self.current_pass_strength = 1.0;
        if (self.current_pass_path) |old| {
            self.allocator.free(old);
            self.current_pass_path = null;
        }
        self.current_pass_path_line = 0;
    }

    fn parseKeyValue(self: *PipelineFileParser, line: []const u8) !void {
        const equals_index = std.mem.indexOfScalar(u8, line, '=') orelse {
            try self.setDiagnostic(self.line_number, "expected key = value", .{});
            return error.InvalidPipelineSyntax;
        };
        const key = std.mem.trim(u8, line[0..equals_index], " \t");
        const value = std.mem.trim(u8, line[equals_index + 1 ..], " \t");
        if (key.len == 0 or value.len == 0) {
            try self.setDiagnostic(self.line_number, "key and value must not be empty", .{});
            return error.InvalidPipelineSyntax;
        }

        switch (self.section) {
            .pipeline => {
                if (std.mem.eql(u8, key, "base")) {
                    if (self.base_value) |old| self.allocator.free(old);
                    self.base_value = parseString(self.allocator, value) catch |err| {
                        try self.setDiagnostic(self.line_number, "invalid value for [pipeline].base: expected quoted string", .{});
                        return err;
                    };
                    self.base_value_line = self.line_number;
                } else {
                    try self.unknownKey(key);
                    return error.InvalidPipelineKey;
                }
            },
            .audio => {
                if (std.mem.eql(u8, key, "enabled")) {
                    self.result.audio_enabled = parseBool(value) catch |err| {
                        try self.setDiagnostic(self.line_number, "invalid value for [audio].enabled: expected true or false", .{});
                        return err;
                    };
                } else if (std.mem.eql(u8, key, "capture")) {
                    self.result.audio_capture_mode = parseCaptureMode(value) catch |err| {
                        try self.setDiagnostic(self.line_number, "invalid audio capture mode \"{s}\"; supported: sink, source", .{value});
                        return err;
                    };
                } else if (std.mem.eql(u8, key, "target")) {
                    const parsed = parseString(self.allocator, value) catch |err| {
                        try self.setDiagnostic(self.line_number, "invalid value for [audio].target: expected quoted string or \"auto\"", .{});
                        return err;
                    };
                    self.setAudioTarget(parsed);
                } else {
                    try self.unknownKey(key);
                    return error.InvalidPipelineKey;
                }
            },
            .modulation => {
                if (std.mem.eql(u8, key, "time_reactive")) {
                    self.result.time_modulation.enabled = parseBool(value) catch |err| {
                        try self.setDiagnostic(self.line_number, "invalid value for [modulation].time_reactive: expected true or false", .{});
                        return err;
                    };
                } else if (std.mem.eql(u8, key, "time_strength")) {
                    self.result.time_modulation.strength = parseNonNegativeFiniteFloat(value) catch |err| {
                        try self.setDiagnostic(self.line_number, "invalid value for [modulation].time_strength: expected non-negative finite number", .{});
                        return err;
                    };
                } else if (std.mem.eql(u8, key, "visual_reactive")) {
                    self.result.visual_modulation.enabled = parseBool(value) catch |err| {
                        try self.setDiagnostic(self.line_number, "invalid value for [modulation].visual_reactive: expected true or false", .{});
                        return err;
                    };
                } else if (std.mem.eql(u8, key, "visual_strength")) {
                    self.result.visual_modulation.strength = parseNonNegativeFiniteFloat(value) catch |err| {
                        try self.setDiagnostic(self.line_number, "invalid value for [modulation].visual_strength: expected non-negative finite number", .{});
                        return err;
                    };
                } else if (std.mem.eql(u8, key, "visual_style")) {
                    self.result.visual_modulation.style = parseVisualStyle(value) catch |err| {
                        try self.setDiagnostic(self.line_number, "invalid visual style \"{s}\"; supported: blend, pulse, drift, strobe, heat", .{value});
                        return err;
                    };
                } else {
                    try self.unknownKey(key);
                    return error.InvalidPipelineKey;
                }
            },
            .pass => {
                if (std.mem.eql(u8, key, "kind")) {
                    self.current_pass_kind = parsePassKind(value) catch |err| {
                        try self.setDiagnostic(self.line_number, "invalid pass kind \"{s}\"; supported: base, postprocess", .{value});
                        return err;
                    };
                } else if (std.mem.eql(u8, key, "path")) {
                    if (self.current_pass_path) |old| self.allocator.free(old);
                    self.current_pass_path = parseString(self.allocator, value) catch |err| {
                        try self.setDiagnostic(self.line_number, "invalid pass path: expected quoted string", .{});
                        return err;
                    };
                    self.current_pass_path_line = self.line_number;
                } else if (std.mem.eql(u8, key, "effect")) {
                    self.current_pass_effect = parsePostProcessEffect(value) catch |err| {
                        try self.setDiagnostic(self.line_number, "unknown postprocess effect \"{s}\"; supported: {s}", .{ value, effects.supportedConfigNames() });
                        return err;
                    };
                    self.current_pass_effect_line = self.line_number;
                } else if (std.mem.eql(u8, key, "strength")) {
                    self.current_pass_strength = parsePassStrength(value) catch |err| {
                        try self.setDiagnostic(self.line_number, "invalid pass strength: expected non-negative finite number", .{});
                        return err;
                    };
                } else {
                    try self.unknownKey(key);
                    return error.InvalidPipelineKey;
                }
            },
            .root => {
                try self.setDiagnostic(self.line_number, "key \"{s}\" must be inside a section", .{key});
                return error.InvalidPipelineSyntax;
            },
        }
    }

    fn setAudioTarget(self: *PipelineFileParser, parsed: []u8) void {
        if (std.mem.eql(u8, parsed, "auto")) {
            self.allocator.free(parsed);
            if (self.result.audio_target) |old| self.allocator.free(old);
            self.result.audio_target = null;
        } else {
            if (self.result.audio_target) |old| self.allocator.free(old);
            self.result.audio_target = parsed;
        }
    }

    fn unknownKey(self: *PipelineFileParser, key: []const u8) !void {
        try self.setDiagnostic(self.line_number, "unknown key \"{s}\" in {s}", .{ key, self.section.label() });
    }

    fn finish(self: *PipelineFileParser) !FileConfig {
        if (self.in_pass) {
            try self.finalizePass();
            self.in_pass = false;
        }

        const base = self.base_value orelse {
            try self.setDiagnostic(@max(self.line_number, 1), "pipeline file must define a base shader using [pipeline].base or a base pass path", .{});
            return error.MissingBaseShader;
        };
        const resolved_base_path = resolvePipelinePath(self.allocator, self.pipeline_path, base) catch |err| {
            if (err == error.MissingEnvironmentVariable) {
                try self.setDiagnostic(self.base_value_line, "pipeline path references an environment variable that is not set: {s}", .{base});
            }
            return err;
        };
        self.allocator.free(self.result.base_path);
        self.result.base_path = resolved_base_path;
        return self.result;
    }

    fn finalizePass(self: *PipelineFileParser) !void {
        switch (self.current_pass_kind) {
            .base => try self.finalizeBasePass(),
            .postprocess => try self.finalizePostProcessPass(),
        }

        self.current_pass_effect = null;
        self.current_pass_strength = 1.0;
    }

    fn finalizeBasePass(self: *PipelineFileParser) !void {
        const path = self.current_pass_path orelse {
            try self.setDiagnostic(self.current_pass_line, "base pass must define path", .{});
            return error.MissingPassPath;
        };
        if (self.current_pass_effect != null) {
            try self.setDiagnostic(self.current_pass_effect_line, "base pass cannot define effect", .{});
            return error.InvalidPipelineSyntax;
        }
        if (self.base_value != null) {
            try self.setDiagnostic(self.current_pass_line, "pipeline can only define one base shader", .{});
            return error.InvalidPipelineSyntax;
        }

        self.base_value = path;
        self.base_value_line = self.current_pass_path_line;
        self.current_pass_path = null;
    }

    fn finalizePostProcessPass(self: *PipelineFileParser) !void {
        if (self.current_pass_effect != null and self.current_pass_path != null) {
            try self.setDiagnostic(self.current_pass_path_line, "postprocess pass must define either effect or path, not both", .{});
            return error.InvalidPipelineSyntax;
        }
        if (self.current_pass_effect == null and self.current_pass_path == null) {
            try self.setDiagnostic(self.current_pass_line, "postprocess pass must define effect or path", .{});
            return error.MissingPassEffect;
        }
        if (self.result.post_count >= max_postprocess_passes) {
            try self.setDiagnostic(self.current_pass_line, "pipeline supports at most {} postprocess passes", .{max_postprocess_passes});
            return error.InvalidPipelineSyntax;
        }
        const resolved_path = if (self.current_pass_path) |path| resolved: {
            const resolved = resolvePipelinePath(self.allocator, self.pipeline_path, path) catch |err| {
                if (err == error.MissingEnvironmentVariable) {
                    try self.setDiagnostic(self.current_pass_path_line, "pipeline path references an environment variable that is not set: {s}", .{path});
                }
                return err;
            };
            self.allocator.free(path);
            self.current_pass_path = null;
            break :resolved resolved;
        } else null;
        self.result.postprocess_passes[self.result.post_count] = .{
            .effect = self.current_pass_effect,
            .path = resolved_path,
            .strength = self.current_pass_strength,
        };
        self.result.post_count += 1;
    }
};

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
    const parsed = try parseIdentifierValue(value);
    if (std.mem.eql(u8, parsed, "sink")) return .sink;
    if (std.mem.eql(u8, parsed, "source")) return .source;
    return error.InvalidPipelineValue;
}

fn parseVisualStyle(value: []const u8) !shader.VisualStyle {
    const parsed = try parseIdentifierValue(value);
    if (std.mem.eql(u8, parsed, "blend")) return .blend;
    if (std.mem.eql(u8, parsed, "pulse")) return .pulse;
    if (std.mem.eql(u8, parsed, "drift")) return .drift;
    if (std.mem.eql(u8, parsed, "strobe")) return .strobe;
    if (std.mem.eql(u8, parsed, "heat")) return .heat;
    return error.InvalidPipelineValue;
}

fn parsePassKind(value: []const u8) !PassKind {
    const parsed = try parseIdentifierValue(value);
    if (std.mem.eql(u8, parsed, "base")) return .base;
    if (std.mem.eql(u8, parsed, "postprocess")) return .postprocess;
    return error.InvalidPipelineValue;
}

fn parsePostProcessEffect(value: []const u8) !PostProcessEffect {
    const parsed = try parseIdentifierValue(value);
    return PostProcessEffect.parseConfigName(parsed) orelse error.InvalidPipelineValue;
}

fn parseIdentifierValue(value: []const u8) ![]const u8 {
    if (value.len == 0) return error.InvalidPipelineValue;
    if (value[0] == '"') {
        if (value.len < 2 or value[value.len - 1] != '"') return error.InvalidPipelineValue;
        const inner = value[1 .. value.len - 1];
        if (std.mem.indexOfScalar(u8, inner, '\\') != null) return error.InvalidPipelineValue;
        return inner;
    }
    return value;
}

fn parsePassStrength(value: []const u8) !f32 {
    return parseNonNegativeFiniteFloat(value);
}

fn parseNonNegativeFiniteFloat(value: []const u8) !f32 {
    const parsed = try parseFloat(value);
    if (!std.math.isFinite(parsed) or parsed < 0.0) return error.InvalidPipelineValue;
    return parsed;
}

fn expandEnvironmentReference(allocator: Allocator, value: []const u8) ![]u8 {
    if (value.len >= 3 and value[0] == '$' and value[1] == '{' and value[value.len - 1] == '}') {
        const env_name = value[2 .. value.len - 1];
        return std.process.getEnvVarOwned(allocator, env_name) catch return error.MissingEnvironmentVariable;
    }
    return allocator.dupe(u8, value);
}
