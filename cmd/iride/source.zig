const std = @import("std");
const rim = @import("rim.zig");
const motion = @import("libiride").motion;

pub const FORMAT = 1;
pub const FIT_FROM = 32;
const MAX_FILE = 16 * 1024 * 1024;
const MAX_DEPTH = 32;

const Retouch = struct {
    up_to: u16,
    layer: ?[]const u8 = null,
};

const Shadow = struct {
    dx: f64,
    dy: f64,
    blur: f64,
    color: []const u8,
    opacity: f64,
    region: [4]f64,
};

const Node = struct {
    layer: ?[]const u8 = null,
    retouch: []const Retouch = &.{},
    rim: ?[]const u8 = null,
    light: ?[4]f64 = null,
    rule: rim.Rule = .nonzero,
    shadow: ?Shadow = null,
    clip: ?[]const u8 = null,
    stack: ?[]const Node = null,
    piece: ?[]const u8 = null,
};

const Track = struct {
    kind: motion.Kind,
    from: []const f64,
    at: u16 = 0,
    duration: u16,
    ease: motion.Ease = .out,
};

const Part = struct {
    piece: []const u8,
    origin: [2]f64,
    clip: ?[4]f64 = null,
    tracks: []const Track,
};

const Manifest = struct {
    format: u32,
    canvas: [2]f64,
    box: [4]f64,
    stack: []const Node,
    motion: []const Part = &.{},
};

pub const Choreography = struct {
    pieces: []const motion.Piece,
    tracks: []const motion.Track,
};

pub const Source = struct {
    io: std.Io,
    a: std.mem.Allocator,
    dir: std.Io.Dir,
    manifest: Manifest,

    pub fn open(io: std.Io, a: std.mem.Allocator, path: []const u8) !Source {
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
        errdefer dir.close(io);
        const text = try dir.readFileAlloc(io, "iride.json", a, .limited(MAX_FILE));
        const m = try std.json.parseFromSliceLeaky(Manifest, a, text, .{});
        try validate(m);
        return .{ .io = io, .a = a, .dir = dir, .manifest = m };
    }

    pub fn close(self: *Source) void {
        self.dir.close(self.io);
    }

    pub fn choreography(self: *const Source, a: std.mem.Allocator) !?Choreography {
        const m = self.manifest;
        if (m.motion.len == 0) return null;
        const pieces = try a.alloc(motion.Piece, m.motion.len);
        var tracks: std.ArrayList(motion.Track) = .empty;
        for (m.motion, pieces, 0..) |part, *p, i| {
            p.* = .{ .origin = .{ @floatCast(part.origin[0] / m.canvas[0]), @floatCast(part.origin[1] / m.canvas[0]) } };
            if (part.clip) |clip| {
                for (&p.clip, clip) |*to, v| to.* = @floatCast(v / m.canvas[0]);
            }
            for (part.tracks) |t| {
                const unit = if (t.kind == .translate or t.kind == .reveal) m.canvas[0] else 1;
                var out: motion.Track = .{ .piece = @intCast(i), .kind = t.kind, .ease = t.ease, .at = t.at, .duration = t.duration, .from = .{ 0, 0, 0, 0 } };
                for (t.from, 0..) |v, k| out.from[k] = @floatCast(v / unit);
                try tracks.append(a, out);
            }
        }
        return .{ .pieces = pieces, .tracks = tracks.items };
    }

    pub fn document(self: *const Source, a: std.mem.Allocator, size: u16, only: ?usize) ![:0]u8 {
        const m = self.manifest;
        var w: Writer = .{ .src = self, .a = a, .size = size };
        if (only) |i| w.only = m.motion[i].piece;
        const view = viewBox(m, size);
        try w.out.print(a, "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" width=\"{d}\" height=\"{d}\" viewBox=\"{d:.6} {d:.6} {d:.6} {d:.6}\"", .{ m.canvas[0], m.canvas[1], view[0], view[1], view[2], view[3] });
        try w.out.appendSlice(a, if (size >= FIT_FROM) " preserveAspectRatio=\"none\">" else ">");
        try w.stack(m.stack, null);
        try w.out.appendSlice(a, "</svg>");
        return w.out.toOwnedSliceSentinel(a, 0);
    }
};

fn viewBox(m: Manifest, size: u16) [4]f64 {
    var v: [4]f64 = .{ 0, 0, m.canvas[0], m.canvas[1] };
    if (size < FIT_FROM) return v;
    for (0..2) |i| {
        const s: f64 = @floatFromInt(size);
        const first = @round(m.box[i] * s / m.canvas[i]);
        const last = @round(m.box[i + 2] * s / m.canvas[i]);
        if (last <= first) continue;
        const unit = (m.box[i + 2] - m.box[i]) / (last - first);
        v[i] = m.box[i] - first * unit;
        v[i + 2] = s * unit;
    }
    return v;
}

fn validate(m: Manifest) !void {
    if (m.format != FORMAT) return error.UnsupportedFormat;
    if (!(m.canvas[0] > 0 and m.canvas[0] == m.canvas[1])) return error.CanvasNotSquare;
    for (0..2) |i| {
        if (!(m.box[i] >= 0 and m.box[i] < m.box[i + 2] and m.box[i + 2] <= m.canvas[i])) return error.BoxOutsideCanvas;
    }
    if (m.stack.len == 0) return error.EmptyStack;
    try validateStack(m.stack, 0);
    try validateMotion(m);
}

fn arity(kind: motion.Kind) usize {
    return switch (kind) {
        .translate, .scale => 2,
        .rotate, .tilt, .opacity => 1,
        .reveal => 4,
    };
}

fn validateMotion(m: Manifest) !void {
    if (m.motion.len > motion.MAX_PIECES) return error.MotionLimit;
    var total: usize = 0;
    for (m.motion) |part| {
        total += part.tracks.len;
        if (total > motion.MAX_TRACKS) return error.MotionLimit;
        for (part.tracks, 0..) |t, i| {
            if (t.from.len != arity(t.kind) or t.duration == 0) return error.BadTrack;
            if (@as(u32, t.at) + t.duration > motion.MAX_DURATION) return error.MotionTooLong;
            if (t.kind != .reveal) continue;
            for (part.tracks[0..i]) |before| if (before.kind == .reveal) return error.BadTrack;
        }
    }
    var reached: usize = 0;
    try assign(m.motion, m.stack, null, &reached);
    if (reached != m.motion.len) return error.UnusedPiece;
}

fn assign(parts: []const Part, nodes: []const Node, above: ?[]const u8, reached: *usize) error{ NoPiece, PieceOrder }!void {
    for (nodes) |n| {
        const name = n.piece orelse above;
        if (n.stack) |children| {
            try assign(parts, children, name, reached);
            continue;
        }
        if (parts.len == 0 and name == null) continue;
        const want = name orelse return error.NoPiece;
        if (reached.* > 0 and std.mem.eql(u8, parts[reached.* - 1].piece, want)) continue;
        if (reached.* == parts.len or !std.mem.eql(u8, parts[reached.*].piece, want)) return error.PieceOrder;
        reached.* += 1;
    }
}

fn holds(node: Node, above: ?[]const u8, wanted: []const u8) bool {
    const name = node.piece orelse above;
    if (node.stack) |children| {
        for (children) |child| if (holds(child, name, wanted)) return true;
        return false;
    }
    return std.mem.eql(u8, name orelse return false, wanted);
}

fn leads(node: Node, above: ?[]const u8, wanted: []const u8) bool {
    const name = node.piece orelse above;
    if (node.stack) |children| return children.len > 0 and leads(children[0], name, wanted);
    return std.mem.eql(u8, name orelse return false, wanted);
}

fn validateStack(nodes: []const Node, depth: usize) error{ BadNode, BadColor, BadFileName, TooDeep }!void {
    if (depth == MAX_DEPTH) return error.TooDeep;
    for (nodes) |n| {
        const group = n.stack != null;
        const kinds = @as(u8, @intFromBool(n.layer != null)) + @intFromBool(n.rim != null) + @intFromBool(group);
        if (kinds != 1) return error.BadNode;
        if ((n.shadow != null or n.clip != null) and !group) return error.BadNode;
        if (n.retouch.len > 0 and n.layer == null) return error.BadNode;
        if (n.light) |l| if (n.rim == null or !(l[0] < l[2] and l[1] < l[3])) return error.BadNode;
        if (n.layer) |name| try checkName(name);
        var last: u16 = 0;
        for (n.retouch) |r| {
            if (r.up_to <= last or r.up_to >= FIT_FROM) return error.BadNode;
            if (r.layer) |name| try checkName(name);
            last = r.up_to;
        }
        if (n.shadow) |s| {
            if (s.color.len != 7 or s.color[0] != '#') return error.BadColor;
            for (s.color[1..]) |ch| if (!std.ascii.isHex(ch)) return error.BadColor;
            if (s.blur < 0 or s.opacity < 0 or s.opacity > 1) return error.BadNode;
        }
        if (n.stack) |children| try validateStack(children, depth + 1);
    }
}

fn checkName(name: []const u8) !void {
    if (name.len == 0 or name[0] == '/') return error.BadFileName;
    var parts = std.mem.splitScalar(u8, name, '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, "..")) return error.BadFileName;
}

fn layerFor(node: Node, size: u16) ?[]const u8 {
    for (node.retouch) |r| if (size <= r.up_to) return r.layer;
    return node.layer;
}

fn tagEnd(s: []const u8, from: usize) !usize {
    var quote: u8 = 0;
    for (s[from..], from..) |ch, i| {
        if (quote != 0) {
            if (ch == quote) quote = 0;
        } else if (ch == '"' or ch == '\'') {
            quote = ch;
        } else if (ch == '>') return i;
    }
    return error.BadLayer;
}

const Writer = struct {
    src: *const Source,
    a: std.mem.Allocator,
    size: u16,
    out: std.ArrayList(u8) = .empty,
    next: usize = 0,
    only: ?[]const u8 = null,

    fn stack(self: *Writer, nodes: []const Node, above: ?[]const u8) anyerror!void {
        for (nodes) |node| try self.emit(node, above);
    }

    fn emit(self: *Writer, node: Node, above: ?[]const u8) !void {
        var shaded = node.shadow != null;
        if (self.only) |wanted| {
            if (!holds(node, above, wanted)) return;
            shaded = shaded and leads(node, above, wanted);
        }
        self.next += 1;
        const id = self.next;
        const m = self.src.manifest;
        if (node.rim) |d| return rim.write(self.a, &self.out, id, d, node.rule, m.canvas[0], node.light orelse m.box, @floatFromInt(self.size));
        if (node.layer != null) {
            const name = layerFor(node, self.size) orelse return;
            const text = try self.src.dir.readFileAlloc(self.src.io, name, self.a, .limited(MAX_FILE));
            defer self.a.free(text);
            return self.layer(id, text);
        }

        if (shaded) {
            const s = node.shadow.?;
            try self.out.print(self.a, "<defs><filter id=\"shadow{d}\" x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" filterUnits=\"userSpaceOnUse\" color-interpolation-filters=\"sRGB\">", .{ id, s.region[0], s.region[1], s.region[2], s.region[3] });
            try self.out.print(self.a, "<feDropShadow dx=\"{d}\" dy=\"{d}\" stdDeviation=\"{d}\" flood-color=\"{s}\" flood-opacity=\"{d}\"/></filter></defs>", .{ s.dx, s.dy, s.blur, s.color, s.opacity });
        }
        if (node.clip) |d| {
            const safe = try rim.shifted(self.a, d, 0, 0);
            defer self.a.free(safe);
            try self.out.print(self.a, "<defs><clipPath id=\"clip{d}\"><path d=\"{s}\" clip-rule=\"{s}\"/></clipPath></defs>", .{ id, safe, @tagName(node.rule) });
        }
        try self.out.appendSlice(self.a, "<g");
        if (node.clip != null) try self.out.print(self.a, " clip-path=\"url(#clip{d})\"", .{id});
        if (shaded) try self.out.print(self.a, " filter=\"url(#shadow{d})\"", .{id});
        try self.out.append(self.a, '>');
        try self.stack(node.stack.?, node.piece orelse above);
        try self.out.appendSlice(self.a, "</g>");
    }

    fn layer(self: *Writer, id: usize, text: []const u8) !void {
        const open_at = std.mem.indexOf(u8, text, "<svg") orelse return error.BadLayer;
        const open_end = try tagEnd(text, open_at);
        const close_at = std.mem.lastIndexOf(u8, text, "</svg>") orelse return error.BadLayer;
        if (close_at < open_end) return error.BadLayer;

        try self.out.appendSlice(self.a, "<g");
        var rest = text[open_at + 4 .. open_end];
        while (true) {
            rest = std.mem.trimStart(u8, rest, " \t\r\n");
            const eq = std.mem.indexOfScalar(u8, rest, '=') orelse break;
            const name = std.mem.trim(u8, rest[0..eq], " \t\r\n");
            const value = std.mem.trimStart(u8, rest[eq + 1 ..], " \t\r\n");
            if (value.len < 2 or (value[0] != '"' and value[0] != '\'')) return error.BadLayer;
            const end = std.mem.indexOfScalarPos(u8, value, 1, value[0]) orelse return error.BadLayer;
            if (std.mem.eql(u8, name, "viewBox")) try self.checkView(value[1..end]);
            if (inherited(name)) try self.out.print(self.a, " {s}={s}", .{ name, value[0 .. end + 1] });
            rest = value[end + 1 ..];
        }
        try self.out.append(self.a, '>');
        const body = text[open_end + 1 .. close_at];
        try checkPaths(self.a, body);
        try self.namespaced(id, body);
        try self.out.appendSlice(self.a, "</g>");
    }

    fn checkView(self: *Writer, text: []const u8) !void {
        const want = [_]f64{ 0, 0, self.src.manifest.canvas[0], self.src.manifest.canvas[1] };
        var it = std.mem.tokenizeAny(u8, text, " ,");
        for (want) |w| {
            const got = std.fmt.parseFloat(f64, it.next() orelse return error.LayerCanvas) catch return error.LayerCanvas;
            if (got != w) return error.LayerCanvas;
        }
        if (it.next() != null) return error.LayerCanvas;
    }

    fn namespaced(self: *Writer, id: usize, body: []const u8) !void {
        const marks = [_][]const u8{ " id=\"", " id='", "\tid=\"", "\nid=\"", "url(#", "url('#", "href=\"#", "href='#" };
        var i: usize = 0;
        scan: while (i < body.len) {
            for (marks) |mark| if (std.mem.startsWith(u8, body[i..], mark)) {
                try self.out.print(self.a, "{s}l{d}-", .{ mark, id });
                i += mark.len;
                continue :scan;
            };
            try self.out.append(self.a, body[i]);
            i += 1;
        }
    }
};

fn checkPaths(a: std.mem.Allocator, body: []const u8) !void {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, body, at, "d=")) |i| {
        at = i + 2;
        if (i == 0 or !std.ascii.isWhitespace(body[i - 1]) or at == body.len) continue;
        const quote = body[at];
        if (quote != '"' and quote != '\'') return error.BadLayer;
        const end = std.mem.indexOfScalarPos(u8, body, at + 1, quote) orelse return error.BadLayer;
        a.free(try rim.shifted(a, body[at + 1 .. end], 0, 0));
        at = end + 1;
    }
}

fn inherited(name: []const u8) bool {
    const root_only = [_][]const u8{ "width", "height", "viewBox", "version", "id", "x", "y", "preserveAspectRatio" };
    for (root_only) |r| if (std.mem.eql(u8, name, r)) return false;
    return !std.mem.startsWith(u8, name, "xmlns");
}

test "grid puts the box on whole pixels from 32 up only" {
    const m: Manifest = .{ .format = 1, .canvas = .{ 236, 236 }, .box = .{ 24, 84, 212, 212 }, .stack = &.{} };
    const v = viewBox(m, 32);
    for ([_]f64{ 24, 212 }) |x| {
        const p = (x - v[0]) * 32 / v[2];
        try std.testing.expectApproxEqAbs(@round(p), p, 1e-9);
    }
    try std.testing.expectEqual([4]f64{ 0, 0, 236, 236 }, viewBox(m, 24));
}

test "retouch replaces or hides a layer at small sizes" {
    const n: Node = .{ .layer = "full", .retouch = &.{ .{ .up_to = 16 }, .{ .up_to = 24, .layer = "small" } } };
    try std.testing.expect(layerFor(n, 16) == null);
    try std.testing.expectEqualStrings("small", layerFor(n, 22).?);
    try std.testing.expectEqualStrings("full", layerFor(n, 32).?);
}

test "layer names stay inside the source" {
    try std.testing.expectError(error.BadFileName, checkName("../secret"));
    try std.testing.expectError(error.BadFileName, checkName("/etc/secret"));
    try checkName("layers/back.svg");
}

test "broken path data in a layer is refused" {
    const a = std.testing.allocator;
    try checkPaths(a, "<path id=\"p\" d='M1 2L3 4Z'/>");
    try std.testing.expectError(error.BadPath, checkPaths(a, "<path d=\"M1 2 L oops\"/>"));
}

test "every leaf belongs to a piece and pieces follow the stack" {
    const move = [_]Track{.{ .kind = .opacity, .from = &.{0}, .duration = 100 }};
    var m: Manifest = .{
        .format = 1,
        .canvas = .{ 8, 8 },
        .box = .{ 0, 0, 8, 8 },
        .stack = &.{ .{ .layer = "back", .piece = "back" }, .{ .layer = "front", .piece = "front" } },
        .motion = &.{ .{ .piece = "back", .origin = .{ 4, 4 }, .tracks = &move }, .{ .piece = "front", .origin = .{ 4, 4 }, .tracks = &move } },
    };
    try validateMotion(m);
    m.motion = &.{ .{ .piece = "front", .origin = .{ 4, 4 }, .tracks = &move }, .{ .piece = "back", .origin = .{ 4, 4 }, .tracks = &move } };
    try std.testing.expectError(error.PieceOrder, validateMotion(m));
    m.stack = &.{.{ .layer = "back" }};
    try std.testing.expectError(error.NoPiece, validateMotion(m));
}

test "a piece repeats any track but reveal" {
    const swing = [_]Track{ .{ .kind = .rotate, .from = &.{-20}, .duration = 100 }, .{ .kind = .rotate, .from = &.{20}, .at = 100, .duration = 100 } };
    var m: Manifest = .{
        .format = 1,
        .canvas = .{ 8, 8 },
        .box = .{ 0, 0, 8, 8 },
        .stack = &.{.{ .layer = "all", .piece = "all" }},
        .motion = &.{.{ .piece = "all", .origin = .{ 4, 4 }, .tracks = &swing }},
    };
    try validateMotion(m);
    const twice = [_]Track{ .{ .kind = .reveal, .from = &.{ 0, 0, 8, 0 }, .duration = 100 }, .{ .kind = .reveal, .from = &.{ 0, 0, 0, 8 }, .duration = 100 } };
    m.motion = &.{.{ .piece = "all", .origin = .{ 4, 4 }, .tracks = &twice }};
    try std.testing.expectError(error.BadTrack, validateMotion(m));
}

test "motion over one second is refused in the source" {
    const move = [_]Track{.{ .kind = .opacity, .from = &.{0}, .at = 600, .duration = 500 }};
    const m: Manifest = .{
        .format = 1,
        .canvas = .{ 8, 8 },
        .box = .{ 0, 0, 8, 8 },
        .stack = &.{.{ .layer = "all", .piece = "all" }},
        .motion = &.{.{ .piece = "all", .origin = .{ 4, 4 }, .tracks = &move }},
    };
    try std.testing.expectError(error.MotionTooLong, validateMotion(m));
}
