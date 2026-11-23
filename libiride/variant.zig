const std = @import("std");

pub const MAGIC = "IRVAR\x00";
pub const HEADER = 8;
pub const ENTRY = 16;

pub const Scheme = enum(u8) { light, dark };
pub const Accent = enum(u8) { none, black, white };
pub const Key = struct { scheme: Scheme, accent: Accent };
pub const Variant = struct { key: Key, data: []const u8 };

const SLOTS = std.meta.fields(Scheme).len * std.meta.fields(Accent).len;

fn word(comptime T: type, data: []const u8, at: usize) T {
    return std.mem.readInt(T, data[at..][0..@sizeOf(T)], .little);
}

fn slot(key: Key) usize {
    return @as(usize, @intFromEnum(key.scheme)) * std.meta.fields(Accent).len + @intFromEnum(key.accent);
}

pub const Table = struct {
    data: []const u8,
    at: usize,
    n: usize,

    pub fn open(data: []const u8, at: usize) !?Table {
        if (at > data.len or !std.mem.startsWith(u8, data[at..], MAGIC)) return null;
        if (data.len - at < HEADER) return error.Corrupt;
        const n: usize = word(u16, data, at + MAGIC.len);
        if (n == 0 or n >= SLOTS or data.len - at < HEADER + n * ENTRY) return error.Corrupt;
        return .{ .data = data, .at = at, .n = n };
    }

    fn row(t: Table, i: usize) []const u8 {
        return t.data[t.at + HEADER + i * ENTRY ..][0..ENTRY];
    }

    pub fn get(t: Table, i: usize) !Variant {
        const e = t.row(i);
        const scheme = std.enums.fromInt(Scheme, e[0]) orelse return error.Corrupt;
        const accent = std.enums.fromInt(Accent, e[1]) orelse return error.Corrupt;
        const key: Key = .{ .scheme = scheme, .accent = accent };
        const at: u64 = word(u32, e, 4);
        const len: u64 = word(u32, e, 8);
        if (word(u16, e, 2) != 0 or slot(key) == 0) return error.Corrupt;
        if (len == 0 or at < t.at + HEADER + t.n * ENTRY or at + len > t.data.len) return error.Corrupt;
        return .{ .key = key, .data = t.data[@intCast(at)..@intCast(at + len)] };
    }

    pub fn verify(t: Table) !void {
        var seen = [_]bool{false} ** SLOTS;
        for (0..t.n) |i| {
            const v = try t.get(i);
            if (seen[slot(v.key)] or std.hash.Crc32.hash(v.data) != word(u32, t.row(i), 12)) return error.Corrupt;
            seen[slot(v.key)] = true;
        }
        for (std.enums.values(Scheme)) |scheme| {
            if (seen[slot(.{ .scheme = scheme, .accent = .black })] != seen[slot(.{ .scheme = scheme, .accent = .white })]) return error.Corrupt;
        }
    }

    pub fn find(t: Table, key: Key) !?[]const u8 {
        for (0..t.n) |i| {
            const v = try t.get(i);
            if (std.meta.eql(v.key, key)) return v.data;
        }
        return null;
    }
};

pub fn append(gpa: std.mem.Allocator, base: []const u8, variants: []const Variant) ![]u8 {
    if (variants.len == 0 or variants.len >= SLOTS) return error.TooLarge;
    var total: usize = base.len + HEADER + variants.len * ENTRY;
    for (variants) |v| total += v.data.len;
    if (total > std.math.maxInt(u32)) return error.TooLarge;

    const out = try gpa.alloc(u8, total);
    @memcpy(out[0..base.len], base);
    @memcpy(out[base.len..][0..MAGIC.len], MAGIC);
    std.mem.writeInt(u16, out[base.len + MAGIC.len ..][0..2], @intCast(variants.len), .little);
    var at: usize = base.len + HEADER + variants.len * ENTRY;
    for (variants, 0..) |v, i| {
        const e = out[base.len + HEADER + i * ENTRY ..][0..ENTRY];
        e[0] = @intFromEnum(v.key.scheme);
        e[1] = @intFromEnum(v.key.accent);
        std.mem.writeInt(u16, e[2..4], 0, .little);
        std.mem.writeInt(u32, e[4..8], @intCast(at), .little);
        std.mem.writeInt(u32, e[8..12], @intCast(v.data.len), .little);
        std.mem.writeInt(u32, e[12..16], std.hash.Crc32.hash(v.data), .little);
        @memcpy(out[at..][0..v.data.len], v.data);
        at += v.data.len;
    }
    return out;
}

pub fn tint(black: []const u8, white: []const u8, rgb: u32, out: []u8) !void {
    if (black.len % 4 != 0 or white.len != black.len) return error.Corrupt;
    if (out.len < black.len) return error.Space;
    const weight = [3]u32{ rgb & 0xff, (rgb >> 8) & 0xff, (rgb >> 16) & 0xff };
    var i: usize = 0;
    while (i < black.len) : (i += 4) {
        for (weight, 0..) |w, ch| {
            out[i + ch] = @intCast((@as(u32, black[i + ch]) * (255 - w) + @as(u32, white[i + ch]) * w + 127) / 255);
        }
        out[i + 3] = black[i + 3];
    }
}

test "a table finds each variant and refuses damage" {
    const gpa = std.testing.allocator;
    const key: Key = .{ .scheme = .dark, .accent = .none };
    const data = try append(gpa, "base", &.{.{ .key = key, .data = "dark" }});
    defer gpa.free(data);
    const t = (try Table.open(data, 4)).?;
    try t.verify();
    try std.testing.expectEqualStrings("dark", (try t.find(key)).?);
    try std.testing.expect(try t.find(.{ .scheme = .light, .accent = .black }) == null);
    try std.testing.expect(try Table.open("base", 4) == null);
    data[data.len - 1] ^= 1;
    try std.testing.expectError(error.Corrupt, t.verify());
}

test "an accent needs both ends" {
    const gpa = std.testing.allocator;
    const data = try append(gpa, "base", &.{.{ .key = .{ .scheme = .light, .accent = .black }, .data = "black" }});
    defer gpa.free(data);
    try std.testing.expectError(error.Corrupt, (try Table.open(data, 4)).?.verify());
}

test "tint runs from the black end to the white end" {
    const black = [_]u8{ 0, 10, 20, 128 };
    const white = [_]u8{ 128, 110, 20, 128 };
    var out: [4]u8 = undefined;
    try tint(&black, &white, 0x000000, &out);
    try std.testing.expectEqualSlices(u8, &black, &out);
    try tint(&black, &white, 0xffffff, &out);
    try std.testing.expectEqualSlices(u8, &white, &out);
    try tint(&black, &white, 0xff0000, &out);
    try std.testing.expectEqualSlices(u8, &.{ 0, 10, 20, 128 }, &out);
    try tint(&black, &white, 0x0000ff, &out);
    try std.testing.expectEqualSlices(u8, &.{ 128, 10, 20, 128 }, &out);
}
