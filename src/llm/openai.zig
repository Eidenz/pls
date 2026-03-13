const std = @import("std");
const Allocator = std.mem.Allocator;
const provider = @import("provider.zig");
const json_helpers = @import("json_helpers.zig");
const http_client = @import("http_client.zig");

const DEFAULT_API_URL = "https://api.openai.com/v1/chat/completions";

/// Send a chat request to an OpenAI-compatible API.
/// Used by both OpenAI and Ollama providers.
pub fn chat(
    allocator: Allocator,
    api_key: ?[]const u8,
    model: []const u8,
    system_prompt: []const u8,
    messages: []const provider.Message,
    tools: []const provider.Tool,
    base_url: ?[]const u8,
) !provider.ChatResponse {
    const body = try buildRequestBody(allocator, model, system_prompt, messages, tools);
    defer allocator.free(body);

    var headers_list: std.ArrayList(std.http.Header) = .empty;
    defer headers_list.deinit(allocator);

    try headers_list.append(allocator, .{ .name = "content-type", .value = "application/json" });

    var auth_duped: ?[]const u8 = null;
    defer if (auth_duped) |a| allocator.free(a);

    if (api_key) |key| {
        auth_duped = try std.fmt.allocPrint(allocator, "Bearer {s}", .{key});
        try headers_list.append(allocator, .{ .name = "authorization", .value = auth_duped.? });
    }

    const url = if (base_url) |bu|
        try std.fmt.allocPrint(allocator, "{s}/v1/chat/completions", .{bu})
    else
        try allocator.dupe(u8, DEFAULT_API_URL);
    defer allocator.free(url);

    const response_body = try http_client.post(allocator, url, headers_list.items, body);
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

    try w.print("{{\"model\":\"{s}\",\"messages\":", .{model});

    const msgs_json = try json_helpers.buildOpenAIMessagesJson(allocator, system_prompt, messages);
    defer allocator.free(msgs_json);
    try w.writeAll(msgs_json);

    if (tools.len > 0) {
        try w.writeAll(",\"tools\":");
        const tools_json = try json_helpers.buildOpenAIToolsJson(allocator, tools);
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

    const choices = if (root.get("choices")) |c| switch (c) {
        .array => |a| a,
        else => return error.InvalidResponse,
    } else return error.InvalidResponse;

    if (choices.items.len == 0) return error.InvalidResponse;

    const choice = switch (choices.items[0]) {
        .object => |o| o,
        else => return error.InvalidResponse,
    };

    const finish_str = if (choice.get("finish_reason")) |fr| switch (fr) {
        .string => |s| s,
        else => "unknown",
    } else "unknown";
    const stop_reason = provider.StopReason.fromString(finish_str);

    const msg_obj = if (choice.get("message")) |m| switch (m) {
        .object => |o| o,
        else => return error.InvalidResponse,
    } else return error.InvalidResponse;

    var content_blocks: std.ArrayList(provider.ContentBlock) = .empty;
    errdefer {
        for (content_blocks.items) |*block| block.deinit(allocator);
        content_blocks.deinit(allocator);
    }

    // Parse text content
    if (msg_obj.get("content")) |content_val| {
        switch (content_val) {
            .string => |s| {
                if (s.len > 0) {
                    try content_blocks.append(allocator, .{ .text = try allocator.dupe(u8, s) });
                }
            },
            else => {},
        }
    }

    // Parse tool calls
    if (msg_obj.get("tool_calls")) |tc_val| {
        switch (tc_val) {
            .array => |tc_arr| {
                for (tc_arr.items) |tc_item| {
                    const tc_obj = switch (tc_item) {
                        .object => |o| o,
                        else => continue,
                    };

                    const id = if (tc_obj.get("id")) |v| switch (v) {
                        .string => |s| s,
                        else => continue,
                    } else continue;

                    const func_obj = if (tc_obj.get("function")) |f| switch (f) {
                        .object => |o| o,
                        else => continue,
                    } else continue;

                    const name = if (func_obj.get("name")) |v| switch (v) {
                        .string => |s| s,
                        else => continue,
                    } else continue;

                    const func_args = if (func_obj.get("arguments")) |v| switch (v) {
                        .string => |s| s,
                        else => continue,
                    } else continue;

                    try content_blocks.append(allocator, .{
                        .tool_call = .{
                            .id = try allocator.dupe(u8, id),
                            .name = try allocator.dupe(u8, name),
                            .arguments = try allocator.dupe(u8, func_args),
                        },
                    });
                }
            },
            else => {},
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
        \\{"id":"chatcmpl-1","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"Hello!"},"finish_reason":"stop"}]}
    ;
    var resp = try parseResponse(a, body);
    defer resp.deinit(a);

    try std.testing.expectEqual(provider.Role.assistant, resp.message.role);
    try std.testing.expectEqual(provider.StopReason.end_turn, resp.stop_reason);
    try std.testing.expect(resp.message.content.len == 1);
    try std.testing.expectEqualStrings("Hello!", resp.message.getText().?);
    try std.testing.expect(!resp.message.hasToolCalls());
}

test "parseResponse with tool calls" {
    const a = std.testing.allocator;
    const body =
        \\{"id":"chatcmpl-2","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_abc","type":"function","function":{"name":"run_shell","arguments":"{\"command\":\"ls\"}"}}]},"finish_reason":"tool_calls"}]}
    ;
    var resp = try parseResponse(a, body);
    defer resp.deinit(a);

    try std.testing.expectEqual(provider.StopReason.tool_use, resp.stop_reason);
    try std.testing.expect(resp.message.hasToolCalls());
    try std.testing.expect(resp.message.content.len == 1);

    const tc = resp.message.content[0].tool_call;
    try std.testing.expectEqualStrings("call_abc", tc.id);
    try std.testing.expectEqualStrings("run_shell", tc.name);
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", tc.arguments);
}

test "parseResponse error response" {
    const a = std.testing.allocator;
    const body =
        \\{"error":{"message":"Invalid API key","type":"invalid_request_error"}}
    ;
    const result = parseResponse(a, body);
    try std.testing.expectError(error.ApiError, result);
}

test "parseResponse malformed JSON" {
    const a = std.testing.allocator;
    const result = parseResponse(a, "not json");
    try std.testing.expectError(error.JsonParseError, result);
}

test "parseResponse empty choices" {
    const a = std.testing.allocator;
    const body =
        \\{"id":"chatcmpl-3","choices":[]}
    ;
    const result = parseResponse(a, body);
    try std.testing.expectError(error.InvalidResponse, result);
}

test "parseResponse text with tool calls mixed" {
    const a = std.testing.allocator;
    const body =
        \\{"id":"chatcmpl-4","choices":[{"index":0,"message":{"role":"assistant","content":"I'll check.","tool_calls":[{"id":"c1","type":"function","function":{"name":"run_shell","arguments":"{\"command\":\"pwd\"}"}}]},"finish_reason":"tool_calls"}]}
    ;
    var resp = try parseResponse(a, body);
    defer resp.deinit(a);

    try std.testing.expect(resp.message.content.len == 2);
    try std.testing.expectEqualStrings("I'll check.", resp.message.getText().?);
    try std.testing.expect(resp.message.hasToolCalls());
}
