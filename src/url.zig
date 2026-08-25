const std = @import("std");
const c = @import("c.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{Invalid} || Allocator.Error;

pub fn resolve(gpa: Allocator, argument: []const u8) Error![:0]u8 {
    const trimmed = std.mem.trim(u8, argument, " \t\r\n");
    if (trimmed.len == 0 or hasSpace(trimmed)) return error.Invalid;

    if (hasScheme(trimmed)) {
        const given = try gpa.dupeZ(u8, trimmed);
        if (valid(given)) return given;
        gpa.free(given);
        return error.Invalid;
    }

    const prefixed = try std.fmt.allocPrintSentinel(gpa, "https://{s}", .{trimmed}, 0);
    if (valid(prefixed)) return prefixed;
    gpa.free(prefixed);
    return error.Invalid;
}

pub fn display(uri: [:0]const u8) [:0]const u8 {
    if (std.mem.startsWith(u8, uri, "https://")) return uri["https://".len..];
    if (std.mem.startsWith(u8, uri, "http://")) return uri["http://".len..];
    return uri;
}

fn valid(uri: [:0]const u8) bool {
    return c.g_uri_is_valid(uri.ptr, c.uri_flags_none, null) != c.FALSE;
}

fn hasScheme(text: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return false;
    if (colon == 0) return false;
    if (!std.ascii.isAlphabetic(text[0])) return false;
    for (text[1..colon]) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        if (byte == '+' or byte == '-') continue;
        return false;
    }
    return true;
}

fn hasSpace(text: []const u8) bool {
    return std.mem.indexOfAny(u8, text, " \t\r\n") != null;
}

test hasScheme {
    try std.testing.expect(hasScheme("https://example.com"));
    try std.testing.expect(hasScheme("mailto:someone@example.com"));
    try std.testing.expect(hasScheme("about:blank"));
    try std.testing.expect(hasScheme("view-source:https://example.com"));
    try std.testing.expect(!hasScheme("example.com"));
    try std.testing.expect(!hasScheme("example.com:8080/path"));
    try std.testing.expect(!hasScheme("://example.com"));
    try std.testing.expect(!hasScheme("1http://example.com"));
}

test "a host with a port is not read as a scheme" {
    const gpa = std.testing.allocator;

    const resolved = try resolve(gpa, "example.com:8080/path");
    defer gpa.free(resolved);
    try std.testing.expectEqualStrings("https://example.com:8080/path", resolved);
}

test "a scheme other than http is passed on" {
    const gpa = std.testing.allocator;

    const resolved = try resolve(gpa, "about:blank");
    defer gpa.free(resolved);
    try std.testing.expectEqualStrings("about:blank", resolved);
}

test "a valid address is taken verbatim" {
    const gpa = std.testing.allocator;

    const resolved = try resolve(gpa, "https://example.com/a?b=c#d");
    defer gpa.free(resolved);
    try std.testing.expectEqualStrings("https://example.com/a?b=c#d", resolved);
}

test "surrounding space is trimmed" {
    const gpa = std.testing.allocator;

    const resolved = try resolve(gpa, "  https://example.com\n");
    defer gpa.free(resolved);
    try std.testing.expectEqualStrings("https://example.com", resolved);
}

test "a bare host gets https" {
    const gpa = std.testing.allocator;

    const resolved = try resolve(gpa, "example.com/path");
    defer gpa.free(resolved);
    try std.testing.expectEqualStrings("https://example.com/path", resolved);
}

test "a non-address is rejected" {
    const gpa = std.testing.allocator;

    try std.testing.expectError(error.Invalid, resolve(gpa, ""));
    try std.testing.expectError(error.Invalid, resolve(gpa, "   "));
    try std.testing.expectError(error.Invalid, resolve(gpa, "not an address"));
}

test display {
    try std.testing.expectEqualStrings("example.com/a", display("https://example.com/a"));
    try std.testing.expectEqualStrings("example.com/a", display("http://example.com/a"));
    try std.testing.expectEqualStrings("mailto:someone@example.com", display("mailto:someone@example.com"));
}
