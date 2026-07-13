const std = @import("std");
const minimux = @import("minimux");

const plain_json = @embedFile("fixtures/vt/plain-text.json");
const plain_ansi = @embedFile("fixtures/vt/plain-text.ansi");
const color_json = @embedFile("fixtures/vt/color-attributes.json");
const color_ansi = @embedFile("fixtures/vt/color-attributes.ansi");
const alternate_json = @embedFile("fixtures/vt/alternate-screen.json");
const alternate_ansi = @embedFile("fixtures/vt/alternate-screen.ansi");
const resize_json = @embedFile("fixtures/vt/resize.json");
const resize_ansi = @embedFile("fixtures/vt/resize.ansi");
const process_exit_json = @embedFile("fixtures/vt/process-exit.json");
const process_exit_ansi = @embedFile("fixtures/vt/process-exit.ansi");
const erase_line_json = @embedFile("fixtures/vt/erase-line.json");
const erase_line_ansi = @embedFile("fixtures/vt/erase-line.ansi");
const cursor_move_json = @embedFile("fixtures/vt/cursor-move.json");
const cursor_move_ansi = @embedFile("fixtures/vt/cursor-move.ansi");

test "snapshot fixture covers plain text" {
    try std.testing.expect(plain_ansi.len > 0);
    try minimux.snapshot.validateFixture(std.testing.allocator, plain_json);
}

test "snapshot fixture covers color attributes" {
    try std.testing.expect(color_ansi.len > 0);
    try minimux.snapshot.validateFixture(std.testing.allocator, color_json);
}

test "snapshot fixture covers alternate screen entry and exit" {
    try std.testing.expect(alternate_ansi.len > 0);
    try minimux.snapshot.validateFixture(std.testing.allocator, alternate_json);
}

test "snapshot fixture covers resize" {
    try std.testing.expect(resize_ansi.len > 0);
    try minimux.snapshot.validateFixture(std.testing.allocator, resize_json);
}

test "snapshot fixture covers process exit code" {
    try std.testing.expect(process_exit_ansi.len > 0);
    try minimux.snapshot.validateFixture(std.testing.allocator, process_exit_json);
}

test "snapshot fixture covers erase-line prompt redraw" {
    try std.testing.expect(erase_line_ansi.len > 0);
    try minimux.snapshot.validateFixture(std.testing.allocator, erase_line_json);
}

test "snapshot fixture covers cursor moves with edge clamping" {
    try std.testing.expect(cursor_move_ansi.len > 0);
    try minimux.snapshot.validateFixture(std.testing.allocator, cursor_move_json);
}
