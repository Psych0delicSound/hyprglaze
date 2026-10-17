//! The per-frame desktop snapshot handed to effects, plus the mapped-window
//! class/title carried alongside it. Lives in `core` (not `effects.zig`) so
//! both the effect union and the plugin host can name it without an import
//! cycle.

const std = @import("std");

const shader_mod = @import("shader.zig");
const transition_mod = @import("transition.zig");
const palette_mod = @import("palette.zig");

/// Class and title of one mapped window (truncated copies), parallel to
/// `FrameState.windows` by index.
pub const WindowInfo = struct {
    class: [64]u8 = undefined,
    class_len: u8 = 0,
    title: [64]u8 = undefined,
    title_len: u8 = 0,
};

/// Per-frame snapshot of the desktop handed to every effect's `update`.
/// The slice fields (`windows`, `window_info`) and the `palette` pointer are
/// only valid for the duration of the call - effects that need them later
/// (e.g. in `upload`) must copy what they keep.
pub const FrameState = struct {
    dt: f32,
    time: f32,
    cursor: [2]f32,
    focused_win: transition_mod.Rect,
    windows: []const shader_mod.ShaderProgram.WindowRect,
    window_info: ?[]const WindowInfo = null,
    focused_class: [64]u8 = [_]u8{0} ** 64,
    focused_class_len: u8 = 0,
    focused_title: [64]u8 = [_]u8{0} ** 64,
    focused_title_len: u8 = 0,
    palette: ?*const palette_mod.Palette = null,
    /// Workspace slide settling: 0 = switch just happened, 1 = settled.
    /// Effects can use it to suppress per-window churn mid-slide.
    workspace_slide: f32 = 1.0,
    /// Bumped on every workspace change, slid or snapped. Window rects jump
    /// across a switch without the windows themselves having moved.
    workspace_switches: u32 = 0,
    /// Windows whose `closewindow` event arrived since the last frame.
    /// Absence from `windows` alone is ambiguous: a window on another
    /// workspace is also absent.
    closed_windows: []const u64 = &.{},
};
