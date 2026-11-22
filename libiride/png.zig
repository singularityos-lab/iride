const std = @import("std");
const flate = std.compress.flate;

const SIGNATURE = "\x89PNG\r\n\x1a\n";
const CHUNK = 12;
const IHDR = 13;
const FIRST = SIGNATURE.len + CHUNK + IHDR;
const RGBA8 = [_]u8{ 8, 6, 0, 0, 0 };

const Idat = struct {
    png: []const u8,
    at: usize = FIRST,
    part: []const u8 = "",
    interface: std.Io.Reader,

    fn init(png: []const u8, buffer: []u8) Idat {
        return .{ .png = png, .interface = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 } };
    }

    fn next(self: *Idat) std.Io.Reader.Error!void {
        while (self.part.len == 0) {
            if (self.at + CHUNK > self.png.len) return error.ReadFailed;
            const len: usize = std.mem.readInt(u32, self.png[self.at..][0..4], .big);
            if (len > self.png.len - self.at - CHUNK) return error.ReadFailed;
            const kind = self.png[self.at + 4 ..][0..4];
            if (std.mem.eql(u8, kind, "IEND")) return error.EndOfStream;
            if (std.mem.eql(u8, kind, "IDAT")) self.part = self.png[self.at + 8 ..][0..len];
            self.at += CHUNK + len;
        }
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Idat = @alignCast(@fieldParentPtr("interface", r));
        try self.next();
        const n = try w.write(limit.sliceConst(self.part));
        self.part = self.part[n..];
        return n;
    }
};

fn paeth(left: u8, up: u8, corner: u8) u8 {
    const p = @as(i16, left) + up - corner;
    const a = @abs(p - left);
    const b = @abs(p - up);
    const c = @abs(p - corner);
    if (a <= b and a <= c) return left;
    return if (b <= c) up else corner;
}

fn unfilter(kind: u8, row: []u8, above: ?[]const u8) !void {
    if (kind > 4) return error.Corrupt;
    for (row, 0..) |*v, i| {
        const left: u8 = if (i >= 4) row[i - 4] else 0;
        const up: u8 = if (above) |line| line[i] else 0;
        const corner: u8 = if (i >= 4) (if (above) |line| line[i - 4] else 0) else 0;
        v.* +%= switch (kind) {
            1 => left,
            2 => up,
            3 => @intCast((@as(u16, left) + up) / 2),
            4 => paeth(left, up, corner),
            else => 0,
        };
    }
}

fn scaled(v: u8, alpha: u8) u8 {
    return @intCast((@as(u32, v) * alpha + 127) / 255);
}

pub fn decode(png: []const u8, side: u16, out: []u8) !void {
    const stride = @as(usize, side) * 4;
    const size = stride * side;
    if (out.len < size) return error.Space;
    if (png.len < FIRST or !std.mem.startsWith(u8, png, SIGNATURE)) return error.Corrupt;
    const head = png[SIGNATURE.len..][0 .. 8 + IHDR];
    if (!std.mem.eql(u8, head[4..8], "IHDR") or !std.mem.eql(u8, head[16..21], &RGBA8)) return error.Corrupt;
    if (std.mem.readInt(u32, head[8..12], .big) != side or std.mem.readInt(u32, head[12..16], .big) != side) return error.Corrupt;

    var buffer: [1024]u8 = undefined;
    var input = Idat.init(png, &buffer);
    var window: [flate.max_window_len]u8 = undefined;
    var unpack = flate.Decompress.init(&input.interface, .zlib, &window);
    for (0..side) |y| {
        const kind = unpack.reader.takeByte() catch return error.Corrupt;
        const row = out[y * stride ..][0..stride];
        unpack.reader.readSliceAll(row) catch return error.Corrupt;
        try unfilter(kind, row, if (y > 0) out[(y - 1) * stride ..][0..stride] else null);
    }

    var at: usize = 0;
    while (at < size) : (at += 4) {
        const p = out[at..][0..4];
        const s = p.*;
        p.* = .{ scaled(s[2], s[3]), scaled(s[1], s[3]), scaled(s[0], s[3]), s[3] };
    }
}

fn testChunk(w: *std.Io.Writer, kind: *const [4]u8, body: []const u8) !void {
    try w.writeInt(u32, @intCast(body.len), .big);
    try w.writeAll(kind);
    try w.writeAll(body);
    try w.writeInt(u32, 0, .big);
}

pub fn testEncode(gpa: std.mem.Allocator, side: u16, rows: []const u8) ![]u8 {
    var z = try std.Io.Writer.Allocating.initCapacity(gpa, 64 + rows.len);
    defer z.deinit();
    var window: [flate.max_window_len]u8 = undefined;
    var packer_state = try flate.Compress.init(&z.writer, &window, .zlib, .best);
    try packer_state.writer.writeAll(rows);
    try packer_state.finish();

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.writeAll(SIGNATURE);
    var head: [IHDR]u8 = undefined;
    std.mem.writeInt(u32, head[0..4], side, .big);
    std.mem.writeInt(u32, head[4..8], side, .big);
    head[8..13].* = RGBA8;
    try testChunk(&out.writer, "IHDR", &head);
    try testChunk(&out.writer, "pHYs", &([_]u8{0} ** 9));
    const body = z.written();
    var at: usize = 0;
    while (at < body.len) : (at += 7) try testChunk(&out.writer, "IDAT", body[at..@min(at + 7, body.len)]);
    try testChunk(&out.writer, "IEND", "");
    return out.toOwnedSlice();
}

test "every filter and a split stream decode to premultiplied pixels" {
    const gpa = std.testing.allocator;
    const side = 5;
    var straight: [side * side * 4]u8 = undefined;
    for (&straight, 0..) |*v, i| v.* = @truncate(i * 37 + 11);
    var rows: [side * (1 + side * 4)]u8 = undefined;
    for (0..side) |y| {
        const line = rows[y * (1 + side * 4) ..][0 .. 1 + side * 4];
        line[0] = @intCast(y);
        for (0..side * 4) |x| {
            const at = y * side * 4 + x;
            const left: u8 = if (x >= 4) straight[at - 4] else 0;
            const up: u8 = if (y > 0) straight[at - side * 4] else 0;
            const corner: u8 = if (x >= 4 and y > 0) straight[at - side * 4 - 4] else 0;
            line[1 + x] = straight[at] -% switch (y) {
                1 => left,
                2 => up,
                3 => @as(u8, @intCast((@as(u16, left) + up) / 2)),
                4 => paeth(left, up, corner),
                else => 0,
            };
        }
    }
    const data = try testEncode(gpa, side, &rows);
    defer gpa.free(data);
    var out: [straight.len]u8 = undefined;
    try decode(data, side, &out);
    for (0..side * side) |i| {
        const s = straight[i * 4 ..][0..4];
        const want = [4]u8{ scaled(s[2], s[3]), scaled(s[1], s[3]), scaled(s[0], s[3]), s[3] };
        try std.testing.expectEqualSlices(u8, &want, out[i * 4 ..][0..4]);
    }
    try std.testing.expectError(error.Corrupt, decode(data, side - 1, &out));
    for (0..data.len - 2 * CHUNK) |n| try std.testing.expectError(error.Corrupt, decode(data[0..n], side, &out));
}
