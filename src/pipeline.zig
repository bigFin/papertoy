const std = @import("std");
const Allocator = std.mem.Allocator;

const AudioSnapshot = @import("audio.zig").Snapshot;
const shader = @import("shader.zig");

pub const PipelineConfig = struct {
    resolution: shader.Resolution,
    frame_rate: u32,
    source: []const u8,
    time_modulation: shader.TimeModulation = .{},
    visual_modulation: shader.VisualModulation = .{},
};

/// Current pipeline runner implementation.
///
/// This starts as a thin wrapper around the existing single-shader render path so
/// the runtime can migrate toward a real multi-pass pipeline without keeping two
/// rendering architectures alive.
pub const PipelineRunner = struct {
    base_pass: *shader.Shader,

    pub fn createLegacy(allocator: Allocator, config: PipelineConfig) !PipelineRunner {
        return .{
            .base_pass = try shader.Shader.create(
                allocator,
                config.source,
                config.resolution,
                config.frame_rate,
                config.time_modulation,
                config.visual_modulation,
            ),
        };
    }

    pub fn destroy(self: *PipelineRunner, allocator: Allocator) void {
        self.base_pass.destroy(allocator);
    }

    pub fn resize(self: *PipelineRunner, resolution: shader.Resolution) void {
        self.base_pass.resolution = resolution;
    }

    pub fn render(self: *PipelineRunner, audio: AudioSnapshot) !void {
        try self.base_pass.render(audio);
    }

    pub fn frame(self: *const PipelineRunner) u32 {
        return self.base_pass.frame;
    }
};
