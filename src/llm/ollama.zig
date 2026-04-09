const std = @import("std");
const Allocator = std.mem.Allocator;
const provider = @import("provider.zig");
const openai = @import("openai.zig");

/// Send a chat request to Ollama using the OpenAI-compatible API.
/// Ollama runs locally and doesn't need an API key.
///
/// Ollama exposes the OpenAI-compatible API at `<host>/v1/chat/completions`.
/// We build that full URL ourselves so the generic openai.buildChatUrl helper
/// (which only appends `/chat/completions`) leaves it untouched. This keeps
/// existing `ollama_host = "http://localhost:11434"` configs working without
/// requiring users to add `/v1`.
pub fn chat(
    allocator: Allocator,
    model: []const u8,
    system_prompt: []const u8,
    messages: []const provider.Message,
    tools: []const provider.Tool,
    host: []const u8,
) !provider.ChatResponse {
    const trimmed = if (host.len > 0 and host[host.len - 1] == '/')
        host[0 .. host.len - 1]
    else
        host;

    const full_url = try std.fmt.allocPrint(allocator, "{s}/v1/chat/completions", .{trimmed});
    defer allocator.free(full_url);

    return openai.chat(
        allocator,
        null, // no API key needed
        model,
        system_prompt,
        messages,
        tools,
        full_url,
    );
}
