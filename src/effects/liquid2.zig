const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");

// Fully shader-side effect: the blob-gated OLED pour, caustic veins, and
// the theme-palette paint ramp all live in the fragment shader, which reads
// only standard uniforms (iResolution/iTime/iMouse, palette, windows).
// This context exists to satisfy the union contract; it is shared verbatim
// by the `custom` variant, which lets any `<subdir>/<frag-stem>` name under
// shaders/ run as a first-class effect (see effects.zig shader path
// resolution) — those shaders are user-maintained and expected to be
// self-contained like this one.
pub const Context = struct {
    pub fn init() !Context {
        return .{};
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        _ = self;
        _ = state;
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        _ = self;
        _ = prog;
    }

    pub fn deinit(self: *Context) void {
        _ = self;
    }
};
