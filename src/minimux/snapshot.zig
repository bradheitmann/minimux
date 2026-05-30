const std = @import("std");
const domain = @import("domain.zig");
const proto = @import("proto.zig");
const shadow = @import("shadow.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const schema_version = "0.1.0";

pub const ProcessStatus = struct {
    status: []const u8,
    exit_code: ?u8 = null,
};

pub const RecoveryStatus = struct {
    state: domain.RecoveryState = .clean,
    recovered_notification: bool = false,
};

pub fn writePaneSnapshotResultJson(
    allocator: Allocator,
    writer: *Io.Writer,
    request_id: u64,
    session_name: []const u8,
    local_id: []const u8,
    engine: *const shadow.Engine,
    process: ProcessStatus,
    recovery: RecoveryStatus,
) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"ok\":true,\"result\":{\"snapshot\":");
    try writeSnapshotJson(allocator, writer, session_name, local_id, engine, process, recovery);
    try writer.print("}},\"request_id\":\"control-socket\",\"seq\":{d}}}\n", .{request_id});
}

pub fn writeSnapshotJson(
    allocator: Allocator,
    writer: *Io.Writer,
    session_name: []const u8,
    local_id: []const u8,
    engine: *const shadow.Engine,
    process: ProcessStatus,
    recovery: RecoveryStatus,
) !void {
    try writer.writeAll("{\"schema\":\"minimux.snapshot.v");
    try writer.writeAll(schema_version);
    try writer.writeAll("\",\"pane_id\":\"");
    try writer.writeAll(session_name);
    try writer.writeAll(":");
    try writer.writeAll(local_id);
    try writer.writeAll("\",\"dimensions\":{\"cols\":");
    try writer.print("{d}", .{engine.dimensions.cols});
    try writer.writeAll(",\"rows\":");
    try writer.print("{d}", .{engine.dimensions.rows});
    try writer.writeAll("},\"cursor\":{\"x\":");
    try writer.print("{d}", .{engine.cursor.x});
    try writer.writeAll(",\"y\":");
    try writer.print("{d}", .{engine.cursor.y});
    try writer.writeAll("},\"sequence\":");
    try writer.print("{d}", .{engine.sequence});
    try writer.writeAll(",\"visible_text\":");
    const visible = try engine.visibleText(allocator);
    defer allocator.free(visible);
    try proto.writeJsonString(writer, visible);
    try writer.writeAll(",\"visible_cells\":[");
    try writeCellsJson(writer, engine);
    try writer.writeAll("],\"scrollback_range\":{\"first\":");
    try writer.print("{d}", .{engine.scrollback_first});
    try writer.writeAll(",\"last\":");
    try writer.print("{d}", .{engine.scrollback_last});
    try writer.writeAll("},\"attributes\":{\"schema\":\"sgr\",\"cell_fields\":[\"fg\",\"bg\",\"bold\",\"underline\",\"inverse\"]}");
    try writer.writeAll(",\"process\":{\"status\":");
    try proto.writeJsonString(writer, process.status);
    try writer.writeAll(",\"exit_code\":");
    if (process.exit_code) |code| {
        try writer.print("{d}", .{code});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll("},\"recovery\":{\"state\":");
    try proto.writeJsonString(writer, domain.recoveryLabel(recovery.state));
    try writer.writeAll(",\"notifications\":");
    if (recovery.recovered_notification) {
        try writer.writeAll("[\"SESSION_RECOVERED\"]");
    } else {
        try writer.writeAll("[]");
    }
    try writer.writeAll("},\"vt_engine\":{\"backend\":");
    try proto.writeJsonString(writer, engine.backend.label());
    try writer.writeAll(",\"alternate_screen\":");
    try writer.print("{}", .{engine.alternate_screen});
    try writer.writeAll("}}");
}

fn writeCellsJson(writer: *Io.Writer, engine: *const shadow.Engine) !void {
    var first = true;
    var y: u16 = 0;
    while (y < engine.dimensions.rows) : (y += 1) {
        var x: u16 = 0;
        while (x < engine.dimensions.cols) : (x += 1) {
            const cell = engine.cellAt(x, y);
            if (cell.char == ' ') continue;
            if (!first) try writer.writeAll(",");
            first = false;
            try writer.writeAll("{\"x\":");
            try writer.print("{d}", .{x});
            try writer.writeAll(",\"y\":");
            try writer.print("{d}", .{y});
            try writer.writeAll(",\"text\":");
            var text = [_]u8{cell.char};
            try proto.writeJsonString(writer, &text);
            try writer.writeAll(",\"attrs\":");
            try writeAttrsJson(writer, cell.attrs);
            try writer.writeAll("}");
        }
    }
}

fn writeAttrsJson(writer: *Io.Writer, attrs: shadow.Attributes) !void {
    try writer.writeAll("{\"fg\":");
    try proto.writeJsonString(writer, attrs.fg.label());
    try writer.writeAll(",\"bg\":");
    try proto.writeJsonString(writer, attrs.bg.label());
    try writer.print(",\"bold\":{},\"underline\":{},\"inverse\":{}}}", .{
        attrs.bold,
        attrs.underline,
        attrs.inverse,
    });
}

const FixtureDimensions = struct {
    cols: u16,
    rows: u16,
};

const FixtureProcess = struct {
    status: []const u8,
    exit_code: ?u8 = null,
};

const FixtureAttrs = struct {
    fg: []const u8 = "default",
    bg: []const u8 = "default",
    bold: bool = false,
    underline: bool = false,
    inverse: bool = false,
};

const FixtureCell = struct {
    x: u16,
    y: u16,
    text: []const u8,
    attrs: FixtureAttrs = .{},
};

const FixtureExpected = struct {
    visible_text: []const u8,
    cursor: shadow.Cursor,
    sequence_min: u64,
    alternate_screen: bool = false,
    cells: []const FixtureCell,
};

const SnapshotFixture = struct {
    name: []const u8,
    dimensions: FixtureDimensions,
    chunks: []const []const u8,
    resizes: []const FixtureDimensions = &.{},
    process: FixtureProcess,
    recovery_state: []const u8 = "clean",
    expected: FixtureExpected,
};

pub fn validateFixture(allocator: Allocator, bytes: []const u8) !void {
    const parsed = try std.json.parseFromSlice(SnapshotFixture, allocator, bytes, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();
    const fixture = parsed.value;

    var engine = try shadow.Engine.init(allocator, .{
        .cols = fixture.dimensions.cols,
        .rows = fixture.dimensions.rows,
    });
    defer engine.deinit(allocator);

    for (fixture.chunks) |chunk| try engine.feed(allocator, chunk);
    for (fixture.resizes) |resize| try engine.resize(allocator, .{
        .cols = resize.cols,
        .rows = resize.rows,
    });

    const visible = try engine.visibleText(allocator);
    defer allocator.free(visible);
    try std.testing.expectEqualStrings(fixture.expected.visible_text, visible);
    try std.testing.expectEqual(fixture.expected.cursor.x, engine.cursor.x);
    try std.testing.expectEqual(fixture.expected.cursor.y, engine.cursor.y);
    try std.testing.expect(engine.sequence >= fixture.expected.sequence_min);
    try std.testing.expectEqual(fixture.expected.alternate_screen, engine.alternate_screen);

    for (fixture.expected.cells) |expected| {
        const cell = engine.cellAt(expected.x, expected.y);
        try std.testing.expectEqual(@as(usize, 1), expected.text.len);
        try std.testing.expectEqual(expected.text[0], cell.char);
        try expectAttrs(expected.attrs, cell.attrs);
    }

    var json_writer: Io.Writer.Allocating = .init(allocator);
    defer json_writer.deinit();
    try writeSnapshotJson(allocator, &json_writer.writer, fixture.name, "pane-1", &engine, .{
        .status = fixture.process.status,
        .exit_code = fixture.process.exit_code,
    }, .{
        .state = try recoveryStateFromLabel(fixture.recovery_state),
    });
    const rendered = json_writer.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"visible_cells\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"scrollback_range\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"sequence\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"process\"") != null);
    if (fixture.process.exit_code) |code| {
        const needle = try std.fmt.allocPrint(allocator, "\"exit_code\":{d}", .{code});
        defer allocator.free(needle);
        try std.testing.expect(std.mem.indexOf(u8, rendered, needle) != null);
    }
}

fn expectAttrs(expected: FixtureAttrs, actual: shadow.Attributes) !void {
    try std.testing.expectEqualStrings(expected.fg, actual.fg.label());
    try std.testing.expectEqualStrings(expected.bg, actual.bg.label());
    try std.testing.expectEqual(expected.bold, actual.bold);
    try std.testing.expectEqual(expected.underline, actual.underline);
    try std.testing.expectEqual(expected.inverse, actual.inverse);
}

fn recoveryStateFromLabel(label: []const u8) !domain.RecoveryState {
    if (std.mem.eql(u8, label, "clean")) return .clean;
    if (std.mem.eql(u8, label, "recovered")) return .recovered;
    if (std.mem.eql(u8, label, "degraded_corrupt_snapshot")) return .degraded_corrupt_snapshot;
    if (std.mem.eql(u8, label, "degraded_partial_journal")) return .degraded_partial_journal;
    if (std.mem.eql(u8, label, "degraded_missing_recording_fallback")) return .degraded_missing_recording_fallback;
    return error.InvalidRecoveryState;
}

test "snapshot fixture validator covers structured fields" {
    const fixture =
        \\{
        \\  "name": "inline",
        \\  "dimensions": {"cols": 8, "rows": 2},
        \\  "chunks": ["\u001b[31mR\u001b[0m"],
        \\  "resizes": [],
        \\  "process": {"status": "exited", "exit_code": 7},
        \\  "recovery_state": "clean",
        \\  "expected": {
        \\    "visible_text": "R",
        \\    "cursor": {"x": 1, "y": 0},
        \\    "sequence_min": 3,
        \\    "alternate_screen": false,
        \\    "cells": [{"x": 0, "y": 0, "text": "R", "attrs": {"fg": "red", "bg": "default", "bold": false, "underline": false, "inverse": false}}]
        \\  }
        \\}
    ;
    try validateFixture(std.testing.allocator, fixture);
}
