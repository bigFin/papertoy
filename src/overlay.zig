const std = @import("std");

const audio = @import("audio.zig");
const gl = @import("zgl");
const shader = @import("shader.zig");

const glb = gl.binding;

const bar_count = 9;

const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

const Bar = struct {
    frame: Rect,
    fill: Rect,
    value: f32,
};

const Layout = struct {
    panel: Rect,
    active: Rect,
    bars: [bar_count]Bar,
};

pub fn renderAudioOverlay(snapshot: audio.Snapshot, resolution: shader.Resolution) void {
    const layout = computeLayout(snapshot, resolution);

    glb.enable(glb.SCISSOR_TEST);
    defer glb.disable(glb.SCISSOR_TEST);

    clearRect(layout.panel, .{ 0.02, 0.025, 0.03, 0.86 });
    clearRect(layout.active, if (snapshot.active > 0.0)
        .{ 0.35, 0.95, 0.68, 1.0 }
    else
        .{ 0.17, 0.20, 0.23, 1.0 });

    for (layout.bars, 0..) |bar, i| {
        clearRect(bar.frame, .{ 0.10, 0.115, 0.13, 1.0 });
        clearRect(bar.fill, barColor(i, bar.value));
    }
}

fn computeLayout(snapshot: audio.Snapshot, resolution: shader.Resolution) Layout {
    const width: i32 = @intCast(resolution.width);
    const height: i32 = @intCast(resolution.height);
    const scale: i32 = if (width >= 3000 or height >= 1800) 2 else 1;

    const margin = 18 * scale;
    const panel_width = 244 * scale;
    const panel_height = 112 * scale;
    const active_size = 10 * scale;
    const bar_width = 18 * scale;
    const bar_gap = 7 * scale;
    const bar_max_height = 72 * scale;
    const bar_y = margin + 16 * scale;
    const bar_x = margin + 16 * scale;

    var bars: [bar_count]Bar = undefined;
    const values = [_]f32{
        snapshot.level,
        snapshot.bass,
        snapshot.mid,
        snapshot.treble,
        snapshot.beat,
        snapshot.impact,
        snapshot.energy,
        snapshot.drive,
        snapshot.brightness,
    };

    for (&bars, values, 0..) |*bar, value, i| {
        const clamped = clamp01(value);
        const fill_height: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(bar_max_height)) * clamped));
        const x = bar_x + @as(i32, @intCast(i)) * (bar_width + bar_gap);
        bar.* = .{
            .frame = .{ .x = x, .y = bar_y, .width = bar_width, .height = bar_max_height },
            .fill = .{ .x = x, .y = bar_y, .width = bar_width, .height = @max(1, fill_height) },
            .value = clamped,
        };
    }

    return .{
        .panel = .{ .x = margin, .y = margin, .width = panel_width, .height = panel_height },
        .active = .{ .x = margin + panel_width - active_size - 12 * scale, .y = margin + panel_height - active_size - 12 * scale, .width = active_size, .height = active_size },
        .bars = bars,
    };
}

fn clearRect(rect: Rect, color: [4]f32) void {
    if (rect.width <= 0 or rect.height <= 0) return;

    glb.scissor(rect.x, rect.y, rect.width, rect.height);
    glb.clearColor(color[0], color[1], color[2], color[3]);
    glb.clear(glb.COLOR_BUFFER_BIT);
}

fn barColor(index: usize, value: f32) [4]f32 {
    const intensity = 0.45 + clamp01(value) * 0.55;
    return switch (index) {
        0 => .{ 0.44 * intensity, 0.76 * intensity, 0.96 * intensity, 1.0 },
        1 => .{ 0.93 * intensity, 0.48 * intensity, 0.28 * intensity, 1.0 },
        2 => .{ 0.62 * intensity, 0.84 * intensity, 0.36 * intensity, 1.0 },
        3 => .{ 0.82 * intensity, 0.62 * intensity, 0.98 * intensity, 1.0 },
        4 => .{ 0.98 * intensity, 0.86 * intensity, 0.32 * intensity, 1.0 },
        5 => .{ 0.98 * intensity, 0.42 * intensity, 0.36 * intensity, 1.0 },
        6 => .{ 0.42 * intensity, 0.88 * intensity, 0.68 * intensity, 1.0 },
        7 => .{ 0.50 * intensity, 0.65 * intensity, 1.00 * intensity, 1.0 },
        else => .{ 0.95 * intensity, 0.72 * intensity, 0.42 * intensity, 1.0 },
    };
}

fn clamp01(value: f32) f32 {
    return std.math.clamp(value, 0.0, 1.0);
}

test "overlay layout clamps values and scales for large outputs" {
    const layout = computeLayout(.{
        .level = -1.0,
        .bass = 0.5,
        .mid = 2.0,
        .active = 1.0,
    }, .{ .width = 3840, .height = 2160 });

    try std.testing.expectEqual(@as(i32, 36), layout.panel.x);
    try std.testing.expectEqual(@as(i32, 488), layout.panel.width);
    try std.testing.expectEqual(@as(f32, 0.0), layout.bars[0].value);
    try std.testing.expectEqual(@as(f32, 0.5), layout.bars[1].value);
    try std.testing.expectEqual(@as(f32, 1.0), layout.bars[2].value);
    try std.testing.expect(layout.bars[2].fill.height <= layout.bars[2].frame.height);
}
