const std = @import("std");
const Allocator = std.mem.Allocator;
const provider = @import("provider.zig");
const json_helpers = @import("json_helpers.zig");
const http_client = @import("http_client.zig");

const API_URL = "https://api.anthropic.com/v1/messages";
const API_VERSION = "2023-06-01";

/// Send a chat request to the Anthropic Claude API.
pub fn chat(
    allocator: Allocator,
    api_key: []const u8,
    model: []const u8,
    system_prompt: []const u8,
    messages: []const provider.Message,
    tools: []const provider.Tool,
) !provider.ChatResponse {
    const body = try buildRequestBody(allocator, model, system_prompt, messages, tools);
    defer allocator.free(body);

    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "x-api-key", .value = api_key },
        .{ .name = "anthropic-version", .value = API_VERSION },
    };

    const response_body = try http_client.post(allocator, API_URL, &headers, body);
    defer allocator.free(response_body);

    return parseResponse(allocator, response_body);
}

fn buildRequestBody(
    allocator: Allocator,
    model: []const u8,
    system_prompt: []const u8,
    messages: []const provider.Message,
    tools: []const provider.Tool,
) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.print("{{\"model\":\"{s}\",\"max_tokens\":4096,\"system\":\"", .{model});

    const sys_escaped = try json_helpers.escapeJsonString(allocator, system_prompt);
    defer allocator.free(sys_escaped);
    try w.writeAll(sys_escaped);

    try w.writeAll("\",\"messages\":");

    const msgs_json = try json_helpers.buildAnthropicMessagesJson(allocator, messages);
    defer allocator.free(msgs_json);
    try w.writeAll(msgs_json);

    if (tools.len > 0) {
        try w.writeAll(",\"tools\":");
        const tools_json = try json_helpers.buildAnthropicToolsJson(allocator, tools);
        defer allocator.free(tools_json);
        try w.writeAll(tools_json);
    }

    try w.writeAll("}");

    return buf.toOwnedSlice(allocator);
}

pub fn parseResponse(allocator: Allocator, body: []const u8) !provider.ChatResponse {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return error.JsonParseError;
    };
    defer parsed.deinit();

    const root = parsed.value.object;

    if (root.get("error")) |_| {
        return error.ApiError;
    }

    const stop_str = if (root.get("stop_reason")) |sr| switch (sr) {
        .string => |s| s,
        else => "unknown",
    } else "unknown";
    const stop_reason = provider.StopReason.fromString(stop_str);

    const content_arr = if (root.get("content")) |c| switch (c) {
        .array => |a| a,
        else => return error.InvalidResponse,
    } else return error.InvalidResponse;

    var content_blocks: std.ArrayList(provider.ContentBlock) = .empty;
    errdefer {
        for (content_blocks.items) |*block| block.deinit(allocator);
        content_blocks.deinit(allocator);
    }

    for (content_arr.items) |block_val| {
        const block_obj = switch (block_val) {
            .object => |o| o,
            else => continue,
        };

        const block_type = if (block_obj.get("type")) |t| switch (t) {
            .string => |s| s,
            else => continue,
        } else continue;

        if (std.mem.eql(u8, block_type, "text")) {
            const text_str = if (block_obj.get("text")) |t| switch (t) {
                .string => |s| s,
                else => continue,
            } else continue;
            try content_blocks.append(allocator, .{ .text = try allocator.dupe(u8, text_str) });
        } else if (std.mem.eql(u8, block_type, "tool_use")) {
            const id = if (block_obj.get("id")) |v| switch (v) {
                .string => |s| s,
                else => continue,
            } else continue;

            const name = if (block_obj.get("name")) |v| switch (v) {
                .string => |s| s,
                else => continue,
            } else continue;

            const input_val = block_obj.get("input") orelse continue;
            const input_json = std.json.Stringify.valueAlloc(allocator, input_val, .{}) catch continue;

            try content_blocks.append(allocator, .{
                .tool_call = .{
                    .id = try allocator.dupe(u8, id),
                    .name = try allocator.dupe(u8, name),
                    .arguments = input_json,
                },
            });
        }
    }

    const content = try content_blocks.toOwnedSlice(allocator);

    return .{
        .message = .{
            .role = .assistant,
            .content = content,
        },
        .stop_reason = stop_reason,
    };
}

// ──────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────

test "parseResponse text content" {
    const a = std.testing.allocator;
    const body =
        \\{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":"Hello!"}],"stop_reason":"end_turn"}
    ;
    var resp = try parseResponse(a, body);
    defer resp.deinit(a);

    try std.testing.expectEqual(provider.Role.assistant, resp.message.role);
    try std.testing.expectEqual(provider.StopReason.end_turn, resp.stop_reason);
    try std.testing.expect(resp.message.content.len == 1);
    try std.testing.expectEqualStrings("Hello!", resp.message.getText().?);
    try std.testing.expect(!resp.message.hasToolCalls());
}

test "parseResponse tool_use content" {
    const a = std.testing.allocator;
    const body =
        \\{"id":"msg_2","type":"message","role":"assistant","content":[{"type":"text","text":"Running..."},{"type":"tool_use","id":"tu_1","name":"run_shell","input":{"command":"ls -la"}}],"stop_reason":"tool_use"}
    ;
    var resp = try parseResponse(a, body);
    defer resp.deinit(a);

    try std.testing.expectEqual(provider.StopReason.tool_use, resp.stop_reason);
    try std.testing.expect(resp.message.content.len == 2);
    try std.testing.expectEqualStrings("Running...", resp.message.getText().?);
    try std.testing.expect(resp.message.hasToolCalls());

    const tc = resp.message.content[1].tool_call;
    try std.testing.expectEqualStrings("tu_1", tc.id);
    try std.testing.expectEqualStrings("run_shell", tc.name);
    // arguments should be valid JSON
    try std.testing.expect(std.mem.indexOf(u8, tc.arguments, "ls -la") != null);
}

test "parseResponse error response" {
    const a = std.testing.allocator;
    const body =
        \\{"type":"error","error":{"type":"authentication_error","message":"Invalid API key"}}
    ;
    const result = parseResponse(a, body);
    try std.testing.expectError(error.ApiError, result);
}

test "parseResponse malformed JSON" {
    const a = std.testing.allocator;
    const result = parseResponse(a, "not json at all");
    try std.testing.expectError(error.JsonParseError, result);
}

test "parseResponse missing content array" {
    const a = std.testing.allocator;
    const body =
        \\{"id":"msg_1","type":"message","role":"assistant","stop_reason":"end_turn"}
    ;
    const result = parseResponse(a, body);
    try std.testing.expectError(error.InvalidResponse, result);
}
