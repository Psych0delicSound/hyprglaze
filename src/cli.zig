//! Command-line parsing.
//!
//! The string fields borrow from argv, which lives for the whole process, so
//! nothing here is allocated and there is nothing to free.

const std = @import("std");

pub const CliArgs = struct {
    output: ?[]const u8 = null,
    shader_path: ?[]const u8 = null,
    theme_name: ?[]const u8 = null,
    config_path: ?[]const u8 = null,
    effect_name: ?[]const u8 = null,
    set_theme: ?[]const u8 = null,
    list_themes: bool = false,
    list_effects: bool = false,
    fps: bool = false,
};

pub const usage_text =
    \\Wayland shader wallpaper daemon for Hyprland with window-aware effects.
    \\
    \\Usage: hyprglaze [options]
    \\
    \\  --output NAME      Monitor to render on, per `hyprctl monitors`
    \\                     (default: the focused monitor at startup)
    \\  --config PATH      TOML config path
    \\                     (default: ~/.config/hypr/hyprglaze/hyprglaze.toml)
    \\  --effect NAME      Effect to render (see --list-effects). A NAME with a
    \\                     slash selects a shader under the installed shaders/ tree
    \\  --shader PATH      Fragment shader, resolved under /usr/share/hyprglaze/
    \\                     shaders unless absolute (overrides effect default)
    \\  --theme NAME       Gogh color scheme name
    \\  --set-theme NAME   Persist a theme to the config file and exit (hot-reloads)
    \\  --list-themes      List available themes and exit
    \\  --list-effects     List available effects and exit
    \\  --fps              Log frames-per-second every second
    \\  --help, -h         Show this help
    \\
;

const StrField = enum { config, effect, shader, theme, set_theme, output };
const BoolField = enum { list_themes, list_effects, fps, help };

fn strField(key: []const u8) ?StrField {
    const map = [_]struct { []const u8, StrField }{
        .{ "--config", .config },
        .{ "--effect", .effect },
        .{ "--shader", .shader },
        .{ "--theme", .theme },
        .{ "--set-theme", .set_theme },
        .{ "--output", .output },
    };
    for (map) |e| if (std.mem.eql(u8, key, e[0])) return e[1];
    return null;
}

fn boolField(key: []const u8) ?BoolField {
    const map = [_]struct { []const u8, BoolField }{
        .{ "--list-themes", .list_themes },
        .{ "--list-effects", .list_effects },
        .{ "--fps", .fps },
        .{ "--help", .help },
        .{ "-h", .help },
    };
    for (map) |e| if (std.mem.eql(u8, key, e[0])) return e[1];
    return null;
}

/// Minimal in-tree CLI parser. Supports `--key value`, `--key=value`, and
/// bool flags; an unknown argument is an error. `--help` prints the usage
/// and exits. `argv[0]` (the program path) is skipped.
pub fn parse(argv: []const [*:0]const u8) !CliArgs {
    var out = CliArgs{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = std.mem.span(argv[i]);
        // Split "--key=value" → key, value.
        var key: []const u8 = arg;
        var value: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
            key = arg[0..eq];
            value = arg[eq + 1 ..];
        }

        if (strField(key)) |sk| {
            const v = value orelse blk: {
                i += 1;
                if (i >= argv.len) {
                    std.log.err("missing value for {s}", .{key});
                    return error.MissingArgValue;
                }
                break :blk std.mem.span(argv[i]);
            };
            switch (sk) {
                .config => out.config_path = v,
                .effect => out.effect_name = v,
                .shader => out.shader_path = v,
                .theme => out.theme_name = v,
                .set_theme => out.set_theme = v,
                .output => out.output = v,
            }
            continue;
        }

        const bk = boolField(key) orelse {
            std.log.err("unknown argument: {s}", .{arg});
            return error.UnknownArg;
        };
        switch (bk) {
            .list_themes => out.list_themes = true,
            .list_effects => out.list_effects = true,
            .fps => out.fps = true,
            .help => {
                // Plain stdout, not the log: help is program output.
                const io = std.Io.Threaded.global_single_threaded.io();
                var stdout_buf: [1024]u8 = undefined;
                var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
                stdout_writer.interface.writeAll(usage_text) catch {};
                stdout_writer.interface.flush() catch {};
                std.process.exit(0);
            },
        }
    }
    return out;
}

test "parse reads --key value, --key=value and flags without copying" {
    const argv = [_][*:0]const u8{ "hyprglaze", "--effect", "fire", "--output=DP-1", "--fps" };
    const a = try parse(&argv);
    try std.testing.expectEqualStrings("fire", a.effect_name.?);
    try std.testing.expectEqualStrings("DP-1", a.output.?);
    try std.testing.expect(a.fps);
    try std.testing.expect(a.theme_name == null);
    // Borrowed straight from argv.
    try std.testing.expectEqual(@intFromPtr(argv[2]), @intFromPtr(a.effect_name.?.ptr));
}
