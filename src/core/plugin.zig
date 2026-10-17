//! Effect plugin host: discovery, compile-on-load, and the C-ABI instance
//! wrapper.
//!
//! A component effect lives at `<system_data_dir>/effects/<name>/` and owns
//! its fragment shader. It is compiled to a shared object on first load (cached
//! under `$XDG_CACHE_HOME/hyprglaze`), then dlopen'd and driven through the ABI
//! in `sdk/include/hg_plugin.h`.
//!
//! Trust: the effects tree is expected to be root-owned under
//! `/usr/share/hyprglaze` (or a user-owned dev symlink). A component whose
//! directory is group/other-writable, or owned by neither root nor the current
//! user, is refused before anything is compiled or loaded. `plugins = false`
//! in the config (or `HG_NO_PLUGINS` in the environment) disables loading
//! entirely.

const std = @import("std");
const builtin = @import("builtin");

const iohelp = @import("io_helper.zig");
const config_mod = @import("config.zig");
const frame_mod = @import("frame.zig");
const shader_mod = @import("shader.zig");
const palette_mod = @import("palette.zig");
const audio_mod = @import("../effects/audio.zig");

const c = @cImport({
    @cInclude("hg_plugin.h");
});

const log = std.log.scoped(.plugin);

pub const abi_version: u32 = c.HG_ABI_VERSION;

/// The installed effects tree and the SDK staged for compiling them.
pub const effects_dir = iohelp.system_data_dir ++ "/effects";
pub const sdk_dir = iohelp.system_data_dir ++ "/sdk";
const sdk_include_dir = sdk_dir ++ "/include";
const sdk_header_path = sdk_include_dir ++ "/hg_plugin.h";

/// Zig SDK modules staged next to every component source, so `@import("hg.zig")`
/// (and `hg.audio`) resolve. Kept in the cache key. Add new SDK `.zig` files
/// here.
const sdk_modules = [_][]const u8{ "hg.zig", "hg_audio.zig", "hg_gl.zig" };

/// Arguments after the source path for every component compile. Kept in the
/// cache key, so changing a flag recompiles.
const compile_flags = "-dynamic -fPIC -OReleaseFast -lc -lGLESv2";
const max_source = 1 << 20; // 1 MiB cap on any compiled source file
const max_windows = shader_mod.max_windows;
const max_component_files = 64; // .zig files a single component may hold

// --- discovery ---------------------------------------------------------------

/// Whether `plugins = false` (config) or `HG_NO_PLUGINS` (environment) turns
/// component loading off.
pub fn enabled(cfg: *const config_mod.Config) bool {
    if (!cfg.plugins) return false;
    return std.c.getenv("HG_NO_PLUGINS") == null;
}

/// A component name is a single path element. Reject anything that could
/// escape `effects_dir` or address a dotfile.
fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    if (name[0] == '.') return false;
    for (name) |ch| switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.' => {},
        else => return false,
    };
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    return true;
}

fn hasEffectSource(dir: []const u8) bool {
    var buf: [1024]u8 = undefined;
    const src = std.fmt.bufPrint(&buf, "{s}/effect.zig", .{dir}) catch return false;
    return iohelp.exists(src);
}

/// The `.zig` files in a component directory, sorted by name. A component may
/// spread itself over several files (e.g. swarm's `boids.zig`); all of them are
/// staged and hashed so a change to any one recompiles it, in a stable order
/// across filesystems. Caller frees each name via `freeSources`. `effect.zig` is
/// always among them (the directory passed `hasEffectSource`).
fn componentSources(allocator: std.mem.Allocator, dir: []const u8) ![]const []const u8 {
    const libc = iohelp.libc;
    var dir_z_buf: [640]u8 = undefined;
    const dir_z = std.fmt.bufPrintZ(&dir_z_buf, "{s}", .{dir}) catch return error.PathTooLong;
    const d = libc.opendir(dir_z.ptr) orelse return error.OpenDirFailed;
    defer libc.closedir(d);

    var stack: [max_component_files][]const u8 = undefined;
    var n: usize = 0;
    while (libc.readdir(d)) |de| {
        const fname = std.mem.sliceTo(&de.d_name, 0);
        if (fname.len <= 4 or fname[0] == '.') continue;
        if (!std.mem.endsWith(u8, fname, ".zig")) continue;
        if (n == stack.len) return error.TooManySources;
        stack[n] = try allocator.dupe(u8, fname);
        n += 1;
    }
    const out = try allocator.alloc([]const u8, n);
    @memcpy(out, stack[0..n]);
    // Insertion sort: n is tiny, and it keeps the hash order deterministic.
    for (1..n) |i| {
        var j = i;
        while (j > 0 and std.mem.order(u8, out[j - 1], out[j]) == .gt) : (j -= 1) {
            std.mem.swap([]const u8, &out[j - 1], &out[j]);
        }
    }
    return out;
}

fn freeSources(allocator: std.mem.Allocator, sources: []const []const u8) void {
    for (sources) |s| allocator.free(s);
    allocator.free(sources);
}

/// The component directory for `name`, or null. Caller owns the returned path.
/// Refuses a directory that fails the trust check.
pub fn findComponent(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    if (!validName(name)) return null;
    const dir = std.fmt.allocPrint(allocator, "{s}/{s}", .{ effects_dir, name }) catch return null;
    if (!hasEffectSource(dir)) {
        allocator.free(dir);
        return null;
    }
    if (!trustedDir(dir)) {
        log.err("effect '{s}': refusing untrusted directory {s}", .{ name, dir });
        allocator.free(dir);
        return null;
    }
    return dir;
}

/// The component's fragment shader: `<dir>/<name>.frag` when present, else the
/// only `.frag` in the directory. Null when `name` is not a component. The
/// result lives in a static buffer; it is re-derived on each config load.
pub fn componentShader(name: []const u8) ?[]const u8 {
    if (!validName(name)) return null;
    var dir_buf: [640]u8 = undefined;
    const dir = std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ effects_dir, name }) catch return null;
    if (!hasEffectSource(dir)) return null;
    const preferred = std.fmt.bufPrint(&shader_buf, "{s}/{s}.frag", .{ dir, name }) catch return null;
    if (iohelp.exists(preferred)) return preferred;
    return firstFrag(dir);
}

var shader_buf: [1024]u8 = undefined;

fn firstFrag(dir: []const u8) ?[]const u8 {
    const libc = iohelp.libc;
    var dir_z_buf: [640]u8 = undefined;
    const dir_z = std.fmt.bufPrintZ(&dir_z_buf, "{s}", .{dir}) catch return null;
    const d = libc.opendir(dir_z.ptr) orelse return null;
    defer libc.closedir(d);
    while (libc.readdir(d)) |de| {
        const fname = std.mem.sliceTo(&de.d_name, 0);
        if (fname.len <= 5 or fname[0] == '.') continue;
        if (!std.mem.endsWith(u8, fname, ".frag")) continue;
        return std.fmt.bufPrint(&shader_buf, "{s}/{s}", .{ dir, fname }) catch null;
    }
    return null;
}

/// Print component effect names (one per line), so `--list-effects` shows them
/// alongside the shader-only effects.
pub fn listComponents(w: *std.Io.Writer) void {
    const libc = iohelp.libc;
    const d = libc.opendir(effects_dir ++ "") orelse return;
    defer libc.closedir(d);
    while (libc.readdir(d)) |de| {
        const fname = std.mem.sliceTo(&de.d_name, 0);
        if (!validName(fname)) continue;
        var dir_buf: [640]u8 = undefined;
        const dir = std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ effects_dir, fname }) catch continue;
        if (hasEffectSource(dir)) w.print("{s}\n", .{fname}) catch {};
    }
}

/// Refuse a directory that other users can write, or that is owned by neither
/// root nor the current user. `statx` follows a dev symlink to its real target.
fn trustedDir(path: []const u8) bool {
    var z_buf: [1024]u8 = undefined;
    const z = std.fmt.bufPrintZ(&z_buf, "{s}", .{path}) catch return false;
    var stx: std.os.linux.Statx = undefined;
    if (std.c.statx(std.c.AT.FDCWD, z.ptr, 0, .BASIC_STATS, &stx) != 0) return false;
    if (stx.mode & 0o022 != 0) return false; // group/other writable
    const uid = std.c.getuid();
    if (stx.uid != 0 and stx.uid != uid) return false;
    return true;
}

// --- cache -------------------------------------------------------------------

fn cacheDir() ![]const u8 {
    if (std.c.getenv("XDG_CACHE_HOME")) |z| {
        const s = std.mem.span(z);
        if (s.len > 0) return std.fmt.allocPrint(std.heap.c_allocator, "{s}/hyprglaze", .{s});
    }
    if (std.c.getenv("HOME")) |z| {
        const s = std.mem.span(z);
        return std.fmt.allocPrint(std.heap.c_allocator, "{s}/.cache/hyprglaze", .{s});
    }
    return error.NoCacheDir;
}

const Loaded = struct {
    name: []const u8,
    handle: *anyopaque,
    mod: *const c.hg_module,
};

var cache_mutex: std.atomic.Mutex = .unlocked;
var cache: std.StringHashMapUnmanaged(*Loaded) = .{};

fn cacheLock() void {
    while (!cache_mutex.tryLock()) {
        std.atomic.spinLoopHint();
    }
}

/// Load (compiling if needed) the module for a component directory. Modules
/// are cached for the process lifetime; a changed source is picked up on the
/// next daemon start.
fn loadModule(name: []const u8, dir: []const u8) !*Loaded {
    cacheLock();
    defer cache_mutex.unlock();

    if (cache.get(name)) |l| return l;

    const gpa = std.heap.c_allocator;

    // Every `.zig` in the component directory (multi-file components stage the
    // whole set), read so both the cache key and the compile see them.
    const sources = try componentSources(gpa, dir);
    defer freeSources(gpa, sources);
    const srcs = try gpa.alloc([]u8, sources.len);
    defer gpa.free(srcs);
    for (sources, 0..) |sname, i| {
        const p = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, sname });
        defer gpa.free(p);
        srcs[i] = try iohelp.readFileAlloc(gpa, p, max_source);
    }
    defer for (srcs) |b| gpa.free(b);

    // Every staged SDK module plus the header feed the cache key, so a change
    // to the SDK recompiles every component.
    var sdk_bytes: [sdk_modules.len][]u8 = undefined;
    for (sdk_modules, 0..) |m, i| {
        const p = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ sdk_dir, m });
        defer gpa.free(p);
        sdk_bytes[i] = try iohelp.readFileAlloc(gpa, p, max_source);
    }
    defer for (sdk_bytes) |b| gpa.free(b);
    const sdk_h = try iohelp.readFileAlloc(gpa, sdk_header_path, max_source);
    defer gpa.free(sdk_h);

    var hex: [16]u8 = undefined;
    computeHash(&hex, sources, srcs, &sdk_bytes, sdk_h);

    const root = try cacheDir();
    defer gpa.free(root);
    const so_path = try std.fmt.allocPrint(gpa, "{s}/{s}-{s}.so", .{ root, name, hex });
    defer gpa.free(so_path);

    if (!iohelp.exists(so_path)) {
        try compile(name, root, sources, srcs, &sdk_bytes, hex, so_path);
    }

    var z_buf: [1024]u8 = undefined;
    const z = std.fmt.bufPrintZ(&z_buf, "{s}", .{so_path}) catch return error.PathTooLong;
    const handle = std.c.dlopen(z.ptr, .{ .NOW = true }) orelse return error.DlopenFailed;
    const sym = std.c.dlsym(handle, "hg_module_entry") orelse return error.NoEntryPoint;
    const entry: *const fn () callconv(.c) [*c]const c.hg_module = @ptrCast(@alignCast(sym));
    const mod = entry();
    if (mod.*.abi_version != abi_version) {
        log.err("effect '{s}': ABI mismatch (module {d}, host {d})", .{ name, mod.*.abi_version, abi_version });
        return error.AbiMismatch;
    }

    const loaded = try gpa.create(Loaded);
    loaded.* = .{
        .name = try gpa.dupe(u8, name),
        .handle = handle,
        .mod = mod,
    };
    try cache.put(gpa, loaded.name, loaded);
    log.info("effect '{s}': loaded plugin {s}", .{ name, so_path });
    return loaded;
}

fn computeHash(
    out: *[16]u8,
    names: []const []const u8,
    srcs: []const []const u8,
    sdk: []const []const u8,
    sdk_h: []const u8,
) void {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(std.mem.asBytes(&abi_version));
    hasher.update(builtin.zig_version_string);
    hasher.update(compile_flags);
    for (names, srcs) |n, bytes| {
        hasher.update(n);
        hasher.update(bytes);
    }
    for (sdk) |bytes| hasher.update(bytes);
    hasher.update(sdk_h);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    out.* = std.fmt.bytesToHex(digest[0..8].*, .lower);
}

fn compile(
    name: []const u8,
    cache_root: []const u8,
    sources: []const []const u8,
    srcs: []const []const u8,
    sdk: []const []const u8,
    hex: [16]u8,
    out_so: []const u8,
) !void {
    const gpa = std.heap.c_allocator;
    const build_dir = try std.fmt.allocPrint(gpa, "{s}/build/{s}-{s}", .{ cache_root, name, hex });
    defer gpa.free(build_dir);
    iohelp.makePath(build_dir) catch return error.MakeDirFailed;

    for (sources, srcs) |sname, bytes| {
        const staged = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ build_dir, sname });
        defer gpa.free(staged);
        try iohelp.writeFile(staged, bytes);
    }
    for (sdk_modules, sdk) |mod, bytes| {
        const staged = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ build_dir, mod });
        defer gpa.free(staged);
        try iohelp.writeFile(staged, bytes);
    }

    const staged_effect = try std.fmt.allocPrint(gpa, "{s}/effect.zig", .{build_dir});
    defer gpa.free(staged_effect);

    const tmp_so = try std.fmt.allocPrint(gpa, "{s}.tmp.so", .{out_so});
    defer gpa.free(tmp_so);

    const emit_arg = try std.fmt.allocPrint(gpa, "-femit-bin={s}", .{tmp_so});
    defer gpa.free(emit_arg);
    const argv = [_][]const u8{
        "zig",           "build-lib", staged_effect,
        "-dynamic",      "-fPIC",     "-OReleaseFast",
        "-lc",           "-lGLESv2",  "-I",
        sdk_include_dir, emit_arg,
    };
    log.info("effect '{s}': compiling plugin", .{name});
    // The daemon's global Io is the single-threaded one, whose allocator is
    // `.failing` and environment is empty; process spawning needs both a real
    // allocator and the inherited environment, so spin up a small
    // c_allocator-backed Io for the compiler invocation.
    const env_block: std.process.Environ.Block = .{
        .slice = @ptrCast(std.mem.span(std.c.environ)),
    };
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = .{ .block = env_block } });
    defer threaded.deinit();
    const res = std.process.run(gpa, threaded.io(), .{
        .argv = &argv,
        .cwd = .{ .path = build_dir },
    }) catch |err| {
        log.err("effect '{s}': could not run the compiler: {}", .{ name, err });
        return err;
    };
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);

    const ok = switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        log.err("effect '{s}': compile failed (term={any}):\n--- stderr ---\n{s}\n--- stdout ---\n{s}", .{
            name, res.term, res.stderr, res.stdout,
        });
        return error.CompileFailed;
    }
    try iohelp.rename(tmp_so, out_so);
    log.info("effect '{s}': compiled {s}", .{ name, out_so });
}

// --- params bridge -----------------------------------------------------------

const params_vtbl = c.hg_params{
    .get_f32 = paramF32,
    .get_i64 = paramI64,
    .get_bool = paramBool,
    .get_str = paramStr,
};

fn cstr(p: [*c]const u8) []const u8 {
    if (p == null) return "";
    return std.mem.span(@as([*:0]const u8, @ptrCast(p)));
}

fn asParams(ctx: ?*anyopaque) *const config_mod.EffectParams {
    return @ptrCast(@alignCast(ctx.?));
}

fn paramF32(ctx: ?*anyopaque, key: [*c]const u8, def: f32) callconv(.c) f32 {
    return asParams(ctx).getFloat(cstr(key), def);
}
fn paramI64(ctx: ?*anyopaque, key: [*c]const u8, def: i64) callconv(.c) i64 {
    return asParams(ctx).getInt(cstr(key), def);
}
fn paramBool(ctx: ?*anyopaque, key: [*c]const u8, def: c_int) callconv(.c) c_int {
    return @intFromBool(asParams(ctx).getBool(cstr(key), def != 0));
}
fn paramStr(ctx: ?*anyopaque, key: [*c]const u8, out_len: [*c]u64) callconv(.c) [*c]const u8 {
    out_len.* = 0;
    const s = asParams(ctx).getString(cstr(key), null) orelse return null;
    out_len.* = s.len;
    return s.ptr;
}

// --- instance ----------------------------------------------------------------

/// One live plugin effect. Held by value in the `Effect` union; the underlying
/// module and its shared object outlive every instance (process-lifetime cache).
pub const Instance = struct {
    loaded: *Loaded,
    handle: ?*anyopaque,
    audio: ?*audio_mod.AudioCapture = null,

    /// Build a plugin instance for `name` if a component exists; null when
    /// `name` is not a component (or plugins are disabled).
    pub fn maybeCreate(width: f32, height: f32, cfg: *const config_mod.Config) !?Instance {
        if (!enabled(cfg)) return null;
        const effect_name = cfg.effect;
        const dir = findComponent(std.heap.c_allocator, effect_name) orelse return null;
        defer std.heap.c_allocator.free(dir);

        const loaded = try loadModule(effect_name, dir);

        // Host + params are valid for the duration of `create` only; the
        // module caches whatever it needs.
        var params = config_mod.effectParams(cfg, effect_name);
        var host = c.hg_host{
            .abi_version = abi_version,
            .params = params_vtbl,
            .params_ctx = &params,
        };
        const handle = loaded.mod.create.?(&host, width, height) orelse return error.PluginCreateFailed;
        errdefer loaded.mod.destroy.?(handle);

        var inst = Instance{ .loaded = loaded, .handle = handle };
        if (loaded.mod.wants_audio != 0 and params.getBool("music", true)) {
            inst.audio = audio_mod.spawn(std.heap.c_allocator, params) catch |err| blk: {
                log.warn("effect '{s}': audio capture failed: {}", .{ effect_name, err });
                break :blk null;
            };
        }
        return inst;
    }

    pub fn name(self: *const Instance) []const u8 {
        return std.mem.span(@as([*:0]const u8, @ptrCast(self.loaded.mod.id)));
    }

    pub fn shader(self: *const Instance) []const u8 {
        return componentShader(self.name()) orelse self.name();
    }

    pub fn update(self: *Instance, state: frame_mod.FrameState) void {
        const handle = self.handle orelse return;
        const dt = std.math.clamp(state.dt, 0.0, 0.05);

        var win_rects: [max_windows]c.hg_rect = undefined;
        const nwin = @min(state.windows.len, max_windows);
        for (0..nwin) |i| {
            const w = state.windows[i];
            win_rects[i] = .{ .x = w.x, .y = w.y, .w = w.w, .h = w.h, .address = w.address };
        }
        var infos: [max_windows]c.hg_window_info = undefined;
        if (state.window_info) |wi| {
            const ni = @min(wi.len, max_windows);
            for (0..ni) |i| {
                infos[i] = .{
                    .class = wi[i].class,
                    .class_len = wi[i].class_len,
                    .title = wi[i].title,
                    .title_len = wi[i].title_len,
                };
            }
        }

        var pal_flat: [palette_mod.max_palette_colors * 3]f32 = undefined;
        var pal_len: u32 = 0;
        var bg = [3]f32{ 0, 0, 0 };
        var fg = [3]f32{ 1, 1, 1 };
        if (state.palette) |p| {
            pal_len = p.color_count;
            for (0..p.color_count) |i| {
                pal_flat[i * 3 + 0] = p.colors[i].r;
                pal_flat[i * 3 + 1] = p.colors[i].g;
                pal_flat[i * 3 + 2] = p.colors[i].b;
            }
            bg = .{ p.background.r, p.background.g, p.background.b };
            fg = .{ p.foreground.r, p.foreground.g, p.foreground.b };
        }

        var closed: [64]u64 = undefined;
        const nclosed = @min(state.closed_windows.len, closed.len);
        @memcpy(closed[0..nclosed], state.closed_windows[0..nclosed]);

        const wave = audio_mod.waveformOr0(self.audio);

        const frame = c.hg_frame{
            .dt = dt,
            .time = state.time,
            .cursor = state.cursor,
            .focused_win = .{
                .x = state.focused_win.x,
                .y = state.focused_win.y,
                .w = state.focused_win.w,
                .h = state.focused_win.h,
                .address = 0,
            },
            .windows = &win_rects,
            .windows_len = nwin,
            .window_info = &infos,
            .focused_class = state.focused_class,
            .focused_class_len = state.focused_class_len,
            .focused_title = state.focused_title,
            .focused_title_len = state.focused_title_len,
            .palette = if (pal_len > 0) &pal_flat else null,
            .palette_len = pal_len,
            .palette_bg = bg,
            .palette_fg = fg,
            .workspace_slide = state.workspace_slide,
            .workspace_switches = state.workspace_switches,
            .closed_windows = &closed,
            .closed_windows_len = nclosed,
            .wave = &wave,
            .wave_len = wave.len,
        };
        self.loaded.mod.update.?(handle, &frame);
    }

    pub fn upload(self: *Instance, prog: *const shader_mod.ShaderProgram) void {
        if (self.handle) |h| self.loaded.mod.upload.?(h, prog.program);
    }

    pub fn deinit(self: *Instance) void {
        if (self.audio) |a| audio_mod.shutdown(a, std.heap.c_allocator);
        self.audio = null;
        if (self.handle) |h| self.loaded.mod.destroy.?(h);
        self.handle = null;
    }
};

// --- tests -------------------------------------------------------------------

test "validName accepts plain effect names and rejects traversal" {
    try std.testing.expect(validName("weft"));
    try std.testing.expect(validName("black-blue"));
    try std.testing.expect(validName("my.effect_2"));
    try std.testing.expect(!validName(""));
    try std.testing.expect(!validName("."));
    try std.testing.expect(!validName(".."));
    try std.testing.expect(!validName("../etc"));
    try std.testing.expect(!validName("a/b")); // single path element only
    try std.testing.expect(!validName(".hidden"));
    try std.testing.expect(!validName("space name"));
}

test "computeHash is deterministic and sensitive to every input" {
    const sdk = [_][]const u8{"hg"};
    const sdk_b = [_][]const u8{"hg2"};
    const names = [_][]const u8{"effect.zig"};
    const srcs = [_][]const u8{"src"};
    const srcs_b = [_][]const u8{"src2"};
    const names_b = [_][]const u8{"helper.zig"};
    var a: [16]u8 = undefined;
    var b: [16]u8 = undefined;
    computeHash(&a, &names, &srcs, &sdk, "header");
    computeHash(&b, &names, &srcs, &sdk, "header");
    try std.testing.expectEqualStrings(&a, &b);

    var src2: [16]u8 = undefined;
    computeHash(&src2, &names, &srcs_b, &sdk, "header");
    try std.testing.expect(!std.mem.eql(u8, &a, &src2));

    var name2: [16]u8 = undefined;
    computeHash(&name2, &names_b, &srcs, &sdk, "header");
    try std.testing.expect(!std.mem.eql(u8, &a, &name2));

    var sdk2: [16]u8 = undefined;
    computeHash(&sdk2, &names, &srcs, &sdk_b, "header");
    try std.testing.expect(!std.mem.eql(u8, &a, &sdk2));

    var hdr2: [16]u8 = undefined;
    computeHash(&hdr2, &names, &srcs, &sdk, "header2");
    try std.testing.expect(!std.mem.eql(u8, &a, &hdr2));
}
