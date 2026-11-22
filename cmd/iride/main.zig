const std = @import("std");
const iride = @import("libiride");
const render = @import("render.zig");
const Source = @import("source.zig").Source;

const SIZES = [_]u16{ 16, 18, 20, 22, 24, 28, 30, 32, 36, 40, 42, 44, 48, 56, 60, 63, 64, 72, 80, 84, 88, 96, 112, 120, 126, 128, 144, 160, 168, 192, 224, 256, 288, 336, 384, 512 };
const THEME_SIZES = [_]u16{ 16, 22, 24, 32, 48, 64, 96, 128, 256, 512 };
const MAX_COMPILED = 64 * 1024 * 1024;
const USAGE =
    \\usage: iride build SOURCE OUT.iride
    \\       iride check SOURCE|FILE.iride
    \\       iride export FILE.iride DIR [CONTEXT]
    \\
;

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("iride: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn compile(io: std.Io, a: std.mem.Allocator, path: []const u8) ![]u8 {
    var src = try Source.open(io, a, path);
    defer src.close();
    var images: [SIZES.len]iride.Image = undefined;
    for (SIZES, 0..) |size, i| {
        const svg = try src.document(a, size, null);
        images[i] = .{ .size = size, .png = try render.png(a, svg, size, render.samples(size)) };
    }
    const moves = try src.choreography(a) orelse return iride.pack(a, &images, null);

    var frames: std.ArrayList(iride.motion.Image) = .empty;
    for (SIZES) |size| {
        if (size < iride.motion.FIRST_SIDE or size > iride.motion.LAST_SIDE) continue;
        for (0..moves.pieces.len) |i| {
            const svg = try src.document(a, size, i);
            try frames.append(a, try render.piece(a, svg, size, render.samples(size)));
        }
        const whole = try src.document(a, size, null);
        try frames.append(a, try render.piece(a, whole, size, render.samples(size)));
    }
    return iride.pack(a, &images, try iride.motion.pack(a, moves.pieces, moves.tracks, frames.items));
}

fn build(io: std.Io, a: std.mem.Allocator, from: []const u8, to: []const u8) !void {
    const data = try compile(io, a, from);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = to, .data = data });
}

fn check(io: std.Io, a: std.mem.Allocator, path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const stat = try cwd.statFile(io, path, .{});
    if (stat.kind == .directory) {
        _ = try compile(io, a, path);
    } else {
        try iride.verify(try cwd.readFileAlloc(io, path, a, .limited(MAX_COMPILED)));
    }
}

fn exportTheme(io: std.Io, a: std.mem.Allocator, path: []const u8, root: []const u8, context: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const data = try cwd.readFileAlloc(io, path, a, .limited(MAX_COMPILED));
    try iride.verify(data);
    const name = std.fs.path.stem(path);
    for (THEME_SIZES) |size| {
        const im = try iride.pick(data, size);
        if (im.size != size) return error.MissingSize;
        const dir = try std.fmt.allocPrint(a, "{s}/{d}x{d}/{s}", .{ root, size, size, context });
        try cwd.createDirPath(io, dir);
        const out = try std.fmt.allocPrint(a, "{s}/{s}.png", .{ dir, name });
        try cwd.writeFile(io, .{ .sub_path = out, .data = im.png });
    }
}

pub fn main(init: std.process.Init) void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = init.minimal.args.toSlice(a) catch fatal("out of memory", .{});
    if (args.len < 3) fatal("missing arguments\n{s}", .{USAGE});
    render.init();

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "build") and args.len == 4) {
        build(io, a, args[2], args[3]) catch |e| fatal("{s}: {s}", .{ args[2], @errorName(e) });
    } else if (std.mem.eql(u8, cmd, "check") and args.len == 3) {
        check(io, a, args[2]) catch |e| fatal("{s}: {s}", .{ args[2], @errorName(e) });
    } else if (std.mem.eql(u8, cmd, "export") and (args.len == 4 or args.len == 5)) {
        const context: []const u8 = if (args.len == 5) args[4] else "apps";
        exportTheme(io, a, args[2], args[3], context) catch |e| fatal("{s}: {s}", .{ args[2], @errorName(e) });
    } else fatal("unknown command\n{s}", .{USAGE});
}

test {
    _ = @import("source.zig");
    _ = @import("rim.zig");
    _ = render;
}
