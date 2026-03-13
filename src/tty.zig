const std = @import("std");

var line_buf: [4096]u8 = undefined;

/// Read a line from the given reader, trimming whitespace.
pub fn readLine(reader: anytype) ![]const u8 {
    const line = reader.readUntilDelimiter(&line_buf, '\n') catch |err| switch (err) {
        error.EndOfStream => return "",
        else => return err,
    };
    return std.mem.trim(u8, line, " \t\r");
}

/// Read a line with terminal echo disabled (for API keys and secrets).
/// Falls back to normal readLine if TTY attributes can't be modified.
pub fn readLineMasked(reader: anytype) ![]const u8 {
    const stderr = std.fs.File.stderr().deprecatedWriter();
    const stdin_fd = std.fs.File.stdin().handle;

    // Save original terminal settings
    const orig = std.posix.tcgetattr(stdin_fd) catch {
        // If we can't get attrs (e.g. not a TTY), fall back to normal read
        return readLine(reader);
    };

    // Disable echo
    var noecho = orig;
    noecho.lflag.ECHO = false;
    std.posix.tcsetattr(stdin_fd, .NOW, noecho) catch {
        return readLine(reader);
    };

    // Read the line
    const line = reader.readUntilDelimiter(&line_buf, '\n') catch |err| switch (err) {
        error.EndOfStream => {
            std.posix.tcsetattr(stdin_fd, .NOW, orig) catch {};
            try stderr.writeAll("\n");
            return "";
        },
        else => {
            std.posix.tcsetattr(stdin_fd, .NOW, orig) catch {};
            return err;
        },
    };

    // Restore terminal settings
    std.posix.tcsetattr(stdin_fd, .NOW, orig) catch {};
    try stderr.writeAll("\n");

    return std.mem.trim(u8, line, " \t\r");
}
