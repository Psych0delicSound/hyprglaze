//! sdk/hg_gl.zig — a GL ES 3.0 program helper for effect modules.
//!
//! Heavy effects (swarm and friends) render an offscreen pass of their own,
//! then hand the result to the host's main shader as a texture. That pass needs
//! a fragment program, the fullscreen-triangle VAO the host also uses, and the
//! standard `iResolution` / `iWindows` / `iPalette*` uniforms on *its* program.
//! `Program` provides exactly that; a module keeps its own extras in an
//! `hg.Uniforms` keyed off `program`.
//!
//! `Target` covers the other half of an offscreen pass: the colour texture and
//! its framebuffer, created and freed as one (see its doc). Ping-pong feedback
//! is two of them.
//!
//! GL is only current during `upload`, so build a `Program` (or `Target`)
//! lazily on the first upload (never in `create`), and `deinit` it in
//! `destroy`.

const std = @import("std");
const hg = @import("hg.zig");

const c = hg.c;
const gl = hg.gl;

const log = std.log.scoped(.shader);

pub const max_windows = 32;
pub const max_palette = 16;

const vertex_source: [*:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\void main() {
    \\    vec2 pos = vec2(
    \\        float((gl_VertexID & 1) * 4 - 1),
    \\        float((gl_VertexID & 2) * 2 - 1)
    \\    );
    \\    gl_Position = vec4(pos, 0.0, 1.0);
    \\}
;

/// A compiled fragment program with the fullscreen-triangle VAO and the
/// standard per-frame uniform locations cached.
pub const Program = struct {
    program: gl.GLuint = 0,
    vao: gl.GLuint = 0,

    i_resolution: gl.GLint = -1,
    i_windows: [max_windows]gl.GLint = [_]gl.GLint{-1} ** max_windows,
    i_window_count: gl.GLint = -1,
    i_palette: [max_palette]gl.GLint = [_]gl.GLint{-1} ** max_palette,
    i_palette_size: gl.GLint = -1,
    i_palette_bg: gl.GLint = -1,
    i_palette_fg: gl.GLint = -1,

    pub fn init(frag_source: [:0]const u8) !Program {
        const vert = gl.glCreateShader(gl.GL_VERTEX_SHADER);
        if (vert == 0) return error.CreateVertexShaderFailed;
        defer gl.glDeleteShader(vert);
        const vsrc: [*c]const [*c]const u8 = @ptrCast(&vertex_source);
        gl.glShaderSource(vert, 1, vsrc, null);
        gl.glCompileShader(vert);
        try checkCompile(vert, "vertex");

        const frag = gl.glCreateShader(gl.GL_FRAGMENT_SHADER);
        if (frag == 0) return error.CreateFragmentShaderFailed;
        defer gl.glDeleteShader(frag);
        const fsrc_ptr: [*:0]const u8 = frag_source.ptr;
        const fsrc: [*c]const [*c]const u8 = @ptrCast(&fsrc_ptr);
        gl.glShaderSource(frag, 1, fsrc, null);
        gl.glCompileShader(frag);
        try checkCompile(frag, "fragment");

        const program = gl.glCreateProgram();
        if (program == 0) return error.CreateProgramFailed;
        errdefer gl.glDeleteProgram(program);
        gl.glAttachShader(program, vert);
        gl.glAttachShader(program, frag);
        gl.glLinkProgram(program);
        try checkLink(program);

        var vao: gl.GLuint = 0;
        gl.glGenVertexArrays(1, &vao);

        var self = Program{ .program = program, .vao = vao };
        self.i_resolution = gl.glGetUniformLocation(program, "iResolution");
        self.i_window_count = gl.glGetUniformLocation(program, "iWindowCount");
        var name_buf: [32]u8 = undefined;
        for (0..max_windows) |i| {
            const n = std.fmt.bufPrintZ(&name_buf, "iWindows[{d}]", .{i}) catch unreachable;
            self.i_windows[i] = gl.glGetUniformLocation(program, n.ptr);
        }
        for (0..max_palette) |i| {
            const n = std.fmt.bufPrintZ(&name_buf, "iPalette[{d}]", .{i}) catch unreachable;
            self.i_palette[i] = gl.glGetUniformLocation(program, n.ptr);
        }
        self.i_palette_size = gl.glGetUniformLocation(program, "iPaletteSize");
        self.i_palette_bg = gl.glGetUniformLocation(program, "iPaletteBg");
        self.i_palette_fg = gl.glGetUniformLocation(program, "iPaletteFg");
        return self;
    }

    pub fn use(self: *const Program) void {
        gl.glUseProgram(self.program);
    }

    /// Bind the VAO and emit the fullscreen triangle (no vertex attributes).
    pub fn draw(self: *const Program) void {
        gl.glBindVertexArray(self.vao);
        gl.glDrawArrays(gl.GL_TRIANGLES, 0, 3);
    }

    pub fn setResolution(self: *const Program, width: f32, height: f32) void {
        if (self.i_resolution >= 0) gl.glUniform3f(self.i_resolution, width, height, 1.0);
    }

    pub fn setWindows(self: *const Program, frame: *const c.hg_frame) void {
        const n: u32 = @intCast(@min(frame.windows_len, max_windows));
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            if (self.i_windows[i] >= 0) {
                const w = frame.windows[i];
                gl.glUniform4f(self.i_windows[i], w.x, w.y, w.w, w.h);
            }
        }
        if (self.i_window_count >= 0) gl.glUniform1i(self.i_window_count, @intCast(n));
    }

    /// Push the theme palette from a frame. No palette reads as size 0, which
    /// shaders already treat as "use the built-in fallback colours".
    pub fn setPalette(self: *const Program, frame: *const c.hg_frame) void {
        const pal = frame.palette;
        const n: u32 = if (pal == null) 0 else frame.palette_len;
        var i: u32 = 0;
        while (i < n and i < max_palette) : (i += 1) {
            if (self.i_palette[i] >= 0)
                gl.glUniform3f(self.i_palette[i], pal[i * 3], pal[i * 3 + 1], pal[i * 3 + 2]);
        }
        if (self.i_palette_size >= 0) gl.glUniform1i(self.i_palette_size, @intCast(n));
        if (self.i_palette_bg >= 0)
            gl.glUniform3f(self.i_palette_bg, frame.palette_bg[0], frame.palette_bg[1], frame.palette_bg[2]);
        if (self.i_palette_fg >= 0)
            gl.glUniform3f(self.i_palette_fg, frame.palette_fg[0], frame.palette_fg[1], frame.palette_fg[2]);
    }

    /// Idempotent: deleting handle 0 is a no-op, and handles are zeroed.
    pub fn deinit(self: *Program) void {
        if (self.vao != 0) gl.glDeleteVertexArrays(1, &self.vao);
        if (self.program != 0) gl.glDeleteProgram(self.program);
        self.vao = 0;
        self.program = 0;
    }
};

/// Internal colour format for a [`Target`]. `rgba16f` keeps overlapping
/// additive glows from clipping to white (and lets a slow feedback decay fade
/// out instead of sticking at the last 8-bit step); `rgba8` is the cheap,
/// universally supported choice.
pub const TextureFormat = enum { rgba8, rgba16f };

/// An offscreen render target: a colour texture with its own framebuffer,
/// created, resized (by re-init) and freed as one. Effects that render an
/// extra pass and hand the texture to the main shader use this for the parts
/// that are the same every time; ping-pong feedback is two `Target`s.
///
/// Build it lazily in `upload` (GL is only current there), never in `create`,
/// and `deinit` it in `destroy`.
pub const Target = struct {
    fbo: gl.GLuint = 0,
    tex: gl.GLuint = 0,
    width: gl.GLsizei = 0,
    height: gl.GLsizei = 0,

    pub const Filter = enum { nearest, linear };
    pub const Wrap = enum { clamp, repeat };

    pub const Options = struct {
        format: TextureFormat = .rgba8,
        /// Try RGBA16F first and fall back to RGBA8 when the attachment is
        /// incomplete (some GLES drivers refuse half-float render targets).
        half_float_fallback: bool = false,
        filter: Filter = .linear,
        wrap: Wrap = .clamp,
        /// Allocate a mip chain (min filter becomes LINEAR_MIPMAP_NEAREST, so
        /// the texture stays complete for `generateMipmaps`).
        mipmaps: bool = false,
    };

    const Format = struct { internal: gl.GLint, data_type: gl.GLenum };

    pub fn init(width_in: i32, height_in: i32, opts: Options) !Target {
        const w: gl.GLsizei = @intCast(@max(width_in, 1));
        const h: gl.GLsizei = @intCast(@max(height_in, 1));

        var self = Target{ .width = w, .height = h };
        gl.glGenTextures(1, &self.tex);
        if (self.tex == 0) return error.CreateTextureFailed;
        errdefer gl.glDeleteTextures(1, &self.tex);
        gl.glGenFramebuffers(1, &self.fbo);
        if (self.fbo == 0) return error.CreateFramebufferFailed;
        errdefer gl.glDeleteFramebuffers(1, &self.fbo);

        gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, self.fbo);

        const eight = Format{ .internal = gl.GL_RGBA8, .data_type = gl.GL_UNSIGNED_BYTE };
        const half = Format{ .internal = gl.GL_RGBA16F, .data_type = gl.GL_HALF_FLOAT };
        const candidates: []const Format = switch (opts.format) {
            .rgba8 => &.{eight},
            .rgba16f => if (opts.half_float_fallback) &.{ half, eight } else &.{half},
        };

        const mag: gl.GLint = switch (opts.filter) {
            .nearest => gl.GL_NEAREST,
            .linear => gl.GL_LINEAR,
        };
        const min: gl.GLint = if (opts.mipmaps) gl.GL_LINEAR_MIPMAP_NEAREST else mag;
        const wrap: gl.GLint = switch (opts.wrap) {
            .clamp => gl.GL_CLAMP_TO_EDGE,
            .repeat => gl.GL_REPEAT,
        };

        var complete = false;
        for (candidates) |fmt| {
            gl.glBindTexture(gl.GL_TEXTURE_2D, self.tex);
            gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, fmt.internal, w, h, 0, gl.GL_RGBA, fmt.data_type, null);
            gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, min);
            gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, mag);
            gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, wrap);
            gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, wrap);
            gl.glFramebufferTexture2D(gl.GL_FRAMEBUFFER, gl.GL_COLOR_ATTACHMENT0, gl.GL_TEXTURE_2D, self.tex, 0);
            complete = gl.glCheckFramebufferStatus(gl.GL_FRAMEBUFFER) == gl.GL_FRAMEBUFFER_COMPLETE;
            if (complete) break;
        }
        gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, 0);
        if (!complete) {
            log.err("target {d}x{d}: framebuffer incomplete", .{ width_in, height_in });
            return error.FramebufferIncomplete;
        }
        return self;
    }

    /// Bind this target's framebuffer and set the viewport to its size.
    pub fn begin(self: *const Target) void {
        gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, self.fbo);
        gl.glViewport(0, 0, self.width, self.height);
    }

    pub fn bind(self: *const Target) void {
        gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, self.fbo);
    }

    /// Bind the texture to `unit` (does not touch the active unit).
    pub fn bindTexture(self: *const Target, unit: gl.GLenum) void {
        gl.glActiveTexture(unit);
        gl.glBindTexture(gl.GL_TEXTURE_2D, self.tex);
    }

    pub fn generateMipmaps(self: *const Target) void {
        gl.glBindTexture(gl.GL_TEXTURE_2D, self.tex);
        gl.glGenerateMipmap(gl.GL_TEXTURE_2D);
    }

    pub fn deinit(self: *Target) void {
        if (self.fbo != 0) gl.glDeleteFramebuffers(1, &self.fbo);
        if (self.tex != 0) gl.glDeleteTextures(1, &self.tex);
        self.fbo = 0;
        self.tex = 0;
        self.width = 0;
        self.height = 0;
    }
};

fn checkCompile(shader: gl.GLuint, label: []const u8) !void {
    var ok: gl.GLint = 0;
    gl.glGetShaderiv(shader, gl.GL_COMPILE_STATUS, &ok);
    if (ok == 0) {
        var buf: [2048]u8 = undefined;
        var len: gl.GLsizei = 0;
        gl.glGetShaderInfoLog(shader, 2048, &len, &buf);
        log.err("{s} shader compile error:\n{s}", .{ label, buf[0..@intCast(len)] });
        return error.ShaderCompileFailed;
    }
}

fn checkLink(program: gl.GLuint) !void {
    var ok: gl.GLint = 0;
    gl.glGetProgramiv(program, gl.GL_LINK_STATUS, &ok);
    if (ok == 0) {
        var buf: [2048]u8 = undefined;
        var len: gl.GLsizei = 0;
        gl.glGetProgramInfoLog(program, 2048, &len, &buf);
        log.err("program link error:\n{s}", .{buf[0..@intCast(len)]});
        return error.ProgramLinkFailed;
    }
}
