const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ShellResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,
    signal: ?u32 = null,
    truncated: bool = false,
    allocator: Allocator,

    pub fn deinit(self: *ShellResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }

    /// Format a human-readable result string.
    pub fn format(self: *const ShellResult, allocator: Allocator) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        const w = buf.writer(allocator);

        if (self.signal) |sig| {
            try w.print("Process killed by signal {d}\n", .{sig});
        } else {
            try w.print("Exit code: {d}\n", .{self.exit_code});
        }

        if (self.truncated) {
            try w.writeAll("[WARNING: Output truncated — exceeded 1MB limit]\n");
        }

        if (self.stdout.len > 0) {
            try w.print("stdout:\n{s}\n", .{self.stdout});
        }
        if (self.stderr.len > 0) {
            try w.print("stderr:\n{s}\n", .{self.stderr});
        }

        return buf.toOwnedSlice(allocator);
    }
};

// ──────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────

test "ShellResult.format normal exit with stdout" {
    const allocator = std.testing.allocator;
    const result = ShellResult{
        .stdout = "hello world",
        .stderr = "",
        .exit_code = 0,
        .allocator = allocator,
    };

    const formatted = try result.format(allocator);
    defer allocator.free(formatted);
    try std.testing.expectEqualStrings("Exit code: 0\nstdout:\nhello world\n", formatted);
}

test "ShellResult.format non-zero exit with stderr" {
    const allocator = std.testing.allocator;
    const result = ShellResult{
        .stdout = "",
        .stderr = "command not found",
        .exit_code = 127,
        .allocator = allocator,
    };

    const formatted = try result.format(allocator);
    defer allocator.free(formatted);
    try std.testing.expectEqualStrings("Exit code: 127\nstderr:\ncommand not found\n", formatted);
}

test "ShellResult.format signal killed" {
    const allocator = std.testing.allocator;
    const result = ShellResult{
        .stdout = "",
        .stderr = "",
        .exit_code = 1,
        .signal = 9,
        .allocator = allocator,
    };

    const formatted = try result.format(allocator);
    defer allocator.free(formatted);
    try std.testing.expectEqualStrings("Process killed by signal 9\n", formatted);
}

test "ShellResult.format truncated output" {
    const allocator = std.testing.allocator;
    const result = ShellResult{
        .stdout = "partial output...",
        .stderr = "",
        .exit_code = 0,
        .truncated = true,
        .allocator = allocator,
    };

    const formatted = try result.format(allocator);
    defer allocator.free(formatted);

    // Should contain the truncation warning
    try std.testing.expect(std.mem.indexOf(u8, formatted, "[WARNING: Output truncated") != null);
    // And the stdout
    try std.testing.expect(std.mem.indexOf(u8, formatted, "partial output...") != null);
}

test "ShellResult.format both stdout and stderr" {
    const allocator = std.testing.allocator;
    const result = ShellResult{
        .stdout = "output",
        .stderr = "warning",
        .exit_code = 0,
        .allocator = allocator,
    };

    const formatted = try result.format(allocator);
    defer allocator.free(formatted);
    try std.testing.expectEqualStrings("Exit code: 0\nstdout:\noutput\nstderr:\nwarning\n", formatted);
}

test "ShellResult.format empty output" {
    const allocator = std.testing.allocator;
    const result = ShellResult{
        .stdout = "",
        .stderr = "",
        .exit_code = 0,
        .allocator = allocator,
    };

    const formatted = try result.format(allocator);
    defer allocator.free(formatted);
    try std.testing.expectEqualStrings("Exit code: 0\n", formatted);
}

/// Execute a shell command and capture its output.
pub fn execute(allocator: Allocator, command: []const u8) !ShellResult {
    const argv = [_][]const u8{ "/bin/sh", "-c", command };

    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const max_output = 1024 * 1024; // 1MB
    var truncated = false;

    child.collectOutput(allocator, &stdout_buf, &stderr_buf, max_output) catch |err| {
        if (err == error.StdoutStreamTooLong or err == error.StderrStreamTooLong) {
            truncated = true;
        } else {
            return err;
        }
    };
    const term = try child.wait();

    var exit_code: u8 = 1;
    var signal: ?u32 = null;
    switch (term) {
        .Exited => |code| {
            exit_code = code;
        },
        .Signal => |sig| {
            signal = sig;
        },
        else => {},
    }

    return .{
        .stdout = try allocator.dupe(u8, stdout_buf.items),
        .stderr = try allocator.dupe(u8, stderr_buf.items),
        .exit_code = exit_code,
        .signal = signal,
        .truncated = truncated,
        .allocator = allocator,
    };
}
