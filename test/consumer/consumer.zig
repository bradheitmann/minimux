const std = @import("std");
const full = @import("full");
const control = @import("control");
const proto = @import("proto");

test "combined consumer shares public control and protocol type identities" {
    try std.testing.expect(control.ControlInbox == full.control.ControlInbox);
    try std.testing.expect(control.ControlInbox == full.daemon.ControlInbox);
    try std.testing.expect(control.DeadlineWriter == full.daemon.DeadlineWriter);
    try std.testing.expect(proto.PublicMethod == full.proto.PublicMethod);
    try std.testing.expectEqualStrings(proto.protocol_version, full.proto.protocol_version);
    try std.testing.expect(!control.sameControlUser(-1));
    try std.testing.expect(!full.session.sameControlUser(-1));
    var inbox: full.daemon.ControlInbox = .{};
    const extracted: *control.ControlInbox = &inbox;
    extracted.deinit(std.testing.allocator, std.testing.io);
}

test "combined consumer preserves fail-closed output" {
    var buffer: [16]u8 = undefined;
    var writer = control.DeadlineWriter.init(std.testing.io, -1, &buffer);
    writer.deadline = 0;
    try writer.interface.writeAll("response");
    try std.testing.expectError(error.WriteFailed, writer.interface.flush());
}
