const std = @import("std");
const iride = @import("libiride");

const GError = opaque {};
const Sized = ?*const fn (*c_int, *c_int, ?*anyopaque) callconv(.c) void;
const Prepared = ?*const fn (*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void;
const Updated = ?*const fn (*anyopaque, c_int, c_int, c_int, c_int, ?*anyopaque) callconv(.c) void;

const Module = extern struct {
    module_name: ?[*:0]u8,
    module_path: ?[*:0]u8,
    module: ?*anyopaque,
    info: ?*Format,
    load: ?*const anyopaque,
    load_xpm_data: ?*const anyopaque,
    begin_load: ?*const fn (Sized, Prepared, Updated, ?*anyopaque, ?*?*GError) callconv(.c) ?*anyopaque,
    stop_load: ?*const fn (*anyopaque, ?*?*GError) callconv(.c) c_int,
    load_increment: ?*const fn (*anyopaque, [*]const u8, c_uint, ?*?*GError) callconv(.c) c_int,
    load_animation: ?*const anyopaque,
    save: ?*const anyopaque,
    save_to_callback: ?*const anyopaque,
    is_save_option_supported: ?*const anyopaque,
    reserved: [4]?*const anyopaque,
};

const Pattern = extern struct { prefix: ?[*:0]const u8, mask: ?[*:0]const u8, relevance: c_int };

const Format = extern struct {
    name: ?[*:0]const u8,
    signature: ?[*]const Pattern,
    domain: ?[*:0]const u8,
    description: ?[*:0]const u8,
    mime_types: ?[*]const ?[*:0]const u8,
    extensions: ?[*]const ?[*:0]const u8,
    flags: u32,
    disabled: c_int,
    license: ?[*:0]const u8,
};

extern fn gdk_pixbuf_error_quark() u32;
extern fn gdk_pixbuf_new_from_stream(stream: *anyopaque, cancellable: ?*anyopaque, err: ?*?*GError) ?*anyopaque;
extern fn g_memory_input_stream_new_from_data(data: [*]const u8, len: isize, destroy: ?*const anyopaque) *anyopaque;
extern fn g_object_unref(object: *anyopaque) void;
extern fn g_set_error_literal(err: ?*?*GError, domain: u32, code: c_int, message: [*:0]const u8) void;

const CORRUPT: c_int = 0;
const MEMORY: c_int = 1;
const FAILED: c_int = 5;
const THREADSAFE: u32 = 1 << 2;
const MAX_FILE = 32 << 20;
const MAX_SIDE = 2048;
const PNG = "\x89PNG\r\n\x1a\n";
const gpa = std.heap.c_allocator;

const Load = struct {
    sized: Sized,
    prepared: Prepared,
    updated: Updated,
    user: ?*anyopaque,
    data: std.ArrayList(u8) = .empty,
};

fn fail(err: ?*?*GError, why: c_int, msg: [*:0]const u8) c_int {
    g_set_error_literal(err, gdk_pixbuf_error_quark(), why, msg);
    return 0;
}

fn square(im: iride.Image) bool {
    if (im.size == 0 or im.size > MAX_SIDE or im.png.len < 24) return false;
    if (!std.mem.startsWith(u8, im.png, PNG)) return false;
    for ([_]usize{ 16, 20 }) |at| if (std.mem.readInt(u32, im.png[at..][0..4], .big) != im.size) return false;
    return true;
}

fn begin(sized: Sized, prepared: Prepared, updated: Updated, user: ?*anyopaque, err: ?*?*GError) callconv(.c) ?*anyopaque {
    const l = gpa.create(Load) catch {
        _ = fail(err, MEMORY, "out of memory");
        return null;
    };
    l.* = .{ .sized = sized, .prepared = prepared, .updated = updated, .user = user };
    return l;
}

fn more(context: *anyopaque, buf: [*]const u8, len: c_uint, err: ?*?*GError) callconv(.c) c_int {
    const l: *Load = @ptrCast(@alignCast(context));
    if (l.data.items.len + len > MAX_FILE) return fail(err, CORRUPT, "Iride file too large");
    l.data.appendSlice(gpa, buf[0..len]) catch return fail(err, MEMORY, "out of memory");
    return 1;
}

fn stop(context: *anyopaque, err: ?*?*GError) callconv(.c) c_int {
    const l: *Load = @ptrCast(@alignCast(context));
    defer gpa.destroy(l);
    defer l.data.deinit(gpa);
    return show(l, err);
}

fn show(l: *Load, err: ?*?*GError) c_int {
    const data = l.data.items;
    iride.verify(data) catch return fail(err, CORRUPT, "damaged Iride file");
    const n = iride.count(data) catch unreachable;
    const largest = iride.entry(data, n - 1) catch unreachable;
    var w: c_int = largest.size;
    var h: c_int = largest.size;
    if (l.sized) |sized| sized(&w, &h, l.user);
    if (w == 0 or h == 0) return fail(err, FAILED, "no size to load");
    const asked: u32 = @intCast(@max(1, @max(w, h)));
    const im = iride.pick(data, asked) catch largest;
    if (!square(im)) return fail(err, CORRUPT, "damaged Iride image");

    const stream = g_memory_input_stream_new_from_data(im.png.ptr, @intCast(im.png.len), null);
    defer g_object_unref(stream);
    const pixbuf = gdk_pixbuf_new_from_stream(stream, null, err) orelse return 0;
    defer g_object_unref(pixbuf);
    if (l.prepared) |prepared| prepared(pixbuf, null, l.user);
    if (l.updated) |updated| updated(pixbuf, 0, 0, im.size, im.size, l.user);
    return 1;
}

const signature = [_]Pattern{
    .{ .prefix = "IRIDE", .mask = null, .relevance = 100 },
    .{ .prefix = null, .mask = null, .relevance = 0 },
};
const mimes = [_]?[*:0]const u8{ "application/vnd.sinty.iride", null };
const extensions = [_]?[*:0]const u8{ "iride", null };

pub export fn fill_vtable(module: *Module) void {
    module.begin_load = begin;
    module.load_increment = more;
    module.stop_load = stop;
}

pub export fn fill_info(info: *Format) void {
    info.name = "iride";
    info.signature = &signature;
    info.description = "Iride icon";
    info.mime_types = &mimes;
    info.extensions = &extensions;
    info.flags = THREADSAFE;
    info.license = "GPL";
}

test "only square images of the declared side are decoded" {
    var png = [_]u8{0} ** 24;
    @memcpy(png[0..PNG.len], PNG);
    std.mem.writeInt(u32, png[16..20], 48, .big);
    std.mem.writeInt(u32, png[20..24], 48, .big);
    try std.testing.expect(square(.{ .size = 48, .png = &png }));
    try std.testing.expect(!square(.{ .size = 64, .png = &png }));
    std.mem.writeInt(u32, png[20..24], 65535, .big);
    try std.testing.expect(!square(.{ .size = 48, .png = &png }));
    try std.testing.expect(!square(.{ .size = 48, .png = "IRIDE\x00 is not a bitmap at all" }));
}
