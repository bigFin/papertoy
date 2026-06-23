const std = @import("std");

pub fn supportedConfigNames() []const u8 {
    return "pulse_zoom, glow_grade, heat_shift, impact_flash, shock_ring";
}

pub const PostProcessEffectInfo = struct {
    effect: PostProcessEffect,
    summary: []const u8,
    drivers: []const u8,
    good_use: []const u8,
};

pub const PostProcessEffect = enum(i32) {
    pulse_zoom = 0,
    glow_grade = 1,
    heat_shift = 2,
    impact_flash = 3,
    shock_ring = 4,

    pub fn parseConfigName(name: []const u8) ?PostProcessEffect {
        if (std.mem.eql(u8, name, "pulse_zoom")) return .pulse_zoom;
        if (std.mem.eql(u8, name, "glow_grade")) return .glow_grade;
        if (std.mem.eql(u8, name, "heat_shift")) return .heat_shift;
        if (std.mem.eql(u8, name, "impact_flash")) return .impact_flash;
        if (std.mem.eql(u8, name, "shock_ring")) return .shock_ring;
        return null;
    }

    pub fn configName(self: PostProcessEffect) []const u8 {
        return switch (self) {
            .pulse_zoom => "pulse_zoom",
            .glow_grade => "glow_grade",
            .heat_shift => "heat_shift",
            .impact_flash => "impact_flash",
            .shock_ring => "shock_ring",
        };
    }

    pub fn shaderValue(self: PostProcessEffect) i32 {
        return @intFromEnum(self);
    }
};

const post_process_effect_infos = [_]PostProcessEffectInfo{
    .{
        .effect = .pulse_zoom,
        .summary = "zoom, contrast, and subtle swirl",
        .drivers = "impact, energy, brightness",
        .good_use = "first pass after the base shader",
    },
    .{
        .effect = .glow_grade,
        .summary = "glow, saturation, and contrast lift",
        .drivers = "energy, brightness",
        .good_use = "grading and bloom-like polish",
    },
    .{
        .effect = .heat_shift,
        .summary = "warm chromatic shimmer",
        .drivers = "bass, impact, energy",
        .good_use = "color movement and heat haze",
    },
    .{
        .effect = .impact_flash,
        .summary = "flash, ring, and vignette",
        .drivers = "beat, impact, brightness",
        .good_use = "beat accents near the end of a chain",
    },
    .{
        .effect = .shock_ring,
        .summary = "radial ripple and color separation",
        .drivers = "beat, impact, drive, brightness",
        .good_use = "deliberately trippy accent chains",
    },
};

pub fn postProcessEffectInfos() []const PostProcessEffectInfo {
    return post_process_effect_infos[0..];
}

test "PostProcessEffect maps config names and shader values" {
    try std.testing.expectEqualStrings("pulse_zoom, glow_grade, heat_shift, impact_flash, shock_ring", supportedConfigNames());

    const cases = [_]struct {
        name: []const u8,
        effect: PostProcessEffect,
        shader_value: i32,
    }{
        .{ .name = "pulse_zoom", .effect = .pulse_zoom, .shader_value = 0 },
        .{ .name = "glow_grade", .effect = .glow_grade, .shader_value = 1 },
        .{ .name = "heat_shift", .effect = .heat_shift, .shader_value = 2 },
        .{ .name = "impact_flash", .effect = .impact_flash, .shader_value = 3 },
        .{ .name = "shock_ring", .effect = .shock_ring, .shader_value = 4 },
    };

    for (cases) |case| {
        const effect = PostProcessEffect.parseConfigName(case.name) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(case.effect, effect);
        try std.testing.expectEqualStrings(case.name, effect.configName());
        try std.testing.expectEqual(case.shader_value, effect.shaderValue());
    }

    try std.testing.expectEqual(@as(?PostProcessEffect, null), PostProcessEffect.parseConfigName("unknown"));
}

test "postprocess effect metadata covers every effect" {
    const infos = postProcessEffectInfos();
    try std.testing.expectEqual(@as(usize, 5), infos.len);

    for (infos) |info| {
        try std.testing.expectEqual(info.effect, PostProcessEffect.parseConfigName(info.effect.configName()).?);
        try std.testing.expect(info.summary.len > 0);
        try std.testing.expect(info.drivers.len > 0);
        try std.testing.expect(info.good_use.len > 0);
    }
}
