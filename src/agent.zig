const std = @import("std");
const Allocator = std.mem.Allocator;
const config_mod = @import("config.zig");
const provider = @import("llm/provider.zig");
const anthropic = @import("llm/anthropic.zig");
const openai = @import("llm/openai.zig");
const gemini = @import("llm/gemini.zig");
const ollama = @import("llm/ollama.zig");
const shell = @import("tools/shell.zig");
const confirm = @import("tools/confirm.zig");

const SYSTEM_PROMPT =
    \\You are `pls`, a command-line assistant that helps users accomplish tasks by executing shell commands.
    \\
    \\You have access to the following tools:
    \\
    \\1. `run_shell` - Execute a shell command on the user's machine. Use this to accomplish the user's task.
    \\   Arguments: {"command": "the shell command to run"}
    \\
    \\2. `confirm` - Ask the user for confirmation before doing something potentially destructive.
    \\   Arguments: {"message": "description of what you're about to do"}
    \\
    \\Guidelines:
    \\- Break complex tasks into steps. Run one command, observe the output, then decide what to do next.
    \\- ALWAYS use `confirm` before destructive operations (kill, rm -rf, drop database, etc).
    \\- Use `run_shell` to investigate first (e.g., list processes, check files) before taking action.
    \\- Prefer safe, reversible approaches when possible.
    \\- Keep your text responses short and clear.
    \\- If a command fails, try to diagnose the issue and suggest alternatives.
    \\- The user's operating system is detected automatically. Use appropriate commands.
    \\- Respond in the same language the user uses.
;

const TOOLS = [_]provider.Tool{
    .{
        .name = "run_shell",
        .description = "Execute a shell command on the user's machine and return its output.",
        .properties = &[_]provider.ToolProperty{
            .{ .name = "command", .type = "string", .description = "The shell command to execute" },
        },
        .required = &[_][]const u8{"command"},
    },
    .{
        .name = "confirm",
        .description = "Ask the user for confirmation before performing a potentially destructive action.",
        .properties = &[_]provider.ToolProperty{
            .{ .name = "message", .type = "string", .description = "Description of the action to confirm" },
        },
        .required = &[_][]const u8{"message"},
    },
};

pub const AgentOptions = struct {
    confirm_mode: config_mod.ConfirmMode = .all,
    dry_run: bool = false,
    max_turns: usize = 20,
};

pub const Agent = struct {
    allocator: Allocator,
    cfg: *const config_mod.Config,
    messages: std.ArrayList(provider.Message) = .empty,
    options: AgentOptions,
    stderr: std.fs.File.DeprecatedWriter,

    pub fn init(allocator: Allocator, cfg: *const config_mod.Config, options: AgentOptions) Agent {
        return .{
            .allocator = allocator,
            .cfg = cfg,
            .options = options,
            .stderr = std.fs.File.stderr().deprecatedWriter(),
        };
    }

    pub fn deinit(self: *Agent) void {
        for (self.messages.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.messages.deinit(self.allocator);
    }

    /// Run the agent with a user task.
    pub fn run(self: *Agent, task: []const u8) !void {
        // Add the user's task as the first message
        const user_msg = try provider.Message.text(self.allocator, .user, task);
        try self.messages.append(self.allocator, user_msg);

        var turn: usize = 0;
        while (turn < self.options.max_turns) : (turn += 1) {
            // Call the LLM
            var response = try self.callLlm();

            // Print any text content
            for (response.message.content) |block| {
                switch (block) {
                    .text => |text| {
                        try self.stderr.print("{s}\n", .{text});
                    },
                    else => {},
                }
            }

            // If no tool calls, we're done
            if (!response.message.hasToolCalls()) {
                response.deinit(self.allocator);
                break;
            }

            // Clone the assistant message into our history before processing tool calls
            const cloned_msg = try self.cloneMessage(&response.message);
            try self.messages.append(self.allocator, cloned_msg);

            // Process tool calls and collect results
            for (response.message.content) |block| {
                switch (block) {
                    .tool_call => |tc| {
                        const result = try self.executeTool(&tc);
                        defer self.allocator.free(result);

                        const tool_msg = try provider.Message.toolResult(
                            self.allocator,
                            tc.id,
                            result,
                        );
                        try self.messages.append(self.allocator, tool_msg);
                    },
                    else => {},
                }
            }

            // Free the response after we're done using its content
            response.deinit(self.allocator);
        }

        // Warn if the agent hit the turn limit
        if (turn >= self.options.max_turns) {
            try self.stderr.print("\n\x1b[33m[warning]\x1b[0m Reached the maximum of {d} turns. Use --max-turns to increase.\n", .{self.options.max_turns});
        }
    }

    fn callLlm(self: *Agent) !provider.ChatResponse {
        return switch (self.cfg.provider) {
            .anthropic => blk: {
                const api_key = self.cfg.anthropic_api_key orelse return error.NoApiKey;
                break :blk anthropic.chat(
                    self.allocator,
                    api_key,
                    self.cfg.anthropic_model,
                    SYSTEM_PROMPT,
                    self.messages.items,
                    &TOOLS,
                );
            },
            .openai => blk: {
                const api_key = self.cfg.openai_api_key orelse return error.NoApiKey;
                break :blk openai.chat(
                    self.allocator,
                    api_key,
                    self.cfg.openai_model,
                    SYSTEM_PROMPT,
                    self.messages.items,
                    &TOOLS,
                    null,
                );
            },
            .gemini => blk: {
                const api_key = self.cfg.gemini_api_key orelse return error.NoApiKey;
                break :blk gemini.chat(
                    self.allocator,
                    api_key,
                    self.cfg.gemini_model,
                    SYSTEM_PROMPT,
                    self.messages.items,
                    &TOOLS,
                );
            },
            .ollama => ollama.chat(
                self.allocator,
                self.cfg.ollama_model,
                SYSTEM_PROMPT,
                self.messages.items,
                &TOOLS,
                self.cfg.ollama_host,
            ),
        };
    }

    fn executeTool(self: *Agent, tc: *const provider.ToolCall) ![]const u8 {
        if (std.mem.eql(u8, tc.name, "run_shell")) {
            return self.executeShellTool(tc.arguments);
        } else if (std.mem.eql(u8, tc.name, "confirm")) {
            return self.executeConfirmTool(tc.arguments);
        } else {
            return self.allocator.dupe(u8, "Unknown tool");
        }
    }

    fn executeShellTool(self: *Agent, arguments_json: []const u8) ![]const u8 {
        const command = try extractJsonString(self.allocator, arguments_json, "command");
        defer self.allocator.free(command);

        try self.stderr.print("  \x1b[90m$ {s}\x1b[0m\n", .{command});

        if (self.options.dry_run) {
            return self.allocator.dupe(u8, "[dry-run] Command not executed.");
        }

        // Check if the command needs confirmation based on confirm_mode
        const needs_confirm = switch (self.options.confirm_mode) {
            .all => true,
            .destructive => isDestructive(command),
            .none => false,
        };
        if (needs_confirm) {
            const confirmed = try confirm.confirmCommand(command, false);
            if (!confirmed) {
                return self.allocator.dupe(u8, "User declined to execute this command.");
            }
        }

        var result = try shell.execute(self.allocator, command);
        defer result.deinit();

        return result.format(self.allocator);
    }

    fn executeConfirmTool(self: *Agent, arguments_json: []const u8) ![]const u8 {
        const message = try extractJsonString(self.allocator, arguments_json, "message");
        defer self.allocator.free(message);

        if (self.options.dry_run) {
            try self.stderr.print("  [dry-run] Would ask: {s}\n", .{message});
            return self.allocator.dupe(u8, "true");
        }

        const auto_yes = self.options.confirm_mode == .none;
        const confirmed = try confirm.ask(message, auto_yes);
        return self.allocator.dupe(u8, if (confirmed) "true" else "false");
    }

    fn cloneMessage(self: *Agent, msg: *const provider.Message) !provider.Message {
        const new_content = try self.allocator.alloc(provider.ContentBlock, msg.content.len);
        for (msg.content, 0..) |block, i| {
            new_content[i] = switch (block) {
                .text => |t| .{ .text = try self.allocator.dupe(u8, t) },
                .tool_call => |tc| .{
                    .tool_call = .{
                        .id = try self.allocator.dupe(u8, tc.id),
                        .name = try self.allocator.dupe(u8, tc.name),
                        .arguments = try self.allocator.dupe(u8, tc.arguments),
                    },
                },
            };
        }

        return .{
            .role = msg.role,
            .content = new_content,
            .tool_call_id = if (msg.tool_call_id) |id| try self.allocator.dupe(u8, id) else null,
            .raw_parts = if (msg.raw_parts) |rp| try self.allocator.dupe(u8, rp) else null,
        };
    }
};

/// Extract a string field from a JSON object.
fn extractJsonString(allocator: Allocator, json_str: []const u8, field: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        return error.JsonParseError;
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidResponse,
    };

    const value = if (obj.get(field)) |v| switch (v) {
        .string => |s| s,
        else => return error.InvalidResponse,
    } else return error.InvalidResponse;

    return allocator.dupe(u8, value);
}

/// Check if a command looks destructive.
pub fn isDestructive(command: []const u8) bool {
    const patterns = [_][]const u8{
        "kill ",
        "killall ",
        "pkill ",
        "rm ",
        "rm -",
        "rmdir ",
        "drop ",
        "truncate ",
        "shutdown",
        "reboot",
        "mkfs",
        "dd ",
        "format ",
        "> /dev/",
    };

    const lower = blk: {
        var buf_arr: [4096]u8 = undefined;
        const len = @min(command.len, buf_arr.len);
        for (0..len) |i| {
            buf_arr[i] = std.ascii.toLower(command[i]);
        }
        break :blk buf_arr[0..len];
    };

    for (patterns) |pattern| {
        if (std.mem.indexOf(u8, lower, pattern) != null) return true;
    }
    return false;
}

// ──────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────

test "isDestructive detects kill commands" {
    try std.testing.expect(isDestructive("kill 1234"));
    try std.testing.expect(isDestructive("killall node"));
    try std.testing.expect(isDestructive("pkill -9 python"));
}

test "isDestructive detects rm commands" {
    try std.testing.expect(isDestructive("rm file.txt"));
    try std.testing.expect(isDestructive("rm -rf /tmp/stuff"));
    try std.testing.expect(isDestructive("rmdir empty_dir"));
}

test "isDestructive detects other dangerous patterns" {
    try std.testing.expect(isDestructive("drop table users"));
    try std.testing.expect(isDestructive("truncate big_table"));
    try std.testing.expect(isDestructive("shutdown -h now"));
    try std.testing.expect(isDestructive("reboot"));
    try std.testing.expect(isDestructive("mkfs.ext4 /dev/sda1"));
    try std.testing.expect(isDestructive("dd if=/dev/zero of=/dev/sda"));
    try std.testing.expect(isDestructive("format C:"));
    try std.testing.expect(isDestructive("echo oops > /dev/sda"));
}

test "isDestructive is case-insensitive" {
    try std.testing.expect(isDestructive("KILL 1234"));
    try std.testing.expect(isDestructive("Rm -Rf /tmp"));
    try std.testing.expect(isDestructive("SHUTDOWN"));
    try std.testing.expect(isDestructive("Reboot"));
    try std.testing.expect(isDestructive("DD if=x of=y"));
}

test "isDestructive returns false for safe commands" {
    try std.testing.expect(!isDestructive("ls -la"));
    try std.testing.expect(!isDestructive("cat file.txt"));
    try std.testing.expect(!isDestructive("grep -r pattern ."));
    try std.testing.expect(!isDestructive("echo hello"));
    try std.testing.expect(!isDestructive("pwd"));
    try std.testing.expect(!isDestructive("ps aux"));
    try std.testing.expect(!isDestructive("curl https://example.com"));
    try std.testing.expect(!isDestructive("mkdir new_dir"));
}

test "isDestructive handles empty command" {
    try std.testing.expect(!isDestructive(""));
}

test "isDestructive detects pattern in middle of command" {
    try std.testing.expect(isDestructive("sudo kill -9 1234"));
    try std.testing.expect(isDestructive("sudo rm -rf /"));
    try std.testing.expect(isDestructive("echo data > /dev/sda"));
}

test "extractJsonString extracts valid field" {
    const allocator = std.testing.allocator;
    const result = try extractJsonString(allocator, "{\"command\":\"ls -la\"}", "command");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("ls -la", result);
}

test "extractJsonString returns error for missing field" {
    const allocator = std.testing.allocator;
    const result = extractJsonString(allocator, "{\"other\":\"value\"}", "command");
    try std.testing.expectError(error.InvalidResponse, result);
}

test "extractJsonString returns error for non-string field" {
    const allocator = std.testing.allocator;
    const result = extractJsonString(allocator, "{\"command\":42}", "command");
    try std.testing.expectError(error.InvalidResponse, result);
}

test "extractJsonString returns error for malformed JSON" {
    const allocator = std.testing.allocator;
    const result = extractJsonString(allocator, "not json", "command");
    try std.testing.expectError(error.JsonParseError, result);
}

test "extractJsonString returns error for JSON array" {
    const allocator = std.testing.allocator;
    const result = extractJsonString(allocator, "[1, 2, 3]", "command");
    try std.testing.expectError(error.InvalidResponse, result);
}

test "extractJsonString handles unicode and escaped strings" {
    const allocator = std.testing.allocator;
    const result = try extractJsonString(allocator, "{\"msg\":\"hello\\nworld\"}", "msg");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello\nworld", result);
}
