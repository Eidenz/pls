const std = @import("std");
const Allocator = std.mem.Allocator;

/// Ask the user for confirmation via the terminal.
/// Returns true if the user confirms (y/Y/yes), false otherwise.
pub fn ask(message: []const u8, auto_yes: bool) !bool {
    if (auto_yes) return true;

    const stderr = std.fs.File.stderr().deprecatedWriter();
    const stdin = std.fs.File.stdin().deprecatedReader();

    try stderr.print("\n{s} [y/N]: ", .{message});

    var buf: [256]u8 = undefined;
    const line = stdin.readUntilDelimiter(&buf, '\n') catch |err| switch (err) {
        error.EndOfStream => return false,
        else => return err,
    };

    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return false;

    return std.ascii.eqlIgnoreCase(trimmed, "y") or
        std.ascii.eqlIgnoreCase(trimmed, "yes");
}

/// Ask the user a clarifying question with numbered options.
/// The user can pick a number or type a custom answer.
/// Returns the chosen option text or the user's custom input.
pub fn askUser(
    allocator: Allocator,
    question: []const u8,
    options: []const []const u8,
    recommended: ?usize,
) ![]const u8 {
    const stderr = std.fs.File.stderr().deprecatedWriter();
    const stdin = std.fs.File.stdin().deprecatedReader();

    try stderr.print("\n\x1b[1m? {s}\x1b[0m\n", .{question});

    for (options, 0..) |option, i| {
        if (recommended != null and recommended.? == i) {
            try stderr.print("  \x1b[36m{d}. {s}  [recommended]\x1b[0m\n", .{ i + 1, option });
        } else {
            try stderr.print("  {d}. {s}\n", .{ i + 1, option });
        }
    }

    try stderr.print("> ", .{});

    var buf: [1024]u8 = undefined;
    const line = stdin.readUntilDelimiter(&buf, '\n') catch |err| switch (err) {
        error.EndOfStream => return allocator.dupe(u8, ""),
        else => return err,
    };

    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) {
        // Empty input: pick recommended if available, otherwise first option
        if (recommended) |rec| {
            if (rec < options.len) {
                return allocator.dupe(u8, options[rec]);
            }
        }
        if (options.len > 0) {
            return allocator.dupe(u8, options[0]);
        }
        return allocator.dupe(u8, "");
    }

    // Try parsing as a number (1-indexed)
    const num = std.fmt.parseInt(usize, trimmed, 10) catch {
        // Not a number — return as custom text
        return allocator.dupe(u8, trimmed);
    };

    if (num >= 1 and num <= options.len) {
        return allocator.dupe(u8, options[num - 1]);
    }

    // Number out of range — return as custom text
    return allocator.dupe(u8, trimmed);
}
