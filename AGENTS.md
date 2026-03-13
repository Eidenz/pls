# Agent Architecture

This document describes how the `pls` CLI agent works internally.

## System prompt

The agent uses the following system prompt when communicating with the LLM:

```
You are `pls`, a command-line assistant that helps users accomplish tasks
by executing shell commands.

You have access to the following tools:

1. `run_shell` - Execute a shell command on the user's machine.
2. `confirm` - Ask the user for confirmation before destructive actions.

Guidelines:
- Break complex tasks into steps. Run one command, observe output, then decide next.
- ALWAYS use `confirm` before destructive operations (kill, rm -rf, drop database, etc).
- Use `run_shell` to investigate first before taking action.
- Prefer safe, reversible approaches when possible.
- Keep responses short and clear.
- Respond in the same language the user uses.
```

## Tool-calling protocol

The agent runs in a loop:

```
User task
   |
   v
[Send messages + tools to LLM]
   |
   v
[LLM responds with text and/or tool_calls]
   |
   +--> If no tool_calls: print text, done.
   |
   +--> If tool_calls:
           |
           +--> Execute each tool call
           |    - run_shell: execute via /bin/sh, capture stdout/stderr/exit_code
           |    - confirm: prompt user Y/N
           |
           +--> Append assistant message + tool results to conversation
           |
           +--> Loop back to [Send messages + tools to LLM]
```

The loop is capped at 20 turns to prevent runaway execution.

## Available tools

### `run_shell`

Executes a shell command via `/bin/sh -c`.

**Input schema:**
```json
{
  "type": "object",
  "properties": {
    "command": {
      "type": "string",
      "description": "The shell command to execute"
    }
  },
  "required": ["command"]
}
```

**Returns:** Exit code, stdout, and stderr as a formatted string.

**Safety:** If the command matches destructive patterns (kill, rm, dd, etc.) and `--yes` was not passed, the user is prompted for confirmation before execution.

### `confirm`

Asks the user for confirmation.

**Input schema:**
```json
{
  "type": "object",
  "properties": {
    "message": {
      "type": "string",
      "description": "Description of the action to confirm"
    }
  },
  "required": ["message"]
}
```

**Returns:** `"true"` or `"false"` as a string.

## Adding a new tool

1. Create a new file in `src/tools/` (e.g., `src/tools/file_read.zig`)
2. Implement the tool's execution logic
3. Add the tool definition to the `TOOLS` array in `src/agent.zig`:
   ```zig
   .{
       .name = "your_tool_name",
       .description = "What this tool does",
       .properties = &[_]provider.ToolProperty{
           .{ .name = "param", .type = "string", .description = "..." },
       },
       .required = &[_][]const u8{"param"},
   },
   ```
4. Add a branch in `Agent.executeTool()` to handle the new tool name
5. Mention the tool in the `SYSTEM_PROMPT` so the LLM knows it exists

## Adding a new LLM provider

1. Create `src/llm/your_provider.zig`
2. Implement a `chat()` function matching this signature:
   ```zig
   pub fn chat(
       allocator: Allocator,
       // provider-specific params (api_key, model, etc.)
       system_prompt: []const u8,
       messages: []const provider.Message,
       tools: []const provider.Tool,
   ) !provider.ChatResponse
   ```
3. The function must:
   - Build the HTTP request body in the provider's format
   - Send it via `http_client.post()`
   - Parse the response into `provider.ChatResponse`
4. Add the provider to `config.zig`:
   - Add a variant to the `Provider` enum
   - Add config fields (api_key, model, host, etc.)
   - Update `fromString()`, `toString()`, `getApiKey()`, `getModel()`, `getBaseUrl()`
5. Add a branch in `Agent.callLlm()` in `src/agent.zig`
6. Add the provider to the setup wizard in `src/init.zig`

## Message format

All providers use the same internal message format (`provider.Message`). Each message has:

- `role`: system, user, assistant, or tool
- `content`: array of `ContentBlock` (text or tool_call)
- `tool_call_id`: set on tool result messages to link back to the call

The JSON serialization differs per provider:
- **Anthropic**: tool calls are `tool_use` content blocks, results are `tool_result` in user messages
- **OpenAI/Ollama**: tool calls are in a `tool_calls` array on the assistant message, results are separate `tool` role messages
- **Gemini**: tool calls are `functionCall` parts in model messages, results are `functionResponse` parts in user messages. Uses the function name as the tool call ID (Gemini doesn't have separate IDs). System prompt goes in `system_instruction` rather than as a message.
