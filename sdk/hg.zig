//! sdk/hg.zig — the Zig side of the hyprglaze effect ABI.
//!
//! An effect module imports this file and exports one `hg_module_entry`:
//!
//!     const hg = @import("hg.zig");
//!
//!     const State = struct { /* ... */ };
//!
//!     fn create(host: *const hg.c.hg_host, w: f32, h: f32) callconv(.c) ?*anyopaque { ... }
//!     fn update(self: *anyopaque, frame: *const hg.c.hg_frame) callconv(.c) void { ... }
//!     fn upload(self: *anyopaque, program: u32) callconv(.c) void { ... }
//!     fn destroy(self: *anyopaque) callconv(.c) void { ... }
//!
//!     const module = hg.c.hg_module{
//!         .abi_version = hg.abi_version,
//!         .id = "my-effect",
//!         .shader = "my-effect.frag",
//!         .config_section = null, // use the section named by `id`
//!         .wants_audio = 0,
//!         .create = create,
//!         .update = update,
//!         .upload = upload,
//!         .destroy = destroy,
//!     };
//!     export fn hg_module_entry() callconv(.c) *const hg.c.hg_module { return &module; }
//!
//! The GL ES 3.0 symbols are available as `hg.gl`. This module is staged next
//! to the effect source by the host's compile-on-load path, so `@import("hg.zig")`
//! resolves without an extra include path.

const std = @import("std");

pub const c = @cImport({
    @cInclude("hg_plugin.h");
});

pub const gl = @cImport({
    @cInclude("GLES3/gl3.h");
});

/// Audio analysis over `hg_frame.wave`: FFT bands (`Bands`), the kick detector
/// (`Onset`), and the combined waveform-fed `Analyzer`. Staged next to this
/// file by the host's compile-on-load path.
pub const audio = @import("hg_audio.zig");

pub const abi_version: u32 = c.HG_ABI_VERSION;

/// Thin wrapper over the host's `[<effect>]` config accessors. String results
/// are borrowed for the call only; copy what you keep.
pub const Host = struct {
    raw: *const c.hg_host,

    pub fn getFloat(self: Host, key: [*:0]const u8, default: f32) f32 {
        const f = self.raw.params.get_f32 orelse return default;
        return f(self.raw.params_ctx, key, default);
    }
    pub fn getInt(self: Host, key: [*:0]const u8, default: i64) i64 {
        const f = self.raw.params.get_i64 orelse return default;
        return f(self.raw.params_ctx, key, default);
    }
    pub fn getBool(self: Host, key: [*:0]const u8, default: bool) bool {
        const f = self.raw.params.get_bool orelse return default;
        return f(self.raw.params_ctx, key, @intFromBool(default)) != 0;
    }
    pub fn getString(self: Host, key: [*:0]const u8) ?[]const u8 {
        const f = self.raw.params.get_str orelse return null;
        var len: u64 = 0;
        const p = f(self.raw.params_ctx, key, &len);
        if (p == null or len == 0) return null;
        return p[0..@intCast(len)];
    }
};

/// Cached uniform locations for an effect's own uniforms. Mirrors the host's
/// `src/effects/uniforms.zig`; a setter silently skips a uniform the shader
/// does not declare.
pub fn Uniforms(comptime spec: anytype) type {
    const Spec = @TypeOf(spec);
    const fields = @typeInfo(Spec).@"struct".fields;
    return struct {
        const Self = @This();
        pub const Name = std.meta.FieldEnum(Spec);

        program: u32 = 0,
        locs: [fields.len]i32 = [_]i32{-1} ** fields.len,

        pub fn use(self: *Self, program: u32) void {
            gl.glUseProgram(program);
            if (self.program == program) return;
            self.program = program;
            inline for (fields, 0..) |f, i| {
                self.locs[i] = gl.glGetUniformLocation(program, @field(spec, f.name));
            }
        }

        pub fn loc(self: *const Self, comptime name: Name) i32 {
            return self.locs[@intFromEnum(name)];
        }

        pub fn f1(self: *const Self, comptime name: Name, x: f32) void {
            const l = self.loc(name);
            if (l >= 0) gl.glUniform1f(l, x);
        }
        pub fn f2(self: *const Self, comptime name: Name, x: f32, y: f32) void {
            const l = self.loc(name);
            if (l >= 0) gl.glUniform2f(l, x, y);
        }
        pub fn f3(self: *const Self, comptime name: Name, x: f32, y: f32, z: f32) void {
            const l = self.loc(name);
            if (l >= 0) gl.glUniform3f(l, x, y, z);
        }
        pub fn f4(self: *const Self, comptime name: Name, x: f32, y: f32, z: f32, w: f32) void {
            const l = self.loc(name);
            if (l >= 0) gl.glUniform4f(l, x, y, z, w);
        }
        pub fn int(self: *const Self, comptime name: Name, x: i32) void {
            const l = self.loc(name);
            if (l >= 0) gl.glUniform1i(l, x);
        }
        pub fn f1v(self: *const Self, comptime name: Name, count: i32, v: anytype) void {
            const l = self.loc(name);
            if (l >= 0 and count > 0) gl.glUniform1fv(l, count, @ptrCast(v));
        }
        pub fn f2v(self: *const Self, comptime name: Name, count: i32, v: anytype) void {
            const l = self.loc(name);
            if (l >= 0 and count > 0) gl.glUniform2fv(l, count, @ptrCast(v));
        }
        pub fn f3v(self: *const Self, comptime name: Name, count: i32, v: anytype) void {
            const l = self.loc(name);
            if (l >= 0 and count > 0) gl.glUniform3fv(l, count, @ptrCast(v));
        }
        pub fn f4v(self: *const Self, comptime name: Name, count: i32, v: anytype) void {
            const l = self.loc(name);
            if (l >= 0 and count > 0) gl.glUniform4fv(l, count, @ptrCast(v));
        }
        pub fn intv(self: *const Self, comptime name: Name, count: i32, v: anytype) void {
            const l = self.loc(name);
            if (l >= 0 and count > 0) gl.glUniform1iv(l, count, @ptrCast(v));
        }
    };
}

/// Helpers for the std `c_allocator` (plugins link libc). `destroy` is the
/// only place a plugin needs to free, so keep `create`/`destroy` paired.
pub const allocator = std.heap.c_allocator;
