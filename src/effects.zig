const std = @import("std");

const shader_mod = @import("core/shader.zig");
const transition_mod = @import("core/transition.zig");
const config_mod = @import("core/config.zig");
const palette_mod = @import("core/palette.zig");
const frame_mod = @import("core/frame.zig");
const plugin_mod = @import("core/plugin.zig");
const iohelp = @import("core/io_helper.zig");

const particles = @import("effects/particles/context.zig");
const windowglow = @import("effects/windowglow.zig");
const glitch = @import("effects/glitch.zig");
const cellbloom = @import("effects/cellbloom.zig");
const concentric = @import("effects/concentric.zig");
const fluid = @import("effects/fluid.zig");
const starfield = @import("effects/starfield.zig");
const visualizer = @import("effects/visualizer/context.zig");
const milkdrop = @import("effects/milkdrop/context.zig");
const tide = @import("effects/tide.zig");
const fire = @import("effects/fire.zig");
const swarm = @import("effects/swarm/context.zig");
const voltaic = @import("effects/voltaic.zig");
const moire = @import("effects/moire.zig");
const ivy = @import("effects/ivy.zig");
const whorl = @import("effects/whorl.zig");
const weft = @import("effects/weft.zig");
const crystal = @import("effects/crystal.zig");
const fur = @import("effects/fur.zig");
const amorphous = @import("effects/amorphous.zig");
const laser = @import("effects/laser/context.zig");
const flux = @import("effects/flux.zig");
const liquid2 = @import("effects/liquid2.zig");

/// Per-frame desktop snapshot and mapped-window class/title. Moved to
/// `core/frame.zig` so the plugin host can name them without an import cycle;
/// re-exported here because every effect imports them from `effects`.
pub const WindowInfo = frame_mod.WindowInfo;
pub const FrameState = frame_mod.FrameState;

/// The active desktop effect. Method contract for every variant Context:
/// - `init` never touches GL: it may run with no context current, or with
///   one that is about to be destroyed (a graphics rebuild builds the
///   replacement effect before tearing the old context down). GL resource
///   creation belongs in the first `upload` call.
/// - `update(state)` runs once per frame before rendering; it may assume a
///   monotonically advancing clock but nothing about GL. FrameState slices
///   are only valid during the call (see FrameState).
/// - `upload(prog)` runs with the GL context current and pushes uniforms
///   (and any lazily created GL state) to the program.
/// - `deinit` must release everything init/update/upload acquired,
///   including stopping any background threads. It runs with the context
///   that created the effect's GL names still current.
pub const Effect = union(enum) {
    particles: particles.Context,
    windowglow: windowglow.Context,
    glitch: glitch.Context,
    cellbloom: cellbloom.Context,
    concentric: concentric.Context,
    fluid: fluid.Context,
    starfield: starfield.Context,
    visualizer: visualizer.Context,
    milkdrop: milkdrop.Context,
    tide: tide.Context,
    fire: fire.Context,
    swarm: swarm.Context,
    voltaic: voltaic.Context,
    moire: moire.Context,
    ivy: ivy.Context,
    whorl: whorl.Context,
    weft: weft.Context,
    crystal: crystal.Context,
    fur: fur.Context,
    amorphous: amorphous.Context,
    laser: laser.Context,
    flux: flux.Context,
    /// The shipped shader-side effect (shaders/customs/liquid2.frag).
    liquid2: liquid2.Context,
    /// Backing variant for `<subdir>/<frag-stem>` shader names: any frag
    /// under a shaders/ subdirectory runs on this stateless context, like
    /// liquid2, with its shader selected by name (see `init` and
    /// `defaultShaderFor`).
    custom: liquid2.Context,

    /// A loadable component effect from `effects/<name>/`: a shared object the
    /// host compiles (on demand) and drives through the C ABI in
    /// `sdk/include/hg_plugin.h`. Selected before the built-in variants when
    /// `effects/<name>/effect.zig` exists.
    plugin: plugin_mod.Instance,

    /// Config section an effect reads its params from. Defaults to the
    /// variant name; the exceptions: starfield and milkdrop intentionally
    /// read the shared [visualizer] section (same audio knobs, e.g. sink).
    fn paramSection(comptime field_name: []const u8) []const u8 {
        if (std.mem.eql(u8, field_name, "starfield")) return "visualizer";
        if (std.mem.eql(u8, field_name, "milkdrop")) return "visualizer";
        return field_name;
    }

    /// Call `T.init` with whichever of the standard argument shapes it
    /// declares (arity-dispatched at comptime). The `!T` return normalizes
    /// plain and error-union inits.
    fn initContext(comptime T: type, allocator: std.mem.Allocator, width: f32, height: f32, cfg: *const config_mod.Config, comptime section: []const u8) !T {
        const n_args = @typeInfo(@TypeOf(T.init)).@"fn".params.len;
        if (comptime n_args == 0) return T.init();
        const params = config_mod.effectParams(cfg, section);
        return switch (comptime n_args) {
            1 => T.init(params),
            2 => T.init(allocator, params),
            4 => T.init(allocator, width, height, params),
            else => @compileError("unsupported Context.init signature on " ++ @typeName(T)),
        };
    }

    pub fn init(name: []const u8, allocator: std.mem.Allocator, width: f32, height: f32, cfg: *const config_mod.Config) !Effect {
        // A component effect (`effects/<name>/effect.zig`) wins over a built-in
        // of the same name: it is the user's explicit override. It compiles on
        // load and runs through the C ABI.
        if (try plugin_mod.Instance.maybeCreate(width, height, cfg)) |inst| {
            return .{ .plugin = inst };
        }

        // A name matching a built-in variant builds its context. Anything
        // else is a user shader from the system `shaders/` tree (an arbitrary
        // `<subdir>/<frag-stem>`, or a top-level frag with no built-in) and
        // runs on the shared stateless context, like liquid2. The shader file
        // itself is resolved by the caller; here we only build the context.
        inline for (@typeInfo(Effect).@"union".fields) |f| {
            if (comptime std.mem.eql(u8, f.name, "plugin") or std.mem.eql(u8, f.name, "custom")) continue;
            if (std.mem.eql(u8, name, comptime cliName(f.name))) {
                return @unionInit(Effect, f.name, try initContext(f.type, allocator, width, height, cfg, comptime paramSection(f.name)));
            }
        }
        return .{ .custom = try initContext(liquid2.Context, allocator, width, height, cfg, comptime paramSection("custom")) };
    }

    pub fn update(self: *Effect, state: FrameState) void {
        switch (self.*) {
            inline else => |*ctx| ctx.update(state),
        }
    }

    pub fn upload(self: *Effect, prog: *const shader_mod.ShaderProgram) void {
        switch (self.*) {
            inline else => |*ctx| ctx.upload(prog),
        }
    }

    pub fn deinit(self: *Effect) void {
        switch (self.*) {
            inline else => |*ctx| ctx.deinit(),
        }
    }

    /// CLI-style name of the live variant, so a
    /// caller can rebuild the same effect without going through config state
    /// that may have drifted from what is actually running.
    pub fn cliNameOf(self: *const Effect) []const u8 {
        return switch (self.*) {
            .plugin => |*p| p.name(),
            inline else => |_, tag| comptime cliName(@tagName(tag)),
        };
    }

    /// Fragment shader an effect loads by default, as a path relative to the
    /// system `shaders/` tree (`<variant>.frag`), except the variants that
    /// share another effect's shader. Resolve with `config.resolveShaderPath`.
    pub fn defaultShader(self: *const Effect) []const u8 {
        return switch (self.*) {
            .plugin => |*p| p.shader(),
            inline else => |_, tag| comptime shaderOf(@tagName(tag)),
        };
    }

    /// The default shader for an effect by its CLI name, without building it
    /// (no audio thread, no GL); null for an empty name. A component effect's
    /// shader lives next to its `effect.zig`; any other non-built-in name is a
    /// shader in the system `shaders/` tree, addressed by its path relative to
    /// that tree (`<subdir>/<frag-stem>`).
    pub fn defaultShaderFor(name: []const u8) ?[]const u8 {
        if (plugin_mod.componentShader(name)) |p| return p;
        inline for (@typeInfo(Effect).@"union".fields) |f| {
            if (comptime std.mem.eql(u8, f.name, "plugin")) continue;
            if (std.mem.eql(u8, name, comptime cliName(f.name))) return comptime shaderOf(f.name);
        }
        if (name.len == 0 or name.len + 5 > shader_name_buf.len) return null;
        // Static buffer: the result isn't freed by callers, and calls happen
        // once per config load / reload.
        const out = std.fmt.bufPrint(&shader_name_buf, "{s}.frag", .{name}) catch return null;
        return out;
    }

    var shader_name_buf: [160]u8 = undefined;
};

fn shaderOf(comptime field_name: []const u8) []const u8 {
    // liquid2 keeps the shader inside the user-maintained customs directory,
    // so it stays hot-editable at its canonical location.
    if (comptime std.mem.eql(u8, field_name, "liquid2"))
        return "customs/liquid2.frag";
    const base = field_name;
    return base ++ ".frag";
}

/// CLI-style effect name: the union field name with `_` rewritten to `-`
/// (e.g. underscores in field names become hyphens). Comptime only.
fn cliName(comptime field_name: []const u8) []const u8 {
    var out: [field_name.len]u8 = undefined;
    for (field_name, 0..) |ch, i| out[i] = if (ch == '_') '-' else ch;
    const final = out;
    return &final;
}

/// Comma-joined list of all effect names with `_` rewritten to `-`.
/// Derived at comptime from the `Effect` union so error messages and CLI
/// help can't drift from the actual variant set.
pub const effect_names_csv: []const u8 = blk: {
    var out: []const u8 = "";
    for (@typeInfo(Effect).@"union".fields, 0..) |f, i| {
        if (!(std.mem.eql(u8, f.name, "custom"))) { // subdir backing, not a name
            if (i > 0) out = out ++ ", ";
            out = out ++ cliName(f.name);
        }
    }
    break :blk out;
};

/// Print the list of available effects (one per line) to stdout. Component
/// effects (`effects/<name>/effect.zig`) are listed first, then every `.frag`
/// under the packaged `shaders/` tree at any depth, addressed by its path
/// relative to that tree (`<subdir>/<frag-stem>`). Names are taken verbatim
/// from the files, matching how `defaultShaderFor` resolves them. Read on every
/// invocation, so it tracks the installed tree.
pub fn listEffects(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var stdout_buf: [1024]u8 = undefined;
    const io = std.Io.Threaded.global_single_threaded.io();
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const w = &stdout_writer.interface;

    plugin_mod.listComponents(w);
    _ = scanFrags(w, config_mod.system_shaders_dir, "") catch {};
    try w.flush();
}

/// Recursively print every `*.frag` under `base`/`rel` as a shaders-tree
/// relative effect name. Returns whether anything was printed. Symlinked
/// directories (the `customs` tree) are followed.
fn scanFrags(w: *std.Io.Writer, base: []const u8, rel: []const u8) !bool {
    var path_buf: [1024]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&path_buf, "{s}{s}{s}", .{
        base,
        if (rel.len == 0) "" else "/",
        rel,
    }) catch return false;
    const dir = libc.opendir(dir_path.ptr) orelse return false;
    defer libc.closedir(dir);

    var found = false;
    while (libc.readdir(dir)) |de| {
        const fname = std.mem.sliceTo(&de.d_name, 0);
        if (fname.len == 0 or fname.len > 240) continue;
        if (std.mem.eql(u8, fname, ".") or std.mem.eql(u8, fname, "..")) continue;

        var child_buf: [512]u8 = undefined;
        const child = std.fmt.bufPrint(&child_buf, "{s}{s}{s}", .{
            rel,
            if (rel.len == 0) "" else "/",
            fname,
        }) catch continue;

        // DT_DIR (4), a symlink (10, possibly to a directory), or DT_UNKNOWN
        // (0): recurse when it actually opens as a directory.
        if ((de.d_type == 4 or de.d_type == 10 or de.d_type == 0) and child.len <= 240 and isDir(base, child)) {
            if (scanFrags(w, base, child) catch false) found = true;
            continue;
        }
        if (fname.len > 5 and std.mem.endsWith(u8, fname, ".frag")) {
            try w.print("{s}\n", .{child[0 .. child.len - 5]});
            found = true;
        }
    }
    return found;
}

fn isDir(base: []const u8, rel: []const u8) bool {
    var path_buf: [1024]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ base, rel }) catch return false;
    const d = libc.opendir(dir_path.ptr) orelse return false;
    libc.closedir(d);
    return true;
}

const libc = iohelp.libc;
