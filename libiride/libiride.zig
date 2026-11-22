const std = @import("std");
pub const motion = @import("motion.zig");

pub const MAGIC = "IRIDE\x00";
pub const VERSION = 1;
pub const MOTION_VERSION = 2;
pub const HEADER = 12;
pub const MOTION_HEADER = 24;
pub const ENTRY = 16;
pub const MAX_ENTRIES = 4096;

const EINVAL: c_int = -22;
const ENOSPC: c_int = -28;
const ERANGE: c_int = -34;
const ENODATA: c_int = -61;

pub const Image = struct { size: u16, png: []const u8 };

fn word(comptime T: type, data: []const u8, at: usize) T {
    return std.mem.readInt(T, data[at..][0..@sizeOf(T)], .little);
}

fn table(data: []const u8) usize {
    return if (word(u16, data, MAGIC.len) == MOTION_VERSION) MOTION_HEADER else HEADER;
}

pub fn count(data: []const u8) !usize {
    if (data.len < HEADER or !std.mem.startsWith(u8, data, MAGIC)) return error.NotIride;
    const version = word(u16, data, MAGIC.len);
    if (version != VERSION and version != MOTION_VERSION) return error.Version;
    const n: usize = word(u32, data, 8);
    if (n == 0 or n > MAX_ENTRIES or data.len < table(data) + n * ENTRY) return error.Corrupt;
    return n;
}

fn movement(data: []const u8) !?[]const u8 {
    _ = try count(data);
    if (table(data) == HEADER) return null;
    const at: u64 = word(u32, data, 12);
    const len: u64 = word(u32, data, 16);
    if (at + len > data.len) return error.Corrupt;
    return data[@intCast(at)..@intCast(at + len)];
}

pub fn animation(data: []const u8) !motion.Clip {
    return motion.Clip.open(try movement(data) orelse return error.Still);
}

pub fn entry(data: []const u8, i: usize) !Image {
    const e = data[table(data) + i * ENTRY ..][0..ENTRY];
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
        if (std.hash.Crc32.hash(im.png) != word(u32, data, table(data) + i * ENTRY + 12)) return error.Corrupt;
        last = im.size;
    }
    if (try movement(data)) |part| {
        if (std.hash.Crc32.hash(part) != word(u32, data, 20)) return error.Corrupt;
        try (try motion.Clip.open(part)).verify();
    }
}

pub fn pick(data: []const u8, pixels: u32) !Image {
    for (0..try count(data)) |i| {
        const im = try entry(data, i);
        if (im.size >= pixels) return im;
    }
    return error.TooLarge;
}

pub fn pack(gpa: std.mem.Allocator, images: []const Image, moving: ?[]const u8) ![]u8 {
    const head: usize = if (moving != null) MOTION_HEADER else HEADER;
    var total: usize = head + images.len * ENTRY;
    if (moving) |part| total += part.len;
    for (images) |im| total += im.png.len;
    if (images.len == 0 or images.len > MAX_ENTRIES or total > std.math.maxInt(u32)) return error.TooLarge;

    const out = try gpa.alloc(u8, total);
    @memcpy(out[0..MAGIC.len], MAGIC);
    std.mem.writeInt(u16, out[MAGIC.len..][0..2], if (moving != null) MOTION_VERSION else VERSION, .little);
    std.mem.writeInt(u32, out[8..][0..4], @intCast(images.len), .little);
    var at: usize = head + images.len * ENTRY;
    for (images, 0..) |im, i| {
        const e = out[head + i * ENTRY ..][0..ENTRY];
        std.mem.writeInt(u16, e[0..2], im.size, .little);
        std.mem.writeInt(u16, e[2..4], 0, .little);
        std.mem.writeInt(u32, e[4..8], @intCast(at), .little);
        std.mem.writeInt(u32, e[8..12], @intCast(im.png.len), .little);
        std.mem.writeInt(u32, e[12..16], std.hash.Crc32.hash(im.png), .little);
        @memcpy(out[at..][0..im.png.len], im.png);
        at += im.png.len;
    }
    if (moving) |part| {
        std.mem.writeInt(u32, out[12..16], @intCast(at), .little);
        std.mem.writeInt(u32, out[16..20], @intCast(part.len), .little);
        std.mem.writeInt(u32, out[20..24], std.hash.Crc32.hash(part), .little);
        @memcpy(out[at..][0..part.len], part);
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

fn code(e: anyerror) c_int {
    return switch (e) {
        error.Still => ENODATA,
        error.Space => ENOSPC,
        error.TooSmall, error.TooLarge => ERANGE,
        else => EINVAL,
    };
}

pub export fn iride_motion(data: [*]const u8, len: usize, pixels: u32, duration: *u32, size: *u32, work_len: *usize) c_int {
    const clip = animation(data[0..len]) catch |e| return code(e);
    const level = clip.level(pixels) catch |e| return code(e);
    work_len.* = clip.room(level) catch |e| return code(e);
    size.* = (clip.image(level, 0) catch |e| return code(e)).side;
    duration.* = clip.duration;
    return 0;
}

pub export fn iride_prepare(data: [*]const u8, len: usize, pixels: u32, work: [*]u8, work_len: usize) c_int {
    const bytes = data[0..len];
    const clip = animation(bytes) catch |e| return code(e);
    verify(bytes) catch |e| return code(e);
    const level = clip.level(pixels) catch |e| return code(e);
    clip.prepare(level, work[0..work_len]) catch |e| return code(e);
    return 0;
}

pub export fn iride_frame(data: [*]const u8, len: usize, pixels: u32, msec: f64, work: [*]const u8, work_len: usize, out: [*]u8, out_len: usize) c_int {
    const clip = animation(data[0..len]) catch |e| return code(e);
    const level = clip.level(pixels) catch |e| return code(e);
    const finished = clip.frame(level, msec, work[0..work_len], out[0..out_len]) catch |e| return code(e);
    return @intFromBool(finished);
}

test {
    _ = motion;
}

test "pick takes the exact size or the next larger one" {
    const gpa = std.testing.allocator;
    const data = try pack(gpa, &.{ .{ .size = 16, .png = "a" }, .{ .size = 32, .png = "bb" }, .{ .size = 48, .png = "ccc" } }, null);
    defer gpa.free(data);
    try verify(data);
    try std.testing.expectEqualStrings("bb", (try pick(data, 32)).png);
    try std.testing.expectEqualStrings("ccc", (try pick(data, 33)).png);
    try std.testing.expectError(error.TooLarge, pick(data, 49));
}

test "damaged and truncated files are refused" {
    const gpa = std.testing.allocator;
    const data = try pack(gpa, &.{.{ .size = 16, .png = "abcdef" }}, null);
    defer gpa.free(data);
    for (0..data.len) |n| try std.testing.expect(iride_check(data.ptr, n) != 0);
    data[data.len - 1] ^= 1;
    try std.testing.expectError(error.Corrupt, verify(data));
}

test "moving files keep their images and refuse damage" {
    const gpa = std.testing.allocator;
    const raw = [_]u8{9} ** (32 * 32 * 4);
    const z = try motion.deflate(gpa, &raw);
    defer gpa.free(z);
    const part = try motion.pack(
        gpa,
        &.{.{ .origin = .{ 0.5, 0.5 } }},
        &.{.{ .piece = 0, .kind = .opacity, .ease = .out, .at = 0, .duration = 100, .from = .{ 0, 0, 0, 0 } }},
        &.{ .{ .side = 32, .x = 0, .y = 0, .w = 32, .h = 32, .data = z }, .{ .side = 32, .x = 0, .y = 0, .w = 32, .h = 32, .data = z } },
    );
    defer gpa.free(part);
    const data = try pack(gpa, &.{.{ .size = 32, .png = "abcdef" }}, part);
    defer gpa.free(data);
    try verify(data);
    try std.testing.expectEqualStrings("abcdef", (try pick(data, 24)).png);
    for (0..data.len) |n| try std.testing.expect(iride_check(data.ptr, n) != 0);
    data[data.len - 1] ^= 1;
    try std.testing.expectError(error.Corrupt, verify(data));
}
