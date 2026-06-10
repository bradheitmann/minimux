const std = @import("std");
const domain = @import("domain.zig");

const Allocator = std.mem.Allocator;

pub const Backend = enum {
    libghostty_vt_port,

    pub fn label(backend: Backend) []const u8 {
        return switch (backend) {
            .libghostty_vt_port => "libghostty-vt-substitution-contract",
        };
    }
};

pub const Color = enum {
    default,
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,

    pub fn label(color: Color) []const u8 {
        return switch (color) {
            .default => "default",
            .black => "black",
            .red => "red",
            .green => "green",
            .yellow => "yellow",
            .blue => "blue",
            .magenta => "magenta",
            .cyan => "cyan",
            .white => "white",
        };
    }
};

pub const Attributes = struct {
    fg: Color = .default,
    bg: Color = .default,
    bold: bool = false,
    underline: bool = false,
    inverse: bool = false,

    pub fn eql(left: Attributes, right: Attributes) bool {
        return left.fg == right.fg and
            left.bg == right.bg and
            left.bold == right.bold and
            left.underline == right.underline and
            left.inverse == right.inverse;
    }
};

pub const Cell = struct {
    char: u8 = ' ',
    attrs: Attributes = .{},
};

pub const Cursor = struct {
    x: u16 = 0,
    y: u16 = 0,
};

pub const Engine = struct {
    dimensions: domain.Dimensions,
    cursor: Cursor = .{},
    sequence: u64 = 0,
    scrollback_first: u64 = 0,
    scrollback_last: u64 = 0,
    alternate_screen: bool = false,
    backend: Backend = .libghostty_vt_port,

    cells: []Cell,
    saved_cells: ?[]Cell = null,
    saved_cursor: Cursor = .{},
    attrs: Attributes = .{},

    pub fn init(allocator: Allocator, dimensions: domain.Dimensions) !Engine {
        const normalized = normalizeDimensions(dimensions);
        const cells = try allocator.alloc(Cell, cellCount(normalized));
        @memset(cells, .{});
        return .{
            .dimensions = normalized,
            .cells = cells,
        };
    }

    pub fn deinit(engine: *Engine, allocator: Allocator) void {
        allocator.free(engine.cells);
        if (engine.saved_cells) |saved| allocator.free(saved);
        engine.* = undefined;
    }

    pub fn resize(engine: *Engine, allocator: Allocator, dimensions: domain.Dimensions) !void {
        const normalized = normalizeDimensions(dimensions);
        if (normalized.cols == engine.dimensions.cols and normalized.rows == engine.dimensions.rows) return;

        const replacement = try allocator.alloc(Cell, cellCount(normalized));
        @memset(replacement, .{});
        const copy_rows = @min(engine.dimensions.rows, normalized.rows);
        const copy_cols = @min(engine.dimensions.cols, normalized.cols);
        var y: u16 = 0;
        while (y < copy_rows) : (y += 1) {
            var x: u16 = 0;
            while (x < copy_cols) : (x += 1) {
                replacement[indexOf(normalized, x, y)] = engine.cells[indexOf(engine.dimensions, x, y)];
            }
        }

        allocator.free(engine.cells);
        engine.cells = replacement;
        engine.dimensions = normalized;
        if (engine.cursor.x >= normalized.cols) engine.cursor.x = normalized.cols - 1;
        if (engine.cursor.y >= normalized.rows) engine.cursor.y = normalized.rows - 1;
        engine.sequence += 1;
    }

    pub fn feed(engine: *Engine, allocator: Allocator, bytes: []const u8) !void {
        var index: usize = 0;
        while (index < bytes.len) {
            const byte = bytes[index];
            if (byte == 0x1b and index + 1 < bytes.len and bytes[index + 1] == '[') {
                const consumed = try engine.consumeCsi(allocator, bytes[index + 2 ..]);
                index += consumed + 2;
                continue;
            }
            switch (byte) {
                '\r' => engine.cursor.x = 0,
                '\n' => engine.lineFeed(),
                0x08 => {
                    if (engine.cursor.x > 0) engine.cursor.x -= 1;
                },
                '\t' => {
                    try engine.putByte(' ');
                    try engine.putByte(' ');
                    try engine.putByte(' ');
                    try engine.putByte(' ');
                },
                0x20...0x7e => try engine.putByte(byte),
                else => {},
            }
            engine.sequence += 1;
            index += 1;
        }
    }

    pub fn cellAt(engine: *const Engine, x: u16, y: u16) Cell {
        if (x >= engine.dimensions.cols or y >= engine.dimensions.rows) return .{};
        return engine.cells[indexOf(engine.dimensions, x, y)];
    }

    pub fn visibleText(engine: *const Engine, allocator: Allocator) ![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);

        var last_non_empty: i32 = -1;
        var y: u16 = 0;
        while (y < engine.dimensions.rows) : (y += 1) {
            if (engine.rowLastContentColumn(y) != null) last_non_empty = y;
        }

        if (last_non_empty < 0) return output.toOwnedSlice(allocator);

        y = 0;
        while (y <= @as(u16, @intCast(last_non_empty))) : (y += 1) {
            if (y != 0) try output.append(allocator, '\n');
            const row_end = engine.rowLastContentColumn(y) orelse 0;
            var x: u16 = 0;
            while (x <= row_end) : (x += 1) {
                try output.append(allocator, engine.cellAt(x, y).char);
            }
        }
        return output.toOwnedSlice(allocator);
    }

    pub fn nonBlankCellCount(engine: *const Engine) usize {
        var count: usize = 0;
        for (engine.cells) |cell| {
            if (cell.char != ' ') count += 1;
        }
        return count;
    }

    fn consumeCsi(engine: *Engine, allocator: Allocator, bytes: []const u8) !usize {
        var end: usize = 0;
        while (end < bytes.len) : (end += 1) {
            const byte = bytes[end];
            if (byte >= 0x40 and byte <= 0x7e) break;
        }
        if (end >= bytes.len) return bytes.len;

        const params = bytes[0..end];
        const final = bytes[end];
        switch (final) {
            'm' => engine.applySgr(params),
            'H', 'f' => engine.applyCursorPosition(params),
            'J' => engine.applyErase(params),
            'K' => engine.applyEraseLine(params),
            'A', 'B', 'C', 'D' => engine.applyCursorMove(final, params),
            'h' => {
                if (std.mem.eql(u8, params, "?1049")) try engine.enterAlternateScreen(allocator);
            },
            'l' => {
                if (std.mem.eql(u8, params, "?1049")) engine.exitAlternateScreen(allocator);
            },
            else => {},
        }
        engine.sequence += 1;
        return end + 1;
    }

    fn putByte(engine: *Engine, byte: u8) !void {
        if (engine.cursor.x >= engine.dimensions.cols) engine.lineFeed();
        engine.cells[indexOf(engine.dimensions, engine.cursor.x, engine.cursor.y)] = .{
            .char = byte,
            .attrs = engine.attrs,
        };
        engine.cursor.x += 1;
        if (engine.cursor.x >= engine.dimensions.cols) engine.lineFeed();
    }

    fn lineFeed(engine: *Engine) void {
        engine.cursor.x = 0;
        if (engine.cursor.y + 1 < engine.dimensions.rows) {
            engine.cursor.y += 1;
            return;
        }
        engine.scrollUp();
        engine.scrollback_last += 1;
    }

    fn scrollUp(engine: *Engine) void {
        if (engine.dimensions.rows <= 1) {
            @memset(engine.cells, .{});
            return;
        }
        var y: u16 = 1;
        while (y < engine.dimensions.rows) : (y += 1) {
            var x: u16 = 0;
            while (x < engine.dimensions.cols) : (x += 1) {
                engine.cells[indexOf(engine.dimensions, x, y - 1)] = engine.cells[indexOf(engine.dimensions, x, y)];
            }
        }
        const last_row = engine.dimensions.rows - 1;
        var x: u16 = 0;
        while (x < engine.dimensions.cols) : (x += 1) {
            engine.cells[indexOf(engine.dimensions, x, last_row)] = .{};
        }
        engine.cursor.y = last_row;
    }

    fn applySgr(engine: *Engine, params: []const u8) void {
        if (params.len == 0) {
            engine.attrs = .{};
            return;
        }

        var iterator = std.mem.splitScalar(u8, params, ';');
        while (iterator.next()) |raw_param| {
            if (raw_param.len == 0) continue;
            const value = std.fmt.parseInt(u16, raw_param, 10) catch continue;
            switch (value) {
                0 => engine.attrs = .{},
                1 => engine.attrs.bold = true,
                4 => engine.attrs.underline = true,
                7 => engine.attrs.inverse = true,
                22 => engine.attrs.bold = false,
                24 => engine.attrs.underline = false,
                27 => engine.attrs.inverse = false,
                30...37 => engine.attrs.fg = colorFromAnsi(value - 30),
                39 => engine.attrs.fg = .default,
                40...47 => engine.attrs.bg = colorFromAnsi(value - 40),
                49 => engine.attrs.bg = .default,
                else => {},
            }
        }
    }

    fn applyCursorPosition(engine: *Engine, params: []const u8) void {
        var row: u16 = 1;
        var col: u16 = 1;
        var iterator = std.mem.splitScalar(u8, params, ';');
        if (iterator.next()) |row_text| {
            if (row_text.len > 0) row = std.fmt.parseInt(u16, row_text, 10) catch 1;
        }
        if (iterator.next()) |col_text| {
            if (col_text.len > 0) col = std.fmt.parseInt(u16, col_text, 10) catch 1;
        }
        engine.cursor.y = @min(if (row == 0) 0 else row - 1, engine.dimensions.rows - 1);
        engine.cursor.x = @min(if (col == 0) 0 else col - 1, engine.dimensions.cols - 1);
    }

    fn applyErase(engine: *Engine, params: []const u8) void {
        if (params.len == 0 or std.mem.eql(u8, params, "2")) {
            @memset(engine.cells, .{});
            engine.cursor = .{};
        }
    }

    fn applyEraseLine(engine: *Engine, params: []const u8) void {
        const mode: u8 = if (params.len == 0) 0 else std.fmt.parseInt(u8, params, 10) catch return;
        const start: u16 = switch (mode) {
            0 => engine.cursor.x,
            1, 2 => 0,
            else => return,
        };
        const end: u16 = switch (mode) {
            0, 2 => engine.dimensions.cols,
            1 => @min(engine.cursor.x + 1, engine.dimensions.cols),
            else => return,
        };
        var x = start;
        while (x < end) : (x += 1) {
            engine.cells[indexOf(engine.dimensions, x, engine.cursor.y)] = .{};
        }
    }

    fn applyCursorMove(engine: *Engine, final: u8, params: []const u8) void {
        const raw: u16 = if (params.len == 0) 1 else std.fmt.parseInt(u16, params, 10) catch return;
        const count = if (raw == 0) 1 else raw;
        switch (final) {
            'A' => engine.cursor.y = if (engine.cursor.y >= count) engine.cursor.y - count else 0,
            'B' => engine.cursor.y = @min(engine.cursor.y +| count, engine.dimensions.rows - 1),
            'C' => engine.cursor.x = @min(engine.cursor.x +| count, engine.dimensions.cols - 1),
            'D' => engine.cursor.x = if (engine.cursor.x >= count) engine.cursor.x - count else 0,
            else => {},
        }
    }

    fn enterAlternateScreen(engine: *Engine, allocator: Allocator) !void {
        if (engine.alternate_screen) return;
        const saved = try allocator.alloc(Cell, engine.cells.len);
        @memcpy(saved, engine.cells);
        engine.saved_cells = saved;
        engine.saved_cursor = engine.cursor;
        @memset(engine.cells, .{});
        engine.cursor = .{};
        engine.alternate_screen = true;
    }

    fn exitAlternateScreen(engine: *Engine, allocator: Allocator) void {
        if (!engine.alternate_screen) return;
        if (engine.saved_cells) |saved| {
            @memcpy(engine.cells, saved);
            allocator.free(saved);
            engine.saved_cells = null;
            engine.cursor = engine.saved_cursor;
        }
        engine.alternate_screen = false;
    }

    fn rowLastContentColumn(engine: *const Engine, y: u16) ?u16 {
        var x = engine.dimensions.cols;
        while (x > 0) {
            x -= 1;
            if (engine.cellAt(x, y).char != ' ') return x;
        }
        return null;
    }
};

fn normalizeDimensions(dimensions: domain.Dimensions) domain.Dimensions {
    return .{
        .cols = if (dimensions.cols == 0) 80 else dimensions.cols,
        .rows = if (dimensions.rows == 0) 24 else dimensions.rows,
    };
}

fn cellCount(dimensions: domain.Dimensions) usize {
    return @as(usize, dimensions.cols) * @as(usize, dimensions.rows);
}

fn indexOf(dimensions: domain.Dimensions, x: u16, y: u16) usize {
    return @as(usize, y) * @as(usize, dimensions.cols) + @as(usize, x);
}

fn colorFromAnsi(value: u16) Color {
    return switch (value) {
        0 => .black,
        1 => .red,
        2 => .green,
        3 => .yellow,
        4 => .blue,
        5 => .magenta,
        6 => .cyan,
        7 => .white,
        else => .default,
    };
}

test "shadow snapshot tracks plain text and cursor" {
    var engine = try Engine.init(std.testing.allocator, .{ .cols = 8, .rows = 3 });
    defer engine.deinit(std.testing.allocator);

    try engine.feed(std.testing.allocator, "hello\nok");
    const visible = try engine.visibleText(std.testing.allocator);
    defer std.testing.allocator.free(visible);

    try std.testing.expectEqualStrings("hello\nok", visible);
    try std.testing.expectEqual(@as(u16, 2), engine.cursor.x);
    try std.testing.expectEqual(@as(u16, 1), engine.cursor.y);
}

test "shadow snapshot tracks color attributes" {
    var engine = try Engine.init(std.testing.allocator, .{ .cols = 12, .rows = 2 });
    defer engine.deinit(std.testing.allocator);

    try engine.feed(std.testing.allocator, "\x1b[31;1mR\x1b[0mN");

    try std.testing.expectEqual(Color.red, engine.cellAt(0, 0).attrs.fg);
    try std.testing.expect(engine.cellAt(0, 0).attrs.bold);
    try std.testing.expectEqual(Color.default, engine.cellAt(1, 0).attrs.fg);
}

test "shadow erase line cursor moves and backspace edit prompt redraws" {
    var engine = try Engine.init(std.testing.allocator, .{ .cols = 12, .rows = 4 });
    defer engine.deinit(std.testing.allocator);

    try engine.feed(std.testing.allocator, "hello");
    try engine.feed(std.testing.allocator, "\x1b[3D\x1b[K");
    var visible = try engine.visibleText(std.testing.allocator);
    try std.testing.expectEqualStrings("he", visible);
    std.testing.allocator.free(visible);

    try engine.feed(std.testing.allocator, "\x1b[2K\rab\x08c");
    visible = try engine.visibleText(std.testing.allocator);
    try std.testing.expectEqualStrings("ac", visible);
    std.testing.allocator.free(visible);

    try engine.feed(std.testing.allocator, "\x1b[2B\x1b[3CX");
    try std.testing.expectEqual(@as(u16, 2), engine.cursor.y);
    try std.testing.expectEqual(@as(u8, 'X'), engine.cellAt(5, 2).char);

    try engine.feed(std.testing.allocator, "\x1b[A\x1b[4DY");
    try std.testing.expectEqual(@as(u8, 'Y'), engine.cellAt(2, 1).char);

    try engine.feed(std.testing.allocator, "\x1b[99A\x1b[99D");
    try std.testing.expectEqual(@as(u16, 0), engine.cursor.y);
    try std.testing.expectEqual(@as(u16, 0), engine.cursor.x);
}

test "shadow snapshot restores primary screen after alternate screen" {
    var engine = try Engine.init(std.testing.allocator, .{ .cols = 12, .rows = 2 });
    defer engine.deinit(std.testing.allocator);

    try engine.feed(std.testing.allocator, "main");
    try engine.feed(std.testing.allocator, "\x1b[?1049hALT\x1b[?1049l");

    const visible = try engine.visibleText(std.testing.allocator);
    defer std.testing.allocator.free(visible);
    try std.testing.expectEqualStrings("main", visible);
    try std.testing.expect(!engine.alternate_screen);
}
