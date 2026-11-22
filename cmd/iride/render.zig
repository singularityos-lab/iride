const std = @import("std");
const iride = @import("libiride");
const c = @cImport({
    @cInclude("cairo.h");
});

const SAMPLES = 16;
const SAMPLE_SIDE = 1024;

const GError = extern struct { domain: u32, code: c_int, message: [*:0]const u8 };
const ErrorHandler = *const fn (*anyopaque, *const GError, *bool) callconv(.c) void;

extern fn gtk_init_check() c_int;
extern fn gtk_svg_new() ?*anyopaque;
extern fn gtk_svg_load_from_bytes(svg: *anyopaque, bytes: *anyopaque) void;
extern fn gtk_snapshot_new() ?*anyopaque;
extern fn gtk_snapshot_free_to_node(snapshot: *anyopaque) ?*anyopaque;
extern fn gdk_paintable_snapshot(paintable: *anyopaque, snapshot: *anyopaque, w: f64, h: f64) void;
extern fn gsk_render_node_draw(node: *anyopaque, cr: *c.cairo_t) void;
extern fn gsk_render_node_unref(node: *anyopaque) void;
extern fn g_bytes_new(data: [*]const u8, len: usize) ?*anyopaque;
extern fn g_bytes_unref(bytes: *anyopaque) void;
extern fn g_object_unref(object: *anyopaque) void;
extern fn g_signal_connect_data(object: *anyopaque, signal: [*:0]const u8, handler: ErrorHandler, data: *bool, destroy: ?*anyopaque, flags: c_uint) c_ulong;

pub fn init() void {
    _ = gtk_init_check();
}

fn ck(status: c.cairo_status_t) !void {
    if (status != c.CAIRO_STATUS_SUCCESS) return error.Cairo;
}

fn onError(_: *anyopaque, e: *const GError, failed: *bool) callconv(.c) void {
    failed.* = true;
    std.debug.print("iride: {s}\n", .{e.message});
}

fn paint(svg: [:0]const u8, side: c_int) !*c.cairo_surface_t {
    var failed = false;
    const image = gtk_svg_new() orelse return error.Gtk;
    defer g_object_unref(image);
    if (g_signal_connect_data(image, "error", onError, &failed, null, 0) == 0) return error.Gtk;
    const bytes = g_bytes_new(svg.ptr, svg.len) orelse return error.Gtk;
    defer g_bytes_unref(bytes);
    gtk_svg_load_from_bytes(image, bytes);
    const snapshot = gtk_snapshot_new() orelse return error.Gtk;
    gdk_paintable_snapshot(image, snapshot, @floatFromInt(side), @floatFromInt(side));
    const node = gtk_snapshot_free_to_node(snapshot) orelse return error.NothingDrawn;
    defer gsk_render_node_unref(node);
    if (failed) return error.Svg;

    const out = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, side, side) orelse return error.Cairo;
    errdefer c.cairo_surface_destroy(out);
    try ck(c.cairo_surface_status(out));
    const cr = c.cairo_create(out) orelse return error.Cairo;
    defer c.cairo_destroy(cr);
    gsk_render_node_draw(node, cr);
    try ck(c.cairo_status(cr));
    c.cairo_surface_flush(out);
    return out;
}

fn pixels(surface: *c.cairo_surface_t, side: usize) []u8 {
    return c.cairo_image_surface_get_data(surface)[0 .. side * side * 4];
}

fn average(big: []const u8, out: []u8, side: usize, n: usize) void {
    const wide = side * n;
    for (0..side) |y| for (0..side) |x| for (0..4) |ch| {
        var sum: usize = 0;
        for (0..n) |j| for (0..n) |i| {
            sum += big[((y * n + j) * wide + x * n + i) * 4 + ch];
        };
        out[(y * side + x) * 4 + ch] = @intCast((sum + n * n / 2) / (n * n));
    };
}

pub fn samples(size: u16) u16 {
    return @max(1, @min(SAMPLES, SAMPLE_SIDE / size));
}

const Sink = struct {
    a: std.mem.Allocator,
    list: std.ArrayList(u8) = .empty,
};

fn put(closure: ?*anyopaque, data: [*c]const u8, len: c_uint) callconv(.c) c.cairo_status_t {
    const sink: *Sink = @ptrCast(@alignCast(closure.?));
    sink.list.appendSlice(sink.a, data[0..len]) catch return c.CAIRO_STATUS_WRITE_ERROR;
    return c.CAIRO_STATUS_SUCCESS;
}

fn sampled(svg: [:0]const u8, size: u16, n: u16) !*c.cairo_surface_t {
    const big = try paint(svg, @as(c_int, size) * n);
    defer c.cairo_surface_destroy(big);
    const out = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, size, size) orelse return error.Cairo;
    errdefer c.cairo_surface_destroy(out);
    try ck(c.cairo_surface_status(out));
    average(pixels(big, @as(usize, size) * n), pixels(out, size), size, n);
    c.cairo_surface_mark_dirty(out);
    return out;
}

pub fn piece(a: std.mem.Allocator, svg: [:0]const u8, size: u16, n: u16) !iride.motion.Image {
    const out = try sampled(svg, size, n);
    defer c.cairo_surface_destroy(out);
    const all = pixels(out, size);
    var box = [4]u16{ size, size, 0, 0 };
    for (0..size) |y| for (0..size) |x| {
        if (all[(y * size + x) * 4 + 3] == 0) continue;
        box = .{ @min(box[0], @as(u16, @intCast(x))), @min(box[1], @as(u16, @intCast(y))), @max(box[2], @as(u16, @intCast(x + 1))), @max(box[3], @as(u16, @intCast(y + 1))) };
    };
    if (box[2] == 0) return error.EmptyPiece;

    const w = box[2] - box[0];
    const h = box[3] - box[1];
    const cut = try a.alloc(u8, @as(usize, w) * h * 4);
    defer a.free(cut);
    for (0..h) |y| @memcpy(cut[y * w * 4 ..][0 .. @as(usize, w) * 4], all[((box[1] + y) * size + box[0]) * 4 ..][0 .. @as(usize, w) * 4]);
    return .{ .side = size, .x = box[0], .y = box[1], .w = w, .h = h, .data = try iride.motion.deflate(a, cut) };
}

pub fn png(a: std.mem.Allocator, svg: [:0]const u8, size: u16, n: u16) ![]u8 {
    const out = try sampled(svg, size, n);
    defer c.cairo_surface_destroy(out);

    var sink: Sink = .{ .a = a };
    errdefer sink.list.deinit(a);
    try ck(c.cairo_surface_write_to_png_stream(out, put, &sink));
    return sink.list.toOwnedSlice(a);
}

test "average rounds to the nearest level" {
    var out: [4]u8 = undefined;
    average(&([_]u8{ 0, 10, 255, 255 } ++ [_]u8{ 1, 10, 255, 255 } ++ [_]u8{ 1, 10, 0, 255 } ++ [_]u8{ 0, 10, 0, 255 }), &out, 1, 2);
    try std.testing.expectEqualSlices(u8, &.{ 1, 10, 128, 255 }, &out);
}
