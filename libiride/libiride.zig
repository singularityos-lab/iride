const std = @import("std");

pub const MAGIC = "IRIDE\x00";
pub const VERSION = 1;
pub const HEADER = 12;
pub const ENTRY = 16;
pub const MAX_ENTRIES = 4096;

const EINVAL: c_int = -22;
const ERANGE: c_int = -34;

pub const Image = struct { size: u16, png: []const u8 };

fn word(comptime T: type, data: []const u8, at: usize) T {
    return std.mem.readInt(T, data[at..][0..@sizeOf(T)], .little);
}

pub fn count(data: []const u8) !usize {
    if (data.len < HEADER or !std.mem.startsWith(u8, data, MAGIC)) return error.NotIride;
    if (word(u16, data, MAGIC.len) != VERSION) return error.Version;
    const n: usize = word(u32, data, 8);
    if (n == 0 or n > MAX_ENTRIES or data.len < HEADER + n * ENTRY) return error.Corrupt;
    return n;
}

pub fn entry(data: []const u8, i: usize) !Image {
    const e = data[HEADER + i * ENTRY ..][0..ENTRY];
    const at: u64 = word(u32, e, 4);
    const len: u64 = word(u32, e, 8);
    if (len == 0 or at + len > data.len) return error.Corrupt;
    const png = data[@intCast(at)..@intCast(at + len)];
    return .{ .size = word(u16, e, 0), .png = png };
}

pub fn verify(data: []const u8) !void {
    var last: u16 = 0;
    for (0..try count(data)) |i| {
        const im = try entry(data, i);
        if (im.size <= last) return error.Corrupt;
        if (std.hash.Crc32.hash(im.png) != word(u32, data, HEADER + i * ENTRY + 12)) return error.Corrupt;
        last = im.size;
    }
}

pub fn pick(data: []const u8, pixels: u32) !Image {
    for (0..try count(data)) |i| {
        const im = try entry(data, i);
        if (im.size >= pixels) return im;
    }
    return error.TooLarge;
}

pub fn pack(gpa: std.mem.Allocator, images: []const Image) ![]u8 {
    var total: usize = HEADER + images.len * ENTRY;
    for (images) |im| total += im.png.len;
    if (images.len == 0 or images.len > MAX_ENTRIES or total > std.math.maxInt(u32)) return error.TooLarge;

    const out = try gpa.alloc(u8, total);
    @memcpy(out[0..MAGIC.len], MAGIC);
    std.mem.writeInt(u16, out[MAGIC.len..][0..2], VERSION, .little);
    std.mem.writeInt(u32, out[8..][0..4], @intCast(images.len), .little);
    var at: usize = HEADER + images.len * ENTRY;
    for (images, 0..) |im, i| {
        const e = out[HEADER + i * ENTRY ..][0..ENTRY];
        std.mem.writeInt(u16, e[0..2], im.size, .little);
        std.mem.writeInt(u16, e[2..4], 0, .little);
        std.mem.writeInt(u32, e[4..8], @intCast(at), .little);
        std.mem.writeInt(u32, e[8..12], @intCast(im.png.len), .little);
        std.mem.writeInt(u32, e[12..16], std.hash.Crc32.hash(im.png), .little);
        @memcpy(out[at..][0..im.png.len], im.png);
        at += im.png.len;
    }
    return out;
}

pub export fn iride_check(data: [*]const u8, len: usize) c_int {
    verify(data[0..len]) catch return EINVAL;
    return 0;
}

pub export fn iride_pick(data: [*]const u8, len: usize, pixels: u32, png: *[*]const u8, png_len: *usize, size: *u32) c_int {
    const im = pick(data[0..len], pixels) catch |e| return if (e == error.TooLarge) ERANGE else EINVAL;
    png.* = im.png.ptr;
    png_len.* = im.png.len;
    size.* = im.size;
    return 0;
}

test "pick takes the exact size or the next larger one" {
    const gpa = std.testing.allocator;
    const data = try pack(gpa, &.{ .{ .size = 16, .png = "a" }, .{ .size = 32, .png = "bb" }, .{ .size = 48, .png = "ccc" } });
    defer gpa.free(data);
    try verify(data);
    try std.testing.expectEqualStrings("bb", (try pick(data, 32)).png);
    try std.testing.expectEqualStrings("ccc", (try pick(data, 33)).png);
    try std.testing.expectError(error.TooLarge, pick(data, 49));
}

test "damaged and truncated files are refused" {
    const gpa = std.testing.allocator;
    const data = try pack(gpa, &.{.{ .size = 16, .png = "abcdef" }});
    defer gpa.free(data);
    for (0..data.len) |n| try std.testing.expect(iride_check(data.ptr, n) != 0);
    data[data.len - 1] ^= 1;
    try std.testing.expectError(error.Corrupt, verify(data));
}
