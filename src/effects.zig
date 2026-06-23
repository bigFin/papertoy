const std = @import("std");

pub const PostProcessEffect = enum(i32) {
    pulse_zoom = 0,

    pub fn parseConfigName(name: []const u8) ?PostProcessEffect {
        if (std.mem.eql(u8, name, "pulse_zoom")) return .pulse_zoom;
        return null;
    }

    pub fn configName(self: PostProcessEffect) []const u8 {
        return switch (self) {
            .pulse_zoom => "pulse_zoom",
        };
    }

    pub fn shaderValue(self: PostProcessEffect) i32 {
        return @intFromEnum(self);
    }
};

test "PostProcessEffect maps config names and shader values" {
    const effect = PostProcessEffect.parseConfigName("pulse_zoom") orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(PostProcessEffect.pulse_zoom, effect);
    try std.testing.expectEqualStrings("pulse_zoom", effect.configName());
    try std.testing.expectEqual(@as(i32, 0), effect.shaderValue());
    try std.testing.expectEqual(@as(?PostProcessEffect, null), PostProcessEffect.parseConfigName("unknown"));
}
