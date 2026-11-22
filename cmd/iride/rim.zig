const std = @import("std");

const REFERENCE = 236.0;
const EDGE = 3.0;
const LIGHT = 2.8;
const LIGHT_PX = 0.85;
const SHADE = 1.6;
const SHADE_PX = 0.45;
const SLANT = 0.6;
const REACH = 0.75;

const Stop = struct { at: f64, opacity: f64 };
const EDGE_STOPS = [_]Stop{ .{ .at = 0, .opacity = 0.2 }, .{ .at = 1, .opacity = 0.1 } };
const LIGHT_STOPS = [_]Stop{ .{ .at = 0, .opacity = 0.95 }, .{ .at = 0.45, .opacity = 0.6 }, .{ .at = 1, .opacity = 0.25 } };
const SHADE_STOPS = [_]Stop{ .{ .at = 0, .opacity = 0.05 }, .{ .at = 0.7, .opacity = 0.15 }, .{ .at = 1, .opacity = 0.42 } };

pub const Rule = enum { nonzero, evenodd };

const Scan = struct {
    s: []const u8,
    i: usize = 0,

    fn skip(self: *Scan) void {
        while (self.i < self.s.len and std.mem.indexOfScalar(u8, " \t\r\n,", self.s[self.i]) != null) self.i += 1;
    }

    fn digits(self: *Scan) void {
        while (self.i < self.s.len and std.ascii.isDigit(self.s[self.i])) self.i += 1;
    }

    fn number(self: *Scan) !f64 {
        self.skip();
        const from = self.i;
        if (self.i < self.s.len and (self.s[self.i] == '-' or self.s[self.i] == '+')) self.i += 1;
        self.digits();
        if (self.i < self.s.len and self.s[self.i] == '.') {
            self.i += 1;
            self.digits();
        }
        if (self.i < self.s.len and (self.s[self.i] == 'e' or self.s[self.i] == 'E')) {
            self.i += 1;
            if (self.i < self.s.len and (self.s[self.i] == '-' or self.s[self.i] == '+')) self.i += 1;
            self.digits();
        }
        return std.fmt.parseFloat(f64, self.s[from..self.i]) catch error.BadPath;
    }

    fn flag(self: *Scan) !f64 {
        self.skip();
        if (self.i == self.s.len or (self.s[self.i] != '0' and self.s[self.i] != '1')) return error.BadPath;
        self.i += 1;
        return @floatFromInt(self.s[self.i - 1] - '0');
    }

    fn more(self: *Scan) bool {
        self.skip();
        return self.i < self.s.len and !std.ascii.isAlphabetic(self.s[self.i]);
    }
};

fn arity(cmd: u8) !usize {
    return switch (std.ascii.toUpper(cmd)) {
        'Z' => 0,
        'H', 'V' => 1,
        'M', 'L', 'T' => 2,
        'S', 'Q' => 4,
        'C' => 6,
        'A' => 7,
        else => error.BadPath,
    };
}

pub fn shifted(a: std.mem.Allocator, d: []const u8, dx: f64, dy: f64) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var s: Scan = .{ .s = d };
    var first = true;
    while (true) {
        s.skip();
        if (s.i == s.s.len) break;
        var cmd = s.s[s.i];
        s.i += 1;
        const n = try arity(cmd);
        if (first and std.ascii.toUpper(cmd) != 'M') return error.BadPath;
        if (n == 0) {
            try out.append(a, cmd);
            continue;
        }
        while (true) {
            var v: [7]f64 = undefined;
            const arc = cmd == 'A' or cmd == 'a';
            for (v[0..n], 0..) |*x, k| x.* = if (arc and (k == 3 or k == 4)) try s.flag() else try s.number();
            if (std.ascii.isUpper(cmd) or first) switch (cmd) {
                'A' => {
                    v[5] += dx;
                    v[6] += dy;
                },
                'H' => v[0] += dx,
                'V' => v[0] += dy,
                else => for (v[0..n], 0..) |*x, k| {
                    x.* += if (k % 2 == 0) dx else dy;
                },
            };
            try out.append(a, if (first) 'M' else cmd);
            for (v[0..n]) |x| try out.print(a, "{d} ", .{x});
            first = false;
            if (cmd == 'M') cmd = 'L';
            if (cmd == 'm') cmd = 'l';
            if (!s.more()) break;
        }
    }
    if (first) return error.BadPath;
    return out.toOwnedSlice(a);
}

pub fn write(a: std.mem.Allocator, out: *std.ArrayList(u8), id: usize, d: []const u8, rule: Rule, canvas: f64, box: [4]f64, size: f64) !void {
    const k = canvas / REFERENCE;
    const px = REFERENCE / size;
    const x2 = box[0] + (box[2] - box[0]) * REACH;

    try out.print(a, "<defs><clipPath id=\"rim{d}\"><path d=\"{s}\" clip-rule=\"{s}\"/></clipPath>", .{ id, d, @tagName(rule) });
    for ([_][]const Stop{ &EDGE_STOPS, &LIGHT_STOPS, &SHADE_STOPS }, 0..) |stops, i| {
        try out.print(a, "<linearGradient id=\"rim{d}g{d}\" x1=\"{d}\" y1=\"{d}\" x2=\"{d}\" y2=\"{d}\" gradientUnits=\"userSpaceOnUse\">", .{ id, i, box[0], box[1], x2, box[3] });
        for (stops) |stop| try out.print(a, "<stop offset=\"{d}\" stop-color=\"#ffffff\" stop-opacity=\"{d:.3}\"/>", .{ stop.at, stop.opacity });
        try out.appendSlice(a, "</linearGradient>");
    }
    try out.print(a, "</defs><g clip-path=\"url(#rim{d})\"><path d=\"{s}\" fill=\"none\" stroke=\"url(#rim{d}g0)\" stroke-width=\"{d}\"/>", .{ id, d, id, EDGE * k });

    const widths = [_]f64{ @max(LIGHT, px * LIGHT_PX), -@max(SHADE, px * SHADE_PX) };
    for (widths, 1..) |w, i| {
        const moved = try shifted(a, d, w * k * SLANT, w * k);
        defer a.free(moved);
        try out.print(a, "<path d=\"{s}{s}\" fill=\"url(#rim{d}g{d})\" fill-rule=\"evenodd\"/>", .{ d, moved, id, i });
    }
    try out.appendSlice(a, "</g>");
}

test "absolute commands move and relative ones stay" {
    const a = std.testing.allocator;
    const got = try shifted(a, "m1 2 3 4H5v6A1 1 0 017 8z", 10, 20);
    defer a.free(got);
    try std.testing.expectEqualStrings("M11 22 l3 4 H15 v6 A1 1 0 0 1 17 28 z", got);
}

test "paths cannot carry markup" {
    try std.testing.expectError(error.BadPath, shifted(std.testing.allocator, "M0 0\"/><image", 1, 1));
}
