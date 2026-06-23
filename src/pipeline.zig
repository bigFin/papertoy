const std = @import("std");
const Allocator = std.mem.Allocator;

const audio = @import("audio.zig");
const AudioSnapshot = audio.Snapshot;
const effects = @import("effects.zig");
const gl = @import("zgl");
const pipeline_config = @import("pipeline_config.zig");
const postprocess = @import("postprocess.zig");
const shader = @import("shader.zig");

pub const PipelineConfig = pipeline_config.PipelineConfig;
pub const PostProcessEffect = effects.PostProcessEffect;

pub const PipelineRunner = struct {
    base_pass: *shader.Shader,
    post_pass: ?postprocess.PostProcessPass = null,
    offscreen_target: ?postprocess.RenderTarget = null,

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

            self.offscreen_target = try postprocess.RenderTarget.init(config.resolution);
            errdefer if (self.offscreen_target) |*target| target.deinit();

            self.post_pass = try postprocess.PostProcessPass.init(allocator, config.resolution, post_config.effect.?);
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
