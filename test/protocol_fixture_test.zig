const std = @import("std");
const minimux = @import("minimux");

const valid_fixture = @embedFile("fixtures/protocol/valid-v0.1.0.json");
const invalid_unknown_required_field = @embedFile("fixtures/protocol/invalid-unknown-required-field.json");
const invalid_enum_value = @embedFile("fixtures/protocol/invalid-enum-value.json");
const invalid_non_monotonic_sequence = @embedFile("fixtures/protocol/invalid-non-monotonic-sequence.json");
const invalid_missing_required_param = @embedFile("fixtures/protocol/invalid-missing-required-param.json");
const invalid_unknown_method = @embedFile("fixtures/protocol/invalid-unknown-method.json");

test "protocol fixture validates v0.1.0 methods and errors" {
    try minimux.proto.validateProtocolFixture(std.testing.allocator, valid_fixture);
    try std.testing.expectEqual(@as(usize, 15), minimux.public_methods.len);
    try std.testing.expectEqual(@as(usize, 14), minimux.error_codes.len);
}

test "protocol fixture rejects unknown required fields" {
    try std.testing.expectError(
        error.UnknownRequiredField,
        minimux.proto.validateProtocolFixture(std.testing.allocator, invalid_unknown_required_field),
    );
}

test "protocol fixture rejects invalid enum values" {
    try std.testing.expectError(
        error.InvalidEnumValue,
        minimux.proto.validateProtocolFixture(std.testing.allocator, invalid_enum_value),
    );
}

test "protocol fixture rejects non-monotonic sequence numbers" {
    try std.testing.expectError(
        error.NonMonotonicSequence,
        minimux.proto.validateProtocolFixture(std.testing.allocator, invalid_non_monotonic_sequence),
    );
}

test "protocol fixture rejects missing required params" {
    try std.testing.expectError(
        error.MissingRequiredParam,
        minimux.proto.validateProtocolFixture(std.testing.allocator, invalid_missing_required_param),
    );
}

test "protocol fixture rejects unknown methods" {
    try std.testing.expectError(
        error.UnknownMethod,
        minimux.proto.validateProtocolFixture(std.testing.allocator, invalid_unknown_method),
    );
}
