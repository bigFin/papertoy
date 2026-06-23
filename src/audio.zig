const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Snapshot = struct {
    level: f32 = 0,
    bass: f32 = 0,
    mid: f32 = 0,
    treble: f32 = 0,
    beat: f32 = 0,
    active: f32 = 0,
    impact: f32 = 0,
    energy: f32 = 0,
    drive: f32 = 0,
    brightness: f32 = 0,
};

/// Render-facing vec4 groups derived from an audio snapshot.
/// Keep this mapping centralized so base shaders and postprocess passes agree.
pub const UniformPayload = struct {
    bands: [4]f32,
    state: [4]f32,
    visualizer: [4]f32,

    pub fn fromSnapshot(snapshot: Snapshot) UniformPayload {
        return .{
            .bands = .{ snapshot.level, snapshot.bass, snapshot.mid, snapshot.treble },
            .state = .{ snapshot.beat, snapshot.active, 0, 0 },
            .visualizer = .{ snapshot.impact, snapshot.energy, snapshot.drive, snapshot.brightness },
        };
    }

    pub fn visualFx(self: UniformPayload, strength: f32) [4]f32 {
        return .{
            clamp01Range(self.impact() * strength, 1.5),
            clamp01Range(self.drive() * strength * 0.85, 1.2),
            clamp01Range(self.brightness() * strength * 0.75, 1.2),
            clamp01Range(self.energy() * strength * 0.65, 1.0),
        };
    }

    pub fn withEffectStrength(self: UniformPayload, strength: f32) UniformPayload {
        var result = self;
        result.visualizer = .{
            self.impact() * strength,
            self.energy() * strength,
            self.drive(),
            self.brightness() * strength,
        };
        return result;
    }

    pub fn impact(self: UniformPayload) f32 {
        return self.visualizer[0];
    }

    pub fn energy(self: UniformPayload) f32 {
        return self.visualizer[1];
    }

    pub fn drive(self: UniformPayload) f32 {
        return self.visualizer[2];
    }

    pub fn brightness(self: UniformPayload) f32 {
        return self.visualizer[3];
    }
};

fn clamp01Range(value: f32, max_value: f32) f32 {
    return std.math.clamp(value, 0, max_value);
}

fn expectVec4Approx(expected: [4]f32, actual: [4]f32) !void {
    for (expected, actual) |expected_value, actual_value| {
        try std.testing.expectApproxEqAbs(expected_value, actual_value, 0.0001);
    }
}

pub const Config = struct {
    enabled: bool = false,
    target: ?[]const u8 = null,
    capture_mode: CaptureMode = .sink,
};

pub const CaptureMode = enum {
    sink,
    source,
};

const target_refresh_interval_ns = 2 * std.time.ns_per_s;
const failure_retry_interval_ns = 10 * std.time.ns_per_s;

const SharedState = struct {
    mutex: std.Thread.Mutex = .{},
    snapshot: Snapshot = .{},
    terminated: bool = false,
};

const CaptureBackend = struct {
    child: std.process.Child,
    thread: std.Thread,
    shared: *SharedState,
};

const AnalyzerState = struct {
    low_lp: f32 = 0,
    mid_lp: f32 = 0,
    level_smooth: f32 = 0,
    bass_smooth: f32 = 0,
    mid_smooth: f32 = 0,
    treble_smooth: f32 = 0,
    beat: f32 = 0,
    level_baseline: f32 = 0,
    active_hold: f32 = 0,
    energy_smooth: f32 = 0,
    drive_smooth: f32 = 0,
    impact_smooth: f32 = 0,
    brightness_smooth: f32 = 0,

    fn update(self: *AnalyzerState, shared: *SharedState, bytes: []const u8) void {
        const frame_size = 4; // stereo s16le
        const usable_len = bytes.len - (bytes.len % frame_size);
        if (usable_len == 0) return;

        var level_energy: f32 = 0;
        var bass_energy: f32 = 0;
        var mid_energy: f32 = 0;
        var treble_energy: f32 = 0;
        var frame_count: usize = 0;

        var i: usize = 0;
        while (i < usable_len) : (i += frame_size) {
            const left = sampleToFloat(bytes[i], bytes[i + 1]);
            const right = sampleToFloat(bytes[i + 2], bytes[i + 3]);
            const mono = 0.5 * (left + right);

            self.low_lp += 0.025 * (mono - self.low_lp);
            self.mid_lp += 0.18 * (mono - self.mid_lp);

            const bass = self.low_lp;
            const mid = self.mid_lp - self.low_lp;
            const treble = mono - self.mid_lp;

            level_energy += mono * mono;
            bass_energy += bass * bass;
            mid_energy += mid * mid;
            treble_energy += treble * treble;
            frame_count += 1;
        }

        if (frame_count == 0) return;
        const sample_count: f32 = @floatFromInt(frame_count);

        const level = normalizeRms(level_energy / sample_count, 4.0);
        const bass = normalizeRms(bass_energy / sample_count, 6.0);
        const mid = normalizeRms(mid_energy / sample_count, 6.0);
        const treble = normalizeRms(treble_energy / sample_count, 8.0);

        self.level_smooth = smooth(self.level_smooth, level, 0.35, 0.08);
        self.bass_smooth = smooth(self.bass_smooth, bass, 0.35, 0.10);
        self.mid_smooth = smooth(self.mid_smooth, mid, 0.35, 0.10);
        self.treble_smooth = smooth(self.treble_smooth, treble, 0.35, 0.10);

        self.level_baseline = (self.level_baseline * 0.985) + (self.level_smooth * 0.015);

        const onset = @max(0.0, self.level_smooth - (self.level_baseline * 1.35));
        self.beat = @max(self.beat * 0.84, clamp01(onset * 6.0));

        const impact = clamp01((self.bass_smooth * 0.75) + (self.beat * 1.15));
        const energy = clamp01((self.level_smooth * 0.55) + (self.mid_smooth * 0.20) + (self.bass_smooth * 0.25));
        const drive_target = clamp01((self.level_smooth * 0.35) + (self.bass_smooth * 0.35) + (self.mid_smooth * 0.30));
        const brightness = clamp01((self.treble_smooth * 0.75) + (self.mid_smooth * 0.25));

        self.impact_smooth = smooth(self.impact_smooth, impact, 0.45, 0.16);
        self.energy_smooth = smooth(self.energy_smooth, energy, 0.20, 0.05);
        self.drive_smooth = smooth(self.drive_smooth, drive_target, 0.08, 0.02);
        self.brightness_smooth = smooth(self.brightness_smooth, brightness, 0.18, 0.06);

        if (self.level_smooth > 0.025 or self.beat > 0.05) {
            self.active_hold = 1.0;
        } else {
            self.active_hold = @max(0.0, self.active_hold - 0.05);
        }

        shared.mutex.lock();
        defer shared.mutex.unlock();
        shared.snapshot = .{
            .level = self.level_smooth,
            .bass = self.bass_smooth,
            .mid = self.mid_smooth,
            .treble = self.treble_smooth,
            .beat = self.beat,
            .active = if (self.active_hold > 0) 1 else 0,
            .impact = self.impact_smooth,
            .energy = self.energy_smooth,
            .drive = self.drive_smooth,
            .brightness = self.brightness_smooth,
        };
    }

    fn sampleToFloat(lo: u8, hi: u8) f32 {
        const sample = @as(i16, @bitCast(@as(u16, lo) | (@as(u16, hi) << 8)));
        return @as(f32, @floatFromInt(sample)) / 32768.0;
    }

    fn normalizeRms(mean_square: f32, gain: f32) f32 {
        return clamp01(std.math.sqrt(mean_square) * gain);
    }

    fn smooth(current: f32, target: f32, attack: f32, release: f32) f32 {
        const factor = if (target > current) attack else release;
        return current + ((target - current) * factor);
    }

    fn clamp01(value: f32) f32 {
        return std.math.clamp(value, 0, 1);
    }
};

fn snapshotFromAnalyzer(analyzer: *AnalyzerState, bytes: []const u8) Snapshot {
    var shared: SharedState = .{};
    analyzer.update(&shared, bytes);
    shared.mutex.lock();
    defer shared.mutex.unlock();
    return shared.snapshot;
}

fn writeStereoSample(bytes: []u8, frame_index: usize, left: i16, right: i16) void {
    const offset = frame_index * 4;
    writeSample(bytes[offset..][0..2], left);
    writeSample(bytes[offset + 2 ..][0..2], right);
}

fn writeSample(bytes: []u8, sample: i16) void {
    const value: u16 = @bitCast(sample);
    bytes[0] = @truncate(value);
    bytes[1] = @truncate(value >> 8);
}

test "AnalyzerState keeps silence inactive" {
    var analyzer: AnalyzerState = .{};
    var silence = [_]u8{0} ** 4096;

    var snapshot: Snapshot = .{};
    for (0..8) |_| {
        snapshot = snapshotFromAnalyzer(&analyzer, &silence);
    }

    try std.testing.expectEqual(@as(f32, 0), snapshot.active);
    try std.testing.expectEqual(@as(f32, 0), snapshot.level);
    try std.testing.expectEqual(@as(f32, 0), snapshot.bass);
    try std.testing.expectEqual(@as(f32, 0), snapshot.mid);
    try std.testing.expectEqual(@as(f32, 0), snapshot.treble);
    try std.testing.expectEqual(@as(f32, 0), snapshot.impact);
}

test "AnalyzerState reports active energy for loud samples" {
    var analyzer: AnalyzerState = .{};
    var samples: [4096]u8 = undefined;
    for (0..(samples.len / 4)) |frame| {
        const sample: i16 = if (frame % 2 == 0) 18000 else -18000;
        writeStereoSample(&samples, frame, sample, sample);
    }

    var snapshot: Snapshot = .{};
    for (0..8) |_| {
        snapshot = snapshotFromAnalyzer(&analyzer, &samples);
    }

    try std.testing.expectEqual(@as(f32, 1), snapshot.active);
    try std.testing.expect(snapshot.level > 0.1);
    try std.testing.expect(snapshot.mid > 0.1 or snapshot.treble > 0.1);
    try std.testing.expect(snapshot.impact > 0.1);
    try std.testing.expect(snapshot.energy > 0.1);
}

test "AnalyzerState ignores incomplete trailing frames" {
    var analyzer: AnalyzerState = .{};
    var samples: [4101]u8 = undefined;
    @memset(&samples, 0);
    for (0..((samples.len - 1) / 4)) |frame| {
        writeStereoSample(&samples, frame, 12000, 12000);
    }
    samples[samples.len - 1] = 0xff;

    const snapshot = snapshotFromAnalyzer(&analyzer, &samples);

    try std.testing.expectEqual(@as(f32, 1), snapshot.active);
    try std.testing.expect(snapshot.level > 0.1);
}

test "UniformPayload packs snapshot values for render uniforms" {
    const snapshot: Snapshot = .{
        .level = 0.1,
        .bass = 0.2,
        .mid = 0.3,
        .treble = 0.4,
        .beat = 0.5,
        .active = 1.0,
        .impact = 0.6,
        .energy = 0.7,
        .drive = 0.8,
        .brightness = 0.9,
    };

    const payload = UniformPayload.fromSnapshot(snapshot);

    try std.testing.expectEqual([4]f32{ 0.1, 0.2, 0.3, 0.4 }, payload.bands);
    try std.testing.expectEqual([4]f32{ 0.5, 1.0, 0, 0 }, payload.state);
    try std.testing.expectEqual([4]f32{ 0.6, 0.7, 0.8, 0.9 }, payload.visualizer);
}

test "UniformPayload derives visual and postprocess effect channels" {
    const payload = UniformPayload.fromSnapshot(.{
        .impact = 1.0,
        .energy = 0.5,
        .drive = 0.75,
        .brightness = 0.25,
    });

    try expectVec4Approx(.{ 1.5, 1.2, 0.375, 0.65 }, payload.visualFx(2.0));
    try expectVec4Approx(.{ 1.5, 0.75, 0.75, 0.375 }, payload.withEffectStrength(1.5).visualizer);
}

/// Render-facing API for audio-reactive state.
///
/// The current implementation reads raw PCM from `pw-record` in a background
/// thread. If PipeWire capture cannot be started, the analyzer falls back to
/// inactive audio inputs and the renderer continues normally.
pub const AudioAnalyzer = struct {
    allocator: Allocator,
    enabled: bool = false,
    requested_target: ?[]const u8 = null,
    capture_mode: CaptureMode = .sink,
    active_target: ?[]u8 = null,
    next_refresh_ns: u64 = 0,
    backend: ?CaptureBackend = null,

    pub fn init(allocator: Allocator, config: Config) AudioAnalyzer {
        var self = AudioAnalyzer{
            .allocator = allocator,
            .enabled = config.enabled,
            .requested_target = config.target,
            .capture_mode = config.capture_mode,
        };

        if (!config.enabled) return self;

        self.refresh(true);

        return self;
    }

    pub fn deinit(self: *AudioAnalyzer) void {
        self.stopBackend();
        if (self.active_target) |target| {
            self.allocator.free(target);
            self.active_target = null;
        }
    }

    pub fn update(self: *AudioAnalyzer) void {
        self.refresh(false);
    }

    pub fn snapshot(self: *const AudioAnalyzer) Snapshot {
        if (self.backend) |backend| {
            backend.shared.mutex.lock();
            defer backend.shared.mutex.unlock();
            return backend.shared.snapshot;
        }

        return .{};
    }

    pub fn activeTarget(self: *const AudioAnalyzer) ?[]const u8 {
        return self.active_target;
    }

    pub fn captureModeLabel(self: *const AudioAnalyzer) []const u8 {
        return switch (self.capture_mode) {
            .sink => "sink-monitor",
            .source => "microphone/source",
        };
    }

    fn refresh(self: *AudioAnalyzer, force: bool) void {
        if (!self.enabled) return;

        const now_ns = nowNs() catch return;
        const backend_dead = self.backend == null or self.backendTerminated();
        if (!force and !backend_dead and now_ns < self.next_refresh_ns) return;
        self.next_refresh_ns = now_ns + target_refresh_interval_ns;

        const target = if (self.requested_target) |manual_target|
            self.allocator.dupe(u8, manual_target) catch return
        else
            self.resolveDefaultTarget() catch |err| {
                self.next_refresh_ns = now_ns + failure_retry_interval_ns;
                std.log.warn("failed to resolve default audio target via wpctl: {s}; continuing with inactive audio inputs", .{resolveTargetErrorMessage(err)});
                return;
            };
        defer self.allocator.free(target);

        const target_changed = self.active_target == null or !std.mem.eql(u8, self.active_target.?, target);
        if (!backend_dead and !target_changed) return;

        self.stopBackend();
        if (self.active_target) |active_target| {
            self.allocator.free(active_target);
            self.active_target = null;
        }

        self.active_target = self.allocator.dupe(u8, target) catch return;
        if (self.requested_target) |_| {
            std.log.info("audio-reactive target: {s} ({s}, manual)", .{ self.active_target.?, self.captureModeLabel() });
        } else {
            std.log.info("audio-reactive target: {s} ({s}, auto)", .{ self.active_target.?, self.captureModeLabel() });
        }
        self.startPipeWire(self.active_target.?) catch |err| {
            self.next_refresh_ns = now_ns + failure_retry_interval_ns;
            std.log.warn("failed to start audio-reactive capture via pw-record for target '{s}': {s}; continuing with inactive audio inputs", .{
                self.active_target.?,
                pipeWireStartErrorMessage(err),
            });
            self.allocator.free(self.active_target.?);
            self.active_target = null;
        };
    }

    fn startPipeWire(self: *AudioAnalyzer, target: []const u8) !void {
        const shared = try self.allocator.create(SharedState);
        errdefer self.allocator.destroy(shared);
        shared.* = .{};

        const target_object_property = try std.fmt.allocPrint(self.allocator, "target.object={s}", .{target});
        defer self.allocator.free(target_object_property);

        const argv = [_][]const u8{
            "pw-record",
            "-P",
            target_object_property,
            "-P",
            switch (self.capture_mode) {
                .sink => "stream.capture.sink=true",
                .source => "stream.capture.sink=false",
            },
            "--raw",
            "--rate",
            "48000",
            "--channels",
            "2",
            "--format",
            "s16",
            "-",
        };

        var child = std.process.Child.init(&argv, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit;
        try child.spawn();
        errdefer {
            _ = child.kill() catch {};
        }
        try child.waitForSpawn();

        const stdout = child.stdout orelse return error.MissingChildStdout;
        child.stdout = null;
        errdefer stdout.close();

        const thread = try std.Thread.spawn(.{}, captureMain, .{ shared, stdout });

        self.backend = .{
            .child = child,
            .thread = thread,
            .shared = shared,
        };
    }

    fn stopBackend(self: *AudioAnalyzer) void {
        if (self.backend) |*backend| {
            _ = backend.child.kill() catch {};
            backend.thread.join();
            self.allocator.destroy(backend.shared);
            self.backend = null;
        }
    }

    fn backendTerminated(self: *const AudioAnalyzer) bool {
        const backend = self.backend orelse return true;
        backend.shared.mutex.lock();
        defer backend.shared.mutex.unlock();
        return backend.shared.terminated;
    }

    fn resolveDefaultTarget(self: *AudioAnalyzer) ![]u8 {
        const default_object = switch (self.capture_mode) {
            .sink => "@DEFAULT_AUDIO_SINK@",
            .source => "@DEFAULT_AUDIO_SOURCE@",
        };
        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "wpctl", "inspect", default_object },
            .max_output_bytes = 64 * 1024,
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        switch (result.term) {
            .Exited => |code| if (code != 0) return error.WpctlFailed,
            else => return error.WpctlFailed,
        }

        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (!std.mem.startsWith(u8, trimmed, "* node.name = \"")) continue;

            const value = trimmed["* node.name = \"".len..];
            const end = std.mem.indexOfScalar(u8, value, '"') orelse continue;
            return self.allocator.dupe(u8, value[0..end]);
        }

        return switch (self.capture_mode) {
            .sink => error.DefaultAudioSinkNotFound,
            .source => error.DefaultAudioSourceNotFound,
        };
    }

    fn nowNs() !u64 {
        const now = try std.time.Instant.now();
        return now.since(std.mem.zeroes(std.time.Instant));
    }

    fn captureMain(shared: *SharedState, stdout: std.fs.File) void {
        defer stdout.close();
        defer {
            shared.mutex.lock();
            shared.snapshot = .{};
            shared.terminated = true;
            shared.mutex.unlock();
        }

        var analyzer: AnalyzerState = .{};
        var buffer: [4096]u8 = undefined;

        while (true) {
            const bytes_read = stdout.read(&buffer) catch |err| {
                std.log.warn("audio capture stream closed: {}", .{err});
                return;
            };
            if (bytes_read == 0) return;

            analyzer.update(shared, buffer[0..bytes_read]);
        }
    }
};

fn resolveTargetErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "wpctl was not found in PATH",
        error.WpctlFailed => "wpctl inspect failed for the default audio node",
        error.DefaultAudioSinkNotFound => "wpctl did not report a default audio sink node.name",
        error.DefaultAudioSourceNotFound => "wpctl did not report a default audio source node.name",
        else => @errorName(err),
    };
}

fn pipeWireStartErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "pw-record was not found in PATH",
        error.AccessDenied => "pw-record could not access the requested PipeWire target",
        error.MissingChildStdout => "pw-record did not provide an audio stream",
        else => @errorName(err),
    };
}

test "audio backend error messages name missing commands" {
    try std.testing.expectEqualStrings("wpctl was not found in PATH", resolveTargetErrorMessage(error.FileNotFound));
    try std.testing.expectEqualStrings("pw-record was not found in PATH", pipeWireStartErrorMessage(error.FileNotFound));
    try std.testing.expectEqualStrings("CustomFailure", pipeWireStartErrorMessage(error.CustomFailure));
}
