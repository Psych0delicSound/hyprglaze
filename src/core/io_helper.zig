const std = @import("std");

/// Returns the process-global synchronous Io. Cheap; safe to call per-op.
/// Used by every site that touches the new std.Io.File / std.Io.Dir APIs
/// to avoid threading an Io parameter through every function signature.
pub fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const Timespec = extern struct { sec: i64, nsec: i64 };
extern "c" fn clock_gettime(clk_id: i32, tp: *Timespec) c_int;
extern "c" fn nanosleep(req: *const Timespec, rem: ?*Timespec) c_int;

/// Sleep `ns` nanoseconds.
pub fn sleepNs(ns: u64) void {
    const sec: i64 = @intCast(ns / std.time.ns_per_s);
    const nsec: i64 = @intCast(ns % std.time.ns_per_s);
    _ = nanosleep(&.{ .sec = sec, .nsec = nsec }, null);
}

/// Monotonic-clock nanoseconds.
pub fn nowNs() u64 {
    var ts: Timespec = .{ .sec = 0, .nsec = 0 };
    _ = clock_gettime(1, &ts); // CLOCK_MONOTONIC
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Minimal monotonic timer.
pub const Timer = struct {
    start_ns: u64,

    pub fn start() !Timer {
        return .{ .start_ns = nowNs() };
    }

    pub fn read(self: *const Timer) u64 {
        return nowNs() - self.start_ns;
    }

    pub fn reset(self: *Timer) void {
        self.start_ns = nowNs();
    }
};

// File helpers. Paths may be absolute or relative to the CWD: std's
// `*Absolute` variants only assert the path is absolute before opening it
// from the CWD, and that assert is a crash on a user-supplied relative path
// (`--config ./foo.toml`, a relative shader in the config).

/// Read up to `max_size` bytes of a file into a new allocation.
pub fn readFileAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    max_size: usize,
) ![]u8 {
    return readFileSentinel(allocator, path, max_size, null);
}

/// Read a file into a null-terminated buffer (for GLSL source, etc.).
pub fn readFileAlloc0(
    allocator: std.mem.Allocator,
    path: []const u8,
    max_size: usize,
) ![:0]u8 {
    return readFileSentinel(allocator, path, max_size, 0);
}

fn readFileSentinel(
    allocator: std.mem.Allocator,
    path: []const u8,
    max_size: usize,
    comptime sentinel: ?u8,
) !(if (sentinel) |s| [:s]u8 else []u8) {
    const i = io();
    const file = try std.Io.Dir.cwd().openFile(i, path, .{});
    defer file.close(i);

    const size = try file.length(i);
    if (size > max_size) return error.FileTooLarge;

    const buf = if (sentinel) |s|
        try allocator.allocSentinel(u8, @intCast(size), s)
    else
        try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(buf);
    _ = try file.readPositionalAll(i, buf, 0);
    return buf;
}

pub fn writeFile(path: []const u8, data: []const u8) !void {
    const i = io();
    const file = try std.Io.Dir.cwd().createFile(i, path, .{});
    defer file.close(i);
    try file.writeStreamingAll(i, data);
}

pub fn rename(old: []const u8, new: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try std.Io.Dir.rename(cwd, old, cwd, new, io());
}

/// mkdir -p.
pub fn makePath(path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io(), path);
}

pub fn deleteFile(path: []const u8) !void {
    try std.Io.Dir.cwd().deleteFile(io(), path);
}

pub fn exists(path: []const u8) bool {
    std.Io.Dir.cwd().access(io(), path, .{}) catch return false;
    return true;
}

pub const system_data_dir = "/usr/share/hyprglaze";

/// Resolve a shipped data file (shader, sprite): as given if it exists
/// (relative to the CWD, or absolute), else under /usr/share/hyprglaze/.
/// Null when neither exists.
pub fn resolveDataPath(path: []const u8, buf: *[512]u8) ?[]const u8 {
    if (exists(path)) return path;
    if (std.fs.path.isAbsolute(path)) return null;
    const full = std.fmt.bufPrint(buf, "{s}/{s}", .{ system_data_dir, path }) catch return null;
    return if (exists(full)) full else null;
}

test "file helpers take relative paths" {
    // The test runner's CWD is the build root.
    const data = try readFileAlloc(std.testing.allocator, "build.zig.zon", 1 << 20);
    defer std.testing.allocator.free(data);
    try std.testing.expect(std.mem.indexOf(u8, data, ".name = .hyprglaze") != null);
    try std.testing.expect(exists("./build.zig"));
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("shaders/flux.frag", resolveDataPath("shaders/flux.frag", &buf).?);
    try std.testing.expect(resolveDataPath("/nonexistent/x.frag", &buf) == null);
}

// libc shims, shared across modules so each one doesn't redeclare the externs.
pub const libc = struct {
    pub extern "c" fn close(fd: c_int) c_int;
    pub extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
    pub extern "c" fn connect(fd: c_int, addr: *const anyopaque, addrlen: u32) c_int;
    pub extern "c" fn shutdown(fd: c_int, how: c_int) c_int;
    pub extern "c" fn popen(cmd: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
    pub extern "c" fn pclose(stream: *anyopaque) c_int;
    pub extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *anyopaque) usize;
    pub const SHUT_RDWR: c_int = 2;

    // Directory walking. libc readdir instead of std.Io.Dir.iterate: the
    // Threaded Io dir iterator mishandles directory reads here (spurious
    // BADF), and discovery runs once per CLI invocation / config load.
    pub const Dirent = extern struct {
        d_ino: u64,
        d_off: i64,
        d_reclen: u16,
        d_type: u8,
        d_name: [256]u8,
    };
    pub extern "c" fn opendir(path: [*:0]const u8) ?*anyopaque;
    pub extern "c" fn readdir(dirp: *anyopaque) ?*Dirent;
    pub extern "c" fn closedir(dirp: *anyopaque) void;
};

/// Auto-detect the user's default PulseAudio sink and write its `.monitor`
/// source name into `buf`. Returns the length, or 0 on failure.
/// Used by effects/audio.zig.
pub fn autoDetectPulseMonitor(buf: *[256]u8) u16 {
    const stream = libc.popen("pactl get-default-sink 2>/dev/null", "r") orelse return 0;
    defer _ = libc.pclose(stream);

    var read_buf: [200]u8 = undefined;
    const n = libc.fread(@ptrCast(&read_buf), 1, read_buf.len, stream);
    if (n == 0) return 0;

    var len = n;
    while (len > 0 and (read_buf[len - 1] == '\n' or read_buf[len - 1] == '\r')) len -= 1;
    if (len == 0) return 0;

    const suffix = ".monitor";
    if (len + suffix.len >= buf.len) return 0;
    @memcpy(buf[0..len], read_buf[0..len]);
    @memcpy(buf[len .. len + suffix.len], suffix);
    return @intCast(len + suffix.len);
}
