const std = @import("std");
const flate = std.compress.flate;
const png = @import("png.zig");

pub const MAX_DURATION = 1000;
pub const MAX_PIECES = 20;
pub const MAX_TRACKS = 48;
pub const MAX_LEVELS = 64;
pub const FIRST_SIDE = 32;
pub const LAST_SIDE = 256;
pub const MAX_BYTES = 2 * 1024 * 1024;

const HEAD = 8;
const PIECE = 24;
const TRACK = 24;
const IMAGE = 20;
const PERSPECTIVE = 3.28;
const SETTLE = 64.0;
const VISIBLE = 1e-6;

pub const Kind = enum(u8) { translate, scale, rotate, tilt, opacity, reveal };
pub const Ease = enum(u8) { out, spring, linear, steps };

pub const Piece = struct {
    origin: [2]f32,
    clip: [4]f32 = .{ -1, -1, 2, 2 },
};

pub const Track = struct {
    piece: u8,
    kind: Kind,
    ease: Ease,
    at: u16,
    duration: u16,
    from: [4]f32,
};

pub const Image = struct {
    side: u16,
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    data: []const u8,

    fn bytes(self: Image) usize {
        return @as(usize, self.w) * self.h * 4;
    }
};

fn word(comptime T: type, data: []const u8, at: usize) T {
    return std.mem.readInt(T, data[at..][0..@sizeOf(T)], .little);
}

fn real(data: []const u8, at: usize) !f32 {
    const v: f32 = @bitCast(word(u32, data, at));
    if (!std.math.isFinite(v) or @abs(v) > 1e4) return error.Corrupt;
    return v;
}

fn member(comptime T: type, v: u8) !T {
    if (v >= @typeInfo(T).@"enum".fields.len) return error.Corrupt;
    return @enumFromInt(v);
}

pub const Clip = struct {
    data: []const u8,
    duration: u16,
    pieces: u8,
    tracks: u8,
    levels: u16,

    pub fn open(data: []const u8) !Clip {
        if (data.len < HEAD or data.len > MAX_BYTES) return error.Corrupt;
        const self: Clip = .{ .data = data, .duration = word(u16, data, 0), .pieces = data[2], .tracks = data[3], .levels = word(u16, data, 4) };
        if (self.duration == 0 or self.duration > MAX_DURATION) return error.Corrupt;
        if (self.pieces == 0 or self.pieces > MAX_PIECES or self.tracks > MAX_TRACKS) return error.Corrupt;
        if (self.levels == 0 or self.levels > MAX_LEVELS or data.len < self.table() + @as(usize, self.levels) * self.stored() * IMAGE) return error.Corrupt;
        return self;
    }

    fn stored(self: Clip) usize {
        return self.pieces;
    }

    fn table(self: Clip) usize {
        return HEAD + @as(usize, self.pieces) * PIECE + @as(usize, self.tracks) * TRACK;
    }

    fn piece(self: Clip, i: usize) !Piece {
        const at = HEAD + i * PIECE;
        var out: Piece = .{ .origin = .{ try real(self.data, at), try real(self.data, at + 4) } };
        for (&out.clip, 0..) |*v, k| v.* = try real(self.data, at + 8 + k * 4);
        return out;
    }

    fn track(self: Clip, i: usize) !Track {
        const at = HEAD + @as(usize, self.pieces) * PIECE + i * TRACK;
        var out: Track = .{
            .piece = self.data[at],
            .kind = try member(Kind, self.data[at + 1]),
            .ease = try member(Ease, self.data[at + 2]),
            .at = word(u16, self.data, at + 4),
            .duration = word(u16, self.data, at + 6),
            .from = undefined,
        };
        if (out.piece >= self.pieces or out.duration == 0 or @as(u32, out.at) + out.duration > self.duration) return error.Corrupt;
        for (&out.from, 0..) |*v, k| v.* = try real(self.data, at + 8 + k * 4);
        return out;
    }

    pub fn image(self: Clip, l: usize, i: usize) !Image {
        const e = self.data[self.table() + (l * self.stored() + i) * IMAGE ..][0..IMAGE];
        const at: u64 = word(u32, e, 12);
        const len: u64 = word(u32, e, 16);
        if (at + len > self.data.len) return error.Corrupt;
        const out: Image = .{
            .side = word(u16, e, 0),
            .x = word(u16, e, 2),
            .y = word(u16, e, 4),
            .w = word(u16, e, 6),
            .h = word(u16, e, 8),
            .data = self.data[@intCast(at)..@intCast(at + len)],
        };
        if (out.side < FIRST_SIDE or out.side > LAST_SIDE) return error.Corrupt;
        if (@as(u32, out.x) + out.w > out.side or @as(u32, out.y) + out.h > out.side) return error.Corrupt;
        return out;
    }

    pub fn verify(self: Clip) !void {
        for (0..self.pieces) |i| _ = try self.piece(i);
        for (0..self.tracks) |i| _ = try self.track(i);
        var last: u16 = 0;
        for (0..self.levels) |l| {
            const side = (try self.image(l, 0)).side;
            if (side <= last) return error.Corrupt;
            for (0..self.stored()) |i| if ((try self.image(l, i)).side != side) return error.Corrupt;
            last = side;
        }
    }

    pub fn level(self: Clip, pixels: u32) !usize {
        if (pixels < FIRST_SIDE) return error.TooSmall;
        for (0..self.levels) |l| if ((try self.image(l, 0)).side >= pixels) return l;
        return error.TooLarge;
    }

    pub fn room(self: Clip, l: usize) !usize {
        var total: usize = 0;
        for (0..self.stored()) |i| total += (try self.image(l, i)).bytes();
        const side: usize = (try self.image(l, 0)).side;
        return total + side * side * 4;
    }

    pub fn prepare(self: Clip, l: usize, work: []u8, still: []const u8) !void {
        if (work.len < try self.room(l)) return error.Space;
        var at: usize = 0;
        for (0..self.stored()) |i| {
            const im = try self.image(l, i);
            if (im.bytes() == 0) continue;
            var input: std.Io.Reader = .fixed(im.data);
            var window: [flate.max_window_len]u8 = undefined;
            var unpack = flate.Decompress.init(&input, .zlib, &window);
            unpack.reader.readSliceAll(work[at..][0..im.bytes()]) catch return error.Corrupt;
            at += im.bytes();
        }
        try png.decode(still, (try self.image(l, 0)).side, work[at..]);
    }

    fn state(self: Clip, index: usize, t: f64) !State {
        var s: State = .{};
        for (0..self.tracks) |i| {
            const k = try self.track(i);
            if (k.piece != index) continue;
            const p = std.math.clamp((t - @as(f64, @floatFromInt(k.at))) / @as(f64, @floatFromInt(k.duration)), 0, 1);
            const left = 1 - ease(k.ease, p);
            const v = k.from;
            switch (k.kind) {
                .translate => {
                    s.move[0] += v[0] * left;
                    s.move[1] += v[1] * left;
                },
                .scale => {
                    s.scale[0] += (v[0] - 1) * left;
                    s.scale[1] += (v[1] - 1) * left;
                },
                .rotate => s.rotate += v[0] * left,
                .tilt => s.tilt += v[0] * left,
                .opacity => s.opacity += (v[0] - 1) * left,
                .reveal => if (left > 0) {
                    s.reveal = .{ v[0] * left, v[1] * left, 1 + (v[2] - 1) * left, 1 + (v[3] - 1) * left };
                },
            }
        }
        s.opacity = std.math.clamp(s.opacity, 0, 1);
        return s;
    }

    pub fn frame(self: Clip, l: usize, t: f64, work: []const u8, out: []u8) !bool {
        const side: usize = (try self.image(l, 0)).side;
        if (work.len < try self.room(l) or out.len < side * side * 4) return error.Space;
        if (!(t < @as(f64, @floatFromInt(self.duration)))) return true;
        @memset(out[0 .. side * side * 4], 0);
        var at: usize = 0;
        for (0..self.pieces) |i| {
            const im = try self.image(l, i);
            if (im.side != side) return error.Corrupt;
            draw(out, side, work[at..][0..im.bytes()], im, try self.piece(i), try self.state(i, t));
            at += im.bytes();
        }
        const near = (t - @as(f64, @floatFromInt(self.duration)) + SETTLE) / SETTLE;
        if (near > 0) {
            const edge: u16 = @intCast(side);
            const whole: Image = .{ .side = edge, .x = 0, .y = 0, .w = edge, .h = edge, .data = "" };
            settle(out, side, work[at..][0..whole.bytes()], whole, near);
        }
        return false;
    }
};

const State = struct {
    move: [2]f64 = .{ 0, 0 },
    scale: [2]f64 = .{ 1, 1 },
    rotate: f64 = 0,
    tilt: f64 = 0,
    opacity: f64 = 1,
    reveal: ?[4]f64 = null,
};

fn bezier(a: f64, b: f64, u: f64) f64 {
    return 3 * (1 - u) * (1 - u) * u * a + 3 * (1 - u) * u * u * b + u * u * u;
}

fn ease(kind: Ease, p: f64) f64 {
    if (p <= 0) return 0;
    if (p >= 1) return 1;
    const c: [4]f64 = switch (kind) {
        .linear => return p,
        .steps => return @floor(p * 4) / 4,
        .out => .{ 0.22, 1, 0.36, 1 },
        .spring => .{ 0.3, 1.4, 0.5, 1 },
    };
    var low: f64 = 0;
    var high: f64 = 1;
    for (0..32) |_| {
        const u = (low + high) / 2;
        if (bezier(c[0], c[2], u) < p) low = u else high = u;
    }
    return bezier(c[1], c[3], (low + high) / 2);
}

fn forward(piece: Piece, s: State, side: f64) [9]f64 {
    const ox = piece.origin[0] * side;
    const oy = piece.origin[1] * side;
    const r = s.rotate * std.math.pi / 180.0;
    const a = s.tilt * std.math.pi / 180.0;
    const xx = @cos(r) * s.scale[0];
    const xy = -@sin(r) * s.scale[1];
    const flat_x = @sin(r) * s.scale[0];
    const flat_y = @cos(r) * s.scale[1];

    const x = [3]f64{ xx, xy, ox + s.move[0] * side - xx * ox - xy * oy };
    const yx = flat_x * @cos(a);
    const yy = flat_y * @cos(a);
    const y = [3]f64{ yx, yy, oy + s.move[1] * side - yx * ox - yy * oy };
    const d = PERSPECTIVE * side;
    const zx = flat_x * @sin(a) / d;
    const zy = flat_y * @sin(a) / d;
    const z = [3]f64{ zx, zy, -zx * ox - zy * oy };
    const centre = side / 2;

    var m: [9]f64 = undefined;
    for (0..3) |i| {
        m[i] = x[i] - centre * z[i];
        m[3 + i] = y[i] - centre * z[i];
        m[6 + i] = @as(f64, if (i == 2) 1 else 0) - z[i];
    }
    return m;
}

fn inverse(m: [9]f64) ?[9]f64 {
    const a = m[4] * m[8] - m[5] * m[7];
    const b = m[5] * m[6] - m[3] * m[8];
    const c = m[3] * m[7] - m[4] * m[6];
    const det = m[0] * a + m[1] * b + m[2] * c;
    if (@abs(det) < VISIBLE) return null;
    var out = [9]f64{
        a, m[2] * m[7] - m[1] * m[8], m[1] * m[5] - m[2] * m[4],
        b, m[0] * m[8] - m[2] * m[6], m[2] * m[3] - m[0] * m[5],
        c, m[1] * m[6] - m[0] * m[7], m[0] * m[4] - m[1] * m[3],
    };
    for (&out) |*v| v.* /= det;
    return out;
}

fn within(box: [4]f64, side: f64, x: f64, y: f64) f64 {
    const across = std.math.clamp(@min(x - box[0] * side, box[2] * side - x) + 0.5, 0, 1);
    const down = std.math.clamp(@min(y - box[1] * side, box[3] * side - y) + 0.5, 0, 1);
    return across * down;
}

fn texel(px: []const u8, im: Image, x: i64, y: i64, ch: usize) f64 {
    const i = x - im.x;
    const j = y - im.y;
    if (i < 0 or j < 0 or i >= im.w or j >= im.h) return 0;
    const at: usize = @intCast((j * im.w + i) * 4);
    return @floatFromInt(px[at + ch]);
}

fn reach(m: [9]f64, im: Image, side: usize) [4]usize {
    const size: f64 = @floatFromInt(side);
    var low = [2]f64{ size, size };
    var high = [2]f64{ 0, 0 };
    for (0..4) |corner| {
        const x: f64 = if (corner & 1 == 0) @as(f64, @floatFromInt(im.x)) - 1 else @floatFromInt(@as(u32, im.x) + im.w + 1);
        const y: f64 = if (corner & 2 == 0) @as(f64, @floatFromInt(im.y)) - 1 else @floatFromInt(@as(u32, im.y) + im.h + 1);
        const w = m[6] * x + m[7] * y + m[8];
        if (w <= VISIBLE) return .{ 0, 0, side, side };
        for (0..2) |axis| {
            const v = (m[axis * 3] * x + m[axis * 3 + 1] * y + m[axis * 3 + 2]) / w;
            low[axis] = @min(low[axis], v - 1);
            high[axis] = @max(high[axis], v + 1);
        }
    }
    var out: [4]usize = undefined;
    for (0..2) |axis| {
        out[axis] = @intFromFloat(std.math.clamp(@floor(low[axis]), 0, size));
        out[axis + 2] = @intFromFloat(std.math.clamp(@ceil(high[axis]), 0, size));
        out[axis + 2] = @max(out[axis], out[axis + 2]);
    }
    return out;
}

fn draw(out: []u8, side: usize, px: []const u8, im: Image, piece: Piece, s: State) void {
    if (s.opacity <= 0 or px.len == 0) return;
    const size: f64 = @floatFromInt(side);
    const placed = forward(piece, s, size);
    const m = inverse(placed) orelse return;
    const area = reach(placed, im, side);
    var clip: [4]f64 = undefined;
    for (&clip, piece.clip) |*v, p| v.* = p;

    for (area[1]..area[3]) |j| for (area[0]..area[2]) |i| {
        const x = @as(f64, @floatFromInt(i)) + 0.5;
        const y = @as(f64, @floatFromInt(j)) + 0.5;
        const w = m[6] * x + m[7] * y + m[8];
        if (w <= 0) continue;
        const sx = (m[0] * x + m[1] * y + m[2]) / w;
        const sy = (m[3] * x + m[4] * y + m[5]) / w;
        if (!(sx > -1 and sy > -1 and sx < size + 1 and sy < size + 1)) continue;
        var cover = s.opacity * within(clip, size, x, y);
        if (s.reveal) |box| cover *= within(box, size, sx, sy);
        if (cover <= 0) continue;

        const left = @floor(sx - 0.5 + VISIBLE);
        const top = @floor(sy - 0.5 + VISIBLE);
        const fx = @max(0, sx - 0.5 - left);
        const fy = @max(0, sy - 0.5 - top);
        const ix: i64 = @intFromFloat(left);
        const iy: i64 = @intFromFloat(top);
        var src: [4]f64 = undefined;
        for (&src, 0..) |*v, ch| {
            const high = texel(px, im, ix, iy, ch) * (1 - fx) + texel(px, im, ix + 1, iy, ch) * fx;
            const low = texel(px, im, ix, iy + 1, ch) * (1 - fx) + texel(px, im, ix + 1, iy + 1, ch) * fx;
            v.* = (high * (1 - fy) + low * fy) * cover;
        }
        const dst = out[(j * side + i) * 4 ..][0..4];
        for (dst, src) |*d, v| d.* = @intFromFloat(@min(255, @round(v + @as(f64, @floatFromInt(d.*)) * (1 - src[3] / 255))));
    };
}

fn settle(out: []u8, side: usize, px: []const u8, im: Image, near: f64) void {
    for (0..side) |j| for (0..side) |i| {
        const dst = out[(j * side + i) * 4 ..][0..4];
        for (dst, 0..) |*d, ch| {
            const was: f64 = @floatFromInt(d.*);
            d.* = @intFromFloat(@round(was + (texel(px, im, @intCast(i), @intCast(j), ch) - was) * near));
        }
    };
}

pub fn deflate(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = try std.Io.Writer.Allocating.initCapacity(gpa, 64 + raw.len / 2);
    defer out.deinit();
    var window: [flate.max_window_len]u8 = undefined;
    var packer_state = try flate.Compress.init(&out.writer, &window, .zlib, .best);
    try packer_state.writer.writeAll(raw);
    try packer_state.finish();
    return out.toOwnedSlice();
}

pub fn pack(gpa: std.mem.Allocator, pieces: []const Piece, tracks: []const Track, images: []const Image) ![]u8 {
    if (pieces.len == 0 or pieces.len > MAX_PIECES or tracks.len > MAX_TRACKS) return error.MotionLimit;
    const stored = pieces.len;
    if (images.len == 0 or images.len % stored != 0 or images.len / stored > MAX_LEVELS) return error.MotionLimit;
    var duration: u32 = 0;
    for (tracks) |k| duration = @max(duration, @as(u32, k.at) + k.duration);
    if (duration == 0 or duration > MAX_DURATION) return error.MotionTooLong;
    const table = HEAD + pieces.len * PIECE + tracks.len * TRACK;
    var total = table + images.len * IMAGE;
    for (images) |im| total += im.data.len;
    if (total > MAX_BYTES) return error.MotionTooBig;

    const out = try gpa.alloc(u8, total);
    errdefer gpa.free(out);
    @memset(out, 0);
    std.mem.writeInt(u16, out[0..2], @intCast(duration), .little);
    out[2] = @intCast(pieces.len);
    out[3] = @intCast(tracks.len);
    std.mem.writeInt(u16, out[4..6], @intCast(images.len / stored), .little);

    for (pieces, 0..) |p, i| {
        for (p.origin ++ p.clip, 0..) |v, k| std.mem.writeInt(u32, out[HEAD + i * PIECE + k * 4 ..][0..4], @bitCast(v), .little);
    }
    for (tracks, 0..) |k, i| {
        const e = out[HEAD + pieces.len * PIECE + i * TRACK ..][0..TRACK];
        e[0] = k.piece;
        e[1] = @intFromEnum(k.kind);
        e[2] = @intFromEnum(k.ease);
        std.mem.writeInt(u16, e[4..6], k.at, .little);
        std.mem.writeInt(u16, e[6..8], k.duration, .little);
        for (k.from, 0..) |v, n| std.mem.writeInt(u32, e[8 + n * 4 ..][0..4], @bitCast(v), .little);
    }
    var at = table + images.len * IMAGE;
    for (images, 0..) |im, i| {
        const e = out[table + i * IMAGE ..][0..IMAGE];
        for ([_]u16{ im.side, im.x, im.y, im.w, im.h }, 0..) |v, n| std.mem.writeInt(u16, e[n * 2 ..][0..2], v, .little);
        std.mem.writeInt(u32, e[12..16], @intCast(at), .little);
        std.mem.writeInt(u32, e[16..20], @intCast(im.data.len), .little);
        @memcpy(out[at..][0..im.data.len], im.data);
        at += im.data.len;
    }
    try (try Clip.open(out)).verify();
    return out;
}

fn testClip(gpa: std.mem.Allocator, raw: []const u8, tracks: []const Track) ![]u8 {
    const z = try deflate(gpa, raw);
    defer gpa.free(z);
    const im: Image = .{ .side = 32, .x = 0, .y = 0, .w = 32, .h = 32, .data = z };
    return pack(gpa, &.{.{ .origin = .{ 0.5, 0.5 } }}, tracks, &.{im});
}

fn testStill(gpa: std.mem.Allocator, value: u8) ![]u8 {
    var rows = [_]u8{255} ** (32 * (1 + 32 * 4));
    for (0..32) |y| {
        rows[y * (1 + 32 * 4)] = 0;
        for (0..32) |x| rows[y * (1 + 32 * 4) + 1 + x * 4 + 3] = value;
    }
    return png.testEncode(gpa, 32, &rows);
}

test "a piece at rest is drawn byte for byte" {
    const gpa = std.testing.allocator;
    var raw: [32 * 32 * 4]u8 = undefined;
    for (0..32 * 32) |i| {
        const v: u8 = @truncate(i * 7);
        raw[i * 4 ..][0..4].* = .{ v / 2, v / 3, v / 4, v };
    }
    const data = try testClip(gpa, &raw, &.{
        .{ .piece = 0, .kind = .rotate, .ease = .spring, .at = 0, .duration = 100, .from = .{ -90, 0, 0, 0 } },
        .{ .piece = 0, .kind = .opacity, .ease = .linear, .at = 300, .duration = 100, .from = .{ 1, 0, 0, 0 } },
    });
    defer gpa.free(data);
    const still = try testStill(gpa, 255);
    defer gpa.free(still);
    const clip = try Clip.open(data);
    var work: [2 * raw.len]u8 = undefined;
    var out: [raw.len]u8 = undefined;
    try clip.prepare(try clip.level(32), &work, still);
    try std.testing.expect(!try clip.frame(0, 200, &work, &out));
    try std.testing.expectEqualSlices(u8, &raw, &out);
    try std.testing.expect(try clip.frame(0, 400, &work, &out));
}

test "a track starts from its first value and waits for its delay" {
    const gpa = std.testing.allocator;
    const raw = [_]u8{255} ** (32 * 32 * 4);
    const data = try testClip(gpa, &raw, &.{.{ .piece = 0, .kind = .translate, .ease = .out, .at = 100, .duration = 200, .from = .{ 0, 0.5, 0, 0 } }});
    defer gpa.free(data);
    const still = try testStill(gpa, 255);
    defer gpa.free(still);
    const clip = try Clip.open(data);
    var work: [2 * raw.len]u8 = undefined;
    var out: [raw.len]u8 = undefined;
    try clip.prepare(0, &work, still);
    for ([_]f64{ 0, 99 }) |t| {
        _ = try clip.frame(0, t, &work, &out);
        try std.testing.expectEqual(@as(u8, 0), out[(15 * 32 + 16) * 4 + 3]);
        try std.testing.expectEqual(@as(u8, 255), out[(16 * 32 + 16) * 4 + 3]);
    }
}

test "tilt keeps the hinge in place" {
    const m = forward(.{ .origin = .{ 0.5, 0.875 } }, .{ .tilt = -62 }, 100);
    const w = m[6] * 20 + m[7] * 87.5 + m[8];
    try std.testing.expectApproxEqAbs(@as(f64, 20), (m[0] * 20 + m[1] * 87.5 + m[2]) / w, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 87.5), (m[3] * 20 + m[4] * 87.5 + m[5]) / w, 1e-9);
}

test "motion over one second and truncated motion are refused" {
    const gpa = std.testing.allocator;
    const raw = [_]u8{0} ** (32 * 32 * 4);
    try std.testing.expectError(error.MotionTooLong, testClip(gpa, &raw, &.{.{ .piece = 0, .kind = .opacity, .ease = .out, .at = 900, .duration = 101, .from = .{ 0, 0, 0, 0 } }}));
    const data = try testClip(gpa, &raw, &.{.{ .piece = 0, .kind = .opacity, .ease = .out, .at = 0, .duration = 100, .from = .{ 0, 0, 0, 0 } }});
    defer gpa.free(data);
    const still = try testStill(gpa, 255);
    defer gpa.free(still);
    for (0..data.len) |n| {
        var work: [2 * raw.len]u8 = undefined;
        const clip = Clip.open(data[0..n]) catch continue;
        try std.testing.expectError(error.Corrupt, clip.prepare(0, &work, still));
    }
}

test "the last frames settle on the whole icon" {
    const gpa = std.testing.allocator;
    const piece = [_]u8{200} ** (32 * 32 * 4);
    const a = try deflate(gpa, &piece);
    defer gpa.free(a);
    const still = try testStill(gpa, 100);
    defer gpa.free(still);
    const data = try pack(
        gpa,
        &.{.{ .origin = .{ 0.5, 0.5 } }},
        &.{.{ .piece = 0, .kind = .opacity, .ease = .linear, .at = 0, .duration = 200, .from = .{ 1, 0, 0, 0 } }},
        &.{.{ .side = 32, .x = 0, .y = 0, .w = 32, .h = 32, .data = a }},
    );
    defer gpa.free(data);
    const clip = try Clip.open(data);
    var work: [2 * piece.len]u8 = undefined;
    var out: [piece.len]u8 = undefined;
    try clip.prepare(0, &work, still);
    for ([_]f64{ 136, 168, 199.99 }, [_]u8{ 200, 150, 100 }) |t, want| {
        _ = try clip.frame(0, t, &work, &out);
        try std.testing.expectEqual(want, out[(16 * 32 + 16) * 4]);
    }
}

test "tracks of one kind add up to a swing that rests still" {
    const gpa = std.testing.allocator;
    const raw = [_]u8{0} ** (32 * 32 * 4);
    const data = try testClip(gpa, &raw, &.{
        .{ .piece = 0, .kind = .rotate, .ease = .linear, .at = 0, .duration = 100, .from = .{ -20, 0, 0, 0 } },
        .{ .piece = 0, .kind = .rotate, .ease = .linear, .at = 100, .duration = 100, .from = .{ 20, 0, 0, 0 } },
        .{ .piece = 0, .kind = .opacity, .ease = .linear, .at = 0, .duration = 100, .from = .{ 0, 0, 0, 0 } },
        .{ .piece = 0, .kind = .opacity, .ease = .linear, .at = 100, .duration = 100, .from = .{ 2, 0, 0, 0 } },
    });
    defer gpa.free(data);
    const clip = try Clip.open(data);
    for ([_]f64{ 0, 50, 100, 150, 200 }, [_]f64{ 0, 10, 20, 10, 0 }) |t, want| {
        const s = try clip.state(0, t);
        try std.testing.expectApproxEqAbs(want, s.rotate, 1e-6);
        try std.testing.expectEqual(@as(f64, 1), s.opacity);
    }
}

test "drawing covers all of a moved piece" {
    const im: Image = .{ .side = 100, .x = 40, .y = 40, .w = 20, .h = 10, .data = "" };
    const area = reach(forward(.{ .origin = .{ 0.5, 0.5 } }, .{ .move = .{ 0.25, 0 } }, 100), im, 100);
    try std.testing.expect(area[0] <= 64 and area[2] >= 86 and area[1] <= 39 and area[3] >= 51);
    try std.testing.expect(area[0] >= 60 and area[2] <= 90);
}
