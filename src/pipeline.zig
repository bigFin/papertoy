const std = @import("std");
const Allocator = std.mem.Allocator;

const audio = @import("audio.zig");
const AudioSnapshot = audio.Snapshot;
const gl = @import("zgl");
const pipeline_config = @import("pipeline_config.zig");
const postprocess = @import("postprocess.zig");
const shader = @import("shader.zig");

pub const PipelineConfig = pipeline_config.PipelineConfig;

pub const PipelineRunner = struct {
    base_pass: *shader.Shader,
    post_passes: ?[]postprocess.PostProcessPass = null,
    post_pass_count: usize = 0,
    post_program: ?postprocess.PostProcessProgram = null,
    render_targets: ?[]postprocess.RenderTarget = null,
    render_target_count: usize = 0,

    pub fn create(allocator: Allocator, config: PipelineConfig) !PipelineRunner {
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
        errdefer self.destroy(allocator);

        const post_count = passes.len - 1;
        if (post_count == 0) return self;

        const target_count: usize = if (post_count > 1) 2 else 1;
        self.render_targets = try allocator.alloc(postprocess.RenderTarget, target_count);
        for (self.render_targets.?[0..target_count]) |*target| {
            target.* = try postprocess.RenderTarget.init(config.resolution);
            self.render_target_count += 1;
        }

        self.post_program = try postprocess.PostProcessProgram.init(allocator);

        self.post_passes = try allocator.alloc(postprocess.PostProcessPass, post_count);
        for (passes[1..], 0..) |post_config, i| {
            if (post_config.kind != .postprocess or post_config.effect == null) return error.InvalidPipelineValue;

            self.post_passes.?[i] = postprocess.PostProcessPass.init(config.resolution, post_config.effect.?);
            self.post_pass_count += 1;
            self.post_passes.?[i].strength = post_config.strength;
        }

        return self;
    }

    pub fn destroy(self: *PipelineRunner, allocator: Allocator) void {
        if (self.post_passes) |passes| {
            allocator.free(passes);
            self.post_passes = null;
            self.post_pass_count = 0;
        }
        if (self.post_program) |*program| {
            program.deinit(allocator);
            self.post_program = null;
        }
        if (self.render_targets) |targets| {
            for (targets[0..self.render_target_count]) |*target| target.deinit();
            allocator.free(targets);
            self.render_targets = null;
            self.render_target_count = 0;
        }
        self.base_pass.destroy(allocator);
    }

    pub fn resize(self: *PipelineRunner, resolution: shader.Resolution) !void {
        self.base_pass.resolution = resolution;
        if (self.render_targets) |targets| {
            for (targets[0..self.render_target_count]) |*target| try target.resize(resolution);
        }
        if (self.post_passes) |passes| {
            for (passes[0..self.post_pass_count]) |*pass| pass.resolution = resolution;
        }
    }

    pub fn render(self: *PipelineRunner, snapshot: AudioSnapshot) !void {
        if (self.post_pass_count == 0) {
            try self.base_pass.render(snapshot);
            return;
        }

        const post_passes = self.post_passes.?[0..self.post_pass_count];
        const post_program = &(self.post_program.?);
        const targets = self.render_targets.?[0..self.render_target_count];

        bindRenderTarget(&targets[0]);
        try self.base_pass.render(snapshot);

        var input_index: usize = 0;
        for (post_passes, 0..) |*pass, i| {
            const is_final_pass = i + 1 == post_passes.len;
            if (is_final_pass) {
                bindDefaultFramebuffer(targets[input_index].resolution);
            } else {
                const output_index: usize = if (input_index == 0) 1 else 0;
                bindRenderTarget(&targets[output_index]);
                try pass.render(post_program, targets[input_index].texture, snapshot);
                input_index = output_index;
                continue;
            }

            try pass.render(post_program, targets[input_index].texture, snapshot);
        }
    }

    pub fn frame(self: *const PipelineRunner) u32 {
        return self.base_pass.frame;
    }

    fn bindRenderTarget(target: *postprocess.RenderTarget) void {
        target.bind();
        gl.viewport(0, 0, target.resolution.width, target.resolution.height);
        gl.clearColor(0, 0, 0, 1);
        gl.clear(.{ .color = true });
    }

    fn bindDefaultFramebuffer(resolution: shader.Resolution) void {
        gl.bindFramebuffer(.invalid, .buffer);
        gl.viewport(0, 0, resolution.width, resolution.height);
    }
};
