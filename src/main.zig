// Copyright (c) 2025, sin-ack <sin-ack@protonmail.com>
//
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const gl = @import("zgl");
const wayland = @import("wayland");
const zig_args = @import("zig-args");

const AudioAnalyzer = @import("audio.zig").AudioAnalyzer;
const CaptureMode = @import("audio.zig").CaptureMode;
const effects = @import("effects.zig");
const GlobalAttributes = @import("shader.zig").GlobalAttributes;
const overlay = @import("overlay.zig");
const TimeModulation = @import("shader.zig").TimeModulation;
const VisualModulation = @import("shader.zig").VisualModulation;
const VisualStyle = @import("shader.zig").VisualStyle;
const PipelineRunner = @import("pipeline.zig").PipelineRunner;
const pipeline_config = @import("pipeline_config.zig");
const PipelineConfig = pipeline_config.PipelineConfig;
const PipelineFileConfig = pipeline_config.FileConfig;
const PipelineParseDiagnostic = pipeline_config.ParseDiagnostic;
const PostProcessConfig = pipeline_config.PostProcessConfig;
const loadPipelineFileConfigWithDiagnostic = pipeline_config.loadFileConfigWithDiagnostic;

const max_shader_file_size = 16 * 1024 * 1024;

const egl = @cImport({
    @cDefine("WL_EGL_PLATFORM", "1");
    @cInclude("EGL/egl.h");
    @cInclude("EGL/eglext.h");
    @cUndef("WL_EGL_PLATFORM");
});

const wl = wayland.client.wl;
const wp = wayland.client.wp;
const zwlr = wayland.client.zwlr;

pub const opengl_error_handling = .assert;
pub const std_options: std.Options = .{
    .log_level = if (builtin.mode == .Debug) .debug else .info,
};

test {
    _ = @import("audio.zig");
    _ = @import("effects.zig");
    _ = @import("overlay.zig");
    _ = @import("pipeline_config.zig");
    _ = @import("postprocess.zig");
    _ = @import("shader.zig");
}

/// An output that represents a physical display.
const Output = struct {
    allocator: Allocator,

    /// The Wayland object representing the output.
    output: *wl.Output,
    /// Whether the `done` event has been received. This flag is cleared if any property
    /// is updated until the compositor sends the `done` event again.
    ready: bool = false,

    /// The registry global name for this output. This is the value reported by
    /// `wl_registry.global` and `wl_registry.global_remove`.
    global_name: u32,
    /// The proxy ID of the output.
    id: u32,
    /// Whether the compositor has removed this output global.
    removed: bool = false,
    /// The number of active wallpapers using this output.
    active_papers: usize = 0,
    invalid_metadata: bool = false,
    invalid_geometry: bool = false,
    invalid_scale: bool = false,
    /// The name of the output. Set by the `name` event.
    name: ?[]const u8 = null,
    /// The human-friendly description of the output. Set by the `description` event.
    description: ?[]const u8 = null,
    /// The scale of this output. Defaults to 1. This only determines the scale of the
    /// output in the compositor, not the scale of the rendered content (which is
    /// determined by the `fractional_scale` object, if available). Set by the `scale` event.
    scale: u32 = 1,
    /// The width of the output in pixels. This is not affected by the scale. Set by the
    /// `mode` event.
    width: u32 = undefined,
    /// The height of the output in pixels. This is not affected by the scale. Set by the
    /// `mode` event.
    height: u32 = undefined,
    /// The refresh rate of the output in Hz (informative, not used for rendering).
    /// We pass it down to the shader in case it wants to use it.
    refresh_rate: u32 = undefined,
    /// The transform of the output. Set by the `geometry` event.
    transform: wl.Output.Transform = .normal,

    /// Create a new output object.
    pub fn create(allocator: Allocator, global_name: u32, output: *wl.Output) !*Output {
        const self = try allocator.create(Output);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .output = output,
            .global_name = global_name,
            .id = output.getId(),
        };
        output.setListener(*Output, listener, self);

        return self;
    }

    /// The listener callback. This should be passed to `wl.Output.setListener`.
    fn listener(output: *wl.Output, event: wl.Output.Event, self: *Output) void {
        self.handle(output, event);
    }

    /// Destroy the output object and free its resources.
    pub fn destroy(self: *Output) void {
        self.output.release();
        if (self.name) |n| self.allocator.free(n);
        if (self.description) |description| self.allocator.free(description);
        self.allocator.destroy(self);
    }

    pub fn retain(self: *Output) void {
        self.active_papers += 1;
    }

    pub fn release(self: *Output) void {
        std.debug.assert(self.active_papers > 0);
        self.active_papers -= 1;
    }

    fn isInvalid(self: *const Output) bool {
        return self.invalid_metadata or self.invalid_geometry or self.invalid_scale;
    }

    /// Handle an output event.
    fn handle(self: *Output, output: *wl.Output, event: wl.Output.Event) void {
        _ = output;

        switch (event) {
            .name => |name| {
                self.ready = false;
                const new_name = self.allocator.dupe(u8, std.mem.sliceTo(name.name, 0)) catch {
                    self.invalid_metadata = true;
                    std.log.err("failed to store name for output global {}", .{self.global_name});
                    return;
                };
                if (self.name) |n| self.allocator.free(n);
                self.name = new_name;
                self.invalid_metadata = false;
            },
            .description => |description| {
                self.ready = false;
                const new_description = self.allocator.dupe(u8, std.mem.sliceTo(description.description, 0)) catch {
                    std.log.warn("failed to store description for output global {}", .{self.global_name});
                    return;
                };
                if (self.description) |d| self.allocator.free(d);
                self.description = new_description;
            },
            .mode => |mode| {
                self.ready = false;

                if (mode.width <= 0 or mode.height <= 0) {
                    self.invalid_geometry = true;
                    std.log.err("output global {} reported invalid mode {}x{}", .{ self.global_name, mode.width, mode.height });
                    return;
                }

                self.width = @intCast(mode.width);
                self.height = @intCast(mode.height);
                const refresh_hz = if (mode.refresh > 0) @divTrunc(mode.refresh, 1000) else 0;
                self.refresh_rate = if (refresh_hz > 0) @intCast(refresh_hz) else 60;
                if (refresh_hz <= 0) {
                    std.log.warn("output global {} reported unknown refresh rate, using 60Hz for shader metadata", .{self.global_name});
                }
                self.invalid_geometry = false;
            },
            .scale => |scale| {
                self.ready = false;

                if (scale.factor <= 0) {
                    self.invalid_scale = true;
                    std.log.err("output global {} reported invalid scale factor {}", .{ self.global_name, scale.factor });
                    return;
                }

                self.scale = @intCast(scale.factor);
                self.invalid_scale = false;
            },
            .done => {
                if (self.name == null) {
                    self.invalid_metadata = true;
                    std.log.err("output global {} did not report a name", .{self.global_name});
                }
                self.ready = !self.isInvalid();
            },
            .geometry => |geometry| {
                self.ready = false;
                self.transform = geometry.transform;
            },
        }
    }

    /// Roundtrip the display until this output is ready.
    pub fn wait(self: *Output, display: *wl.Display) !void {
        while (!self.ready) {
            if (self.isInvalid()) return error.InvalidOutput;
            if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
        }
    }
};

/// A registry listener. This is used to listen for and instantiate global objects.
const RegistryListener = struct {
    allocator: Allocator,

    /// The Wayland display object. This is used to perform roundtrips.
    display: *wl.Display,

    // Protocol objects
    compositor: ?*wl.Compositor,
    layer_shell_v1: ?*zwlr.LayerShellV1,
    fractional_scale_manager_v1: ?*wp.FractionalScaleManagerV1,
    viewporter_v1: ?*wp.Viewporter,

    /// The outputs currently available.
    outputs: std.ArrayListUnmanaged(*Output),

    /// The listener callback. This should be passed to `wl.Registry.setListener`.
    pub fn listener(registry: *wl.Registry, event: wl.Registry.Event, self: *RegistryListener) void {
        self.handle(registry, event);
    }

    /// Deinitialize the registry listener.
    pub fn deinit(self: *RegistryListener) void {
        if (self.layer_shell_v1) |layer_shell_v1| layer_shell_v1.destroy();
        if (self.fractional_scale_manager_v1) |fractional_scale_manager_v1| fractional_scale_manager_v1.destroy();
        if (self.viewporter_v1) |viewporter_v1| viewporter_v1.destroy();

        for (self.outputs.items) |output| {
            output.destroy();
        }
        self.outputs.deinit(self.allocator);
    }

    /// Handle a registry event.
    fn handle(self: *RegistryListener, registry: *wl.Registry, event: wl.Registry.Event) void {
        switch (event) {
            .global => |global| {
                // Protocol objects
                if (std.mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                    self.compositor = registry.bind(global.name, wl.Compositor, 4) catch return;
                } else if (std.mem.orderZ(u8, global.interface, zwlr.LayerShellV1.interface.name) == .eq) {
                    self.layer_shell_v1 = registry.bind(global.name, zwlr.LayerShellV1, 1) catch return;
                } else if (std.mem.orderZ(u8, global.interface, wp.FractionalScaleManagerV1.interface.name) == .eq) {
                    self.fractional_scale_manager_v1 = registry.bind(global.name, wp.FractionalScaleManagerV1, 1) catch return;
                } else if (std.mem.orderZ(u8, global.interface, wp.Viewporter.interface.name) == .eq) {
                    self.viewporter_v1 = registry.bind(global.name, wp.Viewporter, 1) catch return;
                }

                // Outputs
                if (std.mem.orderZ(u8, global.interface, wl.Output.interface.name) == .eq) {
                    const output = registry.bind(global.name, wl.Output, 4) catch return;
                    self.addOutput(global.name, output) catch |err| {
                        std.log.warn("failed to add output global {}: {}", .{ global.name, err });
                    };
                }
            },
            .global_remove => |global_remove| {
                _ = self.removeOutput(global_remove.name);
            },
        }
    }

    fn addOutput(self: *RegistryListener, global_name: u32, wl_output: *wl.Output) !void {
        const output = Output.create(self.allocator, global_name, wl_output) catch |err| {
            wl_output.release();
            return err;
        };
        errdefer output.destroy();

        try output.wait(self.display);
        try self.outputs.append(self.allocator, output);
    }

    fn removeOutput(self: *RegistryListener, global_name: u32) bool {
        for (self.outputs.items, 0..) |item, i| {
            if (item.global_name == global_name) {
                item.removed = true;
                if (item.active_papers != 0) {
                    std.log.info("output {s} was removed; waiting for {} active wallpaper(s) to stop", .{ item.name orelse "unknown", item.active_papers });
                    return true;
                }
                item.destroy();
                _ = self.outputs.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    fn pruneRemovedOutputs(self: *RegistryListener) void {
        var i: usize = 0;
        while (i < self.outputs.items.len) {
            const output = self.outputs.items[i];
            if (!output.removed or output.active_papers != 0) {
                i += 1;
                continue;
            }

            output.destroy();
            _ = self.outputs.orderedRemove(i);
        }
    }
};

/// Wrapper around the Wayland EGL display and configuration.
const GLDisplay = struct {
    /// The EGL display handle.
    egl_display: egl.EGLDisplay,
    /// The configuration chosen for EGL.
    egl_config: egl.EGLConfig,

    pub fn init(display: *wl.Display) !GLDisplay {
        var self: GLDisplay = .{
            .egl_display = egl.eglGetPlatformDisplay(egl.EGL_PLATFORM_WAYLAND_KHR, display, null),
            .egl_config = undefined,
        };

        var egl_major: egl.EGLint = 0;
        var egl_minor: egl.EGLint = 0;
        if (egl.eglInitialize(self.egl_display, &egl_major, &egl_minor) == egl.EGL_TRUE) {
            std.log.debug("EGL version {}.{}", .{ egl_major, egl_minor });
        } else switch (egl.eglGetError()) {
            egl.EGL_BAD_DISPLAY => return error.EglBadDisplay,
            else => return error.EglUnknownError,
        }

        self.egl_config = egl_config: {
            // zig fmt: off
            const egl_attributes = [_:egl.EGL_NONE]egl.EGLint{
                egl.EGL_SURFACE_TYPE,    egl.EGL_WINDOW_BIT,
                egl.EGL_RENDERABLE_TYPE, egl.EGL_OPENGL_BIT,
                egl.EGL_RED_SIZE,        8,
                egl.EGL_GREEN_SIZE,      8,
                egl.EGL_BLUE_SIZE,       8,
                egl.EGL_ALPHA_SIZE,      8,
            };
            // zig fmt: on

            var egl_config: egl.EGLConfig = null;
            var egl_config_count: egl.EGLint = 0;
            if (egl.eglChooseConfig(self.egl_display, &egl_attributes, &egl_config, 1, &egl_config_count) == egl.EGL_TRUE) {
                std.log.debug("EGL config count: {}", .{egl_config_count});
            } else switch (egl.eglGetError()) {
                egl.EGL_BAD_ATTRIBUTE => return error.EglBadAttribute,
                else => return error.EglUnknownError,
            }

            break :egl_config egl_config;
        };

        if (egl.eglBindAPI(egl.EGL_OPENGL_API) != egl.EGL_TRUE) {
            switch (egl.eglGetError()) {
                egl.EGL_BAD_PARAMETER => return error.EglOpenglUnsupported,
                else => return error.EglUnknownError,
            }
        }

        try gl.loadExtensions({}, getProcAddress);

        return self;
    }

    pub fn deinit(self: *GLDisplay) void {
        _ = egl.eglTerminate(self.egl_display);
    }

    fn getProcAddress(ctx: void, name: [:0]const u8) ?gl.binding.FunctionPointer {
        _ = ctx;
        return egl.eglGetProcAddress(name);
    }
};

/// Wrapper around an EGL context for one output.
const GLContext = struct {
    /// The EGL display and config this context belongs to.
    gl_display: *GLDisplay,
    /// The EGL context handle.
    egl_context: egl.EGLContext,

    pub fn init(gl_display: *GLDisplay) !GLContext {
        const egl_context = egl_context: {
            const config_attributes = [_:egl.EGL_NONE]egl.EGLint{
                egl.EGL_CONTEXT_MAJOR_VERSION, 3,
                egl.EGL_CONTEXT_MINOR_VERSION, 3,
            };

            break :egl_context egl.eglCreateContext(gl_display.egl_display, gl_display.egl_config, egl.EGL_NO_CONTEXT, &config_attributes) orelse switch (egl.eglGetError()) {
                egl.EGL_BAD_ATTRIBUTE => return error.InvalidContextAttribute,
                egl.EGL_BAD_CONTEXT => return error.EglBadContext,
                egl.EGL_BAD_MATCH => return error.UnsupportedConfig,
                else => return error.EglUnknownError,
            };
        };

        return .{
            .gl_display = gl_display,
            .egl_context = egl_context,
        };
    }

    pub fn deinit(self: *GLContext) void {
        _ = egl.eglDestroyContext(self.gl_display.egl_display, self.egl_context);
    }
};

/// A wlroots surface object. This is used for the wlroots shell layer to display a surface.
const WlrSurface = struct {
    allocator: Allocator,

    // --- EGL ---
    /// The EGL display and config shared by all output contexts.
    gl_display: *GLDisplay,
    /// The OpenGL context for this surface.
    gl_context: GLContext,
    /// The EGL surface created for the window.
    egl_surface: egl.EGLSurface, // --- State ---
    /// The current width of the surface.
    width: u32 = undefined,
    /// The current height of the surface.
    height: u32 = undefined,
    /// The current scale of the surface buffer.
    scale: u32 = undefined,
    /// The destination width of the surface after applying any scaling necessary for the output.
    destination_width: u32 = undefined,
    /// The destination height of the surface after applying any scaling necessary for the output.
    destination_height: u32 = undefined,
    /// The custom resolution to use for the surface set by the user. If set,
    /// overrides the output resolution.
    custom_resolution: ?Resolution = null,

    // --- Wayland Core ---
    /// The Wayland EGL window.
    wl_egl_window: *wl.EglWindow,
    /// The output associated with this surface.
    output: *Output,
    /// The Wayland surface.
    wl_surface: *wl.Surface,

    // --- Fractional scale handling ---
    /// The fractional scale object associated with the wl_surface. If the compositor does not
    /// support fractional scaling, this will be null.
    fractional_scale: ?*FractionalScale,
    /// The viewport associated with the wl_surface. This is used to scale the surface back to
    /// native size in a fractionally-scaled output.
    viewport: ?*wp.Viewport,

    // --- wlroots Layer Shell ---
    /// The wlroots surface.
    wlr_surface: *zwlr.LayerSurfaceV1,

    /// Pending configuration from the compositor.
    pending_config: ?struct {
        serial: u32,
        width: u32,
        height: u32,
    } = null,
    config_dirty: bool = false,
    closed: bool = false,

    /// Create a wlroots surface with EGL for GPU rendering.
    pub fn createEgl(allocator: Allocator, gl_display: *GLDisplay, compositor: *wl.Compositor, layer_shell: *zwlr.LayerShellV1, fractional_scale_manager: ?*wp.FractionalScaleManagerV1, viewporter: ?*wp.Viewporter, output: *Output, custom_resolution: ?Resolution, layer: Layer) !*WlrSurface {
        const self = try allocator.create(WlrSurface);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.output = output;
        self.gl_display = gl_display;
        self.pending_config = null;
        self.config_dirty = false;
        self.closed = false;
        self.fractional_scale = null;
        self.viewport = null;
        self.gl_context = try GLContext.init(gl_display);
        errdefer self.gl_context.deinit();

        self.destination_width = output.width;
        self.destination_height = output.height;
        self.custom_resolution = custom_resolution;

        if (custom_resolution) |resolution| {
            self.destination_width = resolution.width;
            self.destination_height = resolution.height;
        }

        self.width = self.destination_width;
        self.height = self.destination_height;
        self.scale = output.scale; // Initial scale guess, will be refined in handleConfiguration or by fractional scale

        self.wl_surface = try compositor.createSurface();
        const input_region = try compositor.createRegion();
        defer input_region.destroy();
        self.wl_surface.setInputRegion(input_region);

        errdefer self.wl_surface.destroy();

        self.wl_egl_window = try wl.EglWindow.create(self.wl_surface, @intCast(self.width), @intCast(self.height));
        errdefer self.wl_egl_window.destroy();

        self.egl_surface = egl.eglCreatePlatformWindowSurface(
            self.gl_display.egl_display,
            self.gl_display.egl_config,
            @ptrCast(self.wl_egl_window),
            null,
        ) orelse switch (egl.eglGetError()) {
            egl.EGL_BAD_MATCH => return error.MismatchedConfig,
            egl.EGL_BAD_CONFIG => return error.InvalidConfig,
            egl.EGL_BAD_NATIVE_WINDOW => return error.InvalidNativeWindow,
            else => return error.FailedToCreateSurface,
        };
        errdefer _ = egl.eglDestroySurface(self.gl_display.egl_display, self.egl_surface);

        self.wlr_surface = try layer_shell.getLayerSurface(self.wl_surface, output.output, layer.toWlr(), "papertoy");

        errdefer self.wlr_surface.destroy();

        self.wlr_surface.setListener(*WlrSurface, listener, self);

        // We want to ignore any exclusive zones set by other surfaces.
        self.wlr_surface.setExclusiveZone(-1);
        self.wlr_surface.setSize(self.destination_width, self.destination_height);
        if (fractional_scale_manager) |_| {
            self.wl_surface.setBufferScale(1);
        } else {
            self.wl_surface.setBufferScale(@intCast(self.scale));
        }

        // Anchor to all 4 sides to fill the screen.
        self.wlr_surface.setAnchor(.{ .top = true, .bottom = true, .left = true, .right = true });

        if (fractional_scale_manager) |manager| {
            self.fractional_scale = try FractionalScale.create(allocator, manager, self.wl_surface);
            errdefer if (self.fractional_scale) |scale| scale.destroy(allocator);

            const viewporter_v1 = viewporter orelse return error.NoViewporter;
            self.viewport = try viewporter_v1.getViewport(self.wl_surface);
            errdefer if (self.viewport) |viewport_object| viewport_object.destroy();
        } else {
            // No fractional scale manager available for the current compositor.
            std.log.warn("No fractional scale manager available, using output scale instead", .{});
            self.fractional_scale = null;
            self.viewport = null;
        }

        // Roundtrip once to sync the configuration.
        self.wl_surface.commit();

        return self;
    }

    /// Deinitialize the wlroots surface.
    pub fn deinit(self: *WlrSurface) void {
        _ = egl.eglDestroySurface(self.gl_display.egl_display, self.egl_surface);
        if (self.fractional_scale) |scale| scale.destroy(self.allocator);
        if (self.viewport) |viewport| viewport.destroy();
        self.wlr_surface.destroy();
        self.wl_egl_window.destroy();
        self.wl_surface.destroy();
        self.gl_context.deinit();
        self.allocator.destroy(self);
    }

    /// Make the EGL context current.
    fn makeCurrent(self: *WlrSurface) !void {
        if (egl.eglMakeCurrent(self.gl_display.egl_display, self.egl_surface, self.egl_surface, self.gl_context.egl_context) != egl.EGL_TRUE) {
            switch (egl.eglGetError()) {
                egl.EGL_BAD_ACCESS => return error.EglThreadError,
                egl.EGL_BAD_MATCH => return error.MismatchedContextOrSurfaces,
                egl.EGL_BAD_NATIVE_WINDOW => return error.EglWindowInvalid,
                egl.EGL_BAD_CONTEXT => return error.InvalidEglContext,
                egl.EGL_BAD_ALLOC => return error.OutOfMemory,
                else => return error.EglUnknownError,
            }
        }
    }

    /// Swap the EGL buffers.
    fn swapBuffers(self: *WlrSurface) !void {
        if (egl.eglSwapBuffers(self.gl_display.egl_display, self.egl_surface) != egl.EGL_TRUE) {
            switch (egl.eglGetError()) {
                egl.EGL_BAD_DISPLAY => return error.InvalidDisplay,
                egl.EGL_BAD_SURFACE => return error.PresentInvalidSurface,
                egl.EGL_CONTEXT_LOST => return error.EGLContextLost,
                else => return error.EglUnknownError,
            }
        }
    }

    /// Create a callback object that will be called when it is an appropriate time to render a new
    /// frame.
    fn requestAnimationFrame(self: *WlrSurface) !*wl.Callback {
        return self.wl_surface.frame();
    }

    /// Handle any pending configuration events from the compositor.
    /// Returns whether the surface size changed.
    pub fn handleConfiguration(self: *WlrSurface) !bool {
        if (!self.config_dirty) return false;
        const config = self.pending_config orelse return false;

        self.config_dirty = false;
        self.wlr_surface.ackConfigure(config.serial);

        const fractional_scale_ready = if (self.fractional_scale) |fs|
            if (fs.ready) fs.preferred_scale else null
        else
            null;
        const configured = computeSurfaceConfiguration(.{
            .configure_width = config.width,
            .configure_height = config.height,
            .output_width = self.output.width,
            .output_height = self.output.height,
            .output_scale = self.output.scale,
            .output_transform = self.output.transform,
            .has_fractional_scale = self.fractional_scale != null,
            .fractional_scale = fractional_scale_ready,
            .custom_resolution = self.custom_resolution,
        });

        const width_changed = self.width != configured.buffer_width;
        const height_changed = self.height != configured.buffer_height;
        // We also need to check if destination size changed, or scale changed.
        const dest_width_changed = self.destination_width != configured.destination_width;
        const dest_height_changed = self.destination_height != configured.destination_height;
        const scale_changed = self.scale != configured.buffer_scale;

        if (!width_changed and !height_changed and !dest_width_changed and !dest_height_changed and !scale_changed) return false;

        self.width = configured.buffer_width;
        self.height = configured.buffer_height;
        self.destination_width = configured.destination_width;
        self.destination_height = configured.destination_height;
        self.scale = @intCast(configured.buffer_scale);

        self.wl_surface.setBufferScale(configured.buffer_scale);
        self.wlr_surface.setSize(self.destination_width, self.destination_height);
        self.wl_egl_window.resize(@intCast(self.width), @intCast(self.height), 0, 0);

        std.log.debug("Surface configured: Buffer={}x{}, Logical={}x{}, Scale={}", .{ self.width, self.height, self.destination_width, self.destination_height, configured.buffer_scale });

        if (self.viewport) |viewport| {
            viewport.setSource(.fromInt(0), .fromInt(0), .fromInt(@intCast(self.width)), .fromInt(@intCast(self.height)));
            viewport.setDestination(@intCast(self.destination_width), @intCast(self.destination_height));
        }

        return true;
    }

    /// Handle a wlroots surface event.
    fn listener(wlr_surface: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, self: *WlrSurface) void {
        _ = wlr_surface;

        switch (event) {
            .configure => |configure| {
                self.pending_config = .{
                    .serial = configure.serial,
                    .width = configure.width,
                    .height = configure.height,
                };
                self.config_dirty = true;
            },
            .closed => {
                self.closed = true;
            },
        }
    }
};

const SurfaceConfigurationInput = struct {
    configure_width: u32,
    configure_height: u32,
    output_width: u32,
    output_height: u32,
    output_scale: u32,
    output_transform: wl.Output.Transform,
    has_fractional_scale: bool,
    fractional_scale: ?u32,
    custom_resolution: ?Resolution,
};

const SurfaceConfiguration = struct {
    buffer_width: u32,
    buffer_height: u32,
    destination_width: u32,
    destination_height: u32,
    buffer_scale: i32,
};

fn computeSurfaceConfiguration(input: SurfaceConfigurationInput) SurfaceConfiguration {
    var logical_width = input.configure_width;
    var logical_height = input.configure_height;

    if (logical_width == 0 or logical_height == 0) {
        var output_width = input.output_width;
        var output_height = input.output_height;

        switch (input.output_transform) {
            .@"90", .@"270", .flipped_90, .flipped_270 => {
                std.mem.swap(u32, &output_width, &output_height);
            },
            else => {},
        }

        if (logical_width == 0) logical_width = output_width / input.output_scale;
        if (logical_height == 0) logical_height = output_height / input.output_scale;
    }

    if (input.custom_resolution) |resolution| {
        logical_width = resolution.width;
        logical_height = resolution.height;
    }

    if (input.has_fractional_scale) {
        const buffer_width = scaleWithFractionalScale(input.fractional_scale, logical_width);
        const buffer_height = scaleWithFractionalScale(input.fractional_scale, logical_height);
        return .{
            .buffer_width = buffer_width,
            .buffer_height = buffer_height,
            .destination_width = logical_width,
            .destination_height = logical_height,
            .buffer_scale = 1,
        };
    }

    return .{
        .buffer_width = logical_width * input.output_scale,
        .buffer_height = logical_height * input.output_scale,
        .destination_width = logical_width,
        .destination_height = logical_height,
        .buffer_scale = @intCast(input.output_scale),
    };
}

fn scaleWithFractionalScale(preferred_scale: ?u32, size: u32) u32 {
    return if (preferred_scale) |scale|
        (size * scale) / 120
    else
        size;
}

/// A fractional scale object, getting the fractional scale for a Wayland surface.
/// The surface must live at least as long as the fractional scale object.
const FractionalScale = struct {
    /// The Wayland fractional scale object.
    fractional_scale: *wp.FractionalScaleV1,

    /// The preferred scale, set by the `preferred_scale` event, in 120ths.
    preferred_scale: u32 = undefined,
    /// Whether an initial `preferred_scale` event has been received.
    ready: bool = false,

    /// Create a new fractional scale object.
    pub fn create(allocator: Allocator, manager: *wp.FractionalScaleManagerV1, surface: *wl.Surface) !*FractionalScale {
        const self = try allocator.create(FractionalScale);
        errdefer allocator.destroy(self);

        self.fractional_scale = try manager.getFractionalScale(surface);
        self.fractional_scale.setListener(*FractionalScale, listener, self);

        return self;
    }

    /// Destroy the fractional scale object and free its resources.
    pub fn destroy(self: *FractionalScale, allocator: Allocator) void {
        self.fractional_scale.destroy();
        allocator.destroy(self);
    }

    /// Scale the given size by the preferred scale. If no preferred scale has been set yet,
    /// this will return the original size.
    pub fn scaleSize(self: *FractionalScale, size: u32) u32 {
        return scaleWithFractionalScale(if (self.ready) self.preferred_scale else null, size);
    }

    /// The listener callback. This should be passed to `wp.FractionalScaleV1.setListener`.
    fn listener(fractional_scale: *wp.FractionalScaleV1, event: wp.FractionalScaleV1.Event, self: *FractionalScale) void {
        _ = fractional_scale;

        switch (event) {
            .preferred_scale => |preferred_scale| {
                self.preferred_scale = preferred_scale.scale;
                self.ready = true;
            },
        }
    }
};

const Resolution = struct {
    width: u32,
    height: u32,
};

test "computeSurfaceConfiguration defaults partial zero axes from transformed output" {
    const configured = computeSurfaceConfiguration(.{
        .configure_width = 0,
        .configure_height = 720,
        .output_width = 3440,
        .output_height = 1440,
        .output_scale = 1,
        .output_transform = .@"270",
        .has_fractional_scale = false,
        .fractional_scale = null,
        .custom_resolution = null,
    });

    try std.testing.expectEqual(@as(u32, 1440), configured.destination_width);
    try std.testing.expectEqual(@as(u32, 720), configured.destination_height);
    try std.testing.expectEqual(@as(u32, 1440), configured.buffer_width);
    try std.testing.expectEqual(@as(u32, 720), configured.buffer_height);
    try std.testing.expectEqual(@as(i32, 1), configured.buffer_scale);
}

test "computeSurfaceConfiguration applies integer output scale without fractional scale" {
    const configured = computeSurfaceConfiguration(.{
        .configure_width = 1000,
        .configure_height = 500,
        .output_width = 2000,
        .output_height = 1000,
        .output_scale = 2,
        .output_transform = .normal,
        .has_fractional_scale = false,
        .fractional_scale = null,
        .custom_resolution = null,
    });

    try std.testing.expectEqual(@as(u32, 1000), configured.destination_width);
    try std.testing.expectEqual(@as(u32, 500), configured.destination_height);
    try std.testing.expectEqual(@as(u32, 2000), configured.buffer_width);
    try std.testing.expectEqual(@as(u32, 1000), configured.buffer_height);
    try std.testing.expectEqual(@as(i32, 2), configured.buffer_scale);
}

test "computeSurfaceConfiguration applies fractional scale with buffer scale one" {
    const configured = computeSurfaceConfiguration(.{
        .configure_width = 1000,
        .configure_height = 500,
        .output_width = 2000,
        .output_height = 1000,
        .output_scale = 2,
        .output_transform = .normal,
        .has_fractional_scale = true,
        .fractional_scale = 150,
        .custom_resolution = null,
    });

    try std.testing.expectEqual(@as(u32, 1000), configured.destination_width);
    try std.testing.expectEqual(@as(u32, 500), configured.destination_height);
    try std.testing.expectEqual(@as(u32, 1250), configured.buffer_width);
    try std.testing.expectEqual(@as(u32, 625), configured.buffer_height);
    try std.testing.expectEqual(@as(i32, 1), configured.buffer_scale);
}

test "computeSurfaceConfiguration lets custom resolution override compositor size" {
    const configured = computeSurfaceConfiguration(.{
        .configure_width = 1920,
        .configure_height = 1080,
        .output_width = 3840,
        .output_height = 2160,
        .output_scale = 1,
        .output_transform = .normal,
        .has_fractional_scale = true,
        .fractional_scale = null,
        .custom_resolution = .{ .width = 800, .height = 600 },
    });

    try std.testing.expectEqual(@as(u32, 800), configured.destination_width);
    try std.testing.expectEqual(@as(u32, 600), configured.destination_height);
    try std.testing.expectEqual(@as(u32, 800), configured.buffer_width);
    try std.testing.expectEqual(@as(u32, 600), configured.buffer_height);
    try std.testing.expectEqual(@as(i32, 1), configured.buffer_scale);
}

const Layer = enum {
    background,
    bottom,
    top,
    overlay,

    pub fn toWlr(self: Layer) zwlr.LayerShellV1.Layer {
        return switch (self) {
            .background => .background,
            .bottom => .bottom,
            .top => .top,
            .overlay => .overlay,
        };
    }
};

const OutputConfig = struct {
    id: ?[]const u8 = null,
    resolution: ?Resolution = null,
    frame_rate: ?u32 = null,
    layer: Layer = .background,
};

// Global storage for output configurations parsed from CLI
var global_output_configs = std.ArrayListUnmanaged(OutputConfig){};

const OutputConfigCLI = struct {
    pub fn parse(str: []const u8) !OutputConfigCLI {
        const allocator = std.heap.c_allocator;
        const config = try parseOutputConfigString(allocator, str);
        errdefer if (config.id) |id| allocator.free(id);
        try global_output_configs.append(allocator, config);
        return .{};
    }
};

const Options = struct {
    pipeline: ?[]const u8 = null,
    output: OutputConfigCLI = .{}, // Dummy field to trigger parsing
    @"frame-rate": ?u32 = null,
    resolution: ?[]const u8 = null,
    opacity: ?f32 = null,
    @"audio-reactive": bool = false,
    @"audio-target": ?[]const u8 = null,
    @"audio-capture": ?[]const u8 = null,
    @"audio-time-reactive": bool = false,
    @"audio-time-strength": ?f32 = null,
    @"audio-visual-reactive": bool = false,
    @"audio-visual-strength": ?f32 = null,
    @"audio-visual-style": ?[]const u8 = null,
    @"audio-debug": bool = false,
    @"audio-overlay": bool = false,
    @"list-effects": bool = false,
    help: bool = false,
};

fn parseResolution(s: []const u8) !Resolution {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    var it = std.mem.splitScalar(u8, trimmed, 'x');
    const width_str = it.next() orelse return error.InvalidResolutionFormat;
    const height_str = it.next() orelse return error.InvalidResolutionFormat;
    if (it.next() != null) return error.InvalidResolutionFormat;

    const width = std.fmt.parseInt(u32, width_str, 10) catch |err| switch (err) {
        error.InvalidCharacter => return error.InvalidResolutionValue,
        error.Overflow => return error.ResolutionOverflow,
    };
    const height = std.fmt.parseInt(u32, height_str, 10) catch |err| switch (err) {
        error.InvalidCharacter => return error.InvalidResolutionValue,
        error.Overflow => return error.ResolutionOverflow,
    };
    if (width == 0 or height == 0) return error.ResolutionMustBePositive;
    return .{ .width = width, .height = height };
}

fn parseOutputConfigString(allocator: Allocator, s: []const u8) !OutputConfig {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    if (trimmed.len == 0) return error.OutputIdRequired;

    if (std.mem.indexOfScalar(u8, trimmed, '=') == null) {
        if (std.mem.indexOfScalar(u8, trimmed, ',') != null) return error.InvalidOutputConfig;
        return .{ .id = try allocator.dupe(u8, trimmed) };
    }

    var config: OutputConfig = .{};
    var seen_layer = false;
    errdefer if (config.id) |id| allocator.free(id);

    var it = std.mem.splitScalar(u8, trimmed, ',');
    while (it.next()) |raw_pair| {
        const pair = std.mem.trim(u8, raw_pair, " \t\r\n");
        if (pair.len == 0) return error.InvalidOutputConfig;

        var pair_it = std.mem.splitScalar(u8, pair, '=');
        const key = std.mem.trim(u8, pair_it.next() orelse return error.InvalidOutputConfig, " \t\r\n");
        const value = std.mem.trim(u8, pair_it.next() orelse return error.InvalidOutputConfig, " \t\r\n");
        if (pair_it.next() != null) return error.InvalidOutputConfig;

        if (std.mem.eql(u8, key, "id")) {
            if (value.len == 0) return error.OutputIdRequired;
            if (config.id != null) return error.DuplicateOutputId;
            config.id = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "resolution")) {
            if (config.resolution != null) return error.DuplicateResolution;
            config.resolution = try parseResolution(value);
        } else if (std.mem.eql(u8, key, "frame-rate")) {
            if (config.frame_rate != null) return error.DuplicateFrameRate;
            config.frame_rate = std.fmt.parseInt(u32, value, 10) catch |err| switch (err) {
                error.InvalidCharacter => return error.InvalidFrameRateValue,
                error.Overflow => return error.FrameRateOverflow,
            };
            if (config.frame_rate.? == 0) return error.FrameRateMustBePositive;
        } else if (std.mem.eql(u8, key, "layer")) {
            if (seen_layer) return error.DuplicateLayer;
            seen_layer = true;
            config.layer = std.meta.stringToEnum(Layer, value) orelse return error.UnknownLayer;
        } else {
            return error.UnknownOutputConfigKey;
        }
    }

    if (config.id == null) return error.OutputIdRequired;
    return config;
}

fn applyOutputConfigDefaults(config: *OutputConfig, resolution: ?Resolution, frame_rate: ?u32) void {
    if (config.resolution == null) config.resolution = resolution;
    if (config.frame_rate == null) config.frame_rate = frame_rate;
}

fn findDuplicateOutputConfig(configs: []const OutputConfig) ?[]const u8 {
    for (configs, 0..) |config, i| {
        const id = config.id.?;
        for (configs[i + 1 ..]) |other| {
            if (std.mem.eql(u8, id, other.id.?)) return id;
        }
    }
    return null;
}

test "parseResolution parses trimmed positive dimensions" {
    const resolution = try parseResolution(" 1920x1080 ");
    try std.testing.expectEqual(@as(u32, 1920), resolution.width);
    try std.testing.expectEqual(@as(u32, 1080), resolution.height);
}

test "parseResolution rejects malformed or zero dimensions" {
    try std.testing.expectError(error.InvalidResolutionFormat, parseResolution("1920"));
    try std.testing.expectError(error.InvalidResolutionFormat, parseResolution("1920x1080x60"));
    try std.testing.expectError(error.InvalidResolutionValue, parseResolution("widex1080"));
    try std.testing.expectError(error.ResolutionMustBePositive, parseResolution("0x1080"));
    try std.testing.expectError(error.ResolutionMustBePositive, parseResolution("1920x0"));
}

test "parseOutputConfigString accepts explicit config and legacy output shorthand" {
    const allocator = std.testing.allocator;

    const explicit = try parseOutputConfigString(allocator, "id=DP-1,resolution=1920x1080,frame-rate=60");
    defer allocator.free(explicit.id.?);
    try std.testing.expectEqualStrings("DP-1", explicit.id.?);
    try std.testing.expectEqual(@as(u32, 1920), explicit.resolution.?.width);
    try std.testing.expectEqual(@as(u32, 1080), explicit.resolution.?.height);
    try std.testing.expectEqual(@as(u32, 60), explicit.frame_rate.?);

    const shorthand = try parseOutputConfigString(allocator, " HDMI-A-1 ");
    defer allocator.free(shorthand.id.?);
    try std.testing.expectEqualStrings("HDMI-A-1", shorthand.id.?);
    try std.testing.expectEqual(@as(?Resolution, null), shorthand.resolution);
    try std.testing.expectEqual(@as(?u32, null), shorthand.frame_rate);
}

test "parseOutputConfigString accepts and validates layer" {
    const allocator = std.testing.allocator;

    const with_layer = try parseOutputConfigString(allocator, "id=DP-1,layer=overlay");
    defer allocator.free(with_layer.id.?);
    try std.testing.expectEqual(Layer.overlay, with_layer.layer);

    const def = try parseOutputConfigString(allocator, "id=DP-1");
    defer allocator.free(def.id.?);
    try std.testing.expectEqual(Layer.background, def.layer);

    try std.testing.expectError(error.DuplicateLayer, parseOutputConfigString(allocator, "id=DP-1,layer=top,layer=overlay"));
    try std.testing.expectError(error.UnknownLayer, parseOutputConfigString(allocator, "id=DP-1,layer=sideways"));
}

test "parseOutputConfigString rejects ambiguous and duplicate fields" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.OutputIdRequired, parseOutputConfigString(allocator, ""));
    try std.testing.expectError(error.OutputIdRequired, parseOutputConfigString(allocator, "resolution=1920x1080"));
    try std.testing.expectError(error.InvalidOutputConfig, parseOutputConfigString(allocator, "DP-1,HDMI-A-1"));
    try std.testing.expectError(error.DuplicateOutputId, parseOutputConfigString(allocator, "id=DP-1,id=HDMI-A-1"));
    try std.testing.expectError(error.DuplicateResolution, parseOutputConfigString(allocator, "id=DP-1,resolution=1920x1080,resolution=1280x720"));
    try std.testing.expectError(error.DuplicateFrameRate, parseOutputConfigString(allocator, "id=DP-1,frame-rate=60,frame-rate=30"));
    try std.testing.expectError(error.FrameRateMustBePositive, parseOutputConfigString(allocator, "id=DP-1,frame-rate=0"));
    try std.testing.expectError(error.ResolutionMustBePositive, parseOutputConfigString(allocator, "id=DP-1,resolution=0x1080"));
}

test "applyOutputConfigDefaults only fills missing values" {
    var config: OutputConfig = .{
        .id = "DP-1",
        .resolution = .{ .width = 1280, .height = 720 },
        .frame_rate = null,
    };

    applyOutputConfigDefaults(&config, .{ .width = 1920, .height = 1080 }, 30);
    try std.testing.expectEqual(@as(u32, 1280), config.resolution.?.width);
    try std.testing.expectEqual(@as(u32, 720), config.resolution.?.height);
    try std.testing.expectEqual(@as(u32, 30), config.frame_rate.?);
}

test "findDuplicateOutputConfig detects repeated output ids" {
    const configs = [_]OutputConfig{
        .{ .id = "DP-1" },
        .{ .id = "HDMI-A-1" },
        .{ .id = "DP-1" },
    };
    try std.testing.expectEqualStrings("DP-1", findDuplicateOutputConfig(&configs).?);

    const unique_configs = [_]OutputConfig{
        .{ .id = "DP-1" },
        .{ .id = "HDMI-A-1" },
    };
    try std.testing.expectEqual(@as(?[]const u8, null), findDuplicateOutputConfig(&unique_configs));
}

pub fn printUsage() !void {
    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderrWriter(&buffer);
    defer std.debug.unlockStderrWriter();

    try stderr.writeAll(
        \\Usage: papertoy [options] SHADER_FILE
        \\   or: papertoy [options] --pipeline PIPELINE_FILE
        \\
        \\Run a Shadertoy-compatible shader in a wlroots layer shell, rendering it as
        \\an animated wallpaper.
        \\
        \\Arguments:
        \\  SHADER_FILE       The path to the shader file to render. This should be a GLSL
        \\                    fragment shader that is compatible with the Shadertoy API.
        \\Options:
        \\  --pipeline <file> Use a TOML pipeline file instead of a direct shader path
        \\  --output <config>  Configure individual outputs. Can be specified multiple times.
        \\                     Format: "id=<name>[,resolution=<WxH>][,frame-rate=<fps>][,layer=<layer>]"
        \\                     Compatibility shorthand: --output <name>
        \\                     Layers: background, bottom, top, overlay (default: background)
        \\                     Example: --output "id=DP-1,frame-rate=60,layer=overlay"
        \\                     If not specified, renders on all available outputs.
        \\  --frame-rate <fps> Set a default frame rate for selected outputs (default: native)
        \\  --opacity <f>       Multiply final shader alpha by this value (0.0-1.0, default: 1.0)
        \\  --resolution <WxH> Set a default positive logical resolution for selected outputs
        \\  --audio-reactive   Enable audio-reactive shader inputs from PipeWire
        \\
        \\  --audio-capture <mode> Capture mode: sink (default) or source
        \\  --audio-target <n> Set the PipeWire capture target node name or serial
        \\  --audio-time-reactive  Modulate iTime using audio energy for unmodified shaders
        \\  --audio-time-strength <f> Set the strength of audio time modulation (default: 1.35)
        \\  --audio-visual-reactive  Apply generic audio-driven coordinate and color modulation
        \\  --audio-visual-strength <f> Set the strength of generic visual modulation (default: 1.0)
        \\  --audio-visual-style <s> Visual style: blend (default), pulse, drift, strobe, heat
        \\  --audio-debug      Print live audio analyzer values to the terminal
        \\  --audio-overlay    Draw a compact live audio analyzer overlay
        \\  --list-effects     List built-in postprocess effects and exit
        \\  --help             Show this help message
        \\
    );
}

pub fn printEffects() !void {
    var writer_buf: [256]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&writer_buf);

    try stdout.interface.writeAll(
        \\Built-in postprocess effects:
        \\
    );
    for (effects.postProcessEffectInfos()) |info| {
        try stdout.interface.print(
            \\  {s}
            \\    {s}
            \\    drivers: {s}
            \\    use: {s}
            \\    strength: default {d:.2}, useful {d:.2}-{d:.2}
            \\
        , .{
            info.effect.configName(),
            info.summary,
            info.drivers,
            info.good_use,
            info.strength.default,
            info.strength.useful_min,
            info.strength.useful_max,
        });
    }
    try stdout.interface.flush();
}

fn handleArgsError(err: zig_args.Error) !void {
    if (logOutputConfigArgsError(err)) {
        try printUsage();
        return;
    }

    std.log.err("failed parsing command line arguments: {f}", .{err});
    try printUsage();
}

fn logOutputConfigArgsError(err: zig_args.Error) bool {
    if (!std.mem.eql(u8, err.option, "--output")) return false;

    switch (err.kind) {
        .invalid_value => |value| {
            const reparsed = parseOutputConfigString(std.heap.c_allocator, value) catch |parse_err| {
                std.log.err("invalid --output '{s}': {s}", .{ value, outputConfigErrorMessage(parse_err) });
                return true;
            };
            if (reparsed.id) |id| std.heap.c_allocator.free(id);
            return false;
        },
        else => return false,
    }
}

fn outputConfigErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidOutputConfig => "use --output <name> or --output \"id=<name>[,resolution=<WxH>][,frame-rate=<fps>][,layer=<layer>]\"",
        error.OutputIdRequired => "expected an output name or id=<name>",
        error.DuplicateFrameRate => "frame-rate was specified more than once",
        error.DuplicateLayer => "layer was specified more than once",
        error.DuplicateOutputId => "id was specified more than once",
        error.DuplicateResolution => "resolution was specified more than once",
        error.InvalidResolutionFormat => "resolution must be in WxH form",
        error.InvalidResolutionValue => "resolution width and height must be integers",
        error.ResolutionOverflow => "resolution is too large",
        error.ResolutionMustBePositive => "resolution width and height must be positive",
        error.UnknownOutputConfigKey => "supported keys are id, resolution, frame-rate, and layer",
        error.UnknownLayer => "layer must be one of: background, bottom, top, overlay",
        error.FrameRateOverflow => "frame-rate is too large",
        error.FrameRateMustBePositive => "frame-rate must be positive",
        else => "failed to parse output configuration",
    };
}

fn parseCaptureMode(mode: []const u8) !CaptureMode {
    if (std.mem.eql(u8, mode, "sink")) return .sink;
    if (std.mem.eql(u8, mode, "source")) return .source;
    return error.InvalidCaptureMode;
}

fn parseVisualStyle(style: []const u8) !VisualStyle {
    if (std.mem.eql(u8, style, "blend")) return .blend;
    if (std.mem.eql(u8, style, "pulse")) return .pulse;
    if (std.mem.eql(u8, style, "drift")) return .drift;
    if (std.mem.eql(u8, style, "strobe")) return .strobe;
    if (std.mem.eql(u8, style, "heat")) return .heat;
    return error.InvalidVisualStyle;
}

fn logPipelineParseError(pipeline_path: []const u8, diagnostic: *const PipelineParseDiagnostic, err: anyerror) void {
    if (diagnostic.message) |message| {
        if (diagnostic.line > 0) {
            std.log.err("{s}:{}: {s}", .{ pipeline_path, diagnostic.line, message });
        } else {
            std.log.err("{s}: {s}", .{ pipeline_path, message });
        }
    } else {
        std.log.err("failed to parse pipeline file {s}: {}", .{ pipeline_path, err });
    }
}

const FramePacing = struct {
    callback: *wl.Callback,
    target_frame_interval_ns: ?u64 = null,
    next_frame_time: u64 = 0,
};

const Paper = struct {
    /// The allocator used for this paper's resources.
    allocator: Allocator,
    /// The Wayland surface associated with this paper.
    surface: *WlrSurface,
    /// The shader pipeline being rendered.
    pipeline: PipelineRunner,
    /// Global shader attributes (e.g. time, resolution).
    global_attributes: GlobalAttributes,
    /// Whether a new frame should be rendered. True when a frame callback is received (vsync).
    render_frame: bool = false,
    /// Frame callback plus optional frame-rate cap for this surface.
    frame_pacing: FramePacing,

    pub fn create(
        allocator: Allocator,
        gl_display: *GLDisplay,
        compositor: *wl.Compositor,
        layer_shell: *zwlr.LayerShellV1,
        fractional_scale_manager: ?*wp.FractionalScaleManagerV1,
        viewporter: ?*wp.Viewporter,
        output: *Output,
        custom_resolution: ?Resolution,
        opacity: f32,
        shader_source: []const u8,
        target_frame_rate: ?u32,
        time_modulation: TimeModulation,
        visual_modulation: VisualModulation,
        postprocess_passes: []const PostProcessConfig,
        layer: Layer,
    ) !*Paper {
        const self = try allocator.create(Paper);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        output.retain();
        errdefer output.release();

        self.surface = try WlrSurface.createEgl(allocator, gl_display, compositor, layer_shell, fractional_scale_manager, viewporter, output, custom_resolution, layer);

        errdefer self.surface.deinit();

        try self.surface.makeCurrent();

        self.global_attributes = GlobalAttributes.init();
        errdefer self.global_attributes.deinit();
        self.global_attributes.bind();

        self.pipeline = try PipelineRunner.create(allocator, try PipelineConfig.withPostprocessPasses(
            shader_source,
            .{ .width = self.surface.width, .height = self.surface.height },
            target_frame_rate orelse output.refresh_rate,
            time_modulation,
            visual_modulation,
            postprocess_passes,
        ), opacity);

        errdefer self.pipeline.destroy(allocator);

        self.render_frame = false;
        self.frame_pacing = .{
            .callback = try self.surface.requestAnimationFrame(),
            .target_frame_interval_ns = if (target_frame_rate) |fps| @as(u64, std.time.ns_per_s) / fps else null,
        };
        self.frame_pacing.callback.setListener(*bool, setRenderFrame, &self.render_frame);

        return self;
    }

    pub fn destroy(self: *Paper) void {
        self.surface.makeCurrent() catch {};
        self.pipeline.destroy(self.allocator);
        self.global_attributes.deinit();
        self.frame_pacing.callback.destroy();
        const output = self.surface.output;
        self.surface.deinit();
        output.release();
        self.allocator.destroy(self);
    }

    pub fn handleConfiguration(self: *Paper) !void {
        try self.surface.makeCurrent();
        if (try self.surface.handleConfiguration()) {
            try self.pipeline.resize(.{ .width = self.surface.width, .height = self.surface.height });
            gl.viewport(0, 0, self.surface.width, self.surface.height);
        }
    }

    pub fn shouldStop(self: *const Paper) bool {
        return self.surface.closed or self.surface.output.removed;
    }
};

fn pruneStoppedPapers(papers: *std.ArrayListUnmanaged(*Paper), registry_listener: *RegistryListener) usize {
    var i: usize = 0;
    while (i < papers.items.len) {
        const paper = papers.items[i];
        if (!paper.shouldStop()) {
            i += 1;
            continue;
        }

        const output = paper.surface.output;
        if (paper.surface.closed) {
            std.log.info("surface for output {s} was closed; stopping wallpaper", .{output.name orelse "unknown"});
        } else {
            std.log.info("output {s} was removed; stopping wallpaper", .{output.name orelse "unknown"});
        }

        paper.destroy();
        _ = papers.orderedRemove(i);
        registry_listener.pruneRemovedOutputs();
    }

    return papers.items.len;
}

pub fn main() !u8 {
    const allocator = std.heap.c_allocator;

    const options = zig_args.parseForCurrentProcess(Options, allocator, .{ .forward = handleArgsError }) catch |err| switch (err) {
        error.OutOfMemory => @panic("OOM"),
        error.WriteFailed => return 1, // Nothing we can do about this.
        error.InvalidArguments => return 1, // `handleArgsError` will have handled this.
        else => |e| {
            std.log.err("failed parsing command line arguments: {}", .{e});
            try printUsage();
            return 1;
        },
    };
    defer options.deinit();

    if (options.options.help) {
        try printUsage();
        return 0;
    }
    if (options.options.@"list-effects") {
        try printEffects();
        return 0;
    }

    const using_pipeline_file = options.options.pipeline != null;
    if (using_pipeline_file and options.positionals.len != 0) {
        std.log.err("cannot pass SHADER_FILE when --pipeline is used", .{});
        try printUsage();
        return 1;
    }
    if (!using_pipeline_file and options.positionals.len != 1) {
        std.log.err("must have exactly one positional argument unless --pipeline is used (got {})", .{options.positionals.len});
        try printUsage();
        return 1;
    }
    const shader_path = if (!using_pipeline_file) options.positionals[0] else null;

    if (using_pipeline_file) {
        if (options.options.@"audio-reactive" or
            options.options.@"audio-target" != null or
            options.options.@"audio-capture" != null or
            options.options.@"audio-time-reactive" or
            options.options.@"audio-time-strength" != null or
            options.options.@"audio-visual-reactive" or
            options.options.@"audio-visual-strength" != null or
            options.options.@"audio-visual-style" != null)
        {
            std.log.err("audio and modulation flags cannot be combined with --pipeline in this version", .{});
            return 1;
        }
    }

    const default_resolution = if (options.options.resolution) |resolution|
        parseResolution(resolution) catch |err| {
            std.log.err("invalid --resolution '{s}': {}", .{ resolution, err });
            return 1;
        }
    else
        null;

    const default_frame_rate = if (options.options.@"frame-rate") |frame_rate| frame_rate: {
        if (frame_rate == 0) {
            std.log.err("frame rate must be positive, got 0", .{});
            return 1;
        }
        break :frame_rate frame_rate;
    } else null;
    const opacity = options.options.opacity orelse 1.0;
    if (!isValidOpacity(opacity)) {
        std.log.err("opacity must be a finite value between 0 and 1, got {d}", .{opacity});
        return 1;
    }

    // TODO: Investigate all try uses below and make them return a user-friendly error.

    const display = try wl.Display.connect(null);
    const registry = try display.getRegistry();

    var registry_listener: RegistryListener = .{
        .allocator = allocator,
        .display = display,
        .compositor = null,
        .layer_shell_v1 = null,
        .fractional_scale_manager_v1 = null,
        .viewporter_v1 = null,
        .outputs = .{},
    };
    defer registry_listener.deinit();

    registry.setListener(*RegistryListener, RegistryListener.listener, &registry_listener);
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    const compositor = registry_listener.compositor orelse return error.NoWlCompositor;
    const layer_shell = registry_listener.layer_shell_v1 orelse return error.NoWlrLayerShellV1;

    var pipeline_file_config: ?PipelineFileConfig = null;
    defer if (pipeline_file_config) |*config| config.deinit(allocator);
    var pipeline_parse_diagnostic: PipelineParseDiagnostic = .{};
    defer pipeline_parse_diagnostic.deinit(allocator);

    const effective_shader_path = if (options.options.pipeline) |pipeline_path| blk: {
        pipeline_file_config = loadPipelineFileConfigWithDiagnostic(allocator, pipeline_path, &pipeline_parse_diagnostic) catch |err| switch (err) {
            error.FileNotFound => {
                std.log.err("pipeline file not found: {s}", .{pipeline_path});
                return 1;
            },
            error.FileTooBig => {
                std.log.err("pipeline file is too large: {s}", .{pipeline_path});
                return 1;
            },
            error.MissingBaseShader, error.MissingPassEffect, error.MissingEnvironmentVariable, error.MissingPassPath, error.InvalidPipelineSection, error.InvalidPipelineSyntax, error.InvalidPipelineKey, error.InvalidPipelineValue => {
                logPipelineParseError(pipeline_path, &pipeline_parse_diagnostic, err);
                return 1;
            },
            else => |e| {
                std.log.err("failed to load pipeline file {s}: {}", .{ pipeline_path, e });
                return 1;
            },
        };
        break :blk pipeline_file_config.?.base_path;
    } else shader_path.?;

    const shader_source = std.fs.cwd().readFileAlloc(allocator, effective_shader_path, max_shader_file_size) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.err("shader file not found: {s}", .{effective_shader_path});
            return 1;
        },
        error.FileTooBig => {
            std.log.err("shader file is too large: {s}", .{effective_shader_path});
            return 1;
        },
        else => |e| {
            std.log.err("failed to read shader file: {}", .{e});
            return 1;
        },
    };
    defer allocator.free(shader_source);

    if (pipeline_file_config) |*config| {
        for (config.postprocess_passes[0..config.post_count]) |*pass| {
            const path = pass.path orelse continue;
            pass.source = std.fs.cwd().readFileAlloc(allocator, path, max_shader_file_size) catch |err| switch (err) {
                error.FileNotFound => {
                    std.log.err("postprocess shader file not found: {s}", .{path});
                    return 1;
                },
                error.FileTooBig => {
                    std.log.err("postprocess shader file is too large: {s}", .{path});
                    return 1;
                },
                else => |e| {
                    std.log.err("failed to read postprocess shader file {s}: {}", .{ path, e });
                    return 1;
                },
            };
        }
    }

    defer {
        for (global_output_configs.items) |output_config| {
            if (output_config.id) |id| allocator.free(id);
        }
        global_output_configs.deinit(allocator);
    }

    const cli_capture_mode = if (options.options.@"audio-capture") |mode|
        parseCaptureMode(mode) catch {
            std.log.err("audio capture mode must be 'sink' or 'source', got {s}", .{mode});
            return 1;
        }
    else
        .sink;

    const effective_time_modulation: TimeModulation = if (pipeline_file_config) |config|
        config.time_modulation
    else
        TimeModulation{
            .enabled = options.options.@"audio-time-reactive",
            .strength = options.options.@"audio-time-strength" orelse 1.35,
        };

    const effective_visual_modulation: VisualModulation = if (pipeline_file_config) |config|
        config.visual_modulation
    else
        VisualModulation{
            .enabled = options.options.@"audio-visual-reactive",
            .strength = options.options.@"audio-visual-strength" orelse 1.0,
            .style = if (options.options.@"audio-visual-style") |style|
                parseVisualStyle(style) catch {
                    std.log.err("audio visual style must be one of: blend, pulse, drift, strobe, heat; got {s}", .{style});
                    return 1;
                }
            else
                .blend,
        };

    if (!isNonNegativeFinite(effective_time_modulation.strength)) {
        std.log.err("audio time strength must be a non-negative finite number, got {d}", .{effective_time_modulation.strength});
        return 1;
    }

    if (!isNonNegativeFinite(effective_visual_modulation.strength)) {
        std.log.err("audio visual strength must be a non-negative finite number, got {d}", .{effective_visual_modulation.strength});
        return 1;
    }

    var audio_analyzer = AudioAnalyzer.init(allocator, .{
        .enabled = if (pipeline_file_config) |config|
            config.audio_enabled or config.time_modulation.enabled or config.visual_modulation.enabled or options.options.@"audio-overlay"
        else
            options.options.@"audio-reactive" or options.options.@"audio-time-reactive" or options.options.@"audio-visual-reactive" or options.options.@"audio-overlay",
        .target = if (pipeline_file_config) |config| config.audio_target else options.options.@"audio-target",
        .capture_mode = if (pipeline_file_config) |config| config.audio_capture_mode else cli_capture_mode,
    });
    defer audio_analyzer.deinit();

    const effective_postprocess_passes: []const PostProcessConfig = if (pipeline_file_config) |*config|
        config.activePostprocessPasses()
    else
        &.{};

    if (global_output_configs.items.len == 0) {
        // No specific outputs requested, use all available outputs with the
        // global defaults from legacy options, if any.
        for (registry_listener.outputs.items) |output| {
            try output.wait(display); // Ensure output is ready
            try global_output_configs.append(allocator, .{
                .id = try allocator.dupe(u8, output.name.?),
                .resolution = default_resolution,
                .frame_rate = default_frame_rate,
            });
        }
    } else {
        for (global_output_configs.items) |*output_config| {
            applyOutputConfigDefaults(output_config, default_resolution, default_frame_rate);
        }
    }

    if (global_output_configs.items.len == 0) {
        std.log.err("no outputs configured, cannot render", .{});
        return 1;
    }

    if (findDuplicateOutputConfig(global_output_configs.items)) |id| {
        std.log.err("duplicate output id in --output config: {s}", .{id});
        return 1;
    }

    var gl_display = try GLDisplay.init(display);
    defer gl_display.deinit();

    var papers = std.ArrayListUnmanaged(*Paper){};
    defer {
        for (papers.items) |paper| paper.destroy();
        papers.deinit(allocator);
    }

    for (global_output_configs.items) |output_config| {
        const output_id = output_config.id.?;
        // Find the actual output based on the ID
        var selected_output: ?*Output = null;
        for (registry_listener.outputs.items) |output| {
            try output.wait(display); // Ensure output is ready
            if (std.mem.eql(u8, output.name.?, output_id)) {
                selected_output = output;
                break;
            }
        }

        const output = selected_output orelse {
            std.log.err("output with name '{s}' not found", .{output_id});
            std.log.info("available outputs:", .{});
            for (registry_listener.outputs.items) |out| {
                std.log.info("- {s} ({}x{}, {}Hz)", .{
                    out.name orelse "unknown",
                    out.width,
                    out.height,
                    out.refresh_rate,
                });
            }
            return 1;
        };

        const target_resolution = if (output_config.resolution) |res| res else null;

        const paper = try Paper.create(
            allocator,
            &gl_display,
            compositor,
            layer_shell,
            registry_listener.fractional_scale_manager_v1,
            registry_listener.viewporter_v1,
            output,
            target_resolution,
            opacity,
            shader_source,
            output_config.frame_rate,
            effective_time_modulation,
            effective_visual_modulation,
            effective_postprocess_passes,
            output_config.layer,
        );
        try papers.append(allocator, paper);
        if (output_config.frame_rate) |fps| {
            std.log.info("Rendering on output: {s} (resolution: {}x{}, frame-rate: {})", .{
                output.name.?,
                paper.surface.destination_width,
                paper.surface.destination_height,
                fps,
            });
        } else {
            std.log.info("Rendering on output: {s} (resolution: {}x{}, frame-rate: native)", .{
                output.name.?,
                paper.surface.destination_width,
                paper.surface.destination_height,
            });
        }
    }

    // Initial roundtrip to receive the first configure event from the compositor.
    // We must acknowledge this event before we can attach any buffers (render).
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    for (papers.items) |paper| {
        try paper.handleConfiguration();
    }

    var next_audio_debug_ns: u64 = 0;

    while (true) {
        // Always dispatch pending events first.
        const dispatched = display.dispatchPending();
        if (dispatched != .SUCCESS) return error.DispatchFailed;

        if (pruneStoppedPapers(&papers, &registry_listener) == 0) {
            std.log.warn("no active outputs remain, exiting", .{});
            return 0;
        }

        const now = try std.time.Instant.now();
        const now_ns = now.since(std.mem.zeroes(std.time.Instant));

        audio_analyzer.update();
        const audio_snapshot = audio_analyzer.snapshot();
        if (options.options.@"audio-debug" and now_ns >= next_audio_debug_ns) {
            logAudioDebug(&audio_analyzer, audio_snapshot);
            next_audio_debug_ns = now_ns + std.time.ns_per_s;
        }

        var smallest_frame_cap_sleep_time: ?u64 = null;
        var rendered_count: usize = 0;

        for (papers.items) |paper| {
            var should_render_this_frame = false;
            if (paper.pipeline.frame() == 0 or paper.render_frame) {
                if (paper.frame_pacing.target_frame_interval_ns) |frame_interval_ns| {
                    if (paper.pipeline.frame() == 0 or now_ns >= paper.frame_pacing.next_frame_time) {
                        should_render_this_frame = true;
                        paper.render_frame = false;
                        paper.frame_pacing.next_frame_time = now_ns + frame_interval_ns;
                    } else {
                        const sleep_time = paper.frame_pacing.next_frame_time - now_ns;
                        if (smallest_frame_cap_sleep_time == null or sleep_time < smallest_frame_cap_sleep_time.?) {
                            smallest_frame_cap_sleep_time = sleep_time;
                        }
                    }
                } else {
                    should_render_this_frame = true;
                    paper.render_frame = false;
                }
            }

            if (!should_render_this_frame) continue;

            // We are going to render
            rendered_count += 1;

            try paper.handleConfiguration();
            // Update viewport and resolution uniforms every frame because each output may have
            // a different configured size.
            gl.viewport(0, 0, paper.surface.width, paper.surface.height);

            paper.global_attributes.bind();
            try paper.pipeline.render(audio_snapshot);
            if (options.options.@"audio-overlay") {
                overlay.renderAudioOverlay(audio_snapshot, .{ .width = paper.surface.width, .height = paper.surface.height });
            }

            paper.frame_pacing.callback.destroy();
            paper.frame_pacing.callback = try paper.surface.requestAnimationFrame();
            paper.frame_pacing.callback.setListener(*bool, setRenderFrame, &paper.render_frame);

            try paper.surface.swapBuffers();
        }

        if (rendered_count == 0) {
            // If nothing was rendered, wait for events or the next capped frame time.
            if (smallest_frame_cap_sleep_time) |sleep_time| {
                var fds = [_]std.posix.pollfd{.{
                    .fd = display.getFd(),
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                }};
                _ = std.posix.poll(&fds, @intCast(sleep_time / 1_000_000)) catch {};
            } else {
                // If no custom frame rates, and nothing rendered, just block for events.
                if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
            }
        }
    }

    return 0;
}

fn setRenderFrame(callback: *wl.Callback, event: wl.Callback.Event, render_frame: *bool) void {
    _ = callback;
    switch (event) {
        .done => {
            render_frame.* = true;
        },
    }
}

fn isNonNegativeFinite(value: f32) bool {
    return std.math.isFinite(value) and value >= 0.0;
}
fn isValidOpacity(value: f32) bool {
    return std.math.isFinite(value) and value >= 0.0 and value <= 1.0;
}

test "isValidOpacity accepts unit interval and rejects outside values" {
    try std.testing.expect(isValidOpacity(0.0));
    try std.testing.expect(isValidOpacity(0.35));
    try std.testing.expect(isValidOpacity(1.0));
    try std.testing.expect(!isValidOpacity(-0.1));
    try std.testing.expect(!isValidOpacity(1.1));
    try std.testing.expect(!isValidOpacity(std.math.nan(f32)));
    try std.testing.expect(!isValidOpacity(std.math.inf(f32)));
}

test "isNonNegativeFinite rejects negative and non-finite values" {
    try std.testing.expect(isNonNegativeFinite(0.0));
    try std.testing.expect(isNonNegativeFinite(1.5));
    try std.testing.expect(!isNonNegativeFinite(-0.1));
    try std.testing.expect(!isNonNegativeFinite(std.math.nan(f32)));
    try std.testing.expect(!isNonNegativeFinite(std.math.inf(f32)));
}

fn logAudioDebug(audio_analyzer: *const AudioAnalyzer, snapshot: @import("audio.zig").Snapshot) void {
    const target = audio_analyzer.activeTarget() orelse "(none)";
    std.log.info(
        "audio-debug mode={s} target={s} active={d:.0} level={d:.2} bass={d:.2} mid={d:.2} treble={d:.2} beat={d:.2} impact={d:.2} energy={d:.2} drive={d:.2} brightness={d:.2}",
        .{
            audio_analyzer.captureModeLabel(),
            target,
            snapshot.active,
            snapshot.level,
            snapshot.bass,
            snapshot.mid,
            snapshot.treble,
            snapshot.beat,
            snapshot.impact,
            snapshot.energy,
            snapshot.drive,
            snapshot.brightness,
        },
    );
}
