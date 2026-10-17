//! sdk/hg_gl.zig — a GL ES 3.0 program helper for effect modules.
//!
//! Heavy effects (swarm and friends) render an offscreen pass of their own,
//! then hand the result to the host's main shader as a texture. That pass needs
//! a fragment program, the fullscreen-triangle VAO the host also uses, and the
//! standard `iResolution` / `iWindows` / `iPalette*` uniforms on *its* program.
//! `Program` provides exactly that; a module keeps its own extras in an
//! `hg.Uniforms` keyed off `program`.
//!
//! GL is only current during `upload`, so build a `Program` lazily on the first
//! upload (never in `create`), and `deinit` it in `destroy`.

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
