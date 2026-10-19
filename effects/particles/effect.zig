//! effects/particles — balls with XPBD physics bouncing off your windows.
//!
//! Ported from the built-in `src/effects/particles/context.zig` to the
//! component ABI. `system.zig` (the substepped contact solver) travels with
//! the component; windows are kinematic colliders, the focused window is a
//! gravity well and the cursor pushes balls away, and hard ball-ball impacts
//! pop the smaller ball into an expanding ring. `particles.frag` draws the
//! balls as discs with a motion streak plus the burst rings.
//!
//! Structural changes from the built-in, beyond the ABI:
//!   * window rects, their addresses, the focused window and the cursor are
//!     read straight off the frame (frame pointers die at `update`'s return);
//!   * the solver (`system.zig`) is copied locally, as the compiler stages
//!     every `.zig` in the directory;
//!   * no audio — the effect is silent.
//!
//! The palette colours (`iPalette`/`iPaletteBg`) are the host's standard
//! uniforms; this module only pushes its own.

const std = @import("std");

const hg = @import("hg.zig");

const c = hg.c;

const system = @import("system.zig");

/// Motion streak length: where the ball was this long ago.
const trail_secs: f32 = 0.06;

const State = struct {
    sys: system.ParticleSystem,

    // Last frame's window rects by address, for window velocities.
    prev_addr: [system.max_colliders]u64 = [_]u64{0} ** system.max_colliders,
    prev_rect: [system.max_colliders]system.Rect = undefined,
    prev_count: usize = 0,
    last_ws_switches: u32 = 0,
    last_slide: f32 = 1.0,

    u: hg.Uniforms(.{
        .balls = "iBalls[0]",
        .ball_count = "iBallCount",
        .pops = "iPops[0]",
    }) = .{},
};

fn create(host: [*c]const c.hg_host, width: f32, height: f32) callconv(.c) ?*anyopaque {
    const hp = hg.Host{ .raw = @ptrCast(host) };
    const state = hg.allocator.create(State) catch return null;

    const count: u32 = @intCast(std.math.clamp(hp.getInt("count", 60), 0, system.max_balls));
    var sys = system.ParticleSystem.init(count, width, height);
    // Both knobs predate the rewrite and were per-step at 30Hz: keep
    // their meaning in the new units.
    const damping = std.math.clamp(hp.getFloat("damping", 0.999), 0.5, 1.0);
    sys.params.drag = -@log(damping) * 30.0;
    sys.params.pop_speed = hp.getFloat("pop_threshold", 50.0) * 30.0;

    state.* = .{ .sys = sys };
    return @ptrCast(state);
}

fn update(handle: ?*anyopaque, frame: [*c]const c.hg_frame) callconv(.c) void {
    const self = handle orelse return;
    const s: *State = @ptrCast(@alignCast(self));
    const f: *const c.hg_frame = @ptrCast(frame);

    const dt = @min(f.dt, 0.05);

    // Window displacement is the window's own unless the workspace
    // camera moved it (a slide, or a snap across workspaces): then
    // windows still block, but bat nothing.
    const camera_moving = f.workspace_switches != s.last_ws_switches or
        f.workspace_slide < 1.0 or s.last_slide < 1.0;
    s.last_ws_switches = f.workspace_switches;
    s.last_slide = f.workspace_slide;

    const n = @min(@as(usize, @intCast(f.windows_len)), system.max_colliders);
    var cols: [system.max_colliders]system.Collider = undefined;
    for (0..n) |i| {
        const w = f.windows[i];
        const to = system.Rect{ .x = w.x, .y = w.y, .w = w.w, .h = w.h };
        var from = to;
        var known = false;
        for (s.prev_addr[0..s.prev_count], s.prev_rect[0..s.prev_count]) |a, r| {
            if (a == w.address and a != 0) {
                from = r;
                known = true;
                break;
            }
        }
        cols[i] = .{ .from = from, .to = to, .moving = known and !camera_moving };
    }
    for (0..n) |i| {
        const w = f.windows[i];
        s.prev_addr[i] = w.address;
        s.prev_rect[i] = .{ .x = w.x, .y = w.y, .w = w.w, .h = w.h };
    }
    s.prev_count = n;

    // The focused window is the gravity well.
    const fw = f.focused_win;
    const well: ?[2]f32 = if (fw.w > 0 and fw.h > 0) .{ fw.x + fw.w * 0.5, fw.y + fw.h * 0.5 } else null;

    const cursor = [2]f32{ f.cursor[0], f.cursor[1] };
    s.sys.step(dt, well, cursor, cols[0..n]);
}

fn upload(handle: ?*anyopaque, program: u32) callconv(.c) void {
    const self = handle orelse return;
    const s: *State = @ptrCast(@alignCast(self));

    s.u.use(program);

    // Two vec4 per ball: (x, y, r, colour), (streak tail x, y, 0, 0).
    var buf: [system.max_balls * 2][4]f32 = undefined;
    const count = s.sys.count;
    for (s.sys.balls[0..count], 0..) |b, i| {
        var tx = b.x[0] - b.v[0] * trail_secs;
        var ty = b.x[1] - b.v[1] * trail_secs;
        // Cap the streak so a batted ball reads as fast, not as a line.
        const dx = tx - b.x[0];
        const dy = ty - b.x[1];
        const len = @sqrt(dx * dx + dy * dy);
        const cap = b.r * 6.0;
        if (len > cap) {
            tx = b.x[0] + dx / len * cap;
            ty = b.x[1] + dy / len * cap;
        }
        buf[i * 2] = .{ b.x[0], b.x[1], b.r, b.color };
        buf[i * 2 + 1] = .{ tx, ty, 0, 0 };
    }
    s.u.f4v(.balls, @intCast(count * 2), &buf[0]);
    s.u.int(.ball_count, @intCast(count));

    if (s.u.loc(.pops) >= 0) {
        // (x, y, r, colour + age): age in [0, 1), colour's integer part
        // picks the palette slot.
        var pv: [system.max_pops][4]f32 = undefined;
        for (s.sys.pops, 0..) |p, i| {
            pv[i] = .{ p.x[0], p.x[1], if (p.age < 1) p.r else 0, @floor(p.color * 5.99) + @min(p.age, 0.999) };
        }
        s.u.f4v(.pops, system.max_pops, &pv[0]);
    }
}

fn destroy(handle: ?*anyopaque) callconv(.c) void {
    const self = handle orelse return;
    const s: *State = @ptrCast(@alignCast(self));
    hg.allocator.destroy(s);
}

const module = c.hg_module{
    .abi_version = hg.abi_version,
    .id = "particles",
    .shader = "particles.frag",
    .config_section = null,
    .wants_audio = 0,
    .create = create,
    .update = update,
    .upload = upload,
    .destroy = destroy,
};

export fn hg_module_entry() callconv(.c) *const c.hg_module {
    return &module;
}
