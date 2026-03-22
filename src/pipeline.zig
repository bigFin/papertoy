const std = @import("std");
const Allocator = std.mem.Allocator;

const audio = @import("audio.zig");
const AudioSnapshot = @import("audio.zig").Snapshot;
const shader = @import("shader.zig");

pub const PassKind = enum {
    base,
};

pub const PassConfig = struct {
    kind: PassKind = .base,
    source: []const u8,
    time_modulation: shader.TimeModulation = .{},
    visual_modulation: shader.VisualModulation = .{},
};

pub const PipelineConfig = struct {
    resolution: shader.Resolution,
    frame_rate: u32,
    passes: []const PassConfig,

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
            .passes = &.{
                .{
                    .kind = .base,
                    .source = source,
                    .time_modulation = time_modulation,
                    .visual_modulation = visual_modulation,
                },
            },
        };
    }
};

pub const FileConfig = struct {
    base_path: []u8,
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

    var section: enum { root, pipeline, audio, modulation } = .root;
    var base_value: ?[]u8 = null;
    defer if (base_value) |value| allocator.free(value);

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[') {
            if (line[line.len - 1] != ']') return error.InvalidPipelineSyntax;
            const header = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            if (std.mem.eql(u8, header, "pipeline")) {
                section = .pipeline;
            } else if (std.mem.eql(u8, header, "audio")) {
                section = .audio;
            } else if (std.mem.eql(u8, header, "modulation")) {
                section = .modulation;
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
            .root => return error.InvalidPipelineSyntax,
        }
    }

    const base = base_value orelse return error.MissingBaseShader;
    allocator.free(result.base_path);
    result.base_path = try resolvePipelinePath(allocator, pipeline_path, base);
    return result;
}

fn resolvePipelinePath(allocator: Allocator, pipeline_path: []const u8, target: []const u8) ![]u8 {
    const expanded_target = try expandEnvironmentReference(allocator, target);
    defer if (!std.mem.eql(u8, expanded_target, target)) allocator.free(expanded_target);

    if (std.fs.path.isAbsolute(expanded_target)) return allocator.dupe(u8, expanded_target);
    const base_dir = std.fs.path.dirname(pipeline_path) orelse ".";
    return std.fs.path.resolve(allocator, &.{ base_dir, expanded_target });
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

/// Current pipeline runner implementation.
///
/// This starts as a thin wrapper around the existing single-shader render path so
/// the runtime can migrate toward a real multi-pass pipeline without keeping two
/// rendering architectures alive.
pub const PipelineRunner = struct {
    base_pass: *shader.Shader,

    pub fn createLegacy(allocator: Allocator, config: PipelineConfig) !PipelineRunner {
        const base_config = config.passes[0];
        return .{
            .base_pass = try shader.Shader.create(
                allocator,
                base_config.source,
                config.resolution,
                config.frame_rate,
                base_config.time_modulation,
                base_config.visual_modulation,
            ),
        };
    }

    pub fn destroy(self: *PipelineRunner, allocator: Allocator) void {
        self.base_pass.destroy(allocator);
    }

    pub fn resize(self: *PipelineRunner, resolution: shader.Resolution) void {
        self.base_pass.resolution = resolution;
    }

    pub fn render(self: *PipelineRunner, snapshot: AudioSnapshot) !void {
        try self.base_pass.render(snapshot);
    }

    pub fn frame(self: *const PipelineRunner) u32 {
        return self.base_pass.frame;
    }
};
