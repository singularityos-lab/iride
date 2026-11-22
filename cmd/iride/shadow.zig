const std = @import("std");
pub const c = @cImport({
    @cInclude("cairo.h");
});

const BOX_FACTOR = 3.0 * @sqrt(2.0 * std.math.pi) / 4.0;
const EXTENT_FACTOR = BOX_FACTOR * 1.5;
const ROUND_BIAS = 0.0001;
const MAX_SIDE = 32767;

pub const Shadow = struct {
    dx: f64,
    dy: f64,
    sigma: f64,
    color: [4]f64,
};

fn ck(status: c.cairo_status_t) !void {
    if (status != c.CAIRO_STATUS_SUCCESS) return error.Cairo;
}

fn boxPass(src: []const u8, dst: []u8, width: usize, left: usize) void {
    var sum: usize = 0;
    for (src[0..@min(width - left, src.len)]) |v| sum += v;
    for (dst, 0..) |*out, i| {
        out.* = @intCast((sum + width / 2) / width);
        const next = i + width - left;
        if (next < src.len) sum += src[next];
        if (i >= left) sum -= src[i - left];
    }
}

fn blurLine(line: []u8, tmp: []u8, d: usize) void {
    const half = d / 2;
    const odd = d % 2 == 1;
    boxPass(line, tmp, d, half);
    boxPass(tmp, line, d, if (odd) half else half - 1);
    boxPass(line, tmp, if (odd) d else d + 1, half);
    @memcpy(line, tmp);
}

fn blurMask(gpa: std.mem.Allocator, pixels: []u8, stride: usize, height: usize, d: usize) !void {
    const column = try gpa.alloc(u8, height);
    defer gpa.free(column);
    const tmp = try gpa.alloc(u8, @max(stride, height));
    defer gpa.free(tmp);

    for (0..stride) |x| {
        for (column, 0..) |*v, y| v.* = pixels[y * stride + x];
        blurLine(column, tmp[0..height], d);
        for (column, 0..) |v, y| pixels[y * stride + x] = v;
    }
    for (0..height) |y| blurLine(pixels[y * stride ..][0..stride], tmp[0..stride], d);
}

fn axisScale(cr: *c.cairo_t) ![2]f64 {
    var m: c.cairo_matrix_t = undefined;
    c.cairo_get_matrix(cr, &m);
    const det = @abs(m.xx * m.yy - m.yx * m.xy);
    const x = std.math.hypot(m.xx, m.yx);
    if (x == 0 or det == 0) return error.Degenerate;
    return .{ x, det / x };
}

fn side(v: f64) !c_int {
    if (!(v >= 0 and v <= MAX_SIDE)) return error.TooLarge;
    return @intFromFloat(v);
}

fn setColor(cr: *c.cairo_t, col: [4]f64) void {
    c.cairo_set_source_rgba(cr, col[0], col[1], col[2], col[3]);
}

fn stamp(cr: *c.cairo_t, shadow: Shadow, child: anytype) !void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_translate(cr, shadow.dx, shadow.dy);
    c.cairo_push_group(cr);
    child.paint(cr);
    const shape = c.cairo_pop_group(cr) orelse return error.Cairo;
    defer c.cairo_pattern_destroy(shape);
    c.cairo_reset_clip(cr);
    setColor(cr, shadow.color);
    c.cairo_mask(cr, shape);
    try ck(c.cairo_status(cr));
}

pub fn draw(gpa: std.mem.Allocator, cr: *c.cairo_t, shadow: Shadow, child: anytype) !void {
    if (shadow.sigma <= 1) return stamp(cr, shadow, child);

    var x1: f64 = undefined;
    var y1: f64 = undefined;
    var x2: f64 = undefined;
    var y2: f64 = undefined;
    c.cairo_clip_extents(cr, &x1, &y1, &x2, &y2);
    const scale = try axisScale(cr);
    const pad = @floor(shadow.sigma * EXTENT_FACTOR + 0.5);
    const w = try side(scale[0] * (x2 - x1 + 2 * pad));
    const h = try side(scale[1] * (y2 - y1 + 2 * pad));
    if (w == 0 or h == 0) return;

    const mask = c.cairo_image_surface_create(c.CAIRO_FORMAT_A8, w, h) orelse return error.Cairo;
    defer c.cairo_surface_destroy(mask);
    try ck(c.cairo_surface_status(mask));
    c.cairo_surface_set_device_scale(mask, scale[0], scale[1]);
    c.cairo_surface_set_device_offset(mask, scale[0] * (pad - x1), scale[1] * (pad - y1));
    {
        const mcr = c.cairo_create(mask) orelse return error.Cairo;
        defer c.cairo_destroy(mcr);
        try stamp(mcr, shadow, child);
    }
    c.cairo_surface_flush(mask);

    const radius = @round((scale[0] + ROUND_BIAS) * shadow.sigma);
    if (radius > 1) {
        const stride: usize = @intCast(c.cairo_image_surface_get_stride(mask));
        const rows: usize = @intCast(h);
        const d: usize = @intCast(try side(BOX_FACTOR * radius));
        try blurMask(gpa, c.cairo_image_surface_get_data(mask)[0 .. stride * rows], stride, rows, d);
        c.cairo_surface_mark_dirty(mask);
    }

    setColor(cr, shadow.color);
    c.cairo_mask_surface(cr, mask, 0, 0);
    try ck(c.cairo_status(cr));
}

const Square = struct {
    fn paint(_: Square, cr: *c.cairo_t) void {
        c.cairo_set_source_rgba(cr, 1, 1, 1, 1);
        c.cairo_rectangle(cr, 24, 24, 16, 16);
        c.cairo_fill(cr);
    }
};

fn testAlpha(shadow: Shadow, x: usize, y: usize) !u8 {
    const out = c.cairo_image_surface_create(c.CAIRO_FORMAT_A8, 64, 64) orelse return error.Cairo;
    defer c.cairo_surface_destroy(out);
    const cr = c.cairo_create(out) orelse return error.Cairo;
    defer c.cairo_destroy(cr);
    try draw(std.testing.allocator, cr, shadow, Square{});
    c.cairo_surface_flush(out);
    const stride: usize = @intCast(c.cairo_image_surface_get_stride(out));
    return c.cairo_image_surface_get_data(out)[y * stride + x];
}

test "blur keeps a centred line symmetric for odd and even boxes" {
    for ([_]usize{ 2, 3, 4, 7, 8, 16 }) |d| {
        var line = [_]u8{0} ** 81;
        var tmp: [81]u8 = undefined;
        for (line[30..51]) |*v| v.* = 255;
        blurLine(&line, &tmp, d);
        for (0..40) |i| try std.testing.expectEqual(line[i], line[80 - i]);
        try std.testing.expect(line[29] > 0 and line[29] < 255);
    }
}

test "blur wider than the line stays inside it" {
    var line = [_]u8{255} ** 5;
    var tmp: [5]u8 = undefined;
    blurLine(&line, &tmp, 40);
    for (line) |v| try std.testing.expect(v < 255);
}

test "sharp shadow lands at its offset" {
    const s: Shadow = .{ .dx = 10, .dy = 0, .sigma = 0, .color = .{ 0, 0, 0, 1 } };
    try std.testing.expectEqual(@as(u8, 255), try testAlpha(s, 45, 32));
    try std.testing.expectEqual(@as(u8, 0), try testAlpha(s, 30, 32));
}

test "soft shadow spreads past the shape and fades out" {
    const s: Shadow = .{ .dx = 0, .dy = 0, .sigma = 3, .color = .{ 0, 0, 0, 1 } };
    const near = try testAlpha(s, 21, 32);
    try std.testing.expect(near > 0 and near < 255);
    try std.testing.expectEqual(@as(u8, 0), try testAlpha(s, 2, 32));
}

test "absurd blur is refused" {
    const s: Shadow = .{ .dx = 0, .dy = 0, .sigma = 1e9, .color = .{ 0, 0, 0, 1 } };
    try std.testing.expectError(error.TooLarge, testAlpha(s, 0, 0));
}
