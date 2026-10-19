//! effects/acrylic — a theme-black liquid that the windows stir.
//!
//! The surface is a particle pool, not a shader fold. `system.zig` is the
//! substepped XPBD solver lifted from the particles effect, with the magnetic
//! parts removed: no focused-window gravity well, no cursor push, no impact
//! pops. What is left is a dense, low-friction, near-inelastic packing that
//! behaves like a liquid: it rests as a pool, and a window moving through it is
//! a leaf dragged across water — it shoves particles aside and the pressure
//! wave travels through the packing.
//!
//! The majority of the particles are theme black; the rest pick accent slots
//! from the palette, so black is the bulk of the liquid and the coloured parts
//! are carried around by the flow. The pool is splatted into a coarse
//! density/colour/velocity field (the swarm trick) and `acrylic.frag` shades
//! that field; the shader never loops over particles.
//!
//! Windows enter the solver as kinematic colliders. Everything else here is
//! the frame snapshot: window rects for velocities, and the palette.

const std = @import("std");

const hg = @import("hg.zig");
const system = @import("system.zig");

const c = hg.c;
const gl = hg.gl;

// Coarse field. Linear-filtered, so it reads as a smooth liquid surface;
// 256x144 is ~36864 cells (a particle splat touches a few dozen of them).
const field_w = 256;
const field_h = 144;
const field_cells = field_w * field_h;

const max_windows = system.max_colliders;
const max_palette = 16;

/// Velocity mapped to ±1 in the RG channels.
const vel_scale: f32 = 900.0;
/// Accent light is normalized by density; a little boost keeps the minority
/// colours readable against the black bulk.
const accent_boost: f32 = 1.35;

/// Palette slots the accent particles draw from (the theme black is separate,
/// in `iPaletteBg`).
const accent_index = [system.accent_slots]u8{ 1, 2, 3, 4, 5, 6 };
const accent_fallback = [system.accent_slots][3]f32{
    .{ 0.87, 0.27, 0.23 }, // warm red
    .{ 0.95, 0.63, 0.22 }, // amber
    .{ 0.31, 0.70, 0.36 }, // green
    .{ 0.22, 0.69, 0.70 }, // teal
    .{ 0.20, 0.45, 0.90 }, // blue
    .{ 0.80, 0.31, 0.76 }, // magenta
};

const Accum = struct {
    dens: [field_cells]f32,
    velx: [field_cells]f32,
    vely: [field_cells]f32,
    acc_r: [field_cells]f32,
    acc_g: [field_cells]f32,
    acc_b: [field_cells]f32,
    /// RGB = density-weighted accent colour, A = soft-saturated density.
    field_bytes: [field_cells * 4]u8,
    /// RG = density-weighted velocity, biased to [0,1].
    flow_bytes: [field_cells * 2]u8,
};

const State = struct {
    sys: system.ParticleSystem,
    accum: *Accum,

    // Last frame's window rects by address, for window velocities.
    prev_addr: [max_windows]u64 = [_]u64{0} ** max_windows,
    prev_rect: [max_windows]system.Rect = undefined,
    prev_count: usize = 0,
    last_ws_switches: u32 = 0,
    last_slide: f32 = 1.0,

    accent_rgb: [system.accent_slots][3]f32 = accent_fallback,

    now: f64 = 0,

    // GL resources — created lazily on the first upload, when GL is current.
    field_tex: gl.GLuint = 0,
    flow_tex: gl.GLuint = 0,

    u: hg.Uniforms(.{
        .field = "iAcrField",
        .flow = "iAcrFlowTex",
        .time = "iAcrTime",
        .active = "iAcrActive",
    }) = .{},
};

fn create(host: [*c]const c.hg_host, width: f32, height: f32) callconv(.c) ?*anyopaque {
    const hp = hg.Host{ .raw = @ptrCast(host) };

    const state = hg.allocator.create(State) catch return null;
    const accum = hg.allocator.create(Accum) catch {
        hg.allocator.destroy(state);
        return null;
    };
    accum.* = std.mem.zeroes(Accum);

    // A particle radius that reads as a liquid at any output size. The pool
    // auto-scales its count with the surface area so the packing density stays
    // similar on a laptop and on a 4K panel.
    const min_dim = @max(@min(width, height), 1.0);
    const radius = std.math.clamp(hp.getFloat("radius", 0.028), 0.010, 0.060) * min_dim;

    const auto_count: i64 = @intFromFloat(@round(380.0 * (width * height) / 1_920_000.0));
    const count: u32 = @intCast(std.math.clamp(
        hp.getInt("count", auto_count),
        40,
        @as(i64, system.max_balls),
    ));

    // Black is the bulk of the liquid: at least half the particles, 88% by
    // default. The rest are accent-coloured.
    const black = std.math.clamp(hp.getFloat("black", 0.88), 0.5, 1.0);

    var sys = system.ParticleSystem.init(count, width, height, radius, black);
    sys.params.drag = std.math.clamp(hp.getFloat("viscosity", 0.40), 0.05, 3.0);
    sys.params.current = 20.0 * std.math.clamp(hp.getFloat("current", 1.0), 0.0, 4.0);

    state.* = .{ .sys = sys, .accum = accum };
    return @ptrCast(state);
}

fn update(handle: ?*anyopaque, frame: [*c]const c.hg_frame) callconv(.c) void {
    const self = handle orelse return;
    const s: *State = @ptrCast(@alignCast(self));
    const f: *const c.hg_frame = @ptrCast(frame);

    const dt = std.math.clamp(f.dt, 0.0, 0.05);
    s.now += dt;

    // Window displacement is the window's own unless the workspace camera
    // moved it: a slide still blocks particles, but imparts no velocity.
    const camera_moving = f.workspace_switches != s.last_ws_switches or
        f.workspace_slide < 1.0 or s.last_slide < 1.0;
    s.last_ws_switches = f.workspace_switches;
    s.last_slide = f.workspace_slide;

    const n: usize = @intCast(@min(f.windows_len, max_windows));
    var cols: [max_windows]system.Collider = undefined;
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

    s.sys.step(dt, s.now, cols[0..n]);

    // Snapshot the palette (frame pointers die at update's return) and resolve
    // the accent slots once for the splat.
    const plen: usize = if (f.palette == null) 0 else @min(f.palette_len, max_palette);
    for (0..system.accent_slots) |k| {
        const idx = accent_index[k];
        if (plen > idx) {
            s.accent_rgb[k] = .{
                f.palette[idx * 3 + 0],
                f.palette[idx * 3 + 1],
                f.palette[idx * 3 + 2],
            };
        } else {
            s.accent_rgb[k] = accent_fallback[k];
        }
    }

    splatFields(s);
}

/// Rasterize the pool into the field the shader reads: density, density-weighted
/// accent colour, and density-weighted velocity. Each particle drops a gaussian
/// whose radius follows its physical radius, so neighbouring particles merge
/// into a continuous surface instead of reading as dots.
fn splatFields(s: *State) void {
    const a = s.accum;
    @memset(&a.dens, 0);
    @memset(&a.velx, 0);
    @memset(&a.vely, 0);
    @memset(&a.acc_r, 0);
    @memset(&a.acc_g, 0);
    @memset(&a.acc_b, 0);

    const sx = @as(f32, field_w) / s.sys.width;
    const sy = @as(f32, field_h) / s.sys.height;

    // The splat radius tracks the particle spacing, not the particle radius:
    // neighbours then overlap into one continuous sheet rather than reading as
    // separate dots.
    const n = @max(s.sys.count, 1);
    const spacing = @sqrt(s.sys.width * s.sys.height / @as(f32, @floatFromInt(n)));

    for (s.sys.balls[0..s.sys.count]) |b| {
        const kr = @max(b.r * 1.25, spacing * 0.9);
        const sigma = kr * 0.5;
        const inv2s2 = 1.0 / (2.0 * sigma * sigma);
        const kr2 = kr * kr;

        var col = [3]f32{ 0, 0, 0 };
        if (b.color >= 0) col = s.accent_rgb[@intCast(b.color)];

        const fx = b.x[0] * sx;
        const fy = b.x[1] * sy;
        const cx: i32 = @intFromFloat(@floor(fx));
        const cy: i32 = @intFromFloat(@floor(fy));
        const rx: i32 = @intFromFloat(@ceil(kr * sx));
        const ry: i32 = @intFromFloat(@ceil(kr * sy));

        var oy: i32 = -ry;
        while (oy <= ry) : (oy += 1) {
            const gy = cy + oy;
            if (gy < 0 or gy >= field_h) continue;
            const py = (@as(f32, @floatFromInt(gy)) + 0.5) / sy;
            const dy = py - b.x[1];

            var ox: i32 = -rx;
            while (ox <= rx) : (ox += 1) {
                const gx = cx + ox;
                if (gx < 0 or gx >= field_w) continue;
                const px = (@as(f32, @floatFromInt(gx)) + 0.5) / sx;
                const dx = px - b.x[0];
                const d2 = dx * dx + dy * dy;
                if (d2 > kr2) continue;

                const w = @exp(-d2 * inv2s2);
                const idx: usize = @intCast(gy * field_w + gx);
                a.dens[idx] += w;
                a.velx[idx] += b.v[0] * w;
                a.vely[idx] += b.v[1] * w;
                a.acc_r[idx] += col[0] * w;
                a.acc_g[idx] += col[1] * w;
                a.acc_b[idx] += col[2] * w;
            }
        }
    }

    for (0..field_cells) |i| {
        const d = a.dens[i];
        const inv: f32 = if (d > 1.0e-4) 1.0 / d else 0.0;
        const dens = 1.0 - @exp(-d * 0.30);

        // Average accent colour of whatever liquid is here: black particles
        // contribute nothing, so the black bulk dilutes colour naturally.
        const ar = std.math.clamp(a.acc_r[i] * inv * accent_boost, 0.0, 1.0);
        const ag = std.math.clamp(a.acc_g[i] * inv * accent_boost, 0.0, 1.0);
        const ab = std.math.clamp(a.acc_b[i] * inv * accent_boost, 0.0, 1.0);

        const vx = std.math.clamp(a.velx[i] * inv / vel_scale, -1.0, 1.0);
        const vy = std.math.clamp(a.vely[i] * inv / vel_scale, -1.0, 1.0);

        a.field_bytes[i * 4 + 0] = @intFromFloat(ar * 255.0);
        a.field_bytes[i * 4 + 1] = @intFromFloat(ag * 255.0);
        a.field_bytes[i * 4 + 2] = @intFromFloat(ab * 255.0);
        a.field_bytes[i * 4 + 3] = @intFromFloat(dens * 255.0);

        a.flow_bytes[i * 2 + 0] = @intFromFloat((vx * 0.5 + 0.5) * 255.0);
        a.flow_bytes[i * 2 + 1] = @intFromFloat((vy * 0.5 + 0.5) * 255.0);
    }
}

fn ensureGl(s: *State) bool {
    if (s.field_tex != 0 and s.flow_tex != 0) return true;

    if (s.field_tex == 0) {
        gl.glGenTextures(1, &s.field_tex);
        gl.glBindTexture(gl.GL_TEXTURE_2D, s.field_tex);
        gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA8, field_w, field_h, 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, null);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);
    }
    if (s.flow_tex == 0) {
        gl.glGenTextures(1, &s.flow_tex);
        gl.glBindTexture(gl.GL_TEXTURE_2D, s.flow_tex);
        gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RG8, field_w, field_h, 0, gl.GL_RG, gl.GL_UNSIGNED_BYTE, null);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);
    }
    return s.field_tex != 0 and s.flow_tex != 0;
}

fn upload(handle: ?*anyopaque, program: u32) callconv(.c) void {
    const self = handle orelse return;
    const s: *State = @ptrCast(@alignCast(self));
    if (!ensureGl(s)) return;

    const a = s.accum;

    gl.glActiveTexture(gl.GL_TEXTURE0);
    gl.glBindTexture(gl.GL_TEXTURE_2D, s.field_tex);
    gl.glTexSubImage2D(gl.GL_TEXTURE_2D, 0, 0, 0, field_w, field_h, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, &a.field_bytes[0]);

    gl.glActiveTexture(gl.GL_TEXTURE1);
    gl.glBindTexture(gl.GL_TEXTURE_2D, s.flow_tex);
    gl.glTexSubImage2D(gl.GL_TEXTURE_2D, 0, 0, 0, field_w, field_h, gl.GL_RG, gl.GL_UNSIGNED_BYTE, &a.flow_bytes[0]);

    s.u.use(program);
    s.u.int(.field, 0);
    s.u.int(.flow, 1);
    s.u.f1(.time, @floatCast(@mod(s.now, 3600.0)));
    s.u.f1(.active, 1.0);

    gl.glActiveTexture(gl.GL_TEXTURE0);
}

fn destroy(handle: ?*anyopaque) callconv(.c) void {
    const self = handle orelse return;
    const s: *State = @ptrCast(@alignCast(self));
    if (s.field_tex != 0) gl.glDeleteTextures(1, &s.field_tex);
    if (s.flow_tex != 0) gl.glDeleteTextures(1, &s.flow_tex);
    hg.allocator.destroy(s.accum);
    hg.allocator.destroy(s);
}

const module = c.hg_module{
    .abi_version = hg.abi_version,
    .id = "acrylic",
    .shader = "acrylic.frag",
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
