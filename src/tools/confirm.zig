const std = @import("std");

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

/// Show a command that's about to be executed and ask for confirmation.
pub fn confirmCommand(command: []const u8, auto_yes: bool) !bool {
    const stderr = std.fs.File.stderr().deprecatedWriter();
    try stderr.print("\n  > {s}\n", .{command});

    return ask("Execute this command?", auto_yes);
}
