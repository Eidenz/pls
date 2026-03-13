const std = @import("std");
const Allocator = std.mem.Allocator;
const provider = @import("provider.zig");
const openai = @import("openai.zig");

/// Send a chat request to Ollama using the OpenAI-compatible API.
/// Ollama runs locally and doesn't need an API key.
pub fn chat(
    allocator: Allocator,
    model: []const u8,
    system_prompt: []const u8,
    messages: []const provider.Message,
    tools: []const provider.Tool,
    host: []const u8,
) !provider.ChatResponse {
    return openai.chat(
        allocator,
        null, // no API key needed
        model,
        system_prompt,
        messages,
        tools,
        host, // use ollama host as base URL
    );
}
